#!/usr/bin/env bash

# 1. save this script wherever you want (e.g., ~/src/)
# 2. make the script executable (e.g., `chmod +x ~/src/utility-scripts/prune-local-branches.sh`)
# 3. add an alias to ~/.bash_profile (e.g., alias prunelocal="~/src/utility-scripts/prune-local-branches.sh")
# 4. enter a git repo and run it!

# Check if a branch name is provided as an argument
desired_branch="$1"
default_branch="main"

main() {
  echo "************ begin prunelocal ************"

  log "💣 nuking it"
  nuke_it

  log "🗂️  checking out desired branch"
  checkout_desired_branch

  log "⚙️  running custom repo reset script"
  custom_reset

  log "✅ prunelocal complete"

  echo "************ end prunelocal ************"
}

log() {
  local message="$1"
  local length=${#message}
  local total_length=$((length + 8)) # 3 for '===', 2 for spaces on each side, and 1 for each surrounding space
  local separator=$(printf '=%.0s' $(seq 1 $total_length))

  echo -e "\n$separator"
  echo "=== $message ==="
  echo "$separator"
}

nuke_it() {
  current_branch=$(git rev-parse --abbrev-ref HEAD)
  temp_branch=$(uuidgen)

  git rebase --abort || true
  git reset --hard
  git clean -xdf
  git checkout -b $temp_branch
  git fetch
  git remote prune origin

  for branch in $(git branch --format='%(refname:short)'); do
    if [ "$branch" == "$temp_branch" ]; then
      continue
    fi

    git branch -D $branch
  done

  rm -rf ./**
  git reset --hard

  git checkout $default_branch
  git pull
  git fetch
  git branch -D $temp_branch
}

checkout_desired_branch() {
  if [ -n "$desired_branch" ]; then
    log "Checking Out Branch $desired_branch"
    if git show-ref --verify --quiet "refs/heads/$desired_branch"; then
      git checkout "$desired_branch"
    elif git show-ref --verify --quiet "refs/remotes/origin/$desired_branch"; then
      git checkout -t "origin/$desired_branch"
    else
      git checkout -b "$desired_branch"
    fi
  else
    log "No branch specified, staying on the current branch"
  fi
}

custom_reset() {
  /usr/bin/env bash "$(dirname $(git rev-parse --show-toplevel 2>/dev/null))/$(basename $(git rev-parse --show-toplevel)).reset.sh"
}

main
