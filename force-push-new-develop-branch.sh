#!/usr/bin/env bash

# 1. save this script wherever you want (e.g., ~/src/)
# 2. make the script executable (e.g., `chmod +x ~/src/force-push-new-develop-branch.sh`)
# 3. add an alias to ~/.bash_profile (e.g., alias devpush="~/src/force-push-new-develop-branch.sh")
# 4. enter a git repo and run it!

echo "************ begin devpush ************"

current_branch_name=$(git rev-parse --abbrev-ref HEAD)

git branch -D develop
git checkout -b develop
git push -uf origin develop
git checkout $current_branch_name

echo "************ end devpush ************"
