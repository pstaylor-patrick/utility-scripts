#!/usr/bin/env bash
#
# Remove all docker containers, images, volumes, and custom networks, except
# resources matched by the ignore file. The ignore file defaults to
# docker-kill.ignore next to this script; override it with DOCKER_KILL_IGNORE_FILE.
# See docker-kill.ignore for the format.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IGNORE_FILE="${DOCKER_KILL_IGNORE_FILE:-$SCRIPT_DIR/docker-kill.ignore}"

log() {
  echo "[docker-kill] $*"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { log "missing required command: $1"; exit 1; }
}

require_cmd docker

# Ignore patterns, one combined ERE per resource type. macOS bash 3.2 has no
# associative arrays, so keep these as plain strings.
IGNORE_CONTAINERS=""
IGNORE_IMAGES=""
IGNORE_VOLUMES=""
IGNORE_NETWORKS=""

parse_ignore_file() {
  local file="$1"
  if [ ! -f "$file" ]; then
    log "no ignore file at $file; removing everything"
    return 0
  fi
  log "using ignore file $file"
  local section="" line
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -z "$line" ] && continue
    case "$line" in
      \#*) continue ;;
      \[*\])
        section="${line#[}"
        section="${section%]}"
        continue
        ;;
    esac
    case "$section" in
      containers) IGNORE_CONTAINERS="${IGNORE_CONTAINERS:+$IGNORE_CONTAINERS|}$line" ;;
      images)     IGNORE_IMAGES="${IGNORE_IMAGES:+$IGNORE_IMAGES|}$line" ;;
      volumes)    IGNORE_VOLUMES="${IGNORE_VOLUMES:+$IGNORE_VOLUMES|}$line" ;;
      networks)   IGNORE_NETWORKS="${IGNORE_NETWORKS:+$IGNORE_NETWORKS|}$line" ;;
      *)          log "ignoring line outside any section: $line" ;;
    esac
  done < "$file"
}

# Read "name<TAB>id" lines on stdin, print the id of every row whose name does
# not match the given ERE.
ids_not_matching() {
  awk -F'\t' -v pat="$1" 'pat != "" && $1 ~ pat { next } { print $2 }'
}

# Read names on stdin, print those that do not match the given ERE.
names_not_matching() {
  awk -v pat="$1" 'pat != "" && $0 ~ pat { next } { print }'
}

remove_containers() {
  local running stopped
  running="$(docker ps --format '{{.Names}}\t{{.ID}}' | ids_not_matching "$IGNORE_CONTAINERS")"
  if [ -n "$running" ]; then
    log "stopping containers"
    # Word splitting is intended: pass each id as a separate argument.
    # shellcheck disable=SC2086
    docker stop $running >/dev/null
  fi
  stopped="$(docker ps -a --format '{{.Names}}\t{{.ID}}' | ids_not_matching "$IGNORE_CONTAINERS")"
  if [ -n "$stopped" ]; then
    log "removing containers"
    # shellcheck disable=SC2086
    docker rm $stopped >/dev/null
  else
    log "no containers to remove"
  fi
}

# remove_resources LABEL LIST CMD...
# Run "CMD LIST" when LIST is non-empty, splitting LIST into separate args.
# Refusals are tolerated: kept resources (e.g. an image still held by a kept
# container) cannot be removed, and that is expected.
remove_resources() {
  local label="$1" list="$2"
  shift 2
  if [ -z "$list" ]; then
    log "no $label to remove"
    return 0
  fi
  log "removing $label"
  # shellcheck disable=SC2086
  "$@" $list >/dev/null 2>&1 || true
}

remove_images() {
  local images
  images="$(docker images --format '{{.Repository}}:{{.Tag}}\t{{.ID}}' | ids_not_matching "$IGNORE_IMAGES" | sort -u)"
  remove_resources images "$images" docker rmi
}

remove_volumes() {
  local volumes
  volumes="$(docker volume ls --format '{{.Name}}' | names_not_matching "$IGNORE_VOLUMES")"
  remove_resources volumes "$volumes" docker volume rm
}

remove_networks() {
  local networks default='^(bridge|host|none)$' pat
  pat="$default"
  [ -n "$IGNORE_NETWORKS" ] && pat="$default|$IGNORE_NETWORKS"
  networks="$(docker network ls --format '{{.Name}}' | names_not_matching "$pat")"
  remove_resources networks "$networks" docker network rm
}

parse_ignore_file "$IGNORE_FILE"
remove_containers
remove_images
remove_volumes
remove_networks
log "done"
