#!/usr/bin/env bash

# Convert a video to MP4 at 24 fps, half the original dimensions, and drop audio.
# If halving would result in odd dimensions (incompatible with libx264), scaling is skipped.
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

# Get video dimensions using ffprobe
dimensions=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 "$input")
width=$(echo "$dimensions" | cut -d',' -f1)
height=$(echo "$dimensions" | cut -d',' -f2)

# Check if halving would result in even dimensions (width and height must be divisible by 4)
if (( width % 4 == 0 && height % 4 == 0 )); then
  vf_filter="scale=iw/2:ih/2,fps=24"
  output="${2:-${base}-24fps-half.mp4}"
else
  echo "Warning: Dimensions ${width}x${height} would result in odd values when halved. Skipping scaling." >&2
  vf_filter="fps=24"
  output="${2:-${base}-24fps.mp4}"
fi

if [[ -e "$output" ]]; then
  echo "Error: output file '$output' already exists. Choose a different name or remove the existing file." >&2
  exit 1
fi

ffmpeg -i "$input" \
  -vf "$vf_filter" \
  -an \
  -c:v libx264 -preset medium -crf 23 \
  -pix_fmt yuv420p \
  -movflags +faststart \
  "$output"

echo "Done. Saved to: $output"
