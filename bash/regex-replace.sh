#!/usr/bin/env bash

# Check for correct number of arguments
if [ "$#" -ne 3 ]; then
  echo "Usage: $0 DIRECTORY SEARCH_REGEX REPLACEMENT"
  exit 1
fi

DIRECTORY=$1
SEARCH_REGEX=$2
REPLACEMENT=$3

# Check if the directory exists
if [ ! -d "$DIRECTORY" ]; then
  echo "Error: Directory '$DIRECTORY' does not exist."
  exit 1
fi

# Find and replace in all files within the directory
find "$DIRECTORY" -type f -exec sed -i.bak -E "s/${SEARCH_REGEX}/${REPLACEMENT}/g" {} +

# Optional: Clean up backup files
find "$DIRECTORY" -type f -name "*.bak" -delete

echo "Regex replacement completed."