#!/usr/bin/env bash

# Read from stdin if available, otherwise exit
while IFS= read -r line || [[ -n "$line" ]]; do
    # Convert to lowercase using tr and store in variable
    lowered=$(echo "$line" | tr '[:upper:]' '[:lower:]')
    # Output to stdout
    echo "$lowered"
    # Copy to clipboard
    echo -n "$lowered" | pbcopy
done
