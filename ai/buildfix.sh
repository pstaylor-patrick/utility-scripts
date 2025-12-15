#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ai/lib/provider.sh
. "${SCRIPT_DIR}/lib/provider.sh"
# shellcheck source=ai/lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=ai/lib/codex.sh
. "${SCRIPT_DIR}/lib/codex.sh"

LOCKFILE_DIR=""
MAX_ROUNDS=3
BUILD_CMD=""

usage() {
    echo "Usage: $(basename "$0") [-c] [-d] [-x] [-h]"
    echo "  -c  use Claude Code CLI for AI operations"
    echo "  -d  use DeepSeek API for AI operations"
    echo "  -x  use OpenAI Codex for AI operations (default)"
    echo "  -h  show this help message"
}

build_script_name() {
  find_package_script "build" "build:ci"
}

launch_ai_fix() {
  local log_file="$1"
  local exit_code="$2"

  local log_body
  log_body=$(cat "$log_file")

  local prompt
  prompt=$(cat <<EOF
You are an expert developer fixing build failures directly in the current repository.
Workdir: $(pwd)

Build command: ${BUILD_CMD}
Last exit code: ${exit_code}

Full build output:
${log_body}

Use the build log to identify the failing code and apply changes in the workspace so the build succeeds. Do not ignore or skip steps the build requires.
EOF
)

  log "[buildfix] sending build log to ${AI_BACKEND}"
  if ai_exec "$prompt"; then
    log "[buildfix] ${AI_BACKEND} edits applied"
  else
    return 1
  fi
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

  local script_name
  if ! script_name=$(build_script_name); then
    die "No build script found (tried \"build\", \"build:ci\" in package.json)."
  fi

  if ! BUILD_CMD=$(build_pm_command "$pm" "$script_name"); then
    die "Failed to build build command."
  fi

  log "Using AI backend: ${AI_BACKEND}"
  if [ -n "$LOCKFILE_DIR" ] && [ "$LOCKFILE_DIR" != "$PWD" ]; then
    log "Using package manager: ${pm} (lockfile at ${LOCKFILE_DIR})"
  else
    log "Using package manager: ${pm}"
  fi
  log "Build command: ${BUILD_CMD}"
  log "AI provider: $(ai_provider_name)"

  local round=1
  while [ "$round" -le "$MAX_ROUNDS" ]; do
    log "Round ${round}/${MAX_ROUNDS}: running build"

    local build_log
    build_log=$(mktemp)

    set +e
    eval "$BUILD_CMD" 2>&1 | tee "$build_log"
    local build_status="${PIPESTATUS[0]}"
    set -euo pipefail

    if [ "$build_status" -eq 0 ]; then
      log "Build finished cleanly on round ${round}; no fixes needed."
      exit 0
    fi

    log "Build failed (exit ${build_status}); log saved to ${build_log}"
    if ! launch_ai_fix "$build_log" "$build_status"; then
      die "${AI_BACKEND} buildfix failed."
    fi

    if [ "$round" -eq "$MAX_ROUNDS" ]; then
      log "Reached max buildfix rounds (${MAX_ROUNDS}); rerun ${BUILD_CMD} to confirm clean output."
      exit 0
    fi

    round=$((round + 1))
  done
}

main "$@"
