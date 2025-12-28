#!/usr/bin/env bash

# Generate favicon variants from a source image.
# Usage: ./favicon.sh input_image
#
# Generates the following files in the current directory:
#   - favicon.ico (multi-resolution: 16x16, 32x32, 48x48)
#   - favicon-16x16.png, favicon-32x32.png
#   - apple-touch-icon.png (180x180), apple-touch-icon-152x152.png, apple-touch-icon-120x120.png
#   - android-chrome-192x192.png, android-chrome-512x512.png
#   - mstile-150x150.png

set -euo pipefail

# Check ImageMagick is installed
if ! command -v convert >/dev/null 2>&1; then
  echo "Error: ImageMagick is not installed. Run: brew install imagemagick" >&2
  exit 1
fi

# Validate arguments
if [[ $# -lt 1 ]]; then
  echo "Usage: $0 input_image" >&2
  echo "Supported formats: png, jpg, jpeg, gif, webp, tiff, tif, bmp" >&2
  exit 1
fi

input="$1"

# Check input file exists
if [[ ! -f "$input" ]]; then
  echo "Error: input file '$input' not found." >&2
  exit 1
fi

# Validate supported image format
ext="${input##*.}"
ext_lower=$(echo "$ext" | tr '[:upper:]' '[:lower:]')
case "$ext_lower" in
  png|jpg|jpeg|gif|webp|tiff|tif|bmp) ;;
  *)
    echo "Error: Unsupported image format '.$ext'." >&2
    echo "Supported formats: png, jpg, jpeg, gif, webp, tiff, tif, bmp" >&2
    exit 1
    ;;
esac

# Define all output files
output_files=(
  "favicon.ico"
  "favicon-16x16.png"
  "favicon-32x32.png"
  "apple-touch-icon.png"
  "apple-touch-icon-152x152.png"
  "apple-touch-icon-120x120.png"
  "android-chrome-192x192.png"
  "android-chrome-512x512.png"
  "mstile-150x150.png"
)

# Check if any output files already exist
existing_files=()
for file in "${output_files[@]}"; do
  if [[ -e "$file" ]]; then
    existing_files+=("$file")
  fi
done

if [[ ${#existing_files[@]} -gt 0 ]]; then
  echo "Error: The following output files already exist:" >&2
  for file in "${existing_files[@]}"; do
    echo "  - $file" >&2
  done
  echo "Remove them first or run from a different directory." >&2
  exit 1
fi

# Check source image dimensions and warn if too small
dimensions=$(identify -format "%wx%h" "$input" 2>/dev/null) || {
  echo "Error: Could not read image dimensions from '$input'." >&2
  exit 1
}
width="${dimensions%x*}"
height="${dimensions#*x}"

if [[ "$width" -lt 512 || "$height" -lt 512 ]]; then
  echo "Warning: Source image is ${width}x${height}. For best results, use an image at least 512x512." >&2
fi

echo "Generating favicons from '$input'..."

# Generate favicon.ico with multiple resolutions embedded
convert "$input" -resize 48x48 -define icon:auto-resize=48,32,16 favicon.ico
echo "  Created favicon.ico"

# Generate PNG favicons
convert "$input" -resize 16x16 favicon-16x16.png
echo "  Created favicon-16x16.png"

convert "$input" -resize 32x32 favicon-32x32.png
echo "  Created favicon-32x32.png"

# Generate Apple touch icons
convert "$input" -resize 180x180 apple-touch-icon.png
echo "  Created apple-touch-icon.png"

convert "$input" -resize 152x152 apple-touch-icon-152x152.png
echo "  Created apple-touch-icon-152x152.png"

convert "$input" -resize 120x120 apple-touch-icon-120x120.png
echo "  Created apple-touch-icon-120x120.png"

# Generate Android/PWA icons
convert "$input" -resize 192x192 android-chrome-192x192.png
echo "  Created android-chrome-192x192.png"

convert "$input" -resize 512x512 android-chrome-512x512.png
echo "  Created android-chrome-512x512.png"

# Generate Microsoft tile
convert "$input" -resize 150x150 mstile-150x150.png
echo "  Created mstile-150x150.png"

echo ""
echo "Done! Generated ${#output_files[@]} favicon files."
echo ""
echo "Add the following to your HTML <head>:"
echo ""
cat <<'EOF'
<link rel="icon" type="image/x-icon" href="/favicon.ico">
<link rel="icon" type="image/png" sizes="32x32" href="/favicon-32x32.png">
<link rel="icon" type="image/png" sizes="16x16" href="/favicon-16x16.png">
<link rel="apple-touch-icon" sizes="180x180" href="/apple-touch-icon.png">
<link rel="manifest" href="/site.webmanifest">
<meta name="msapplication-TileImage" content="/mstile-150x150.png">
EOF
