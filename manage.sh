
# ==============================================================================
# GitHub Backend Manager - Termux 精简版 v4.1
# 核心功能: release / notify / clean
# 无备份、无日志、无冗余
# ==============================================================================

set -euo pipefail
IFS=$'\n\t'

# ---------- 配置 ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="comlirong/project-backend"
API_DIR="api/v1"
DEFAULT_BRANCH="main"
MIN_OS_VERSION="21"
KEEP_RELEASES="0"
AUTO_CLEAN="true"

FORCE_YES=0
VERBOSE=0
HAS_JQ=0
HAS_GH=0
SHA_CMD=""

# ---------- 颜色 ----------
if [[ -t 1 ]]; then
    C_RED='\033[0;31m'; C_GREEN='\033[0;32m'
    C_YELLOW='\033[1;33m'; C_BLUE='\033[0;34m'
    C_CYAN='\033[0;36m'; C_GRAY='\033[0;90m'
    C_RESET='\033[0m'; C_BOLD='\033[1m'
else
    C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''
    C_CYAN=''; C_GRAY=''; C_RESET=''; C_BOLD=''
fi

log()   { echo -e "${C_BLUE}[*]${C_RESET} $*"; }
ok()    { echo -e "${C_GREEN}[OK]${C_RESET} $*"; }
warn()  { echo -e "${C_YELLOW}[!]${C_RESET} $*" >&2; }
error() { echo -e "${C_RED}[ERR]${C_RESET} $*" >&2; }
info()  { echo -e " ${C_CYAN}->${C_RESET} $*"; }
data()  { echo -e "    ${C_GRAY}$*${C_RESET}"; }
debug() { [[ "$VERBOSE" == "1" ]] && echo -e "    ${C_GRAY}. $*${C_RESET}" >&2 || true; }
ask()   { echo -ne "${C_BOLD}[?]${C_RESET} $* "; }

# ---------- 工具检测 ----------
detect_sha() {
    if command -v sha256sum &>/dev/null; then
        echo "sha256sum"
    elif command -v shasum &>/dev/null; then
        echo "shasum -a 256"
    fi
}

check_deps() {
    echo ""
    log "检查环境..."

    command -v gh &>/dev/null && HAS_GH=1 || HAS_GH=0
    command -v jq &>/dev/null && HAS_JQ=1 || HAS_JQ=0
    SHA_CMD=$(detect_sha)

    [[ "$HAS_GH" == "1" ]] && ok "gh CLI 就绪" || warn "gh CLI 未安装，Release 功能受限"
    [[ "$HAS_JQ" == "1" ]] && ok "jq 就绪" || info "jq 未安装，使用 Python 回退"
    [[ -n "$SHA_CMD" ]] && ok "SHA 工具就绪" || warn "未找到 sha256sum/shasum"

    if ! git rev-parse --git-dir &>/dev/null; then
        error "当前目录不是 git 仓库，请先 git init"
        exit 1
    fi
    ok "git 仓库检测通过"

    mkdir -p "$API_DIR"
}

# ---------- 通用函数 ----------
_is_int() { [[ "$1" =~ ^[0-9]+$ ]]; }

confirm() {
    [[ "$FORCE_YES" == "1" ]] && return 0
    [[ ! -t 0 ]] && { warn "非交互环境，操作已跳过"; return 1; }
    local r
    ask "$1 [y/N]: "
    read -r r
    [[ "$r" =~ ^[Yy]$ ]]
}

current_branch() {
    git branch --show-current 2>/dev/null || git symbolic-ref --short HEAD 2>/dev/null || echo "$DEFAULT_BRANCH"
}

# ---------- JSON 处理 ----------
json_get() {
    local file="$1" key="$2"
    [[ -f "$file" ]] || { echo ""; return; }
    if [[ "$HAS_JQ" == "1" ]]; then
        jq -r ".$key // empty" "$file" 2>/dev/null || echo ""
    else
        python3 -c "import json,sys; d=json.load(open(sys.argv[1])); v=d.get(sys.argv[2],''); print(v if isinstance(v,(str,int,bool)) else '')" "$file" "$key" 2>/dev/null || echo ""
    fi
}

json_get_lang() {
    local file="$1" key="$2" lang="$3"
    [[ -f "$file" ]] || { echo ""; return; }
    if [[ "$HAS_JQ" == "1" ]]; then
        jq -r ".$key.$lang // empty" "$file" 2>/dev/null || echo ""
    else
        python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get(sys.argv[2],{}).get(sys.argv[3],''))" "$file" "$key" "$lang" 2>/dev/null || echo ""
    fi
}

json_validate() {
    local file="$1"
    [[ -f "$file" ]] || { error "文件不存在: $file"; return 1; }
    if [[ "$HAS_JQ" == "1" ]]; then
        jq empty "$file" 2>/dev/null && return 0
    fi
    python3 -c "import json; json.load(open(sys.argv[1]))" "$file" 2>/dev/null && return 0
    error "JSON 格式错误: $file"
    return 1
}

json_build_update() {
    local vc="$1" url="$2" msg_zh="$3" msg_en="$4" msg_ru="$5" force="$6" sha="$7"
    if [[ "$HAS_JQ" == "1" ]]; then
        jq -n \
            --argjson vc "$vc" --arg url "$url" \
            --arg zh "$msg_zh" --arg en "$msg_en" --arg ru "$msg_ru" \
            --argjson force "$force" --arg sha "$sha" --argjson min "$MIN_OS_VERSION" \
            '{versionCode:$vc, url:$url, message:{zh:$zh, en:$en, ru:$ru}, force:$force, sha256:$sha, minOsVersion:$min}' \
            > "$API_DIR/update.json"
    else
        python3 -c "
import json, sys
vc, url, zh, en, ru, force, sha, minos = sys.argv[2:]
with open(sys.argv[1], 'w') as f:
    json.dump({
        'versionCode': int(vc), 'url': url,
        'message': {'zh': zh, 'en': en, 'ru': ru},
        'force': force.lower()=='true', 'sha256': sha,
        'minOsVersion': int(minos)
    }, f, ensure_ascii=False, indent=2)
    f.write('\n')
" "$API_DIR/update.json" "$vc" "$url" "$msg_zh" "$msg_en" "$msg_ru" "$force" "$sha" "$MIN_OS_VERSION"
    fi
}

json_build_notify() {
    local id="$1" tzh="$2" ten="$3" tru="$4" czh="$5" cen="$6" cru="$7" force="$8"
    local ts
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    if [[ "$HAS_JQ" == "1" ]]; then
        jq -n \
            --arg id "$id" --arg tzh "$tzh" --arg ten "$ten" --arg tru "$tru" \
            --arg czh "$czh" --arg cen "$cen" --arg cru "$cru" \
            --argjson force "$force" --arg ts "$ts" \
            '{id:$id, title:{zh:$tzh,en:$ten,ru:$tru}, content:{zh:$czh,en:$cen,ru:$cru}, force:$force, createdAt:$ts}' \
            > "$API_DIR/notify.json"
    else
        python3 -c "
import json, sys
from datetime import datetime, timezone
id_, tzh, ten, tru, czh, cen, cru, force = sys.argv[2:10]
with open(sys.argv[1], 'w') as f:
    json.dump({
        'id': id_, 'title': {'zh': tzh, 'en': ten, 'ru': tru},
        'content': {'zh': czh, 'en': cen, 'ru': cru},
        'force': force.lower()=='true',
        'createdAt': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
    }, f, ensure_ascii=False, indent=2)
    f.write('\n')
" "$API_DIR/notify.json" "$id" "$tzh" "$ten" "$tru" "$czh" "$cen" "$cru" "$force"
    fi
}

# ---------- Git 操作 ----------
git_sync() {
    local branch
    branch=$(current_branch)
    info "同步远程 origin/$branch..."

    git fetch origin "$branch" 2>/dev/null || git fetch origin 2>/dev/null || {
        warn "fetch 失败，跳过同步"; return 0;
    }

    local local_head remote_head
    local_head=$(git rev-parse HEAD)
    remote_head=$(git rev-parse "origin/$branch" 2>/dev/null || true)

    [[ -z "$remote_head" ]] && { warn "远程分支不存在"; return 0; }
    [[ "$local_head" == "$remote_head" ]] && { ok "已是最新"; return 0; }

    if git merge-base --is-ancestor "origin/$branch" HEAD 2>/dev/null; then
        info "本地领先，推送中..."
        git push origin "$branch" || warn "推送失败"
        return 0
    fi

    if git merge "origin/$branch" --no-edit -m "auto: sync" 2>/dev/null; then
        git push origin "$branch" || warn "推送失败"
        ok "已合并并推送"; return 0
    fi

    warn "检测到冲突，保留本地 API 文件..."
    git checkout --ours "$API_DIR/update.json" "$API_DIR/notify.json" 2>/dev/null || true
    git add "$API_DIR" 2>/dev/null || true
    git commit -m "auto: resolve conflicts" || true
    git push origin "$branch" || warn "推送失败"
    ok "冲突已解决"
}

# ---------- 版本推断 ----------
suggest_version() {
    local current=""
    [[ -f "$API_DIR/update.json" ]] && current=$(json_get "$API_DIR/update.json" "versionCode")
    [[ -z "$current" ]] && current=$(git tag --sort=-version:refname 2>/dev/null | grep -E '^v[0-9]+$' | head -1 | sed 's/^v//') || true
    [[ -n "$current" && "$current" =~ ^[0-9]+$ ]] && echo $((current + 1)) || echo "1"
}

suggest_notify_id() {
    local last=""
    [[ -f "$API_DIR/notify.json" ]] && last=$(json_get "$API_DIR/notify.json" "id")
    [[ -z "$last" ]] && { echo "001"; return; }
    local num
    num=$(echo "$last" | sed 's/^0*//')
    [[ -z "$num" ]] && num=0
    printf "%03d" $((num + 1))
}

# ---------- 查找 so ----------
find_so() {
    local dirs=("." "build" "libs" "jniLibs" "src/main/jniLibs" "app/build/intermediates/merged_native_libs")
    local found=()
    for d in "${dirs[@]}"; do
        [[ -d "$d" ]] || continue
        while IFS= read -r -d '' f; do
            found+=("$f")
        done < <(find "$d" -maxdepth 3 -name "*.so" -type f -print0 2>/dev/null)
    done
    [[ ${#found[@]} -eq 0 ]] && return
    printf '%s\n' "${found[@]}" | sort -u
}

# ---------- 清理旧版本 ----------
clean_old() {
    local keep_tag="${1:-}"
    local keep="$KEEP_RELEASES"

    info "获取远程标签..."
    local tags
    tags=$(git ls-remote --tags origin 'refs/tags/v*' 2>/dev/null | awk '{print $2}' | sed 's|refs/tags/||' | grep -E '^v[0-9]+$' | sort -Vr) || true
    [[ -z "$tags" ]] && { warn "无远程标签"; return; }

    local -a del=()
    local count=0
    while IFS= read -r tag; do
        [[ -z "$tag" || "$tag" == "$keep_tag" ]] && continue
        count=$((count+1))
        [[ "$keep" -gt 0 && "$count" -le "$keep" ]] && { ok "保留: $tag"; continue; }
        del+=("$tag")
    done <<< "$tags"

    [[ ${#del[@]} -eq 0 ]] && { ok "无需清理"; return; }
    warn "将删除 ${#del[@]} 个版本:"
    for t in "${del[@]}"; do data "$t"; done
    confirm "确认删除" || { ok "已取消"; return; }

    for tag in "${del[@]}"; do
        if [[ "$HAS_GH" == "1" ]]; then
            gh release view "$tag" --repo "$REPO" &>/dev/null && \
                gh release delete "$tag" --repo "$REPO" --yes 2>/dev/null && ok "删 release: $tag" || true
        fi
        git push origin ":refs/tags/$tag" 2>/dev/null && ok "删 tag: $tag" || warn "删 tag 失败: $tag"
    done
}

# ==============================================================================
# 命令
# ==============================================================================

cmd_init() {
    log "初始化..."
    mkdir -p "$API_DIR"
    [[ -f "$API_DIR/update.json" ]] || cat > "$API_DIR/update.json" <<'EOF'
{
  "versionCode": 0,
  "url": "",
  "message": {"zh": "", "en": "", "ru": ""},
  "force": false,
  "sha256": "",
  "minOsVersion": 21
}
EOF
    [[ -f "$API_DIR/notify.json" ]] || cat > "$API_DIR/notify.json" <<'EOF'
{
  "id": "000",
  "title": {"zh": "", "en": "", "ru": ""},
  "content": {"zh": "", "en": "", "ru": ""},
  "force": false,
  "createdAt": ""
}
EOF
    ok "初始化完成"
}

cmd_status() {
    log "项目状态"
    data "仓库: $REPO"
    data "分支: $(current_branch)"
    data "API目录: $API_DIR"
    echo ""
    [[ -f "$API_DIR/update.json" ]] && {
        info "update.json:"
        data "  版本: $(json_get "$API_DIR/update.json" "versionCode")"
        data "  URL: $(json_get "$API_DIR/update.json" "url")"
        data "  强制: $(json_get "$API_DIR/update.json" "force")"
        data "  说明(zh): $(json_get_lang "$API_DIR/update.json" "message" "zh")"
    }
    [[ -f "$API_DIR/notify.json" ]] && {
        info "notify.json:"
        data "  ID: #$(json_get "$API_DIR/notify.json" "id")"
        data "  标题(zh): $(json_get_lang "$API_DIR/notify.json" "title" "zh")"
        data "  内容(zh): $(json_get_lang "$API_DIR/notify.json" "content" "zh")"
    }
    echo ""
    data "Git提交: $(git rev-parse --short HEAD 2>/dev/null || echo 'N/A')"
    data "远程标签: $(git ls-remote --tags origin 2>/dev/null | wc -l | tr -d ' ') 个"
}

cmd_release() {
    local vc="${1:-}" so="${2:-}" msg_zh="${3:-}" msg_en="${4:-}" msg_ru="${5:-}" force="${6:-}"

    local last_zh="" last_en="" last_ru=""
    if [[ -f "$API_DIR/update.json" ]]; then
        last_zh=$(json_get_lang "$API_DIR/update.json" "message" "zh")
        last_en=$(json_get_lang "$API_DIR/update.json" "message" "en")
        last_ru=$(json_get_lang "$API_DIR/update.json" "message" "ru")
    fi

    if [[ -z "$vc" ]]; then
        local sug; sug=$(suggest_version)
        ask "版本号 [默认: $sug]: "; read -r vc
        [[ -z "$vc" ]] && vc="$sug"
    fi
    _is_int "$vc" || { error "版本号必须是整数"; return 1; }

    if [[ -z "$so" ]]; then
        local so_files; so_files=$(find_so)
        local count=0
        [[ -n "$so_files" ]] && count=$(echo "$so_files" | grep -c '^' || echo 0)
        if [[ "$count" -eq 1 ]]; then
            so="$so_files"; info "自动发现 so: $so"
        elif [[ "$count" -gt 1 ]]; then
            info "发现 $count 个 so:"
            local -a files=(); local i=1
            while IFS= read -r f; do
                [[ -n "$f" ]] || continue
                data "$i) $f ($(du -h "$f" 2>/dev/null | cut -f1))"
                files+=("$f"); i=$((i+1))
            done <<< "$so_files"
            data "0) 手动输入"
            ask "选择 [0-$((i-1))]: "; read -r choice
            if [[ "$choice" == "0" ]]; then
                ask "so 路径: "; read -r so
            elif _is_int "$choice" && [[ "$choice" -ge 1 && "$choice" -lt "$i" ]]; then
                so="${files[$((choice-1))]}"
            else
                error "无效选择"; return 1
            fi
        else
            ask "so 路径: "; read -r so
        fi
    fi
    [[ -f "$so" ]] || { error "so 文件不存在: $so"; return 1; }

    if [[ -z "$msg_zh" ]]; then
        ask "更新说明(中文) [默认: ${last_zh:-版本更新}]: "; read -r msg_zh
        [[ -z "$msg_zh" ]] && msg_zh="${last_zh:-版本更新}"
    fi
    if [[ -z "$msg_en" ]]; then
        ask "更新说明(英文) [默认: ${last_en:-$msg_zh}]: "; read -r msg_en
        [[ -z "$msg_en" ]] && msg_en="${last_en:-$msg_zh}"
    fi
    if [[ -z "$msg_ru" ]]; then
        ask "更新说明(俄文) [默认: ${last_ru:-$msg_en}]: "; read -r msg_ru
        [[ -z "$msg_ru" ]] && msg_ru="${last_ru:-$msg_en}"
    fi

    if [[ -z "$force" ]]; then
        ask "强制更新? [y/N]: "; read -r f
        [[ "$f" =~ ^[Yy]$ ]] && force="true" || force="false"
    fi

    local tag="v$vc"
    local so_name; so_name=$(basename "$so")
    local url="https://github.com/$REPO/releases/download/$tag/$so_name"
    local sha; sha=$($SHA_CMD "$so" | awk '{print $1}')
    [[ -z "$sha" ]] && { error "SHA256 计算失败"; return 1; }

    echo ""
    info "发布预览:"
    data "版本: $tag | 文件: $so | SHA256: ${sha:0:16}..."
    data "说明: zh=$msg_zh | en=$msg_en | ru=$msg_ru"
    data "强制: $force"
    confirm "确认发布" || { ok "已取消"; return 0; }

    # 自动提交未保存更改
    if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
        info "自动提交未保存更改..."
        git add . 2>/dev/null || true
        git commit -m "auto: pre-release $tag" 2>/dev/null || true
    fi
    git_sync

    json_build_update "$vc" "$url" "$msg_zh" "$msg_en" "$msg_ru" "$force" "$sha"

    git add "$API_DIR/update.json"
    git commit -m "release: $tag" || true
    git tag -a "$tag" -m "release $tag" || { error "打标签失败"; return 1; }
    git push origin "$(current_branch)" || warn "推送失败"
    git push origin "$tag" || warn "推送标签失败"

    if [[ "$HAS_GH" == "1" ]]; then
        gh release view "$tag" --repo "$REPO" &>/dev/null || \
            gh release create "$tag" --repo "$REPO" --title "Release $tag" --notes "$msg_en" 2>/dev/null || warn "创建 Release 失败"
        gh release upload "$tag" "$so" --repo "$REPO" --clobber 2>/dev/null || warn "上传资源失败"
    fi

    ok "发布完成: $tag"
    [[ "$AUTO_CLEAN" == "true" ]] && clean_old "$tag"
}

cmd_notify() {
    local id="${1:-}" title_zh="${2:-}" title_en="${3:-}" title_ru="${4:-}" content_zh="${5:-}" content_en="${6:-}" content_ru="${7:-}" force="${8:-}"

    local lt_zh="" lt_en="" lt_ru="" lc_zh="" lc_en="" lc_ru=""
    if [[ -f "$API_DIR/notify.json" ]]; then
        lt_zh=$(json_get_lang "$API_DIR/notify.json" "title" "zh")
        lt_en=$(json_get_lang "$API_DIR/notify.json" "title" "en")
        lt_ru=$(json_get_lang "$API_DIR/notify.json" "title" "ru")
        lc_zh=$(json_get_lang "$API_DIR/notify.json" "content" "zh")
        lc_en=$(json_get_lang "$API_DIR/notify.json" "content" "en")
        lc_ru=$(json_get_lang "$API_DIR/notify.json" "content" "ru")
    fi

    if [[ -z "$id" ]]; then
        local sug; sug=$(suggest_notify_id)
        ask "通知ID [默认: $sug]: "; read -r id
        [[ -z "$id" ]] && id="$sug"
    fi

    if [[ -z "$title_zh" ]]; then
        ask "标题(中文) [默认: ${lt_zh:-(无)}]: "; read -r title_zh
        [[ -z "$title_zh" ]] && title_zh="$lt_zh"
    fi
    if [[ -z "$title_en" ]]; then
        ask "标题(英文) [默认: ${lt_en:-$title_zh}]: "; read -r title_en
        [[ -z "$title_en" ]] && title_en="${lt_en:-$title_zh}"
    fi
    if [[ -z "$title_ru" ]]; then
        ask "标题(俄文) [默认: ${lt_ru:-$title_en}]: "; read -r title_ru
        [[ -z "$title_ru" ]] && title_ru="${lt_ru:-$title_en}"
    fi

    if [[ -z "$content_zh" ]]; then
        ask "内容(中文) [默认: ${lc_zh:-(无)}]: "; read -r content_zh
        [[ -z "$content_zh" ]] && content_zh="$lc_zh"
    fi
    if [[ -z "$content_en" ]]; then
        ask "内容(英文) [默认: ${lc_en:-$content_zh}]: "; read -r content_en
        [[ -z "$content_en" ]] && content_en="${lc_en:-$content_zh}"
    fi
    if [[ -z "$content_ru" ]]; then
        ask "内容(俄文) [默认: ${lc_ru:-$content_en}]: "; read -r content_ru
        [[ -z "$content_ru" ]] && content_ru="${lc_ru:-$content_en}"
    fi

    if [[ -z "$force" ]]; then
        ask "强制显示? [y/N]: "; read -r f
        [[ "$f" =~ ^[Yy]$ ]] && force="true" || force="false"
    fi

    json_build_notify "$id" "$title_zh" "$title_en" "$title_ru" "$content_zh" "$content_en" "$content_ru" "$force"

    git add "$API_DIR/notify.json" 2>/dev/null || true
    git commit -m "notify: $id" 2>/dev/null || true
    git push origin "$(current_branch)" 2>/dev/null || warn "推送失败"
    ok "通知已发布: #$id"
}

cmd_clean() {
    local keep_tag="${1:-}"
    [[ -z "$keep_tag" && -f "$API_DIR/update.json" ]] && keep_tag="v$(json_get "$API_DIR/update.json" "versionCode")"
    [[ -z "$keep_tag" || "$keep_tag" == "v" ]] && keep_tag=$(git tag --sort=-version:refname 2>/dev/null | grep -E '^v[0-9]+$' | head -1) || true
    [[ -z "$keep_tag" ]] && { ask "保留标签 (如 v100): "; read -r keep_tag; }
    clean_old "$keep_tag"
}

# ---------- 菜单 ----------
show_menu() {
    while true; do
        echo ""
        log "GitHub Backend Manager v4.1"
        data "仓库: $REPO  |  分支: $(current_branch)"
        echo ""
        echo "  [1] 发布新版本 (release)"
        echo "  [2] 发布通知 (notify)"
        echo "  [3] 清理旧版本 (clean)"
        echo "  [4] 查看状态 (status)"
        echo "  [5] 初始化 (init)"
        echo "  [0] 退出"
        echo ""
        ask "请选择 [0-5]: "
        local c; read -r c
        echo ""
        case "$c" in
            1) cmd_release ;;
            2) cmd_notify ;;
            3) cmd_clean ;;
            4) cmd_status ;;
            5) cmd_init ;;
            0|q) log "再见!"; break ;;
            *) warn "无效选择" ;;
        esac
        echo ""
        read -rp "按 Enter 继续..."
    done
}

usage() {
    cat <<'EOF'
GitHub Backend Manager v4.1 (极简版)

用法:
    bash manage.sh              交互菜单
    bash manage.sh <命令> [参数...]

命令:
    init                初始化环境
    status              查看状态
    release [v] [so] [msg_zh] [msg_en] [msg_ru] [force]
                        发布新版本
    notify [id] [title_zh] [title_en] [title_ru]
           [content_zh] [content_en] [content_ru] [force]
                        发布通知
    clean [tag]         清理旧版本

选项:
    -y                  自动确认
    -v                  调试信息
    -h                  显示帮助
EOF
}

parse_opts() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -y) FORCE_YES=1; shift ;;
            -v) VERBOSE=1; shift ;;
            -h|--help) usage; exit 0 ;;
            --) shift; break ;;
            -*) warn "未知选项: $1"; shift ;;
            *) break ;;
        esac
    done
    CMD="${1:-}"
    shift 2>/dev/null || true
    ARGS=("$@")
}

main() {
    cd "$SCRIPT_DIR"
    check_deps
    parse_opts "$@"

    if [[ -z "$CMD" ]]; then
        show_menu
        exit 0
    fi

    case "$CMD" in
        init)       cmd_init ;;
        status|st)  cmd_status ;;
        release|r)  cmd_release "${ARGS[@]}" ;;
        notify|n)   cmd_notify "${ARGS[@]}" ;;
        clean|c)    cmd_clean "${ARGS[@]}" ;;
        help)       usage ;;
        *)          error "未知命令: $CMD"; usage ;;
    esac
}

main "$@"