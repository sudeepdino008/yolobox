#!/usr/bin/env bash
# config.sh — configuration management for yolobox

YOLOBOX_CONFIG_DIR="${HOME}/.config/yolobox"
YOLOBOX_CONFIG_FILE="${YOLOBOX_CONFIG_DIR}/config"

config_load() {
    if [[ ! -f "$YOLOBOX_CONFIG_FILE" ]]; then
        die "No config found. Run 'yolobox setup' first."
    fi

    # Parse config manually (don't source — safer, supports repeated keys)
    while IFS='=' read -r key value; do
        # Skip comments and blank lines
        [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue
        # Trim whitespace
        key=$(echo "$key" | xargs)
        value=$(echo "$value" | xargs)
        case "$key" in
            WORKTREE_LOC) export WORKTREE_LOC="$value" ;;
            # allow_read / allow_write lines are parsed on demand
        esac
    done < "$YOLOBOX_CONFIG_FILE"

    if [[ -z "${WORKTREE_LOC:-}" ]]; then
        die "Config missing WORKTREE_LOC. Run 'yolobox setup' again."
    fi
}

config_save() {
    local worktree_loc="$1"

    mkdir -p "$YOLOBOX_CONFIG_DIR"
    cat > "$YOLOBOX_CONFIG_FILE" <<EOF
WORKTREE_LOC=${worktree_loc}
EOF
}

# Get extra allowed read paths (global + project-specific).
# Outputs one path per line.
# Usage: config_get_allow_reads [project_name]
config_get_allow_reads() {
    local project="${1:-}"
    [[ -f "$YOLOBOX_CONFIG_FILE" ]] || return 0

    while IFS='=' read -r key value; do
        [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue
        key=$(echo "$key" | xargs)
        value=$(echo "$value" | xargs)
        [[ -z "$value" ]] && continue
        # Global: allow_read=/path
        if [[ "$key" == "allow_read" ]]; then
            echo "$value"
        fi
        # Project-specific: allow_read.myproject=/path
        if [[ -n "$project" && "$key" == "allow_read.${project}" ]]; then
            echo "$value"
        fi
    done < "$YOLOBOX_CONFIG_FILE"
}

# Get extra allowed write paths (global + project-specific).
# Outputs one path per line.
# Usage: config_get_allow_writes [project_name]
config_get_allow_writes() {
    local project="${1:-}"
    [[ -f "$YOLOBOX_CONFIG_FILE" ]] || return 0

    while IFS='=' read -r key value; do
        [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue
        key=$(echo "$key" | xargs)
        value=$(echo "$value" | xargs)
        [[ -z "$value" ]] && continue
        # Global: allow_write=/path
        if [[ "$key" == "allow_write" ]]; then
            echo "$value"
        fi
        # Project-specific: allow_write.myproject=/path
        if [[ -n "$project" && "$key" == "allow_write.${project}" ]]; then
            echo "$value"
        fi
    done < "$YOLOBOX_CONFIG_FILE"
}

# Get extra env var names to pass through into the sandbox (global + project-specific).
# Values may be comma-separated lists. Outputs one var name per line.
# Usage: config_get_allow_envs [project_name]
config_get_allow_envs() {
    local project="${1:-}"
    [[ -f "$YOLOBOX_CONFIG_FILE" ]] || return 0

    while IFS='=' read -r key value; do
        [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue
        key=$(echo "$key" | xargs)
        value=$(echo "$value" | xargs)
        [[ -z "$value" ]] && continue
        local emit=0
        # Global: allow_env=VAR1,VAR2
        [[ "$key" == "allow_env" ]] && emit=1
        # Project-specific: allow_env.myproject=VAR1,VAR2
        [[ -n "$project" && "$key" == "allow_env.${project}" ]] && emit=1
        if [[ $emit -eq 1 ]]; then
            IFS=',' read -ra vars <<< "$value"
            for var in "${vars[@]}"; do
                var=$(echo "$var" | xargs)
                [[ -n "$var" ]] && echo "$var"
            done
        fi
    done < "$YOLOBOX_CONFIG_FILE"
}

config_check_deps() {
    local missing=()

    command -v git >/dev/null 2>&1 || missing+=("git")
    command -v fzf >/dev/null 2>&1 || missing+=("fzf — install: https://github.com/junegunn/fzf#installation")
    command -v claude >/dev/null 2>&1 || missing+=("claude — install: npm install -g @anthropic-ai/claude-code")

    local os
    os=$(uname -s)
    case "$os" in
        Darwin)
            command -v sandbox-exec >/dev/null 2>&1 || missing+=("sandbox-exec (should be built into macOS)")
            ;;
        Linux)
            command -v bwrap >/dev/null 2>&1 || missing+=("bwrap — install: apt install bubblewrap / dnf install bubblewrap")
            ;;
        *)
            die "Unsupported OS: $os"
            ;;
    esac

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "Missing dependencies:"
        for dep in "${missing[@]}"; do
            echo "  - $dep"
        done
        return 1
    fi
    return 0
}

config_setup() {
    echo -e "${BOLD}yolobox setup${RESET}"
    echo ""

    # Check dependencies
    echo "Checking dependencies..."
    if ! config_check_deps; then
        echo ""
        die "Install missing dependencies and run 'yolobox setup' again."
    fi
    info "All dependencies found."
    echo ""

    # Prompt for WORKTREE_LOC
    local worktree_loc
    read -r -p "Where should worktrees be stored? [${HOME}/worktrees]: " worktree_loc
    worktree_loc="${worktree_loc:-${HOME}/worktrees}"

    # Expand ~ if present
    worktree_loc="${worktree_loc/#\~/$HOME}"

    # Create if needed
    if [[ ! -d "$worktree_loc" ]]; then
        read -r -p "Directory '$worktree_loc' does not exist. Create it? [Y/n]: " create_it
        create_it="${create_it:-Y}"
        if [[ "$create_it" =~ ^[Yy] ]]; then
            mkdir -p "$worktree_loc"
            info "Created $worktree_loc"
        else
            die "Aborted."
        fi
    fi
    echo ""

    # Save
    config_save "$worktree_loc"
    info "Config saved to $YOLOBOX_CONFIG_FILE"
    echo ""
    info "Setup complete! You can now use:"
    echo "  yolobox create <branch_name>   — create a sandboxed worktree"
    echo "  yolobox attach                 — pick a worktree and launch claude"
    echo "  yolobox list                   — show all worktrees"
    echo "  yolobox delete <branch_name>   — remove a worktree"
}
