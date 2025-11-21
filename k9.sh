#!/usr/bin/env bash

# Kill processes using the provided TCP ports.

if [ "$#" -eq 0 ]; then
  echo "Usage: $0 <port> [port ...]"
  exit 1
fi

killed_pids=""

for port in "$@"; do
  echo "Checking port $port"
  pids=$(lsof -t -wni tcp:"$port" 2>/dev/null | sort -u)

  if [ -z "$pids" ]; then
    echo "No processes found on port $port"
    continue
  fi

  for pid in $pids; do
    if echo " $killed_pids " | grep -q " $pid "; then
      continue
    fi

    echo "Killing PID $pid on port $port"
    kill -9 "$pid"
    killed_pids="$killed_pids $pid"
  done
done
