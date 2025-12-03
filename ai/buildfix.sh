#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ai/lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=ai/lib/codex.sh
. "${SCRIPT_DIR}/lib/codex.sh"

LOCKFILE_DIR=""
MAX_ROUNDS=3
BUILD_CMD=""

build_script_name() {
  find_package_script "build" "build:ci"
}

launch_codex_fix() {
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

  log "[buildfix] sending build log to Codex"
  if codex exec "$prompt"; then
    log "[buildfix] Codex edits applied"
  else
    return 1
  fi
}

main() {
  require_cmd codex

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

  if [ -n "$LOCKFILE_DIR" ] && [ "$LOCKFILE_DIR" != "$PWD" ]; then
    log "Using package manager: ${pm} (lockfile at ${LOCKFILE_DIR})"
  else
    log "Using package manager: ${pm}"
  fi
  log "Build command: ${BUILD_CMD}"

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
    if ! launch_codex_fix "$build_log" "$build_status"; then
      die "Codex buildfix failed."
    fi

    if [ "$round" -eq "$MAX_ROUNDS" ]; then
      log "Reached max buildfix rounds (${MAX_ROUNDS}); rerun ${BUILD_CMD} to confirm clean output."
      exit 0
    fi

    round=$((round + 1))
  done
}

main "$@"
