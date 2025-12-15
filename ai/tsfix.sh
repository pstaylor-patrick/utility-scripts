#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ai/lib/provider.sh
. "${SCRIPT_DIR}/lib/provider.sh"
# shellcheck source=ai/lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=ai/lib/codex.sh
. "${SCRIPT_DIR}/lib/codex.sh"

DELIM=$'\x1f'
ISSUES=()
JOB_PIDS=()
FILE_KEYS=()
FILE_ISSUES=()
ISSUE_TOTAL=0
LOCKFILE_DIR=""
MAX_ROUNDS=3

usage() {
    echo "Usage: $(basename "$0") [-c] [-d] [-x] [-h]"
    echo "  -c  use Claude Code CLI for AI operations"
    echo "  -d  use DeepSeek API for AI operations"
    echo "  -x  use OpenAI Codex for AI operations (default)"
    echo "  -h  show this help message"
}

typecheck_command_for() {
  local pm="$1"
  local script_name="$2"
  build_pm_command "$pm" "$script_name"
}

typecheck_script_name() {
  find_package_script "typecheck" "type-check"
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

launch_ai_fix() {
  local file_path="$1"
  local issues="$2"

  local friendly_name
  friendly_name=$(friendly_name_from_path "$file_path")

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

  local label
  label=$(codex_label_from_prompt "$summary_prompt" "${friendly_name} type fixes")

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

  codex_stream_with_label "$label" "$prompt" &
  JOB_PIDS+=("$!")
}

main() {
    while getopts ":cdxh" opt; do
        case "$opt" in
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

    ai_require_provider

    local pm
    if ! pm=$(detect_package_manager); then
        die "No supported lockfile found (package-lock.json, pnpm-lock.yaml, bun.lockb)."
    fi

    local type_script
    if ! type_script=$(typecheck_script_name); then
        die "No typecheck script found (expected \"typecheck\" or \"type-check\" in package.json)."
    fi

    local type_cmd
    if ! type_cmd=$(typecheck_command_for "$pm" "$type_script"); then
        die "Failed to build typecheck command."
    fi

    log "Using AI backend: ${AI_BACKEND}"
    if [ -n "$LOCKFILE_DIR" ] && [ "$LOCKFILE_DIR" != "$PWD" ]; then
        log "Using package manager: ${pm} (lockfile at ${LOCKFILE_DIR})"
    else
        log "Using package manager: ${pm}"
    fi
    log "Typecheck command: ${type_cmd}"
    log "AI provider: $(ai_provider_name)"

    local round=1
    while [ "$round" -le "$MAX_ROUNDS" ]; do
        log "Round ${round}/${MAX_ROUNDS}: running typecheck"

        ISSUES=()
        JOB_PIDS=()
        FILE_KEYS=()
        FILE_ISSUES=()
        ISSUE_TOTAL=0

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
                log "Typecheck finished cleanly on round ${round}; no issues to fix."
                exit 0
            fi
            log "Typecheck exited with status ${type_status} but no parseable issues were found. See ${type_log}."
            exit "$type_status"
        fi

        log "Launching ${file_count} ${AI_BACKEND} worker(s) in parallel for ${ISSUE_TOTAL} issue(s)."

        for idx in "${!FILE_KEYS[@]}"; do
            local file_path="${FILE_KEYS[$idx]}"
            local file_issues="${FILE_ISSUES[$idx]}"
            launch_ai_fix "$file_path" "$file_issues"
        done

        local failures=0
        for pid in "${JOB_PIDS[@]}"; do
            if ! wait "$pid"; then
                failures=$((failures + 1))
            fi
        done

        if [ "$failures" -gt 0 ]; then
            die "${failures} ${AI_BACKEND} job(s) failed."
        fi

        if [ "$round" -eq "$MAX_ROUNDS" ]; then
            log "Reached max tsfix rounds (${MAX_ROUNDS}); rerun typecheck to confirm clean output."
            exit 0
        fi

        round=$((round + 1))
    done
}

main "$@"
