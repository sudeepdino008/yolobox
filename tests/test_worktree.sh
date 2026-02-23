#!/usr/bin/env bash
# test_worktree.sh — tests for worktree + synthetic home management
# Tests are numbered to control execution order (sorted alphabetically).

_TEST_WT_DIR=""
_ORIG_WORKTREE_LOC=""

setup_all() {
    _TEST_WT_DIR=$(mktemp -d)

    # Save originals
    _ORIG_WORKTREE_LOC="${WORKTREE_LOC:-}"

    # Set up test config
    export WORKTREE_LOC="$_TEST_WT_DIR"
}

teardown_all() {
    # Clean up worktrees properly
    local repo_root
    repo_root=$(git_repo_root 2>/dev/null) || true
    if [[ -n "$repo_root" ]]; then
        for wt in "$_TEST_WT_DIR"/*.worktrees/*/; do
            [[ -d "$wt" ]] || continue
            git -C "$repo_root" worktree remove "$wt" --force 2>/dev/null || true
        done
        # Clean up test branches
        for branch in test-yolobox-wt-1 test-yolobox-wt-2 test-yolobox-wt-3 test-yolobox-dup test-yolobox-del; do
            git -C "$repo_root" branch -D "$branch" 2>/dev/null || true
        done
    fi

    [[ -n "$_TEST_WT_DIR" ]] && rm -rf "$_TEST_WT_DIR"

    # Restore originals
    export WORKTREE_LOC="${_ORIG_WORKTREE_LOC}"
}

setup_all

test_01_project_name_from_remote() {
    local name
    name=$(detect_project_name)
    # This repo has a remote — should get repo name, not empty
    [[ -n "$name" ]] || { echo "  FAIL: project name is empty"; return 1; }
}

test_02_create_worktree() {
    worktree_create "test-yolobox-wt-1" >/dev/null 2>&1

    local project
    project=$(detect_project_name)
    local wt_path="${_TEST_WT_DIR}/${project}.worktrees/test-yolobox-wt-1"
    local hm_path="${_TEST_WT_DIR}/${project}.homes/test-yolobox-wt-1"

    assert_dir_exists "$wt_path"
    assert_dir_exists "$hm_path"
    assert_dir_exists "${hm_path}/.claude"

    # Verify it's a valid git worktree
    assert_ok git -C "$wt_path" rev-parse --is-inside-work-tree
}

test_03_synthetic_home_contents() {
    local project
    project=$(detect_project_name)
    local hm_path="${_TEST_WT_DIR}/${project}.homes/test-yolobox-wt-1"

    # .gitconfig should be copied (not symlinked — symlink target blocked by Seatbelt)
    if [[ -f "${HOME}/.gitconfig" ]]; then
        assert_file_exists "${hm_path}/.gitconfig"
    fi
}

test_03b_push_url_not_modified() {
    # Push URL should NOT be modified at the worktree level — push is only
    # disabled inside the sandbox via GIT_CONFIG_* environment variables.
    local project
    project=$(detect_project_name)
    local wt_path="${_TEST_WT_DIR}/${project}.worktrees/test-yolobox-wt-1"

    local push_url
    push_url=$(git -C "$wt_path" remote get-url --push origin)
    if [[ "$push_url" == "PUSH_DISABLED_BY_YOLOBOX" ]]; then
        echo "  FAIL: Push URL should not be overridden in worktree"
        return 1
    fi
}

test_03c_ssh_url_rewrite_in_synthetic_gitconfig() {
    # Synthetic gitconfig should rewrite SSH GitHub URLs to HTTPS
    local project
    project=$(detect_project_name)
    local hm_path="${_TEST_WT_DIR}/${project}.homes/test-yolobox-wt-1"

    local insteadof
    insteadof=$(git config --file "${hm_path}/.gitconfig" "url.https://github.com/.insteadOf" 2>/dev/null || true)
    assert_eq "git@github.com:" "$insteadof" "insteadOf should rewrite SSH to HTTPS"

    local push_insteadof
    push_insteadof=$(git config --file "${hm_path}/.gitconfig" "url.https://github.com/.pushInsteadOf" 2>/dev/null || true)
    assert_eq "git@github.com:" "$push_insteadof" "pushInsteadOf should rewrite SSH to HTTPS"
}

test_04_create_duplicate() {
    # Should fail — worktree already exists from test_02
    local output
    output=$(worktree_create "test-yolobox-wt-1" 2>&1) && return 1 || true
    assert_contains "$output" "already exists" "Should say worktree already exists"
}

test_05_list_worktrees() {
    worktree_create "test-yolobox-wt-2" >/dev/null 2>&1

    local output
    output=$(worktree_list 2>&1)

    assert_contains "$output" "test-yolobox-wt-1" "Should list first branch"
    assert_contains "$output" "test-yolobox-wt-2" "Should list second branch"
}

test_06_delete_worktree() {
    worktree_create "test-yolobox-del" >/dev/null 2>&1

    local project
    project=$(detect_project_name)
    local wt_path="${_TEST_WT_DIR}/${project}.worktrees/test-yolobox-del"
    local hm_path="${_TEST_WT_DIR}/${project}.homes/test-yolobox-del"

    assert_dir_exists "$wt_path"

    worktree_delete "test-yolobox-del" >/dev/null 2>&1

    # Worktree should be gone
    assert_file_not_exists "$wt_path"

    # Synthetic home should still exist (session state preserved)
    assert_dir_exists "$hm_path"
}

test_07_delete_nonexistent() {
    local output
    output=$(worktree_delete "nonexistent-branch-xyz" 2>&1) && return 1 || true
    assert_contains "$output" "No worktree found" "Should say worktree not found"
}
