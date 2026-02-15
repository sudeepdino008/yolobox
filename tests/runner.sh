#!/usr/bin/env bash
# runner.sh — minimal bash test framework for yolobox
#
# Usage: ./tests/runner.sh [test_file...]
#   If no files specified, runs all tests/test_*.sh files.

set -euo pipefail

# Colors
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    BOLD='\033[1m'
    RESET='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    BOLD=''
    RESET=''
fi

_TESTS_RUN=0
_TESTS_PASSED=0
_TESTS_FAILED=0
_TESTS_SKIPPED=0
_CURRENT_TEST=""

# ---- Assertions ----

assert_eq() {
    local expected="$1"
    local actual="$2"
    local msg="${3:-"expected '$expected', got '$actual'"}"
    if [[ "$expected" != "$actual" ]]; then
        echo -e "  ${RED}FAIL${RESET}: $msg"
        echo "    expected: $expected"
        echo "    actual:   $actual"
        return 1
    fi
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local msg="${3:-"expected output to contain '$needle'"}"
    if [[ "$haystack" != *"$needle"* ]]; then
        echo -e "  ${RED}FAIL${RESET}: $msg"
        echo "    looking for: $needle"
        echo "    in: $haystack"
        return 1
    fi
}

assert_not_contains() {
    local haystack="$1"
    local needle="$2"
    local msg="${3:-"expected output NOT to contain '$needle'"}"
    if [[ "$haystack" == *"$needle"* ]]; then
        echo -e "  ${RED}FAIL${RESET}: $msg"
        echo "    should not contain: $needle"
        echo "    in: $haystack"
        return 1
    fi
}

assert_ok() {
    if ! "$@" >/dev/null 2>&1; then
        echo -e "  ${RED}FAIL${RESET}: command should have succeeded: $*"
        return 1
    fi
}

assert_fail() {
    if "$@" >/dev/null 2>&1; then
        echo -e "  ${RED}FAIL${RESET}: command should have failed: $*"
        return 1
    fi
}

assert_file_exists() {
    local path="$1"
    if [[ ! -e "$path" ]]; then
        echo -e "  ${RED}FAIL${RESET}: file should exist: $path"
        return 1
    fi
}

assert_file_not_exists() {
    local path="$1"
    if [[ -e "$path" ]]; then
        echo -e "  ${RED}FAIL${RESET}: file should NOT exist: $path"
        return 1
    fi
}

assert_dir_exists() {
    local path="$1"
    if [[ ! -d "$path" ]]; then
        echo -e "  ${RED}FAIL${RESET}: directory should exist: $path"
        return 1
    fi
}

assert_symlink() {
    local path="$1"
    if [[ ! -L "$path" ]]; then
        echo -e "  ${RED}FAIL${RESET}: should be a symlink: $path"
        return 1
    fi
}

skip_test() {
    local reason="${1:-"no reason given"}"
    echo "SKIP: $reason"
    return 2
}

# ---- Test runner ----

run_test() {
    local test_func="$1"
    _CURRENT_TEST="$test_func"
    ((_TESTS_RUN++)) || true

    echo -n -e "  ${test_func}... "

    local exit_code=0
    # Run the test function, capturing output
    local output
    output=$("$test_func" 2>&1) || exit_code=$?

    if [[ $exit_code -eq 0 ]]; then
        echo -e "${GREEN}PASS${RESET}"
        ((_TESTS_PASSED++)) || true
    elif [[ $exit_code -eq 2 ]]; then
        # skip_test returns 2
        ((_TESTS_SKIPPED++)) || true
        # Output contains the "SKIP: reason" message
        if [[ -n "$output" ]]; then
            echo -e "${YELLOW}SKIP${RESET} (${output#SKIP: })"
        else
            echo -e "${YELLOW}SKIP${RESET}"
        fi
    else
        echo -e "${RED}FAIL${RESET}"
        if [[ -n "$output" ]]; then
            echo "$output"
        fi
        ((_TESTS_FAILED++)) || true
    fi
}

run_test_file() {
    local test_file="$1"
    local file_name
    file_name=$(basename "$test_file")

    echo -e "${BOLD}${file_name}${RESET}"

    # Source the test file (it defines test_ functions)
    # shellcheck source=/dev/null
    source "$test_file"

    # Discover and run all test_ functions
    local test_funcs
    test_funcs=$(declare -F | awk '{print $3}' | grep '^test_' | sort)

    for func in $test_funcs; do
        run_test "$func"
    done

    # Run teardown if defined
    if declare -F teardown_all >/dev/null 2>&1; then
        teardown_all
    fi

    # Unset test functions to avoid leaking between files
    for func in $test_funcs; do
        unset -f "$func"
    done
    unset -f teardown_all 2>/dev/null || true
    unset -f setup_all 2>/dev/null || true

    echo ""
}

# ---- Main ----

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
YOLOBOX_ROOT="$(dirname "$TESTS_DIR")"

# Source yolobox libraries for testing
source "${YOLOBOX_ROOT}/lib/common.sh"
source "${YOLOBOX_ROOT}/lib/config.sh"
source "${YOLOBOX_ROOT}/lib/sandbox.sh"
source "${YOLOBOX_ROOT}/lib/worktree.sh"

if [[ $# -gt 0 ]]; then
    # Run specific test files
    for f in "$@"; do
        run_test_file "$f"
    done
else
    # Run all test files
    for f in "$TESTS_DIR"/test_*.sh; do
        [[ -f "$f" ]] || continue
        run_test_file "$f"
    done
fi

# Summary
echo -e "${BOLD}Results:${RESET} ${_TESTS_RUN} run, ${GREEN}${_TESTS_PASSED} passed${RESET}, ${RED}${_TESTS_FAILED} failed${RESET}, ${YELLOW}${_TESTS_SKIPPED} skipped${RESET}"

if [[ $_TESTS_FAILED -gt 0 ]]; then
    exit 1
fi
