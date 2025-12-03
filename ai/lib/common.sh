#!/usr/bin/env bash

# Common helpers shared by ai/* fixer scripts.

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

# Sets global LOCKFILE_DIR to the dir containing the detected lockfile.
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

build_pm_command() {
  local pm="$1"
  local script="$2"
  case "$pm" in
    npm) echo "npm run ${script}" ;;
    pnpm) echo "pnpm run ${script}" ;;
    bun) echo "bun run ${script}" ;;
    *) return 1 ;;
  esac
}

find_package_script() {
  local candidates=("$@")
  if [ ! -f "package.json" ] || [ "${#candidates[@]}" -eq 0 ]; then
    return 1
  fi

  local script_name=""

  if command -v node >/dev/null 2>&1; then
    script_name=$(node - "${candidates[@]}" <<'NODE' || true
const fs = require('fs');
const candidates = process.argv.slice(1);
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
process.exit(1);
NODE
)
  fi

  if [ -z "$script_name" ] && command -v python3 >/dev/null 2>&1; then
    script_name=$(python3 - "${candidates[@]}" <<'PY' || true
import json
import sys
from pathlib import Path
candidates = sys.argv[1:]
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

  script_name=$(printf "%s" "$script_name" | sed -n '1p' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  if [ -n "$script_name" ]; then
    printf "%s\n" "$script_name"
    return 0
  fi

  return 1
}

friendly_name_from_path() {
  local file_path="$1"
  local include_parent="${2:-1}"

  local friendly
  friendly=$(basename "$file_path")
  friendly="${friendly%.*}"
  friendly=$(printf "%s" "$friendly" | sed 's/[][_-]/ /g; s/[[:space:]]\+/ /g; s/^ //; s/ $//')
  [ -z "$friendly" ] && friendly="this file"

  if [ "$include_parent" != "0" ]; then
    local parent_dir
    parent_dir=$(basename "$(dirname "$file_path")")
    if [ -n "$parent_dir" ] && [ "$parent_dir" != "." ] && [ "$parent_dir" != "$(basename "$PWD")" ]; then
      friendly="${parent_dir} ${friendly}"
      friendly=$(printf "%s" "$friendly" | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')
    fi
  fi

  printf "%s\n" "$friendly"
}

clamp_label() {
  local label="$1"
  local max_len="${2:-50}"
  label=$(printf "%s" "$label" | tr '\n' ' ' | tr '\t' ' ' | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')
  if [ "${#label}" -gt "$max_len" ]; then
    label="${label:0:$((max_len - 3))}..."
  fi
  printf "%s\n" "$label"
}
