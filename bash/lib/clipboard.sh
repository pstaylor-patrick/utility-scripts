#!/usr/bin/env bash
# Shared clipboard helper. Source this file, then pipe text to copy_to_clipboard.
# Tries native tools first, then OSC 52 for SSH sessions.

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

  local encoded
  encoded=$(printf '%s' "$input" | base64 | tr -d '\n')

  local sink
  for sink in /dev/tty "${SSH_TTY:-}"; do
    if [[ -n "$sink" ]] && [[ -w "$sink" ]]; then
      { printf '\033]52;c;%s\a' "$encoded" > "$sink"; } 2>/dev/null && return 0
    fi
  done

  if [[ -t 2 ]]; then
    printf '\033]52;c;%s\a' "$encoded" >&2 && return 0
  fi

  echo "Warning: could not copy to clipboard (no working clipboard tool found)." >&2
  return 1
}
