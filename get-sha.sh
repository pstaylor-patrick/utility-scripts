#!/usr/bin/env bash

# Get the short SHA of the current git HEAD
SHA=$(git rev-parse --short=7 HEAD)

# Output it to the terminal
echo $SHA

# Copy it to the clipboard
echo $SHA | pbcopy
