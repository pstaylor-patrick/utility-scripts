#!/usr/bin/env bash

# 1. save this script wherever you want (e.g., ~/src/)
# 2. make the script executable (e.g., `chmod +x ~/src/utility-scripts/prune-local-branches.sh`)
# 3. add an alias to ~/.bash_profile (e.g., alias prunelocal="~/src/utility-scripts/prune-local-branches.sh")
# 4. enter a git repo and run it!

echo "************ begin prunelocal ************"

# Check if a branch name is provided as an argument
desired_branch="$1"

current_branch=$(git rev-parse --abbrev-ref HEAD)
temp_branch=$(uuidgen)

git reset --hard
git clean -xdf
git checkout -b $temp_branch
git fetch
git remote prune origin

for branch in $(git branch --format='%(refname:short)')
do
  if [ "$branch" == "$temp_branch" ]
  then
    continue
  fi

  git branch -D $branch
done

rm -rf ./**
git reset --hard

git checkout main
git pull
git fetch
git branch -D $temp_branch

# Conditionally pass the branch name to the reset script
if [ -n "$desired_branch" ]; then
    /usr/bin/env bash "$(dirname $(git rev-parse --show-toplevel 2>/dev/null))/$(basename $(git rev-parse --show-toplevel)).reset.sh" "$desired_branch"
else
    /usr/bin/env bash "$(dirname $(git rev-parse --show-toplevel 2>/dev/null))/$(basename $(git rev-parse --show-toplevel)).reset.sh"
fi

git branch --list --all

echo "************ end prunelocal ************"
