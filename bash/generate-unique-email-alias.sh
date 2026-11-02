#!/usr/bin/env bash

# shellcheck source=lib/clipboard.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/clipboard.sh"

# Check if an email address was provided as an argument
if [ -z "$1" ]; then
    echo "Usage: $0 <email>"
    exit 1
fi

# Extract the username and domain from the provided email address
email="$1"
username=$(echo "$email" | cut -d '@' -f 1)
domain=$(echo "$email" | cut -d '@' -f 2)

# Generate a UUID and extract the last alphanumeric chunk after the last `-`
uuid=$(uuidgen)
suffix=$(echo $uuid | awk -F'-' '{print tolower($NF)}')

# Construct the new email alias using the username and domain from the input email
new_email="${username}+${suffix}@${domain}"

echo "$new_email"
echo -n "$new_email" | copy_to_clipboard