#!/usr/bin/env bash
# Park a repo: harvest gitignored extras to NAS sidecar, then delete local clone.
# Usage: repo-park <area>/<org>/<repo>
#   e.g. repo-park pst/ShirePath-Solutions/league-os
set -euo pipefail

NAS_EXTRAS="/Volumes/home/2-resources/repo-extras"
CODE_ROOT="${HOME}/code"

if [[ $# -lt 1 ]]; then
  echo "Usage: repo-park <area>/<org>/<repo>"
  exit 1
fi

REPO_PATH="$1"
LOCAL_DIR="${CODE_ROOT}/${REPO_PATH}"

if [[ ! -d "$LOCAL_DIR" ]]; then
  echo "ERROR: ${LOCAL_DIR} does not exist."
  exit 1
fi

if [[ ! -d "${LOCAL_DIR}/.git" ]]; then
  echo "ERROR: ${LOCAL_DIR} is not a git repo."
  exit 1
fi

# Abort on uncommitted changes
if ! git -C "$LOCAL_DIR" diff --quiet || ! git -C "$LOCAL_DIR" diff --cached --quiet; then
  echo "ERROR: ${REPO_PATH} has uncommitted changes. Commit or stash before parking."
  git -C "$LOCAL_DIR" status --short
  exit 1
fi

# Warn on unpushed commits
UNPUSHED=$(git -C "$LOCAL_DIR" log --oneline @{u}..HEAD 2>/dev/null || true)
if [[ -n "$UNPUSHED" ]]; then
  echo "WARNING: ${REPO_PATH} has unpushed commits:"
  echo "$UNPUSHED"
  read -r -p "Continue parking anyway? [y/N] " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || exit 1
fi

# Harvest gitignored extras (all .env* files, excluding .example/.sample)
SIDECAR_DIR="${NAS_EXTRAS}/${REPO_PATH}"
HARVESTED=0

while IFS= read -r -d '' file; do
  basename=$(basename "$file")
  [[ "$basename" == *.example ]] && continue
  [[ "$basename" == *.sample ]] && continue
  rel="${file#${LOCAL_DIR}/}"
  dest="${SIDECAR_DIR}/${rel}"
  mkdir -p "$(dirname "$dest")"
  cp -X "$file" "$dest"
  echo "  harvested: ${rel}"
  HARVESTED=$((HARVESTED + 1))
done < <(find "$LOCAL_DIR" -not -path '*/.git/*' -name ".env*" -print0 2>/dev/null)

if [[ $HARVESTED -eq 0 ]]; then
  echo "  (no .env files found to harvest)"
fi

# Record the GitHub remote so checkout can re-clone without user input
REMOTE_URL=$(git -C "$LOCAL_DIR" remote get-url origin 2>/dev/null || true)
if [[ -n "$REMOTE_URL" ]]; then
  mkdir -p "$SIDECAR_DIR"
  echo "$REMOTE_URL" > "${SIDECAR_DIR}/.remote-url"
  echo "  remote: ${REMOTE_URL}"
fi

echo ""
echo "Deleting ${LOCAL_DIR}..."
rm -rf "$LOCAL_DIR"
echo "Parked. ${REPO_PATH} removed locally; sidecar at ${SIDECAR_DIR}"
