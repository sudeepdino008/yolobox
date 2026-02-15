#!/usr/bin/env bash
# test_sandbox_enforcement.sh — actually runs sandbox-exec and verifies restrictions
#
# These tests are macOS-only. They create a real sandbox, run commands inside it,
# and verify that write/read restrictions are enforced.

_TEST_SANDBOX_DIR=""

setup_all() {
    _TEST_SANDBOX_DIR=$(mktemp -d)
    mkdir -p "${_TEST_SANDBOX_DIR}/worktree"
    mkdir -p "${_TEST_SANDBOX_DIR}/home"
    mkdir -p "${_TEST_SANDBOX_DIR}/outside"
    echo "hello" > "${_TEST_SANDBOX_DIR}/worktree/testfile.txt"
}

teardown_all() {
    [[ -n "$_TEST_SANDBOX_DIR" ]] && rm -rf "$_TEST_SANDBOX_DIR"
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
    profile_file=$(mktemp /tmp/yolobox-test-XXXXXX.sb)

    sandbox_generate_profile \
        "${_TEST_SANDBOX_DIR}/worktree" \
        "${_TEST_SANDBOX_DIR}/home" \
        "${HOME}" \
        > "$profile_file"

    local exit_code=0
    sandbox-exec -f "$profile_file" \
        env HOME="${_TEST_SANDBOX_DIR}/home" \
        bash -c "$*" 2>&1 || exit_code=$?

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
    output=$(_sandbox_run "touch '${_TEST_SANDBOX_DIR}/outside/bad'" 2>&1) && {
        echo "  FAIL: write outside sandbox should have been denied"
        return 1
    } || true

    # File should NOT exist
    assert_file_not_exists "${_TEST_SANDBOX_DIR}/outside/bad"
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

    # Create a file outside the sandbox
    echo "protected" > "${_TEST_SANDBOX_DIR}/outside/protected.txt"

    _sandbox_run "rm '${_TEST_SANDBOX_DIR}/outside/protected.txt'" 2>/dev/null && {
        echo "  FAIL: rm outside sandbox should have been denied"
        return 1
    } || true

    assert_file_exists "${_TEST_SANDBOX_DIR}/outside/protected.txt"
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
