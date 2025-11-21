#!/usr/bin/env bash

# 1. save this script wherever you want (e.g., ~/src/)
# 2. make the script executable (e.g., `chmod +x ~/src/bump-uuidgen-commits.sh`)
# 3. add an alias to ~/.bash_profile (e.g., alias poke="~/src/bump-uuidgen-commits.sh")
# 4. enter a git repo and run it!

echo "************ begin poke ************"

file_name=$(uuidgen)
touch "${file_name}"
git add "${file_name}"
git commit -m "add ${file_name}" -n
git revert $(git rev-parse head) --no-edit
git status

echo "************ end poke ************"
