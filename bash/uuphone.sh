#!/usr/bin/env bash

# Function to generate a random 10-digit phone number
generate_phone_number() {
  # Use UUID for randomness, extract only digits
  local digits=$(uuidgen | tr -d '-' | tr -cd '0-9')

  # Ensure we have at least 10 digits
  while [ ${#digits} -lt 10 ]; do
    digits+=$(uuidgen | tr -d '-' | tr -cd '0-9')
  done

  # Return first 10 digits
  echo "${digits:0:10}"
}

# Generate the phone number
PHONE_NUMBER=$(generate_phone_number)

# Echo to stdout and copy to clipboard
echo "$PHONE_NUMBER"
echo -n "$PHONE_NUMBER" | pbcopy
