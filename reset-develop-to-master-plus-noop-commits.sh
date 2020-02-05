#!/usr/bin/env bash

# 1. save this script wherever you want (e.g., ~/src/)
# 2. make the script executable (e.g., `chmod +x ~/src/reset-develop-to-master-plus-noop-commits.sh`)
# 3. add an alias to ~/.bash_profile (e.g., alias devreset="~/src/reset-develop-to-master-plus-noop-commits.sh")
# 4. enter a git repo and run it!

echo "************ begin devreset ************"

current_branch=$(git rev-parse --abbrev-ref HEAD)
temp_branch=$(uuidgen)
temp_file=$(uuidgen)

git checkout -b $temp_branch
git branch -D develop
git branch -D master
git checkout master
git checkout -b develop
touch $temp_file
git add $temp_file
git commit -m "noop: add $temp_file"
git revert $(git rev-parse HEAD) --no-edit
git push -uf origin develop
git branch -D $temp_branch
git checkout $current_branch

echo "************ end devreset ************"
