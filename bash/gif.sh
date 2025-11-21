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
    echo "Usage: $0 <input_video_file> [low|mid|high]"
    exit 1
fi

# Get the input file path
input_file="$1"

# Set default resolution to high
resolution="high"

# Check if a resolution flag is provided
if [ ! -z "$2" ]; then
    case "$2" in
        low|mid|high)
            resolution="$2"
            ;;
        *)
            echo "Invalid resolution option. Use low, mid, or high."
            exit 1
            ;;
    esac
fi

# Extract the directory and base name from the input file
output_dir=$(dirname "$input_file")
output_base=$(basename "$input_file" | sed 's/\.[^.]*$//')

# Construct the output file path
if [ "$resolution" = "high" ] && [ -z "$2" ]; then
    output_file="$output_dir/$output_base.gif"
else
    output_file="$output_dir/$output_base $resolution.gif"
fi

# Process based on resolution
case "$resolution" in
    low)
        ffmpeg -y -i "$input_file" -vf "fps=10,scale=600:-1:flags=lanczos" -c:v gif "$output_file"
        ;;
    mid)
        ffmpeg -y -i "$input_file" -vf "fps=10,scale=600:-1:flags=lanczos,split[s0][s1];[s1]palettegen[p];[s0][p]paletteuse" "$output_file"
        ;;
    high)
        ffmpeg -y -i "$input_file" -vf "fps=15,scale=800:-1:flags=lanczos,split[s0][s1];[s1]palettegen[p];[s0][p]paletteuse" "$output_file"
        ;;
esac
