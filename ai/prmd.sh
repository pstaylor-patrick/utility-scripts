#!/usr/bin/env bash

PULL_REQUEST_TEMPLATE="$HOME/src/pstaylor-patrick/utility-scripts/ai/prmd/pull_request_template.md"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

main() {
    if [ -z "$1" ]; then
        echo "Usage: ./ai/prmd.sh BASE_BRANCH"
        echo "Example: ./ai/prmd.sh main"
        exit 1
    fi

    local base_branch="$1"
    log "Starting PR description generation against $base_branch..."
    cp "$PULL_REQUEST_TEMPLATE" ./pr.md

    # Get a statistical summary of the diff against the base branch
    log "Generating diff summary against '$base_branch' from directory: $(pwd)"
    local diff_content=$(git --no-pager diff --stat "$base_branch")
    if [ -z "$diff_content" ]; then
        echo "Error: No differences found against branch $base_branch"
        exit 1
    fi

    generate_pr_md "$diff_content"
}

generate_pr_md() {
    local diff_content="$1"
    # Get the directory where the script is located to reliably find the project root
    SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
    PROJECT_ROOT="$SCRIPT_DIR/.."

    # Load API key from .env file in the project root
    if [ -f "$PROJECT_ROOT/.env" ]; then
        source "$PROJECT_ROOT/.env"
    fi
    
    if [ -z "$OPENAI_API_KEY" ]; then
        echo "Error: OPENAI_API_KEY environment variable not set."
        echo "Please ensure it is set in the .env file at the project root: $PROJECT_ROOT/.env"
        exit 1
    fi

    local pr_content=$(cat ./pr.md)
    
    # Build a detailed and specific JSON payload using jq
    payload=$(jq -n \
        --arg pr_template "$pr_content" \
        --arg diff_content "$diff_content" \
        '{
            "model": "gpt-4o",
            "messages": [
                {
                    "role": "system",
                    "content": "You are a senior software engineer writing a pull request description. Your task is to complete a PR description template using a `git diff --stat` summary. Adhere strictly to the following rules:\n1. Use the provided PR TEMPLATE as the base for your entire response.\n2. Your primary goal is to replace the `(coming soon)` placeholders in the `TL;DR`, `Details`, and `How to Test` sections.\n3. The content you generate for these sections must be a high-level summary derived *only* from the provided GIT DIFF SUMMARY. Do not invent file contents.\n4. PRESERVE THE ENTIRE TEMPLATE STRUCTURE. This includes all HTML comments, markdown formatting, headers, and the existing GIF link. Do not add, remove, or alter any sections.\n5. Be concise and professional."
                },
                {
                    "role": "user",
                    "content": ("Here is the PR TEMPLATE:\n---\n" + $pr_template + "\n---\n\nHere is the GIT DIFF SUMMARY (`git diff --stat`):\n---\n" + $diff_content + "\n---")
                }
            ],
            "temperature": 0.5
        }')

    response=$(curl -s -X POST "https://api.openai.com/v1/chat/completions" \
        -H "Authorization: Bearer $OPENAI_API_KEY" \
        -H "Content-Type: application/json" \
        -d "$payload")

    if [[ $? -ne 0 ]]; then
        echo "Error: Failed to call OpenAI API"
        exit 1
    fi

    # Validate that the response contains the expected content path
    if ! jq -e '.choices[0].message.content' <<<"$response" > /dev/null; then
        echo "Error: API response did not contain expected content."
        echo "API Response:"
        echo "$response"
        exit 1
    fi

    local raw_content=$(jq -r '.choices[0].message.content' <<<"$response")
    
    # Post-process the response to remove the --- delimiters if they exist
    local cleaned_content=$(echo "$raw_content" | sed '/^---$/d')
    
    # Save generated content to pr.md
    echo "$cleaned_content" > ./pr.md
    echo "$cleaned_content"
}

# Wrap main execution to ensure cleanup
{
    main "$@"
    log "PR description generation complete"
}
