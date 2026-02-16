#!/usr/bin/env bash
# sandbox.sh — OS-aware sandbox dispatcher

YOLOBOX_OS=$(uname -s)

# Source the appropriate OS implementation
YOLOBOX_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "$YOLOBOX_OS" in
    Darwin)
        # shellcheck source=sandbox_darwin.sh
        source "${YOLOBOX_LIB_DIR}/sandbox_darwin.sh"
        ;;
    Linux)
        # shellcheck source=sandbox_linux.sh
        source "${YOLOBOX_LIB_DIR}/sandbox_linux.sh"
        ;;
    *)
        die "Unsupported OS: $YOLOBOX_OS"
        ;;
esac

# Unified interface
# Args: worktree_path synthetic_home [extra_reads] [extra_writes] [sandbox_cmd] [block_lan]
sandbox_exec() {
    local worktree_path="$1"
    local synthetic_home="$2"
    local extra_reads="${3:-}"
    local extra_writes="${4:-}"
    local sandbox_cmd="${5:-}"
    local block_lan="${6:-}"

    case "$YOLOBOX_OS" in
        Darwin) sandbox_exec_darwin "$worktree_path" "$synthetic_home" "$extra_reads" "$extra_writes" "$sandbox_cmd" "$block_lan" ;;
        Linux)  sandbox_exec_linux "$worktree_path" "$synthetic_home" ;;
    esac
}

sandbox_is_active() {
    local worktree_path="$1"

    case "$YOLOBOX_OS" in
        Darwin) sandbox_is_active_darwin "$worktree_path" ;;
        Linux)  sandbox_is_active_linux "$worktree_path" ;;
    esac
}
