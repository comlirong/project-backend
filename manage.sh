#!/bin/bash

set -e

REPO="comlirong/project-backend"
BASE_URL="https://comlirong.github.io/project-backend/api/v1"
API_DIR="api/v1"
HISTORY_MAX=20

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

log() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
info() { echo -e "${BLUE}[STEP]${NC} $1"; }
dim() { echo -e "${CYAN}[HINT]${NC} $1"; }
highlight() { echo -e "${MAGENTA}[DATA]${NC} $1"; }

check_deps() {
    if ! command -v gh &> /dev/null; then
        error "请先安装 GitHub CLI: https://cli.github.com/"
    fi
    if ! gh auth status &> /dev/null; then
        error "请先登录: gh auth login"
    fi
    cd "$(dirname "$0")"
}

ensure_api_dir() {
    if [ ! -d "$API_DIR" ]; then
        mkdir -p "$API_DIR"
        log "创建目录: ${API_DIR}"
    fi
}

# 从 JSON 文件中提取字符串值（不依赖 jq/python，纯 Bash）
get_json_value() {
    local file="$1"
    local key="$2"
    if [ ! -f "$file" ]; then
        echo ""
        return
    fi
    grep -o "\"${key}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$file" 2>/dev/null | \
        sed 's/.*"'"${key}"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' || echo ""
}

# 从 JSON 中提取布尔值
get_json_bool() {
    local file="$1"
    local key="$2"
    if [ ! -f "$file" ]; then
        echo "false"
        return
    fi
    grep -o "\"${key}\"[[:space:]]*:[[:space:]]*\(true\|false\)" "$file" 2>/dev/null | \
        sed 's/.*:[[:space:]]*\(true\|false\).*/\1/' || echo "false"
}

# 自动暂存本地修改并提交
ensure_git_clean() {
    if [ -n "$(git status --porcelain)" ]; then
        git add .
        git commit -m "auto: sync before release" 2>/dev/null || true
    fi
}

# 自动同步远程，处理冲突
sync_remote() {
    local branch="main"

    info "同步远程分支 origin/${branch}..."
    git fetch origin "${branch}" || error "获取远程分支失败，请检查网络"

    if git merge-base --is-ancestor "origin/${branch}" HEAD 2>/dev/null; then
        git push origin "${branch}"
        log "已推送至远程"
        return 0
    fi

    info "检测到远程有新提交，正在自动合并..."
    if git merge "origin/${branch}" --no-edit -m "auto: sync remote changes" 2>/dev/null; then
        git push origin "${branch}"
        log "合并成功并已推送"
        return 0
    fi

    warn "检测到文件冲突，正在自动解决（优先保留本地版本）..."

    for f in "${API_DIR}/update.json" "${API_DIR}/notify.json" "${API_DIR}/notify_history.json"; do
        if [ -f "$f" ]; then
            if git diff --name-only --diff-filter=U | grep -qx "${f}"; then
                git checkout --ours "$f"
                git add "$f"
                log "冲突已解决: ${f} (保留本地)"
            fi
        fi
    done

    git diff --name-only --diff-filter=U | while read -r conflict_file; do
        git checkout --ours "$conflict_file"
        git add "$conflict_file"
        warn "冲突已解决: ${conflict_file} (保留本地)"
    done

    git commit -m "auto: resolve merge conflicts (keep local)" || true
    git push origin "${branch}"
    log "冲突已解决并推送完成"
}

# 自动发布新版本
cmd_release() {
    local version_code="$1"
    local so_path="$2"
    local message="${3:-}"
    local force="${4:-false}"

    [[ -z "$version_code" ]] && error "用法: $0 release <versionCode> <so_path> [message] [true/false]"
    [[ -f "$so_path" ]] || error "so 文件不存在: $so_path"

    local tag="v${version_code}"
    local so_filename=$(basename "$so_path")
    local download_url="https://github.com/${REPO}/releases/download/${tag}/${so_filename}"
    local sha256=$(sha256sum "$so_path" | awk '{print $1}')

    if [[ -z "$message" ]]; then
        local last_msg
        last_msg=$(get_json_value "${API_DIR}/update.json" "message")
        if [[ -n "$last_msg" ]]; then
            message="$last_msg"
            dim "更新说明为空，已自动复用旧版: \"${message}\""
        else
            message="版本更新"
            dim "未找到旧版说明，使用默认: \"${message}\""
        fi
    fi

    info "准备发布版本 ${version_code}..."
    log "文件: ${so_path}"
    log "SHA256: ${sha256}"
    log "强制更新: ${force}"
    log "更新说明: ${message}"

    ensure_api_dir

    cat > "${API_DIR}/update.json" << EOF
{
  "versionCode": ${version_code},
  "url": "${download_url}",
  "message": "${message}",
  "force": ${force},
  "sha256": "${sha256}",
  "minOsVersion": 21
}
EOF

    ensure_git_clean
    git add "${API_DIR}/update.json"
    git commit -m "release: v${version_code}" || true
    sync_remote

    if gh release view "${tag}" --repo "${REPO}" &> /dev/null; then
        info "Release ${tag} 已存在，删除旧文件并重新上传..."
        gh release delete-asset "${tag}" "${so_filename}" --repo "${REPO}" -y 2>/dev/null || true
        gh release upload "${tag}" "$so_path" --repo "${REPO}" || error "上传失败"
    else
        info "创建新 Release ${tag}..."
        gh release create "${tag}" "$so_path" \
            --repo "${REPO}" \
            --title "Version ${version_code}" \
            --notes "${message}" || error "Release 创建失败"
    fi

    log "发布完成!"
    log "更新接口: ${BASE_URL}/update.json"
    log "下载地址: ${download_url}"
}

# 生成通知 ID（智能递增）
gen_notify_id() {
    local last_id
    last_id=$(get_json_value "${API_DIR}/notify.json" "id")

    if [[ -z "$last_id" ]]; then
        echo "001"
        return
    fi

    # 如果是纯数字，直接 +1
    if [[ "$last_id" =~ ^[0-9]+$ ]]; then
        printf "%03d" $((10#$last_id + 1))
    else
        # 非纯数字，使用时间戳
        date +"%Y%m%d%H%M%S"
    fi
}

# 追加通知到历史记录
append_notify_history() {
    local id="$1"
    local title="$2"
    local content="$3"
    local force="$4"
    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    local history_file="${API_DIR}/notify_history.json"

    # 如果历史文件不存在，创建初始结构
    if [ ! -f "$history_file" ]; then
        cat > "$history_file" << EOF
{
  "total": 0,
  "items": []
}
EOF
    fi

    # 读取现有 items 并追加新记录（使用临时文件处理 JSON 拼接）
    local tmp_file="${history_file}.tmp"

    # 提取现有 items 内容（去掉最外层的包裹）
    local existing_items=""
    if [ -f "$history_file" ]; then
        existing_items=$(sed -n '/"items":/,/\]/p' "$history_file" | sed '1d;$d' | sed '$s/,$//')
    fi

    # 构建新的 items 数组
    local new_entry="    {\n      \"id\": \"${id}\",\n      \"title\": \"${title}\",\n      \"content\": \"${content}\",\n      \"force\": ${force},\n      \"createdAt\": \"${timestamp}\"\n    }"

    if [[ -n "$existing_items" ]]; then
        # 现有记录 + 新记录，限制数量
        local all_items="${existing_items},\n${new_entry}"
        # 只保留最后 HISTORY_MAX 条
        local filtered_items
        filtered_items=$(echo -e "$all_items" | awk -v max="$HISTORY_MAX" '
            /"id":/ { count++ }
            { lines[NR] = $0 }
            END {
                start = 1
                if (count > max) {
                    # 找到需要保留的起始位置
                    skip = count - max
                    seen = 0
                    for (i = 1; i <= NR; i++) {
                        if (lines[i] ~ /"id":/) seen++
                        if (seen > skip) { start = i; break }
                    }
                }
                for (i = start; i <= NR; i++) print lines[i]
            }
        ')

        cat > "$tmp_file" << EOF
{
  "total": $(echo "$filtered_items" | grep -c '"id":' || echo 0),
  "items": [
$(echo -e "$filtered_items")
  ]
}
EOF
    else
        cat > "$tmp_file" << EOF
{
  "total": 1,
  "items": [
${new_entry}
  ]
}
EOF
    fi

    mv "$tmp_file" "$history_file"
}

# 快速更新通知（核心优化）
cmd_notify() {
    local notify_id="${1:-}"
    local title="${2:-}"
    local content="${3:-}"
    local force="${4:-false}"

    # 智能生成 ID
    if [[ -z "$notify_id" ]]; then
        notify_id=$(gen_notify_id)
        dim "通知ID为空，已自动生成: ${notify_id}"
    fi

    # 复用旧版标题
    if [[ -z "$title" ]]; then
        local last_title
        last_title=$(get_json_value "${API_DIR}/notify.json" "title")
        if [[ -n "$last_title" ]]; then
            title="$last_title"
            dim "标题为空，已自动复用旧版: \"${title}\""
        else
            error "标题不能为空（且无旧版可复用）"
        fi
    fi

    # 复用旧版内容
    if [[ -z "$content" ]]; then
        local last_content
        last_content=$(get_json_value "${API_DIR}/notify.json" "content")
        if [[ -n "$last_content" ]]; then
            content="$last_content"
            dim "内容为空，已自动复用旧版: \"${content}\""
        else
            error "内容不能为空（且无旧版可复用）"
        fi
    fi

    info "更新通知 ${notify_id}..."
    log "标题: ${title}"
    log "强制显示: ${force}"

    ensure_api_dir

    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    cat > "${API_DIR}/notify.json" << EOF
{
  "id": "${notify_id}",
  "title": "${title}",
  "content": "${content}",
  "force": ${force},
  "createdAt": "${timestamp}"
}
EOF

    # 追加到历史记录
    append_notify_history "$notify_id" "$title" "$content" "$force"

    ensure_git_clean
    git add "${API_DIR}/notify.json" "${API_DIR}/notify_history.json"
    git commit -m "notify: ${notify_id}" || true
    sync_remote
    log "通知已推送: ${BASE_URL}/notify.json"
    log "历史记录: ${BASE_URL}/notify_history.json"
}

# 查看通知历史
cmd_history() {
    local history_file="${API_DIR}/notify_history.json"
    echo ""
    log "===== 通知历史记录 ====="
    echo ""
    if [ -f "$history_file" ]; then
        cat "$history_file"
    else
        echo "暂无历史记录"
    fi
    echo ""
}

# 查看状态
cmd_status() {
    echo ""
    log "===== 当前配置 ====="
    echo ""
    echo -e "${YELLOW}update.json:${NC}"
    if [ -f "${API_DIR}/update.json" ]; then
        cat "${API_DIR}/update.json"
    else
        echo "不存在"
    fi
    echo ""
    echo -e "${YELLOW}notify.json (当前通知):${NC}"
    if [ -f "${API_DIR}/notify.json" ]; then
        cat "${API_DIR}/notify.json"
    else
        echo "不存在"
    fi
    echo ""
    echo -e "${YELLOW}notify_history.json:${NC}"
    if [ -f "${API_DIR}/notify_history.json" ]; then
        highlight "共 $(grep -c '"id":' "${API_DIR}/notify_history.json" || echo 0) 条历史记录"
    else
        echo "不存在"
    fi
    echo ""
}

# 交互式菜单
interactive_menu() {
    while true; do
        echo ""
        log "GitHub 后端管理"
        echo "  1) 发布新版本"
        echo "  2) 更新通知"
        echo "  3) 查看通知历史"
        echo "  4) 查看当前配置"
        echo "  0) 退出"
        echo ""
        read -p "选择操作: " choice

        case $choice in
            1)
                echo ""
                local last_msg
                last_msg=$(get_json_value "${API_DIR}/update.json" "message")
                [ -n "$last_msg" ] && dim "旧版说明: ${last_msg}"

                read -p "版本号: " vc
                read -p "so 文件路径: " path
                read -p "更新说明 (留空复用旧版): " msg
                read -p "强制更新 [y/N]: " f
                [[ "$f" == "y" ]] && f="true" || f="false"
                cmd_release "$vc" "$path" "$msg" "$f"
                ;;
            2)
                echo ""
                local last_id last_title last_content
                last_id=$(get_json_value "${API_DIR}/notify.json" "id")
                last_title=$(get_json_value "${API_DIR}/notify.json" "title")
                last_content=$(get_json_value "${API_DIR}/notify.json" "content")

                [ -n "$last_id" ] && dim "旧版ID: ${last_id}"
                [ -n "$last_title" ] && dim "旧版标题: ${last_title}"
                [ -n "$last_content" ] && dim "旧版内容: ${last_content}"

                read -p "通知ID (留空自动递增): " id
                read -p "标题 (留空复用旧版): " title
                read -p "内容 (留空复用旧版): " content
                read -p "强制显示 [y/N]: " f
                [[ "$f" == "y" ]] && f="true" || f="false"
                cmd_notify "$id" "$title" "$content" "$f"
                ;;
            3) cmd_history ;;
            4) cmd_status ;;
            0) exit 0 ;;
            *) warn "无效选择" ;;
        esac
    done
}

# 帮助信息
show_help() {
    cat << EOF
用法: $0 <命令> [参数...]

命令:
  release <versionCode> <so_path> [message] [force]
      发布新版本，自动更新 update.json 并创建 GitHub Release
      message 留空则自动复用旧版 update.json 中的说明
      示例: $0 release 3 /path/to/libmain.so "修复崩溃" false
      示例: $0 release 3 /path/to/libmain.so "" false   (复用旧说明)

  notify [id] [title] [content] [force]
      更新通知内容，所有参数均可留空自动复用/生成
      id 留空 → 自动递增生成（如 001 → 002）
      title/content 留空 → 复用旧版 notify.json 内容
      示例: $0 notify 002 "维护通知" "今晚更新" false
      示例: $0 notify "" "" "" false   (完全复用旧版，仅递增ID)

  history
      查看通知历史记录

  status
      查看当前 update.json、notify.json 和历史记录概览

  help
      显示此帮助信息

不带参数时进入交互式菜单。
EOF
}

# 主入口
check_deps
ensure_api_dir

case "${1:-}" in
    release)
        shift
        cmd_release "$@"
        ;;
    notify)
        shift
        cmd_notify "$@"
        ;;
    history)
        cmd_history
        ;;
    status)
        cmd_status
        ;;
    help|--help|-h)
        show_help
        ;;
    "")
        interactive_menu
        ;;
    *)
        error "未知命令: $1\n请使用: $0 help"
        ;;
esac
