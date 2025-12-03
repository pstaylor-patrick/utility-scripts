#!/usr/bin/env bash

set -euo pipefail

LOG_SEP=$'\n---\n'
FILE_KEYS=()
FILE_ISSUES=()
JOB_PIDS=()
ISSUE_TOTAL=0
TEST_CMD=""
LOCKFILE_DIR=""

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
    local dir="$PWD"
    while :; do
        if [ -f "${dir}/package-lock.json" ]; then
            LOCKFILE_DIR="$dir"
            echo "npm"
            return 0
        fi
        if [ -f "${dir}/pnpm-lock.yaml" ]; then
            LOCKFILE_DIR="$dir"
            echo "pnpm"
            return 0
        fi
        if [ -f "${dir}/bun.lockb" ]; then
            LOCKFILE_DIR="$dir"
            echo "bun"
            return 0
        fi
        if [ "$dir" = "/" ]; then
            break
        fi
        dir=$(dirname "$dir")
    done
    return 1
}

test_script_name() {
    if [ ! -f "package.json" ]; then
        return 1
    fi

    local candidates=("test" "test:ci" "test:unit")
    local script_name=""

    if command -v node >/dev/null 2>&1; then
        script_name=$(node - <<'NODE' || true
const fs = require('fs');
const candidates = ["test", "test:ci", "test:unit"];
try {
  const pkg = JSON.parse(fs.readFileSync('package.json', 'utf8'));
  const scripts = pkg.scripts || {};
  for (const name of candidates) {
    if (Object.prototype.hasOwnProperty.call(scripts, name)) {
      console.log(name);
      process.exit(0);
    }
  }
} catch (_) {}
NODE
)
    fi

    if [ -z "$script_name" ] && command -v python3 >/dev/null 2>&1; then
        script_name=$(python3 - <<'PY' || true
import json
from pathlib import Path
candidates = ["test", "test:ci", "test:unit"]
try:
    pkg = json.loads(Path("package.json").read_text())
    scripts = pkg.get("scripts") or {}
    for name in candidates:
        if name in scripts:
            print(name)
            break
except Exception:
    pass
PY
)
    fi

    if [ -n "$script_name" ]; then
        echo "$script_name"
        return 0
    fi

    return 1
}

test_command_for() {
    local pm="$1"
    local script="$2"
    case "$pm" in
        npm) echo "npm run ${script}" ;;
        pnpm) echo "pnpm run ${script}" ;;
        bun) echo "bun run ${script}" ;;
        *) return 1 ;;
    esac
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
    friendly=$(basename "$file_path")
    friendly="${friendly%.*}"
    friendly=$(printf "%s" "$friendly" | sed 's/[][_-]/ /g; s/[[:space:]]\+/ /g; s/^ //; s/ $//')
    [ -z "$friendly" ] && friendly="this file"

    local parent_dir
    parent_dir=$(basename "$(dirname "$file_path")")
    if [ -n "$parent_dir" ] && [ "$parent_dir" != "." ] && [ "$parent_dir" != "$(basename "$PWD")" ]; then
        friendly="${parent_dir} ${friendly}"
    fi

    local label="${friendly} tests"
    label=$(printf "%s" "$label" | tr '\n' ' ' | tr '\t' ' ' | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')
    if [ "${#label}" -gt 50 ]; then
        label="${label:0:47}..."
    fi
    local prefix="[$label]"

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
    log "Running test script \"${test_script}\": ${TEST_CMD}"

    local test_log
    test_log=$(mktemp)

    set +e
    eval "$TEST_CMD" 2>&1 | tee "$test_log"
    local test_status="${PIPESTATUS[0]}"
    set -euo pipefail

    if [ "$test_status" -eq 0 ]; then
        log "Tests finished cleanly; no failures detected."
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

    log "All test fixes completed."
}

main "$@"
