#!/usr/bin/env bash

set -euo pipefail

# Commit every pending file in the current git repository with an AI-generated
# message derived from the file's staged diff. Designed to be invoked from
# any repo (e.g., alias `gc=~/src/pstaylor-patrick/utility-scripts/ai/gc.sh`).
#
# Supports OpenAI Codex (default), Claude Code CLI, or DeepSeek API for message generation.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ai/lib/provider.sh
. "${SCRIPT_DIR}/lib/provider.sh"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >&2
}

# Strip surrounding double quotes from git porcelain paths (used for filenames with spaces)
strip_quotes() {
    local path="$1"
    if [[ "$path" == \"*\" ]]; then
        path="${path#\"}"  # Remove leading quote
        path="${path%\"}"  # Remove trailing quote
    fi
    printf '%s' "$path"
}

load_skip_list() {
    SKIP_PATTERNS=()
    local gcignore
    gcignore="$(git rev-parse --show-toplevel)/.gcignore"
    [ -f "$gcignore" ] || return 0
    while IFS= read -r line; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        SKIP_PATTERNS+=("$line")
    done < "$gcignore"
    log "Loaded ${#SKIP_PATTERNS[@]} skip pattern(s) from .gcignore"
}

is_skipped() {
    local path="$1"
    [ ${#SKIP_PATTERNS[@]} -eq 0 ] && return 1
    local basename="${path##*/}"
    for pattern in "${SKIP_PATTERNS[@]}"; do
        # Match against full path or basename
        if [[ "$path" == $pattern || "$basename" == $pattern ]]; then
            return 0
        fi
    done
    return 1
}

require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Error: $1 is required but not installed." >&2
        exit 1
    fi
}

ensure_git_repo() {
    if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        echo "Error: Not inside a git repository." >&2
        exit 1
    fi
}

enter_repo_root() {
    local repo_root
    repo_root=$(git rev-parse --show-toplevel)
    if [ "$PWD" != "$repo_root" ]; then
        log "Switching to git repository root: $repo_root"
        cd "$repo_root"
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

# Maximum characters for diff content in prompts (leaves room for prompt text and response)
# DeepSeek's limit is 131072 tokens; ~4 chars per token = ~500K chars, but we use 100K to be safe
MAX_DIFF_CHARS="${MAX_DIFF_CHARS:-100000}"

# When diff exceeds MAX_DIFF_CHARS, create a summarized version using git diff --stat
# plus the first and last portions of the actual diff for context
summarize_large_diff() {
    local diff_content="$1"
    local file_paths="$2"  # Space-separated list of paths, or empty for all staged

    local diff_len=${#diff_content}
    if [ "$diff_len" -le "$MAX_DIFF_CHARS" ]; then
        # Diff is small enough, return as-is
        printf '%s' "$diff_content"
        return 0
    fi

    log "Diff is too large ($diff_len chars > $MAX_DIFF_CHARS). Using summarized diff."

    # Get the stat summary
    local stat_output
    if [ -n "$file_paths" ]; then
        stat_output=$(git diff --cached --stat -- $file_paths 2>/dev/null || git diff --stat -- $file_paths 2>/dev/null || echo "")
    else
        stat_output=$(git diff --cached --stat 2>/dev/null || echo "")
    fi

    # Calculate how much of the actual diff we can include
    # Reserve ~2000 chars for stat and explanatory text
    local available_chars=$((MAX_DIFF_CHARS - 2000))
    local half_available=$((available_chars / 2))

    # Get first portion of diff (shows file headers and initial changes)
    local head_content
    head_content=$(printf '%s' "$diff_content" | head -c "$half_available")

    # Get last portion of diff (shows final changes)
    local tail_content
    tail_content=$(printf '%s' "$diff_content" | tail -c "$half_available")

    # Build summarized output
    cat <<EOF
[DIFF SUMMARY - Full diff too large ($diff_len chars), showing summary and samples]

=== CHANGE STATISTICS ===
$stat_output

=== FIRST PORTION OF DIFF ===
$head_content

[... TRUNCATED ${diff_len} chars total ...]

=== LAST PORTION OF DIFF ===
$tail_content
EOF
}

generate_commit_message_from_prompt() {
    local prompt="$1"
    local target_label="$2"
    local raw_message
    if ! raw_message=$(ai_exec "$prompt"); then
        log "Error: Failed to call $(ai_provider_name) for $target_label"
        return 1
    fi

    local cleaned
    cleaned=$(echo "$raw_message" \
        | sed '/^---$/d' \
        | head -n1 \
        | sed 's/^[`"'"'"']//' \
        | sed 's/[`"'"'"']$//' \
        | sed 's/[[:space:]]\+$//')

    if [ -z "$cleaned" ]; then
        log "Error: Empty commit message generated for $target_label"
        return 1
    fi

    echo "$cleaned"
}

generate_commit_message() {
    local file_path="$1"
    local diff_content="$2"

    # Summarize if diff is too large
    local processed_diff
    processed_diff=$(summarize_large_diff "$diff_content" "$file_path")

    local prompt
    prompt=$(cat <<EOF
You are a senior engineer writing a single, conventional git commit subject for one file. Respond with a concise, imperative, <=65 character line that captures the main change. Do not include quotes, backticks, or additional commentary.

Repository path: $(pwd)
File: $file_path

Here is the staged git diff for this file:
---
$processed_diff
---

Return only the commit subject line.
EOF
)

    generate_commit_message_from_prompt "$prompt" "$file_path"
}

generate_combined_commit_message() {
    local diff_content="$1"

    # Summarize if diff is too large (pass empty string for file_paths to use all staged)
    local processed_diff
    processed_diff=$(summarize_large_diff "$diff_content" "")

    local prompt
    prompt=$(cat <<EOF
You are a senior engineer writing a single, conventional git commit subject for the staged changes in this repository. Respond with a concise, imperative, <=65 character line that captures the main change. Do not include quotes, backticks, or additional commentary.

Repository path: $(pwd)

Here is the staged git diff for all staged changes:
---
$processed_diff
---

Return only the commit subject line.
EOF
)

    generate_commit_message_from_prompt "$prompt" "all staged changes"
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
        local raw_path="${entry:3}"
        raw_path=$(strip_quotes "$raw_path")
        if is_skipped "$raw_path"; then
            log "Skipping (gcignore) $raw_path"
            continue
        fi
        run_prettier_for_entry "$entry"
    done
}

run_prettier_for_entry() {
    local entry="$1"
    local raw_path="${entry:3}"
    raw_path=$(strip_quotes "$raw_path")
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
    local single_commit="$2"
    local skip_prettier="$3"

    local status="${entry:0:2}"
    local raw_path="${entry:3}"
    raw_path=$(strip_quotes "$raw_path")

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

    if is_skipped "$display_path"; then
        log "Skipping (gcignore) $display_path"
        # Restore tracked modified files to discard noise from auto-generated changes
        if [[ "$status" == *M* || "$status" == *D* ]] && git ls-files --error-unmatch "$display_path" >/dev/null 2>&1; then
            log "Restoring $display_path to clean working tree"
            git checkout -- "$display_path" 2>/dev/null || true
        fi
        return 0
    fi

    log "Staging ($status) $display_path"
    # Use git rm for deletions to avoid "could not open directory" warnings
    if [[ "$status" == *D* ]]; then
        git -c core.literalPathspecs=true rm --cached -- "${commit_paths[@]}"
    else
        git -c core.literalPathspecs=true add --all -- "${commit_paths[@]}"
    fi

    if [ "$single_commit" -eq 1 ]; then
        return 0
    fi

    local diff_output
    diff_output=$(git -c core.literalPathspecs=true diff --cached -- "${commit_paths[@]}")
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
    if [ "$skip_prettier" -eq 1 ]; then
        HUSKY=0 git -c core.literalPathspecs=true commit -m "$commit_message" -- "${commit_paths[@]}"
    else
        git -c core.literalPathspecs=true commit -m "$commit_message" -- "${commit_paths[@]}"
    fi
}

usage() {
    cat <<EOF
Usage: $(basename "$0") [-1] [-f] [-c|-d|-x] [-h]

Commit pending git changes with AI-generated commit messages.

Options:
  -1            Stage and commit all changes in a single commit
  -f            Fast mode: skip Prettier formatting and Husky hooks
  -h            Show this help message
$(ai_provider_usage)
EOF
}

main() {
    local single_commit=0
    local skip_prettier=0
    [ "${FORMAT:-1}" = "0" ] && skip_prettier=1

    while getopts ":1fcdxh" opt; do
        case "$opt" in
            1)
                single_commit=1
                ;;
            f)
                skip_prettier=1
                ;;
            c)
                ai_set_provider claude
                ;;
            d)
                ai_set_provider deepseek
                ;;
            x)
                ai_set_provider codex
                ;;
            h)
                usage
                exit 0
                ;;
            \?)
                echo "Invalid option: -$OPTARG" >&2
                usage >&2
                exit 1
                ;;
        esac
    done
    shift $((OPTIND - 1))

    require_cmd git
    ai_require_provider
    require_cmd npx
    ensure_git_repo
    enter_repo_root
    load_skip_list
    maybe_clean_gc_log

    log "Using AI backend: $(ai_provider_name)"
    log "Initial git status:"
    git status

    local status_entries
    status_entries=$(collect_status_entries)

    if [ -z "$status_entries" ]; then
        log "No changes to commit."
        exit 0
    fi

    if [ "$skip_prettier" -eq 0 ]; then
        log "Running Prettier on pending files from initial status."
        if ! format_entries_with_prettier <<< "$status_entries"; then
            log "Prettier formatting failed; aborting."
            exit 1
        fi
    else
        log "Skipping Prettier formatting (fast mode)."
    fi

    if [ "$single_commit" -eq 1 ]; then
        log "Single-commit mode enabled (-1); staging all entries for one commit."
    fi

    # Process each status line independently
    while IFS= read -r entry; do
        # Skip empty lines defensively
        [ -z "$entry" ] && continue
        if ! process_entry "$entry" "$single_commit" "$skip_prettier"; then
            log "Encountered an error while processing: $entry"
        fi
    done <<< "$status_entries"

    if [ "$single_commit" -eq 1 ]; then
        local combined_diff
        combined_diff=$(git diff --cached)
        if [ -z "$combined_diff" ]; then
            log "No staged diff found after staging; nothing to commit."
            exit 0
        fi

        local commit_message
        if ! commit_message=$(generate_combined_commit_message "$combined_diff"); then
            log "Failed to generate commit message for staged changes."
            exit 1
        fi

        log "Committing all staged changes with message: $commit_message"
        if [ "$skip_prettier" -eq 1 ]; then
            HUSKY=0 git commit -m "$commit_message"
        else
            git commit -m "$commit_message"
        fi
    fi

    log "Finished committing pending files."
    log "Final git status:"
    git status
}

main "$@"
