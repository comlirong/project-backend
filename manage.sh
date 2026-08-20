#!/bin/bash
# ==============================================================================
# GitHub Backend Manager - Termux 专用精简版
# 用法: bash manage.sh              # 进入交互菜单
#       bash manage.sh release      # 直接发布
# ==============================================================================

set -uo pipefail
IFS=$'\n\t'

# ---------- 基础配置 ----------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="comlirong/project-backend"
API_DIR="api/v1"
BACKUP_DIR=".api_backups"
DEFAULT_BRANCH="main"
MIN_OS_VERSION="21"
KEEP_RELEASES="0"
AUTO_CLEAN="true"

# 运行时状态
DRY_RUN=0
VERBOSE=0
FORCE_YES=0
HAS_JQ=0
SHA_CMD=""

# ---------- 日志 ----------
log()   { echo "[*] $*"; }
ok()    { echo "[OK] $*"; }
warn()  { echo "[!] $*" >&2; }
error() { echo "[ERR] $*" >&2; }
info()  { echo " -> $*"; }
data()  { echo "    $*"; }
debug() { [[ "$VERBOSE" == "1" ]] && echo "    . $*" >&2 || true; }

# ---------- 配置加载 ----------
load_env() {
    [[ -f "$SCRIPT_DIR/.env" ]] && source "$SCRIPT_DIR/.env"
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

    if ! command -v gh &>/dev/null; then
        warn "未找到 gh CLI，部分功能不可用"
    else
        ok "gh CLI 已安装"
    fi

    if ! git rev-parse --git-dir &>/dev/null; then
        warn "当前目录不是 git 仓库"
    else
        ok "git 仓库检测通过"
    fi

    HAS_JQ=$(detect_jq)
    SHA_CMD=$(detect_sha)

    [[ "$HAS_JQ" == "1" ]] && ok "jq 可用" || warn "jq 未安装，JSON 功能受限"
    [[ -n "$SHA_CMD" ]] && ok "SHA 工具: $SHA_CMD" || warn "未找到 sha256sum/shasum"

    mkdir -p "$API_DIR" "$BACKUP_DIR"
    ok "环境检查完成"
}

# ---------- Git 操作 ----------
current_branch() {
    git branch --show-current 2>/dev/null || git symbolic-ref --short HEAD 2>/dev/null || echo "$DEFAULT_BRANCH"
}

git_sync() {
    local branch
    branch=$(current_branch)
    info "同步远程 origin/$branch..."

    git fetch origin "$branch" 2>/dev/null || git fetch origin 2>/dev/null || {
        warn "fetch 失败，跳过同步"
        return 0
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

    if git merge "origin/$branch" --no-edit -m "auto: sync remote" 2>/dev/null; then
        git push origin "$branch" || warn "推送失败"
        ok "已合并并推送"
        return 0
    fi

    warn "检测到冲突，尝试自动解决..."
    git checkout --ours "$API_DIR/update.json" "$API_DIR/notify.json" 2>/dev/null || true
    git add "$API_DIR" 2>/dev/null || true
    git commit -m "auto: resolve conflicts" || true
    git push origin "$branch" || warn "推送失败"
    ok "冲突已解决"
}

# ---------- JSON 处理 ----------
json_get() {
    local file="$1" key="$2"
    [[ -f "$file" ]] || { echo ""; return; }
    if [[ "$HAS_JQ" == "1" ]]; then
        jq -r ".$key // empty" "$file" 2>/dev/null || echo ""
        return
    fi
    grep -oP "\"$key\"\s*:\s*(\"[^\"]*\"|[0-9]+|true|false)" "$file" 2>/dev/null | head -1 | sed 's/.*:\s*//; s/^"//; s/"$//'
}

json_get_lang() {
    local file="$1" key="$2" lang="$3"
    [[ -f "$file" ]] || { echo ""; return; }
    if [[ "$HAS_JQ" == "1" ]]; then
        jq -r ".$key.$lang // empty" "$file" 2>/dev/null || echo ""
        return
    fi
    python3 -c "import json,sys; d=json.load(open('$file')); print(d.get('$key',{}).get('$lang',''))" 2>/dev/null || echo ""
}

json_build_update() {
    local vc="$1" url="$2" msg_zh="$3" msg_en="$4" msg_ru="$5" force="$6" sha="$7"
    cat > "$API_DIR/update.json" <<EOF
{
  "versionCode": $vc,
  "url": "$url",
  "message": {
    "zh": "$msg_zh",
    "en": "$msg_en",
    "ru": "$msg_ru"
  },
  "force": $force,
  "sha256": "$sha",
  "minOsVersion": $MIN_OS_VERSION
}
EOF
}

json_build_notify() {
    local id="$1" title_zh="$2" title_en="$3" title_ru="$4" content_zh="$5" content_en="$6" content_ru="$7" force="$8"
    cat > "$API_DIR/notify.json" <<EOF
{
  "id": "$id",
  "title": {
    "zh": "$title_zh",
    "en": "$title_en",
    "ru": "$title_ru"
  },
  "content": {
    "zh": "$content_zh",
    "en": "$content_en",
    "ru": "$content_ru"
  },
  "force": $force,
  "createdAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
}

# ---------- 备份 ----------
backup_create() {
    local ts=$(date +%Y%m%d_%H%M%S)
    local path="$BACKUP_DIR/backup_${ts}_$1"
    mkdir -p "$path"
    for f in update.json notify.json notify_history.json; do
        [[ -f "$API_DIR/$f" ]] && cp "$API_DIR/$f" "$path/$f"
    done
    echo "$path"
}

backup_list() {
    [[ -d "$BACKUP_DIR" ]] || { warn "无备份目录"; return; }
    info "备份列表:"
    for b in "$BACKUP_DIR"/backup_*; do
        [[ -d "$b" ]] || continue
        data "$(basename "$b") ($(du -sh "$b" 2>/dev/null | cut -f1))"
    done
}

# ---------- 版本推断 ----------
suggest_version() {
    local current=""
    [[ -f "$API_DIR/update.json" ]] && current=$(json_get "$API_DIR/update.json" "versionCode")
    [[ -z "$current" ]] && current=$(git tag --sort=-version:refname 2>/dev/null | grep -E '^v[0-9]+$' | head -1 | sed 's/^v//')
    [[ -n "$current" && "$current" =~ ^[0-9]+$ ]] && echo $((current + 1)) || echo "1"
}

suggest_notify_id() {
    local last=""
    [[ -f "$API_DIR/notify.json" ]] && last=$(json_get "$API_DIR/notify.json" "id")
    [[ -z "$last" ]] && { echo "001"; return; }
    [[ "$last" =~ ^[0-9]+$ ]] && printf "%03d" $((10#$last + 1)) || date +"%Y%m%d%H%M%S"
}

# ---------- 查找 so 文件 ----------
find_so() {
    local dirs=("." "build" "libs" "jniLibs" "src/main/jniLibs")
    local found=""
    for d in "${dirs[@]}"; do
        [[ -d "$d" ]] || continue
        while IFS= read -r -d '' f; do
            found="$found$f\n"
        done < <(find "$d" -maxdepth 3 -name "*.so" -type f -print0 2>/dev/null)
    done
    echo -e "$found" | grep -v '^$' | sort -u
}

# ---------- 清理旧版本 ----------
clean_old() {
    local keep_tag="${1:-}"
    local keep="$KEEP_RELEASES"

    info "获取远程标签..."
    local tags
    tags=$(git ls-remote --tags origin 'refs/tags/v*' 2>/dev/null | awk '{print $2}' | sed 's|refs/tags/||' | grep -E '^v[0-9]+$' | sort -Vr)
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
    read -rp "确认删除? [y/N]: " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { ok "已取消"; return; }

    for tag in "${tags_to_delete[@]}"; do
        if gh release view "$tag" --repo "$REPO" &>/dev/null; then
            gh release delete "$tag" --repo "$REPO" --yes 2>/dev/null && ok "删除 release: $tag" || warn "release 删除失败: $tag"
        else
            debug "release $tag 不存在，跳过"
        fi
        git push origin ":refs/tags/$tag" 2>/dev/null && ok "删除 tag: $tag" || warn "tag 删除失败: $tag"
    done
}

# ---------- 命令: init ----------
cmd_init() {
    log "初始化项目..."
    mkdir -p "$API_DIR" "$BACKUP_DIR"
    [[ -f "$API_DIR/update.json" ]] || cat > "$API_DIR/update.json" <<'EOF'
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
    [[ -f "$API_DIR/notify.json" ]] || cat > "$API_DIR/notify.json" <<'EOF'
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
    [[ -f "$API_DIR/notify_history.json" ]] || echo '[]' > "$API_DIR/notify_history.json"

    if [[ ! -f "$SCRIPT_DIR/.env" ]]; then
        cat > "$SCRIPT_DIR/.env" <<'EOF'
# GitHub Backend 配置
# REPO=comlirong/project-backend
# KEEP_RELEASES=3
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
        data "当前版本: $(json_get "$API_DIR/update.json" "versionCode")"
        data "下载地址: $(json_get "$API_DIR/update.json" "url")"
        data "更新说明(zh): $(json_get_lang "$API_DIR/update.json" "message" "zh")"
        data "强制更新: $(json_get "$API_DIR/update.json" "force")"
    fi
    if [[ -f "$API_DIR/notify.json" ]]; then
        data "当前通知ID: #$(json_get "$API_DIR/notify.json" "id")"
        data "通知内容(zh): $(json_get_lang "$API_DIR/notify.json" "content" "zh")"
    fi
    data "Git提交: $(git rev-parse --short HEAD 2>/dev/null || echo 'N/A')"
    data "远程标签: $(git ls-remote --tags origin 2>/dev/null | wc -l) 个"
}

# ---------- 命令: release ----------
cmd_release() {
    local vc="${1:-}"
    local so="${2:-}"
    local msg_zh="${3:-}"
    local msg_en="${4:-}"
    local msg_ru="${5:-}"
    local force="${6:-}"

    if [[ -z "$vc" ]]; then
        local sug=$(suggest_version)
        read -rp "版本号 [默认: $sug]: " vc
        [[ -z "$vc" ]] && vc="$sug"
    fi
    [[ "$vc" =~ ^[0-9]+$ ]] || { error "版本号必须是整数"; return 1; }

    if [[ -z "$so" ]]; then
        local so_files=$(find_so)
        local count=$(echo "$so_files" | grep -c . || echo 0)
        if [[ "$count" -eq 1 ]]; then
            so="$so_files"
            info "自动发现 so: $so"
        elif [[ "$count" -gt 1 ]]; then
            info "发现多个 so 文件:"
            local i=1
            while IFS= read -r f; do
                data "$i) $f ($(du -h "$f" 2>/dev/null | cut -f1))"
                i=$((i+1))
            done <<< "$so_files"
            data "0) 手动输入路径"
            read -rp "选择 [0-$((i-1))]: " choice
            if [[ "$choice" == "0" ]]; then
                read -rp "so 文件路径: " so
            else
                so=$(sed -n "${choice}p" <<< "$so_files")
            fi
        else
            read -rp "so 文件路径: " so
        fi
    fi
    [[ -f "$so" ]] || { error "so 文件不存在: $so"; return 1; }

    if [[ -z "$msg_zh" ]]; then
        local last_zh=""
        [[ -f "$API_DIR/update.json" ]] && last_zh=$(json_get_lang "$API_DIR/update.json" "message" "zh")
        read -rp "更新说明(中文) [默认: ${last_zh:-版本更新}]: " msg_zh
        [[ -z "$msg_zh" ]] && msg_zh="${last_zh:-版本更新}"
    fi
    if [[ -z "$msg_en" ]]; then
        read -rp "更新说明(英文) [默认: $msg_zh]: " msg_en
        [[ -z "$msg_en" ]] && msg_en="$msg_zh"
    fi
    if [[ -z "$msg_ru" ]]; then
        read -rp "更新说明(俄文) [默认: $msg_en]: " msg_ru
        [[ -z "$msg_ru" ]] && msg_ru="$msg_en"
    fi

    if [[ -z "$force" ]]; then
        read -rp "强制更新? [y/N]: " f
        [[ "$f" =~ ^[Yy]$ ]] && force="true" || force="false"
    fi

    local tag="v$vc"
    local so_name=$(basename "$so")
    local url="https://github.com/$REPO/releases/download/$tag/$so_name"
    local sha=$($SHA_CMD "$so" | awk '{print $1}')

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
    read -rp "确认发布? [y/N]: " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { ok "已取消"; return 0; }

    backup_create "pre_$tag" >/dev/null
    git add . 2>/dev/null || true
    git commit -m "auto: sync" 2>/dev/null || true
    git_sync

    json_build_update "$vc" "$url" "$msg_zh" "$msg_en" "$msg_ru" "$force" "$sha"

    git add "$API_DIR/update.json"
    git commit -m "release: $tag" || true
    git tag -a "$tag" -m "release $tag" || { error "打标签失败"; return 1; }
    git push origin "$(current_branch)" || warn "推送失败"
    git push origin "$tag" || warn "推送标签失败"

    if gh release view "$tag" --repo "$REPO" &>/dev/null; then
        warn "Release $tag 已存在，尝试上传资源"
    else
        gh release create "$tag" --repo "$REPO" --title "Release $tag" --notes "$msg_en" || warn "创建 Release 失败"
    fi
    gh release upload "$tag" "$so" --repo "$REPO" --clobber || warn "上传资源失败"

    ok "发布完成: $tag"

    [[ "$AUTO_CLEAN" == "true" ]] && clean_old "$tag"
}

# ---------- 命令: notify ----------
cmd_notify() {
    local id="${1:-}"
    local title_zh="${2:-}"
    local title_en="${3:-}"
    local title_ru="${4:-}"
    local content_zh="${5:-}"
    local content_en="${6:-}"
    local content_ru="${7:-}"
    local force="${8:-}"

    if [[ -z "$id" ]]; then
        local sug=$(suggest_notify_id)
        read -rp "通知ID [默认: $sug]: " id
        [[ -z "$id" ]] && id="$sug"
    fi

    if [[ -z "$title_zh" ]]; then
        read -rp "通知标题(中文): " title_zh
    fi
    if [[ -z "$title_en" ]]; then
        read -rp "通知标题(英文) [默认: $title_zh]: " title_en
        [[ -z "$title_en" ]] && title_en="$title_zh"
    fi
    if [[ -z "$title_ru" ]]; then
        read -rp "通知标题(俄文) [默认: $title_en]: " title_ru
        [[ -z "$title_ru" ]] && title_ru="$title_en"
    fi

    if [[ -z "$content_zh" ]]; then
        read -rp "通知内容(中文): " content_zh
    fi
    if [[ -z "$content_en" ]]; then
        read -rp "通知内容(英文) [默认: $content_zh]: " content_en
        [[ -z "$content_en" ]] && content_en="$content_zh"
    fi
    if [[ -z "$content_ru" ]]; then
        read -rp "通知内容(俄文) [默认: $content_en]: " content_ru
        [[ -z "$content_ru" ]] && content_ru="$content_en"
    fi

    if [[ -z "$force" ]]; then
        read -rp "强制显示? [y/N]: " f
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
        [[ -z "$keep_tag" || "$keep_tag" == "v" ]] && keep_tag=$(git tag --sort=-version:refname 2>/dev/null | grep -E '^v[0-9]+$' | head -1)
        [[ -z "$keep_tag" ]] && { read -rp "保留的版本标签 (如 v100): " keep_tag; }
    fi
    clean_old "$keep_tag"
}

# ---------- 命令: backup ----------
cmd_backup() {
    local action="${1:-list}"
    case "$action" in
        list)   backup_list ;;
        create) local path=$(backup_create "${2:-manual}"); ok "备份创建: $(basename "$path")" ;;
        restore)
            local name="$2"
            [[ -z "$name" ]] && { read -rp "备份名称: " name; }
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

# ---------- GitHub Pages 管理 ----------
_pages_check_gh() {
    command -v gh &>/dev/null && return 0
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
    resp=$(gh api --method DELETE -H "Accept: application/vnd.github+json" "/repos/$owner/$repo/pages" 2>&1)
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
    info "检查分支: $branch"
    local remote_exists=0
    git ls-remote --heads origin "$branch" 2>/dev/null | grep -q "$branch" && remote_exists=1

    if [[ "$remote_exists" -eq 0 ]]; then
        info "远程分支 $branch 不存在，跳过"
    else
        warn "将删除远程分支: $branch"
        read -rp "确认删除远程分支 $branch? [y/N]: " c
        if [[ "$c" =~ ^[Yy]$ ]]; then
            git push origin --delete "$branch" 2>&1 && ok "远程分支 $branch 已删除" || warn "删除远程分支失败"
        else
            info "已跳过远程分支删除"
        fi
    fi

    if git show-ref --verify --quiet "refs/heads/$branch"; then
        warn "将删除本地分支: $branch"
        read -rp "确认删除本地分支 $branch? [y/N]: " c
        if [[ "$c" =~ ^[Yy]$ ]]; then
            git checkout "$(current_branch)" &>/dev/null || true
            git branch -D "$branch" 2>&1 && ok "本地分支 $branch 已删除" || warn "删除本地分支失败"
        fi
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
    count=$(echo "$deps" | wc -l | tr -d ' ')
    warn "发现 $count 条 github-pages 部署记录"

    local MAX_DEPS=200
    if [[ "$count" -gt "$MAX_DEPS" ]]; then
        warn "超过 $MAX_DEPS 条，仅处理前 $MAX_DEPS 条"
        deps=$(echo "$deps" | head -n "$MAX_DEPS")
        count=$MAX_DEPS
    fi

    read -rp "确认全部标记为 inactive (实质清理)? [y/N]: " c
    [[ "$c" =~ ^[Yy]$ ]] || { info "已跳过"; return 0; }

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
    local targets=("index.html" "404.html" "CNAME" "_config.yml" "_site" "docs/_site")
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

    if [[ ${#found[@]} -eq 0 ]]; then
        info "未发现常见站点残留文件"
        return 0
    fi
    warn "发现 ${#found[@]} 个可能属于站点文件的项:"
    for f in "${found[@]}"; do
        data "$f"
    done
    read -rp "从工作区删除这些文件? [y/N]: " c
    if [[ "$c" =~ ^[Yy]$ ]]; then
        for f in "${found[@]}"; do
            rm -rf "$f" && ok "已删除: $f" || warn "删除失败: $f"
        done
        read -rp "是否 git commit 这次清理? [y/N]: " cc
        if [[ "$cc" =~ ^[Yy]$ ]]; then
            git add -A
            git commit -m "cleanup: remove github-pages artifacts" 2>/dev/null && ok "已提交清理" || warn "提交失败"
        fi
    else
        info "已跳过文件删除"
    fi
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
            read -rp "即将执行: 关闭站点+删分支+清部署+清文件，确认? [y/N]: " c
            [[ "$c" =~ ^[Yy]$ ]] || { ok "已取消"; return 0; }
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
                read -rp "请选择 [0-5]: " p
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
        echo "  [1] 发布新版本"
        echo "  [2] 发布通知"
        echo "  [3] 清理旧版本"
        echo "  [4] 备份管理"
        echo "  [5] 查看状态"
        echo "  [6] 初始化"
        echo "  [7] GitHub Pages 管理"
        echo "  [0] 退出"
        echo ""
        read -rp "请选择 [0-7]: " choice
        echo ""

        case "$choice" in
            1) cmd_release ;;
            2) cmd_notify ;;
            3) cmd_clean ;;
            4)
                echo "  [1] 查看备份"
                echo "  [2] 创建备份"
                echo "  [3] 恢复备份"
                read -rp "请选择 [1-3]: " bchoice
                case "$bchoice" in
                    1) cmd_backup list ;;
                    2) read -rp "备份备注: " note; cmd_backup create "$note" ;;
                    3) cmd_backup list; read -rp "备份名称: " bname; cmd_backup restore "$bname" ;;
                esac
                ;;
            5) cmd_status ;;
            6) cmd_init ;;
            7) cmd_pages menu ;;
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
GitHub Backend Manager - Termux 版

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
                        (status|disable|remove-branch|clean-deployments|
                         clean-files|full|menu)

JSON 格式:
    update.json:  versionCode, url, message{zh,en,ru}, force, sha256, minOsVersion
    notify.json:   id, title{zh,en,ru}, content{zh,en,ru}, force, createdAt

选项:
    -v                  显示调试信息
    -h                  显示帮助
EOF
}

# ---------- 参数解析 ----------
parse_opts() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
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
        help)       usage ;;
        *)          error "未知命令: $CMD"; usage ;;
    esac
}

main "$@"
