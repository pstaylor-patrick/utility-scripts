#!/usr/bin/env bash

# Default to the HEAD commit if no argument is provided, otherwise use the argument as the offset
OFFSET=${1:-0}

# Get the short SHA of the commit at the given offset before HEAD
SHA=$(git rev-parse --short=7 HEAD~$OFFSET)

# Get the one-line commit message for the same commit
COMMIT_MSG=$(git log --oneline -n 1 HEAD~$OFFSET)

# Output the SHA and the commit message to the terminal
echo "$COMMIT_MSG"

# Copy only the SHA to the clipboard, removing any trailing newline
echo -n $SHA | pbcopy
