#!/usr/bin/env bash
# test_config.sh — tests for config management

_TEST_CONFIG_DIR=""

setup_all() {
    _TEST_CONFIG_DIR=$(mktemp -d)
}

teardown_all() {
    [[ -n "$_TEST_CONFIG_DIR" ]] && rm -rf "$_TEST_CONFIG_DIR"
}

setup_all

test_config_save_and_load() {
    local cfg_dir="${_TEST_CONFIG_DIR}/save_load"
    YOLOBOX_CONFIG_DIR="$cfg_dir"
    YOLOBOX_CONFIG_FILE="${cfg_dir}/config"

    config_save "/tmp/my-worktrees" "/home/user/.ssh/id_ed25519"

    assert_file_exists "$YOLOBOX_CONFIG_FILE"

    # Reset vars then load
    unset WORKTREE_LOC SSH_KEY_PATH
    config_load

    assert_eq "/tmp/my-worktrees" "$WORKTREE_LOC" "WORKTREE_LOC should match"
    assert_eq "/home/user/.ssh/id_ed25519" "$SSH_KEY_PATH" "SSH_KEY_PATH should match"
}

test_config_load_missing() {
    local cfg_dir="${_TEST_CONFIG_DIR}/missing"
    YOLOBOX_CONFIG_DIR="$cfg_dir"
    YOLOBOX_CONFIG_FILE="${cfg_dir}/config"

    # Should fail because file doesn't exist
    local output
    output=$(config_load 2>&1) && return 1 || true
    assert_contains "$output" "No config found" "Should mention missing config"
}

test_config_load_incomplete() {
    local cfg_dir="${_TEST_CONFIG_DIR}/incomplete"
    mkdir -p "$cfg_dir"
    YOLOBOX_CONFIG_DIR="$cfg_dir"
    YOLOBOX_CONFIG_FILE="${cfg_dir}/config"

    # Write config with only WORKTREE_LOC
    echo "WORKTREE_LOC=/tmp/wt" > "$YOLOBOX_CONFIG_FILE"

    unset SSH_KEY_PATH 2>/dev/null || true
    local output
    output=$(config_load 2>&1) && return 1 || true
    assert_contains "$output" "SSH_KEY_PATH" "Should mention missing SSH_KEY_PATH"
}

test_config_dir_creation() {
    local cfg_dir="${_TEST_CONFIG_DIR}/newdir/subdir"
    YOLOBOX_CONFIG_DIR="$cfg_dir"
    YOLOBOX_CONFIG_FILE="${cfg_dir}/config"

    assert_file_not_exists "$cfg_dir"

    config_save "/tmp/wt" "/tmp/key"

    assert_dir_exists "$cfg_dir"
    assert_file_exists "$YOLOBOX_CONFIG_FILE"
}
