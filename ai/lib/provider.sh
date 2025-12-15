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

# Load .env file if it exists (searches multiple locations)
_ai_load_env() {
    local env_file=""
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    # Priority: current dir > git root > script's parent dir (ai/) > script's grandparent (utility-scripts/)
    if [ -f "./.env" ]; then
        env_file="./.env"
    elif git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        local git_root
        git_root=$(git rev-parse --show-toplevel 2>/dev/null)
        if [ -n "$git_root" ] && [ -f "${git_root}/.env" ]; then
            env_file="${git_root}/.env"
        fi
    fi

    # Fallback to script directory locations
    if [ -z "$env_file" ] && [ -f "${script_dir}/../.env" ]; then
        env_file="${script_dir}/../.env"
    elif [ -z "$env_file" ] && [ -f "${script_dir}/../../.env" ]; then
        env_file="${script_dir}/../../.env"
    fi

    if [ -n "$env_file" ] && [ -f "$env_file" ]; then
        # Source the .env file, only exporting lines that look like VAR=value
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
    fi
}

# Load environment variables from .env
_ai_load_env

# Default provider
AI_PROVIDER="${AI_PROVIDER:-codex}"

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
    local response
    local content

    # Escape the prompt for JSON
    local escaped_prompt
    escaped_prompt=$(printf '%s' "$prompt" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')

    response=$(curl -s -X POST "$DEEPSEEK_API_URL" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $DEEPSEEK_API_KEY" \
        -d "{
            \"model\": \"$DEEPSEEK_MODEL\",
            \"messages\": [{\"role\": \"user\", \"content\": $escaped_prompt}],
            \"temperature\": 0.7,
            \"max_tokens\": 4096
        }")

    # Check for API errors
    local error
    error=$(printf '%s' "$response" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("error",{}).get("message",""))' 2>/dev/null || true)
    if [ -n "$error" ]; then
        echo "DeepSeek API error: $error" >&2
        return 1
    fi

    # Extract content from response
    content=$(printf '%s' "$response" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["choices"][0]["message"]["content"])' 2>/dev/null)
    if [ -z "$content" ]; then
        echo "Error: Failed to parse DeepSeek response" >&2
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
  -x, --codex      Use OpenAI Codex (default)
  -c, --claude     Use Claude Code
  -d, --deepseek   Use DeepSeek API (requires DEEPSEEK_API_KEY)

Environment Variables:
  AI_PROVIDER      Set default provider (codex, claude, deepseek)
  DEEPSEEK_API_KEY API key for DeepSeek (required when using -d)
  DEEPSEEK_MODEL   DeepSeek model name (default: deepseek-chat)
EOF
}
