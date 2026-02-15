# yolobox

Sandboxed git worktrees for running `claude --dangerously-skip-permissions` safely.

Each worktree gets its own OS-native sandbox (macOS `sandbox-exec`) that restricts filesystem access — Claude can only write to the worktree and a synthetic `$HOME`, and can't read your real home directory.

---

## Table of Contents

- [How It Works](#how-it-works)
- [Install](#install)
- [Quick Start](#quick-start)
- [Commands](#commands)
- [Configuration](#configuration)
- [Access Rules](#access-rules)
- [Security Model](#security-model)
- [Platform Support](#platform-support)

---

## How It Works

```
your-repo/
  ├── (your normal working copy)

~/worktrees/
  ├── your-repo.worktrees/
  │   ├── feature-x/        ← git worktree (read-write)
  │   └── bugfix-y/         ← git worktree (read-write)
  └── your-repo.homes/
      ├── feature-x/        ← synthetic $HOME (read-write)
      │   ├── .claude/      ← session state persists here
      │   ├── .ssh/         ← symlinks to your real key
      │   └── .gitconfig    ← symlink to your real config
      └── bugfix-y/
```

`yolobox create` makes a cheap git worktree + a minimal synthetic home.
`yolobox attach` picks one via fzf and drops you into a sandboxed Claude session.

The sandbox allows full network access but locks down the filesystem:
writes only go to the worktree and synthetic home, reads to your real `$HOME` are blocked.

---

## Install

```bash
git clone https://github.com/sudeepdino008/yolobox.git
export PATH="$PWD/yolobox/bin:$PATH"
```

**Dependencies:** `git`, `fzf`, `claude` (Claude Code CLI), `sandbox-exec` (built into macOS).

---

## Quick Start

```bash
# 1. One-time setup
yolobox setup

# 2. cd into any git repo and create a worktree
cd ~/projects/my-app
yolobox create feature-x

# 3. Attach — launches claude in sandbox
yolobox attach
```

---

## Commands

| Command | Description |
|---|---|
| `yolobox setup` | One-time config: worktree location, SSH key, dependency check |
| `yolobox create <branch>` | Create a git worktree + synthetic home |
| `yolobox attach` | fzf picker → launch Claude in sandbox |
| `yolobox list` | Show worktrees for current project with active/inactive status |
| `yolobox delete <branch>` | Remove worktree + branch. Session state (`.claude/`) is preserved |

---

## Configuration

Config lives at `~/.config/yolobox/config`:

```bash
WORKTREE_LOC=~/worktrees
SSH_KEY_PATH=~/.ssh/id_ed25519
```

---

## Access Rules

By default, the sandbox blocks reads to your real `$HOME` and only allows writes to the worktree + synthetic home. You can grant extra access in the config file:

```bash
# Global — applies to all projects
allow_read=/usr/local/share/data
allow_write=/tmp/shared-cache

# Project-specific — only when working on that repo
allow_read.my-app=/path/to/shared-lib
allow_write.my-app=/path/to/output-dir
```

- One path per line, multiple entries allowed
- Global rules (`allow_read`, `allow_write`) apply to every sandbox session
- Project rules (`allow_read.<project>`, `allow_write.<project>`) only apply when the repo name matches
- Project name is derived from `git remote get-url origin` (falls back to directory name)

---

## Security Model

The macOS Seatbelt profile enforces:

| Access | Policy |
|---|---|
| **Filesystem writes** | Denied everywhere, except worktree, synthetic `$HOME`, `/tmp` |
| **Filesystem reads** | Denied for real `$HOME`. Allowed for worktree, synthetic `$HOME`, system paths |
| **Network** | Full access |
| **Processes** | Full access (Claude can run git, npm, etc.) |

What this protects against:
- Claude reading `~/.ssh/`, `~/.aws/`, `~/.env`, other repos, browser data
- Claude writing outside its worktree (no modifying your real home, other projects, system files)

What this does **not** protect against:
- Network exfiltration (Claude can `curl` anywhere)
- Damage within the worktree itself (it has full write access there)

---

## Platform Support

| Platform | Status | Mechanism |
|---|---|---|
| macOS | Supported | `sandbox-exec` (Seatbelt) |
| Linux | Planned | `bubblewrap` (bwrap with setgid) |
