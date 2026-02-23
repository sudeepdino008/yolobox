#!/usr/bin/env bash
# worktree.sh — git worktree + synthetic home management

worktree_path() {
    local branch="$1"
    echo "$(worktrees_base)/${branch}"
}

# List all worktree branch names under the worktrees base.
# Handles branch names with slashes (e.g., user/feature-x) by looking
# for .git files (linked worktree markers) at any depth.
# Outputs one branch name per line.
_list_worktree_branches() {
    local wt_base
    wt_base=$(worktrees_base)
    [[ -d "$wt_base" ]] || return 0

    while IFS= read -r git_file; do
        local wt_dir="${git_file%/.git}"
        echo "${wt_dir#${wt_base}/}"
    done < <(find "$wt_base" -name ".git" -type f 2>/dev/null)
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

    mkdir -p "${hm_path}/.claude"

    # Copy .gitconfig (needed for user.name/email in commits).
    # Must copy, not symlink — symlink target is in real $HOME which Seatbelt blocks.
    if [[ -f "${real_home}/.gitconfig" ]]; then
        cp "${real_home}/.gitconfig" "${hm_path}/.gitconfig"
    fi

    # Configure gh as git credential helper so HTTPS push/pull works inside sandbox.
    # Equivalent to: gh auth setup-git --hostname github.com
    # The empty helper entry clears any inherited helper before setting gh.
    local gh_bin
    gh_bin=$(command -v gh 2>/dev/null) || true
    if [[ -n "$gh_bin" ]]; then
        git config --file "${hm_path}/.gitconfig" "credential.https://github.com.helper" ""
        git config --file "${hm_path}/.gitconfig" --add "credential.https://github.com.helper" "!${gh_bin} auth git-credential"
    fi

    # Copy gh CLI config (auth tokens for gh commands inside sandbox).
    # Seatbelt blocks reads to real $HOME, so gh can't find its config there.
    # Copy to synthetic home so $HOME/.config/gh/ resolves correctly inside sandbox.
    if [[ -d "${real_home}/.config/gh" ]]; then
        mkdir -p "${hm_path}/.config"
        cp -R "${real_home}/.config/gh" "${hm_path}/.config/gh"
    fi

    # Symlink .local (Claude Code native install lives at ~/.local/bin/claude
    # and checks $HOME/.local when installMethod is "native")
    if [[ -d "${real_home}/.local" ]]; then
        ln -sf "${real_home}/.local" "${hm_path}/.local"
    fi

    # Copy ~/.claude.json — stores onboarding state, theme, auth method, etc.
    # Without this, Claude Code shows the onboarding wizard in every sandbox.
    if [[ -f "${real_home}/.claude.json" ]]; then
        cp "${real_home}/.claude.json" "${hm_path}/.claude.json"
    fi

    # Copy all top-level claude config/state files (settings, theme, setup markers,
    # etc.). Subdirectories are skipped — they contain session data and caches that
    # should start fresh per worktree.
    for f in "${real_home}/.claude/"*; do
        [[ -f "$f" ]] || continue
        cp "$f" "${hm_path}/.claude/"
    done

    # Copy small state subdirectories Claude Code checks during startup
    # (onboarding state, feature flags, caches). Skip large dirs that are
    # session-specific or should start fresh per worktree.
    # Best-effort: some subdirs (e.g. commands/) may contain git repos with
    # restricted pack file permissions — tolerate copy failures.
    for d in cache commands downloads ide plugins statsig telemetry; do
        [[ -d "${real_home}/.claude/${d}" ]] || continue
        cp -R "${real_home}/.claude/${d}" "${hm_path}/.claude/" 2>/dev/null || true
    done

    # Auto-accept the bypass permissions prompt so the sandbox session starts
    # without manual intervention. This is safe because yolobox IS the sandbox.
    local settings="${hm_path}/.claude/settings.json"
    if [[ -f "$settings" ]]; then
        python3 -c "
import json, sys
with open(sys.argv[1]) as f: d = json.load(f)
d['skipDangerousModePermissionPrompt'] = True
with open(sys.argv[1], 'w') as f: json.dump(d, f, indent=2)
" "$settings"
    else
        echo '{"skipDangerousModePermissionPrompt":true}' > "$settings"
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
    while IFS= read -r branch; do
        [[ -z "$branch" ]] && continue
        branches+=("$branch")
    done < <(_list_worktree_branches)

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
