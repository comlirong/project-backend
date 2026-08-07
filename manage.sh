#!/bin/bash

set -e

REPO="comlirong/project-backend"
BASE_URL="https://comlirong.github.io/project-backend/api/v1"
API_DIR="api/v1"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
info() { echo -e "${BLUE}[STEP]${NC} $1"; }

check_deps() {
    if ! command -v gh &> /dev/null; then
        error "请先安装 GitHub CLI: https://cli.github.com/"
    fi
    if ! gh auth status &> /dev/null; then
        error "请先登录: gh auth login"
    fi
    cd "$(dirname "$0")"
}

ensure_git_clean() {
    if [ -n "$(git status --porcelain)" ]; then
        git add .
        git commit -m "auto: sync before release" 2>/dev/null || true
    fi
}

# 自动发布新版本
cmd_release() {
    local version_code="$1"
    local so_path="$2"
    local message="${3:-版本更新}"
    local force="${4:-false}"
    
    [[ -z "$version_code" ]] && error "用法: $0 release <versionCode> <so_path> [message] [true/false]"
    [[ -f "$so_path" ]] || error "so 文件不存在: $so_path"
    
    local tag="v${version_code}"
    local so_filename=$(basename "$so_path")
    local download_url="https://github.com/${REPO}/releases/download/${tag}/${so_filename}"
    local sha256=$(sha256sum "$so_path" | awk '{print $1}')
    
    info "准备发布版本 ${version_code}..."
    log "文件: ${so_path}"
    log "SHA256: ${sha256}"
    log "强制更新: ${force}"
    
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
    git push origin main
    log "GitHub Pages 已更新"
    
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
    git push origin main
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
                read -p "版本号: " vc
                read -p "so 文件路径: " path
                read -p "更新说明: " msg
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
      示例: $0 release 3 /path/to/libmain.so "修复崩溃" false

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
