#!/usr/bin/env bash

set -euo pipefail

LOCKFILE_DIR=""
MAX_ROUNDS=3
BUILD_CMD=""

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

build_command_for() {
  local pm="$1"
  local script_name="$2"
  case "$pm" in
    npm) echo "npm run ${script_name}" ;;
    pnpm) echo "pnpm run ${script_name}" ;;
    bun) echo "bun run ${script_name}" ;;
    *) return 1 ;;
  esac
}

build_script_name() {
  if [ ! -f "package.json" ]; then
    return 1
  fi

  local candidates=("build" "build:ci")
  local script_name=""

  if command -v node >/dev/null 2>&1; then
    script_name=$(node - <<'NODE' || true
const fs = require('fs');
const candidates = ["build", "build:ci"];
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
candidates = ["build", "build:ci"]
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

  if ! BUILD_CMD=$(build_command_for "$pm" "$script_name"); then
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
