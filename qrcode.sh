#!/usr/bin/env bash

# 1. save this script wherever you want (e.g., ~/src/)
# 2. make the script executable (e.g., `chmod +x ~/src/qrcode.sh`)
# 3. add an alias to ~/.bash_profile or ~/.zshrc (e.g., alias qrcode="~/src/qrcode.sh")
# 4. enter a git repo and run it!

# Check if at least one argument is provided
if [ $# -eq 0 ]; then
  echo "Usage: $0 <URL>"
  exit 1
fi

# Assign the first argument to a variable
url="$1"

# Run the npx code with the provided URL
npx qrcode -e M -t svg  -o qrcode.svg "$url"
