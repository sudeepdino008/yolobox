#!/usr/bin/env bash
# sandbox_linux.sh — Linux bubblewrap (bwrap) implementation (stub)

sandbox_exec_linux() {
    die "Linux sandbox support is not yet implemented. Coming soon (bubblewrap with setgid)."
}

sandbox_is_active_linux() {
    local worktree_path="$1"
    pgrep -f "bwrap.*${worktree_path}" >/dev/null 2>&1
}
