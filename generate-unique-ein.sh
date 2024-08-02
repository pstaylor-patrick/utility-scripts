#!/usr/bin/env bash

# Function to generate a UUID fragment if not provided
generate_uuid_fragment() {
  uuidgen | awk -F '-' '{print $NF}'
}

# Check if a UUID fragment is provided as a command line argument
if [ -z "$1" ]; then
  UUID_FRAGMENT=$(generate_uuid_fragment)
else
  UUID_FRAGMENT="$1"
fi

# Extract numbers from the UUID fragment
NUMERICAL_STRING=$(echo "$UUID_FRAGMENT" | tr -cd '0-9')

# Truncate the string from the leading characters if it exceeds 9 characters
if [ ${#NUMERICAL_STRING} -gt 9 ]; then
  NUMERICAL_STRING=${NUMERICAL_STRING: -9}
fi

# Add leading zeros to make the total length 9
FAKE_EIN=$(printf "%09d" "$NUMERICAL_STRING")

# Copy the resulting string to clipboard and echo it back to the console
echo "$FAKE_EIN" | pbcopy
echo "UUID Fragment: $UUID_FRAGMENT"
echo "Fake EIN: $FAKE_EIN"