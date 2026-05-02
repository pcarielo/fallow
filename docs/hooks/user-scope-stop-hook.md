# User-scope Stop hook (`fallow init --hook-user`)

Run `fallow audit` after every Claude Code turn that edits TS/JS files,
across **all** projects on your machine, with a 3-strike anti-loop.

## Install

```bash
npm install -g fallow      # or: cargo install fallow-cli
fallow init --hook-user
```

This writes `~/.claude/hooks/fallow-stop-gate.sh` and adds an entry to
`~/.claude/settings.json` Stop array. Existing hooks are preserved.

## Recommended rollout: 2 phases

**Phase 1 — dry-run (1 week):**

```bash
echo 'export FALLOW_HOOK_DRY_RUN=1' >> ~/.zshrc
exec zsh
```

The hook computes verdict but never blocks. Decisions are logged to
`~/.claude/.fallow-hook.log`. Review the log; once you're satisfied
there are no false positives, drop the env var to go live.

**Phase 2 — live:** remove `FALLOW_HOOK_DRY_RUN` from your shell rc.

## How it decides to run

1. `stop_hook_active=true` from Claude Code → exit 0 (re-entry guard)
2. `FALLOW_HOOK_DISABLED=1` → exit 0
3. No TS/JS edits in the turn (transcript scan) → exit 0
4. No `package.json` and no `.fallowrc.{json,jsonc}`/`fallow.toml` in
   project root → exit 0
5. `.fallowrc.json` has `hook.disabled=true` → exit 0
6. No `fallow` on PATH and no `npx --no-install fallow` → exit 0
7. `fallow` version below `FALLOW_HOOK_MIN_VERSION` (default 2.61.0) → exit 2 with message
8. `git diff` (tracked + untracked) exceeds `FALLOW_HOOK_MAX_DIFF` files (default 500) → exit 0 with note
9. Otherwise: run `fallow audit --format json --quiet --explain` (timeout 120s)

## Verdict behaviour

| Verdict | Action |
|---------|--------|
| `pass` | Silent. State `fail_count=0`. |
| `warn` | Stderr note `⚠ fallow audit: N warn findings`. |
| `fail` (count <3) | `{"decision":"block","reason":"…"}` JSON to Claude with top 10 introduced issues. |
| `fail` (count ≥3) | Advisory: instructs Claude to **stop and ask the user**. Resets on `pass`/`warn` or 30 min idle or new session. |

## Environment variables

| Var | Default | Function |
|-----|---------|----------|
| `FALLOW_HOOK_DISABLED` | unset | `1` exits immediately |
| `FALLOW_HOOK_DRY_RUN` | unset | Compute verdict, never block |
| `FALLOW_HOOK_DEBUG` | unset | Verbose stderr |
| `FALLOW_HOOK_TIMEOUT` | 120 | Seconds for `fallow audit` |
| `FALLOW_HOOK_MAX_DIFF` | 500 | Skip if `git diff` > N files (set 0 to disable) |
| `FALLOW_HOOK_LOOP_LIMIT` | 3 | Strikes before advisory |
| `FALLOW_HOOK_LOOP_TTL_SECS` | 1800 | Reset count after N idle seconds |
| `FALLOW_HOOK_MIN_VERSION` | 2.61.0 | Binary floor |
| `FALLOW_HOOK_STATE_DIR` | `$CLAUDE_PROJECT_DIR/.claude` | State file dir |
| `FALLOW_HOOK_LOG` | `~/.claude/.fallow-hook.log` | Log path (DEBUG/DRY_RUN) |

## Per-project opt-out

Add to `.fallowrc.json` (TOML and `.jsonc` with comments are not honored
for this flag — see "MVP limitations" below):

```json
{ "hook": { "disabled": true } }
```

## MVP limitations

- `hook.disabled` only respected in pure-JSON `.fallowrc.json` (or
  `.fallowrc.jsonc` without comments). TOML and JSONC-with-comments
  configs surface a debug message and proceed.
- Hook runs only on Unix-style shells (Linux, macOS, WSL/git-bash on
  Windows). The `~/.claude/` settings file path is shared by Claude
  Code across all of these.

## Uninstall

```bash
fallow init --hook-user --uninstall
```

Removes the script and the Stop array entry. State files in each
project's `.claude/.fallow-hook-state.json` remain — delete manually if
desired.

## Coexistence with `fallow setup-hooks` and `fallow hooks install`

The user-scope Stop hook is complementary to fallow's commit-time gates:

- **`fallow init --hook-user`** (this doc) — soft, per-turn, user-scope
- **`fallow hooks install --target git`** — hard, blocks `git commit`, project-scope shell hook
- **`fallow hooks install --target agent`** — hard, blocks Claude Code/Codex `git commit/push` tool calls, project-scope

Defense in depth: turn-time soft check + commit-time hard gate. The
three can coexist; their checks are independent.
