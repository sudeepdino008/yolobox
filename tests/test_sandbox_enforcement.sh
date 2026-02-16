#!/usr/bin/env bash
# test_sandbox_enforcement.sh — actually runs sandbox-exec and verifies restrictions
#
# These tests are macOS-only. They create a real sandbox, run commands inside it,
# and verify that write/read restrictions are enforced.

_TEST_SANDBOX_DIR=""
_TEST_OUTSIDE_DIR=""

setup_all() {
    _TEST_SANDBOX_DIR=$(mktemp -d)
    mkdir -p "${_TEST_SANDBOX_DIR}/worktree"
    mkdir -p "${_TEST_SANDBOX_DIR}/home"
    # "outside" dir must be under $HOME (not /tmp) so sandbox write-deny applies
    _TEST_OUTSIDE_DIR="${HOME}/.yolobox-test-outside-$$"
    mkdir -p "$_TEST_OUTSIDE_DIR"
    echo "hello" > "${_TEST_SANDBOX_DIR}/worktree/testfile.txt"
}

teardown_all() {
    [[ -n "$_TEST_SANDBOX_DIR" ]] && rm -rf "$_TEST_SANDBOX_DIR"
    [[ -n "$_TEST_OUTSIDE_DIR" ]] && rm -rf "$_TEST_OUTSIDE_DIR"
}

setup_all

_require_darwin() {
    if [[ "$(uname -s)" != "Darwin" ]]; then
        skip_test "macOS only"
        return 2
    fi
    return 0
}

# Helper: run a command inside sandbox-exec with our generated profile
_sandbox_run() {
    local profile_file
    profile_file=$(mktemp /tmp/yolobox-test-sb-XXXXXX)

    sandbox_generate_profile \
        "${_TEST_SANDBOX_DIR}/worktree" \
        "${_TEST_SANDBOX_DIR}/home" \
        "${HOME}" \
        > "$profile_file"

    local exit_code=0
    (cd "${_TEST_SANDBOX_DIR}/worktree" && \
        sandbox-exec -f "$profile_file" \
        env -i \
        HOME="${_TEST_SANDBOX_DIR}/home" \
        PATH="$PATH" \
        SHELL="${SHELL:-/bin/bash}" \
        TERM="${TERM:-xterm-256color}" \
        LANG="${LANG:-en_US.UTF-8}" \
        USER="${USER:-$(whoami)}" \
        TMPDIR="${TMPDIR:-/tmp}" \
        ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}" \
        bash -c "$*" 2>&1) || exit_code=$?

    rm -f "$profile_file"
    return $exit_code
}

test_write_to_worktree_allowed() {
    _require_darwin || return 2

    _sandbox_run "touch '${_TEST_SANDBOX_DIR}/worktree/newfile'"
    assert_file_exists "${_TEST_SANDBOX_DIR}/worktree/newfile"
}

test_write_to_home_allowed() {
    _require_darwin || return 2

    _sandbox_run "touch '${_TEST_SANDBOX_DIR}/home/newfile'"
    assert_file_exists "${_TEST_SANDBOX_DIR}/home/newfile"
}

test_write_outside_denied() {
    _require_darwin || return 2

    local output
    output=$(_sandbox_run "touch '${_TEST_OUTSIDE_DIR}/bad'" 2>&1) && {
        echo "  FAIL: write outside sandbox should have been denied"
        return 1
    } || true

    # File should NOT exist
    assert_file_not_exists "${_TEST_OUTSIDE_DIR}/bad"
}

test_write_to_real_home_denied() {
    _require_darwin || return 2

    local canary="${HOME}/.yolobox-test-canary-$(date +%s)"

    _sandbox_run "touch '${canary}'" 2>/dev/null && {
        # If somehow it succeeded, clean up and fail
        rm -f "$canary"
        echo "  FAIL: write to real home should have been denied"
        return 1
    } || true

    assert_file_not_exists "$canary"
}

test_read_worktree_allowed() {
    _require_darwin || return 2

    local output
    output=$(_sandbox_run "cat '${_TEST_SANDBOX_DIR}/worktree/testfile.txt'")
    assert_eq "hello" "$output" "Should be able to read worktree files"
}

test_read_real_home_denied() {
    _require_darwin || return 2

    # Try to read a file that almost certainly exists in real home
    local target=""
    for candidate in "${HOME}/.bashrc" "${HOME}/.zshrc" "${HOME}/.profile" "${HOME}/.bash_profile"; do
        if [[ -f "$candidate" ]]; then
            target="$candidate"
            break
        fi
    done

    if [[ -z "$target" ]]; then
        skip_test "No shell rc file found in real home to test read denial"
        return 2
    fi

    _sandbox_run "cat '${target}'" 2>/dev/null && {
        echo "  FAIL: read from real home should have been denied"
        return 1
    } || true
}

test_read_system_allowed() {
    _require_darwin || return 2

    local output
    output=$(_sandbox_run "cat /etc/hosts" 2>&1)
    assert_contains "$output" "localhost" "Should be able to read /etc/hosts"
}

test_git_operations_work() {
    _require_darwin || return 2

    # Initialize a git repo in the test worktree
    git -C "${_TEST_SANDBOX_DIR}/worktree" init -q 2>/dev/null

    local output
    output=$(_sandbox_run "cd '${_TEST_SANDBOX_DIR}/worktree' && git status" 2>&1)
    assert_contains "$output" "branch" "git status should work inside sandbox"
}

test_rm_outside_denied() {
    _require_darwin || return 2

    # Create a file outside the sandbox (under $HOME, which is write-denied)
    echo "protected" > "${_TEST_OUTSIDE_DIR}/protected.txt"

    _sandbox_run "rm '${_TEST_OUTSIDE_DIR}/protected.txt'" 2>/dev/null && {
        echo "  FAIL: rm outside sandbox should have been denied"
        return 1
    } || true

    assert_file_exists "${_TEST_OUTSIDE_DIR}/protected.txt"
}

test_network_allowed() {
    _require_darwin || return 2

    # Quick connectivity check — skip gracefully if no network
    if ! curl -s --max-time 3 https://example.com >/dev/null 2>&1; then
        skip_test "No network available"
        return 2
    fi

    local output
    output=$(_sandbox_run "curl -s --max-time 5 https://example.com" 2>&1) || {
        echo "  FAIL: network should be allowed inside sandbox"
        return 1
    }
    assert_contains "$output" "Example Domain" "Should fetch example.com"
}

test_no_getcwd_errors_in_output() {
    _require_darwin || return 2

    # Verifies that sandbox output is clean — no getcwd noise from bash starting
    # in a CWD that Seatbelt blocks. This catches regressions in the cd-to-worktree fix.
    local output
    output=$(_sandbox_run "echo ok")
    assert_eq "ok" "$output" "Sandbox output should be clean (no getcwd errors)"
}

test_exec_binary_under_home_blocked() {
    _require_darwin || return 2

    # A binary under real $HOME should not be executable — Seatbelt blocks reads there.
    # This is the security property that prevents Claude from using tools like gh/aws
    # that happen to live under $HOME, and also blocks claude itself without whitelisting.
    local tool_dir="${HOME}/.yolobox-test-tools-$$"
    mkdir -p "$tool_dir"
    printf '#!/bin/bash\necho tool-ok\n' > "${tool_dir}/yolobox-test-tool"
    chmod +x "${tool_dir}/yolobox-test-tool"

    _sandbox_run "${tool_dir}/yolobox-test-tool" 2>/dev/null && {
        rm -rf "$tool_dir"
        echo "  FAIL: binary under real \$HOME should not be executable without whitelist"
        return 1
    } || true

    rm -rf "$tool_dir"
}

test_exec_binary_under_home_allowed_with_whitelist() {
    _require_darwin || return 2

    # When a $HOME subdirectory is whitelisted via extra_reads, binaries there
    # should be executable. This is how _tool_home_dirs enables claude to run.
    local tool_dir="${HOME}/.yolobox-test-tools-$$"
    mkdir -p "$tool_dir"
    printf '#!/bin/bash\necho tool-ok\n' > "${tool_dir}/yolobox-test-tool"
    chmod +x "${tool_dir}/yolobox-test-tool"

    # Generate profile with tool_dir whitelisted for reads
    local profile_file
    profile_file=$(mktemp /tmp/yolobox-test-sb-XXXXXX)
    sandbox_generate_profile \
        "${_TEST_SANDBOX_DIR}/worktree" \
        "${_TEST_SANDBOX_DIR}/home" \
        "${HOME}" \
        "${tool_dir}" \
        > "$profile_file"

    local output exit_code=0
    output=$(cd "${_TEST_SANDBOX_DIR}/worktree" && \
        sandbox-exec -f "$profile_file" \
        env -i \
        HOME="${_TEST_SANDBOX_DIR}/home" \
        PATH="${tool_dir}:${PATH}" \
        SHELL="${SHELL:-/bin/bash}" \
        TERM="${TERM:-xterm-256color}" \
        LANG="${LANG:-en_US.UTF-8}" \
        USER="${USER:-$(whoami)}" \
        TMPDIR="${TMPDIR:-/tmp}" \
        bash -c "${tool_dir}/yolobox-test-tool" 2>&1) || exit_code=$?

    rm -f "$profile_file"
    rm -rf "$tool_dir"

    [[ $exit_code -eq 0 ]] || { echo "  FAIL: whitelisted tool should succeed (exit $exit_code)"; return 1; }
    assert_eq "tool-ok" "$output" "Whitelisted binary under \$HOME should be executable"
}

test_env_scrubbed_no_github_token() {
    _require_darwin || return 2

    # Set a token that should NOT survive env scrubbing
    export GITHUB_TOKEN="super-secret-token"

    local output
    output=$(_sandbox_run "echo \"\${GITHUB_TOKEN:-}\"")

    # Token must be empty inside the sandbox
    assert_eq "" "$output" "GITHUB_TOKEN should not be visible inside sandbox"

    unset GITHUB_TOKEN
}

test_env_scrubbed_allowed_vars_present() {
    _require_darwin || return 2

    local output

    # HOME should be the synthetic home
    output=$(_sandbox_run "echo \$HOME")
    assert_eq "${_TEST_SANDBOX_DIR}/home" "$output" "HOME should be set to synthetic home"

    # PATH should be non-empty
    output=$(_sandbox_run "echo \$PATH")
    [[ -n "$output" ]] || { echo "  FAIL: PATH should be non-empty"; return 1; }

    # USER should be non-empty
    output=$(_sandbox_run "echo \$USER")
    [[ -n "$output" ]] || { echo "  FAIL: USER should be non-empty"; return 1; }
}
