#!/usr/bin/env bash
# sandbox_darwin.sh — macOS sandbox-exec (Seatbelt) implementation

# Generate a Seatbelt profile.
# Args: worktree_path synthetic_home real_home [extra_read_paths] [extra_write_paths] [traversal_dirs]
#   extra_read_paths, extra_write_paths, and traversal_dirs are newline-delimited strings of paths.
sandbox_generate_profile() {
    local worktree_path="$1"
    local synthetic_home="$2"
    local real_home="$3"
    local extra_reads="${4:-}"
    local extra_writes="${5:-}"
    local traversal_dirs="${6:-}"

    cat <<SEATBELT
(version 1)
(allow default)

;; --- WRITE RESTRICTIONS ---
;; Deny all file writes globally
(deny file-write*)

;; Allow writes to the worktree
(allow file-write*
  (subpath "${worktree_path}"))

;; Allow writes to the synthetic home
(allow file-write*
  (subpath "${synthetic_home}"))

;; Allow writes to system temp dirs
(allow file-write*
  (subpath "/private/tmp")
  (subpath "/private/var/folders")
  (subpath "/tmp"))

;; Allow writes to device files needed for terminal/IO
(allow file-write*
  (literal "/dev/null")
  (literal "/dev/tty")
  (literal "/dev/dfd")
  (regex #"^/dev/ttys[0-9]+$")
  (regex #"^/dev/pty[a-z][0-9a-f]$"))
SEATBELT

    # Extra write paths from config
    if [[ -n "$extra_writes" ]]; then
        echo ""
        echo ";; Extra write paths from config"
        while IFS= read -r p; do
            [[ -z "$p" ]] && continue
            echo "(allow file-write*"
            echo "  (subpath \"${p}\"))"
        done <<< "$extra_writes"
    fi

    cat <<SEATBELT

;; --- READ RESTRICTIONS ---
;; Deny reads to real home (prevents snooping on other repos, credentials, browser data)
(deny file-read*
  (subpath "${real_home}"))

;; Allow reads back for worktree and synthetic home
(allow file-read*
  (subpath "${worktree_path}")
  (subpath "${synthetic_home}"))
SEATBELT

    # Extra read paths from config
    if [[ -n "$extra_reads" ]]; then
        echo ""
        echo ";; Extra read paths from config"
        while IFS= read -r p; do
            [[ -z "$p" ]] && continue
            echo "(allow file-read*"
            echo "  (subpath \"${p}\"))"
        done <<< "$extra_reads"
    fi

    # Allow stat() on intermediate directories for path traversal to whitelisted
    # paths under real home (e.g. parent repo .git). Only metadata — no data reads.
    if [[ -n "$traversal_dirs" ]]; then
        echo ""
        echo ";; Allow path traversal (stat only) to reach whitelisted paths"
        echo "(allow file-read-metadata"
        while IFS= read -r p; do
            [[ -z "$p" ]] && continue
            echo "  (literal \"${p}\")"
        done <<< "$traversal_dirs"
        echo ")"
    fi
}

# Given a binary name and real home path, output top-level $HOME subdirectories
# that need read access (follows symlinks). One path per line, deduplicated.
# e.g., /Users/foo/.local/bin/claude → /Users/foo/.local
# e.g., /Users/foo/.nvm/versions/.../bin/claude → /Users/foo/.nvm
_tool_home_dirs() {
    local bin_name="$1"
    local real_home="$2"

    local bin_path
    bin_path=$(command -v "$bin_name" 2>/dev/null) || return 0
    local real_path
    real_path=$(realpath "$bin_path" 2>/dev/null || echo "$bin_path")

    for p in "$bin_path" "$real_path"; do
        if [[ "$p" == "${real_home}/"* ]]; then
            local rel="${p#${real_home}/}"
            echo "${real_home}/${rel%%/*}"
        fi
    done | sort -u
}

# Output intermediate directories between a whitelisted path and real_home
# (inclusive of real_home). Used to allow stat() traversal through Seatbelt's
# read-deny on $HOME. Outputs nothing if path is not under real_home.
_traversal_dirs() {
    local path="$1"
    local real_home="$2"
    [[ "$path" == "${real_home}/"* ]] || return 0
    local dir="${path%/*}"
    while [[ "$dir" == "${real_home}"* && "$dir" != "${real_home}" ]]; do
        echo "$dir"
        dir="${dir%/*}"
    done
    echo "$real_home"
}

sandbox_exec_darwin() {
    local worktree_path="$1"
    local synthetic_home="$2"
    local extra_reads="${3:-}"
    local extra_writes="${4:-}"
    local sandbox_cmd="${5:-claude --dangerously-skip-permissions}"
    local real_home="${HOME}"

    # Auto-detect claude binary location — if installed under $HOME (e.g. ~/.local,
    # ~/.nvm, ~/.volta), whitelist its top-level directory for Seatbelt reads.
    local tool_dirs
    tool_dirs=$(_tool_home_dirs "claude" "$real_home")
    if [[ -n "$tool_dirs" ]]; then
        while IFS= read -r d; do
            [[ -z "$d" ]] && continue
            info "Whitelisting ${d} for reads (claude binary location)"
            if [[ -n "$extra_reads" ]]; then
                extra_reads="${extra_reads}"$'\n'"${d}"
            else
                extra_reads="${d}"
            fi
        done <<< "$tool_dirs"
    fi

    # Git worktrees have a .git file pointing to the parent repo's
    # .git/worktrees/<name> directory. Whitelist the parent .git dir for
    # reads and writes (objects, refs, config, worktree state).
    local parent_gitdir=""
    local git_file="${worktree_path}/.git"
    if [[ -f "$git_file" ]]; then
        local gitdir
        gitdir=$(sed -n 's/^gitdir: //p' "$git_file")
        if [[ -n "$gitdir" ]]; then
            # Resolve worktree-specific dir (.git/worktrees/<name>),
            # then go up two levels to the .git root
            parent_gitdir=$(cd "$worktree_path" && cd "$gitdir" && cd ../.. && pwd)

            info "Whitelisting ${parent_gitdir} for reads+writes (parent .git)"
            if [[ -n "$extra_reads" ]]; then
                extra_reads="${extra_reads}"$'\n'"${parent_gitdir}"
            else
                extra_reads="${parent_gitdir}"
            fi
            if [[ -n "$extra_writes" ]]; then
                extra_writes="${extra_writes}"$'\n'"${parent_gitdir}"
            else
                extra_writes="${parent_gitdir}"
            fi
        fi
    fi

    # Collect traversal dirs for all whitelisted paths under real home.
    # Seatbelt blocks reads to $HOME, so git's getcwd() canonicalization
    # needs file-read-metadata on intermediate path components.
    local traversal_dirs
    traversal_dirs=$({
        _traversal_dirs "$worktree_path" "$real_home"
        _traversal_dirs "$synthetic_home" "$real_home"
        if [[ -n "$parent_gitdir" ]]; then
            _traversal_dirs "$parent_gitdir" "$real_home"
        fi
    } | sort -u)

    # Extract OAuth token from keychain before entering the sandbox.
    # The sandbox blocks reads to ~/Library/Keychains/, so Claude Code can't
    # access the keychain itself. Pass the token via environment variable instead.
    # Skip this when launching a plain shell (not needed for bash).
    local oauth_token=""
    if [[ "$sandbox_cmd" == claude* && -z "${ANTHROPIC_API_KEY:-}" ]]; then
        local cred_json
        cred_json=$(security find-generic-password -a "${USER}" -s "Claude Code-credentials" -w 2>/dev/null) || true
        if [[ -n "$cred_json" ]]; then
            oauth_token=$(echo "$cred_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('claudeAiOauth',{}).get('accessToken',''))" 2>/dev/null) || true
        fi
    fi

    # Generate profile to a temp file
    local profile_file
    profile_file=$(mktemp /tmp/yolobox-sb-XXXXXX)

    sandbox_generate_profile "$worktree_path" "$synthetic_home" "$real_home" "$extra_reads" "$extra_writes" "$traversal_dirs" > "$profile_file"

    info "Starting sandboxed session..."
    info "Worktree: ${worktree_path}"
    info "Home:     ${synthetic_home}"
    info "Profile:  ${profile_file}"
    if [[ -n "$extra_reads" ]]; then
        info "Extra reads: $(echo "$extra_reads" | tr '\n' ' ')"
    fi
    if [[ -n "$extra_writes" ]]; then
        info "Extra writes: $(echo "$extra_writes" | tr '\n' ' ')"
    fi
    local env_list="HOME, PATH, SHELL, TERM, LANG, USER, TMPDIR, GOCACHE, GOMODCACHE"
    if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
        env_list="${env_list}, ANTHROPIC_API_KEY"
    elif [[ -n "$oauth_token" ]]; then
        env_list="${env_list}, CLAUDE_CODE_OAUTH_TOKEN"
    fi
    info "Environment scrubbed (env -i). Passing: ${env_list}"
    echo ""

    # Run sandbox-exec with scrubbed environment — only essential vars pass through.
    # This kills GITHUB_TOKEN, GH_TOKEN, AWS_SECRET_ACCESS_KEY, NPM_TOKEN, etc.
    # Start from worktree dir to avoid getcwd errors (Seatbelt blocks reads to real $HOME CWD).
    local exit_code=0
    (cd "$worktree_path" && \
        sandbox-exec -f "$profile_file" \
        env -i \
        HOME="$synthetic_home" \
        PATH="${synthetic_home}/.local/bin:$PATH" \
        SHELL="${SHELL:-/bin/bash}" \
        TERM="${TERM:-xterm-256color}" \
        LANG="${LANG:-en_US.UTF-8}" \
        USER="${USER:-$(whoami)}" \
        TMPDIR="${TMPDIR:-/tmp}" \
        GOCACHE="${real_home}/Library/Caches/go-build" \
        GOMODCACHE="${real_home}/go/pkg/mod" \
        ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}" \
        CLAUDE_CODE_OAUTH_TOKEN="${oauth_token}" \
        GIT_CONFIG_COUNT=1 \
        GIT_CONFIG_KEY_0="remote.origin.pushurl" \
        GIT_CONFIG_VALUE_0="PUSH_DISABLED_BY_YOLOBOX" \
        bash -c "$sandbox_cmd") \
        || exit_code=$?

    # Clean up
    rm -f "$profile_file"

    if [[ $exit_code -ne 0 ]]; then
        warn "Sandbox exited with code ${exit_code}"
    fi
    return $exit_code
}

sandbox_is_active_darwin() {
    local worktree_path="$1"
    # Check if any sandbox-exec process has this worktree path in its args
    pgrep -f "sandbox-exec.*${worktree_path}" >/dev/null 2>&1
}
