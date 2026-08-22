#!/bin/bash
# ==============================================================================
# GitHub Backend Manager - Termux 专用版 (优化版 v3.0)
# 优化: 安全性加固、稳定性增强、错误处理完善、JSON安全构建
# ==============================================================================

set -euo pipefail
IFS=$'\n\t'

# ---------- 严格模式与信号处理 ----------
__cleanup() {
    local rc=$?
    [[ -n "${__TMPDIR:-}" && -d "$__TMPDIR" ]] && rm -rf "$__TMPDIR"
    exit $rc
}
__TMPDIR=""
trap '__cleanup' EXIT

trap 'error "接收到中断信号，正在退出..."; exit 130' INT TERM

# ---------- 颜色配置 ----------
if [[ -t 1 ]]; then
    C_RED='\033[0;31m'; C_GREEN='\033[0;32m'
    C_YELLOW='\033[1;33m'; C_BLUE='\033[0;34m'
    C_CYAN='\033[0;36m'; C_GRAY='\033[0;90m'
    C_RESET='\033[0m'; C_BOLD='\033[1m'
else
    C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''
    C_CYAN=''; C_GRAY=''; C_RESET=''; C_BOLD=''
fi

# ---------- 基础配置 ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="comlirong/project-backend"
API_DIR="api/v1"
BACKUP_DIR=".api_backups"
LOG_FILE="$SCRIPT_DIR/.manage.log"
DEFAULT_BRANCH="main"
MIN_OS_VERSION="21"
KEEP_RELEASES="0"
AUTO_CLEAN="true"

# 运行时状态
DRY_RUN=0
VERBOSE=0
FORCE_YES=0
HAS_JQ=0
HAS_GH=0
SHA_CMD=""

# ---------- 安全工具函数 ----------
# 验证字符串是否为有效整数
_is_int() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

# 验证路径是否为常规文件且在允许范围内（防止路径遍历）
_validate_file_path() {
    local path="$1"
    [[ -z "$path" ]] && return 1
    # 拒绝包含 .. 的路径
    [[ "$path" == *".."* ]] && { error "路径包含非法字符: $path"; return 1; }
    [[ -f "$path" ]] || { error "文件不存在: $path"; return 1; }
    return 0
}

# 安全执行命令，支持 dry-run
_safe_exec() {
    if [[ "$DRY_RUN" == "1" ]]; then
        info "[DRY-RUN] $*"
        return 0
    fi
    "$@"
}

# ---------- 日志系统 ----------
_log_write() {
    local level="$1"; shift
    local msg="$*"
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    # 避免日志文件过大（>10MB 时轮转）
    if [[ -f "$LOG_FILE" ]]; then
        local size
        size=$(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
        if [[ "$size" -gt 10485760 ]]; then
            mv "$LOG_FILE" "$LOG_FILE.old"
        fi
    fi
    echo "[$ts] [$level] $msg" >> "$LOG_FILE" 2>/dev/null || true
}

log()   { echo -e "${C_BLUE}[*]${C_RESET} $*"; _log_write "INFO" "$*"; }
ok()    { echo -e "${C_GREEN}[OK]${C_RESET} $*"; _log_write "OK" "$*"; }
warn()  { echo -e "${C_YELLOW}[!]${C_RESET} $*" >&2; _log_write "WARN" "$*"; }
error() { echo -e "${C_RED}[ERR]${C_RESET} $*" >&2; _log_write "ERROR" "$*"; }
info()  { echo -e " ${C_CYAN}->${C_RESET} $*"; _log_write "INFO" "$*"; }
data()  { echo -e "    ${C_GRAY}$*${C_RESET}"; }
debug() { [[ "$VERBOSE" == "1" ]] && echo -e "    ${C_GRAY}. $*${C_RESET}" >&2 || true; }
ask()   { echo -ne "${C_BOLD}[?]${C_RESET} $* "; }

# ---------- 配置加载（安全版） ----------
load_env() {
    local env_file="$SCRIPT_DIR/.env"
    [[ -f "$env_file" ]] || return 0
    # 安全 source：仅允许 KEY=VALUE 格式，拒绝命令替换和函数定义
    local line key val
    while IFS= read -r line || [[ -n "$line" ]]; do
        # 跳过空行和注释
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        # 仅接受 VAR=value 格式（字母数字下划线开头）
        if [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*=.*$ ]]; then
            key="${line%%=*}"
            val="${line#*=}"
            # 去除可能的引号
            val="${val#\"}"; val="${val%\"}"
            val="${val#\'}"; val="${val%\'}"
            # 仅设置白名单变量
            case "$key" in
                REPO|KEEP_RELEASES|AUTO_CLEAN|DEFAULT_BRANCH|MIN_OS_VERSION)
                    declare -g "$key=$val"
                    ;;
                *) debug "忽略非白名单变量: $key" ;;
            esac
        else
            warn ".env 中存在非标准行，已跳过: $line"
        fi
    done < "$env_file"
}

# ---------- 工具检测 ----------
detect_sha() {
    if command -v sha256sum &>/dev/null; then
        echo "sha256sum"
    elif command -v shasum &>/dev/null; then
        echo "shasum -a 256"
    else
        echo ""
    fi
}

detect_jq() {
    command -v jq &>/dev/null && echo "1" || echo "0"
}

# ---------- 依赖检查 ----------
check_deps() {
    echo ""
    log "检查环境..."

    if command -v gh &>/dev/null; then
        HAS_GH=1
        ok "gh CLI 已安装"
    else
        HAS_GH=0
        warn "未找到 gh CLI，部分功能不可用"
    fi

    if ! git rev-parse --git-dir &>/dev/null; then
        warn "当前目录不是 git 仓库"
    else
        ok "git 仓库检测通过"
    fi

    HAS_JQ=$(detect_jq)
    SHA_CMD=$(detect_sha)

    [[ "$HAS_JQ" == "1" ]] && ok "jq 可用 (v$(jq --version 2>/dev/null | sed 's/jq-//'))" || warn "jq 未安装，JSON 功能受限"
    [[ -n "$SHA_CMD" ]] && ok "SHA 工具: ${SHA_CMD%% *}" || warn "未找到 sha256sum/shasum"

    mkdir -p "$API_DIR" "$BACKUP_DIR"
    ok "环境检查完成"
}

# ---------- 确认提示（支持非交互环境） ----------
confirm() {
    local msg="${1:-确认执行?}"
    [[ "$FORCE_YES" == "1" ]] && return 0
    # 非交互环境（无 tty）默认拒绝
    if [[ ! -t 0 ]]; then
        warn "非交互环境，默认拒绝操作: $msg"
        return 1
    fi
    local r
    ask "$msg [y/N]: "
    read -r r
    [[ "$r" =~ ^[Yy]$ ]]
}

# ---------- Git 操作封装（含错误处理） ----------
current_branch() {
    git branch --show-current 2>/dev/null || git symbolic-ref --short HEAD 2>/dev/null || echo "$DEFAULT_BRANCH"
}

_git_safe_checkout() {
    local branch="$1"
    if ! git show-ref --verify --quiet "refs/heads/$branch"; then
        error "本地分支不存在: $branch"
        return 1
    fi
    git checkout "$branch" || { error "切换分支失败: $branch"; return 1; }
}

git_sync() {
    local branch
    branch=$(current_branch)
    info "同步远程 origin/$branch..."

    if ! git fetch origin "$branch" 2>/dev/null && ! git fetch origin 2>/dev/null; then
        warn "fetch 失败，跳过同步"
        return 0
    fi

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

    # 尝试自动合并
    if git merge "origin/$branch" --no-edit -m "auto: sync remote" 2>/dev/null; then
        git push origin "$branch" || warn "推送失败"
        ok "已合并并推送"
        return 0
    fi

    warn "检测到冲突，尝试自动解决..."
    # 优先保留本地 API 文件
    git checkout --ours "$API_DIR/update.json" "$API_DIR/notify.json" 2>/dev/null || true
    git add "$API_DIR" 2>/dev/null || true
    git commit -m "auto: resolve conflicts" || true
    git push origin "$branch" || warn "推送失败"
    ok "冲突已解决"
}

# ---------- JSON 处理（安全增强版） ----------
json_get() {
    local file="$1" key="$2"
    [[ -f "$file" ]] || { echo ""; return; }
    if [[ "$HAS_JQ" == "1" ]]; then
        jq -r ".$key // empty" "$file" 2>/dev/null || echo ""
        return
    fi
    # 纯 Bash 回退：更安全地提取值
    grep -oP "\"$key\"\s*:\s*(\"[^\"]*\"|[0-9]+|true|false)" "$file" 2>/dev/null | head -1 | sed 's/.*:\s*//; s/^"//; s/"$//'
}

json_get_lang() {
    local file="$1" key="$2" lang="$3"
    [[ -f "$file" ]] || { echo ""; return; }
    if [[ "$HAS_JQ" == "1" ]]; then
        jq -r ".$key.$lang // empty" "$file" 2>/dev/null || echo ""
        return
    fi
    # Python 回退：使用安全方式传递参数
    python3 -c "import json,sys; f=open(sys.argv[1]); d=json.load(f); f.close(); print(d.get(sys.argv[2],{}).get(sys.argv[3],''))" "$file" "$key" "$lang" 2>/dev/null || echo ""
}

json_validate() {
    local file="$1"
    [[ -f "$file" ]] || { error "文件不存在: $file"; return 1; }

    if [[ "$HAS_JQ" == "1" ]]; then
        jq empty "$file" 2>/dev/null && return 0
    elif command -v python3 &>/dev/null; then
        python3 -c "import json; f=open(sys.argv[1]); json.load(f); f.close()" "$file" 2>/dev/null && return 0
    fi

    local open close
    open=$(grep -o '{' "$file" | wc -l)
    close=$(grep -o '}' "$file" | wc -l)
    [[ "$open" -eq "$close" ]] || { error "JSON括号不匹配: $file"; return 1; }

    warn "无法精确验证JSON，请手动检查: $file"
    return 0
}

# 安全构建 JSON：使用 jq 或 Python，避免字符串拼接注入
json_build_update() {
    local vc="$1" url="$2" msg_zh="$3" msg_en="$4" msg_ru="$5" force="$6" sha="$7"
    local out="$API_DIR/update.json"

    if [[ "$HAS_JQ" == "1" ]]; then
        jq -n \
            --argjson versionCode "$vc" \
            --arg url "$url" \
            --arg zh "$msg_zh" \
            --arg en "$msg_en" \
            --arg ru "$msg_ru" \
            --argjson force "$force" \
            --arg sha256 "$sha" \
            --argjson minOsVersion "$MIN_OS_VERSION" \
            '{versionCode: $versionCode, url: $url, message: {zh: $zh, en: $en, ru: $ru}, force: $force, sha256: $sha256, minOsVersion: $minOsVersion}' > "$out"
    else
        python3 -c "
import json, sys
vc, url, zh, en, ru, force, sha, minos = sys.argv[1:]
data = {
    'versionCode': int(vc),
    'url': url,
    'message': {'zh': zh, 'en': en, 'ru': ru},
    'force': force.lower() == 'true',
    'sha256': sha,
    'minOsVersion': int(minos)
}
with open(sys.argv[9], 'w') as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
    f.write('\n')
" "$vc" "$url" "$msg_zh" "$msg_en" "$msg_ru" "$force" "$sha" "$MIN_OS_VERSION" "$out"
    fi
}

json_build_notify() {
    local id="$1" title_zh="$2" title_en="$3" title_ru="$4" content_zh="$5" content_en="$6" content_ru="$7" force="$8"
    local out="$API_DIR/notify.json"

    if [[ "$HAS_JQ" == "1" ]]; then
        jq -n \
            --arg id "$id" \
            --arg zh_t "$title_zh" --arg en_t "$title_en" --arg ru_t "$title_ru" \
            --arg zh_c "$content_zh" --arg en_c "$content_en" --arg ru_c "$content_ru" \
            --argjson force "$force" \
            --arg createdAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            '{id: $id, title: {zh: $zh_t, en: $en_t, ru: $ru_t}, content: {zh: $zh_c, en: $en_c, ru: $ru_c}, force: $force, createdAt: $createdAt}' > "$out"
    else
        python3 -c "
import json, sys
id_, tzh, ten, tru, czh, cen, cru, force = sys.argv[1:9]
data = {
    'id': id_,
    'title': {'zh': tzh, 'en': ten, 'ru': tru},
    'content': {'zh': czh, 'en': cen, 'ru': cru},
    'force': force.lower() == 'true',
    'createdAt': __import__('datetime').datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')
}
with open(sys.argv[9], 'w') as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
    f.write('\n')
" "$id" "$title_zh" "$title_en" "$title_ru" "$content_zh" "$content_en" "$content_ru" "$force" "$out"
    fi
}

# ---------- 备份（增强版） ----------
backup_create() {
    local reason="${1:-manual}"
    local ts
    ts=$(date +%Y%m%d_%H%M%S)
    # 清理 reason 中的特殊字符
    reason="${reason//[^a-zA-Z0-9_-]/_}"
    local path="$BACKUP_DIR/backup_${ts}_${reason}"
    mkdir -p "$path"
    local copied=0
    for f in update.json notify.json notify_history.json; do
        if [[ -f "$API_DIR/$f" ]]; then
            cp "$API_DIR/$f" "$path/$f"
            copied=$((copied + 1))
        fi
    done
    if [[ "$copied" -gt 0 ]]; then
        echo "$path"
        return 0
    fi
    rmdir "$path" 2>/dev/null || true
    return 1
}

backup_list() {
    [[ -d "$BACKUP_DIR" ]] || { warn "无备份目录"; return; }
    info "备份列表:"
    local count=0
    for b in "$BACKUP_DIR"/backup_*; do
        [[ -d "$b" ]] || continue
        count=$((count + 1))
        local size
        size=$(du -sh "$b" 2>/dev/null | cut -f1)
        local name
        name=$(basename "$b")
        data "$name ($size)"
    done
    [[ "$count" -eq 0 ]] && data "(无备份)"
}

# ---------- 版本推断 ----------
suggest_version() {
    local current=""
    if [[ -f "$API_DIR/update.json" ]]; then
        current=$(json_get "$API_DIR/update.json" "versionCode")
    fi
    if [[ -z "$current" ]]; then
        current=$(git tag --sort=-version:refname 2>/dev/null | grep -E '^v[0-9]+$' | head -1 | sed 's/^v//') || true
    fi
    if [[ -n "$current" && "$current" =~ ^[0-9]+$ ]]; then
        echo $((current + 1))
    else
        echo "1"
    fi
}

suggest_notify_id() {
    local last=""
    [[ -f "$API_DIR/notify.json" ]] && last=$(json_get "$API_DIR/notify.json" "id")
    [[ -z "$last" ]] && { echo "001"; return; }
    # 去除前导零后递增
    local num
    num=$(echo "$last" | sed 's/^0*//')
    [[ -z "$num" ]] && num=0
    printf "%03d" $((num + 1))
}

# ---------- 查找 so 文件（修复空值与空格问题） ----------
find_so() {
    local dirs=("." "build" "libs" "jniLibs" "src/main/jniLibs" "app/build/intermediates/merged_native_libs")
    local found=()
    for d in "${dirs[@]}"; do
        [[ -d "$d" ]] || continue
        while IFS= read -r -d '' f; do
            found+=("$f")
        done < <(find "$d" -maxdepth 3 -name "*.so" -type f -print0 2>/dev/null)
    done
    if [[ ${#found[@]} -eq 0 ]]; then
        return 0
    fi
    printf '%s\0' "${found[@]}" | sort -uz | tr '\0' '\n'
}

# ---------- 清理旧版本（增强错误处理） ----------
clean_old() {
    local keep_tag="${1:-}"
    local keep="$KEEP_RELEASES"

    info "获取远程标签..."
    local tags
    tags=$(git ls-remote --tags origin 'refs/tags/v*' 2>/dev/null | awk '{print $2}' | sed 's|refs/tags/||' | grep -E '^v[0-9]+$' | sort -Vr) || true
    [[ -z "$tags" ]] && { warn "无远程标签"; return; }

    local tags_to_delete=()
    local count=0
    while IFS= read -r tag; do
        [[ -z "$tag" || "$tag" == "$keep_tag" ]] && continue
        count=$((count + 1))
        if [[ "$keep" -gt 0 && "$count" -le "$keep" ]]; then
            ok "保留: $tag"
            continue
        fi
        tags_to_delete+=("$tag")
    done <<< "$tags"

    [[ ${#tags_to_delete[@]} -eq 0 ]] && { ok "无需清理"; return; }

    info "将删除 ${#tags_to_delete[@]} 个版本:"
    for tag in "${tags_to_delete[@]}"; do
        data "$tag"
    done
    echo ""
    confirm "确认删除" || { ok "已取消"; return; }

    for tag in "${tags_to_delete[@]}"; do
        if [[ "$HAS_GH" == "1" ]]; then
            if gh release view "$tag" --repo "$REPO" &>/dev/null; then
                if gh release delete "$tag" --repo "$REPO" --yes 2>/dev/null; then
                    ok "删除 release: $tag"
                else
                    warn "release 删除失败: $tag"
                fi
            fi
        fi
        if git push origin ":refs/tags/$tag" 2>/dev/null; then
            ok "删除 tag: $tag"
        else
            warn "tag 删除失败: $tag"
        fi
    done
}

# ==============================================================================
# 命令实现
# ==============================================================================

# ---------- 命令: init ----------
cmd_init() {
    log "初始化项目..."
    mkdir -p "$API_DIR" "$BACKUP_DIR"

    if [[ ! -f "$API_DIR/update.json" ]]; then
        cat > "$API_DIR/update.json" <<'EOF'
{
  "versionCode": 0,
  "url": "",
  "message": {
    "zh": "",
    "en": "",
    "ru": ""
  },
  "force": false,
  "sha256": "",
  "minOsVersion": 21
}
EOF
        ok "已创建 update.json"
    fi

    if [[ ! -f "$API_DIR/notify.json" ]]; then
        cat > "$API_DIR/notify.json" <<'EOF'
{
  "id": "000",
  "title": {
    "zh": "",
    "en": "",
    "ru": ""
  },
  "content": {
    "zh": "",
    "en": "",
    "ru": ""
  },
  "force": false,
  "createdAt": ""
}
EOF
        ok "已创建 notify.json"
    fi

    [[ -f "$API_DIR/notify_history.json" ]] || echo '[]' > "$API_DIR/notify_history.json"

    if [[ ! -f "$SCRIPT_DIR/.env" ]]; then
        cat > "$SCRIPT_DIR/.env" <<'EOF'
# GitHub Backend 配置
# REPO=comlirong/project-backend
# KEEP_RELEASES=3
# AUTO_CLEAN=true
EOF
        ok "已创建 .env 模板"
    fi
    ok "初始化完成"
}

# ---------- 命令: status ----------
cmd_status() {
    log "项目状态"
    data "仓库: $REPO"
    data "分支: $(current_branch)"
    data "API目录: $API_DIR"

    if [[ -f "$API_DIR/update.json" ]]; then
        echo ""
        info "update.json:"
        data "  版本: $(json_get "$API_DIR/update.json" "versionCode")"
        data "  URL: $(json_get "$API_DIR/update.json" "url")"
        data "  强制: $(json_get "$API_DIR/update.json" "force")"
        data "  说明(zh): $(json_get_lang "$API_DIR/update.json" "message" "zh")"
    fi
    if [[ -f "$API_DIR/notify.json" ]]; then
        echo ""
        info "notify.json:"
        data "  ID: #$(json_get "$API_DIR/notify.json" "id")"
        data "  强制: $(json_get "$API_DIR/notify.json" "force")"
        data "  标题(zh): $(json_get_lang "$API_DIR/notify.json" "title" "zh")"
        data "  内容(zh): $(json_get_lang "$API_DIR/notify.json" "content" "zh")"
    fi
    echo ""
    data "Git提交: $(git rev-parse --short HEAD 2>/dev/null || echo 'N/A')"
    data "远程标签: $(git ls-remote --tags origin 2>/dev/null | wc -l | tr -d ' ') 个"
    data "备份数: $(find "$BACKUP_DIR" -maxdepth 1 -type d -name 'backup_*' 2>/dev/null | wc -l | tr -d ' ') 个"
}

# ---------- 命令: release (安全增强版) ----------
cmd_release() {
    local vc="${1:-}"
    local so="${2:-}"
    local msg_zh="${3:-}"
    local msg_en="${4:-}"
    local msg_ru="${5:-}"
    local force="${6:-}"

    # 预读取现有JSON中的各语言值
    local last_zh="" last_en="" last_ru=""
    if [[ -f "$API_DIR/update.json" ]]; then
        last_zh=$(json_get_lang "$API_DIR/update.json" "message" "zh")
        last_en=$(json_get_lang "$API_DIR/update.json" "message" "en")
        last_ru=$(json_get_lang "$API_DIR/update.json" "message" "ru")
    fi

    if [[ -z "$vc" ]]; then
        local sug
        sug=$(suggest_version)
        ask "版本号 [默认: $sug]: "
        read -r vc
        [[ -z "$vc" ]] && vc="$sug"
    fi
    _is_int "$vc" || { error "版本号必须是整数"; return 1; }

    if [[ -z "$so" ]]; then
        local so_files
        so_files=$(find_so)
        local count=0
        if [[ -n "$so_files" ]]; then
            count=$(printf '%s\n' "$so_files" | grep -c '^' || echo 0)
        fi
        if [[ "$count" -eq 1 ]]; then
            so="$so_files"
            info "自动发现 so: $so"
        elif [[ "$count" -gt 1 ]]; then
            info "发现 $count 个 so 文件:"
            local i=1
            local -a files=()
            while IFS= read -r f; do
                [[ -n "$f" ]] || continue
                data "$i) $f ($(du -h "$f" 2>/dev/null | cut -f1))"
                files+=("$f")
                i=$((i+1))
            done <<< "$so_files"
            data "0) 手动输入路径"
            ask "选择 [0-$((i-1))]: "
            local choice
            read -r choice
            if [[ "$choice" == "0" ]]; then
                ask "so 文件路径: "
                read -r so
            elif _is_int "$choice" && [[ "$choice" -ge 1 && "$choice" -lt "$i" ]]; then
                so="${files[$((choice-1))]}"
            else
                error "无效选择"
                return 1
            fi
        else
            ask "so 文件路径: "
            read -r so
        fi
    fi
    _validate_file_path "$so" || return 1

    # 多语言默认值优先读取JSON中对应语言的现有值
    if [[ -z "$msg_zh" ]]; then
        ask "更新说明(中文) [默认: ${last_zh:-版本更新}]: "
        read -r msg_zh
        [[ -z "$msg_zh" ]] && msg_zh="${last_zh:-版本更新}"
    fi
    if [[ -z "$msg_en" ]]; then
        ask "更新说明(英文) [默认: ${last_en:-$msg_zh}]: "
        read -r msg_en
        [[ -z "$msg_en" ]] && msg_en="${last_en:-$msg_zh}"
    fi
    if [[ -z "$msg_ru" ]]; then
        ask "更新说明(俄文) [默认: ${last_ru:-$msg_en}]: "
        read -r msg_ru
        [[ -z "$msg_ru" ]] && msg_ru="${last_ru:-$msg_en}"
    fi

    if [[ -z "$force" ]]; then
        ask "强制更新? [y/N]: "
        local f
        read -r f
        [[ "$f" =~ ^[Yy]$ ]] && force="true" || force="false"
    fi

    local tag="v$vc"
    local so_name
    so_name=$(basename "$so")
    # 验证 so_name 不包含路径分隔符
    [[ "$so_name" == *"/"* ]] && { error "文件名非法: $so_name"; return 1; }

    local url="https://github.com/$REPO/releases/download/$tag/$so_name"
    local sha
    sha=$($SHA_CMD "$so" | awk '{print $1}')
    [[ -z "$sha" ]] && { error "SHA256 计算失败"; return 1; }

    echo ""
    info "发布预览:"
    data "版本: $tag"
    data "文件: $so ($(du -h "$so" | cut -f1))"
    data "SHA256: $sha"
    data "说明(zh): $msg_zh"
    data "说明(en): $msg_en"
    data "说明(ru): $msg_ru"
    data "强制: $force"
    echo ""
    confirm "确认发布" || { ok "已取消"; return 0; }

    # 自动备份
    local backup_path
    backup_path=$(backup_create "pre_$tag") || true
    [[ -n "${backup_path:-}" ]] && debug "已备份到: $backup_path"

    # Git 操作前确保工作区干净（或自动提交）
    if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
        info "检测到未提交更改，自动提交..."
        git add . 2>/dev/null || true
        git commit -m "auto: sync before release $tag" 2>/dev/null || true
    fi
    git_sync

    json_build_update "$vc" "$url" "$msg_zh" "$msg_en" "$msg_ru" "$force" "$sha"

    git add "$API_DIR/update.json"
    git commit -m "release: $tag" || true

    if ! git tag -a "$tag" -m "release $tag"; then
        error "打标签失败"
        return 1
    fi

    git push origin "$(current_branch)" || warn "推送失败"
    git push origin "$tag" || warn "推送标签失败"

    if [[ "$HAS_GH" == "1" ]]; then
        if gh release view "$tag" --repo "$REPO" &>/dev/null; then
            warn "Release $tag 已存在，尝试上传资源"
        else
            gh release create "$tag" --repo "$REPO" --title "Release $tag" --notes "$msg_en" || warn "创建 Release 失败"
        fi
        gh release upload "$tag" "$so" --repo "$REPO" --clobber || warn "上传资源失败"
    else
        warn "gh CLI 不可用，跳过 Release 创建"
    fi

    ok "发布完成: $tag"

    [[ "$AUTO_CLEAN" == "true" ]] && clean_old "$tag"
}

# ---------- 命令: notify (安全增强版) ----------
cmd_notify() {
    local id="${1:-}"
    local title_zh="${2:-}"
    local title_en="${3:-}"
    local title_ru="${4:-}"
    local content_zh="${5:-}"
    local content_en="${6:-}"
    local content_ru="${7:-}"
    local force="${8:-}"

    # 预读取现有JSON中的各语言值
    local last_t_zh="" last_t_en="" last_t_ru=""
    local last_c_zh="" last_c_en="" last_c_ru=""
    if [[ -f "$API_DIR/notify.json" ]]; then
        last_t_zh=$(json_get_lang "$API_DIR/notify.json" "title" "zh")
        last_t_en=$(json_get_lang "$API_DIR/notify.json" "title" "en")
        last_t_ru=$(json_get_lang "$API_DIR/notify.json" "title" "ru")
        last_c_zh=$(json_get_lang "$API_DIR/notify.json" "content" "zh")
        last_c_en=$(json_get_lang "$API_DIR/notify.json" "content" "en")
        last_c_ru=$(json_get_lang "$API_DIR/notify.json" "content" "ru")
    fi

    if [[ -z "$id" ]]; then
        local sug
        sug=$(suggest_notify_id)
        ask "通知ID [默认: $sug]: "
        read -r id
        [[ -z "$id" ]] && id="$sug"
    fi

    # 标题各语言默认值
    if [[ -z "$title_zh" ]]; then
        ask "通知标题(中文) [默认: ${last_t_zh:-(无)}]: "
        read -r title_zh
        [[ -z "$title_zh" ]] && title_zh="$last_t_zh"
    fi
    if [[ -z "$title_en" ]]; then
        ask "通知标题(英文) [默认: ${last_t_en:-$title_zh}]: "
        read -r title_en
        [[ -z "$title_en" ]] && title_en="${last_t_en:-$title_zh}"
    fi
    if [[ -z "$title_ru" ]]; then
        ask "通知标题(俄文) [默认: ${last_t_ru:-$title_en}]: "
        read -r title_ru
        [[ -z "$title_ru" ]] && title_ru="${last_t_ru:-$title_en}"
    fi

    # 内容各语言默认值
    if [[ -z "$content_zh" ]]; then
        ask "通知内容(中文) [默认: ${last_c_zh:-(无)}]: "
        read -r content_zh
        [[ -z "$content_zh" ]] && content_zh="$last_c_zh"
    fi
    if [[ -z "$content_en" ]]; then
        ask "通知内容(英文) [默认: ${last_c_en:-$content_zh}]: "
        read -r content_en
        [[ -z "$content_en" ]] && content_en="${last_c_en:-$content_zh}"
    fi
    if [[ -z "$content_ru" ]]; then
        ask "通知内容(俄文) [默认: ${last_c_ru:-$content_en}]: "
        read -r content_ru
        [[ -z "$content_ru" ]] && content_ru="${last_c_ru:-$content_en}"
    fi

    if [[ -z "$force" ]]; then
        ask "强制显示? [y/N]: "
        local f
        read -r f
        [[ "$f" =~ ^[Yy]$ ]] && force="true" || force="false"
    fi

    json_build_notify "$id" "$title_zh" "$title_en" "$title_ru" "$content_zh" "$content_en" "$content_ru" "$force"

    git add "$API_DIR/notify.json" 2>/dev/null || true
    git commit -m "notify: $id" 2>/dev/null || true
    git push origin "$(current_branch)" 2>/dev/null || warn "推送失败"

    ok "通知已发布: #$id"
}

# ---------- 命令: clean ----------
cmd_clean() {
    local keep_tag="${1:-}"
    if [[ -z "$keep_tag" ]]; then
        [[ -f "$API_DIR/update.json" ]] && keep_tag="v$(json_get "$API_DIR/update.json" "versionCode")"
        [[ -z "$keep_tag" || "$keep_tag" == "v" ]] && keep_tag=$(git tag --sort=-version:refname 2>/dev/null | grep -E '^v[0-9]+$' | head -1) || true
        [[ -z "$keep_tag" ]] && { ask "保留的版本标签 (如 v100): "; read -r keep_tag; }
    fi
    clean_old "$keep_tag"
}

# ---------- 命令: backup ----------
cmd_backup() {
    local action="${1:-list}"
    case "$action" in
        list)   backup_list ;;
        create) 
            local path
            path=$(backup_create "${2:-manual}")
            [[ $? -eq 0 ]] && ok "备份创建: $(basename "$path")" || warn "备份创建失败"
            ;;
        restore)
            local name="$2"
            [[ -z "$name" ]] && { ask "备份名称: "; read -r name; }
            local path="$BACKUP_DIR/$name"
            [[ -d "$path" ]] || { error "备份不存在: $path"; return 1; }
            for f in update.json notify.json notify_history.json; do
                [[ -f "$path/$f" ]] && cp "$path/$f" "$API_DIR/$f"
            done
            ok "已恢复: $name"
            ;;
        *) error "未知操作: $action (list/create/restore)" ;;
    esac
}

# ==============================================================================
# 本地文件一键上传功能（安全增强）
# ==============================================================================

cmd_upload() {
    local src_update="${1:-}"
    local src_notify="${2:-}"
    local mode="${3:-both}"

    log "本地文件上传模式"
    info "支持直接上传本地编辑好的 update.json / notify.json"
    echo ""

    local candidates=()
    [[ -f "$API_DIR/update.json" ]] && candidates+=("$API_DIR/update.json")
    [[ -f "$API_DIR/notify.json" ]] && candidates+=("$API_DIR/notify.json")
    [[ -f "./update.json" ]] && candidates+=("./update.json")
    [[ -f "./notify.json" ]] && candidates+=("./notify.json")

    if [[ -n "$src_update" || -n "$src_notify" ]]; then
        info "使用命令行指定的文件路径"
        if [[ -n "$src_update" ]]; then
            _validate_file_path "$src_update" || return 1
        fi
        if [[ -n "$src_notify" ]]; then
            _validate_file_path "$src_notify" || return 1
        fi

        [[ "$mode" == "both" || "$mode" == "update" ]] && cp "$src_update" "$API_DIR/update.json"
        [[ "$mode" == "both" || "$mode" == "notify" ]] && cp "$src_notify" "$API_DIR/notify.json"

    else
        info "发现以下候选文件:"
        local i=1
        local -a files=()
        for f in "${candidates[@]}"; do
            [[ -f "$f" ]] || continue
            local size
            size=$(du -h "$f" 2>/dev/null | cut -f1)
            data "$i) $f ($size)"
            files+=("$f")
            i=$((i+1))
        done
        data "0) 手动输入路径"
        echo ""

        ask "选择 update.json 来源 [1-$((i-1)) 或 0]: "
        local u_choice
        read -r u_choice

        local update_src=""
        if [[ "$u_choice" == "0" ]]; then
            ask "输入 update.json 完整路径: "
            read -r update_src
        elif _is_int "$u_choice" && [[ "$u_choice" -ge 1 && "$u_choice" -lt "$i" ]]; then
            update_src="${files[$((u_choice-1))]:-}"
        else
            error "无效选择"
            return 1
        fi

        _validate_file_path "$update_src" || return 1

        echo ""
        ask "是否同时上传 notify.json? [Y/n]: "
        local also_notify
        read -r also_notify
        also_notify=${also_notify:-Y}

        local notify_src=""
        if [[ "$also_notify" =~ ^[Yy]$ ]]; then
            ask "选择 notify.json 来源 [1-$((i-1)) 或 0]: "
            local n_choice
            read -r n_choice

            if [[ "$n_choice" == "0" ]]; then
                ask "输入 notify.json 完整路径: "
                read -r notify_src
            elif _is_int "$n_choice" && [[ "$n_choice" -ge 1 && "$n_choice" -lt "$i" ]]; then
                notify_src="${files[$((n_choice-1))]:-}"
            else
                error "无效选择"
                return 1
            fi
            [[ -n "$notify_src" ]] && _validate_file_path "$notify_src" || return 1
        fi

        src_update="$update_src"
        src_notify="$notify_src"
    fi

    echo ""
    log "验证文件格式..."
    json_validate "$src_update" || return 1
    [[ -n "$src_notify" ]] && { json_validate "$src_notify" || return 1; }
    ok "JSON 格式验证通过"

    echo ""
    info "文件预览:"
    data "update.json -> $(json_get "$src_update" "versionCode") | $(json_get_lang "$src_update" "message" "zh")"
    [[ -n "$src_notify" ]] && data "notify.json -> #$(json_get "$src_notify" "id") | $(json_get_lang "$src_notify" "title" "zh")"

    echo ""
    local backup_path
    backup_path=$(backup_create "pre_upload") || true
    [[ -n "${backup_path:-}" ]] && info "已备份到: $(basename "$backup_path")"

    echo ""
    confirm "确认上传并推送" || { ok "已取消"; return 0; }

    cp "$src_update" "$API_DIR/update.json"
    [[ -n "$src_notify" ]] && cp "$src_notify" "$API_DIR/notify.json"

    git add "$API_DIR/update.json" 2>/dev/null || true
    [[ -n "$src_notify" ]] && git add "$API_DIR/notify.json" 2>/dev/null || true

    local commit_msg="upload: sync json files"
    [[ -n "$src_notify" ]] || commit_msg="upload: sync update.json"

    git commit -m "$commit_msg" 2>/dev/null || true
    git push origin "$(current_branch)" 2>/dev/null || warn "推送失败"

    ok "上传完成!"
    info "文件已同步到: $API_DIR/"

    if [[ "$AUTO_CLEAN" == "true" ]]; then
        local current_tag
        current_tag="v$(json_get "$API_DIR/update.json" "versionCode")"
        [[ "$current_tag" != "v" ]] && clean_old "$current_tag"
    fi
}

# ---------- 命令: sync ----------
cmd_sync() {
    log "从远程同步 JSON 文件..."
    git fetch origin "$(current_branch)" 2>/dev/null || { warn "fetch 失败"; return 1; }

    local changed=0
    for f in update.json notify.json; do
        if git diff "origin/$(current_branch)" -- "$API_DIR/$f" &>/dev/null; then
            git checkout "origin/$(current_branch)" -- "$API_DIR/$f" 2>/dev/null && {
                ok "已同步: $f"
                changed=1
            } || warn "同步失败: $f"
        fi
    done

    [[ "$changed" -eq 1 ]] && ok "同步完成" || info "本地已是最新"
}

# ---------- 命令: diff ----------
cmd_diff() {
    log "对比本地与远程差异..."
    git fetch origin "$(current_branch)" 2>/dev/null || { warn "fetch 失败"; return 1; }

    for f in update.json notify.json; do
        local path="$API_DIR/$f"
        [[ -f "$path" ]] || continue
        echo ""
        info "$f 差异:"
        git diff "origin/$(current_branch)" -- "$path" 2>/dev/null || data "(无差异或文件仅在本地存在)"
    done
}

# ==============================================================================
# GitHub Pages 管理（安全增强）
# ==============================================================================
_pages_check_gh() {
    [[ "$HAS_GH" == "1" ]] && return 0
    error "需要 gh CLI 才能管理 GitHub Pages"
    info "安装: pkg install gh  或  apt install gh"
    return 1
}

_pages_info() {
    gh api "repos/$REPO/pages" --silent 2>/dev/null || true
}

_pages_status() {
    local info
    info=$(_pages_info)
    if [[ -z "$info" ]]; then
        warn "GitHub Pages 当前未启用或无法访问 (404)"
        return 1
    fi
    log "GitHub Pages 状态"
    if [[ "$HAS_JQ" == "1" ]]; then
        data "状态:     $(echo "$info" | jq -r '.status // "unknown"')"
        data "URL:      $(echo "$info" | jq -r '.html_url // "N/A"')"
        data "源分支:   $(echo "$info" | jq -r '.source.branch // "none"')"
        data "源路径:   $(echo "$info" | jq -r '.source.path // "/"')"
        data "CNAME:    $(echo "$info" | jq -r '.cname // "(无)"')"
        data "HTTPS:    $(echo "$info" | jq -r '.https_enforced // false')"
    else
        data "原始响应: $info"
    fi
    return 0
}

_pages_disable() {
    _pages_check_gh || return 1
    local owner repo
    owner=$(echo "$REPO" | cut -d/ -f1)
    repo=$(echo "$REPO" | cut -d/ -f2)

    log "关闭 GitHub Pages (DELETE /repos/$owner/$repo/pages)..."
    local resp
    resp=$(gh api --method DELETE -H "Accept: application/vnd.github+json" "/repos/$owner/$repo/pages" 2>&1) || true
    local rc=$?

    if [[ $rc -eq 0 ]]; then
        ok "GitHub Pages 已关闭 (站点资源已删除，仓库保留)"
    elif echo "$resp" | grep -q '"status":"404"'; then
        ok "Pages 站点本来就不存在，无需关闭"
    elif echo "$resp" | grep -q '"status":"409"'; then
        warn "冲突: 可能站点正在构建中，稍后重试"
        return 1
    elif echo "$resp" | grep -qi "Must have admin"; then
        error "权限不足: 当前账号需要仓库 Admin/Maintainer 权限"
        return 1
    else
        error "关闭失败 (rc=$rc): $resp"
        return 1
    fi
}

_pages_remove_branch() {
    local branch="${1:-gh-pages}"
    # 验证分支名合法性
    [[ "$branch" =~ ^[a-zA-Z0-9_.-]+$ ]] || { error "非法分支名: $branch"; return 1; }

    info "检查分支: $branch"
    local remote_exists=0
    git ls-remote --heads origin "$branch" 2>/dev/null | grep -q "$branch" && remote_exists=1

    if [[ "$remote_exists" -eq 0 ]]; then
        info "远程分支 $branch 不存在，跳过"
    else
        warn "将删除远程分支: $branch"
        confirm "确认删除远程分支 $branch" && {
            git push origin --delete "$branch" 2>&1 && ok "远程分支 $branch 已删除" || warn "删除远程分支失败"
        } || info "已跳过远程分支删除"
    fi

    if git show-ref --verify --quiet "refs/heads/$branch"; then
        warn "将删除本地分支: $branch"
        confirm "确认删除本地分支 $branch" && {
            git checkout "$(current_branch)" &>/dev/null || true
            git branch -D "$branch" 2>&1 && ok "本地分支 $branch 已删除" || warn "删除本地分支失败"
        }
    else
        info "本地分支 $branch 不存在，跳过"
    fi
}

_pages_clean_deployments() {
    info "获取 Pages 部署记录..."
    local deps
    deps=$(gh api "repos/$REPO/deployments?environment=github-pages&per_page=100" --jq '.[].id' 2>/dev/null || true)
    if [[ -z "$deps" ]]; then
        info "无 github-pages 部署记录"
        return 0
    fi

    local count
    count=$(echo "$deps" | grep -c '^' || echo 0)
    warn "发现 $count 条 github-pages 部署记录"

    local MAX_DEPS=200
    if [[ "$count" -gt "$MAX_DEPS" ]]; then
        warn "超过 $MAX_DEPS 条，仅处理前 $MAX_DEPS 条"
        deps=$(echo "$deps" | head -n "$MAX_DEPS")
        count=$MAX_DEPS
    fi

    confirm "确认全部标记为 inactive (实质清理)" || { info "已跳过"; return 0; }

    local i=0 total=$count CONCURRENCY=8
    info "正在并发标记 (并发=$CONCURRENCY, 总数=$total)..."

    while IFS= read -r dep_id; do
        [[ -z "$dep_id" ]] && continue
        i=$((i+1))
        echo -ne "\r  -> 处理中 $i/$total" >&2

        (
            gh api "repos/$REPO/deployments/$dep_id/statuses" --method POST --field state=inactive 2>/dev/null || true
        ) &

        while [[ $(jobs -r | wc -l) -ge $CONCURRENCY ]]; do
            sleep 0.2
        done
    done <<< "$deps"

    wait
    echo -e "\r  -> 处理完成             " >&2
    ok "部署记录处理完成 (共 $total 条)"
    info "提示: 设为 inactive 后，GitHub 会自动清理对应部署"
}

_pages_clean_files() {
    # 使用白名单模式，更安全
    local targets=("index.html" "404.html" "CNAME" "_config.yml")
    info "扫描工作区残留站点文件..."
    local found=()
    for t in "${targets[@]}"; do
        [[ -e "$t" ]] && found+=("$t")
    done
    if [[ -d "docs" ]]; then
        while IFS= read -r f; do
            found+=("$f")
        done < <(find docs -maxdepth 2 -type f \( -name "index.html" -o -name "CNAME" -o -name "_config.yml" \) 2>/dev/null)
    fi
    # 额外检查 _site 目录
    if [[ -d "_site" ]]; then
        found+=("_site")
    fi
    if [[ -d "docs/_site" ]]; then
        found+=("docs/_site")
    fi

    if [[ ${#found[@]} -eq 0 ]]; then
        info "未发现常见站点残留文件"
        return 0
    fi
    warn "发现 ${#found[@]} 个可能属于站点文件的项:"
    for f in "${found[@]}"; do
        data "$f"
    done
    confirm "从工作区删除这些文件" && {
        for f in "${found[@]}"; do
            if [[ -d "$f" ]]; then
                rm -rf "$f" && ok "已删除目录: $f" || warn "删除失败: $f"
            else
                rm -f "$f" && ok "已删除: $f" || warn "删除失败: $f"
            fi
        done
        confirm "是否 git commit 这次清理" && {
            git add -A
            git commit -m "cleanup: remove github-pages artifacts" 2>/dev/null && ok "已提交清理" || warn "提交失败"
        }
    } || info "已跳过文件删除"
}

cmd_pages() {
    _pages_check_gh || return 1

    local action="${1:-menu}"
    shift 2>/dev/null || true

    case "$action" in
        status)
            _pages_status
            ;;
        disable|off|close)
            _pages_status || true
            echo ""
            _pages_disable
            ;;
        remove-branch|rm-branch)
            _pages_remove_branch "${1:-gh-pages}"
            ;;
        clean-deployments|clean-deps)
            _pages_clean_deployments
            ;;
        clean-files)
            _pages_clean_files
            ;;
        full|purge)
            log "GitHub Pages 完整清理流程"
            echo ""
            _pages_status || true
            echo ""
            confirm "即将执行: 关闭站点+删分支+清部署+清文件" || { ok "已取消"; return 0; }
            echo ""
            _pages_disable || true
            echo ""
            _pages_remove_branch "${1:-gh-pages}"
            echo ""
            _pages_clean_deployments
            echo ""
            _pages_clean_files
            echo ""
            ok "GitHub Pages 完整清理完成"
            info "注意: 仓库本身不会被删除，仅 Pages 站点被关闭清理"
            ;;
        menu|"")
            while true; do
                echo ""
                log "GitHub Pages 管理"
                _pages_status 2>/dev/null || warn "Pages 未启用"
                echo ""
                echo "  [1] 关闭 Pages 站点 (DELETE)"
                echo "  [2] 删除 gh-pages 分支 (本地+远程)"
                echo "  [3] 清理历史 deployments (并发)"
                echo "  [4] 清理工作区站点文件"
                echo "  [5] 完整清理 (1+2+3+4)"
                echo "  [0] 返回上级"
                echo ""
                ask "请选择 [0-5]: "
                local p
                read -r p
                echo ""
                case "$p" in
                    1) _pages_disable ;;
                    2) _pages_remove_branch ;;
                    3) _pages_clean_deployments ;;
                    4) _pages_clean_files ;;
                    5) cmd_pages full ;;
                    0|q) break ;;
                    *) warn "无效选择: $p" ;;
                esac
                echo ""
                read -rp "按 Enter 继续..."
            done
            ;;
        help|-h)
            cat <<'EOF'
pages 子命令用法:
    pages                      进入交互菜单
    pages status               查看 Pages 状态
    pages disable              关闭 Pages (DELETE 站点)
    pages remove-branch [name] 删除 gh-pages 分支 (默认 gh-pages)
    pages clean-deployments    清理历史 deployment 记录 (并发)
    pages clean-files          清理工作区残留站点文件
    pages full [branch]        一键完整清理 (关闭+分支+部署+文件)
EOF
            ;;
        *) error "未知子命令: $action"; cmd_pages help ;;
    esac
}

# ---------- 交互式主菜单 ----------
show_menu() {
    while true; do
        echo ""
        log "GitHub Backend Manager"
        data "仓库: $REPO  |  分支: $(current_branch)"
        echo ""
        echo "  [1] 发布新版本 (release)"
        echo "  [2] 发布通知 (notify)"
        echo "  [3] 清理旧版本 (clean)"
        echo "  [4] 备份管理 (backup)"
        echo "  [5] 查看状态 (status)"
        echo "  [6] 初始化 (init)"
        echo "  [7] GitHub Pages 管理"
        echo "  ─────────────────────────"
        echo "  [8] 上传本地JSON (upload)"
        echo "  [9] 同步远程JSON (sync)"
        echo "  [10] 对比差异 (diff)"
        echo "  ─────────────────────────"
        echo "  [0] 退出"
        echo ""
        ask "请选择 [0-10]: "
        local choice
        read -r choice
        echo ""

        case "$choice" in
            1) cmd_release ;;
            2) cmd_notify ;;
            3) cmd_clean ;;
            4)
                echo "  [1] 查看备份"
                echo "  [2] 创建备份"
                echo "  [3] 恢复备份"
                ask "请选择 [1-3]: "
                local bchoice
                read -r bchoice
                case "$bchoice" in
                    1) cmd_backup list ;;
                    2) ask "备份备注: "; read -r note; cmd_backup create "$note" ;;
                    3) cmd_backup list; ask "备份名称: "; read -r bname; cmd_backup restore "$bname" ;;
                esac
                ;;
            5) cmd_status ;;
            6) cmd_init ;;
            7) cmd_pages menu ;;
            8) cmd_upload ;;
            9) cmd_sync ;;
            10) cmd_diff ;;
            0|q) log "再见!"; break ;;
            *) warn "无效选择: $choice" ;;
        esac

        echo ""
        read -rp "按 Enter 继续..."
    done
}

# ---------- 帮助 ----------
usage() {
    cat <<'EOF'
GitHub Backend Manager - Termux 版 (v3.0)

用法:
    bash manage.sh              进入交互菜单
    bash manage.sh <命令> [参数...]

命令:
    init                初始化环境
    status              查看状态
    release [v] [so] [msg_zh] [msg_en] [msg_ru] [force]
                        发布新版本 (支持多语言)
    notify [id] [title_zh] [title_en] [title_ru]
            [content_zh] [content_en] [content_ru] [force]
                        发布多语言通知
    clean [tag]         清理旧版本
    backup [action]     备份管理 (list/create/restore)
    pages [sub]         GitHub Pages 关闭与清理

    upload [update.json] [notify.json]   一键上传本地JSON
    sync                                 从远程拉取JSON
    diff                                 对比本地与远程差异

JSON 格式:
    update.json:  versionCode, url, message{zh,en,ru}, force, sha256, minOsVersion
    notify.json:   id, title{zh,en,ru}, content{zh,en,ru}, force, createdAt

选项:
    -y                  自动确认 (非交互)
    -v                  显示调试信息
    -h                  显示帮助

上传示例:
    bash manage.sh upload                    # 交互式上传
    bash manage.sh upload ./update.json ./notify.json   # 直接指定路径
EOF
}

# ---------- 参数解析 ----------
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

# ---------- 主入口 ----------
main() {
    cd "$SCRIPT_DIR"
    load_env
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
        backup|b)   cmd_backup "${ARGS[@]}" ;;
        pages|p)    cmd_pages "${ARGS[@]}" ;;
        upload|up)  cmd_upload "${ARGS[@]}" ;;
        sync|pull)  cmd_sync ;;
        diff|d)     cmd_diff ;;
        help)       usage ;;
        *)          error "未知命令: $CMD"; usage ;;
    esac
}

main "$@"
