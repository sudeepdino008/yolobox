#!/usr/bin/env bash
# sandbox_darwin.sh — macOS sandbox-exec (Seatbelt) implementation

sandbox_generate_profile() {
    local worktree_path="$1"
    local synthetic_home="$2"
    local real_home="$3"

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

;; --- READ RESTRICTIONS ---
;; Deny reads to real home (prevents snooping on other repos, credentials, browser data)
(deny file-read*
  (subpath "${real_home}"))

;; Allow reads back for worktree and synthetic home
(allow file-read*
  (subpath "${worktree_path}")
  (subpath "${synthetic_home}"))
SEATBELT
}

sandbox_exec_darwin() {
    local worktree_path="$1"
    local synthetic_home="$2"
    local real_home="${HOME}"

    # Generate profile to a temp file
    local profile_file
    profile_file=$(mktemp /tmp/yolobox-XXXXXX.sb)

    sandbox_generate_profile "$worktree_path" "$synthetic_home" "$real_home" > "$profile_file"

    info "Starting sandboxed session..."
    info "Worktree: ${worktree_path}"
    info "Home:     ${synthetic_home}"
    info "Profile:  ${profile_file}"
    echo ""

    # Run sandbox-exec with overridden HOME
    local exit_code=0
    sandbox-exec -f "$profile_file" \
        env HOME="$synthetic_home" \
        bash -c "cd \"${worktree_path}\" && claude --dangerously-skip-permissions" \
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
