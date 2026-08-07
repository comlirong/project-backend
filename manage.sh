#!/bin/bash

set -e

REPO="comlirong/project-backend"
BASE_URL="https://comlirong.github.io/project-backend/api/v1"
API_DIR="api/v1"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
info() { echo -e "${BLUE}[STEP]${NC} $1"; }
dim() { echo -e "${CYAN}[HINT]${NC} $1"; }

check_deps() {
    if ! command -v gh &> /dev/null; then
        error "请先安装 GitHub CLI: https://cli.github.com/"
    fi
    if ! gh auth status &> /dev/null; then
        error "请先登录: gh auth login"
    fi
    cd "$(dirname "$0")"
}

# 确保 api 目录存在
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

# 自动暂存本地修改并提交
ensure_git_clean() {
    if [ -n "$(git status --porcelain)" ]; then
        git add .
        git commit -m "auto: sync before release" 2>/dev/null || true
    fi
}

# 自动同步远程，处理冲突（核心优化）
sync_remote() {
    local branch="main"

    info "同步远程分支 origin/${branch}..."
    git fetch origin "${branch}" || error "获取远程分支失败，请检查网络"

    # 检查远程是否领先于本地（origin/main 不是 HEAD 的祖先，说明本地落后）
    if git merge-base --is-ancestor "origin/${branch}" HEAD 2>/dev/null; then
        # 远程是本地的祖先 → 本地领先或同步，直接推送
        git push origin "${branch}"
        log "已推送至远程"
        return 0
    fi

    # 本地落后于远程，尝试自动合并
    info "检测到远程有新提交，正在自动合并..."
    if git merge "origin/${branch}" --no-edit -m "auto: sync remote changes" 2>/dev/null; then
        git push origin "${branch}"
        log "合并成功并已推送"
        return 0
    fi

    # 合并冲突，自动解决（核心优化：优先保留本地修改）
    warn "检测到文件冲突，正在自动解决（优先保留本地版本）..."

    # 对我们管理的 API JSON 文件，强制保留本地版本
    for f in "${API_DIR}/update.json" "${API_DIR}/notify.json"; do
        if [ -f "$f" ]; then
            if git diff --name-only --diff-filter=U | grep -qx "${f}"; then
                git checkout --ours "$f"
                git add "$f"
                log "冲突已解决: ${f} (保留本地)"
            fi
        fi
    done

    # 对其他冲突文件，同样保留本地版本（可根据需要改为 --theirs）
    git diff --name-only --diff-filter=U | while read -r conflict_file; do
        git checkout --ours "$conflict_file"
        git add "$conflict_file"
        warn "冲突已解决: ${conflict_file} (保留本地)"
    done

    # 提交合并结果
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

    # 如果 message 为空，自动复用旧版（核心优化）
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

    # 更新 update.json
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

    # 自动处理远端冲突并推送（核心优化）
    sync_remote

    # 创建或更新 Release
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

# 快速更新通知
cmd_notify() {
    local notify_id="$1"
    local title="$2"
    local content="$3"
    local force="${4:-false}"

    [[ -z "$notify_id" ]] && error "用法: $0 notify <id> <title> <content> [true/false]"
    [[ -z "$title" ]] && error "标题不能为空"
    [[ -z "$content" ]] && error "内容不能为空"

    info "更新通知 ${notify_id}..."
    ensure_api_dir

    cat > "${API_DIR}/notify.json" << EOF
{
  "id": "${notify_id}",
  "title": "${title}",
  "content": "${content}",
  "force": ${force}
}
EOF

    ensure_git_clean
    git add "${API_DIR}/notify.json"
    git commit -m "notify: ${notify_id}" || true
    sync_remote
    log "通知已推送: ${BASE_URL}/notify.json"
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
    echo -e "${YELLOW}notify.json:${NC}"
    if [ -f "${API_DIR}/notify.json" ]; then
        cat "${API_DIR}/notify.json"
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
        echo "  3) 查看当前配置"
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
                read -p "通知ID: " id
                read -p "标题: " title
                read -p "内容: " content
                read -p "强制显示 [y/N]: " f
                [[ "$f" == "y" ]] && f="true" || f="false"
                cmd_notify "$id" "$title" "$content" "$f"
                ;;
            3) cmd_status ;;
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

  notify <id> <title> <content> [force]
      更新通知内容
      示例: $0 notify 001 "系统通知" "请更新" false

  status
      查看当前 update.json 和 notify.json 内容

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
