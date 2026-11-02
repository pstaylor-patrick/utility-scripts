#!/usr/bin/env bash

# shellcheck source=lib/clipboard.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/clipboard.sh"

# Lowercase stdin, print it, and copy the whole result to the clipboard
lowered=$(tr '[:upper:]' '[:lower:]')
printf '%s\n' "$lowered"
printf '%s' "$lowered" | copy_to_clipboard
