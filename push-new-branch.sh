#!/usr/bin/env bash

# 1. save this script wherever you want (e.g., ~/src/)
# 2. make the script executable (e.g., `chmod +x ~/src/push-new-branch.sh`)
# 3. add an alias to ~/.bash_profile (e.g., alias pushnew="~/src/push-new-branch.sh")
# 4. enter a git repo and run it!

echo "************ begin pushnew ************"

temp_branch=$(uuidgen)

git reset --hard
git clean -xdf
git checkout -b $temp_branch
git fetch
git remote prune origin
git branch -D master
git checkout master
git branch -D $temp_branch
git pull
git branch -D $1
git checkout -b $1
git push -u origin $1

echo "************ end pushnew ************"
