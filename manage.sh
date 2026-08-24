#!/usr/bin/env bash
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

# ---------- 语言检测 ----------
LANG_IS_EN=0
if [[ "${LANG:-}" =~ ^en ]] || [[ "${LC_ALL:-}" =~ ^en ]] || [[ "${LC_MESSAGES:-}" =~ ^en ]]; then
    LANG_IS_EN=1
fi

# 翻译函数：根据语言返回对应字符串
_t() {
    if [[ "$LANG_IS_EN" -eq 1 ]]; then
        echo "$2"
    else
        echo "$1"
    fi
}

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
    log "$(_t "检查环境..." "Checking environment...")"

    command -v gh &>/dev/null && HAS_GH=1 || HAS_GH=0
    command -v jq &>/dev/null && HAS_JQ=1 || HAS_JQ=0
    SHA_CMD=$(detect_sha)

    [[ "$HAS_GH" == "1" ]] && ok "$(_t "gh CLI 就绪" "gh CLI ready")" || warn "$(_t "gh CLI 未安装，Release 功能受限" "gh CLI not installed, Release features limited")"
    [[ "$HAS_JQ" == "1" ]] && ok "$(_t "jq 就绪" "jq ready")" || info "$(_t "jq 未安装，使用 Python 回退" "jq not installed, using Python fallback")"
    [[ -n "$SHA_CMD" ]] && ok "$(_t "SHA 工具就绪" "SHA tool ready")" || warn "$(_t "未找到 sha256sum/shasum" "sha256sum/shasum not found")"

    if ! git rev-parse --git-dir &>/dev/null; then
        error "$(_t "当前目录不是 git 仓库，请先 git init" "Not a git repository, please run 'git init' first")"
        exit 1
    fi
    ok "$(_t "git 仓库检测通过" "Git repository check passed")"

    mkdir -p "$API_DIR"
}

# ---------- 通用函数 ----------
_is_int() { [[ "$1" =~ ^[0-9]+$ ]]; }

confirm() {
    [[ "$FORCE_YES" == "1" ]] && return 0
    [[ ! -t 0 ]] && { warn "$(_t "非交互环境，操作已跳过" "Non-interactive environment, operation skipped")"; return 1; }
    local r
    ask "$(_t "确认" "Confirm")? [y/N]: "
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
    [[ -f "$file" ]] || { error "$(_t "文件不存在" "File not found"): $file"; return 1; }
    if [[ "$HAS_JQ" == "1" ]]; then
        jq empty "$file" 2>/dev/null && return 0
    fi
    python3 -c "import json; json.load(open(sys.argv[1]))" "$file" 2>/dev/null && return 0
    error "$(_t "JSON 格式错误" "JSON format error"): $file"
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
    info "$(_t "同步远程 origin/$branch..." "Syncing remote origin/$branch...")"

    git fetch origin "$branch" 2>/dev/null || git fetch origin 2>/dev/null || {
        warn "$(_t "fetch 失败，跳过同步" "Fetch failed, skipping sync")"; return 0;
    }

    local local_head remote_head
    local_head=$(git rev-parse HEAD)
    remote_head=$(git rev-parse "origin/$branch" 2>/dev/null || true)

    [[ -z "$remote_head" ]] && { warn "$(_t "远程分支不存在" "Remote branch does not exist")"; return 0; }
    [[ "$local_head" == "$remote_head" ]] && { ok "$(_t "已是最新" "Already up to date")"; return 0; }

    if git merge-base --is-ancestor "origin/$branch" HEAD 2>/dev/null; then
        info "$(_t "本地领先，推送中..." "Local ahead, pushing...")"
        git push origin "$branch" || warn "$(_t "推送失败" "Push failed")"
        return 0
    fi

    if git merge "origin/$branch" --no-edit -m "auto: sync" 2>/dev/null; then
        git push origin "$branch" || warn "$(_t "推送失败" "Push failed")"
        ok "$(_t "已合并并推送" "Merged and pushed")"; return 0
    fi

    warn "$(_t "检测到冲突，保留本地 API 文件..." "Conflict detected, keeping local API files...")"
    git checkout --ours "$API_DIR/update.json" "$API_DIR/notify.json" 2>/dev/null || true
    git add "$API_DIR" 2>/dev/null || true
    git commit -m "auto: resolve conflicts" || true
    git push origin "$branch" || warn "$(_t "推送失败" "Push failed")"
    ok "$(_t "冲突已解决" "Conflicts resolved")"
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

    info "$(_t "获取远程标签..." "Fetching remote tags...")"
    local tags
    tags=$(git ls-remote --tags origin 'refs/tags/v*' 2>/dev/null | awk '{print $2}' | sed 's|refs/tags/||' | grep -E '^v[0-9]+$' | sort -Vr) || true
    [[ -z "$tags" ]] && { warn "$(_t "无远程标签" "No remote tags")"; return; }

    local -a del=()
    local count=0
    while IFS= read -r tag; do
        [[ -z "$tag" || "$tag" == "$keep_tag" ]] && continue
        count=$((count+1))
        [[ "$keep" -gt 0 && "$count" -le "$keep" ]] && { ok "$(_t "保留" "Keeping"): $tag"; continue; }
        del+=("$tag")
    done <<< "$tags"

    [[ ${#del[@]} -eq 0 ]] && { ok "$(_t "无需清理" "Nothing to clean")"; return; }
    warn "$(_t "将删除 ${#del[@]} 个版本:" "Will delete ${#del[@]} releases:")"
    for t in "${del[@]}"; do data "$t"; done
    confirm "$(_t "确认删除" "Confirm deletion")" || { ok "$(_t "已取消" "Cancelled")"; return; }

    for tag in "${del[@]}"; do
        if [[ "$HAS_GH" == "1" ]]; then
            gh release view "$tag" --repo "$REPO" &>/dev/null && \
                gh release delete "$tag" --repo "$REPO" --yes 2>/dev/null && ok "$(_t "删 release" "Deleted release"): $tag" || true
        fi
        git push origin ":refs/tags/$tag" 2>/dev/null && ok "$(_t "删 tag" "Deleted tag"): $tag" || warn "$(_t "删 tag 失败" "Failed to delete tag"): $tag"
    done
}

# ==============================================================================
# 命令
# ==============================================================================

cmd_init() {
    log "$(_t "初始化..." "Initializing...")"
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
    ok "$(_t "初始化完成" "Initialization complete")"
}

cmd_status() {
    log "$(_t "项目状态" "Project status")"
    data "$(_t "仓库" "Repository"): $REPO"
    data "$(_t "分支" "Branch"): $(current_branch)"
    data "$(_t "API目录" "API directory"): $API_DIR"
    echo ""
    [[ -f "$API_DIR/update.json" ]] && {
        info "update.json:"
        data "$(_t "版本" "Version"): $(json_get "$API_DIR/update.json" "versionCode")"
        data "URL: $(json_get "$API_DIR/update.json" "url")"
        data "$(_t "强制" "Force"): $(json_get "$API_DIR/update.json" "force")"
        data "$(_t "说明(zh)" "Note(zh)"): $(json_get_lang "$API_DIR/update.json" "message" "zh")"
    }
    [[ -f "$API_DIR/notify.json" ]] && {
        info "notify.json:"
        data "ID: #$(json_get "$API_DIR/notify.json" "id")"
        data "$(_t "标题(zh)" "Title(zh)"): $(json_get_lang "$API_DIR/notify.json" "title" "zh")"
        data "$(_t "内容(zh)" "Content(zh)"): $(json_get_lang "$API_DIR/notify.json" "content" "zh")"
    }
    echo ""
    data "$(_t "Git提交" "Git commit"): $(git rev-parse --short HEAD 2>/dev/null || echo 'N/A')"
    data "$(_t "远程标签" "Remote tags"): $(git ls-remote --tags origin 2>/dev/null | wc -l | tr -d ' ') $(_t "个" "")"
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
        ask "$(_t "版本号" "Version number") [$(_t "默认" "default"): $sug]: "; read -r vc
        [[ -z "$vc" ]] && vc="$sug"
    fi
    _is_int "$vc" || { error "$(_t "版本号必须是整数" "Version must be an integer")"; return 1; }

    if [[ -z "$so" ]]; then
        local so_files; so_files=$(find_so)
        local count=0
        [[ -n "$so_files" ]] && count=$(echo "$so_files" | grep -c '^' || echo 0)
        if [[ "$count" -eq 1 ]]; then
            so="$so_files"; info "$(_t "自动发现 so" "Auto-discovered so"): $so"
        elif [[ "$count" -gt 1 ]]; then
            info "$(_t "发现" "Found") $count $(_t "个 so" "so files"):"
            local -a files=(); local i=1
            while IFS= read -r f; do
                [[ -n "$f" ]] || continue
                data "$i) $f ($(du -h "$f" 2>/dev/null | cut -f1))"
                files+=("$f"); i=$((i+1))
            done <<< "$so_files"
            data "0) $(_t "手动输入" "Manual input")"
            ask "$(_t "选择" "Select") [0-$((i-1))]: "; read -r choice
            if [[ "$choice" == "0" ]]; then
                ask "$(_t "so 路径" "SO file path"): "; read -r so
            elif _is_int "$choice" && [[ "$choice" -ge 1 && "$choice" -lt "$i" ]]; then
                so="${files[$((choice-1))]}"
            else
                error "$(_t "无效选择" "Invalid choice")"; return 1
            fi
        else
            ask "$(_t "so 路径" "SO file path"): "; read -r so
        fi
    fi
    [[ -f "$so" ]] || { error "$(_t "so 文件不存在" "SO file not found"): $so"; return 1; }

    if [[ -z "$msg_zh" ]]; then
        ask "$(_t "更新说明(中文)" "Update notes (Chinese)") [$(_t "默认" "default"): ${last_zh:-$(_t "版本更新" "version update")}]: "; read -r msg_zh
        [[ -z "$msg_zh" ]] && msg_zh="${last_zh:-$(_t "版本更新" "version update")}"
    fi
    if [[ -z "$msg_en" ]]; then
        ask "$(_t "更新说明(英文)" "Update notes (English)") [$(_t "默认" "default"): ${last_en:-$msg_zh}]: "; read -r msg_en
        [[ -z "$msg_en" ]] && msg_en="${last_en:-$msg_zh}"
    fi
    if [[ -z "$msg_ru" ]]; then
        ask "$(_t "更新说明(俄文)" "Update notes (Russian)") [$(_t "默认" "default"): ${last_ru:-$msg_en}]: "; read -r msg_ru
        [[ -z "$msg_ru" ]] && msg_ru="${last_ru:-$msg_en}"
    fi

    if [[ -z "$force" ]]; then
        ask "$(_t "强制更新" "Force update")? [y/N]: "; read -r f
        [[ "$f" =~ ^[Yy]$ ]] && force="true" || force="false"
    fi

    local tag="v$vc"
    local so_name; so_name=$(basename "$so")
    local url="https://github.com/$REPO/releases/download/$tag/$so_name"
    local sha; sha=$($SHA_CMD "$so" | awk '{print $1}')
    [[ -z "$sha" ]] && { error "$(_t "SHA256 计算失败" "SHA256 calculation failed")"; return 1; }

    echo ""
    info "$(_t "发布预览" "Release preview"):"
    data "$(_t "版本" "Version"): $tag | $(_t "文件" "File"): $so | SHA256: ${sha:0:16}..."
    data "$(_t "说明" "Notes"): zh=$msg_zh | en=$msg_en | ru=$msg_ru"
    data "$(_t "强制" "Force"): $force"
    confirm "$(_t "确认发布" "Confirm release")" || { ok "$(_t "已取消" "Cancelled")"; return 0; }

    # 自动提交未保存更改
    if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
        info "$(_t "自动提交未保存更改..." "Auto-committing unsaved changes...")"
        git add . 2>/dev/null || true
        git commit -m "auto: pre-release $tag" 2>/dev/null || true
    fi
    git_sync

    json_build_update "$vc" "$url" "$msg_zh" "$msg_en" "$msg_ru" "$force" "$sha"

    git add "$API_DIR/update.json"
    git commit -m "release: $tag" || true
    git tag -a "$tag" -m "release $tag" || { error "$(_t "打标签失败" "Tagging failed")"; return 1; }
    git push origin "$(current_branch)" || warn "$(_t "推送失败" "Push failed")"
    git push origin "$tag" || warn "$(_t "推送标签失败" "Push tag failed")"

    if [[ "$HAS_GH" == "1" ]]; then
        gh release view "$tag" --repo "$REPO" &>/dev/null || \
            gh release create "$tag" --repo "$REPO" --title "Release $tag" --notes "$msg_en" 2>/dev/null || warn "$(_t "创建 Release 失败" "Failed to create Release")"
        gh release upload "$tag" "$so" --repo "$REPO" --clobber 2>/dev/null || warn "$(_t "上传资源失败" "Failed to upload asset")"
    fi

    ok "$(_t "发布完成" "Release completed"): $tag"
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
        ask "$(_t "通知ID" "Notification ID") [$(_t "默认" "default"): $sug]: "; read -r id
        [[ -z "$id" ]] && id="$sug"
    fi

    if [[ -z "$title_zh" ]]; then
        ask "$(_t "标题(中文)" "Title (Chinese)") [$(_t "默认" "default"): ${lt_zh:-$(_t "(无)" "(none)")}]: "; read -r title_zh
        [[ -z "$title_zh" ]] && title_zh="$lt_zh"
    fi
    if [[ -z "$title_en" ]]; then
        ask "$(_t "标题(英文)" "Title (English)") [$(_t "默认" "default"): ${lt_en:-$title_zh}]: "; read -r title_en
        [[ -z "$title_en" ]] && title_en="${lt_en:-$title_zh}"
    fi
    if [[ -z "$title_ru" ]]; then
        ask "$(_t "标题(俄文)" "Title (Russian)") [$(_t "默认" "default"): ${lt_ru:-$title_en}]: "; read -r title_ru
        [[ -z "$title_ru" ]] && title_ru="${lt_ru:-$title_en}"
    fi

    if [[ -z "$content_zh" ]]; then
        ask "$(_t "内容(中文)" "Content (Chinese)") [$(_t "默认" "default"): ${lc_zh:-$(_t "(无)" "(none)")}]: "; read -r content_zh
        [[ -z "$content_zh" ]] && content_zh="$lc_zh"
    fi
    if [[ -z "$content_en" ]]; then
        ask "$(_t "内容(英文)" "Content (English)") [$(_t "默认" "default"): ${lc_en:-$content_zh}]: "; read -r content_en
        [[ -z "$content_en" ]] && content_en="${lc_en:-$content_zh}"
    fi
    if [[ -z "$content_ru" ]]; then
        ask "$(_t "内容(俄文)" "Content (Russian)") [$(_t "默认" "default"): ${lc_ru:-$content_en}]: "; read -r content_ru
        [[ -z "$content_ru" ]] && content_ru="${lc_ru:-$content_en}"
    fi

    if [[ -z "$force" ]]; then
        ask "$(_t "强制显示" "Force show")? [y/N]: "; read -r f
        [[ "$f" =~ ^[Yy]$ ]] && force="true" || force="false"
    fi

    json_build_notify "$id" "$title_zh" "$title_en" "$title_ru" "$content_zh" "$content_en" "$content_ru" "$force"

    git add "$API_DIR/notify.json" 2>/dev/null || true
    git commit -m "notify: $id" 2>/dev/null || true
    git push origin "$(current_branch)" 2>/dev/null || warn "$(_t "推送失败" "Push failed")"
    ok "$(_t "通知已发布" "Notification published"): #$id"
}

cmd_clean() {
    local keep_tag="${1:-}"
    [[ -z "$keep_tag" && -f "$API_DIR/update.json" ]] && keep_tag="v$(json_get "$API_DIR/update.json" "versionCode")"
    [[ -z "$keep_tag" || "$keep_tag" == "v" ]] && keep_tag=$(git tag --sort=-version:refname 2>/dev/null | grep -E '^v[0-9]+$' | head -1) || true
    [[ -z "$keep_tag" ]] && { ask "$(_t "保留标签" "Keep tag") (如 v100): "; read -r keep_tag; }
    clean_old "$keep_tag"
}

# ---------- 菜单 ----------
show_menu() {
    while true; do
        echo ""
        log "$(_t "GitHub Backend Manager v4.1" "GitHub Backend Manager v4.1")"
        data "$(_t "仓库" "Repo"): $REPO  |  $(_t "分支" "Branch"): $(current_branch)"
        echo ""
        echo "  $(_t "[1] 发布新版本 (release)" "[1] Release new version")"
        echo "  $(_t "[2] 发布通知 (notify)" "[2] Publish notification")"
        echo "  $(_t "[3] 清理旧版本 (clean)" "[3] Clean old versions")"
        echo "  $(_t "[4] 查看状态 (status)" "[4] View status")"
        echo "  $(_t "[5] 初始化 (init)" "[5] Initialize")"
        echo "  $(_t "[0] 退出" "[0] Exit")"
        echo ""
        ask "$(_t "请选择" "Please select") [0-5]: "
        local c; read -r c
        echo ""
        case "$c" in
            1) cmd_release ;;
            2) cmd_notify ;;
            3) cmd_clean ;;
            4) cmd_status ;;
            5) cmd_init ;;
            0|q) log "$(_t "再见!" "Goodbye!")"; break ;;
            *) warn "$(_t "无效选择" "Invalid choice")" ;;
        esac
        echo ""
        read -rp "$(_t "按 Enter 继续..." "Press Enter to continue...")"
    done
}

usage() {
    if [[ "$LANG_IS_EN" -eq 1 ]]; then
        cat <<'EOF'
GitHub Backend Manager v4.1 (minimal)

Usage:
    bash manage.sh              Interactive menu
    bash manage.sh <command> [args...]

Commands:
    init                Initialize environment
    status              Show status
    release [v] [so] [msg_zh] [msg_en] [msg_ru] [force]
                        Publish a new version
    notify [id] [title_zh] [title_en] [title_ru]
           [content_zh] [content_en] [content_ru] [force]
                        Publish a notification
    clean [tag]         Clean old versions

Options:
    -y                  Auto confirm
    -v                  Verbose output
    -h                  Show this help
EOF
    else
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
    fi
}

parse_opts() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -y) FORCE_YES=1; shift ;;
            -v) VERBOSE=1; shift ;;
            -h|--help) usage; exit 0 ;;
            --) shift; break ;;
            -*) warn "$(_t "未知选项" "Unknown option"): $1"; shift ;;
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
        *)          error "$(_t "未知命令" "Unknown command"): $CMD"; usage ;;
    esac
}

main "$@"