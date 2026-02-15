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

# ---- Access rule tests ----

test_config_global_allow_read() {
    local cfg_dir="${_TEST_CONFIG_DIR}/allow_read"
    mkdir -p "$cfg_dir"
    YOLOBOX_CONFIG_DIR="$cfg_dir"
    YOLOBOX_CONFIG_FILE="${cfg_dir}/config"

    cat > "$YOLOBOX_CONFIG_FILE" <<'EOF'
WORKTREE_LOC=/tmp/wt
SSH_KEY_PATH=/tmp/key
allow_read=/usr/local/share/data
allow_read=/opt/shared-libs
EOF

    local reads
    reads=$(config_get_allow_reads)
    assert_contains "$reads" "/usr/local/share/data" "Should include first global read path"
    assert_contains "$reads" "/opt/shared-libs" "Should include second global read path"
}

test_config_global_allow_write() {
    local cfg_dir="${_TEST_CONFIG_DIR}/allow_write"
    mkdir -p "$cfg_dir"
    YOLOBOX_CONFIG_DIR="$cfg_dir"
    YOLOBOX_CONFIG_FILE="${cfg_dir}/config"

    cat > "$YOLOBOX_CONFIG_FILE" <<'EOF'
WORKTREE_LOC=/tmp/wt
SSH_KEY_PATH=/tmp/key
allow_write=/tmp/shared-cache
EOF

    local writes
    writes=$(config_get_allow_writes)
    assert_contains "$writes" "/tmp/shared-cache" "Should include global write path"
}

test_config_project_allow_read() {
    local cfg_dir="${_TEST_CONFIG_DIR}/project_read"
    mkdir -p "$cfg_dir"
    YOLOBOX_CONFIG_DIR="$cfg_dir"
    YOLOBOX_CONFIG_FILE="${cfg_dir}/config"

    cat > "$YOLOBOX_CONFIG_FILE" <<'EOF'
WORKTREE_LOC=/tmp/wt
SSH_KEY_PATH=/tmp/key
allow_read=/global/path
allow_read.myapp=/project/specific/path
allow_read.otherapp=/other/project/path
EOF

    # With project=myapp, should get global + myapp-specific
    local reads
    reads=$(config_get_allow_reads "myapp")
    assert_contains "$reads" "/global/path" "Should include global read"
    assert_contains "$reads" "/project/specific/path" "Should include myapp read"
    assert_not_contains "$reads" "/other/project/path" "Should NOT include otherapp read"
}

test_config_project_allow_write() {
    local cfg_dir="${_TEST_CONFIG_DIR}/project_write"
    mkdir -p "$cfg_dir"
    YOLOBOX_CONFIG_DIR="$cfg_dir"
    YOLOBOX_CONFIG_FILE="${cfg_dir}/config"

    cat > "$YOLOBOX_CONFIG_FILE" <<'EOF'
WORKTREE_LOC=/tmp/wt
SSH_KEY_PATH=/tmp/key
allow_write=/global/write
allow_write.webapp=/webapp/output
EOF

    local writes
    writes=$(config_get_allow_writes "webapp")
    assert_contains "$writes" "/global/write" "Should include global write"
    assert_contains "$writes" "/webapp/output" "Should include webapp write"
}

test_config_no_allow_rules() {
    local cfg_dir="${_TEST_CONFIG_DIR}/no_rules"
    mkdir -p "$cfg_dir"
    YOLOBOX_CONFIG_DIR="$cfg_dir"
    YOLOBOX_CONFIG_FILE="${cfg_dir}/config"

    cat > "$YOLOBOX_CONFIG_FILE" <<'EOF'
WORKTREE_LOC=/tmp/wt
SSH_KEY_PATH=/tmp/key
EOF

    local reads writes
    reads=$(config_get_allow_reads "myapp")
    writes=$(config_get_allow_writes "myapp")
    assert_eq "" "$reads" "Should have no extra reads"
    assert_eq "" "$writes" "Should have no extra writes"
}

test_config_comments_ignored() {
    local cfg_dir="${_TEST_CONFIG_DIR}/comments"
    mkdir -p "$cfg_dir"
    YOLOBOX_CONFIG_DIR="$cfg_dir"
    YOLOBOX_CONFIG_FILE="${cfg_dir}/config"

    cat > "$YOLOBOX_CONFIG_FILE" <<'EOF'
WORKTREE_LOC=/tmp/wt
SSH_KEY_PATH=/tmp/key
# This is a comment
allow_read=/real/path
# allow_read=/commented/path
EOF

    local reads
    reads=$(config_get_allow_reads)
    assert_contains "$reads" "/real/path" "Should include real path"
    assert_not_contains "$reads" "/commented/path" "Should NOT include commented path"
}
