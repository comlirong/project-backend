#!/bin/bash
# ==============================================================================
# 智能 GitHub 后端管理脚本（极简实用版）
# 功能: 版本发布、通知管理、历史追踪、配置持久化、
#       自动清理旧版本、日志清理、智能冲突解决、自动备份恢复
# ==============================================================================

set -euo pipefail
IFS=$'\n\t'

# ------------------------------------------------------------------------------
# 基础配置（可通过 .env 覆盖）
# ------------------------------------------------------------------------------
: "${REPO:=comlirong/project-backend}"
: "${BASE_URL:=https://comlirong.github.io/project-backend/api/v1}"
: "${API_DIR:=api/v1}"
: "${HISTORY_MAX:=20}"
: "${GIT_STRATEGY:=merge}"          # merge | rebase
: "${BACKUP_DIR:=.api_backups}"
: "${LOG_FILE:=.release_log}"
: "${DEFAULT_BRANCH:=main}"
: "${MIN_OS_VERSION:=21}"
: "${AUTO_CLEAN_OLD_RELEASES:=true}"
: "${KEEP_RELEASES:=0}"
: "${KEEP_LOG_LINES:=100}"
: "${CLEAR_GH_ACTIONS_LOGS:=false}"

# ------------------------------------------------------------------------------
# 极简日志（无边框 / 无 Emoji / 克制配色）
# ------------------------------------------------------------------------------
log()   { printf "\033[1m%s\033[0m\n" "$*"; }
ok()    { printf "  \033[32m✓\033[0m %s\n" "$*"; }
warn()  { printf "  \033[33m!\033[0m %s\n" "$*" >&2; }
error() { printf "\033[31merror:\033[0m %s\n" "$*" >&2; exit 1; }
info()  { printf "  → %s\n" "$*"; }
data()  { printf "    %s\n" "$*"; }
hint()  { printf "    \033[36mhint:\033[0m %s\n" "$*" >&2; }
debug() { [[ "${VERBOSE:-0}" == "1" ]] && printf "  \033[90m· %s\033[0m\n" "$*" >&2 || true; }

# ------------------------------------------------------------------------------
# 初始化与依赖检查
# ------------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
[[ -f ".env" ]] && source .env

# 检测可用编辑器
detect_editor() {
    local candidates=("${EDITOR:-}" "nano" "vim" "vi" "emacs" "micro" "notepad" "code")
    for ed in "${candidates[@]}"; do
        [[ -n "$ed" ]] && command -v "$ed" &>/dev/null && { echo "$ed"; return 0; }
    done
    echo ""
    return 1
}

# 检测 Git 远程协议和认证状态（自动诊断）
check_git_auth() {
    local remote_url
    remote_url=$(git remote get-url origin 2>/dev/null || echo "")

    [[ -z "$remote_url" ]] && { warn "no origin remote found"; return; }

    info "remote: $remote_url"

    if ! git ls-remote --heads origin &>/dev/null; then
        warn "cannot reach remote (ls-remote failed)"
        if [[ "$remote_url" == https://* ]]; then
            hint "HTTPS detected — auth may be required each push"
            hint "fix 1: git config --global credential.helper cache"
            hint "fix 2: git remote set-url origin git@github.com:${REPO}.git"
            hint "fix 3: gh auth setup-git"
        elif [[ "$remote_url" == git@github.com:* ]]; then
            hint "SSH failed — check key: cat ~/.ssh/id_rsa.pub"
            hint "and ssh-agent: eval \$(ssh-agent -s) && ssh-add"
        fi
    else
        debug "remote reachable"
    fi
}

# 检查核心依赖
check_deps() {
    command -v gh &>/dev/null || error "gh cli not found — install: https://cli.github.com/"
    gh auth status &>/dev/null || error "gh not logged in — run: gh auth login"
    git rev-parse --git-dir &>/dev/null || error "not a git repo"

    HAS_JQ=0
    if command -v jq &>/dev/null; then
        HAS_JQ=1
        debug "jq available"
    else
        warn "jq not found — using bash fallback parser (limited)"
    fi

    if command -v sha256sum &>/dev/null; then
        SHA_CMD="sha256sum"
    elif command -v shasum &>/dev/null; then
        SHA_CMD="shasum -a 256"
    else
        error "sha256sum/shasum not found"
    fi

    mkdir -p "$API_DIR" "$BACKUP_DIR"
    check_git_auth
}

# ------------------------------------------------------------------------------
# 自动检测当前分支
# ------------------------------------------------------------------------------
detect_branch() {
    local branch
    branch=$(git branch --show-current 2>/dev/null || true)
    [[ -n "$branch" ]] && { echo "$branch"; return; }
    branch=$(git symbolic-ref --short HEAD 2>/dev/null || true)
    [[ -n "$branch" ]] && { echo "$branch"; return; }
    echo "$DEFAULT_BRANCH"
}

fetch_remote_tags() {
    debug "fetching remote tags"
    git fetch origin --tags &>/dev/null || true
}

# 获取所有远程版本标签（包括无 Release 的）
get_all_remote_tags() {
    local versions
    versions=$(git ls-remote --tags origin 'refs/tags/v*' 2>/dev/null \
        | awk '{print $2}' | sed 's|refs/tags/||' | grep -E '^v[0-9]+$' | sort -Vr || true)

    if [[ -z "$versions" ]]; then
        fetch_remote_tags
        versions=$(git tag --sort=-version:refname | grep -E '^v[0-9]+$' || true)
    fi
    echo "$versions"
}

# 获取有 Release 的版本
get_all_releases() {
    local versions
    versions=$(gh api "repos/${REPO}/releases" --jq '.[].tag_name' 2>/dev/null \
        | grep -E '^v[0-9]+$' | sort -Vr || true)

    if [[ -z "$versions" ]]; then
        versions=$(gh release list --repo "$REPO" --json tagName --jq '.[].tagName' 2>/dev/null \
            | grep -E '^v[0-9]+$' | sort -Vr || true)
    fi
    echo "$versions"
}

# ------------------------------------------------------------------------------
# 智能 JSON 处理引擎（jq + bash fallback）
# ------------------------------------------------------------------------------
json_get() {
    local file="$1" key="$2"
    [[ -f "$file" ]] || { echo ""; return; }

    if [[ "$HAS_JQ" == "1" ]]; then
        jq -r ".$key // empty" "$file" 2>/dev/null || echo ""
        return
    fi

    local raw
    raw=$(grep -oP "\"${key}\"\\s*:\\s*(\"[^\"]*\"|true|false|[0-9]+)" "$file" 2>/dev/null | head -1)
    [[ -z "$raw" ]] && { echo ""; return; }

    local value="${raw#*:}"
    value="${value#"${value%%[![:space:]]*}"}"

    case "$value" in
        \"*\") echo "$value" | sed 's/^"//;s/"$//' ;;
        true|false) echo "$value" ;;
        [0-9]*) echo "$value" ;;
        *) echo "" ;;
    esac
}

json_set() {
    local file="$1" key="$2" value="$3" type="${4:-string}"
    [[ -f "$file" ]] || echo "{}" > "$file"

    if [[ "$HAS_JQ" == "1" ]]; then
        local jq_val
        case "$type" in
            string) jq_val="\"$value\"" ;;
            number|bool) jq_val="$value" ;;
            *) jq_val="\"$value\"" ;;
        esac
        jq ".$key = $jq_val" "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
        return
    fi

    if grep -q "\"$key\"" "$file" 2>/dev/null; then
        sed -i "s|\"$key\"[[:space:]]*:[[:space:]]*[^,}]*|\"$key\": $value|" "$file"
    else
        sed -i "$ i\\  \"$key\": $value," "$file"
    fi
}

json_build_update() {
    local versionCode="$1" url="$2" message="$3" force="$4" sha256="$5"
    local minOs="${6:-$MIN_OS_VERSION}"

    local safe_msg
    safe_msg=$(echo "$message" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\n/\\n/g; s/\r/\\r/g; s/\t/\\t/g')

    cat > "${API_DIR}/update.json" <<EOF
{
  "versionCode": ${versionCode},
  "url": "${url}",
  "message": "${safe_msg}",
  "force": ${force},
  "sha256": "${sha256}",
  "minOsVersion": ${minOs}
}
EOF
}

json_build_notify() {
    local id="$1" title="$2" content="$3" force="$4" timestamp="$5"

    local safe_title safe_content
    safe_title=$(echo "$title" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\n/\\n/g')
    safe_content=$(echo "$content" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\n/\\n/g')

    cat > "${API_DIR}/notify.json" <<EOF
{
  "id": "${id}",
  "title": "${safe_title}",
  "content": "${safe_content}",
  "force": ${force},
  "createdAt": "${timestamp}"
}
EOF
}

# ------------------------------------------------------------------------------
# 智能备份与恢复
# ------------------------------------------------------------------------------
backup_api_files() {
    local suffix="$1"
    local ts; ts=$(date +%Y%m%d_%H%M%S)
    local backup_path="${BACKUP_DIR}/backup_${ts}_${suffix}"
    mkdir -p "$backup_path"
    for f in update.json notify.json notify_history.json; do
        [[ -f "${API_DIR}/$f" ]] && cp "${API_DIR}/$f" "${backup_path}/$f"
    done
    echo "$backup_path"
}

restore_backup() {
    local backup_path="$1"
    [[ -d "$backup_path" ]] || return 1
    for f in update.json notify.json notify_history.json; do
        [[ -f "${backup_path}/$f" ]] && cp "${backup_path}/$f" "${API_DIR}/$f"
    done
    log "restored from $(basename "$backup_path")"
}

# ------------------------------------------------------------------------------
# 智能 Git 操作（自动 commit / merge / rebase / 冲突解决）
# ------------------------------------------------------------------------------
ensure_git_clean() {
    if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
        info "auto-commit local changes"
        git add .
        git commit -m "auto: sync workspace before release [$(date +%H:%M:%S)]" &>/dev/null || true
    fi
}

sync_remote() {
    local branch; branch=$(detect_branch)
    info "sync remote origin/${branch}"

    # 1) fetch
    if ! git fetch origin "$branch" 2>/dev/null; then
        if ! git fetch origin 2>/dev/null; then
            local err_detail
            err_detail=$(git fetch origin 2>&1 || true)
            error "fetch failed — branch '${branch}' may not exist on remote
       remote: $(git remote get-url origin 2>/dev/null || echo unknown)
       detail: ${err_detail}"
        fi
    fi

    local local_head remote_head
    local_head=$(git rev-parse HEAD)
    remote_head=$(git rev-parse "origin/${branch}" 2>/dev/null || echo "")

    [[ -z "$remote_head" ]] && { warn "remote branch origin/${branch} not found, skip sync"; return 0; }

    # 2) 本地已最新
    if [[ "$local_head" == "$remote_head" ]]; then
        ok "local already up-to-date"
        return 0
    fi

    # 3) 本地领先 → 直接 push
    if git merge-base --is-ancestor "origin/${branch}" HEAD 2>/dev/null; then
        info "local ahead, pushing"
        git push origin "$branch" || error "push failed"
        ok "pushed"
        return 0
    fi

    # 4) 远程有新提交 → 按策略处理
    info "remote has new commits, strategy: ${GIT_STRATEGY}"

    # 4a) rebase 优先
    if [[ "$GIT_STRATEGY" == "rebase" ]]; then
        if git pull --rebase origin "$branch" 2>/dev/null; then
            git push origin "$branch" || error "push after rebase failed"
            ok "rebase + push done"
            return 0
        else
            warn "rebase conflict, aborting"
            git rebase --abort 2>/dev/null || true
        fi
    fi

    # 4b) merge 兜底
    if git merge "origin/${branch}" --no-edit -m "auto: sync remote changes" 2>/dev/null; then
        git push origin "$branch" || error "push after merge failed"
        ok "merge + push done"
        return 0
    fi

    # 4c) 冲突智能解决
    warn "conflicts detected, auto-resolving"
    local api_files=("${API_DIR}/update.json" "${API_DIR}/notify.json" "${API_DIR}/notify_history.json")

    # API 文件 → 保留本地版本
    for f in "${api_files[@]}"; do
        if [[ -f "$f" ]] && git diff --name-only --diff-filter=U 2>/dev/null | grep -qx "${f#./}"; then
            git checkout --ours "$f"
            git add "$f"
            ok "kept ours: $f"
        fi
    done

    # 其他文件 → 保留远程版本
    git diff --name-only --diff-filter=U 2>/dev/null | while read -r cf; do
        [[ " ${api_files[*]} " =~ " ${cf} " ]] && continue
        git checkout --theirs "$cf"
        git add "$cf"
        warn "kept theirs: $cf"
    done

    git commit -m "auto: resolve merge conflicts (smart keep)" || true
    git push origin "$branch" || error "push after conflict resolution failed"
    ok "conflicts resolved + pushed"
}

# ------------------------------------------------------------------------------
# 智能版本推断
# ------------------------------------------------------------------------------
suggest_next_version() {
    local current=""
    if [[ -f "${API_DIR}/update.json" ]]; then
        current=$(json_get "${API_DIR}/update.json" "versionCode")
    fi
    if [[ -z "$current" ]]; then
        current=$(get_all_remote_tags | head -1 | sed 's/^v//' || true)
    fi
    if [[ -n "$current" && "$current" =~ ^[0-9]+$ ]]; then
        echo "$((current + 1))"
    else
        echo "1"
    fi
}

# ------------------------------------------------------------------------------
# 智能通知 ID 生成
# ------------------------------------------------------------------------------
suggest_notify_id() {
    local last_id=""
    if [[ -f "${API_DIR}/notify.json" ]]; then
        last_id=$(json_get "${API_DIR}/notify.json" "id")
    fi
    if [[ -z "$last_id" ]]; then
        echo "001"
        return
    fi
    if [[ "$last_id" =~ ^[0-9]+$ ]]; then
        printf "%03d" "$((10#$last_id + 1))"
    else
        date +"%Y%m%d%H%M%S"
    fi
}

# ------------------------------------------------------------------------------
# 智能文件发现
# ------------------------------------------------------------------------------
find_so_files() {
    local search_dirs=("." "build" "libs" "jniLibs" "src/main/jniLibs")
    local found=()

    for dir in "${search_dirs[@]}"; do
        [[ -d "$dir" ]] || continue
        while IFS= read -r -d '' file; do
            found+=("$file")
        done < <(find "$dir" -maxdepth 3 -name "*.so" -type f -print0 2>/dev/null)
    done

    printf "%s\n" "${found[@]}" | sort -u
}

# ------------------------------------------------------------------------------
# 自动清理旧版本 Release + Tag（含 dry-run / 批量推送）
# ------------------------------------------------------------------------------
clean_old_releases() {
    local current_tag="${1:-}"
    local keep="${KEEP_RELEASES:-0}"
    local dry_run="${DRY_RUN:-0}"

    info "fetching all remote tags"
    local all_tags; all_tags=$(get_all_remote_tags)
    [[ -z "$all_tags" ]] && { warn "no remote tags found"; return 0; }

    # 计数
    local total=0
    while IFS= read -r tag; do
        [[ -z "$tag" || "$tag" == "$current_tag" ]] && continue
        total=$((total + 1))
    done <<< "$all_tags"

    [[ "$total" -eq 0 ]] && { ok "no old versions to clean (current: ${current_tag:-none})"; return 0; }

    info "found ${total} old tags, keep policy: last ${keep}"

    local tags_to_delete=()
    local refspecs_to_delete=()
    local delete_count=0 keep_count=0

    while IFS= read -r tag; do
        [[ -z "$tag" || "$tag" == "$current_tag" ]] && continue
        delete_count=$((delete_count + 1))

        if [[ "$keep" -gt 0 && "$delete_count" -le "$keep" ]]; then
            ok "keep: $tag"
            keep_count=$((keep_count + 1))
            continue
        fi

        if [[ "$dry_run" == "1" ]]; then
            info "would delete: $tag"
            continue
        fi

        tags_to_delete+=("$tag")
        refspecs_to_delete+=(":refs/tags/$tag")
    done <<< "$all_tags"

    [[ "$dry_run" == "1" ]] && { ok "dry-run complete, nothing deleted"; return 0; }

    local removed=${#tags_to_delete[@]}
    [[ "$removed" -eq 0 ]] && { ok "nothing to delete"; return 0; }

    # 1) 删除 GitHub Release
    info "deleting ${removed} releases"
    for tag in "${tags_to_delete[@]}"; do
        if gh release view "$tag" --repo "$REPO" &>/dev/null; then
            if gh release delete "$tag" --repo "$REPO" --yes &>/dev/null; then
                ok "release deleted: $tag"
            else
                warn "release delete failed: $tag"
            fi
        else
            debug "no release for $tag, skip"
        fi
    done

    # 2) 删除本地 Tag
    local existing_local=()
    for tag in "${tags_to_delete[@]}"; do
        git rev-parse "$tag" &>/dev/null && existing_local+=("$tag")
    done
    if [[ ${#existing_local[@]} -gt 0 ]]; then
        if git tag -d "${existing_local[@]}" &>/dev/null; then
            ok "local tags deleted: ${existing_local[*]}"
        else
            warn "some local tags delete failed"
        fi
    fi

    # 3) 批量删除远程 Tag（一次认证）
    if [[ ${#refspecs_to_delete[@]} -gt 0 ]]; then
        info "batch delete remote tags"
        if git push origin "${refspecs_to_delete[@]}" 2>/dev/null; then
            ok "remote tags deleted: ${tags_to_delete[*]}"
        else
            warn "batch delete failed, retrying one-by-one"
            for tag in "${tags_to_delete[@]}"; do
                if git push origin ":refs/tags/$tag" 2>/dev/null; then
                    ok "$tag"
                else
                    warn "$tag failed"
                fi
            done
        fi
    fi

    ok "cleaned ${removed} old releases"
}

cmd_clean() {
    local current_tag=""
    if [[ -f "${API_DIR}/update.json" ]]; then
        local vc; vc=$(json_get "${API_DIR}/update.json" "versionCode")
        [[ -n "$vc" ]] && current_tag="v${vc}"
    fi
    if [[ -z "$current_tag" ]]; then
        current_tag=$(get_all_remote_tags | head -1 || true)
    fi
    if [[ -z "$current_tag" ]]; then
        warn "cannot auto-detect current version"
        read -rp "keep tag (e.g. v1000048, empty = clean all): " current_tag
    fi

    if [[ "${INTERACTIVE:-1}" == "1" && "${DRY_RUN:-0}" != "1" ]]; then
        warn "will delete all tags except '${current_tag:-none}'"
        read -rp "confirm? [y/N]: " confirm
        [[ "$confirm" =~ ^[Yy]$ ]] || { ok "cancelled"; return 0; }
    fi

    clean_old_releases "$current_tag"
}

# ------------------------------------------------------------------------------
# 核心命令：发布新版本（含自动推断 / 自动发现 / 自动备份 / 自动恢复）
# ------------------------------------------------------------------------------
cmd_release() {
    local version_code="${1:-}"
    local so_path="${2:-}"
    local message="${3:-}"
    local force="${4:-}"
    local dry_run="${DRY_RUN:-0}"

    # 自动推断版本号
    if [[ -z "$version_code" ]]; then
        local suggested; suggested=$(suggest_next_version)
        if [[ "${INTERACTIVE:-1}" == "1" ]]; then
            read -rp "version [auto: ${suggested}]: " version_code
            [[ -z "$version_code" ]] && version_code="$suggested"
        else
            error "non-interactive mode requires version argument"
        fi
    fi
    [[ "$version_code" =~ ^[0-9]+$ ]] || error "version must be integer, got: $version_code"

    # 自动发现 so 文件
    if [[ -z "$so_path" ]]; then
        local so_files; so_files=$(find_so_files)
        local count; count=$(echo "$so_files" | grep -c . || echo 0)

        if [[ "$count" -eq 1 ]]; then
            so_path="$so_files"
            info "auto-detected so: $so_path"
        elif [[ "$count" -gt 1 && "${INTERACTIVE:-1}" == "1" ]]; then
            info "multiple so files found:"
            local i=1
            while IFS= read -r f; do
                local sz; sz=$(du -h "$f" 2>/dev/null | cut -f1)
                echo "    ${i}) ${f} (${sz})"
                i=$((i + 1))
            done <<< "$so_files"
            echo "    0) enter path manually"
            read -rp "select: " choice
            if [[ "$choice" == "0" ]]; then
                read -rp "so path: " so_path
            else
                so_path=$(sed -n "${choice}p" <<< "$so_files")
            fi
        else
            read -rp "so path: " so_path
        fi
    fi
    [[ -f "$so_path" ]] || error "so file not found: $so_path"

    # 自动复用上次 message
    if [[ -z "$message" ]]; then
        local last_msg=""
        [[ -f "${API_DIR}/update.json" ]] && last_msg=$(json_get "${API_DIR}/update.json" "message")
        if [[ -n "$last_msg" && "${INTERACTIVE:-1}" == "1" ]]; then
            read -rp "msg [reuse: \"${last_msg}\"]: " message
            [[ -z "$message" ]] && message="$last_msg"
        else
            message="${last_msg:-版本更新}"
        fi
    fi

    # 强制更新
    if [[ -z "$force" && "${INTERACTIVE:-1}" == "1" ]]; then
        read -rp "force update? [y/N]: " f
        [[ "$f" =~ ^[Yy]$ ]] && force="true" || force="false"
    fi
    [[ "$force" == "true" || "$force" == "1" ]] && force="true" || force="false"

    local tag="v${version_code}"
    local so_filename; so_filename=$(basename "$so_path")
    local download_url="https://github.com/${REPO}/releases/download/${tag}/${so_filename}"
    local sha256; sha256=$($SHA_CMD "$so_path" | awk '{print $1}')

    info "prepare release ${version_code}"
    data "file    : $so_path"
    data "sha256  : $sha256"
    data "force   : $force"
    data "msg     : $message"

    # Dry run
    if [[ "$dry_run" == "1" ]]; then
        warn "DRY RUN — no remote changes"
        json_build_update "$version_code" "$download_url" "$message" "$force" "$sha256"
        ok "preview ${API_DIR}/update.json:"
        cat "${API_DIR}/update.json"
        clean_old_releases "$tag"
        return 0
    fi

    # 备份 → 构建 → 提交 → 同步 → 发布
    local backup_path; backup_path=$(backup_api_files "pre_release")
    info "backup: $(basename "$backup_path")"

    json_build_update "$version_code" "$download_url" "$message" "$force" "$sha256"

    ensure_git_clean
    git add "${API_DIR}/update.json"
    git commit -m "release: ${tag}" &>/dev/null || true
    sync_remote

    # 创建或更新 Release
    if gh release view "$tag" --repo "$REPO" &>/dev/null; then
        info "release ${tag} exists, updating asset"
        gh release delete-asset "$tag" "$so_filename" --repo "$REPO" -y 2>/dev/null || true
        if ! gh release upload "$tag" "$so_path" --repo "$REPO"; then
            warn "upload failed, restoring backup"
            restore_backup "$backup_path"
            error "release upload failed"
        fi
    else
        info "creating release ${tag}"
        if ! gh release create "$tag" "$so_path" \
            --repo "$REPO" \
            --title "Version ${version_code}" \
            --notes "$message"; then
            restore_backup "$backup_path"
            error "release create failed"
        fi
    fi

    echo "[$(date -Iseconds)] RELEASE ${tag} | file=${so_path} | sha256=${sha256} | force=${force}" >> "$LOG_FILE"

    ok "release done"
    data "api  : ${BASE_URL}/update.json"
    data "url  : ${download_url}"

    # 自动清理旧版本
    if [[ "${AUTO_CLEAN_OLD_RELEASES}" == "true" ]]; then
        echo
        clean_old_releases "$tag"
    fi
}

# ------------------------------------------------------------------------------
# 核心命令：更新通知（含自动 ID / 复用标题内容 / 历史追加）
# ------------------------------------------------------------------------------
cmd_notify() {
    local notify_id="${1:-}"
    local title="${2:-}"
    local content="${3:-}"
    local force="${4:-false}"
    local dry_run="${DRY_RUN:-0}"

    # 自动生成 ID
    if [[ -z "$notify_id" ]]; then
        local suggested; suggested=$(suggest_notify_id)
        if [[ "${INTERACTIVE:-1}" == "1" ]]; then
            read -rp "id [auto: ${suggested}]: " notify_id
            [[ -z "$notify_id" ]] && notify_id="$suggested"
        else
            notify_id="$suggested"
            info "auto id: $notify_id"
        fi
    fi

    # 自动复用标题
    if [[ -z "$title" ]]; then
        local last_title=""
        [[ -f "${API_DIR}/notify.json" ]] && last_title=$(json_get "${API_DIR}/notify.json" "title")
        if [[ -n "$last_title" && "${INTERACTIVE:-1}" == "1" ]]; then
            read -rp "title [reuse: \"${last_title}\"]: " title
            [[ -z "$title" ]] && title="$last_title"
        else
            [[ -z "$title" ]] && error "title required (no previous to reuse)"
        fi
    fi

    # 自动复用内容
    if [[ -z "$content" ]]; then
        local last_content=""
        [[ -f "${API_DIR}/notify.json" ]] && last_content=$(json_get "${API_DIR}/notify.json" "content")
        if [[ -n "$last_content" && "${INTERACTIVE:-1}" == "1" ]]; then
            read -rp "content [reuse: \"${last_content}\"]: " content
            [[ -z "$content" ]] && content="$last_content"
        else
            [[ -z "$content" ]] && error "content required (no previous to reuse)"
        fi
    fi

    [[ "$force" == "true" || "$force" == "1" ]] && force="true" || force="false"

    local timestamp; timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    info "notify ${notify_id}"
    data "title : $title"
    data "force : $force"

    if [[ "$dry_run" == "1" ]]; then
        warn "DRY RUN"
        json_build_notify "$notify_id" "$title" "$content" "$force" "$timestamp"
        cat "${API_DIR}/notify.json"
        return 0
    fi

    local backup_path; backup_path=$(backup_api_files "pre_notify")
    json_build_notify "$notify_id" "$title" "$content" "$force" "$timestamp"
    append_notify_history "$notify_id" "$title" "$content" "$force" "$timestamp"

    ensure_git_clean
    git add "${API_DIR}/notify.json" "${API_DIR}/notify_history.json"
    git commit -m "notify: ${notify_id}" &>/dev/null || true
    sync_remote

    echo "[$(date -Iseconds)] NOTIFY ${notify_id} | title=${title} | force=${force}" >> "$LOG_FILE"

    ok "notify pushed"
    data "api  : ${BASE_URL}/notify.json"
    data "hist : ${BASE_URL}/notify_history.json"
}

# ------------------------------------------------------------------------------
# 历史记录管理（jq 优先 + bash fallback + 自动截断）
# ------------------------------------------------------------------------------
append_notify_history() {
    local id="$1" title="$2" content="$3" force="$4" timestamp="$5"
    local history_file="${API_DIR}/notify_history.json"

    local safe_title safe_content
    safe_title=$(echo "$title" | sed 's/\\/\\\\/g; s/"/\\"/g')
    safe_content=$(echo "$content" | sed 's/\\/\\\\/g; s/"/\\"/g')

    if [[ "$HAS_JQ" == "1" ]]; then
        local new_entry
        new_entry=$(jq -n \
            --arg id "$id" \
            --arg title "$safe_title" \
            --arg content "$safe_content" \
            --argjson force "$force" \
            --arg createdAt "$timestamp" \
            '{id: $id, title: $title, content: $content, force: $force, createdAt: $createdAt}')

        if [[ -f "$history_file" ]]; then
            jq --argjson entry "$new_entry" --argjson max "$HISTORY_MAX" \
                '.items = ([$entry] + .items)[:$max] | .total = (.items | length)' \
                "$history_file" > "${history_file}.tmp" && mv "${history_file}.tmp" "$history_file"
        else
            jq -n --argjson entry "$new_entry" '{total: 1, items: [$entry]}' > "$history_file"
        fi
        return
    fi

    # bash fallback
    if [[ ! -f "$history_file" ]]; then
        cat > "$history_file" <<EOF
{
  "total": 1,
  "items": [
    {
      "id": "${id}",
      "title": "${safe_title}",
      "content": "${safe_content}",
      "force": ${force},
      "createdAt": "${timestamp}"
    }
  ]
}
EOF
        return
    fi

    local existing="" new_entry=""
    if grep -q '"items"' "$history_file"; then
        existing=$(sed -n '/"items":/,/\]/p' "$history_file" | sed '1d;$d' | sed '$s/,$//')
    fi

    new_entry="    {\n      \"id\": \"${id}\",\n      \"title\": \"${safe_title}\",\n      \"content\": \"${safe_content}\",\n      \"force\": ${force},\n      \"createdAt\": \"${timestamp}\"\n    }"

    local all_items
    if [[ -n "$existing" ]]; then
        all_items="${new_entry}"$'\n'"${existing}"
    else
        all_items="${new_entry}"
    fi

    # 截断
    local count; count=$(echo -e "$all_items" | grep -c '"id":' || echo 0)
    if [[ "$count" -gt "$HISTORY_MAX" ]]; then
        local skip=$((count - HISTORY_MAX)) cur=0 filtered=""
        while IFS= read -r line; do
            if [[ "$line" =~ \"id\": ]]; then
                cur=$((cur + 1))
                [[ "$cur" -le "$skip" ]] && continue
            fi
            filtered+="${line}"$'\n'
        done <<< "$(echo -e "$all_items")"
        all_items="$filtered"
        count="$HISTORY_MAX"
    fi

    cat > "$history_file" <<EOF
{
  "total": ${count},
  "items": [
$(echo -e "$all_items")
  ]
}
EOF
}

# ------------------------------------------------------------------------------
# 工作日志清理（自动备份 / 截断 / 可选清理 GH Actions）
# ------------------------------------------------------------------------------
cmd_clearlog() {
    local keep_lines="${1:-${KEEP_LOG_LINES:-100}}"
    local dry_run="${DRY_RUN:-0}"

    [[ -f "$LOG_FILE" ]] || { ok "no log file to clean"; return 0; }

    local total; total=$(wc -l < "$LOG_FILE" | tr -d ' ')
    [[ "$total" -eq 0 ]] && { ok "log empty"; return 0; }

    info "log: ${total} lines, keep: ${keep_lines}"

    # 全部清空
    if [[ "$keep_lines" -le 0 ]]; then
        if [[ "${INTERACTIVE:-1}" == "1" && "$dry_run" != "1" ]]; then
            warn "will clear all ${total} lines"
            read -rp "confirm? [y/N]: " c
            [[ "$c" =~ ^[Yy]$ ]] || { ok "cancelled"; return 0; }
        fi
        [[ "$dry_run" == "1" ]] && { warn "DRY RUN: would clear all"; return 0; }
        local bak="${LOG_FILE}.$(date +%Y%m%d_%H%M%S).bak"
        cp "$LOG_FILE" "$bak"; : > "$LOG_FILE"
        ok "log cleared, backup: $bak"
        [[ "${CLEAR_GH_ACTIONS_LOGS}" == "true" ]] && clear_github_actions_logs
        return 0
    fi

    [[ "$total" -le "$keep_lines" ]] && { ok "within limit, nothing to do"; return 0; }

    local del=$((total - keep_lines))
    if [[ "${INTERACTIVE:-1}" == "1" && "$dry_run" != "1" ]]; then
        warn "will delete oldest ${del} lines, keep ${keep_lines}"
        read -rp "confirm? [y/N]: " c
        [[ "$c" =~ ^[Yy]$ ]] || { ok "cancelled"; return 0; }
    fi
    [[ "$dry_run" == "1" ]] && { warn "DRY RUN: would delete ${del} lines"; return 0; }

    local bak="${LOG_FILE}.$(date +%Y%m%d_%H%M%S).bak"
    cp "$LOG_FILE" "$bak"
    tail -n "$keep_lines" "$LOG_FILE" > "${LOG_FILE}.tmp"
    mv "${LOG_FILE}.tmp" "$LOG_FILE"
    ok "trimmed ${del} lines, backup: $bak"

    [[ "${CLEAR_GH_ACTIONS_LOGS}" == "true" ]] && clear_github_actions_logs
}

# 清理 GitHub Actions 工作流日志
clear_github_actions_logs() {
    info "checking GitHub Actions logs"
    local workflow_id
    workflow_id=$(gh api "repos/${REPO}/actions/workflows" \
        --jq '.workflows[] | select(.name | test("pages|Pages")) | .id' 2>/dev/null | head -1 || true)
    [[ -z "$workflow_id" ]] && { debug "no pages workflow found"; return 0; }

    local runs
    runs=$(gh api "repos/${REPO}/actions/workflows/${workflow_id}/runs" \
        --jq '.workflow_runs[].id' 2>/dev/null || true)
    [[ -z "$runs" ]] && { ok "no actions runs to clean"; return 0; }

    local count=0
    while IFS= read -r run_id; do
        [[ -z "$run_id" ]] && continue
        gh api --method DELETE "repos/${REPO}/actions/runs/${run_id}" &>/dev/null && count=$((count + 1))
    done <<< "$runs"

    [[ "$count" -gt 0 ]] && ok "cleaned ${count} actions runs"
}

# ------------------------------------------------------------------------------
# 查询命令
# ------------------------------------------------------------------------------
cmd_history() {
    local f="${API_DIR}/notify_history.json"
    [[ -f "$f" ]] && cat "$f" || echo "no history yet"
}

cmd_status() {
    local branch; branch=$(detect_branch)
    log "repo      $REPO"
    log "branch    $branch"
    log "api       $API_DIR"
    log "strategy  $GIT_STRATEGY"
    log "auto-clean $AUTO_CLEAN_OLD_RELEASES"
    log "keep      ${KEEP_RELEASES} (releases) / ${KEEP_LOG_LINES} (log lines)"
    log "jq        $([[ "$HAS_JQ" == "1" ]] && echo yes || echo no)"

    echo
    log "update.json"
    [[ -f "${API_DIR}/update.json" ]] && cat "${API_DIR}/update.json" | sed 's/^/  /' || echo "  (none)"

    echo
    log "notify.json"
    [[ -f "${API_DIR}/notify.json" ]] && cat "${API_DIR}/notify.json" | sed 's/^/  /' || echo "  (none)"

    echo
    log "tags"
    local tags; tags=$(get_all_remote_tags)
    [[ -n "$tags" ]] && echo "$tags" | sed 's/^/  /' || echo "  (none)"

    echo
    log "log"
    [[ -f "$LOG_FILE" ]] && echo "  $(wc -l < "$LOG_FILE") lines · $(du -h "$LOG_FILE" | cut -f1)" || echo "  (none)"
}

cmd_log() {
    [[ -f "$LOG_FILE" ]] || { echo "no log"; return; }
    tail -n "${1:-20}" "$LOG_FILE" | sed 's/^/  /'
}

# ------------------------------------------------------------------------------
# 极简交互菜单
# ------------------------------------------------------------------------------
interactive_menu() {
    INTERACTIVE=1
    local branch jq_status
    branch=$(detect_branch)
    [[ "$HAS_JQ" == "1" ]] && jq_status="yes" || jq_status="no"

    while true; do
        printf "\n"
        log "GitHub Backend Manager"
        info "repo: $REPO | branch: $branch | jq: $jq_status"
        printf "\n"
        printf "  1) release     发布新版本\n"
        printf "  2) notify      更新通知\n"
        printf "  3) history     通知历史\n"
        printf "  4) status      当前配置\n"
        printf "  5) log         操作日志\n"
        printf "  6) config      编辑 .env\n"
        printf "  7) clean       清理旧版本\n"
        printf "  8) clearlog    清理日志\n"
        printf "  0) exit\n\n"
        printf "> "
        read -r choice
        echo

        case "$choice" in
            1) cmd_release ;;
            2) cmd_notify ;;
            3) cmd_history ;;
            4) cmd_status ;;
            5) cmd_log ;;
            6)
                if [[ ! -f ".env" ]]; then
                    cat > .env <<'EOF'
# GitHub Backend Manager Config
# REPO="username/repo"
# BASE_URL="https://username.github.io/repo/api/v1"
# GIT_STRATEGY=merge
# HISTORY_MAX=20
# AUTO_CLEAN_OLD_RELEASES=true
# KEEP_RELEASES=0
# KEEP_LOG_LINES=100
# CLEAR_GH_ACTIONS_LOGS=false
EOF
                fi
                local ed; ed=$(detect_editor)
                if [[ -n "$ed" ]]; then
                    info "editor: $ed"
                    "$ed" .env
                    source .env 2>/dev/null || true
                    ok "config reloaded"
                else
                    warn "no editor found (set \$EDITOR or install nano/vim)"
                    cat .env
                fi
                ;;
            7) cmd_clean ;;
            8) cmd_clearlog ;;
            0) ok "bye"; exit 0 ;;
            *) warn "invalid choice" ;;
        esac
    done
}

# ------------------------------------------------------------------------------
# 帮助
# ------------------------------------------------------------------------------
show_help() {
    cat <<EOF
GitHub Backend Manager (minimal)

usage: $0 <command> [args...]

global:
  DRY_RUN=1 $0 ...     preview, no remote changes
  VERBOSE=1 $0 ...     debug output

commands:
  release [ver] [so] [msg] [force]    release new version
  notify  [id] [title] [content] [f]  push notification
  clean                               clean old releases + tags
  clearlog [keep]                     trim operation log
  history                             show notify history
  status                              show config + versions
  log [n]                             show last n log lines
  init                                create .env
  help                                this help

examples:
  $0 release
  $0 release 3 ./lib.so "fix crash" true
  DRY_RUN=1 $0 release 3 ./lib.so "test" false
  $0 notify
  $0 clearlog 50
EOF
}

# ------------------------------------------------------------------------------
# 主入口
# ------------------------------------------------------------------------------
main() {
    check_deps
    case "${1:-}" in
        release)
            shift; INTERACTIVE=0; [[ $# -lt 2 ]] && INTERACTIVE=1
            cmd_release "$@" ;;
        notify)
            shift; INTERACTIVE=0; [[ $# -lt 2 ]] && INTERACTIVE=1
            cmd_notify "$@" ;;
        clean)    cmd_clean ;;
        clearlog) shift; cmd_clearlog "${1:-${KEEP_LOG_LINES:-100}}" ;;
        history)  cmd_history ;;
        status)   cmd_status ;;
        log)      shift; cmd_log "${1:-20}" ;;
        init)
            [[ -f ".env" ]] && error ".env already exists"
            cat > .env <<EOF
REPO="$REPO"
BASE_URL="$BASE_URL"
API_DIR="$API_DIR"
HISTORY_MAX=$HISTORY_MAX
GIT_STRATEGY=$GIT_STRATEGY
AUTO_CLEAN_OLD_RELEASES=$AUTO_CLEAN_OLD_RELEASES
KEEP_RELEASES=$KEEP_RELEASES
KEEP_LOG_LINES=$KEEP_LOG_LINES
CLEAR_GH_ACTIONS_LOGS=$CLEAR_GH_ACTIONS_LOGS
EOF
            ok "created .env"
            ;;
        help|--help|-h) show_help ;;
        "") interactive_menu ;;
        *) error "unknown command: $1 (try: $0 help)" ;;
    esac
}

main "$@"
