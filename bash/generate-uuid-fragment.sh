#!/usr/bin/env bash

# shellcheck source=lib/clipboard.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/clipboard.sh"

UUID_TAIL=$(uuidgen | awk -F '-' '{print $NF}' | tr '[:lower:]' '[:upper:]')

echo "$UUID_TAIL"
echo -n "$UUID_TAIL" | copy_to_clipboard
