#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ai/lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=ai/lib/codex.sh
. "${SCRIPT_DIR}/lib/codex.sh"

# Delimiter unlikely to appear in lint messages; used to pack fields into array entries
DELIM=$'\x1f'
ISSUES=()
JOB_PIDS=()
FILE_KEYS=()
FILE_ISSUES=()
ISSUE_TOTAL=0
LOCKFILE_DIR=""
MAX_ROUNDS=3

usage() {
    echo "Usage: $(basename "$0") [-c] [-o] [-h]"
    echo "  -c  use Claude Code CLI for AI operations"
    echo "  -o  use OpenAI Codex for AI operations (default)"
    echo "  -h  show this help message"
}

lint_command_for() {
    case "$1" in
        npm) echo "npm run lint" ;;
        pnpm) echo "pnpm lint" ;;
        bun) echo "bun run lint" ;;
        *) return 1 ;;
    esac
}

parse_lint_output() {
    local log_file="$1"
    local current_file=""

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
        # Drop trailing whitespace for matching, keep raw for messages
        local line
        line=$(printf "%s" "$raw_line" | sed 's/[[:space:]]*$//')

        # Track current file only when the line clearly looks like a path
        case "$line" in
            ./*|/*)
                current_file="$line"
                continue
                ;;
            *)
                ;;
        esac

        # Match lint findings (e.g., "12:3  Warning: message")
        if [[ "$line" =~ ^[[:space:]]*([0-9]+):([0-9]+)[[:space:]]+([Ee]rror|[Ww]arning):?[[:space:]]+(.*)$ ]]; then
            if [ -z "$current_file" ]; then
                continue
            fi

            local line_num="${BASH_REMATCH[1]}"
            local col_num="${BASH_REMATCH[2]}"
            local level="${BASH_REMATCH[3]}"
            local message="${BASH_REMATCH[4]}"

            ISSUES+=("${current_file}${DELIM}${line_num}${DELIM}${col_num}${DELIM}${level}${DELIM}${message}")
            add_issue "$current_file" "$line_num" "$col_num" "$level" "$message"
        fi
    done < "$log_file"
}

launch_codex_fix() {
  local file_path="$1"
  local issues="$2"

  local friendly_name
  friendly_name=$(friendly_name_from_path "$file_path")

  local summary_prompt
  summary_prompt=$(cat <<EOF
Summarize these lint issues for one file in <=50 characters, single line, no quotes or code fences.
Use a short, semantic page/feature name (e.g., "homepage", "client detail page", "${friendly_name}") instead of the literal filename, plus the issue gist/count.
File: ${file_path}
Issues:
${issues}
Return only the summary text.
EOF
)

  local label
  label=$(codex_label_from_prompt "$summary_prompt" "${friendly_name} lint fixes")

  local prompt
  prompt=$(cat <<EOF
You are an expert developer fixing lint findings directly in the current repository.
Workdir: $(pwd)

Fix the following lint issues for the file:
${file_path}

Issues to address:
${issues}

Apply changes to resolve this lint issue without changing intended behavior. Run the necessary edits directly in the workspace.
EOF
)

  codex_stream_with_label "$label" "$prompt" &
  JOB_PIDS+=("$!")
}

main() {
    while getopts ":coh" opt; do
        case "$opt" in
            c)
                AI_BACKEND="claude"
                ;;
            o)
                AI_BACKEND="codex"
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

    require_ai_cmd

    local pm
    if ! pm=$(detect_package_manager); then
        die "No supported lockfile found (package-lock.json, pnpm-lock.yaml, bun.lockb)."
    fi

    local lint_cmd
    if ! lint_cmd=$(lint_command_for "$pm"); then
        die "Failed to build lint command."
    fi

    log "Using AI backend: ${AI_BACKEND}"
    if [ -n "$LOCKFILE_DIR" ] && [ "$LOCKFILE_DIR" != "$PWD" ]; then
        log "Using package manager: ${pm} (lockfile at ${LOCKFILE_DIR})"
    else
        log "Using package manager: ${pm}"
    fi
    log "Lint command: ${lint_cmd}"

    local round=1
    while [ "$round" -le "$MAX_ROUNDS" ]; do
        log "Round ${round}/${MAX_ROUNDS}: running lint"

        ISSUES=()
        JOB_PIDS=()
        FILE_KEYS=()
        FILE_ISSUES=()
        ISSUE_TOTAL=0

        local lint_log
        lint_log=$(mktemp)

        set +e
        eval "$lint_cmd" 2>&1 | tee "$lint_log"
        local lint_status="${PIPESTATUS[0]}"
        set -euo pipefail

        parse_lint_output "$lint_log"
        local file_count="${#FILE_KEYS[@]}"

        if [ "$file_count" -eq 0 ]; then
            if [ "$lint_status" -eq 0 ]; then
                log "Lint finished cleanly on round ${round}; no warnings or errors to fix."
                exit 0
            fi
            log "Lint exited with status ${lint_status} but no parseable issues were found. See ${lint_log}."
            exit "$lint_status"
        fi

        log "Launching ${file_count} ${AI_BACKEND} worker(s) in parallel for ${ISSUE_TOTAL} issue(s)."

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
            die "${failures} ${AI_BACKEND} job(s) failed."
        fi

        if [ "$round" -eq "$MAX_ROUNDS" ]; then
            log "Reached max lintfix rounds (${MAX_ROUNDS}); rerun lint to confirm clean output."
            exit 0
        fi

        round=$((round + 1))
    done
}

main "$@"
