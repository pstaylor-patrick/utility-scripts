#!/usr/bin/env bash

# Function to get the tail (last fragment) of a UUID
get_uuid_tail() {
  # Generate a UUID and extract the last fragment after the last '-'
  uuidgen | awk -F '-' '{print $NF}'
}

# Call the function and store the result
UUID_TAIL=$(get_uuid_tail)

# Echo the result to stdout and copy it to clipboard without a newline
echo "$UUID_TAIL"
echo -n "$UUID_TAIL" | pbcopy