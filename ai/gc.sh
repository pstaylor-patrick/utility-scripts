#!/usr/bin/env bash

set -euo pipefail

# Commit every pending file in the current git repository with an AI-generated
# message derived from the file's staged diff. Designed to be invoked from
# any repo (e.g., alias `gc=~/src/pstaylor-patrick/utility-scripts/ai/gc.sh`).

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
PROJECT_ROOT="$SCRIPT_DIR/.."

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >&2
}

require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Error: $1 is required but not installed." >&2
        exit 1
    fi
}

load_api_key() {
    if [ -f "$PROJECT_ROOT/.env" ]; then
        # shellcheck disable=SC1091
        source "$PROJECT_ROOT/.env"
    fi

    if [ -z "${DEEPSEEK_API_KEY:-}" ]; then
        echo "Error: DEEPSEEK_API_KEY is not set. Add it to $PROJECT_ROOT/.env" >&2
        exit 1
    fi
}

ensure_git_repo() {
    if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        echo "Error: Not inside a git repository." >&2
        exit 1
    fi
}

maybe_clean_gc_log() {
    local git_dir
    git_dir=$(git rev-parse --git-dir)
    local gc_log="$git_dir/gc.log"

    if [ ! -f "$gc_log" ]; then
        return
    fi

    log "Existing git gc log detected at $gc_log. Last run reported:"
    tail -n 20 "$gc_log" || true
    log "Running 'git prune --expire=now' to clear unreachable loose objects..."
    if git prune --expire=now; then
        rm -f "$gc_log"
        log "Removed stale gc log; git auto-gc can resume normally."
    else
        log "git prune failed; leaving $gc_log in place."
    fi
}

generate_commit_message() {
    local file_path="$1"
    local diff_content="$2"

    local system_prompt="You are a senior engineer writing a single, conventional git commit subject for one file. Respond with a concise, imperative, <=65 character line that captures the main change. Do not include quotes, backticks, or additional commentary."
    local user_content="Repository path: $(pwd)\nFile: $file_path\n\nHere is the staged git diff for this file:\n---\n$diff_content\n---\n\nReturn only the commit subject line."

    local payload
    payload=$(jq -n \
        --arg system_prompt "$system_prompt" \
        --arg user_content "$user_content" \
        '{
            "model": "deepseek-chat",
            "messages": [
                {"role": "system", "content": $system_prompt},
                {"role": "user", "content": $user_content}
            ],
            "temperature": 0.3
        }')

    local response
    response=$(curl -s -X POST "https://api.deepseek.com/chat/completions" \
        -H "Authorization: Bearer $DEEPSEEK_API_KEY" \
        -H "Content-Type: application/json" \
        -d "$payload")

    if [[ $? -ne 0 ]]; then
        log "Error: Failed to call DeepSeek API for $file_path"
        return 1
    fi

    if ! jq -e '.choices[0].message.content' <<<"$response" >/dev/null 2>&1; then
        log "Error: Unexpected API response for $file_path"
        log "$response"
        return 1
    fi

    local raw_message
    raw_message=$(jq -r '.choices[0].message.content' <<<"$response")
    # Use the first line, strip wrapping quotes/backticks/spaces.
    local cleaned
    cleaned=$(echo "$raw_message" \
        | sed '/^---$/d' \
        | head -n1 \
        | sed 's/^[`"'"'"']//' \
        | sed 's/[`"'"'"']$//' \
        | sed 's/[[:space:]]\+$//')

    if [ -z "$cleaned" ]; then
        log "Error: Empty commit message generated for $file_path"
        return 1
    fi

    echo "$cleaned"
}

collect_status_entries() {
    git status --porcelain=v1 --untracked-files=all
}

can_prettier_format() {
    local path="$1"
    local filename="${path##*/}"

    [ -d "$path" ] && return 1

    local ext="${filename##*.}"
    if [ "$filename" = "$ext" ]; then
        return 1
    fi

    case "$ext" in
        js|jsx|ts|tsx|mjs|cjs|cts|mts|json|jsonc|css|scss|sass|less|md|mdx|markdown|yml|yaml|html|htm|graphql|gql|vue|svelte)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

format_entries_with_prettier() {
    local entry
    while IFS= read -r entry; do
        [ -z "$entry" ] && continue
        run_prettier_for_entry "$entry"
    done
}

run_prettier_for_entry() {
    local entry="$1"
    local raw_path="${entry:3}"
    local paths=()

    if [[ "$raw_path" == *" -> "* ]]; then
        local old_path="${raw_path%% -> *}"
        local new_path="${raw_path##* -> }"
        paths=("$new_path" "$old_path")
    else
        paths=("$raw_path")
    fi

    local found_existing=0
    local formatted=0
    for path in "${paths[@]}"; do
        if [ -e "$path" ] || [ -L "$path" ]; then
            found_existing=1
            if ! can_prettier_format "$path"; then
                log "Skipping Prettier for $path (unsupported type)"
                continue
            fi
            formatted=1
            log "Formatting $path with Prettier"
            if ! npx prettier --write -- "$path"; then
                log "Prettier failed for $path; continuing without aborting."
            fi
        fi
    done

    if [ "$formatted" -eq 0 ] && [ "$found_existing" -eq 0 ]; then
        log "Skipping Prettier for $raw_path (file not found)"
    elif [ "$formatted" -eq 0 ]; then
        log "Skipping Prettier for $raw_path (no supported file types found)"
    fi

    return 0
}

process_entry() {
    local entry="$1"

    local status="${entry:0:2}"
    local raw_path="${entry:3}"

    # Handle rename/copy indicators that present as "old -> new"
    local commit_paths=()
    local display_path
    if [[ "$raw_path" == *" -> "* ]]; then
        local old_path="${raw_path%% -> *}"
        local new_path="${raw_path##* -> }"
        commit_paths=("$old_path" "$new_path")
        display_path="$new_path"
    else
        commit_paths=("$raw_path")
        display_path="$raw_path"
    fi

    log "Staging ($status) $display_path"
    git add --all -- "${commit_paths[@]}"

    local diff_output
    diff_output=$(git diff --cached -- "${commit_paths[@]}")
    if [ -z "$diff_output" ]; then
        log "No staged diff for $display_path; skipping."
        return 0
    fi

    local commit_message
    if ! commit_message=$(generate_commit_message "$display_path" "$diff_output"); then
        log "Skipping commit for $display_path due to message generation failure."
        return 1
    fi

    log "Committing $display_path with message: $commit_message"
    git commit -m "$commit_message" -- "${commit_paths[@]}"
}

main() {
    require_cmd git
    require_cmd jq
    require_cmd curl
    require_cmd npx
    load_api_key
    ensure_git_repo
    maybe_clean_gc_log

    log "Initial git status:"
    git status

    local status_entries
    status_entries=$(collect_status_entries)

    if [ -z "$status_entries" ]; then
        log "No changes to commit."
        exit 0
    fi

    log "Running Prettier on pending files from initial status."
    if ! format_entries_with_prettier <<< "$status_entries"; then
        log "Prettier formatting failed; aborting."
        exit 1
    fi

    # Process each status line independently
    while IFS= read -r entry; do
        # Skip empty lines defensively
        [ -z "$entry" ] && continue
        if ! process_entry "$entry"; then
            log "Encountered an error while processing: $entry"
        fi
    done <<< "$status_entries"

    log "Finished committing pending files."
    log "Final git status:"
    git status
}

main "$@"
