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
    load_api_key
    ensure_git_repo

    local status_entries
    status_entries=$(collect_status_entries)

    if [ -z "$status_entries" ]; then
        log "No changes to commit."
        exit 0
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
}

main "$@"
