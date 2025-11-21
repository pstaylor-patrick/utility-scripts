#!/usr/bin/env bash

set -euo pipefail

command_name="pra"

usage() {
    cat <<EOF
Usage: $0 <base-branch>

Options:
  --completion [bash|zsh]   Print shell completion script for ${command_name}.
EOF
}

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
            cat <<'EOF'
_pra_branch_completions() {
    if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        return
    fi

    git for-each-ref --format='%(refname:short)' refs/heads refs/remotes 2>/dev/null \
        | grep -vE '^origin/HEAD$' \
        | LC_ALL=C sort -u
}

_pra_complete() {
    local cur
    cur="${COMP_WORDS[COMP_CWORD]}"

    COMPREPLY=()
    local branches
    branches=$(_pra_branch_completions)

    if [ -n "$branches" ]; then
        mapfile -t COMPREPLY < <(compgen -W "$branches" -- "$cur")
    fi
}

complete -o default -F _pra_complete pra
EOF
            ;;
        zsh)
            cat <<'EOF'
#compdef pra

_pra_branch_completions() {
    if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        return
    fi

    git for-each-ref --format='%(refname:short)' refs/heads refs/remotes 2>/dev/null \
        | grep -vE '^origin/HEAD$' \
        | LC_ALL=C sort -u
}

_pra_complete() {
    local -a branches
    branches=(${(f)$(_pra_branch_completions)})
    _describe 'branch' branches
}

compdef _pra_complete pra
EOF
            ;;
        *)
            echo "Error: unsupported shell '${target_shell}'. Use 'bash' or 'zsh'." >&2
            exit 1
            ;;
    esac
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    usage
    exit 0
fi

if [[ "${1:-}" == "--completion" ]]; then
    print_completion_script "${2:-}"
    exit 0
fi

if ! command -v codex >/dev/null 2>&1; then
    echo "Error: codex CLI is not installed or not on PATH." >&2
    exit 1
fi

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "Error: This script must be run inside a git repository." >&2
    exit 1
fi

if [ "$#" -lt 1 ]; then
    usage >&2
    exit 1
fi

base_branch="$1"
diff_stat=$(git diff "$base_branch" --stat)
commit_log=$(git log --oneline "${base_branch}"..HEAD)

if [ -z "$commit_log" ]; then
    commit_log="(no commits between HEAD and ${base_branch})"
fi

prompt=$(cat <<EOF
study each file in this diff and report back on any major code quality issues, recommended refactors, or security vulnerabilities.

Diff against ${base_branch}:
${diff_stat}

Commit log from HEAD back to ${base_branch}:
${commit_log}
EOF
)

codex exec "${prompt}"
