#!/usr/bin/env bash

codex_clean_label() {
  local label="$1"
  local max_len="${2:-50}"

  if type clamp_label >/dev/null 2>&1; then
    clamp_label "$label" "$max_len"
    return
  fi

  label=$(printf "%s" "$label" | tr '\n' ' ' | tr '\t' ' ' | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')
  if [ "${#label}" -gt "$max_len" ]; then
    label="${label:0:$((max_len - 3))}..."
  fi
  printf "%s\n" "$label"
}

codex_label_from_prompt() {
  local prompt="$1"
  local fallback="$2"
  local max_len="${3:-50}"

  local label=""
  if label=$(codex exec "$prompt" 2>/dev/null); then
    label=$(printf "%s" "$label" | sed '/^```.*$/d; /^---$/d' | head -n1 | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  else
    label=""
  fi

  if [ -z "$label" ]; then
    label="$fallback"
  fi

  codex_clean_label "$label" "$max_len"
}

codex_stream_with_label() {
  local label="$1"
  local prompt="$2"
  local prefix="[$label]"

  if type log >/dev/null 2>&1; then
    log "${prefix} starting"
  fi

  if codex exec "$prompt" 2>&1 | awk -v p="${prefix} " '{print p $0}'; then
    if type log >/dev/null 2>&1; then
      log "${prefix} completed"
    fi
    return 0
  fi

  if type log >/dev/null 2>&1; then
    log "${prefix} failed"
  fi
  return 1
}
