# yolobox

Sandboxed git worktrees for running `claude --dangerously-skip-permissions` safely.

## Project Structure

```
bin/yolobox           — Main CLI entry point
lib/common.sh         — Logging, project name detection, shared utils
lib/config.sh         — Config load/save/setup (~/.config/yolobox/config)
lib/worktree.sh       — Git worktree + synthetic home management
lib/sandbox.sh        — OS-aware sandbox dispatcher
lib/sandbox_darwin.sh  — macOS sandbox-exec (Seatbelt) implementation
lib/sandbox_linux.sh   — Linux bwrap stub (not yet implemented)
tests/runner.sh       — Minimal bash test framework
tests/test_*.sh       — Test suites
```

## Running Tests

```bash
# Run all tests
bash tests/runner.sh

# Run a specific test file
bash tests/runner.sh tests/test_worktree.sh
```

Sandbox profile and enforcement tests are macOS-only and will be skipped on Linux.

## Commands

- `yolobox setup` — one-time config (worktree location, SSH key)
- `yolobox create <branch>` — create worktree + synthetic home
- `yolobox attach` — fzf picker → launches claude in sandbox
- `yolobox list` — show worktrees + active status
- `yolobox delete <branch>` — remove worktree, preserve session state
