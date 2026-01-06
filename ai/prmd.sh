#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ai/lib/provider.sh
. "${SCRIPT_DIR}/lib/provider.sh"

DEFAULT_PULL_REQUEST_TEMPLATE="$HOME/src/pstaylor-patrick/utility-scripts/ai/prmd/pull_request_template.md"
COMMAND_NAME="prmd"


usage() {
    cat <<EOF
Usage: $0 [-c] [-d] [-x] [--stat] [-t <name>] <base-branch>

Options:
  -c, --claude              Use Claude Code CLI for AI operations.
  -d, --deepseek            Use DeepSeek API for AI operations.
  -x, --codex               Use OpenAI Codex for AI operations (default).
  -t, --template <name>     Use a specific PR template from .github/PULL_REQUEST_TEMPLATE/<name>.md.
  --completion [bash|zsh]   Print shell completion script for ${COMMAND_NAME}.
  --stat                    Use git diff --stat summary only.
  -h, --help                Show this help message.

Template Resolution:
  Templates are searched in this order:
    1. User-specified via -t <name> (e.g., -t release uses release.md)
    2. .github/PULL_REQUEST_TEMPLATE/feature.md (default if multiple exist)
    3. First .github/PULL_REQUEST_TEMPLATE/*.md alphabetically
    4. .github/pull_request_template.md
    5. Default template (~/.../ai/prmd/pull_request_template.md)
EOF
}

# Configuration for chunking to keep prompts within a safe size
MAX_CHUNK_SIZE=30000  # Reduced chunk size to stay within token limits
OVERLAP_SIZE=200     # Reduced overlap for speed
BATCH_SIZE=6         # Increased batch size to match parallel jobs
ENABLE_PARALLEL=true # Enable parallel processing
PARALLEL_JOBS=6      # Number of parallel jobs to run (scaled to 6)

print_completion_script() {
    local target_shell="${1:-}"

    if [ -z "$target_shell" ]; then
        if [ -n "${ZSH_VERSION:-}" ] || [ "$(basename "${SHELL:-}")" = "zsh" ]; then
            target_shell="zsh"
        else
            target_shell="bash"
        fi
    fi

    case "$target_shell" in
        bash)
            cat <<EOF
_${COMMAND_NAME}_branch_completions() {
    if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        return
    fi

    git for-each-ref --format='%(refname:short)' refs/heads refs/remotes 2>/dev/null \\
        | grep -vE '^origin/HEAD$' \\
        | LC_ALL=C sort -u
}

_${COMMAND_NAME}_complete() {
    local cur prev
    cur="\${COMP_WORDS[COMP_CWORD]}"
    prev="\${COMP_WORDS[COMP_CWORD-1]}"

    COMPREPLY=()

    if [[ "\$prev" == "--completion" ]]; then
        if type mapfile >/dev/null 2>&1; then
            mapfile -t COMPREPLY < <(compgen -W "bash zsh" -- "\$cur")
        else
            IFS=\$'\n' COMPREPLY=(\$(compgen -W "bash zsh" -- "\$cur"))
        fi
        return
    fi

    if [[ "\$prev" == "-t" ]] || [[ "\$prev" == "--template" ]]; then
        # Complete template names from .github/PULL_REQUEST_TEMPLATE/
        local template_dir=".github/PULL_REQUEST_TEMPLATE"
        if [ -d "\$template_dir" ]; then
            local templates
            templates=\$(find "\$template_dir" -maxdepth 1 -name "*.md" -type f 2>/dev/null | xargs -I{} basename {} .md | LC_ALL=C sort)
            if [ -n "\$templates" ]; then
                if type mapfile >/dev/null 2>&1; then
                    mapfile -t COMPREPLY < <(compgen -W "\$templates" -- "\$cur")
                else
                    IFS=\$'\n' COMPREPLY=(\$(compgen -W "\$templates" -- "\$cur"))
                fi
            fi
        fi
        return
    fi

    if [[ "\$cur" == --* ]]; then
        if type mapfile >/dev/null 2>&1; then
            mapfile -t COMPREPLY < <(compgen -W "--stat --template --completion --help -h -c -d -x -t" -- "\$cur")
        else
            IFS=\$'\n' COMPREPLY=(\$(compgen -W "--stat --template --completion --help -h -c -d -x -t" -- "\$cur"))
        fi
        return
    fi

    local branches
    branches=\$(_${COMMAND_NAME}_branch_completions)

    if [ -n "\$branches" ]; then
        # macOS ships an older bash without mapfile; fall back to array expansion when unavailable
        if type mapfile >/dev/null 2>&1; then
            mapfile -t COMPREPLY < <(compgen -W "\$branches" -- "\$cur")
        else
            IFS=\$'\n' COMPREPLY=(\$(compgen -W "\$branches" -- "\$cur"))
        fi
    fi
}

complete -o default -F _${COMMAND_NAME}_complete ${COMMAND_NAME}
EOF
            ;;
        zsh)
            local cmd="$COMMAND_NAME"
            cat <<EOF
#compdef ${cmd}

# Initialize zsh completion system if it isn't already
if ! type compdef >/dev/null 2>&1; then
    autoload -Uz compinit && compinit
fi

_${cmd}_branch_completions() {
    if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        return
    fi

    git for-each-ref --format='%(refname:short)' refs/heads refs/remotes 2>/dev/null \\
        | grep -vE '^origin/HEAD$' \\
        | LC_ALL=C sort -u
}

_${cmd}_template_completions() {
    local template_dir=".github/PULL_REQUEST_TEMPLATE"
    if [ -d "\$template_dir" ]; then
        find "\$template_dir" -maxdepth 1 -name "*.md" -type f 2>/dev/null \\
            | xargs -I{} basename {} .md \\
            | LC_ALL=C sort
    fi
}

_${cmd}_complete() {
    _arguments \\
        '(-h --help)'{-h,--help}'[show help]' \\
        '--stat[use git diff --stat summary]' \\
        '(-t --template)'{-t,--template}'[use specific PR template]:template:_${cmd}_template_completions' \\
        '--completion[print shell completion script]:shell:(bash zsh)' \\
        '-c[use Claude Code]' \\
        '-d[use DeepSeek API]' \\
        '-x[use OpenAI Codex]' \\
        '*:branch:_${cmd}_branch_completions'
}

compdef _${cmd}_complete ${cmd}
EOF
            ;;
        *)
            echo "Error: unsupported shell '${target_shell}'. Use 'bash' or 'zsh'." >&2
            exit 1
            ;;
    esac
}

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >&2
}

require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Error: $1 is required but not installed or on PATH." >&2
        exit 1
    fi
}

# Ensure the PR template starts with an H1 title placeholder
ensure_title_placeholder() {
    local pr_file="./pr.md"
    local placeholder="# pr title"
    local first_line
    first_line=$(awk 'NF {print; exit}' "$pr_file" 2>/dev/null)
    local first_line_trimmed
    first_line_trimmed=$(printf "%s" "$first_line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

    if [ -z "$first_line_trimmed" ]; then
        log "Adding top-level PR title placeholder"
        printf "%s\n\n%s\n" "$placeholder" "$(cat "$pr_file" 2>/dev/null)" > "$pr_file"
        return
    fi

    if [[ "$first_line_trimmed" =~ ^#([^#]|$) ]]; then
        if [ "$first_line_trimmed" != "$placeholder" ]; then
            log "Replacing existing top-level heading with PR title placeholder"
            awk -v placeholder="$placeholder" '
                BEGIN {replaced=0}
                {
                    if (!replaced && $0 ~ /[^[:space:]]/) {
                        print placeholder
                        replaced=1
                        next
                    }
                    print
                }
            ' "$pr_file" > "${pr_file}.tmp" && mv "${pr_file}.tmp" "$pr_file"
        fi
    else
        log "Adding top-level PR title placeholder"
        printf "%s\n\n%s\n" "$placeholder" "$(cat "$pr_file" 2>/dev/null)" > "$pr_file"
    fi
}

# Normalize AI responses to just the PR body (no preamble or fences)
clean_ai_output() {
    local raw_output="$1"

    # Strip separators and code fences AI sometimes wraps responses with
    local cleaned_output
    cleaned_output=$(printf "%s\n" "$raw_output" | sed '/^---$/d' | sed '/^```[[:alnum:]]*[[:space:]]*$/d')

    # Drop any leading blank lines
    cleaned_output=$(printf "%s\n" "$cleaned_output" | sed '/./,$!d')

    # Use the current PR template bounds (first/last non-empty lines) to slice out any pre/postamble
    local start_marker=""
    local end_marker=""
    if [ -f "./pr.md" ]; then
        start_marker=$(awk 'NF{gsub(/^[ \t]+|[ \t]+$/,""); print; exit}' ./pr.md)
        end_marker=$(awk 'NF{line=$0; gsub(/^[ \t]+|[ \t]+$/,"",line); last=line} END{print last}' ./pr.md)
    fi

    if [ -n "$start_marker" ]; then
        local anchored_output
        anchored_output=$(printf "%s\n" "$cleaned_output" | awk -v start="$start_marker" '
            BEGIN {capture=0}
            {
                line_trim=$0
                gsub(/^[ \t]+|[ \t]+$/,"",line_trim)
                if (capture==0 && line_trim==start) {
                    capture=1
                }
                if (capture) {
                    print
                }
            }
        ')
        if [ -n "$anchored_output" ]; then
            cleaned_output="$anchored_output"
        fi
    fi

    # Remove any preface before the start of a markdown heading/comment as a fallback
    local body_only
    body_only=$(printf "%s\n" "$cleaned_output" | awk '
        BEGIN {capture=0}
        /^[[:space:]]*<!--/ {capture=1}
        /^[[:space:]]*##/ {capture=1}
        /^[[:space:]]*###/ {capture=1}
        capture {print}
    ')
    if [ -n "$body_only" ]; then
        cleaned_output="$body_only"
    fi

    if [ -n "$end_marker" ]; then
        cleaned_output=$(printf "%s\n" "$cleaned_output" | awk -v end="$end_marker" '
            {
                lines[NR] = $0
                line_trim=$0
                gsub(/^[ \t]+|[ \t]+$/,"",line_trim)
                if (line_trim == end) {
                    last = NR
                }
            }
            END {
                max = (last > 0) ? last : NR
                for (i = 1; i <= max; i++) {
                    print lines[i]
                }
            }
        ')
    fi

    # Trim trailing blank lines (portable, works with BSD awk)
    cleaned_output=$(printf "%s\n" "$cleaned_output" | awk '
        {
            lines[NR] = $0
            if ($0 ~ /[^[:space:]]/) {
                last = NR
            }
        }
        END {
            for (i = 1; i <= last; i++) {
                print lines[i]
            }
        }
    ')

    echo "$cleaned_output"
}

run_ai_prompt() {
    local prompt="$1"
    local context="${2:-ai}"
    local output

    if ! output=$(ai_exec "$prompt"); then
        log "${AI_BACKEND} exec failed while ${context}"
        return 1
    fi

    clean_ai_output "$output"
}

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

    local chunk_content
    chunk_content=$(cat "$chunk_file")

    local prompt
    prompt=$(cat <<EOF
You are a senior software engineer extending a pull request description. You have an existing PR description that was generated from previous chunks of a git diff. Your task is to update and extend this PR description with additional context from a new chunk of the diff. Adhere strictly to the following rules:
1. Use the provided CURRENT PR DESCRIPTION as the base and extend/refine it.
2. Update the 'TL;DR', 'Details', and 'How to Test' sections to incorporate insights from the new diff chunk.
3. PRESERVE THE ENTIRE TEMPLATE STRUCTURE. This includes all HTML comments, markdown formatting, headers, and the existing GIF link.
4. Be concise and professional.
5. Integrate the new information seamlessly with the existing content.
6. Do not duplicate information, but do add new insights and details from this chunk.
7. Update the top-level '# ...' PR title so it succinctly reflects the changes introduced in this chunk.
8. Return only the updated PR description markdown with no additional commentary or preamble.

CURRENT PR DESCRIPTION:
---
$(cat ./pr.md)
---

ADDITIONAL GIT DIFF CHUNK $chunk_num of $total_chunks:
---
$chunk_content
---

Please update and extend the PR description to incorporate the new information from this chunk while maintaining the existing structure and content.
EOF
)

    local cleaned_content
    if ! cleaned_content=$(run_ai_prompt "$prompt" "processing chunk $chunk_num/$total_chunks"); then
        echo "Error: Failed to call ${AI_BACKEND} for chunk $chunk_num" >&2
        return 1
    fi

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

    local prompt
    prompt=$(cat <<EOF
You are a senior software engineer integrating multiple PR description analyses. Your task is to merge the analysis from a new chunk with the existing PR description. Adhere strictly to the following rules:
1. Use the provided CURRENT PR DESCRIPTION as the base.
2. Integrate insights from the NEW CHUNK ANALYSIS seamlessly.
3. PRESERVE THE ENTIRE TEMPLATE STRUCTURE including all HTML comments, markdown formatting, headers, and the existing GIF link.
4. Be concise and professional.
5. Do not duplicate information, but do add new insights and details.
6. Maintain logical flow and coherence.
7. Update the top-level '# ...' PR title so it succinctly reflects the merged changes.
8. Return only the updated PR description markdown with no additional commentary or preamble.

CURRENT PR DESCRIPTION:
---
$current_pr_content
---

ANALYSIS FROM CHUNK $chunk_num:
---
$chunk_analysis
---

Please merge these analyses into a single coherent PR description while maintaining the existing structure.
EOF
)

    local cleaned_content
    if ! cleaned_content=$(run_ai_prompt "$prompt" "integrating chunk $chunk_num"); then
        echo "Error: Failed to call ${AI_BACKEND} for integration" >&2
        return 1
    fi

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

# Get template from .github/PULL_REQUEST_TEMPLATE/ directory
# Args: $1 = optional user-specified template name (without .md extension)
# Returns: path to template file, or empty string if not found
get_template_from_directory() {
    local user_template="${1:-}"
    local template_dir="./.github/PULL_REQUEST_TEMPLATE"

    # Check if the directory exists
    if [ ! -d "$template_dir" ]; then
        return 1
    fi

    # If user specified a template name, look for it
    if [ -n "$user_template" ]; then
        local user_template_path="$template_dir/${user_template}.md"
        if [ -f "$user_template_path" ]; then
            echo "$user_template_path"
            return 0
        else
            # User specified a template that doesn't exist - fatal error
            echo "Error: Template '${user_template}' not found at ${user_template_path}" >&2
            echo "" >&2
            echo "Available templates in ${template_dir}:" >&2
            local available_templates
            available_templates=$(find "$template_dir" -maxdepth 1 -name "*.md" -type f 2>/dev/null | sort)
            if [ -n "$available_templates" ]; then
                echo "$available_templates" | while read -r tmpl; do
                    local name
                    name=$(basename "$tmpl" .md)
                    echo "  - $name" >&2
                done
            else
                echo "  (no templates found)" >&2
            fi
            return 2
        fi
    fi

    # No user-specified template - check for feature.md first
    local feature_template="$template_dir/feature.md"
    if [ -f "$feature_template" ]; then
        echo "$feature_template"
        return 0
    fi

    # Fall back to first .md file alphabetically
    local first_template
    first_template=$(find "$template_dir" -maxdepth 1 -name "*.md" -type f 2>/dev/null | sort | head -n 1)
    if [ -n "$first_template" ]; then
        echo "$first_template"
        return 0
    fi

    # No templates found in directory
    return 1
}

# Get the PR template path with priority resolution
# Args: $1 = optional user-specified template name
# Returns: 0 on success with path echoed, 1 on error
get_template_path() {
    local user_template="${1:-}"

    # Try to get template from .github/PULL_REQUEST_TEMPLATE/ directory
    local dir_template
    dir_template=$(get_template_from_directory "$user_template")
    local result=$?

    # If user specified a template that doesn't exist, return error
    if [ $result -eq 2 ]; then
        return 1
    fi

    # If we found a template in the directory, use it
    if [ $result -eq 0 ] && [ -n "$dir_template" ]; then
        echo "$dir_template"
        return 0
    fi

    # If user specified a template but directory doesn't exist, that's also an error
    if [ -n "$user_template" ]; then
        echo "Error: Template directory .github/PULL_REQUEST_TEMPLATE/ not found." >&2
        echo "Cannot use -t/--template flag without this directory." >&2
        return 1
    fi

    # Fall back to single-file template
    local github_template="./.github/pull_request_template.md"
    if [ -f "$github_template" ]; then
        echo "$github_template"
    else
        echo "$DEFAULT_PULL_REQUEST_TEMPLATE"
    fi
    return 0
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

    local pr_content=$(cat ./pr.md)
    local prompt

    if [ "$is_chunked" = "true" ]; then
        prompt=$(cat <<EOF
You are a senior software engineer writing a pull request description. Your task is to complete a PR description template using a full git diff. This is the FIRST CHUNK of a larger diff that will be processed in multiple parts. Adhere strictly to the following rules:
1. Use the provided PR TEMPLATE as the base for your entire response.
2. Your primary goal is to replace the '(coming soon)' placeholders in the 'TL;DR', 'Details', and 'How to Test' sections.
3. The content you generate should be based on the provided GIT DIFF CHUNK, but keep in mind this is only part of the full changes.
4. PRESERVE THE ENTIRE TEMPLATE STRUCTURE. This includes all HTML comments, markdown formatting, headers, and the existing GIF link.
5. Be concise and professional.
6. Since this is the first chunk, provide a comprehensive overview but note that additional details may be added as more chunks are processed.
7. Update the top-level '# ...' PR title so it succinctly reflects the changes from this chunk.
8. Return only the updated PR description markdown with no additional commentary or preamble.

PR TEMPLATE:
---
$pr_content
---

FIRST CHUNK of the GIT DIFF ($chunk_info):
---
$diff_chunk
---

Note: This is chunk 1 of multiple chunks. Generate a complete PR description based on this chunk, but be aware that subsequent chunks may provide additional context.
EOF
)
    else
        prompt=$(cat <<EOF
You are a senior software engineer writing a pull request description. Your task is to complete a PR description template using a git diff --stat summary. Adhere strictly to the following rules:
1. Use the provided PR TEMPLATE as the base for your entire response.
2. Your primary goal is to replace the '(coming soon)' placeholders in the 'TL;DR', 'Details', and 'How to Test' sections.
3. The content you generate should be based on the provided GIT DIFF --STAT SUMMARY, which shows files changed and line counts but not the actual code changes.
4. PRESERVE THE ENTIRE TEMPLATE STRUCTURE. This includes all HTML comments, markdown formatting, headers, and the existing GIF link.
5. Be concise and professional.
6. Focus on high-level changes and file modifications. Note that detailed code analysis will be added in a subsequent phase.
7. Update the top-level '# ...' PR title so it succinctly reflects the changes implied by this summary.
8. Return only the updated PR description markdown with no additional commentary or preamble.

PR TEMPLATE:
---
$pr_content
---

GIT DIFF --STAT SUMMARY:
---
$diff_chunk
---

Note: This is a statistical summary showing files changed and line counts. Generate an initial PR description based on this overview. Detailed code changes will be processed in a follow-up phase.
EOF
)
    fi

    local cleaned_content
    if ! cleaned_content=$(run_ai_prompt "$prompt" "building initial PR description"); then
        echo "Error: Failed to call ${AI_BACKEND} for initial PR description." >&2
        exit 1
    fi

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

    local current_pr_content=$(cat ./pr.md)

    # Combine multiple chunks into a single request
    local combined_chunks=""
    local total_chunk_size=0
    for ((i=start_chunk; i<=end_chunk; i++)); do
        local chunk_content=$(cat "$temp_dir/chunk_$i.txt")
        combined_chunks="$combined_chunks\n\n--- CHUNK $((i+1)) of $total_chunks ---\n$chunk_content"
        total_chunk_size=$((total_chunk_size + ${#chunk_content}))
    done

    local prompt
    prompt=$(cat <<EOF
You are a senior software engineer extending a pull request description. You have an existing PR description and multiple chunks of a git diff to process. Your task is to update and extend this PR description with additional context from ALL the provided diff chunks. Adhere strictly to the following rules:
1. Use the provided CURRENT PR DESCRIPTION as the base and extend/refine it.
2. Update the 'TL;DR', 'Details', and 'How to Test' sections to incorporate insights from ALL the diff chunks.
3. PRESERVE THE ENTIRE TEMPLATE STRUCTURE. This includes all HTML comments, markdown formatting, headers, and the existing GIF link.
4. Be concise and professional.
5. Integrate information from all chunks seamlessly with the existing content.
6. Do not duplicate information, but do add new insights and details from these chunks.
7. Update the top-level '# ...' PR title so it succinctly reflects the combined changes from these chunks.
8. Return only the updated PR description markdown with no additional commentary or preamble.

CURRENT PR DESCRIPTION:
---
$current_pr_content
---

ADDITIONAL GIT DIFF CHUNKS $((start_chunk+1))-$((end_chunk+1)) of $total_chunks:
$combined_chunks

Please update and extend the PR description to incorporate the new information from all these chunks while maintaining the existing structure and content.
EOF
)

    # Estimate total token usage
    local total_estimated_tokens=$(estimate_tokens "$prompt")

    local max_tokens=120000
    local safety_margin=5000  # 5k token safety margin

    if [ $total_estimated_tokens -gt $((max_tokens - safety_margin)) ]; then
        log "Warning: Estimated token count ($total_estimated_tokens) approaches the token budget. Processing chunks individually."

        # Process chunks one by one instead of in batch
        for ((i=start_chunk; i<=end_chunk; i++)); do
            local chunk_content=$(cat "$temp_dir/chunk_$i.txt")
            extend_pr_md "$chunk_content" "$((i+1))" "$total_chunks"
        done
        return
    fi

    local cleaned_content
    if ! cleaned_content=$(run_ai_prompt "$prompt" "extending chunks $((start_chunk+1))-$((end_chunk+1))"); then
        echo "Error: Failed to call ${AI_BACKEND} for chunks $((start_chunk+1))-$((end_chunk+1))" >&2
        exit 1
    fi

    # Save updated content to pr.md
    echo "$cleaned_content" > ./pr.md
    log "Extended PR description with chunks $((start_chunk+1))-$((end_chunk+1)) of $total_chunks"
}

extend_pr_md() {
    local diff_chunk="$1"
    local chunk_number="$2"
    local total_chunks="$3"
    local current_pr_content=$(cat ./pr.md)

    local prompt
    prompt=$(cat <<EOF
You are a senior software engineer extending a pull request description. You have an existing PR description that was generated from previous chunks of a git diff. Your task is to update and extend this PR description with additional context from a new chunk of the diff. Adhere strictly to the following rules:
1. Use the provided CURRENT PR DESCRIPTION as the base and extend/refine it.
2. Update the 'TL;DR', 'Details', and 'How to Test' sections to incorporate insights from the new diff chunk.
3. PRESERVE THE ENTIRE TEMPLATE STRUCTURE. This includes all HTML comments, markdown formatting, headers, and the existing GIF link.
4. Be concise and professional.
5. Integrate the new information seamlessly with the existing content.
6. Do not duplicate information, but do add new insights and details from this chunk.
7. Update the top-level '# ...' PR title so it succinctly reflects the changes introduced in this chunk.
8. Return only the updated PR description markdown with no additional commentary or preamble.

CURRENT PR DESCRIPTION:
---
$current_pr_content
---

ADDITIONAL GIT DIFF CHUNK $chunk_number of $total_chunks:
---
$diff_chunk
---

Please update and extend the PR description to incorporate the new information from this chunk while maintaining the existing structure and content.
EOF
)

    local cleaned_content
    if ! cleaned_content=$(run_ai_prompt "$prompt" "extending chunk $chunk_number/$total_chunks"); then
        echo "Error: Failed to call ${AI_BACKEND} for chunk $chunk_number" >&2
        exit 1
    fi

    # Save updated content to pr.md
    echo "$cleaned_content" > ./pr.md
    log "Extended PR description with chunk $chunk_number of $total_chunks"
}

generate_pr_md_fast() {
    local base_branch="$1"
    
    log "Fast mode: Processing full diff in single ${AI_BACKEND} call"
    local full_diff_content=$(git --no-pager diff "$base_branch")
    if [ -z "$full_diff_content" ]; then
        echo "Error: No differences found against branch $base_branch"
        return 1
    fi

    local diff_size=${#full_diff_content}
    log "Full diff size: $diff_size characters"

    local pr_content=$(cat ./pr.md)
    local prompt
    prompt=$(cat <<EOF
You are a senior software engineer writing a pull request description. Your task is to complete a PR description template using a full git diff in a single pass for maximum speed. Adhere strictly to the following rules:
1. Use the provided PR TEMPLATE as the base for your entire response.
2. Your primary goal is to replace the '(coming soon)' placeholders in the 'TL;DR', 'Details', and 'How to Test' sections.
3. The content you generate should be based on the provided COMPLETE GIT DIFF.
4. PRESERVE THE ENTIRE TEMPLATE STRUCTURE. This includes all HTML comments, markdown formatting, headers, and the existing GIF link.
5. Be concise and professional.
6. Provide comprehensive coverage of all changes shown in the diff in a single response.
7. Update the top-level '# ...' PR title so it succinctly reflects the overall changes in the diff.
8. Return only the updated PR description markdown with no additional commentary or preamble.

PR TEMPLATE:
---
$pr_content
---

COMPLETE GIT DIFF:
---
$full_diff_content
---

Generate a complete PR description based on the entire diff in a single response.
EOF
)

    # Estimate token usage for safety check
    local total_estimated_tokens=$(estimate_tokens "$prompt")

    local max_tokens=120000
    local safety_margin=10000  # 10k token safety margin for fast mode

    if [ $total_estimated_tokens -gt $((max_tokens - safety_margin)) ]; then
        log "Warning: Fast mode would exceed token budget (estimated: $total_estimated_tokens tokens)"
        log "Falling back to standard two-phase processing for safety"
        return 1
    fi

    local cleaned_content
    if ! cleaned_content=$(run_ai_prompt "$prompt" "fast mode PR description"); then
        echo "Error: Failed to call ${AI_BACKEND} in fast mode" >&2
        return 1
    fi

    # Save generated content to pr.md
    echo "$cleaned_content" > ./pr.md
    log "Fast mode: Generated complete PR description in single ${AI_BACKEND} call"
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

    local refined="false"

    local pr_content=$(cat ./pr.md)
    local prompt
    prompt=$(cat <<EOF
You are a senior software engineer refining a pull request description. Your task is to adjust the existing PR description so it better reflects the commits listed in the git log. Adhere strictly to the following rules:
1. Use the provided CURRENT PR DESCRIPTION as the base and refine it without changing the overall template structure.
2. Ensure the TL;DR, Details, and How to Test sections align with the commit messages and scope described in the git log.
3. Preserve all existing markdown structure, HTML comments, and asset links.
4. Keep the tone concise and professional.
5. Only make adjustments that are justified by the git log content.
6. Update the top-level '# ...' PR title so it reflects the changes implied by the commits.
7. Return only the updated PR description markdown with no additional commentary or preamble.

CURRENT PR DESCRIPTION:
---
$pr_content
---

GIT LOG for $base_branch..HEAD:
\`\`\`text
$git_log_output
\`\`\`

Refine the PR description so it better reflects the changes described in this git log while preserving the existing structure.
EOF
)

    local refined_content
    if refined_content=$(run_ai_prompt "$prompt" "refining with git log"); then
        echo "$refined_content" > ./pr.md
        refined="true"
        log "Refinement step complete"
    else
        log "Error: ${AI_BACKEND} refinement step failed"
    fi

    if [ "$refined" != "true" ]; then
        log "Refinement step skipped or failed; keeping existing PR description content"
    fi
}

main() {
    local base_branch=""
    local use_stat="false"
    local template_name=""

    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            --help|-h)
                usage
                exit 0
                ;;
            --completion)
                print_completion_script "${2:-}"
                exit 0
                ;;
            --stat)
                use_stat="true"
                ;;
            -t|--template)
                if [ -z "${2:-}" ] || [[ "${2:-}" == -* ]]; then
                    echo "Error: -t/--template requires a template name argument." >&2
                    usage >&2
                    exit 1
                fi
                template_name="$2"
                shift
                ;;
            -c|--claude)
                ai_set_provider claude
                ;;
            -d|--deepseek)
                ai_set_provider deepseek
                ;;
            -x|--codex)
                ai_set_provider codex
                ;;
            --*)
                echo "Error: unknown option '$1'." >&2
                usage >&2
                exit 1
                ;;
            -*)
                echo "Error: unknown option '$1'." >&2
                usage >&2
                exit 1
                ;;
            *)
                if [ -z "$base_branch" ]; then
                    base_branch="$1"
                else
                    echo "Error: too many arguments provided." >&2
                    usage >&2
                    exit 1
                fi
                ;;
        esac
        shift
    done

    if [ -z "$base_branch" ]; then
        usage >&2
        exit 1
    fi

    require_cmd git
    ai_require_provider

    # Check for flags
    if [ "$use_stat" = "true" ]; then
        log "Using statistical diff summary only (--stat flag provided)"
    else
        log "Using optimized approach: try full diff first, fall back if needed"
    fi

    log "AI provider: $(ai_provider_name)"
    log "Starting PR description generation against $base_branch..."

    # Determine which template to use
    local template_path
    if ! template_path=$(get_template_path "$template_name"); then
        exit 1
    fi
    if [[ "$template_path" == "./.github/PULL_REQUEST_TEMPLATE/"* ]]; then
        log "Using template: $template_path"
    elif [ "$template_path" = "./.github/pull_request_template.md" ]; then
        log "Using local .github/pull_request_template.md"
    else
        log "Using default pull request template"
    fi
    cp "$template_path" ./pr.md
    ensure_title_placeholder

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

    # Open the generated PR description in VS Code for quick review/editing
    log "Opening PR description in VS Code..."
    code ./pr.md

    # Print the PR description to stdout
    cat ./pr.md

    log "PR description generation complete"
}
