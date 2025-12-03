#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ai/lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=ai/lib/codex.sh
. "${SCRIPT_DIR}/lib/codex.sh"

LOG_SEP=$'\n---\n'
FILE_KEYS=()
FILE_ISSUES=()
JOB_PIDS=()
ISSUE_TOTAL=0
TEST_CMD=""
LOCKFILE_DIR=""
MAX_ROUNDS=3

test_script_name() {
  find_package_script "test" "test:ci" "test:unit"
}

test_command_for() {
  local pm="$1"
  local script="$2"
  build_pm_command "$pm" "$script"
}

ensure_file_entry() {
    local file="$1"
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
    echo "$idx"
}

append_issue_line() {
    local idx="$1"
    local line="$2"
    if [ -n "${FILE_ISSUES[$idx]-}" ]; then
        FILE_ISSUES[$idx]="${FILE_ISSUES[$idx]}$LOG_SEP${line}"
    else
        FILE_ISSUES[$idx]="$line"
    fi
}

codex_extract_files() {
    local log_file="$1"
    local log_body
    log_body=$(cat "$log_file")

    local prompt
    prompt=$(cat <<EOF
Given the following test output, list the distinct test file paths that have failing tests. Return only the paths, one per line, no bullets, no extra text.

Test output:
${log_body}
EOF
)

    local output
    if ! output=$(codex exec "$prompt" 2>/dev/null); then
        return 1
    fi

    output=$(printf "%s" "$output" | sed '/^```/d; /^---$/d' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')

    local added=0
    while IFS= read -r line; do
        line=$(printf "%s" "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
        line=$(printf "%s" "$line" | sed 's/^[0-9][0-9]*[).[:space:]]*//; s/^[-*][[:space:]]*//')
        [ -z "$line" ] && continue
        ensure_file_entry "$line" >/dev/null
        added=1
    done <<< "$output"

    if [ "$added" -eq 0 ]; then
        log "Codex did not return any failing file paths. Raw Codex output:"
        printf "%s\n" "$output" >&2
        return 1
    fi

    return 0
}

parse_fail_blocks() {
    local log_file="$1"
    local current_idx=-1
    while IFS= read -r line; do
        if [[ "$line" =~ ^[[:space:]]*FAIL[[:space:]]+([^[:space:]]+) ]]; then
            local file_path="${BASH_REMATCH[1]}"
            current_idx=$(ensure_file_entry "$file_path")
            append_issue_line "$current_idx" "$line"
            ISSUE_TOTAL=$((ISSUE_TOTAL + 1))
            continue
        fi
        if [ "$current_idx" -ge 0 ]; then
            append_issue_line "$current_idx" "$line"
        fi
    done < "$log_file"
}

launch_codex_fix() {
  local file_path="$1"
  local issues="$2"

  local friendly
  friendly=$(friendly_name_from_path "$file_path")

  local label
  label=$(clamp_label "${friendly} tests")

  local prompt
  prompt=$(cat <<EOF
You are an expert developer fixing automated test failures directly in the current repository.
Workdir: $(pwd)

Test command: ${TEST_CMD}
Failing test file: ${file_path}

Relevant failure output:
${issues}

Fix the underlying code and/or tests so the tests in this file pass. Do not skip, delete, or silence tests unless they are invalid. Apply edits directly in the workspace.
EOF
)

  codex_stream_with_label "$label" "$prompt" &
  JOB_PIDS+=("$!")
}

generate_report() {
    local log_file="$1"

    local log_body
    log_body=$(cat "$log_file")

    local prompt
    prompt=$(cat <<EOF
You are summarizing automated test failures.

Create concise markdown with:
- Heading per failing test file path: "## <path>"
- Under each heading, bullet list failing test names with a short error gist (one line each, <=120 chars).
- Include only failing files; no extra commentary or code fences.

Test output:
${log_body}
EOF
)

    local summary_header="# Test failure summary ($(date '+%Y-%m-%d %H:%M:%S'))"
    local codex_out=""
    if ! codex_out=$(codex exec "$prompt" 2>/dev/null); then
        codex_out=""
    fi

    codex_out=$(printf "%s" "$codex_out" | sed '/^```/d; /^---$/d')

    if [ -z "$(printf "%s" "$codex_out" | tr -d '[:space:]')" ]; then
        log "Codex summary failed; falling back to file list."
        local files
        files=$(grep -E '^ FAIL ' "$log_file" | awk '{print $2}' | sort -u)
        local fallback=""
        fallback+="${summary_header}\n\n"
        for f in $files; do
            fallback+="## ${f}\n- see test log ${log_file} for details\n\n"
        done
        printf "%b" "$fallback"
        return 0
    fi

    printf "%s\n\n%s\n" "$summary_header" "$codex_out"
}

main() {
    require_cmd codex

    local pm
    if ! pm=$(detect_package_manager); then
        die "No supported lockfile found (package-lock.json, pnpm-lock.yaml, bun.lockb)."
    fi

    local test_script
    if ! test_script=$(test_script_name); then
        die "No test script found (tried \"test\", \"test:ci\", \"test:unit\" in package.json)."
    fi

    if ! TEST_CMD=$(test_command_for "$pm" "$test_script"); then
        die "Failed to build test command."
    fi

    if [ -n "$LOCKFILE_DIR" ] && [ "$LOCKFILE_DIR" != "$PWD" ]; then
        log "Using package manager: ${pm} (lockfile at ${LOCKFILE_DIR})"
    else
        log "Using package manager: ${pm}"
    fi
    log "Test command: ${TEST_CMD}"

    local round=1
    while [ "$round" -le "$MAX_ROUNDS" ]; do
        log "Round ${round}/${MAX_ROUNDS}: running tests"

        FILE_KEYS=()
        FILE_ISSUES=()
        JOB_PIDS=()
        ISSUE_TOTAL=0

        local test_log
        test_log=$(mktemp)

        set +e
        eval "$TEST_CMD" 2>&1 | tee "$test_log"
        local test_status="${PIPESTATUS[0]}"
        set -euo pipefail

        if [ "$test_status" -eq 0 ]; then
            log "Tests finished cleanly on round ${round}; no failures detected."
            exit 0
        fi

        # Identify failing files (prefer Codex, then fallback parse)
        if ! codex_extract_files "$test_log"; then
            log "Codex-based failure detection returned no files; falling back to regex parsing."
        fi
        parse_fail_blocks "$test_log"

        local file_count="${#FILE_KEYS[@]}"
        if [ "$file_count" -eq 0 ]; then
            log "Tests failed (exit ${test_status}) but no parseable failures were found. See ${test_log}."
            exit "$test_status"
        fi

        log "Tests failed (exit ${test_status}); generating summary."
        local summary
        summary=$(generate_report "$test_log")
        printf "\n%s\n" "$summary"
        log "Raw test log: ${test_log}"

        log "Launching ${file_count} codex worker(s) in parallel for ${ISSUE_TOTAL} failure section(s)."
        for idx in "${!FILE_KEYS[@]}"; do
            local file_path="${FILE_KEYS[$idx]}"
            local file_issues="${FILE_ISSUES[$idx]-}"
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

        if [ "$round" -eq "$MAX_ROUNDS" ]; then
            log "Reached max testfix rounds (${MAX_ROUNDS}); rerun ${TEST_CMD} to confirm clean output."
            exit 0
        fi

        round=$((round + 1))
    done
}

main "$@"
