# yolobox

Sandboxed git worktrees for running `claude --dangerously-skip-permissions` safely.

## Project Structure

```
bin/yolobox            — CLI entry point, argument parsing, command dispatch
lib/common.sh          — Logging (info/warn/die), project name detection, path helpers
lib/config.sh          — Config parse/save/setup, access rule queries (~/.config/yolobox/config) [only WORKTREE_LOC]
lib/worktree.sh        — Git worktree create/delete/list, synthetic home setup
lib/sandbox.sh         — OS-aware sandbox dispatcher (sources OS-specific impl)
lib/sandbox_darwin.sh  — macOS: Seatbelt profile generation + sandbox-exec invocation
lib/sandbox_linux.sh   — Linux: bubblewrap stub (not yet implemented)
tests/runner.sh        — Minimal bash test framework (assert_eq, assert_contains, etc.)
tests/test_*.sh        — Test suites (config, worktree, sandbox profile, enforcement, integration)
```

## Running Tests

```bash
bash tests/runner.sh                          # all tests
bash tests/runner.sh tests/test_worktree.sh   # single suite
```

Sandbox profile generation and enforcement tests are macOS-only (skipped on Linux).

## Key Design Decisions

- Config is parsed manually (not sourced) for safety and to support repeated keys
- Seatbelt profile denies writes globally, then whitelists worktree + synthetic home + /tmp
- Seatbelt profile denies reads to real $HOME, then whitelists worktree + synthetic home
- No git push from sandbox — `GIT_CONFIG_*` env vars override push URL inside sandbox only
- Environment scrubbed via `env -i` — only essential vars pass through
- OAuth token extracted from macOS keychain pre-sandbox, passed via `CLAUDE_CODE_OAUTH_TOKEN`
- `~/.claude.json` copied to synthetic home (onboarding state, theme, auth method)
- Small `~/.claude/` subdirectories (statsig, cache, commands, etc.) copied best-effort
- `allow_read` / `allow_write` config lines add extra paths to the Seatbelt profile
- Project-scoped rules use dot notation: `allow_read.myproject=/path`
- Synthetic home persists after `yolobox delete` (preserves .claude/ session state)
- Project name derived from `git remote get-url origin`, fallback to directory name
