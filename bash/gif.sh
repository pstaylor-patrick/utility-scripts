#!/usr/bin/env bash

# built with ffmpeg version 7.1 Copyright (c) 2000-2024 the FFmpeg developers
# https://github.com/FFmpeg/FFmpeg
# brew install ffmpeg

# Function to compare version numbers
version_gte() {
    # Compare two version numbers
    [ "$(printf '%s\n' "$1" "$2" | sort -V | head -n1)" = "$2" ]
}

# Get the current ffmpeg version
current_version=$(ffmpeg -version | head -n1 | awk '{print $3}')

# Required version
required_version="7.1"

# Check if the current version is greater than or equal to the required version
if ! version_gte "$current_version" "$required_version"; then
    echo "ffmpeg version $required_version or higher is required. Current version is $current_version."
    exit 1
fi

# Check if an argument is provided
if [ -z "$1" ]; then
    echo "Usage: $0 <input_video_file> [low|mid|high|all]"
    exit 1
fi

# Get the input file path
input_file="$1"

# Check if file is not an MP4, convert it first
extension="${input_file##*.}"
extension_lower=$(echo "$extension" | tr '[:upper:]' '[:lower:]')
if [[ "$extension_lower" != "mp4" ]]; then
    echo "Input is not an MP4. Converting first..."
    script_dir="$(dirname "$0")"
    "$script_dir/convert_half_24fps.sh" "$input_file"

    # Determine the output filename from convert_half_24fps.sh
    base="${input_file%.*}"
    # Check which output was created (with or without -half suffix)
    if [[ -f "${base}-24fps-half.mp4" ]]; then
        input_file="${base}-24fps-half.mp4"
    elif [[ -f "${base}-24fps.mp4" ]]; then
        input_file="${base}-24fps.mp4"
    else
        echo "Error: Conversion failed, MP4 output not found."
        exit 1
    fi
    echo "Using converted file: $input_file"
fi

# Set default resolution to all (renders low, mid, and high)
resolution="all"

# Check if a resolution flag is provided
if [ ! -z "$2" ]; then
    case "$2" in
        low|mid|high|all)
            resolution="$2"
            ;;
        *)
            echo "Invalid resolution option. Use low, mid, high, or all."
            exit 1
            ;;
    esac
fi

# Extract the directory and base name from the input file
output_dir=$(dirname "$input_file")
output_base=$(basename "$input_file" | sed 's/\.[^.]*$//')

# Process based on resolution
case "$resolution" in
    low)
        output_file="$output_dir/$output_base low.gif"
        ffmpeg -y -i "$input_file" -vf "fps=10,scale=600:-1:flags=lanczos" -an -c:v gif "$output_file"
        ;;
    mid)
        output_file="$output_dir/$output_base mid.gif"
        ffmpeg -y -i "$input_file" -vf "fps=10,scale=600:-1:flags=lanczos,split[s0][s1];[s1]palettegen[p];[s0][p]paletteuse" -an "$output_file"
        ;;
    high)
        output_file="$output_dir/$output_base high.gif"
        ffmpeg -y -i "$input_file" -vf "fps=15,scale=800:-1:flags=lanczos,split[s0][s1];[s1]palettegen[p];[s0][p]paletteuse" -an "$output_file"
        ;;
    all)
        echo "Rendering low resolution..."
        ffmpeg -y -i "$input_file" -vf "fps=10,scale=600:-1:flags=lanczos" -an -c:v gif "$output_dir/$output_base low.gif"
        echo "Rendering mid resolution..."
        ffmpeg -y -i "$input_file" -vf "fps=10,scale=600:-1:flags=lanczos,split[s0][s1];[s1]palettegen[p];[s0][p]paletteuse" -an "$output_dir/$output_base mid.gif"
        echo "Rendering high resolution..."
        ffmpeg -y -i "$input_file" -vf "fps=15,scale=800:-1:flags=lanczos,split[s0][s1];[s1]palettegen[p];[s0][p]paletteuse" -an "$output_dir/$output_base high.gif"
        ;;
esac
