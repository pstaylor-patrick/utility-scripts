#!/bin/bash

# Generate a UUID
uuid=$(uuidgen)

# Extract the last alphanumeric chunk after the last `-`
suffix=$(echo $uuid | awk -F'-' '{print tolower($NF)}')

# Construct the email address
email="ptaylor+${suffix}@gloo.us"

# Output the email address
echo $email