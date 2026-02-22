#!/usr/bin/env bash

# AI provider abstraction layer for supporting multiple AI completion backends:
# - codex (OpenAI Codex CLI)
# - claude (Claude Code CLI)
# - deepseek (DeepSeek API via curl)
#
# Usage:
#   source this file, then call:
#     ai_exec "prompt"           # Execute prompt with current provider
#     ai_provider_name           # Get current provider name
#     ai_require_provider        # Ensure provider is available
#
# Provider selection (in priority order):
#   1. AI_PROVIDER environment variable (codex, claude, deepseek)
#   2. Command-line flag sets AI_PROVIDER before sourcing
#   3. Default: codex

# Load .env files from multiple locations (all are checked, first value wins)
_ai_load_env() {
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    # Collect all potential .env files (checked in priority order)
    local env_files=()

    # 1. Current directory
    if [ -f "./.env" ]; then
        env_files+=("$(pwd)/.env")
    fi

    # 2. Git root of current repo (if in a git repo)
    if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        local git_root
        git_root=$(git rev-parse --show-toplevel 2>/dev/null)
        if [ -n "$git_root" ] && [ -f "${git_root}/.env" ]; then
            local abs_git_env="${git_root}/.env"
            # Avoid duplicates if current dir is git root
            if [[ ! " ${env_files[*]} " =~ " ${abs_git_env} " ]]; then
                env_files+=("$abs_git_env")
            fi
        fi
    fi

    # 3. Script's parent dir (ai/)
    if [ -f "${script_dir}/../.env" ]; then
        env_files+=("${script_dir}/../.env")
    fi

    # 4. Script's grandparent dir (utility-scripts/)
    if [ -f "${script_dir}/../../.env" ]; then
        env_files+=("${script_dir}/../../.env")
    fi

    # Load all .env files; existing vars are never overridden
    local env_file
    for env_file in "${env_files[@]}"; do
        while IFS= read -r line || [ -n "$line" ]; do
            # Skip comments and empty lines
            [[ "$line" =~ ^[[:space:]]*# ]] && continue
            [[ -z "${line// }" ]] && continue
            # Only process lines that look like VAR=value
            if [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
                # Don't override existing environment variables
                local var_name="${line%%=*}"
                if [ -z "${!var_name:-}" ]; then
                    export "$line"
                fi
            fi
        done < "$env_file"
    done
}

# Load environment variables from .env
_ai_load_env

# Default provider
AI_PROVIDER="${AI_PROVIDER:-deepseek}"

# DeepSeek configuration
DEEPSEEK_API_URL="${DEEPSEEK_API_URL:-https://api.deepseek.com/v1/chat/completions}"
DEEPSEEK_MODEL="${DEEPSEEK_MODEL:-deepseek-chat}"

ai_provider_name() {
    echo "$AI_PROVIDER"
}

ai_set_provider() {
    local provider="$1"
    case "$provider" in
        codex|claude|deepseek)
            AI_PROVIDER="$provider"
            ;;
        *)
            echo "Error: Unknown AI provider '$provider'. Supported: codex, claude, deepseek" >&2
            return 1
            ;;
    esac
}

ai_require_provider() {
    case "$AI_PROVIDER" in
        codex)
            if ! command -v codex >/dev/null 2>&1; then
                echo "Error: codex CLI is required but not installed or on PATH." >&2
                echo "Install: npm install -g @openai/codex" >&2
                return 1
            fi
            ;;
        claude)
            if ! command -v claude >/dev/null 2>&1; then
                echo "Error: claude CLI is required but not installed or on PATH." >&2
                echo "Install: npm install -g @anthropic-ai/claude-code" >&2
                return 1
            fi
            ;;
        deepseek)
            if ! command -v curl >/dev/null 2>&1; then
                echo "Error: curl is required for DeepSeek API calls." >&2
                return 1
            fi
            if [ -z "${DEEPSEEK_API_KEY:-}" ]; then
                echo "Error: DEEPSEEK_API_KEY environment variable is required." >&2
                return 1
            fi
            ;;
        *)
            echo "Error: Unknown AI provider '$AI_PROVIDER'." >&2
            return 1
            ;;
    esac
    return 0
}

_ai_exec_codex() {
    local prompt="$1"
    codex exec "$prompt"
}

_ai_exec_claude() {
    local prompt="$1"
    # Claude Code CLI uses -p for prompt mode (non-interactive)
    claude -p "$prompt" --allowedTools "Edit" "Write" "Bash" "Read"
}

_ai_exec_deepseek() {
    local prompt="$1"

    # Escape the prompt for JSON
    local escaped_prompt
    escaped_prompt=$(printf '%s' "$prompt" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')

    # Capture response body and HTTP status code separately
    local http_code response tmpfile
    tmpfile=$(mktemp)
    http_code=$(curl -s -o "$tmpfile" -w '%{http_code}' -X POST "$DEEPSEEK_API_URL" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $DEEPSEEK_API_KEY" \
        -d "{
            \"model\": \"$DEEPSEEK_MODEL\",
            \"messages\": [{\"role\": \"user\", \"content\": $escaped_prompt}],
            \"temperature\": 0.7,
            \"max_tokens\": 4096
        }")
    response=$(<"$tmpfile")
    rm -f "$tmpfile"

    if [ -z "$response" ]; then
        echo "Error: Empty response from DeepSeek API (HTTP $http_code)" >&2
        return 1
    fi

    # Single python3 call handles error checking and content extraction
    local content
    content=$(printf '%s' "$response" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except (json.JSONDecodeError, ValueError) as e:
    print(f"JSON parse error: {e}", file=sys.stderr)
    sys.exit(1)
if "error" in d:
    e = d["error"]
    msg = e.get("message", str(e)) if isinstance(e, dict) else str(e)
    print(f"API error: {msg}", file=sys.stderr)
    sys.exit(1)
try:
    c = d["choices"][0]["message"]["content"]
except (KeyError, IndexError, TypeError) as e:
    print(f"Unexpected response structure: {e}", file=sys.stderr)
    sys.exit(1)
if not c or not c.strip():
    print("Empty content in response", file=sys.stderr)
    sys.exit(1)
print(c)
')
    local parse_exit=$?

    if [ $parse_exit -ne 0 ] || [ -z "$content" ]; then
        echo "Error: DeepSeek request failed (HTTP $http_code)" >&2
        echo "Response preview: ${response:0:300}" >&2
        return 1
    fi

    printf '%s\n' "$content"
}

ai_exec() {
    local prompt="$1"

    case "$AI_PROVIDER" in
        codex)
            _ai_exec_codex "$prompt"
            ;;
        claude)
            _ai_exec_claude "$prompt"
            ;;
        deepseek)
            _ai_exec_deepseek "$prompt"
            ;;
        *)
            echo "Error: Unknown AI provider '$AI_PROVIDER'." >&2
            return 1
            ;;
    esac
}

# Parse provider flags from command line arguments
# Call this function early in scripts to handle -c (claude), -d (deepseek) flags
# Returns remaining arguments via stdout, one per line
ai_parse_provider_args() {
    local args=()
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            -c|--claude)
                AI_PROVIDER="claude"
                ;;
            -d|--deepseek)
                AI_PROVIDER="deepseek"
                ;;
            -x|--codex)
                AI_PROVIDER="codex"
                ;;
            *)
                args+=("$1")
                ;;
        esac
        shift
    done
    # Export the provider selection
    export AI_PROVIDER
    # Return remaining args
    printf '%s\n' "${args[@]}"
}

# Helper for scripts using getopts - returns the getopts option string with provider flags
ai_getopts_string() {
    local base="$1"
    echo "${base}cdx"
}

# Handle provider option in getopts case statement
# Returns 0 if it was a provider option, 1 otherwise
ai_handle_getopts_provider() {
    local opt="$1"
    case "$opt" in
        c)
            AI_PROVIDER="claude"
            export AI_PROVIDER
            return 0
            ;;
        d)
            AI_PROVIDER="deepseek"
            export AI_PROVIDER
            return 0
            ;;
        x)
            AI_PROVIDER="codex"
            export AI_PROVIDER
            return 0
            ;;
    esac
    return 1
}

# Print provider usage help
ai_provider_usage() {
    cat <<'EOF'
AI Provider Options:
  -d, --deepseek   Use DeepSeek API (default, requires DEEPSEEK_API_KEY)
  -x, --codex      Use OpenAI Codex
  -c, --claude     Use Claude Code

Environment Variables:
  AI_PROVIDER      Set default provider (codex, claude, deepseek)
  DEEPSEEK_API_KEY API key for DeepSeek (required when using -d)
  DEEPSEEK_MODEL   DeepSeek model name (default: deepseek-chat)
EOF
}
