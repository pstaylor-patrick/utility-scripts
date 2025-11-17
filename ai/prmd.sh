#!/usr/bin/env bash

DEFAULT_PULL_REQUEST_TEMPLATE="$HOME/src/pstaylor-patrick/utility-scripts/ai/prmd/pull_request_template.md"

# Configuration for chunking - adjusted for DeepSeek's 131072 token limit
MAX_CHUNK_SIZE=30000  # Reduced chunk size to stay within token limits
OVERLAP_SIZE=200     # Reduced overlap for speed
BATCH_SIZE=6         # Increased batch size to match parallel jobs
ENABLE_PARALLEL=true # Enable parallel processing
PARALLEL_JOBS=6      # Number of parallel jobs to run (scaled to 6)

# File locking function for safe concurrent writes (macOS compatible)
safe_file_update() {
    local content="$1"
    local lock_file="/tmp/prmd.lock"
    
    # macOS-compatible file locking using mkdir (atomic operation)
    while ! mkdir "$lock_file.lock" 2>/dev/null; do
        sleep 0.1
    done
    
    echo "$content" > ./pr.md
    
    # Cleanup lock
    rmdir "$lock_file.lock" 2>/dev/null
}

# Process a single chunk and save result to temporary file
process_single_chunk() {
    local chunk_file="$1"
    local chunk_num="$2"
    local total_chunks="$3"
    local output_file="$4"
    
    # Get the directory where the script is located to reliably find the project root
    SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
    PROJECT_ROOT="$SCRIPT_DIR/.."

    # Load API key from .env file in the project root
    if [ -f "$PROJECT_ROOT/.env" ]; then
        source "$PROJECT_ROOT/.env"
    fi

    local chunk_content=$(cat "$chunk_file")
    
    local system_prompt="You are a senior software engineer extending a pull request description. You have an existing PR description that was generated from previous chunks of a git diff. Your task is to update and extend this PR description with additional context from a new chunk of the diff. Adhere strictly to the following rules:\n1. Use the provided CURRENT PR DESCRIPTION as the base and extend/refine it.\n2. Update the 'TL;DR', 'Details', and 'How to Test' sections to incorporate insights from the new diff chunk.\n3. PRESERVE THE ENTIRE TEMPLATE STRUCTURE. This includes all HTML comments, markdown formatting, headers, and the existing GIF link.\n4. Be concise and professional.\n5. Integrate the new information seamlessly with the existing content.\n6. Do not duplicate information, but do add new insights and details from this chunk."
    
    local user_content="Here is the CURRENT PR DESCRIPTION:\n---\n$(cat ./pr.md)\n---\n\nHere is ADDITIONAL GIT DIFF CHUNK $chunk_num of $total_chunks:\n---\n$chunk_content\n---\n\nPlease update and extend the PR description to incorporate the new information from this chunk while maintaining the existing structure and content."
    
    # Build a detailed and specific JSON payload using jq
    payload=$(jq -n \
        --arg system_prompt "$system_prompt" \
        --arg user_content "$user_content" \
        '{
            "model": "deepseek-chat",
            "messages": [
                {
                    "role": "system",
                    "content": $system_prompt
                },
                {
                    "role": "user",
                    "content": $user_content
                }
            ],
            "temperature": 0.5
        }')

    response=$(curl -s -X POST "https://api.deepseek.com/chat/completions" \
        -H "Authorization: Bearer $DEEPSEEK_API_KEY" \
        -H "Content-Type: application/json" \
        -d "$payload")

    if [[ $? -ne 0 ]]; then
        echo "Error: Failed to call DeepSeek API for chunk $chunk_num" >&2
        return 1
    fi

    # Validate that the response contains the expected content path
    if ! jq -e '.choices[0].message.content' <<<"$response" > /dev/null; then
        echo "Error: API response did not contain expected content for chunk $chunk_num." >&2
        echo "API Response:" >&2
        echo "$response" >&2
        return 1
    fi

    local raw_content=$(jq -r '.choices[0].message.content' <<<"$response")
    
    # Post-process the response to remove the --- delimiters if they exist
    local cleaned_content=$(echo "$raw_content" | sed '/^---$/d')
    
    # Save result to temporary file
    echo "$cleaned_content" > "$output_file"
    return 0
}

# Integrate chunk analysis into main PR description
integrate_chunk_analysis() {
    local chunk_analysis_file="$1"
    local chunk_num="$2"
    
    local chunk_analysis=$(cat "$chunk_analysis_file")
    local current_pr_content=$(cat ./pr.md)
    
    local system_prompt="You are a senior software engineer integrating multiple PR description analyses. Your task is to merge the analysis from a new chunk with the existing PR description. Adhere strictly to the following rules:\n1. Use the provided CURRENT PR DESCRIPTION as the base.\n2. Integrate insights from the NEW CHUNK ANALYSIS seamlessly.\n3. PRESERVE THE ENTIRE TEMPLATE STRUCTURE including all HTML comments, markdown formatting, headers, and the existing GIF link.\n4. Be concise and professional.\n5. Do not duplicate information, but do add new insights and details.\n6. Maintain logical flow and coherence."
    
    local user_content="Here is the CURRENT PR DESCRIPTION:\n---\n$current_pr_content\n---\n\nHere is ANALYSIS FROM CHUNK $chunk_num:\n---\n$chunk_analysis\n---\n\nPlease merge these analyses into a single coherent PR description while maintaining the existing structure."
    
    # Build a detailed and specific JSON payload using jq
    payload=$(jq -n \
        --arg system_prompt "$system_prompt" \
        --arg user_content "$user_content" \
        '{
            "model": "deepseek-chat",
            "messages": [
                {
                    "role": "system",
                    "content": $system_prompt
                },
                {
                    "role": "user",
                    "content": $user_content
                }
            ],
            "temperature": 0.5
        }')

    response=$(curl -s -X POST "https://api.deepseek.com/chat/completions" \
        -H "Authorization: Bearer $DEEPSEEK_API_KEY" \
        -H "Content-Type: application/json" \
        -d "$payload")

    if [[ $? -ne 0 ]]; then
        echo "Error: Failed to call DeepSeek API for integration" >&2
        return 1
    fi

    # Validate that the response contains the expected content path
    if ! jq -e '.choices[0].message.content' <<<"$response" > /dev/null; then
        echo "Error: API response did not contain expected content for integration." >&2
        echo "API Response:" >&2
        echo "$response" >&2
        return 1
    fi

    local raw_content=$(jq -r '.choices[0].message.content' <<<"$response")
    
    # Post-process the response to remove the --- delimiters if they exist
    local cleaned_content=$(echo "$raw_content" | sed '/^---$/d')
    
    # Save updated content using safe file update
    safe_file_update "$cleaned_content"
    log "Integrated analysis from chunk $chunk_num"
    return 0
}

# Process chunks in parallel with sequential integration
process_chunks_parallel() {
    local temp_dir="$1"
    local total_chunks="$2"
    
    log "Processing $total_chunks chunks in parallel with $PARALLEL_JOBS jobs"
    
    # Create temporary directory for chunk analyses
    local analysis_dir=$(mktemp -d)
    
    # Process chunks in parallel
    local pids=()
    local chunk_status=()  # Track which chunks are being processed
    
    for ((i=0; i<total_chunks; i++)); do
        # Wait if we've reached the maximum parallel jobs
        while [ ${#pids[@]} -ge $PARALLEL_JOBS ]; do
            # Check if any processes have finished
            for pid_index in "${!pids[@]}"; do
                if ! kill -0 "${pids[$pid_index]}" 2>/dev/null; then
                    # Process finished, remove from array
                    local finished_chunk="${chunk_status[$pid_index]}"
                    log "Completed processing chunk $((finished_chunk+1)) of $total_chunks"
                    unset "pids[$pid_index]"
                    unset "chunk_status[$pid_index]"
                fi
            done
            pids=("${pids[@]}")  # Reindex arrays
            chunk_status=("${chunk_status[@]}")
            sleep 0.1
        done
        
        # Process chunk in background
        (
            local output_file="$analysis_dir/chunk_$i.analysis.md"
            if process_single_chunk "$temp_dir/chunk_$i.txt" "$((i+1))" "$total_chunks" "$output_file"; then
                touch "$analysis_dir/chunk_$i.done"
            else
                touch "$analysis_dir/chunk_$i.failed"
            fi
        ) &
        pids+=($!)
        chunk_status+=($i)  # Track which chunk this PID corresponds to
    done
    
    # Wait for all background processes to complete
    wait
    
    # Log completion of any remaining chunks
    for ((i=0; i<total_chunks; i++)); do
        if [ -f "$analysis_dir/chunk_$i.done" ]; then
            log "Completed processing chunk $((i+1)) of $total_chunks"
        fi
    done
    
    # Check for any failed chunks
    local failed_chunks=$(find "$analysis_dir" -name "*.failed" | wc -l)
    if [ "$failed_chunks" -gt 0 ]; then
        log "Warning: $failed_chunks chunks failed to process"
    fi
    
    # Integrate analyses sequentially in correct order
    for ((i=0; i<total_chunks; i++)); do
        local analysis_file="$analysis_dir/chunk_$i.analysis.md"
        if [ -f "$analysis_file" ]; then
            log "Integrating analysis from chunk $((i+1)) of $total_chunks"
            if ! integrate_chunk_analysis "$analysis_file" "$((i+1))"; then
                log "Warning: Failed to integrate analysis from chunk $((i+1))"
            fi
        fi
    done
    
    # Cleanup analysis directory
    rm -rf "$analysis_dir"
    log "Completed parallel processing of $total_chunks chunks"
}

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >&2
}

get_template_path() {
    # Check if there's a .github/pull_request_template.md in the current directory
    local github_template="./.github/pull_request_template.md"
    if [ -f "$github_template" ]; then
        echo "$github_template"
    else
        echo "$DEFAULT_PULL_REQUEST_TEMPLATE"
    fi
}

get_diff_content() {
    local base_branch="$1"
    local use_stat="$2"
    
    if [ "$use_stat" = "true" ]; then
        git --no-pager diff --stat "$base_branch"
    else
        git --no-pager diff "$base_branch"
    fi
}

chunk_diff() {
    local diff_content="$1"
    local chunk_size="$2"
    local overlap_size="$3"
    
    # Create temporary directory for chunks
    local temp_dir=$(mktemp -d)
    local chunk_count=0
    local content_length=${#diff_content}
    local start_pos=0
    
    log "Diff content size: $content_length characters"
    log "Chunking into ~$chunk_size character segments with $overlap_size character overlap"
    
    while [ $start_pos -lt $content_length ]; do
        local end_pos=$((start_pos + chunk_size))
        
        # Don't go beyond the content length
        if [ $end_pos -gt $content_length ]; then
            end_pos=$content_length
        fi
        
        # Extract chunk
        local chunk="${diff_content:$start_pos:$((end_pos - start_pos))}"
        
        # Save chunk to file
        echo "$chunk" > "$temp_dir/chunk_$chunk_count.txt"
        
        chunk_count=$((chunk_count + 1))
        
        # Move start position, accounting for overlap
        start_pos=$((end_pos - overlap_size))
        
        # If we're at the end, break
        if [ $end_pos -eq $content_length ]; then
            break
        fi
    done
    
    echo "$temp_dir:$chunk_count"
}

generate_initial_pr_md() {
    local diff_chunk="$1"
    local is_chunked="$2"
    local chunk_info="$3"
    
    # Get the directory where the script is located to reliably find the project root
    SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
    PROJECT_ROOT="$SCRIPT_DIR/.."

    # Load API key from .env file in the project root
    if [ -f "$PROJECT_ROOT/.env" ]; then
        source "$PROJECT_ROOT/.env"
    fi
    
    if [ -z "$DEEPSEEK_API_KEY" ]; then
        echo "Error: DEEPSEEK_API_KEY environment variable not set."
        echo "Please ensure it is set in the .env file at the project root: $PROJECT_ROOT/.env"
        exit 1
    fi

    local pr_content=$(cat ./pr.md)
    local system_prompt
    local user_content
    
    if [ "$is_chunked" = "true" ]; then
        system_prompt="You are a senior software engineer writing a pull request description. Your task is to complete a PR description template using a full git diff. This is the FIRST CHUNK of a larger diff that will be processed in multiple parts. Adhere strictly to the following rules:\n1. Use the provided PR TEMPLATE as the base for your entire response.\n2. Your primary goal is to replace the '(coming soon)' placeholders in the 'TL;DR', 'Details', and 'How to Test' sections.\n3. The content you generate should be based on the provided GIT DIFF CHUNK, but keep in mind this is only part of the full changes.\n4. PRESERVE THE ENTIRE TEMPLATE STRUCTURE. This includes all HTML comments, markdown formatting, headers, and the existing GIF link.\n5. Be concise and professional.\n6. Since this is the first chunk, provide a comprehensive overview but note that additional details may be added as more chunks are processed."
        user_content="Here is the PR TEMPLATE:\n---\n$pr_content\n---\n\nHere is the FIRST CHUNK of the GIT DIFF ($chunk_info):\n---\n$diff_chunk\n---\n\nNote: This is chunk 1 of multiple chunks. Generate a complete PR description based on this chunk, but be aware that subsequent chunks may provide additional context."
    else
        system_prompt="You are a senior software engineer writing a pull request description. Your task is to complete a PR description template using a git diff --stat summary. Adhere strictly to the following rules:\n1. Use the provided PR TEMPLATE as the base for your entire response.\n2. Your primary goal is to replace the '(coming soon)' placeholders in the 'TL;DR', 'Details', and 'How to Test' sections.\n3. The content you generate should be based on the provided GIT DIFF --STAT SUMMARY, which shows files changed and line counts but not the actual code changes.\n4. PRESERVE THE ENTIRE TEMPLATE STRUCTURE. This includes all HTML comments, markdown formatting, headers, and the existing GIF link.\n5. Be concise and professional.\n6. Focus on high-level changes and file modifications. Note that detailed code analysis will be added in a subsequent phase."
        user_content="Here is the PR TEMPLATE:\n---\n$pr_content\n---\n\nHere is the GIT DIFF --STAT SUMMARY:\n---\n$diff_chunk\n---\n\nNote: This is a statistical summary showing files changed and line counts. Generate an initial PR description based on this overview. Detailed code changes will be processed in a follow-up phase."
    fi
    
    # Build a detailed and specific JSON payload using jq
    payload=$(jq -n \
        --arg system_prompt "$system_prompt" \
        --arg user_content "$user_content" \
        '{
            "model": "deepseek-chat",
            "messages": [
                {
                    "role": "system",
                    "content": $system_prompt
                },
                {
                    "role": "user",
                    "content": $user_content
                }
            ],
            "temperature": 0.5
        }')

    response=$(curl -s -X POST "https://api.deepseek.com/chat/completions" \
        -H "Authorization: Bearer $DEEPSEEK_API_KEY" \
        -H "Content-Type: application/json" \
        -d "$payload")

    if [[ $? -ne 0 ]]; then
        echo "Error: Failed to call DeepSeek API"
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

# Estimate token count for a given text (rough approximation)
estimate_tokens() {
    local text="$1"
    # Rough approximation: ~4 characters per token for English text
    local char_count=${#text}
    echo $(( (char_count + 3) / 4 ))  # Round up division
}

extend_pr_md_batch() {
    local temp_dir="$1"
    local start_chunk="$2"
    local end_chunk="$3"
    local total_chunks="$4"
    
    # Get the directory where the script is located to reliably find the project root
    SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
    PROJECT_ROOT="$SCRIPT_DIR/.."

    # Load API key from .env file in the project root
    if [ -f "$PROJECT_ROOT/.env" ]; then
        source "$PROJECT_ROOT/.env"
    fi

    local current_pr_content=$(cat ./pr.md)
    
    # Combine multiple chunks into a single request
    local combined_chunks=""
    local total_chunk_size=0
    for ((i=start_chunk; i<=end_chunk; i++)); do
        local chunk_content=$(cat "$temp_dir/chunk_$i.txt")
        combined_chunks="$combined_chunks\n\n--- CHUNK $((i+1)) of $total_chunks ---\n$chunk_content"
        total_chunk_size=$((total_chunk_size + ${#chunk_content}))
    done
    
    local system_prompt="You are a senior software engineer extending a pull request description. You have an existing PR description and multiple chunks of a git diff to process. Your task is to update and extend this PR description with additional context from ALL the provided diff chunks. Adhere strictly to the following rules:\n1. Use the provided CURRENT PR DESCRIPTION as the base and extend/refine it.\n2. Update the 'TL;DR', 'Details', and 'How to Test' sections to incorporate insights from ALL the diff chunks.\n3. PRESERVE THE ENTIRE TEMPLATE STRUCTURE. This includes all HTML comments, markdown formatting, headers, and the existing GIF link.\n4. Be concise and professional.\n5. Integrate information from all chunks seamlessly with the existing content.\n6. Do not duplicate information, but do add new insights and details from these chunks."
    
    local user_content="Here is the CURRENT PR DESCRIPTION:\n---\n$current_pr_content\n---\n\nHere are ADDITIONAL GIT DIFF CHUNKS $((start_chunk+1))-$((end_chunk+1)) of $total_chunks:\n$combined_chunks\n\nPlease update and extend the PR description to incorporate the new information from all these chunks while maintaining the existing structure and content."
    
    # Estimate total token usage
    local system_tokens=$(estimate_tokens "$system_prompt")
    local user_tokens=$(estimate_tokens "$user_content")
    local total_estimated_tokens=$((system_tokens + user_tokens))
    
    # DeepSeek limit is 131072 tokens
    local max_tokens=131072
    local safety_margin=5000  # 5k token safety margin
    
    if [ $total_estimated_tokens -gt $((max_tokens - safety_margin)) ]; then
        log "Warning: Estimated token count ($total_estimated_tokens) approaches API limit. Processing chunks individually."
        
        # Process chunks one by one instead of in batch
        for ((i=start_chunk; i<=end_chunk; i++)); do
            local chunk_content=$(cat "$temp_dir/chunk_$i.txt")
            extend_pr_md "$chunk_content" "$((i+1))" "$total_chunks"
        done
        return
    fi
    
    # Build a detailed and specific JSON payload using jq
    payload=$(jq -n \
        --arg system_prompt "$system_prompt" \
        --arg user_content "$user_content" \
        '{
            "model": "deepseek-chat",
            "messages": [
                {
                    "role": "system",
                    "content": $system_prompt
                },
                {
                    "role": "user",
                    "content": $user_content
                }
            ],
            "temperature": 0.5
        }')

    response=$(curl -s -X POST "https://api.deepseek.com/chat/completions" \
        -H "Authorization: Bearer $DEEPSEEK_API_KEY" \
        -H "Content-Type: application/json" \
        -d "$payload")

    if [[ $? -ne 0 ]]; then
        echo "Error: Failed to call DeepSeek API for chunks $((start_chunk+1))-$((end_chunk+1))"
        exit 1
    fi

    # Validate that the response contains the expected content path
    if ! jq -e '.choices[0].message.content' <<<"$response" > /dev/null; then
        echo "Error: API response did not contain expected content for chunks $((start_chunk+1))-$((end_chunk+1))."
        echo "API Response:"
        echo "$response"
        exit 1
    fi

    local raw_content=$(jq -r '.choices[0].message.content' <<<"$response")
    
    # Post-process the response to remove the --- delimiters if they exist
    local cleaned_content=$(echo "$raw_content" | sed '/^---$/d')
    
    # Save updated content to pr.md
    echo "$cleaned_content" > ./pr.md
    log "Extended PR description with chunks $((start_chunk+1))-$((end_chunk+1)) of $total_chunks"
}

extend_pr_md() {
    local diff_chunk="$1"
    local chunk_number="$2"
    local total_chunks="$3"
    
    # Get the directory where the script is located to reliably find the project root
    SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
    PROJECT_ROOT="$SCRIPT_DIR/.."

    # Load API key from .env file in the project root
    if [ -f "$PROJECT_ROOT/.env" ]; then
        source "$PROJECT_ROOT/.env"
    fi

    local current_pr_content=$(cat ./pr.md)
    
    local system_prompt="You are a senior software engineer extending a pull request description. You have an existing PR description that was generated from previous chunks of a git diff. Your task is to update and extend this PR description with additional context from a new chunk of the diff. Adhere strictly to the following rules:\n1. Use the provided CURRENT PR DESCRIPTION as the base and extend/refine it.\n2. Update the 'TL;DR', 'Details', and 'How to Test' sections to incorporate insights from the new diff chunk.\n3. PRESERVE THE ENTIRE TEMPLATE STRUCTURE. This includes all HTML comments, markdown formatting, headers, and the existing GIF link.\n4. Be concise and professional.\n5. Integrate the new information seamlessly with the existing content.\n6. Do not duplicate information, but do add new insights and details from this chunk."
    
    local user_content="Here is the CURRENT PR DESCRIPTION:\n---\n$current_pr_content\n---\n\nHere is ADDITIONAL GIT DIFF CHUNK $chunk_number of $total_chunks:\n---\n$diff_chunk\n---\n\nPlease update and extend the PR description to incorporate the new information from this chunk while maintaining the existing structure and content."
    
    # Build a detailed and specific JSON payload using jq
    payload=$(jq -n \
        --arg system_prompt "$system_prompt" \
        --arg user_content "$user_content" \
        '{
            "model": "deepseek-chat",
            "messages": [
                {
                    "role": "system",
                    "content": $system_prompt
                },
                {
                    "role": "user",
                    "content": $user_content
                }
            ],
            "temperature": 0.5
        }')

    response=$(curl -s -X POST "https://api.deepseek.com/chat/completions" \
        -H "Authorization: Bearer $DEEPSEEK_API_KEY" \
        -H "Content-Type: application/json" \
        -d "$payload")

    if [[ $? -ne 0 ]]; then
        echo "Error: Failed to call DeepSeek API for chunk $chunk_number"
        exit 1
    fi

    # Validate that the response contains the expected content path
    if ! jq -e '.choices[0].message.content' <<<"$response" > /dev/null; then
        echo "Error: API response did not contain expected content for chunk $chunk_number."
        echo "API Response:"
        echo "$response"
        exit 1
    fi

    local raw_content=$(jq -r '.choices[0].message.content' <<<"$response")
    
    # Post-process the response to remove the --- delimiters if they exist
    local cleaned_content=$(echo "$raw_content" | sed '/^---$/d')
    
    # Save updated content to pr.md
    echo "$cleaned_content" > ./pr.md
    log "Extended PR description with chunk $chunk_number of $total_chunks"
}

generate_pr_md_fast() {
    local base_branch="$1"
    
    log "Fast mode: Processing full diff in single API call"
    local full_diff_content=$(git --no-pager diff "$base_branch")
    if [ -z "$full_diff_content" ]; then
        echo "Error: No differences found against branch $base_branch"
        return 1
    fi
    
    local diff_size=${#full_diff_content}
    log "Full diff size: $diff_size characters"
    
    # Get the directory where the script is located to reliably find the project root
    SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
    PROJECT_ROOT="$SCRIPT_DIR/.."

    # Load API key from .env file in the project root
    if [ -f "$PROJECT_ROOT/.env" ]; then
        source "$PROJECT_ROOT/.env"
    fi
    
    if [ -z "$DEEPSEEK_API_KEY" ]; then
        echo "Error: DEEPSEEK_API_KEY environment variable not set."
        echo "Please ensure it is set in the .env file at the project root: $PROJECT_ROOT/.env"
        return 1
    fi

    local pr_content=$(cat ./pr.md)
    
    local system_prompt="You are a senior software engineer writing a pull request description. Your task is to complete a PR description template using a full git diff in a single pass for maximum speed. Adhere strictly to the following rules:\n1. Use the provided PR TEMPLATE as the base for your entire response.\n2. Your primary goal is to replace the '(coming soon)' placeholders in the 'TL;DR', 'Details', and 'How to Test' sections.\n3. The content you generate should be based on the provided COMPLETE GIT DIFF.\n4. PRESERVE THE ENTIRE TEMPLATE STRUCTURE. This includes all HTML comments, markdown formatting, headers, and the existing GIF link.\n5. Be concise and professional.\n6. Provide comprehensive coverage of all changes shown in the diff in a single response."
    
    local user_content="Here is the PR TEMPLATE:\n---\n$pr_content\n---\n\nHere is the COMPLETE GIT DIFF:\n---\n$full_diff_content\n---\n\nGenerate a complete PR description based on the entire diff in a single response."
    
    # Estimate token usage for safety check
    local system_tokens=$(estimate_tokens "$system_prompt")
    local user_tokens=$(estimate_tokens "$user_content")
    local total_estimated_tokens=$((system_tokens + user_tokens))
    
    # DeepSeek limit is 131072 tokens
    local max_tokens=131072
    local safety_margin=10000  # 10k token safety margin for fast mode
    
    if [ $total_estimated_tokens -gt $((max_tokens - safety_margin)) ]; then
        log "Warning: Fast mode would exceed API token limit (estimated: $total_estimated_tokens tokens)"
        log "Falling back to standard two-phase processing for safety"
        return 1
    fi
    
    # Build a detailed and specific JSON payload using jq
    payload=$(jq -n \
        --arg system_prompt "$system_prompt" \
        --arg user_content "$user_content" \
        '{
            "model": "deepseek-chat",
            "messages": [
                {
                    "role": "system",
                    "content": $system_prompt
                },
                {
                    "role": "user",
                    "content": $user_content
                }
            ],
            "temperature": 0.5
        }')

    response=$(curl -s -X POST "https://api.deepseek.com/chat/completions" \
        -H "Authorization: Bearer $DEEPSEEK_API_KEY" \
        -H "Content-Type: application/json" \
        -d "$payload")

    if [[ $? -ne 0 ]]; then
        echo "Error: Failed to call DeepSeek API in fast mode"
        return 1
    fi

    # Validate that the response contains the expected content path
    if ! jq -e '.choices[0].message.content' <<<"$response" > /dev/null; then
        echo "Error: API response did not contain expected content in fast mode."
        echo "API Response:"
        echo "$response"
        return 1
    fi

    local raw_content=$(jq -r '.choices[0].message.content' <<<"$response")
    
    # Post-process the response to remove the --- delimiters if they exist
    local cleaned_content=$(echo "$raw_content" | sed '/^---$/d')
    
    # Save generated content to pr.md
    echo "$cleaned_content" > ./pr.md
    log "Fast mode: Generated complete PR description in single API call"
    return 0
}

generate_pr_md() {
    local base_branch="$1"
    local use_stat_only="$2"
    
    # Phase 1: Generate initial PR description using diff --stat
    log "Phase 1: Generating initial PR description using diff --stat summary"
    local stat_content=$(git --no-pager diff --stat "$base_branch")
    if [ -z "$stat_content" ]; then
        echo "Error: No differences found against branch $base_branch"
        exit 1
    fi
    
    log "Stat summary size: ${#stat_content} characters"
    generate_initial_pr_md "$stat_content" "false" ""
    
    # If --stat flag was provided, stop here
    if [ "$use_stat_only" = "true" ]; then
        log "Using --stat flag, skipping full diff processing"
        return
    fi
    
    # Phase 2: Get full diff and extend PR description with detailed changes
    log "Phase 2: Extending PR description with full diff details"
    local full_diff_content=$(git --no-pager diff "$base_branch")
    local diff_size=${#full_diff_content}
    
    log "Full diff size: $diff_size characters"
    
    # Check if we need to chunk the full diff
    if [ $diff_size -gt $MAX_CHUNK_SIZE ]; then
        log "Full diff exceeds maximum chunk size ($MAX_CHUNK_SIZE chars), falling back to --stat summary only"
        log "Skipping full diff extension to avoid chunking per configuration"
        return
    fi
    
    log "Full diff size is within limits, processing as single extension"
    extend_pr_md "$full_diff_content" "1" "1"
}

refine_pr_md_with_git_log() {
    local base_branch="$1"
    
    log "Running secondary refinement using git log against $base_branch"
    
    local git_log_output
    if ! git_log_output=$(git --no-pager log "$base_branch"..HEAD); then
        log "Failed to retrieve git log for $base_branch..HEAD, skipping refinement step"
        return
    fi
    
    if [ -z "$git_log_output" ]; then
        log "No commits found between $base_branch and current HEAD, skipping refinement step"
        return
    fi
    
    # Get the directory where the script is located to reliably find the project root
    SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
    PROJECT_ROOT="$SCRIPT_DIR/.."

    # Load API key from .env file in the project root
    if [ -f "$PROJECT_ROOT/.env" ]; then
        source "$PROJECT_ROOT/.env"
    fi
    
    local refined="false"
    
    if [ -z "$DEEPSEEK_API_KEY" ]; then
        log "DEEPSEEK_API_KEY not set, skipping API refinement step"
    else
        local pr_content=$(cat ./pr.md)
        local system_prompt="You are a senior software engineer refining a pull request description. Your task is to adjust the existing PR description so it better reflects the commits listed in the git log. Adhere strictly to the following rules:\n1. Use the provided CURRENT PR DESCRIPTION as the base and refine it without changing the overall template structure.\n2. Ensure the TL;DR, Details, and How to Test sections align with the commit messages and scope described in the git log.\n3. Preserve all existing markdown structure, HTML comments, and asset links.\n4. Keep the tone concise and professional.\n5. Only make adjustments that are justified by the git log content."
        
        local user_content="Here is the CURRENT PR DESCRIPTION:\n---\n$pr_content\n---\n\nHere is the GIT LOG for $base_branch..HEAD:\n\`\`\`text\n$git_log_output\n\`\`\`\n\nRefine the PR description so it better reflects the changes described in this git log while preserving the existing structure."

        payload=$(jq -n \
            --arg system_prompt "$system_prompt" \
            --arg user_content "$user_content" \
            '{
                "model": "deepseek-chat",
                "messages": [
                    {
                        "role": "system",
                        "content": $system_prompt
                    },
                    {
                        "role": "user",
                        "content": $user_content
                    }
                ],
                "temperature": 0.5
            }')

        response=$(curl -s -X POST "https://api.deepseek.com/chat/completions" \
            -H "Authorization: Bearer $DEEPSEEK_API_KEY" \
            -H "Content-Type: application/json" \
            -d "$payload")

        if [[ $? -ne 0 ]]; then
            log "Error: Failed to call DeepSeek API for refinement step"
        elif ! jq -e '.choices[0].message.content' <<<"$response" > /dev/null; then
            log "Error: API response did not contain expected content during refinement"
            log "API Response: $response"
        else
            local refined_content=$(jq -r '.choices[0].message.content' <<<"$response" | sed '/^---$/d')
            echo "$refined_content" > ./pr.md
            refined="true"
            log "Refinement step complete"
        fi
    fi
    
    if [ "$refined" != "true" ]; then
        log "Refinement step skipped or failed; keeping existing PR description content"
    fi
}

main() {
    if [ -z "$1" ]; then
        echo "Usage: ./ai/prmd.sh BASE_BRANCH [--stat]"
        echo "Example: ./ai/prmd.sh main"
        echo "         ./ai/prmd.sh main --stat  (use statistical summary only)"
        echo ""
        echo "Default behavior: Try to process full diff in single API call first,"
        echo "fall back to stat summary + parallel chunks if diff is too large"
        exit 1
    fi

    local base_branch="$1"
    local use_stat="false"
    
    # Check for flags
    if [ "$2" = "--stat" ]; then
        use_stat="true"
        log "Using statistical diff summary only (--stat flag provided)"
    else
        log "Using optimized approach: try full diff first, fall back if needed"
    fi
    
    log "Starting PR description generation against $base_branch..."
    
    # Determine which template to use
    local template_path=$(get_template_path)
    if [ "$template_path" = "./.github/pull_request_template.md" ]; then
        log "Using local .github/pull_request_template.md"
    else
        log "Using default pull request template"
    fi
    cp "$template_path" ./pr.md

    # Generate PR description using appropriate approach
    if [ "$use_stat" = "true" ]; then
        generate_pr_md "$base_branch" "$use_stat"
    else
        # Try fast mode first, fall back to standard approach if it fails
        if ! generate_pr_md_fast "$base_branch"; then
            generate_pr_md "$base_branch" "false"
        fi
    fi
    
    refine_pr_md_with_git_log "$base_branch"
}

# Wrap main execution to ensure cleanup
{
    main "$@"
    
    # Copy the PR description to clipboard
    log "Copying PR description to clipboard..."
    pbcopy < ./pr.md
    
    # Print the PR description to stdout
    cat ./pr.md
    
    log "PR description generation complete"
}
