#!/usr/bin/env bash
# test_integration.sh — end-to-end integration tests using real yolobox commands

_TEST_INT_DIR=""
_ORIG_WORKTREE_LOC=""
_ORIG_SSH_KEY_PATH=""

setup_all() {
    _TEST_INT_DIR=$(mktemp -d)
    local test_key="${_TEST_INT_DIR}/test_key"
    touch "$test_key"

    _ORIG_WORKTREE_LOC="${WORKTREE_LOC:-}"
    _ORIG_SSH_KEY_PATH="${SSH_KEY_PATH:-}"

    export WORKTREE_LOC="$_TEST_INT_DIR"
    export SSH_KEY_PATH="$test_key"
}

teardown_all() {
    local repo_root
    repo_root=$(git_repo_root 2>/dev/null) || true
    if [[ -n "$repo_root" ]]; then
        for wt in "$_TEST_INT_DIR"/*.worktrees/*/; do
            [[ -d "$wt" ]] || continue
            git -C "$repo_root" worktree remove "$wt" --force 2>/dev/null || true
        done
        for branch in test-int-e2e test-int-persist test-int-multi-1 test-int-multi-2 test-int-multi-3; do
            git -C "$repo_root" branch -D "$branch" 2>/dev/null || true
        done
    fi

    [[ -n "$_TEST_INT_DIR" ]] && rm -rf "$_TEST_INT_DIR"

    export WORKTREE_LOC="${_ORIG_WORKTREE_LOC}"
    export SSH_KEY_PATH="${_ORIG_SSH_KEY_PATH}"
}

setup_all

test_create_list_delete_flow() {
    # Create
    local create_output
    create_output=$(worktree_create "test-int-e2e" 2>&1)
    assert_contains "$create_output" "Created worktree" "Create should print success"

    # List
    local list_output
    list_output=$(worktree_list 2>&1)
    assert_contains "$list_output" "test-int-e2e" "List should show the branch"

    # Delete
    local delete_output
    delete_output=$(worktree_delete "test-int-e2e" 2>&1)
    assert_contains "$delete_output" "Deleted worktree" "Delete should print success"

    # List again — should not show deleted branch's worktree dir
    local project
    project=$(detect_project_name)
    local wt_path="${_TEST_INT_DIR}/${project}.worktrees/test-int-e2e"
    assert_file_not_exists "$wt_path"
}

test_session_state_persists() {
    local project
    project=$(detect_project_name)

    # Create
    worktree_create "test-int-persist" >/dev/null 2>&1

    local hm_path="${_TEST_INT_DIR}/${project}.homes/test-int-persist"

    # Simulate claude writing session state
    echo '{"session":"data"}' > "${hm_path}/.claude/session.json"

    # Delete worktree
    worktree_delete "test-int-persist" >/dev/null 2>&1

    # Session state should still exist
    assert_dir_exists "${hm_path}/.claude"
    assert_file_exists "${hm_path}/.claude/session.json"

    local content
    content=$(cat "${hm_path}/.claude/session.json")
    assert_eq '{"session":"data"}' "$content" "Session state should be preserved"
}

test_multiple_worktrees() {
    local project
    project=$(detect_project_name)

    worktree_create "test-int-multi-1" >/dev/null 2>&1
    worktree_create "test-int-multi-2" >/dev/null 2>&1
    worktree_create "test-int-multi-3" >/dev/null 2>&1

    local list_output
    list_output=$(worktree_list 2>&1)

    assert_contains "$list_output" "test-int-multi-1" "Should list first"
    assert_contains "$list_output" "test-int-multi-2" "Should list second"
    assert_contains "$list_output" "test-int-multi-3" "Should list third"
}
