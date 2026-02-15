#!/usr/bin/env bash
# test_sandbox_profile.sh — tests for Seatbelt profile generation

_require_darwin() {
    if [[ "$(uname -s)" != "Darwin" ]]; then
        skip_test "macOS only"
        return 2
    fi
    return 0
}

test_profile_has_version() {
    _require_darwin || return 2

    local profile
    profile=$(sandbox_generate_profile "/tmp/wt" "/tmp/home" "/Users/alice")

    local first_line
    first_line=$(echo "$profile" | head -1)
    assert_eq "(version 1)" "$first_line" "First line should be (version 1)"
}

test_profile_contains_worktree_path() {
    _require_darwin || return 2

    local profile
    profile=$(sandbox_generate_profile "/my/worktree/path" "/tmp/home" "/Users/alice")

    assert_contains "$profile" '(subpath "/my/worktree/path")' "Profile should contain worktree subpath"
}

test_profile_contains_home_path() {
    _require_darwin || return 2

    local profile
    profile=$(sandbox_generate_profile "/tmp/wt" "/my/synthetic/home" "/Users/alice")

    assert_contains "$profile" '(subpath "/my/synthetic/home")' "Profile should contain synthetic home subpath"
}

test_profile_denies_writes() {
    _require_darwin || return 2

    local profile
    profile=$(sandbox_generate_profile "/tmp/wt" "/tmp/home" "/Users/alice")

    assert_contains "$profile" "(deny file-write*)" "Profile should deny file-write*"
}

test_profile_denies_home_reads() {
    _require_darwin || return 2

    local profile
    profile=$(sandbox_generate_profile "/tmp/wt" "/tmp/home" "/Users/alice")

    assert_contains "$profile" '(subpath "/Users/alice")' "Profile should reference real home"
    assert_contains "$profile" "(deny file-read*" "Profile should deny file-read*"
}

test_profile_allows_tmp() {
    _require_darwin || return 2

    local profile
    profile=$(sandbox_generate_profile "/tmp/wt" "/tmp/home" "/Users/alice")

    assert_contains "$profile" '"/private/tmp"' "Profile should allow /private/tmp"
    assert_contains "$profile" '"/private/var/folders"' "Profile should allow /private/var/folders"
}

test_profile_allows_dev_null() {
    _require_darwin || return 2

    local profile
    profile=$(sandbox_generate_profile "/tmp/wt" "/tmp/home" "/Users/alice")

    assert_contains "$profile" '"/dev/null"' "Profile should allow /dev/null"
    assert_contains "$profile" '"/dev/tty"' "Profile should allow /dev/tty"
}
