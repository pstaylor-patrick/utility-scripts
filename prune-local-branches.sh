#!/usr/bin/env bash

# 1. save this script wherever you want (e.g., ~/src/)
# 2. make the script executable (e.g., `chmod +x ~/src/utility-scripts/prune-local-branches.sh`)
# 3. add an alias to ~/.bash_profile (e.g., alias prunelocal="~/src/utility-scripts/prune-local-branches.sh")
# 4. enter a git repo and run it!

# Check if a branch name is provided as an argument
desired_branch="$1"

detect_default_branch() {
  local has_master=false
  local has_main=false

  # Check for master branch
  if git show-ref --verify --quiet "refs/heads/master" || git show-ref --verify --quiet "refs/remotes/origin/master"; then
    has_master=true
  fi

  # Check for main branch
  if git show-ref --verify --quiet "refs/heads/main" || git show-ref --verify --quiet "refs/remotes/origin/main"; then
    has_main=true
  fi

  # Handle error cases
  if [ "$has_master" = true ] && [ "$has_main" = true ]; then
    echo "Error: Repository has both 'master' and 'main' branches. Please resolve this ambiguity manually."
    exit 1
  elif [ "$has_master" = false ] && [ "$has_main" = false ]; then
    echo "Error: Repository has neither 'master' nor 'main' branch. Please ensure a default branch exists."
    exit 1
  fi

  # Return the appropriate default branch
  if [ "$has_master" = true ]; then
    echo "master"
  else
    echo "main"
  fi
}

main() {
  echo "************ begin prunelocal ************"

  log "🔍 detecting default branch"
  default_branch=$(detect_default_branch)
  log "Using default branch: $default_branch"

  log "💣 nuking it"
  nuke_it

  log "🗂️  checking out desired branch"
  checkout_desired_branch

  log "🔥 killing docker"
  kill_docker

  log "🔥 setting up nvm"
  setup_nvm

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

  git checkout --track origin/$default_branch
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

kill_docker() {
  log "destroying all docker resources"

  # Stop and remove all running containers
  if [ "$(docker ps -aq)" ]; then
    if [ "$(docker ps -q)" ]; then
      docker stop $(docker ps -q)
    fi
    docker rm $(docker ps -a -q)
  else
    echo "No running containers to stop or remove."
  fi

  # Remove all images
  if [ "$(docker images -q)" ]; then
    docker rmi $(docker images -q)
  else
    echo "No images to remove."
  fi

  # Remove all volumes
  if [ "$(docker volume ls -q)" ]; then
    docker volume rm $(docker volume ls -q)
  else
    echo "No volumes to remove."
  fi

  # Remove all networks except the default ones
  networks_to_remove=$(docker network ls -q | grep -vE 'bridge|host|none')
  if [ "$networks_to_remove" ]; then
    docker network rm $networks_to_remove 2>/dev/null || true
  else
    echo "No custom networks to remove."
  fi
}

setup_nvm() {
  export NVM_DIR="$HOME/.nvm"
  [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"                   # This loads nvm
  [ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion" # This loads nvm bash_completion
  nvm install "lts/*"
  nvm use
  npm i -g pnpm@latest
}

custom_reset() {
  /usr/bin/env bash "$(dirname $(git rev-parse --show-toplevel 2>/dev/null))/$(basename $(git rev-parse --show-toplevel)).reset.sh"
}

main
