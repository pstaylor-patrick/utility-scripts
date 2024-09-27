#!/usr/bin/env bash

# Function to generate a UUID fragment for the fake org name
generate_uuid_fragment() {
  uuidgen | awk -F '-' '{print $NF}'
}

# Function to generate a universally unique 8-digit EIN/SSN without any zeros, followed by a 3
generate_random_ein() {
  # Use a UUID for uniqueness
  local uuid_fragment=$(uuidgen | tr -d '-' | tr -cd '1-9')  # Ensure only 1-9 digits, no zeros

  # Ensure we have at least 8 characters from the UUID, append random digits if needed
  while [ ${#uuid_fragment} -lt 8 ]; do
    uuid_fragment+=$(( RANDOM % 9 + 1 ))  # Generate random digits from 1-9
  done

  # Take the first 8 digits and append a 3 at the end
  local ein="${uuid_fragment:0:8}3"
  
  echo "$ein"
}

# Generate the fake org name using a UUID fragment
ORG_NAME="$(generate_uuid_fragment)"

# Generate the fake EIN
FAKE_EIN=$(generate_random_ein)

# Copy the resulting org name and EIN to the clipboard and echo them back to the console
echo "$ORG_NAME $FAKE_EIN" | pbcopy
echo "Fake Organization Name: $ORG_NAME"
echo "Fake EIN: $FAKE_EIN"