#!/usr/bin/env bash

# Generate a UUID
uuid=$(uuidgen)

# Extract the last alphanumeric chunk after the last `-`
suffix=$(echo $uuid | awk -F'-' '{print tolower($NF)}')

# Construct the email address
email="ptaylor+${suffix}@gloo.us"

# Copy the email address to the clipboard using pbcopy without trailing newline
echo -n "$email" | pbcopy

if [ $? -eq 0 ]; then
    echo $email
else
    echo "$email (failed to copy text to the clipboard)"
    exit 1
fi
