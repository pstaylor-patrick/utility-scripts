#!/bin/bash

# Generate a Lorem Ipsum paragraph
lorem_text="Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat. Duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla pariatur. Excepteur sint occaecat cupidatat non proident, sunt in culpa qui officia deserunt mollit anim id est laborum."

# Copy the Lorem Ipsum text to the clipboard using pbcopy without trailing newline
echo -n "$lorem_text" | pbcopy

if [ $? -eq 0 ]; then
    echo "Lorem Ipsum text has been copied to the clipboard."
else
    echo "Failed to copy text to the clipboard."
    exit 1
fi