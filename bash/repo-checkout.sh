#!/usr/bin/env bash
# Checkout a repo: clone from GitHub and restore NAS sidecar extras.
# Usage: repo-checkout <area>/<org>/<repo> [git-url]
#   e.g. repo-checkout pst/ShirePath-Solutions/league-os
#   If git-url is omitted, reads it from the NAS sidecar .remote-url file.
set -euo pipefail

NAS_EXTRAS="/Volumes/home/2-resources/repo-extras"
CODE_ROOT="${HOME}/code"

if [[ $# -lt 1 ]]; then
  echo "Usage: repo-checkout <area>/<org>/<repo> [git-url]"
  exit 1
fi

REPO_PATH="$1"
LOCAL_DIR="${CODE_ROOT}/${REPO_PATH}"
SIDECAR_DIR="${NAS_EXTRAS}/${REPO_PATH}"
GIT_URL="${2:-}"

if [[ -d "$LOCAL_DIR" ]]; then
  echo "ERROR: ${LOCAL_DIR} already exists. Remove it first if you want a fresh clone."
  exit 1
fi

# Resolve git URL
if [[ -z "$GIT_URL" ]]; then
  REMOTE_FILE="${SIDECAR_DIR}/.remote-url"
  if [[ ! -f "$REMOTE_FILE" ]]; then
    echo "ERROR: No git URL provided and no .remote-url found at ${REMOTE_FILE}."
    echo "       Pass the URL explicitly: repo-checkout ${REPO_PATH} <git-url>"
    exit 1
  fi
  GIT_URL=$(cat "$REMOTE_FILE")
fi

echo "Cloning ${GIT_URL} -> ${LOCAL_DIR}..."
mkdir -p "$(dirname "$LOCAL_DIR")"
git clone "$GIT_URL" "$LOCAL_DIR"

# Restore sidecar extras
if [[ -d "$SIDECAR_DIR" ]]; then
  RESTORED=0
  while IFS= read -r -d '' file; do
    basename=$(basename "$file")
    [[ "$basename" == ".remote-url" ]] && continue
    rel="${file#${SIDECAR_DIR}/}"
    dest="${LOCAL_DIR}/${rel}"
    mkdir -p "$(dirname "$dest")"
    cp -X "$file" "$dest"
    echo "  restored: ${rel}"
    RESTORED=$((RESTORED + 1))
  done < <(find "$SIDECAR_DIR" -type f -print0 2>/dev/null)
  [[ $RESTORED -eq 0 ]] && echo "  (no sidecar extras to restore)"
else
  echo "  (no sidecar found at ${SIDECAR_DIR})"
fi

echo ""
echo "Done. ${REPO_PATH} ready at ${LOCAL_DIR}"
