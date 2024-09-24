#!/usr/bin/env bash

# Default to the HEAD commit if no argument is provided, otherwise use the argument as the offset
OFFSET=${1:-0}

# Get the short SHA of the commit at the given offset before HEAD
SHA=$(git rev-parse --short=7 HEAD~$OFFSET)

# Output the SHA to the terminal
echo $SHA

# Copy it to the clipboard
echo $SHA | pbcopy
