#!/usr/bin/env bash

set -euo pipefail

DELIM=$'\x1f'
ISSUES=()
JOB_PIDS=()
FILE_KEYS=()
FILE_ISSUES=()
ISSUE_TOTAL=0

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2
}

die() {
    echo "Error: $*" >&2
    exit 1
}

require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        die "$1 is required but not installed or on PATH."
    fi
}

detect_package_manager() {
    if [ -f "package-lock.json" ]; then
        echo "npm"
        return 0
    fi
    if [ -f "pnpm-lock.yaml" ]; then
        echo "pnpm"
        return 0
    fi
    if [ -f "bun.lockb" ]; then
        echo "bun"
        return 0
    fi
    return 1
}

typecheck_command_for() {
    case "$1" in
        npm) echo "npm run typecheck" ;;
        pnpm) echo "pnpm typecheck" ;;
        bun) echo "bun run typecheck" ;;
        *) return 1 ;;
    esac
}

parse_type_output() {
    local log_file="$1"
    local pattern1='^([^:(]+):([0-9]+):([0-9]+)[[:space:]]*[-]?[[:space:]]*([Ee]rror|[Ww]arning)?[[:space:]]*(TS[0-9]+:)?[[:space:]]*(.*)$'
    local pattern2='^([^(:]+)\(([0-9]+),([0-9]+)\):[[:space:]]*([Ee]rror|[Ww]arning)?[[:space:]]*(TS[0-9]+:)?[[:space:]]*(.*)$'

    add_issue() {
        local file="$1" line="$2" col="$3" level="$4" message="$5"
        local idx=-1
        for i in "${!FILE_KEYS[@]}"; do
            if [ "${FILE_KEYS[$i]}" = "$file" ]; then
                idx=$i
                break
            fi
        done
        if [ "$idx" -lt 0 ]; then
            idx=${#FILE_KEYS[@]}
            FILE_KEYS+=("$file")
            FILE_ISSUES+=("")
        fi
        local entry="line ${line}, col ${col} ${level}: ${message}"
        if [ -n "${FILE_ISSUES[$idx]}" ]; then
            FILE_ISSUES[$idx]+=$'\n'"$entry"
        else
            FILE_ISSUES[$idx]="$entry"
        fi
        ISSUE_TOTAL=$((ISSUE_TOTAL + 1))
    }

    while IFS= read -r raw_line; do
        local line trimmed
        line="$raw_line"
        trimmed=$(printf "%s" "$line" | sed 's/[[:space:]]*$//')

        # Pattern: path:line:col - error TS123: message
        if [[ "$trimmed" =~ $pattern1 ]]; then
            local file_path="${BASH_REMATCH[1]}"
            local line_num="${BASH_REMATCH[2]}"
            local col_num="${BASH_REMATCH[3]}"
            local level="${BASH_REMATCH[4]}"
            local message="${BASH_REMATCH[6]}"
            [ -z "$level" ] && level="error"
            ISSUES+=("${file_path}${DELIM}${line_num}${DELIM}${col_num}${DELIM}${level}${DELIM}${message}")
            add_issue "$file_path" "$line_num" "$col_num" "$level" "$message"
            continue
        fi

        # Pattern: path(line,col): error TS123: message
        if [[ "$trimmed" =~ $pattern2 ]]; then
            local file_path="${BASH_REMATCH[1]}"
            local line_num="${BASH_REMATCH[2]}"
            local col_num="${BASH_REMATCH[3]}"
            local level="${BASH_REMATCH[4]}"
            local message="${BASH_REMATCH[6]}"
            [ -z "$level" ] && level="error"
            ISSUES+=("${file_path}${DELIM}${line_num}${DELIM}${col_num}${DELIM}${level}${DELIM}${message}")
            add_issue "$file_path" "$line_num" "$col_num" "$level" "$message"
            continue
        fi
    done < "$log_file"
}

launch_codex_fix() {
    local file_path="$1"
    local issues="$2"

    # Derive a friendly name from the path (fallback if Codex summary fails)
    local friendly_name
    friendly_name=$(basename "$file_path")
    friendly_name="${friendly_name%.*}"
    friendly_name=$(printf "%s" "$friendly_name" | sed 's/[][_-]/ /g; s/[[:space:]]\+/ /g; s/^ //; s/ $//')
    if [ -z "$friendly_name" ]; then
        friendly_name="this file"
    fi
    local parent_dir
    parent_dir=$(basename "$(dirname "$file_path")")
    if [ -n "$parent_dir" ] && [ "$parent_dir" != "." ] && [ "$parent_dir" != "$(basename "$PWD")" ]; then
        friendly_name="${parent_dir} ${friendly_name}"
    fi

    # Build a Codex-generated, <=50 char summary for streaming logs
    local label=""
    local summary_prompt
    summary_prompt=$(cat <<EOF
Summarize these typecheck issues for one file in <=50 characters, single line, no quotes or code fences.
Use a short, semantic page/feature name (e.g., "homepage", "client detail page", "${friendly_name}") instead of the literal filename, plus the issue gist/count.
File: ${file_path}
Issues:
${issues}
Return only the summary text.
EOF
)

    if label=$(codex exec "$summary_prompt" 2>/dev/null); then
        label=$(printf "%s" "$label" | sed '/^```.*$/d' | sed '/^---$/d' | head -n1 | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    else
        label=""
    fi

    if [ -z "$label" ]; then
        label="${friendly_name} type fixes"
    fi

    # Collapse whitespace and clamp length for readability
    label=$(printf "%s" "$label" | tr '\n' ' ' | tr '\t' ' ' | sed 's/[[:space:]]\+/ /g' | sed 's/^ //; s/ $//')
    if [ "${#label}" -gt 50 ]; then
        label="${label:0:47}..."
    fi
    local prefix="[$label]"

    local prompt
    prompt=$(cat <<EOF
You are an expert developer fixing TypeScript typecheck findings directly in the current repository.
Workdir: $(pwd)

Fix the following typecheck issues for the file:
${file_path}

Issues to address:
${issues}

Apply changes to resolve this typecheck issue without changing intended behavior. Run the necessary edits directly in the workspace.
EOF
)

    {
        log "${prefix} starting"
        if codex exec "$prompt" 2>&1 | awk -v p="${prefix} " '{print p $0}'; then
            log "${prefix} completed"
        else
            log "${prefix} failed"
            return 1
        fi
    } &

    JOB_PIDS+=("$!")
}

main() {
    require_cmd codex

    local pm
    if ! pm=$(detect_package_manager); then
        die "No supported lockfile found (package-lock.json, pnpm-lock.yaml, bun.lockb)."
    fi

    local type_cmd
    if ! type_cmd=$(typecheck_command_for "$pm"); then
        die "Failed to build typecheck command."
    fi

    log "Using package manager: ${pm}"
    log "Running typecheck: ${type_cmd}"

    local type_log
    type_log=$(mktemp)

    set +e
    eval "$type_cmd" 2>&1 | tee "$type_log"
    local type_status="${PIPESTATUS[0]}"
    set -euo pipefail

    parse_type_output "$type_log"
    local file_count="${#FILE_KEYS[@]}"

    if [ "$file_count" -eq 0 ]; then
        if [ "$type_status" -eq 0 ]; then
            log "Typecheck finished cleanly; no issues to fix."
            exit 0
        fi
        log "Typecheck exited with status ${type_status} but no parseable issues were found. See ${type_log}."
        exit "$type_status"
    fi

    log "Launching ${file_count} codex worker(s) in parallel for ${ISSUE_TOTAL} issue(s)."

    for idx in "${!FILE_KEYS[@]}"; do
        local file_path="${FILE_KEYS[$idx]}"
        local file_issues="${FILE_ISSUES[$idx]}"
        launch_codex_fix "$file_path" "$file_issues"
    done

    local failures=0
    for pid in "${JOB_PIDS[@]}"; do
        if ! wait "$pid"; then
            failures=$((failures + 1))
        fi
    done

    if [ "$failures" -gt 0 ]; then
        die "${failures} codex job(s) failed."
    fi

    log "All typecheck fixes completed."
}

main "$@"
