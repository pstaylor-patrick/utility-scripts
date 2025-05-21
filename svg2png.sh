#!/usr/bin/env bash

set -euo pipefail

# 1. Install Homebrew if needed
if ! command -v brew >/dev/null 2>&1; then
  echo "➜ Homebrew not found. Installing Homebrew…"
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

# 2. Ensure homebrew is up to date and install librsvg
echo "➜ Updating Homebrew…"
brew update
echo "➜ Installing librsvg…"
brew install librsvg

# 3. Convert the SVG → PNG
if [[ $# -lt 1 ]]; then
  echo "Usage: $0 input.svg [output.png]"
  exit 1
fi

INPUT="${1}"
# If the user passes a second arg, use it; otherwise swap .svg → .png
if [[ $# -ge 2 ]]; then
  OUTPUT="${2}"
else
  OUTPUT="${INPUT%.*}.png"
fi

# Preprocess SVG: replace CSS variables with static values (light mode)
TMP_SVG=$(mktemp)
sed -e 's/fill="var(--primary-fill)"/fill="#fff"/g' \
    -e 's/fill="var(--secondary-fill)"/fill="#000"/g' \
    "${INPUT}" > "${TMP_SVG}"

echo "➜ Converting ${INPUT} → ${OUTPUT}…"
rsvg-convert -w 1000 -h 1000 "${TMP_SVG}" -o "${OUTPUT}"

rm "${TMP_SVG}"

echo "✅ Done! Saved to ${OUTPUT}"
