#!/usr/bin/env bash

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

# Copy the new email alias to the clipboard using pbcopy without trailing newline
echo -n "$new_email" | pbcopy

if [ $? -eq 0 ]; then
    echo $new_email
else
    echo "$new_email (failed to copy text to the clipboard)"
    exit 1
fi