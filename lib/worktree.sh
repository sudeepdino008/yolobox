#!/usr/bin/env bash
# worktree.sh — git worktree + synthetic home management

worktree_path() {
    local branch="$1"
    echo "$(worktrees_base)/${branch}"
}

home_path() {
    local branch="$1"
    echo "$(homes_base)/${branch}"
}

worktree_create() {
    local branch="$1"
    local wt_path
    wt_path=$(worktree_path "$branch")
    local hm_path
    hm_path=$(home_path "$branch")

    # Check if worktree already exists
    if [[ -d "$wt_path" ]]; then
        die "Worktree already exists at $wt_path"
    fi

    # Ensure base directories exist
    mkdir -p "$(worktrees_base)" "$(homes_base)"

    # Create the git worktree
    local repo_root
    repo_root=$(git_repo_root)

    if git -C "$repo_root" show-ref --verify --quiet "refs/heads/${branch}" 2>/dev/null; then
        # Branch already exists — don't use -b
        git -C "$repo_root" worktree add "$wt_path" "$branch"
    else
        # New branch — create it
        git -C "$repo_root" worktree add "$wt_path" -b "$branch"
    fi

    # Set up synthetic home
    _setup_synthetic_home "$branch" "$hm_path"

    info "Created worktree '${branch}' at ${wt_path}"
    info "Synthetic home at ${hm_path}"
}

_setup_synthetic_home() {
    local branch="$1"
    local hm_path="$2"
    local real_home="${HOME}"

    mkdir -p "${hm_path}/.claude" "${hm_path}/.ssh"

    # Symlink .gitconfig
    if [[ -f "${real_home}/.gitconfig" ]]; then
        ln -sf "${real_home}/.gitconfig" "${hm_path}/.gitconfig"
    fi

    # Symlink SSH key files
    local key_name
    key_name=$(basename "$SSH_KEY_PATH")
    ln -sf "$SSH_KEY_PATH" "${hm_path}/.ssh/${key_name}"
    if [[ -f "${SSH_KEY_PATH}.pub" ]]; then
        ln -sf "${SSH_KEY_PATH}.pub" "${hm_path}/.ssh/${key_name}.pub"
    fi
    if [[ -f "${real_home}/.ssh/known_hosts" ]]; then
        ln -sf "${real_home}/.ssh/known_hosts" "${hm_path}/.ssh/known_hosts"
    fi
    if [[ -f "${real_home}/.ssh/config" ]]; then
        ln -sf "${real_home}/.ssh/config" "${hm_path}/.ssh/config"
    fi

    # Copy claude config files (these may be modified by claude in the sandbox)
    if [[ -f "${real_home}/.claude/settings.json" ]]; then
        cp "${real_home}/.claude/settings.json" "${hm_path}/.claude/settings.json"
    fi
    if [[ -f "${real_home}/.claude/CLAUDE.md" ]]; then
        cp "${real_home}/.claude/CLAUDE.md" "${hm_path}/.claude/CLAUDE.md"
    fi
}

worktree_delete() {
    local branch="$1"
    local wt_path
    wt_path=$(worktree_path "$branch")
    local hm_path
    hm_path=$(home_path "$branch")

    if [[ ! -d "$wt_path" ]]; then
        die "No worktree found for branch '${branch}'"
    fi

    # Check if sandbox is active
    if sandbox_is_active "$wt_path" 2>/dev/null; then
        die "Sandbox is active for '${branch}'. Exit it first."
    fi

    # Remove the git worktree
    local repo_root
    repo_root=$(git_repo_root)
    git -C "$repo_root" worktree remove "$wt_path" --force

    # Delete the branch
    git -C "$repo_root" branch -D "$branch" 2>/dev/null || warn "Branch '${branch}' could not be deleted (may have been merged or not exist)"

    info "Deleted worktree '${branch}'."
    if [[ -d "$hm_path" ]]; then
        info "Session state preserved at ${hm_path}"
    fi
}

worktree_list() {
    local wt_base
    wt_base=$(worktrees_base)

    if [[ ! -d "$wt_base" ]]; then
        echo "No worktrees found."
        return 0
    fi

    local branches=()
    for dir in "$wt_base"/*/; do
        [[ -d "$dir" ]] || continue
        branches+=("$(basename "$dir")")
    done

    if [[ ${#branches[@]} -eq 0 ]]; then
        echo "No worktrees found."
        return 0
    fi

    printf "${BOLD}%-30s %-10s %s${RESET}\n" "BRANCH" "STATUS" "PATH"
    for branch in "${branches[@]}"; do
        local wt_path="${wt_base}/${branch}"
        local status="inactive"
        if sandbox_is_active "$wt_path" 2>/dev/null; then
            status="active"
        fi
        local status_colored
        if [[ "$status" == "active" ]]; then
            status_colored="${GREEN}active${RESET}"
        else
            status_colored="inactive"
        fi
        printf "%-30s %-10b %s\n" "$branch" "$status_colored" "$wt_path"
    done
}
