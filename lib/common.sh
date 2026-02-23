#!/usr/bin/env bash
# common.sh — shared utilities for yolobox

set -euo pipefail

# Colors (only if stdout is a terminal)
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    RESET='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    CYAN=''
    BOLD=''
    RESET=''
fi

info() {
    echo -e "${GREEN}[yolobox]${RESET} $*"
}

warn() {
    echo -e "${YELLOW}[yolobox]${RESET} $*" >&2
}

die() {
    echo -e "${RED}[yolobox]${RESET} $*" >&2
    exit 1
}

# Detect project name from git remote or directory name.
# Must be called from inside a git repo.
detect_project_name() {
    local remote_url
    if remote_url=$(git remote get-url origin 2>/dev/null); then
        # Extract repo name from URL:
        #   git@github.com:user/repo.git  →  repo
        #   https://github.com/user/repo.git  →  repo
        #   https://github.com/user/repo  →  repo
        local name
        name=$(basename "$remote_url" .git)
        echo "$name"
    else
        # No remote — fall back to directory name of the repo root
        local root
        root=$(git_repo_root)
        basename "$root"
    fi
}

# Get the root of the main working tree (not a worktree's root).
# Works from inside any worktree of the same repo.
git_repo_root() {
    local common_dir
    common_dir=$(git rev-parse --git-common-dir 2>/dev/null) || die "Not inside a git repository"

    # --git-common-dir returns the path to the shared .git directory.
    # For the main worktree, this is just ".git" (relative) or "/path/to/repo/.git".
    # For linked worktrees, this is "/path/to/repo/.git/worktrees/<name>/../../" effectively.
    # We resolve to the parent of the .git dir to get the repo root.
    if [[ "$common_dir" == ".git" ]]; then
        pwd
    else
        # Resolve to absolute, then go up one level from .git
        local abs_common
        abs_common=$(cd "$common_dir" && pwd)
        dirname "$abs_common"
    fi
}

# Resolve the worktrees base directory for the current project
worktrees_base() {
    local project
    project=$(detect_project_name)
    echo "${WORKTREE_LOC}/${project}.worktrees"
}

# Resolve the homes base directory for the current project
homes_base() {
    local project
    project=$(detect_project_name)
    echo "${WORKTREE_LOC}/${project}.homes"
}
