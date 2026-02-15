# yolobox — Implementation Plan

## Overview

yolobox combines **git worktrees** with **OS-native sandboxing** to create cheap,
isolated copies of a repo where `claude --dangerously-skip-permissions` can run safely.
On macOS, we use `sandbox-exec` (Seatbelt); on Linux (future), bubblewrap.

The sandbox **restricts filesystem writes** to the worktree, a synthetic `$HOME`,
and system temp directories. It also **denies reads to the user's real `$HOME`**
to prevent snooping on other repos, credentials, browser data, etc.

---

## Decisions Summary

| Decision | Choice |
|---|---|
| Platform | macOS first (`sandbox-exec`), Linux later (`bwrap`) |
| Network | Full access for now (domain filtering is v2 — needs proxy) |
| `yolobox attach` | Auto-launches `claude --dangerously-skip-permissions` |
| Home directory | Minimal synthetic home |
| Multi-terminal | Same bind config, separate processes |
| Global installs | Ephemeral (lost on sandbox exit) |
| `yolobox delete` | Removes worktree + branch; `.claude/` session state preserved in synthetic home |
| Config location | `~/.config/yolobox/config` |
| `yolobox create` | Creates and returns (no auto-attach) |
| Deps check | `yolobox setup` verifies `git`, `fzf`, `claude`, `sandbox-exec` |
| Env vars passed | Inherit all, override `HOME` |
| `yolobox list` | Yes, shows worktrees + active status |

---

## Directory Layout

### Project structure (this repo)

```
yolobox/
├── bin/
│   └── yolobox                # Main entry point (bash)
├── lib/
│   ├── common.sh              # Shared utils: logging, error handling, project detection
│   ├── config.sh              # Config load/save, setup wizard
│   ├── worktree.sh            # Git worktree create/delete/list
│   ├── sandbox.sh             # Sandbox dispatcher (delegates to OS-specific impl)
│   ├── sandbox_darwin.sh      # macOS: generate Seatbelt profile, run sandbox-exec
│   └── sandbox_linux.sh       # Linux: bwrap invocation (stub for now)
├── tests/
│   ├── runner.sh              # Minimal test runner (no external deps)
│   ├── test_config.sh         # Config management tests
│   ├── test_worktree.sh       # Worktree create/delete/list tests
│   ├── test_sandbox_profile.sh # Seatbelt profile generation tests
│   └── test_integration.sh    # End-to-end tests (uses this repo)
└── CLAUDE.md
```

### Runtime directory layout

```
$WORKTREE_LOC/
├── <project>.worktrees/
│   ├── feature-foo/           # git worktree checkout
│   └── bugfix-bar/            # git worktree checkout
└── <project>.homes/
    ├── feature-foo/           # synthetic $HOME for feature-foo
    │   ├── .claude/
    │   │   ├── settings.json  # copied from real home (at create time)
    │   │   ├── CLAUDE.md      # copied from real home (at create time)
    │   │   └── ...            # writable session state accumulates here
    │   ├── .ssh/
    │   │   ├── <key>          # symlink to configured private key
    │   │   ├── <key>.pub      # symlink to public key
    │   │   └── known_hosts    # symlink to real known_hosts
    │   └── .gitconfig         # symlink to real .gitconfig
    └── bugfix-bar/
        └── ...
```

---

## Commands

### `yolobox setup`

One-time global setup. Interactive wizard.

1. Check dependencies: `git`, `fzf`, `claude`, and `sandbox-exec` (macOS) or `bwrap` (Linux)
   - If missing, print install instructions and exit
2. Prompt for `WORKTREE_LOC` (base directory for all worktrees)
   - Validate path exists or offer to create it
3. Prompt for SSH private key path (for git commits inside sandbox)
   - Validate file exists
4. Save config to `~/.config/yolobox/config` (bash-sourceable `KEY=value` format)

**Config file format:**
```bash
WORKTREE_LOC=/path/to/worktrees
SSH_KEY_PATH=/path/to/.ssh/id_ed25519
```

### `yolobox create <branch_name>`

Creates a worktree + synthetic home. Returns without attaching.

1. Load config, determine project name (from `git remote get-url origin`, fallback to dir name)
2. Resolve main repo root via `git rev-parse --git-common-dir`
   - Works even if run from inside an existing worktree
3. Create `$WORKTREE_LOC/<project>.worktrees/<branch_name>`:
   - `git worktree add <path> -b <branch_name>` (new branch)
   - If branch exists: `git worktree add <path> <branch_name>` (no `-b`)
4. Create synthetic home at `$WORKTREE_LOC/<project>.homes/<branch_name>/`
   - `mkdir -p .claude .ssh`
   - Symlink `.gitconfig` → real `~/.gitconfig`
   - Symlink `.ssh/<keyname>`, `.ssh/<keyname>.pub`, `.ssh/known_hosts`
   - Copy `~/.claude/settings.json` if exists
   - Copy `~/.claude/CLAUDE.md` if exists
5. Print: `Created worktree '<branch_name>' at <path>`

### `yolobox attach`

Interactive worktree selector → enters sandbox with claude.

1. Load config, determine project name
2. List worktrees in `$WORKTREE_LOC/<project>.worktrees/`
3. Pipe to `fzf` for selection (show branch name + path)
4. Generate a Seatbelt profile (macOS) with:
   - Worktree path (read-write)
   - Synthetic home path (read-write)
   - System temp dirs (read-write)
   - Everything else readable, not writable
5. Execute:
   ```bash
   sandbox-exec -f /tmp/yolobox-<pid>.sb \
     env HOME=<synthetic_home> \
     bash -c 'cd "<worktree_path>" && claude --dangerously-skip-permissions'
   ```
6. On exit, clean up temp profile file

### `yolobox delete <branch_name>`

Removes worktree and branch. Preserves session state.

1. Load config, determine project name
2. Check if any sandbox process is running for this worktree
   - If running: refuse, print "Sandbox is active. Exit it first."
3. `git worktree remove $WORKTREE_LOC/<project>.worktrees/<branch_name>`
4. `git branch -D <branch_name>`
5. Print: `Deleted worktree '<branch_name>'. Session state preserved at <homes_path>.`
   - Do NOT delete the synthetic home — `.claude/` session state persists

### `yolobox list`

Shows all worktrees for the current project with status.

1. Load config, determine project name
2. List dirs in `$WORKTREE_LOC/<project>.worktrees/`
3. For each, check if a `sandbox-exec` process exists with that path in its args
4. Display table:
   ```
   BRANCH          STATUS     PATH
   feature-foo     active     /worktrees/myproject.worktrees/feature-foo
   bugfix-bar      inactive   /worktrees/myproject.worktrees/bugfix-bar
   ```

---

## Seatbelt Profile (macOS)

Generated per-attach with paths substituted:

```scheme
(version 1)
(allow default)

;; --- WRITE RESTRICTIONS ---
;; Deny all file writes globally
(deny file-write*)

;; Allow writes to the worktree
(allow file-write*
  (subpath "${WORKTREE_PATH}"))

;; Allow writes to the synthetic home
(allow file-write*
  (subpath "${SYNTHETIC_HOME}"))

;; Allow writes to system temp dirs (macOS uses /private/tmp and /private/var/folders)
(allow file-write*
  (subpath "/private/tmp")
  (subpath "/private/var/folders"))

;; Allow writes to device files needed for terminal/IO
(allow file-write*
  (literal "/dev/null")
  (literal "/dev/tty")
  (literal "/dev/dfd")
  (regex #"^/dev/ttys[0-9]+$")
  (regex #"^/dev/pty[a-z][0-9a-f]$"))

;; --- READ RESTRICTIONS ---
;; Deny reads to real home (prevents snooping on other repos, credentials, browser data)
(deny file-read*
  (subpath "${REAL_HOME}"))

;; Allow reads back for worktree and synthetic home (overrides the deny above)
(allow file-read*
  (subpath "${WORKTREE_PATH}")
  (subpath "${SYNTHETIC_HOME}"))
```

**Why restrict reads?** Without this, a sandboxed process could read `~/.ssh/id_rsa`,
`~/.aws/credentials`, `~/.env`, other repos, browser profile data, etc. The worktree
and synthetic home contain everything the sandbox needs.

---

## Implementation Steps

### Step 1: Project scaffolding + main entry point
- Create directory structure (`bin/`, `lib/`, `tests/`)
- `bin/yolobox`: argument parser, dispatches to subcommands
- `lib/common.sh`: logging (`info`, `warn`, `die`), project name detection
- Make executable, add shebang

### Step 2: Config management (`lib/config.sh`)
- `config_load()`: source `~/.config/yolobox/config`, validate required vars
- `config_save()`: write config file
- `config_setup()`: interactive wizard (prompts for WORKTREE_LOC, SSH_KEY_PATH)
- Dependency checking function

### Step 3: Worktree management (`lib/worktree.sh`)
- `worktree_create <branch>`: git worktree add + synthetic home setup
- `worktree_delete <branch>`: safety check, git worktree remove + branch delete
- `worktree_list`: enumerate worktrees with status
- `worktree_path <branch>`: resolve full path for a branch
- `home_path <branch>`: resolve synthetic home path

### Step 4: Sandbox — macOS (`lib/sandbox_darwin.sh`)
- `sandbox_generate_profile()`: takes worktree_path + home_path, outputs .sb file
- `sandbox_exec()`: generates profile, runs `sandbox-exec -f ... env HOME=... bash -c '...'`
- `sandbox_is_active()`: checks if a sandbox process is running for a given worktree

### Step 5: Sandbox dispatcher (`lib/sandbox.sh`)
- Detects OS (`uname -s`)
- Sources `sandbox_darwin.sh` or `sandbox_linux.sh`
- `sandbox_linux.sh`: stub that prints "Linux support coming soon"

### Step 6: Attach command with fzf
- Enumerate worktrees, pipe to fzf
- On selection, call `sandbox_exec`

### Step 7: Tests
- `tests/runner.sh`: minimal test framework (`assert_eq`, `assert_ok`, `assert_fail`, test discovery)
- `tests/test_config.sh`: setup writes config, load reads it back
- `tests/test_worktree.sh`: create/delete/list using this repo as test subject
  - Uses a temp WORKTREE_LOC
  - Cleans up after itself
- `tests/test_sandbox_profile.sh`: profile generation produces valid syntax, correct paths
- `tests/test_sandbox_enforcement.sh`: actually runs sandbox-exec and verifies restrictions
- `tests/test_integration.sh`: end-to-end create → list → delete flow

See **Test Plan** section below for full details.

### Step 8: CLAUDE.md
- Document project structure, how to run tests, development notes

---

## Linux Support (Future — Not Implemented Now)

`lib/sandbox_linux.sh` will use bubblewrap with setgid method:

```bash
bwrap \
  --ro-bind /usr /usr \
  --ro-bind /bin /bin \
  --ro-bind /lib /lib \
  --ro-bind /lib64 /lib64 \
  --ro-bind /etc/resolv.conf /etc/resolv.conf \
  --ro-bind /etc/hosts /etc/hosts \
  --ro-bind /etc/ssl /etc/ssl \
  --bind "$WORKTREE_PATH" "$WORKTREE_PATH" \
  --bind "$SYNTHETIC_HOME" "$HOME" \
  --tmpfs /tmp \
  --proc /proc \
  --dev /dev \
  --unshare-pid \
  --die-with-parent \
  claude --dangerously-skip-permissions
```

---

## Test Plan

### Test Framework (`tests/runner.sh`)
Minimal bash test runner, no external dependencies. Provides:
- `assert_eq <expected> <actual> <msg>` — string equality
- `assert_contains <haystack> <needle> <msg>` — substring check
- `assert_ok <cmd...>` — command exits 0
- `assert_fail <cmd...>` — command exits non-zero
- `assert_file_exists <path>`
- `assert_file_not_exists <path>`
- Auto-discovers `test_*` functions in test files
- Prints pass/fail with colors, exits non-zero on any failure

### Test Suite 1: Config (`tests/test_config.sh`)

| Test | What it does | Expected output |
|---|---|---|
| `test_config_save_and_load` | Save config with WORKTREE_LOC + SSH_KEY_PATH, then load it back | Variables match saved values |
| `test_config_load_missing` | Try to load when config file doesn't exist | Exits non-zero, prints error |
| `test_config_load_incomplete` | Config file exists but missing required vars | Exits non-zero, names missing var |
| `test_config_dir_creation` | Save config when `~/.config/yolobox/` doesn't exist | Directory and file are created |

### Test Suite 2: Worktree Management (`tests/test_worktree.sh`)

Uses this repo as the test subject. Creates a temp dir for WORKTREE_LOC. Cleans up on exit.

| Test | What it does | Expected output |
|---|---|---|
| `test_create_worktree` | `worktree_create test-branch-1` | Dir exists at `<loc>/<project>.worktrees/test-branch-1/`, is a valid git worktree, synthetic home exists with .claude/ and .ssh/ dirs |
| `test_create_existing_branch` | Create worktree for a branch that already exists | Succeeds (uses existing branch, no `-b`) |
| `test_create_duplicate` | Try to create worktree for a branch that already has a worktree | Exits non-zero, prints error |
| `test_synthetic_home_contents` | Inspect synthetic home after create | `.gitconfig` symlink exists, `.ssh/` contains key symlinks, `.claude/` dir exists |
| `test_list_worktrees` | Create 2 worktrees, run list | Both branches appear in output with paths |
| `test_delete_worktree` | Create then delete a worktree | Worktree dir gone, branch deleted, synthetic home still exists |
| `test_delete_nonexistent` | Delete a branch that doesn't exist | Exits non-zero, prints error |
| `test_project_name_from_remote` | In a repo with remote origin set | Returns repo name from URL |
| `test_project_name_fallback` | In a repo with no remote | Falls back to directory name |

### Test Suite 3: Sandbox Profile Generation (`tests/test_sandbox_profile.sh`)

| Test | What it does | Expected output |
|---|---|---|
| `test_profile_contains_worktree_path` | Generate profile with worktree path `/tmp/test-wt` | Profile contains `(subpath "/tmp/test-wt")` in both read and write allows |
| `test_profile_contains_home_path` | Generate profile with home path `/tmp/test-home` | Profile contains `(subpath "/tmp/test-home")` in both read and write allows |
| `test_profile_denies_writes` | Inspect generated profile | Contains `(deny file-write*)` |
| `test_profile_denies_home_reads` | Generate with real home `/Users/alice` | Contains `(deny file-read* (subpath "/Users/alice"))` |
| `test_profile_has_version` | Inspect generated profile | First line is `(version 1)` |
| `test_profile_allows_tmp` | Inspect generated profile | Contains write allow for `/private/tmp` |

### Test Suite 4: Sandbox Enforcement (`tests/test_sandbox_enforcement.sh`)

**These tests actually run inside `sandbox-exec` on macOS.** Skipped on Linux.

| Test | What it does | Expected output |
|---|---|---|
| `test_write_to_worktree_allowed` | Inside sandbox: `touch <worktree>/testfile` | Succeeds (exit 0) |
| `test_write_to_home_allowed` | Inside sandbox: `touch <synthetic_home>/testfile` | Succeeds (exit 0) |
| `test_write_outside_denied` | Inside sandbox: `touch /tmp/yolobox-outside-test/bad` | Fails (Operation not permitted) |
| `test_write_to_real_home_denied` | Inside sandbox: `touch <real_home>/yolobox-test-canary` | Fails (Operation not permitted) |
| `test_read_worktree_allowed` | Inside sandbox: `cat <worktree>/README.md` (or any file) | Succeeds |
| `test_read_real_home_denied` | Inside sandbox: `cat <real_home>/.bashrc` | Fails (Operation not permitted) |
| `test_read_system_allowed` | Inside sandbox: `cat /etc/hosts` | Succeeds |
| `test_network_allowed` | Inside sandbox: `curl -s --max-time 5 https://example.com` | Succeeds (or skip if no network) |
| `test_git_operations_work` | Inside sandbox: `cd <worktree> && git status` | Succeeds |
| `test_rm_outside_denied` | Inside sandbox: `rm <real_home>/yolobox-should-not-exist` | Fails |

### Test Suite 5: Integration (`tests/test_integration.sh`)

End-to-end flows using the real `yolobox` commands.

| Test | What it does | Expected output |
|---|---|---|
| `test_create_list_delete_flow` | `create test-e2e` → `list` → `delete test-e2e` | Create prints path, list shows branch, delete prints confirmation, list no longer shows branch |
| `test_session_state_persists` | Create worktree, write file to `.claude/` in synthetic home, delete worktree | Synthetic home and `.claude/` file still exist |
| `test_multiple_worktrees` | Create 3 worktrees, list, verify all present | All 3 appear |

---

## Edge Cases & Notes

- **Running from a worktree**: `yolobox create` should work from any worktree of the same repo.
  Uses `git rev-parse --git-common-dir` to find the shared .git.
- **Branch already exists**: `yolobox create` detects this and skips `-b` flag.
- **No remote**: falls back to directory name for project naming.
- **Worktree dir already exists**: error with clear message.
- **sandbox-exec deprecation**: Still functional through macOS 15+. Used by OpenAI Codex,
  Anthropic srt, Gemini CLI. If Apple removes it, we'll need an alternative (Apple Containers, Docker).
- **Env vars**: All inherited from host. Only `HOME` is overridden.
- **Network**: Full access. Domain-level filtering (v2) would require a local proxy.
