#!/usr/bin/env bash

UUID_TAIL=$(uuidgen | awk -F '-' '{print $NF}')

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

  if [[ -n "$SSH_TTY" ]] && [[ -w "$SSH_TTY" ]]; then
    printf '\033]52;c;%s\a' "$(printf '%s' "$input" | base64 | tr -d '\n')" > "$SSH_TTY" && return 0
  fi

  echo "Warning: could not copy to clipboard (no working clipboard tool found)." >&2
  return 1
}

echo "$UUID_TAIL"
echo -n "$UUID_TAIL" | copy_to_clipboard
