#!/usr/bin/env bash

get_uuid_tail() {
  uuidgen | awk -F '-' '{print $NF}'
}

UUID_TAIL=$(get_uuid_tail)

copy_to_clipboard() {
  local input
  input=$(cat)

  local tool
  for tool in pbcopy wl-copy xclip xsel clip.exe; do
    if command -v "$tool" >/dev/null 2>&1; then
      case "$tool" in
        xclip) printf '%s' "$input" | xclip -selection clipboard 2>/dev/null && return 0 ;;
        xsel) printf '%s' "$input" | xsel --clipboard --input 2>/dev/null && return 0 ;;
        *) printf '%s' "$input" | "$tool" && return 0 ;;
      esac
    fi
  done

  echo "Warning: could not copy to clipboard (no working clipboard tool found)." >&2
  return 1
}

echo "$UUID_TAIL"
echo -n "$UUID_TAIL" | copy_to_clipboard
