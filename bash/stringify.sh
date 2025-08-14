#!/usr/bin/env bash

# Usage: ./stringify.sh <path-to-json-file>

DIRNAME=$(pwd)

{
  cd "$(dirname "$0")"

#   npm i -D

  if [ -z "$1" ]; then
    echo "Usage: $0 <path-to-json-file>"
    exit 1
  fi

  npm run stringify "$1"
} || {
  echo "Error: An error occurred while processing the file"
  exit 1
}

cd "$DIRNAME"