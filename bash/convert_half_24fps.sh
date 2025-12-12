#!/usr/bin/env bash

# Convert a video to MP4 at 24 fps, half the original dimensions, and drop audio.
# Usage: ./convert_half_24fps.sh input_file [output_file]

set -euo pipefail

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "Error: ffmpeg is not installed or not in PATH." >&2
  exit 1
fi

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 input_file [output_file]" >&2
  exit 1
fi

input=$1
if [[ ! -f "$input" ]]; then
  echo "Error: input file '$input' not found." >&2
  exit 1
fi

base="${input%.*}"
output="${2:-${base}-24fps-half.mp4}"

if [[ -e "$output" ]]; then
  echo "Error: output file '$output' already exists. Choose a different name or remove the existing file." >&2
  exit 1
fi

ffmpeg -i "$input" \
  -vf "scale=iw/2:ih/2,fps=24" \
  -an \
  -c:v libx264 -preset medium -crf 23 \
  -pix_fmt yuv420p \
  -movflags +faststart \
  "$output"

echo "Done. Saved to: $output"
