# Fallow Delivery Hook Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `fallow init --hook-user` plus `fallow-stop-gate.sh`, a user-scope Claude Code Stop hook that gates code delivery via `fallow audit`, with 3-strike anti-loop, graceful degradation, and 2-phase rollout.

**Architecture:** Bash hook script (embedded via `include_str!`) installed at `~/.claude/hooks/`, registered in `~/.claude/settings.json` Stop array by a new Rust subcommand flag. Script parses Stop hook input JSON, runs heuristic on the Claude transcript, conditionally invokes `fallow audit --format json --quiet --explain`, and emits `{"decision":"block","reason":"..."}` JSON for the LLM to react to. Per-project state file tracks consecutive failures.

**Tech Stack:** Bash 4+, jq, Rust (clap, serde_json), bats-style bash test harness (existing pattern in `action/tests/run.sh`), Rust integration tests (existing pattern in `crates/cli/tests/init_tests.rs`).

**Spec:** `docs/superpowers/specs/2026-05-02-fallow-delivery-hook-design.md`

---

## File Structure

**Created:**
- `crates/cli/src/setup_hooks/fallow-stop-gate.sh` — main hook script (embedded)
- `crates/cli/src/hook_user.rs` — Rust install/uninstall logic for `init --hook-user`
- `crates/cli/tests/hook_user_tests.rs` — Rust integration tests for install/uninstall
- `crates/cli/tests/fallow_stop_gate/` — bash test directory
  - `run.sh` — runner (bats-style, mirrors `action/tests/run.sh`)
  - `mocks/fallow` — mock binary that echoes a canned JSON from `$FALLOW_MOCK_OUTPUT`
  - `fixtures/transcript-edits-ts.jsonl` — sample transcript with `.ts` edit
  - `fixtures/transcript-edits-rs.jsonl` — sample transcript with only `.rs` edit
  - `fixtures/audit-pass.json`, `fixtures/audit-warn.json`, `fixtures/audit-fail-1-introduced.json`, `fixtures/audit-fail-many.json`
  - `cases/01_disabled.bash` … `cases/13_dry_run.bash` (one case per Phase A task)
- `docs/hooks/user-scope-stop-hook.md` — user-facing doc page

**Modified:**
- `crates/cli/src/main.rs` — extend `Init` clap variant with `--hook-user` and `--uninstall` flags
- `crates/cli/src/init.rs` — when `--hook-user` is set, dispatch to `hook_user::install_or_uninstall()` and skip standard config scaffolding
- `crates/cli/src/lib.rs` — declare `pub mod hook_user;` so integration tests can call it
- `CHANGELOG.md` — entry under Unreleased

---

## Pre-flight

- [ ] **Check toolchain.** Run `cargo --version` and `bash --version` and `jq --version`. All required for development. If `cargo` missing, install rustup via `https://rustup.rs`. Existing repo conventions: signed commits via GPG (already configured this session — key `32E117ECAB18A4E3`).

- [ ] **Confirm starting branch.** Run `git status` — must be clean. Run `git rev-parse --abbrev-ref HEAD` — note current branch. If on `main`, create a feature branch:

```bash
git checkout -b feat/user-scope-stop-hook
```

- [ ] **Read related code.** Open these files for context (do NOT modify yet):
  - `crates/cli/src/setup_hooks.rs` — existing project-scope install pattern
  - `crates/cli/src/setup_hooks/fallow-gate.sh` — existing project-scope hook script (reference for structure, error handling, version-floor logic)
  - `crates/cli/src/setup_hooks/settings.json` — existing settings.json template
  - `crates/cli/src/init.rs` — existing init command logic
  - `action/tests/run.sh` — bash test harness pattern
  - `crates/cli/tests/init_tests.rs` — Rust integration test pattern

---

## Phase A — Bash hook script (TDD via bash harness)

### Task 1: Bash test harness scaffolding

**Files:**
- Create: `crates/cli/tests/fallow_stop_gate/run.sh`
- Create: `crates/cli/tests/fallow_stop_gate/mocks/fallow`
- Create: `crates/cli/tests/fallow_stop_gate/fixtures/transcript-edits-ts.jsonl`
- Create: `crates/cli/tests/fallow_stop_gate/fixtures/transcript-edits-rs.jsonl`
- Create: `crates/cli/tests/fallow_stop_gate/fixtures/audit-pass.json`
- Create: `crates/cli/tests/fallow_stop_gate/fixtures/audit-warn.json`
- Create: `crates/cli/tests/fallow_stop_gate/fixtures/audit-fail-1-introduced.json`
- Create: `crates/cli/tests/fallow_stop_gate/cases/00_smoke.bash`
- Create: `crates/cli/src/setup_hooks/fallow-stop-gate.sh` (placeholder)

- [ ] **Step 1: Write the failing smoke test.** Create the harness skeleton plus one trivial case that confirms the script exits 0 when `FALLOW_HOOK_DISABLED=1`.

`crates/cli/tests/fallow_stop_gate/run.sh`:

```bash
#!/usr/bin/env bash
# Test suite for fallow-stop-gate.sh (user-scope Stop hook).
# Run: bash crates/cli/tests/fallow_stop_gate/run.sh

set -o pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$DIR/../../src/setup_hooks/fallow-stop-gate.sh"
FIXTURES="$DIR/fixtures"
MOCKS="$DIR/mocks"
CASES="$DIR/cases"
PASSED=0
FAILED=0
ERRORS=()

pass() { PASSED=$((PASSED + 1)); echo "  ✓ $1"; }
fail() { FAILED=$((FAILED + 1)); ERRORS+=("$1: $2"); echo "  ✗ $1 — $2"; }

# Builds an isolated $CLAUDE_PROJECT_DIR per case so state files don't leak.
mk_project() {
  local proj
  proj="$(mktemp -d)"
  mkdir -p "$proj/.claude"
  echo "$proj"
}

# Standard Stop hook input JSON.
hook_input() {
  local session="${1:-sess-test}" transcript="${2:-/dev/null}" cwd="${3:-/tmp}" stop_active="${4:-false}"
  jq -n \
    --arg s "$session" \
    --arg t "$transcript" \
    --arg c "$cwd" \
    --argjson a "$stop_active" \
    '{session_id:$s, transcript_path:$t, cwd:$c, stop_hook_active:$a}'
}

assert_exit() {
  local got="$1" expected="$2" name="$3"
  if [ "$got" = "$expected" ]; then pass "$name"; else fail "$name" "exit $got, expected $expected"; fi
}
assert_contains() {
  local output="$1" expected="$2" name="$3"
  if [[ "$output" == *"$expected"* ]]; then pass "$name"; else fail "$name" "missing: $expected"; fi
}
assert_not_contains() {
  local output="$1" unexpected="$2" name="$3"
  if [[ "$output" != *"$unexpected"* ]]; then pass "$name"; else fail "$name" "should not contain: $unexpected"; fi
}
assert_empty() {
  local output="$1" name="$2"
  if [ -z "$output" ]; then pass "$name"; else fail "$name" "expected empty, got: $output"; fi
}
assert_state_count() {
  local proj="$1" expected="$2" name="$3"
  local actual
  actual=$(jq -r '.fail_count // 0' "$proj/.claude/.fallow-hook-state.json" 2>/dev/null || echo "missing")
  if [ "$actual" = "$expected" ]; then pass "$name"; else fail "$name" "fail_count=$actual, expected $expected"; fi
}

export -f mk_project hook_input
export -f pass fail assert_exit assert_contains assert_not_contains assert_empty assert_state_count
export PASSED FAILED
export SCRIPT FIXTURES MOCKS

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq required for tests" >&2
  exit 1
fi

echo "→ fallow-stop-gate test suite"
for case_file in "$CASES"/*.bash; do
  echo
  echo "[$(basename "$case_file")]"
  # shellcheck disable=SC1090
  source "$case_file"
done

echo
echo "─── Summary: $PASSED passed, $FAILED failed ───"
if [ "$FAILED" -ne 0 ]; then
  printf '%s\n' "${ERRORS[@]}" >&2
  exit 1
fi
```

`crates/cli/tests/fallow_stop_gate/mocks/fallow`:

```bash
#!/usr/bin/env bash
# Mock fallow binary. Behavior controlled by env vars.
# FALLOW_MOCK_VERSION  — version string for `fallow --version` (default 2.61.0)
# FALLOW_MOCK_OUTPUT   — file path; contents echoed for `fallow audit ...`
# FALLOW_MOCK_EXIT     — exit code for audit (default 0)
# FALLOW_MOCK_SLEEP    — sleep N seconds before audit returns
case "$1" in
  --version) echo "fallow ${FALLOW_MOCK_VERSION:-2.61.0}"; exit 0 ;;
  audit)
    [ -n "${FALLOW_MOCK_SLEEP:-}" ] && sleep "$FALLOW_MOCK_SLEEP"
    if [ -n "${FALLOW_MOCK_OUTPUT:-}" ] && [ -f "${FALLOW_MOCK_OUTPUT}" ]; then
      cat "${FALLOW_MOCK_OUTPUT}"
    else
      echo '{"verdict":"pass","summary":{}}'
    fi
    exit "${FALLOW_MOCK_EXIT:-0}" ;;
  *) echo "mock fallow: unknown command $1" >&2; exit 2 ;;
esac
```

`crates/cli/tests/fallow_stop_gate/fixtures/transcript-edits-ts.jsonl`:

```jsonl
{"type":"user","message":{"content":"add helper"}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"src/utils.ts","old_string":"x","new_string":"y"}}]}}
```

`crates/cli/tests/fallow_stop_gate/fixtures/transcript-edits-rs.jsonl`:

```jsonl
{"type":"user","message":{"content":"refactor rust"}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"src/lib.rs","old_string":"a","new_string":"b"}}]}}
```

`crates/cli/tests/fallow_stop_gate/fixtures/audit-pass.json`:

```json
{"schema_version":3,"command":"audit","verdict":"pass","changed_files_count":1,"summary":{"dead_code_issues":0,"complexity_findings":0,"duplication_clone_groups":0},"attribution":{"gate":"new-only","dead_code_introduced":0,"complexity_introduced":0,"duplication_introduced":0}}
```

`crates/cli/tests/fallow_stop_gate/fixtures/audit-warn.json`:

```json
{"schema_version":3,"command":"audit","verdict":"warn","changed_files_count":2,"summary":{"dead_code_issues":1,"complexity_findings":0,"duplication_clone_groups":0},"attribution":{"gate":"new-only","dead_code_introduced":0,"complexity_introduced":0,"duplication_introduced":0}}
```

`crates/cli/tests/fallow_stop_gate/fixtures/audit-fail-1-introduced.json`:

```json
{"schema_version":3,"command":"audit","verdict":"fail","changed_files_count":1,"summary":{"dead_code_issues":1,"complexity_findings":0,"duplication_clone_groups":0},"attribution":{"gate":"new-only","dead_code_introduced":1,"complexity_introduced":0,"duplication_introduced":0},"dead_code":{"unused_exports":[{"path":"src/utils.ts","line":42,"export_name":"helper","introduced":true,"actions":[{"type":"remove-export","auto_fixable":true,"description":"Remove the unused export"}]}]}}
```

`crates/cli/tests/fallow_stop_gate/cases/00_smoke.bash`:

```bash
# 00 — smoke: script exists, runs, FALLOW_HOOK_DISABLED short-circuits
proj=$(mk_project)

out=$(FALLOW_HOOK_DISABLED=1 bash "$SCRIPT" <<<"$(hook_input sess1 /dev/null "$proj" false)" 2>&1)
rc=$?
assert_exit "$rc" "0" "00.disabled-exits-zero"
assert_empty "$out" "00.disabled-no-output"

rm -rf "$proj"
```

`crates/cli/src/setup_hooks/fallow-stop-gate.sh` (placeholder):

```bash
#!/usr/bin/env bash
# Placeholder — implementation lands in Task 2.
exit 0
```

- [ ] **Step 2: Run test to verify harness works (placeholder script trivially passes).**

```bash
chmod +x crates/cli/tests/fallow_stop_gate/mocks/fallow
chmod +x crates/cli/src/setup_hooks/fallow-stop-gate.sh
bash crates/cli/tests/fallow_stop_gate/run.sh
```

Expected: 2 passed, 0 failed.

- [ ] **Step 3: Commit harness scaffolding.**

```bash
git add crates/cli/tests/fallow_stop_gate crates/cli/src/setup_hooks/fallow-stop-gate.sh
git commit -S -m "test(cli): add fallow-stop-gate bash harness scaffolding"
```

---

### Task 2: Skeleton script + DISABLED env + input parsing

**Files:**
- Modify: `crates/cli/src/setup_hooks/fallow-stop-gate.sh` (replace placeholder)
- Modify: `crates/cli/tests/fallow_stop_gate/cases/00_smoke.bash` (extend)
- Create: `crates/cli/tests/fallow_stop_gate/cases/01_input.bash`

- [ ] **Step 1: Write failing tests for input parsing + stop_hook_active short-circuit.**

`crates/cli/tests/fallow_stop_gate/cases/01_input.bash`:

```bash
# 01 — input parsing: stop_hook_active=true short-circuits; missing fields don't crash
proj=$(mk_project)

out=$(bash "$SCRIPT" <<<"$(hook_input sess1 /dev/null "$proj" true)" 2>&1)
rc=$?
assert_exit "$rc" "0" "01.stop-active-exits-zero"

out=$(bash "$SCRIPT" <<<'{}' 2>&1)
rc=$?
assert_exit "$rc" "0" "01.empty-input-fail-open"

rm -rf "$proj"
```

- [ ] **Step 2: Run tests to verify they fail.**

```bash
bash crates/cli/tests/fallow_stop_gate/run.sh
```

Expected: `01.stop-active-exits-zero` etc. pass trivially because placeholder always exits 0. To produce a real failure for TDD: skip ahead — placeholder already returns 0 for these cases. Treat Task 2 as foundation: ensure the eventual real script preserves these properties. Move to implementation directly.

- [ ] **Step 3: Implement skeleton.** Replace `crates/cli/src/setup_hooks/fallow-stop-gate.sh` with:

```bash
#!/usr/bin/env bash
set -euo pipefail

# Generated by fallow init --hook-user.
# Installer version: @@FALLOW_INSTALLER_VERSION@@
# Stop hook for Claude Code that runs `fallow audit` after turns
# that edited TS/JS files. Fail-open by design.

if [ "${FALLOW_HOOK_DISABLED:-}" = "1" ]; then exit 0; fi

if ! command -v jq >/dev/null 2>&1; then
  echo "fallow-stop-gate: jq not on PATH, skipping audit." >&2
  exit 0
fi

INPUT="$(cat 2>/dev/null || true)"
if [ -z "$INPUT" ]; then exit 0; fi

SESSION_ID="$(jq -r '.session_id // empty' <<<"$INPUT" 2>/dev/null || true)"
TRANSCRIPT_PATH="$(jq -r '.transcript_path // empty' <<<"$INPUT" 2>/dev/null || true)"
HOOK_CWD="$(jq -r '.cwd // empty' <<<"$INPUT" 2>/dev/null || true)"
STOP_ACTIVE="$(jq -r '.stop_hook_active // false' <<<"$INPUT" 2>/dev/null || echo false)"

if [ "$STOP_ACTIVE" = "true" ]; then exit 0; fi

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$HOOK_CWD}"
if [ -z "$PROJECT_DIR" ]; then exit 0; fi

# Subsequent phases land below; for now exit 0 (fail-open default).
exit 0
```

- [ ] **Step 4: Run tests to verify they pass.**

```bash
bash crates/cli/tests/fallow_stop_gate/run.sh
```

Expected: 4 passed, 0 failed.

- [ ] **Step 5: Commit.**

```bash
git add crates/cli/src/setup_hooks/fallow-stop-gate.sh crates/cli/tests/fallow_stop_gate/cases/01_input.bash
git commit -S -m "feat(hook): skeleton script with disabled env + input parsing"
```

---

### Task 3: Transcript heuristic (TS/JS edit detection)

**Files:**
- Modify: `crates/cli/src/setup_hooks/fallow-stop-gate.sh`
- Create: `crates/cli/tests/fallow_stop_gate/cases/02_heuristic.bash`

- [ ] **Step 1: Write failing tests for heuristic.**

`crates/cli/tests/fallow_stop_gate/cases/02_heuristic.bash`:

```bash
# 02 — heuristic: only TS/JS edits trigger; rust-only edits skip
proj=$(mk_project)

# TS edit transcript: should NOT exit 0 prematurely (we'll later detect lack of project)
# But with no package.json, project detection (Task 4) returns 0. So for now we test by
# capturing DEBUG output to confirm heuristic decision.
out=$(FALLOW_HOOK_DEBUG=1 bash "$SCRIPT" \
  <<<"$(hook_input sess1 "$FIXTURES/transcript-edits-ts.jsonl" "$proj" false)" 2>&1)
rc=$?
assert_exit "$rc" "0" "02.ts-edit-still-zero-no-project"
assert_contains "$out" "ts/js edits detected" "02.ts-edit-detected"

out=$(FALLOW_HOOK_DEBUG=1 bash "$SCRIPT" \
  <<<"$(hook_input sess1 "$FIXTURES/transcript-edits-rs.jsonl" "$proj" false)" 2>&1)
rc=$?
assert_exit "$rc" "0" "02.rs-edit-zero"
assert_not_contains "$out" "ts/js edits detected" "02.rs-edit-not-detected"

rm -rf "$proj"
```

- [ ] **Step 2: Run tests to verify they fail.**

```bash
bash crates/cli/tests/fallow_stop_gate/run.sh
```

Expected: `02.ts-edit-detected` FAILS (no DEBUG output yet).

- [ ] **Step 3: Implement heuristic.** Insert into `fallow-stop-gate.sh` immediately before the final `exit 0`:

```bash
debug() { [ "${FALLOW_HOOK_DEBUG:-}" = "1" ] && echo "fallow-stop-gate: $*" >&2; return 0; }

if [ -z "$TRANSCRIPT_PATH" ] || [ ! -r "$TRANSCRIPT_PATH" ]; then
  debug "transcript missing or unreadable, skipping heuristic"
else
  TS_EXTS_RE='\.(ts|tsx|js|jsx|mjs|cjs|mts|cts|svelte|vue|astro)$'
  EXCLUDE_RE='^(node_modules/|\.git/|dist/|build/|target/|\.next/|\.nuxt/|out/|coverage/)'
  CHANGED_PATHS="$(tail -n 500 "$TRANSCRIPT_PATH" 2>/dev/null \
    | jq -r 'select(.type=="assistant")
             | .message.content[]?
             | select(.type=="tool_use")
             | select(.name=="Edit" or .name=="Write" or .name=="MultiEdit" or .name=="NotebookEdit")
             | (.input.file_path // .input.notebook_path // empty)' 2>/dev/null \
    | grep -Ei "$TS_EXTS_RE" \
    | grep -Ev "$EXCLUDE_RE" \
    | sort -u || true)"

  if [ -z "$CHANGED_PATHS" ]; then
    debug "no ts/js edits in turn, exiting"
    exit 0
  fi
  debug "ts/js edits detected: $(echo "$CHANGED_PATHS" | wc -l | tr -d ' ') file(s)"
fi
```

- [ ] **Step 4: Run tests to verify they pass.**

```bash
bash crates/cli/tests/fallow_stop_gate/run.sh
```

Expected: all cases pass (heuristic detects TS, ignores RS).

- [ ] **Step 5: Commit.**

```bash
git add crates/cli/src/setup_hooks/fallow-stop-gate.sh crates/cli/tests/fallow_stop_gate/cases/02_heuristic.bash
git commit -S -m "feat(hook): transcript heuristic for ts/js edit detection"
```

---

### Task 4: Project detection (package.json + .fallowrc + hook.disabled)

**Files:**
- Modify: `crates/cli/src/setup_hooks/fallow-stop-gate.sh`
- Create: `crates/cli/tests/fallow_stop_gate/cases/03_project.bash`

- [ ] **Step 1: Write failing tests.**

`crates/cli/tests/fallow_stop_gate/cases/03_project.bash`:

```bash
# 03 — project detection: package.json OR .fallowrc, .fallowrc.hook.disabled honored
proj=$(mk_project)

# No marker → exit 0 silent
out=$(FALLOW_HOOK_DEBUG=1 bash "$SCRIPT" \
  <<<"$(hook_input sess1 "$FIXTURES/transcript-edits-ts.jsonl" "$proj" false)" 2>&1)
rc=$?
assert_exit "$rc" "0" "03.no-marker-zero"
assert_contains "$out" "no project marker" "03.no-marker-debug"

# Add package.json → progresses past detection
echo '{}' > "$proj/package.json"
out=$(FALLOW_HOOK_DEBUG=1 bash "$SCRIPT" \
  <<<"$(hook_input sess1 "$FIXTURES/transcript-edits-ts.jsonl" "$proj" false)" 2>&1)
rc=$?
assert_exit "$rc" "0" "03.pkg-progresses"
assert_contains "$out" "project marker found" "03.pkg-debug"

# .fallowrc with hook.disabled=true short-circuits
rm "$proj/package.json"
echo '{"hook":{"disabled":true}}' > "$proj/.fallowrc.json"
out=$(FALLOW_HOOK_DEBUG=1 bash "$SCRIPT" \
  <<<"$(hook_input sess1 "$FIXTURES/transcript-edits-ts.jsonl" "$proj" false)" 2>&1)
rc=$?
assert_exit "$rc" "0" "03.disabled-rc-zero"
assert_contains "$out" "disabled by .fallowrc" "03.disabled-rc-debug"

rm -rf "$proj"
```

- [ ] **Step 2: Run tests to verify they fail.**

```bash
bash crates/cli/tests/fallow_stop_gate/run.sh
```

Expected: `03.no-marker-debug`, `03.pkg-debug`, `03.disabled-rc-debug` FAIL (no detection logic yet).

- [ ] **Step 3: Implement project detection.** Append to `fallow-stop-gate.sh` before final `exit 0`:

```bash
RC_DISABLED=0
RC_PATH=""
for rc in .fallowrc.json .fallowrc.jsonc fallow.toml .fallow.toml; do
  if [ -f "$PROJECT_DIR/$rc" ]; then RC_PATH="$PROJECT_DIR/$rc"; break; fi
done

if [ -n "$RC_PATH" ] && [[ "$RC_PATH" == *.json* ]]; then
  RC_DISABLED="$(jq -r '.hook.disabled // false' "$RC_PATH" 2>/dev/null || echo false)"
  if [ "$RC_DISABLED" = "true" ]; then
    debug "disabled by .fallowrc hook.disabled=true"
    exit 0
  fi
fi

if [ -z "$RC_PATH" ] && [ ! -f "$PROJECT_DIR/package.json" ]; then
  debug "no project marker (package.json/.fallowrc absent), skipping"
  exit 0
fi
debug "project marker found at $PROJECT_DIR"
```

- [ ] **Step 4: Run tests to verify they pass.**

```bash
bash crates/cli/tests/fallow_stop_gate/run.sh
```

Expected: all 03.* cases pass.

- [ ] **Step 5: Commit.**

```bash
git add crates/cli/src/setup_hooks/fallow-stop-gate.sh crates/cli/tests/fallow_stop_gate/cases/03_project.bash
git commit -S -m "feat(hook): project detection via package.json or .fallowrc"
```

---

### Task 5: Binary location + version floor

**Files:**
- Modify: `crates/cli/src/setup_hooks/fallow-stop-gate.sh`
- Create: `crates/cli/tests/fallow_stop_gate/cases/04_binary.bash`

- [ ] **Step 1: Write failing tests.**

`crates/cli/tests/fallow_stop_gate/cases/04_binary.bash`:

```bash
# 04 — binary location: PATH wins, missing binary fails open, version floor enforced
proj=$(mk_project)
echo '{}' > "$proj/package.json"

# No fallow on PATH → exit 0 silent (fail open) with stderr note
out=$(PATH=/usr/bin:/bin FALLOW_HOOK_DEBUG=1 bash "$SCRIPT" \
  <<<"$(hook_input sess1 "$FIXTURES/transcript-edits-ts.jsonl" "$proj" false)" 2>&1)
rc=$?
assert_exit "$rc" "0" "04.no-binary-zero"
assert_contains "$out" "fallow binary not found" "04.no-binary-msg"

# Mock fallow on PATH → progresses; version below floor → exit 2
out=$(PATH="$MOCKS:/usr/bin:/bin" FALLOW_MOCK_VERSION=2.10.0 FALLOW_HOOK_DEBUG=1 bash "$SCRIPT" \
  <<<"$(hook_input sess1 "$FIXTURES/transcript-edits-ts.jsonl" "$proj" false)" 2>&1)
rc=$?
assert_exit "$rc" "2" "04.below-floor-blocks"
assert_contains "$out" "below required" "04.below-floor-msg"

# Above floor → no early exit (will fail later for other reasons since audit not wired)
out=$(PATH="$MOCKS:/usr/bin:/bin" FALLOW_MOCK_VERSION=2.61.0 FALLOW_HOOK_DEBUG=1 bash "$SCRIPT" \
  <<<"$(hook_input sess1 "$FIXTURES/transcript-edits-ts.jsonl" "$proj" false)" 2>&1)
rc=$?
assert_exit "$rc" "0" "04.above-floor-progresses"

rm -rf "$proj"
```

- [ ] **Step 2: Run tests to verify they fail.**

```bash
bash crates/cli/tests/fallow_stop_gate/run.sh
```

Expected: `04.no-binary-msg` and `04.below-floor-blocks` FAIL.

- [ ] **Step 3: Implement.** Append to `fallow-stop-gate.sh` before final `exit 0`:

```bash
if command -v fallow >/dev/null 2>&1; then
  RUNNER=(fallow)
  BIN_DESC="$(command -v fallow)"
elif command -v npx >/dev/null 2>&1 && VER_PROBE="$(npx --no-install fallow --version 2>/dev/null || true)" && [[ "$VER_PROBE" == fallow* ]]; then
  RUNNER=(npx --no-install fallow)
  BIN_DESC="npx --no-install fallow"
else
  echo "fallow-stop-gate: fallow binary not found (tried PATH and npx --no-install), skipping audit." >&2
  exit 0
fi

VERSION_RAW="$("${RUNNER[@]}" --version 2>/dev/null || true)"
VERSION="${VERSION_RAW#fallow }"
VERSION="${VERSION%% *}"

MIN_VERSION="${FALLOW_HOOK_MIN_VERSION-2.61.0}"
if [ -n "$MIN_VERSION" ] && [ -n "$VERSION" ]; then
  LOWER="$(printf '%s\n%s\n' "$MIN_VERSION" "$VERSION" | sort -V | head -n1)"
  if [ "$LOWER" != "$MIN_VERSION" ]; then
    {
      echo "fallow-stop-gate: blocked: $BIN_DESC is fallow $VERSION, below required $MIN_VERSION."
      echo "fallow-stop-gate: upgrade (npm install -g fallow@latest or cargo install fallow-cli),"
      echo "fallow-stop-gate: or set FALLOW_HOOK_MIN_VERSION= to disable."
    } >&2
    exit 2
  fi
fi
debug "binary OK: $BIN_DESC ($VERSION)"
```

- [ ] **Step 4: Run tests to verify they pass.**

```bash
bash crates/cli/tests/fallow_stop_gate/run.sh
```

Expected: all 04.* cases pass.

- [ ] **Step 5: Commit.**

```bash
git add crates/cli/src/setup_hooks/fallow-stop-gate.sh crates/cli/tests/fallow_stop_gate/cases/04_binary.bash
git commit -S -m "feat(hook): binary location with npx fallback and version floor"
```

---

### Task 6: Diff size skip

**Files:**
- Modify: `crates/cli/src/setup_hooks/fallow-stop-gate.sh`
- Create: `crates/cli/tests/fallow_stop_gate/cases/05_diff_size.bash`

- [ ] **Step 1: Write failing test.**

`crates/cli/tests/fallow_stop_gate/cases/05_diff_size.bash`:

```bash
# 05 — diff size skip: > FALLOW_HOOK_MAX_DIFF skips audit
proj=$(mk_project)
echo '{}' > "$proj/package.json"
( cd "$proj" && git init -q && git commit --allow-empty -q -m init )

# Stage 600 fake files to exceed default 500 threshold
mkdir "$proj/many"
for i in $(seq 1 600); do touch "$proj/many/f$i.ts"; done
( cd "$proj" && git add -A )

out=$(PATH="$MOCKS:/usr/bin:/bin" FALLOW_HOOK_DEBUG=1 bash "$SCRIPT" \
  <<<"$(hook_input sess1 "$FIXTURES/transcript-edits-ts.jsonl" "$proj" false)" 2>&1)
rc=$?
assert_exit "$rc" "0" "05.huge-diff-zero"
assert_contains "$out" "diff exceeds" "05.huge-diff-msg"

# Override threshold to 1000 → should not skip on size
out=$(PATH="$MOCKS:/usr/bin:/bin" FALLOW_HOOK_MAX_DIFF=1000 FALLOW_HOOK_DEBUG=1 bash "$SCRIPT" \
  <<<"$(hook_input sess1 "$FIXTURES/transcript-edits-ts.jsonl" "$proj" false)" 2>&1)
rc=$?
assert_exit "$rc" "0" "05.large-but-under-threshold-zero"
assert_not_contains "$out" "diff exceeds" "05.large-but-under-threshold-no-msg"

rm -rf "$proj"
```

- [ ] **Step 2: Run tests to verify they fail.** (`05.huge-diff-msg` FAILS — no diff check yet.)

```bash
bash crates/cli/tests/fallow_stop_gate/run.sh
```

- [ ] **Step 3: Implement.** Append before final `exit 0`:

```bash
MAX_DIFF="${FALLOW_HOOK_MAX_DIFF-500}"
if command -v git >/dev/null 2>&1 && [ -d "$PROJECT_DIR/.git" ]; then
  DIFF_COUNT="$(git -C "$PROJECT_DIR" diff --name-only HEAD 2>/dev/null | wc -l | tr -d ' ' || echo 0)"
  STAGED_COUNT="$(git -C "$PROJECT_DIR" diff --name-only --cached 2>/dev/null | wc -l | tr -d ' ' || echo 0)"
  TOTAL_COUNT=$((DIFF_COUNT + STAGED_COUNT))
  if [ "$MAX_DIFF" != "0" ] && [ "$TOTAL_COUNT" -gt "$MAX_DIFF" ]; then
    echo "fallow-stop-gate: diff exceeds $MAX_DIFF files ($TOTAL_COUNT changed), skipping audit." >&2
    exit 0
  fi
  debug "diff size: $TOTAL_COUNT files (threshold $MAX_DIFF)"
fi
```

- [ ] **Step 4: Run tests.**

```bash
bash crates/cli/tests/fallow_stop_gate/run.sh
```

Expected: all 05.* cases pass.

- [ ] **Step 5: Commit.**

```bash
git add crates/cli/src/setup_hooks/fallow-stop-gate.sh crates/cli/tests/fallow_stop_gate/cases/05_diff_size.bash
git commit -S -m "feat(hook): skip audit when diff exceeds FALLOW_HOOK_MAX_DIFF"
```

---

### Task 7: Audit invocation + verdict parsing + state file load

**Files:**
- Modify: `crates/cli/src/setup_hooks/fallow-stop-gate.sh`
- Create: `crates/cli/tests/fallow_stop_gate/cases/06_audit_pass_warn.bash`

- [ ] **Step 1: Write failing tests for pass/warn paths + state init.**

`crates/cli/tests/fallow_stop_gate/cases/06_audit_pass_warn.bash`:

```bash
# 06 — audit pass/warn paths + state file initialization
proj=$(mk_project)
echo '{}' > "$proj/package.json"
( cd "$proj" && git init -q && git commit --allow-empty -q -m init )

# Pass verdict → exit 0 silent + state.fail_count=0
out=$(PATH="$MOCKS:/usr/bin:/bin" FALLOW_MOCK_OUTPUT="$FIXTURES/audit-pass.json" \
  bash "$SCRIPT" <<<"$(hook_input sess1 "$FIXTURES/transcript-edits-ts.jsonl" "$proj" false)" 2>&1)
rc=$?
assert_exit "$rc" "0" "06.pass-zero"
assert_empty "$out" "06.pass-no-stderr"
assert_state_count "$proj" "0" "06.pass-state-zero"

# Warn verdict → exit 0 + stderr note + state.fail_count=0
out=$(PATH="$MOCKS:/usr/bin:/bin" FALLOW_MOCK_OUTPUT="$FIXTURES/audit-warn.json" \
  bash "$SCRIPT" <<<"$(hook_input sess1 "$FIXTURES/transcript-edits-ts.jsonl" "$proj" false)" 2>&1)
rc=$?
assert_exit "$rc" "0" "06.warn-zero"
assert_contains "$out" "warn findings" "06.warn-stderr-note"
assert_state_count "$proj" "0" "06.warn-state-zero"

rm -rf "$proj"
```

- [ ] **Step 2: Run tests to verify failure.** Multiple `06.*` cases FAIL.

```bash
bash crates/cli/tests/fallow_stop_gate/run.sh
```

- [ ] **Step 3: Implement audit + verdict parsing + state file load.** Append before final `exit 0`:

```bash
TIMEOUT="${FALLOW_HOOK_TIMEOUT-120}"
STATE_DIR="${FALLOW_HOOK_STATE_DIR-$PROJECT_DIR/.claude}"
STATE_FILE="$STATE_DIR/.fallow-hook-state.json"
mkdir -p "$STATE_DIR" 2>/dev/null || true

PREV_STATE='{}'
if [ -f "$STATE_FILE" ]; then
  if jq -e '.' "$STATE_FILE" >/dev/null 2>&1; then
    PREV_STATE="$(cat "$STATE_FILE")"
  else
    debug "state file corrupt, resetting"
  fi
fi

PREV_SESSION="$(jq -r '.session_id // empty' <<<"$PREV_STATE" 2>/dev/null || true)"
PREV_COUNT="$(jq -r '.fail_count // 0' <<<"$PREV_STATE" 2>/dev/null || echo 0)"
PREV_TS="$(jq -r '.last_ts // 0' <<<"$PREV_STATE" 2>/dev/null || echo 0)"
PREV_LOCKED="$(jq -r '.advisory_locked // false' <<<"$PREV_STATE" 2>/dev/null || echo false)"

NOW="$(date +%s)"
TTL="${FALLOW_HOOK_LOOP_TTL_SECS-1800}"
LOOP_LIMIT="${FALLOW_HOOK_LOOP_LIMIT-3}"

TMP_JSON="$(mktemp)"
TMP_ERR="$(mktemp)"
cleanup() { rm -f "$TMP_JSON" "$TMP_ERR"; }
trap cleanup EXIT

if command -v timeout >/dev/null 2>&1; then
  TIMEOUT_CMD=(timeout "${TIMEOUT}s")
else
  TIMEOUT_CMD=()
fi

if "${TIMEOUT_CMD[@]}" "${RUNNER[@]}" audit --format json --quiet --explain >"$TMP_JSON" 2>"$TMP_ERR"; then
  AUDIT_STATUS=0
else
  AUDIT_STATUS=$?
fi

if [ "$AUDIT_STATUS" -eq 124 ]; then
  echo "fallow-stop-gate: fallow audit timed out after ${TIMEOUT}s, skipping." >&2
  exit 0
fi

VERDICT="$(jq -r '.verdict // empty' <"$TMP_JSON" 2>/dev/null || true)"
if [ -z "$VERDICT" ]; then
  echo "fallow-stop-gate: fallow audit produced no parseable JSON, skipping." >&2
  exit 0
fi

# Atomic state writer
write_state() {
  local count="$1" verdict="$2" locked="$3"
  local tmp
  tmp="$(mktemp "$STATE_DIR/.state.XXXXXX")"
  jq -n \
    --arg s "$SESSION_ID" \
    --argjson c "$count" \
    --arg v "$verdict" \
    --argjson t "$NOW" \
    --argjson l "$locked" \
    '{session_id:$s, fail_count:$c, last_verdict:$v, last_ts:$t, advisory_locked:$l}' \
    > "$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$STATE_FILE"
}

case "$VERDICT" in
  pass)
    write_state 0 pass false
    debug "verdict=pass, state reset"
    exit 0
    ;;
  warn)
    WARN_TOTAL="$(jq -r '.summary.dead_code_issues + .summary.complexity_findings + .summary.duplication_clone_groups' <"$TMP_JSON" 2>/dev/null || echo "?")"
    echo "⚠ fallow audit: $WARN_TOTAL warn findings — considere /review antes de fechar entrega." >&2
    write_state 0 warn false
    exit 0
    ;;
esac
```

- [ ] **Step 4: Run tests.**

```bash
bash crates/cli/tests/fallow_stop_gate/run.sh
```

Expected: all 06.* cases pass.

- [ ] **Step 5: Commit.**

```bash
git add crates/cli/src/setup_hooks/fallow-stop-gate.sh crates/cli/tests/fallow_stop_gate/cases/06_audit_pass_warn.bash
git commit -S -m "feat(hook): audit invocation, pass/warn verdict handling, state file"
```

---

### Task 8: Fail verdict + reason builder + 3-strike escalation

**Files:**
- Modify: `crates/cli/src/setup_hooks/fallow-stop-gate.sh`
- Create: `crates/cli/tests/fallow_stop_gate/cases/07_fail_basic.bash`
- Create: `crates/cli/tests/fallow_stop_gate/cases/08_fail_loop.bash`

- [ ] **Step 1: Write failing tests for fail handling and 3-strike.**

`crates/cli/tests/fallow_stop_gate/cases/07_fail_basic.bash`:

```bash
# 07 — fail (count<3) emits decision:block JSON with reason
proj=$(mk_project)
echo '{}' > "$proj/package.json"
( cd "$proj" && git init -q && git commit --allow-empty -q -m init )

out=$(PATH="$MOCKS:/usr/bin:/bin" FALLOW_MOCK_OUTPUT="$FIXTURES/audit-fail-1-introduced.json" \
  FALLOW_MOCK_EXIT=2 \
  bash "$SCRIPT" <<<"$(hook_input sess1 "$FIXTURES/transcript-edits-ts.jsonl" "$proj" false)")
rc=$?
assert_exit "$rc" "0" "07.fail-exit-zero-with-json"

# stdout must be valid JSON with decision=block
decision=$(jq -r '.decision // empty' <<<"$out" 2>/dev/null || true)
reason=$(jq -r '.reason // empty' <<<"$out" 2>/dev/null || true)
[ "$decision" = "block" ] && pass "07.fail-decision-block" || fail "07.fail-decision-block" "got: $out"
[[ "$reason" == *"verdict=fail"* ]] && pass "07.fail-reason-verdict" || fail "07.fail-reason-verdict" ""
[[ "$reason" == *"helper"* ]] && pass "07.fail-reason-issue" || fail "07.fail-reason-issue" ""
[[ "$reason" == *"tentativa 1 de 3"* ]] && pass "07.fail-attempt-counter" || fail "07.fail-attempt-counter" ""
assert_state_count "$proj" "1" "07.fail-state-count"

rm -rf "$proj"
```

`crates/cli/tests/fallow_stop_gate/cases/08_fail_loop.bash`:

```bash
# 08 — 3-strike escalation: 3rd consecutive fail in same session → advisory_locked
proj=$(mk_project)
echo '{}' > "$proj/package.json"
( cd "$proj" && git init -q && git commit --allow-empty -q -m init )

run_fail() {
  PATH="$MOCKS:/usr/bin:/bin" FALLOW_MOCK_OUTPUT="$FIXTURES/audit-fail-1-introduced.json" \
    FALLOW_MOCK_EXIT=2 \
    bash "$SCRIPT" <<<"$(hook_input sess-loop "$FIXTURES/transcript-edits-ts.jsonl" "$proj" false)"
}

out1=$(run_fail); rc1=$?
out2=$(run_fail); rc2=$?
out3=$(run_fail); rc3=$?

assert_exit "$rc1" "0" "08.r1-zero"
assert_exit "$rc2" "0" "08.r2-zero"
assert_exit "$rc3" "0" "08.r3-zero"

reason1=$(jq -r '.reason' <<<"$out1")
reason2=$(jq -r '.reason' <<<"$out2")
reason3=$(jq -r '.reason' <<<"$out3")

[[ "$reason1" == *"tentativa 1 de 3"* ]] && pass "08.r1-attempt" || fail "08.r1-attempt" ""
[[ "$reason2" == *"tentativa 2 de 3"* ]] && pass "08.r2-attempt" || fail "08.r2-attempt" ""
[[ "$reason3" == *"3× consecutivas"* ]] && pass "08.r3-advisory" || fail "08.r3-advisory" "$reason3"
[[ "$reason3" == *"PARE"* || "$reason3" == *"pare"* ]] && pass "08.r3-stop-instruction" || fail "08.r3-stop-instruction" ""

# Pass after 3rd fail resets count and unlocks advisory
PATH="$MOCKS:/usr/bin:/bin" FALLOW_MOCK_OUTPUT="$FIXTURES/audit-pass.json" FALLOW_MOCK_EXIT=0 \
  bash "$SCRIPT" <<<"$(hook_input sess-loop "$FIXTURES/transcript-edits-ts.jsonl" "$proj" false)" >/dev/null
assert_state_count "$proj" "0" "08.pass-resets-count"
locked=$(jq -r '.advisory_locked' "$proj/.claude/.fallow-hook-state.json")
[ "$locked" = "false" ] && pass "08.pass-unlocks" || fail "08.pass-unlocks" "locked=$locked"

rm -rf "$proj"
```

- [ ] **Step 2: Run tests to verify they fail.** All 07.*/08.* FAIL — no fail logic yet.

```bash
bash crates/cli/tests/fallow_stop_gate/run.sh
```

- [ ] **Step 3: Implement fail handling, reason builder, escalation.** Append after the `case "$VERDICT"` block (the `pass`/`warn` branches above) — keep them, then add:

```bash
# Fall-through: VERDICT == fail
SAME_SESSION="false"
[ "$PREV_SESSION" = "$SESSION_ID" ] && SAME_SESSION="true"
TS_FRESH="false"
[ $((NOW - PREV_TS)) -lt "$TTL" ] && TS_FRESH="true"

if [ "$SAME_SESSION" = "true" ] && [ "$TS_FRESH" = "true" ]; then
  NEW_COUNT=$((PREV_COUNT + 1))
else
  NEW_COUNT=1
fi

build_reason_normal() {
  local count="$1" limit="$2"
  local changed_files dc_in cx_in du_in
  changed_files="$(jq -r '.changed_files_count // 0' <"$TMP_JSON")"
  dc_in="$(jq -r '.attribution.dead_code_introduced // 0' <"$TMP_JSON")"
  cx_in="$(jq -r '.attribution.complexity_introduced // 0' <"$TMP_JSON")"
  du_in="$(jq -r '.attribution.duplication_introduced // 0' <"$TMP_JSON")"

  local issues
  issues="$(jq -r '
    [ (.dead_code.unused_exports // [])
      + (.dead_code.unused_files // [])
      + (.dead_code.unused_dependencies // [])
      + (.health.findings // [])
      + (.duplication.clone_groups // [])
    | .[]
    | select(.introduced == true)
    | "  • " +
        (.path // .file // "(?)") +
        ":" +
        ((.line // .start_line // 0) | tostring) +
        " " +
        (.export_name // .rule // .kind // .code // "issue") +
        " [actions: " +
        ((.actions // [] | map(.type) | join(", "))) +
        "]"
    ] | .[0:10] | join("\n")
  ' <"$TMP_JSON" 2>/dev/null || true)"
  local total_introduced=$((dc_in + cx_in + du_in))
  local extra=""
  if [ "$total_introduced" -gt 10 ]; then
    extra=$'\n  +'"$((total_introduced - 10))"' more'
  fi

  cat <<EOF
fallow audit verdict=fail (tentativa $count de $limit antes de bloquear consultoria)
changed_files=$changed_files — introduced this turn:
  dead_code: $dc_in
  complexity: $cx_in
  duplication: $du_in

Top issues introduced:
${issues:-  (no introduced issues parsed; rerun with --explain for actions[])}$extra

Full details + actions: re-run \`fallow audit --explain --format json\` locally.
EOF
}

build_reason_advisory() {
  local total_introduced
  total_introduced="$(jq -r '(.attribution.dead_code_introduced // 0) + (.attribution.complexity_introduced // 0) + (.attribution.duplication_introduced // 0)' <"$TMP_JSON")"
  local fp
  fp="$(jq -r '
    [ (.dead_code.unused_exports // [])[]?
      | select(.introduced == true)
      | (.path // "?") + ":" + ((.line // 0) | tostring) + ":" + (.export_name // "?")
    ] | sort | join("|")
  ' <"$TMP_JSON" 2>/dev/null | shasum | cut -c1-12)"

  cat <<EOF
🛑 fallow audit falhou 3× consecutivas no mesmo session.

Verdict atual: fail (introduced=$total_introduced).
Estagnação detectada — pare de tentar corrigir.

INSTRUÇÃO PARA CLAUDE: NÃO tente outro fix. Apresente os findings ao
usuário, explique tentativas até agora, peça orientação antes de
continuar editando código.

Last fingerprint: $fp
Reset automático em: novo \`pass\`/\`warn\` no audit, OU 30min idle, OU sessão Claude nova.
EOF
}

if [ "$NEW_COUNT" -ge "$LOOP_LIMIT" ] || [ "$PREV_LOCKED" = "true" ]; then
  REASON="$(build_reason_advisory)"
  write_state "$NEW_COUNT" fail true
else
  REASON="$(build_reason_normal "$NEW_COUNT" "$LOOP_LIMIT")"
  write_state "$NEW_COUNT" fail false
fi

jq -n --arg r "$REASON" '{decision:"block", reason:$r}'
exit 0
```

- [ ] **Step 4: Run tests.**

```bash
bash crates/cli/tests/fallow_stop_gate/run.sh
```

Expected: all 07.*/08.* cases pass.

- [ ] **Step 5: Commit.**

```bash
git add crates/cli/src/setup_hooks/fallow-stop-gate.sh \
        crates/cli/tests/fallow_stop_gate/cases/07_fail_basic.bash \
        crates/cli/tests/fallow_stop_gate/cases/08_fail_loop.bash
git commit -S -m "feat(hook): fail verdict, reason builder, 3-strike advisory escalation"
```

---

### Task 9: Session/TTL reset + DRY_RUN

**Files:**
- Modify: `crates/cli/src/setup_hooks/fallow-stop-gate.sh`
- Create: `crates/cli/tests/fallow_stop_gate/cases/09_reset.bash`
- Create: `crates/cli/tests/fallow_stop_gate/cases/10_dry_run.bash`

- [ ] **Step 1: Write failing tests.**

`crates/cli/tests/fallow_stop_gate/cases/09_reset.bash`:

```bash
# 09 — count resets on new session_id and on TTL expiry
proj=$(mk_project)
echo '{}' > "$proj/package.json"
( cd "$proj" && git init -q && git commit --allow-empty -q -m init )

# Two failures in sess-A
PATH="$MOCKS:/usr/bin:/bin" FALLOW_MOCK_OUTPUT="$FIXTURES/audit-fail-1-introduced.json" FALLOW_MOCK_EXIT=2 \
  bash "$SCRIPT" <<<"$(hook_input sess-A "$FIXTURES/transcript-edits-ts.jsonl" "$proj" false)" >/dev/null
PATH="$MOCKS:/usr/bin:/bin" FALLOW_MOCK_OUTPUT="$FIXTURES/audit-fail-1-introduced.json" FALLOW_MOCK_EXIT=2 \
  bash "$SCRIPT" <<<"$(hook_input sess-A "$FIXTURES/transcript-edits-ts.jsonl" "$proj" false)" >/dev/null
assert_state_count "$proj" "2" "09.same-session-count2"

# Switch to sess-B → count must reset to 1
PATH="$MOCKS:/usr/bin:/bin" FALLOW_MOCK_OUTPUT="$FIXTURES/audit-fail-1-introduced.json" FALLOW_MOCK_EXIT=2 \
  bash "$SCRIPT" <<<"$(hook_input sess-B "$FIXTURES/transcript-edits-ts.jsonl" "$proj" false)" >/dev/null
assert_state_count "$proj" "1" "09.new-session-resets"

# Force TTL expiry by hand-editing last_ts to 1h ago
ts_old=$(($(date +%s) - 7200))
jq --argjson t "$ts_old" '.last_ts = $t' "$proj/.claude/.fallow-hook-state.json" > "$proj/.claude/.fallow-hook-state.json.tmp"
mv "$proj/.claude/.fallow-hook-state.json.tmp" "$proj/.claude/.fallow-hook-state.json"

PATH="$MOCKS:/usr/bin:/bin" FALLOW_MOCK_OUTPUT="$FIXTURES/audit-fail-1-introduced.json" FALLOW_MOCK_EXIT=2 \
  bash "$SCRIPT" <<<"$(hook_input sess-B "$FIXTURES/transcript-edits-ts.jsonl" "$proj" false)" >/dev/null
assert_state_count "$proj" "1" "09.ttl-expiry-resets"

rm -rf "$proj"
```

`crates/cli/tests/fallow_stop_gate/cases/10_dry_run.bash`:

```bash
# 10 — DRY_RUN: never emits decision:block; logs to FALLOW_HOOK_LOG
proj=$(mk_project)
echo '{}' > "$proj/package.json"
( cd "$proj" && git init -q && git commit --allow-empty -q -m init )
log_file="$proj/.claude/.fallow-hook.log"

out=$(PATH="$MOCKS:/usr/bin:/bin" \
  FALLOW_MOCK_OUTPUT="$FIXTURES/audit-fail-1-introduced.json" FALLOW_MOCK_EXIT=2 \
  FALLOW_HOOK_DRY_RUN=1 FALLOW_HOOK_LOG="$log_file" \
  bash "$SCRIPT" <<<"$(hook_input sess1 "$FIXTURES/transcript-edits-ts.jsonl" "$proj" false)" 2>&1)
rc=$?
assert_exit "$rc" "0" "10.dry-run-zero"
assert_not_contains "$out" '"decision":"block"' "10.dry-run-no-block"
[ -f "$log_file" ] && pass "10.dry-run-log-exists" || fail "10.dry-run-log-exists" ""
grep -q "verdict=fail" "$log_file" 2>/dev/null && pass "10.dry-run-log-has-verdict" || fail "10.dry-run-log-has-verdict" ""

rm -rf "$proj"
```

- [ ] **Step 2: Run tests to verify they fail.** Likely 09 partially passes (logic is already there); 10 FAILs (no DRY_RUN handling).

```bash
bash crates/cli/tests/fallow_stop_gate/run.sh
```

- [ ] **Step 3: Implement DRY_RUN.** In `fallow-stop-gate.sh`, replace the final block (the section that emits `jq -n ... '{decision:"block", reason:$r}'`) with:

```bash
LOG_FILE="${FALLOW_HOOK_LOG-$HOME/.claude/.fallow-hook.log}"
log_event() {
  if [ "${FALLOW_HOOK_DEBUG:-}" = "1" ] || [ "${FALLOW_HOOK_DRY_RUN:-}" = "1" ]; then
    {
      printf '%s [%s] proj=%s session=%s verdict=%s count=%s locked=%s\n' \
        "$(date '+%Y-%m-%dT%H:%M:%S%z')" \
        "${FALLOW_HOOK_DRY_RUN:+DRY}${FALLOW_HOOK_DRY_RUN:-LIVE}" \
        "$PROJECT_DIR" "$SESSION_ID" "$VERDICT" "$NEW_COUNT" "$1"
    } >>"$LOG_FILE" 2>/dev/null || true
  fi
}

if [ "$NEW_COUNT" -ge "$LOOP_LIMIT" ] || [ "$PREV_LOCKED" = "true" ]; then
  REASON="$(build_reason_advisory)"
  ADVISORY_LOCKED=true
else
  REASON="$(build_reason_normal "$NEW_COUNT" "$LOOP_LIMIT")"
  ADVISORY_LOCKED=false
fi

write_state "$NEW_COUNT" fail "$ADVISORY_LOCKED"
log_event "$ADVISORY_LOCKED"

if [ "${FALLOW_HOOK_DRY_RUN:-}" = "1" ]; then
  echo "fallow-stop-gate: DRY_RUN — would block with reason:" >&2
  echo "$REASON" >&2
  exit 0
fi

jq -n --arg r "$REASON" '{decision:"block", reason:$r}'
exit 0
```

- [ ] **Step 4: Run tests.**

```bash
bash crates/cli/tests/fallow_stop_gate/run.sh
```

Expected: all 09.*/10.* cases pass.

- [ ] **Step 5: Commit.**

```bash
git add crates/cli/src/setup_hooks/fallow-stop-gate.sh \
        crates/cli/tests/fallow_stop_gate/cases/09_reset.bash \
        crates/cli/tests/fallow_stop_gate/cases/10_dry_run.bash
git commit -S -m "feat(hook): TTL/session reset, DRY_RUN mode, log_event"
```

---

### Task 10: Bash test harness — wire into `cargo test`

**Files:**
- Modify: `crates/cli/tests/fallow_stop_gate/run.sh` (add `BAIL_ON_MISSING_JQ` exit code 0)
- Create: `crates/cli/tests/fallow_stop_gate_runner.rs` — Rust shim that invokes `bash run.sh`

- [ ] **Step 1: Write the Rust shim test.** Create `crates/cli/tests/fallow_stop_gate_runner.rs`:

```rust
use std::process::Command;

#[test]
fn fallow_stop_gate_bash_suite() {
    let manifest = env!("CARGO_MANIFEST_DIR");
    let script = format!("{manifest}/tests/fallow_stop_gate/run.sh");
    let output = Command::new("bash")
        .arg(&script)
        .output()
        .expect("failed to spawn bash test runner");
    if !output.status.success() {
        eprintln!("--- stdout ---\n{}", String::from_utf8_lossy(&output.stdout));
        eprintln!("--- stderr ---\n{}", String::from_utf8_lossy(&output.stderr));
        panic!("fallow-stop-gate bash suite failed");
    }
}
```

- [ ] **Step 2: Verify suite runs under cargo.**

```bash
cargo test -p fallow-cli --test fallow_stop_gate_runner 2>&1 | tail -20
```

Expected: 1 test passes, output of bash runner visible if it fails.

- [ ] **Step 3: Commit.**

```bash
git add crates/cli/tests/fallow_stop_gate_runner.rs
git commit -S -m "test(cli): wire fallow-stop-gate bash suite into cargo test"
```

---

## Phase B — Rust install command

### Task 11: Clap flags `--hook-user` and `--uninstall`

**Files:**
- Modify: `crates/cli/src/main.rs`
- Create: `crates/cli/src/hook_user.rs` (stub)
- Modify: `crates/cli/src/lib.rs`

- [ ] **Step 1: Inspect existing Init variant.** Run:

```bash
grep -n "Init\b" crates/cli/src/main.rs | head -10
```

Identify the `Init { ... }` enum variant in the `Commands` enum. Note its existing fields (e.g., `--toml`, `--hooks`).

- [ ] **Step 2: Write failing test.** Create `crates/cli/tests/hook_user_tests.rs`:

```rust
use fallow_cli::hook_user;

#[test]
fn install_writes_script_and_settings() {
    let temp = tempfile::tempdir().expect("tempdir");
    let home = temp.path().to_path_buf();

    hook_user::install_at(&home).expect("install ok");

    let script = home.join(".claude").join("hooks").join("fallow-stop-gate.sh");
    assert!(script.exists(), "script not created");

    let settings = home.join(".claude").join("settings.json");
    let body = std::fs::read_to_string(&settings).expect("read settings");
    assert!(body.contains("fallow-stop-gate.sh"), "settings missing entry");
}
```

Add `tempfile = "3"` to `crates/cli/Cargo.toml` `[dev-dependencies]` if missing:

```bash
grep -q "^tempfile" crates/cli/Cargo.toml || \
  sed -i.bak '/^\[dev-dependencies\]/a\
tempfile = { workspace = true }' crates/cli/Cargo.toml
rm -f crates/cli/Cargo.toml.bak
```

(If `tempfile` is already in workspace deps, this works. If not, add to root `Cargo.toml` `[workspace.dependencies]` first: `tempfile = "3"`.)

- [ ] **Step 3: Run test to verify it fails.**

```bash
cargo test -p fallow-cli --test hook_user_tests 2>&1 | tail -20
```

Expected: compile error — `fallow_cli::hook_user` does not exist.

- [ ] **Step 4: Create stub module.** Create `crates/cli/src/hook_user.rs`:

```rust
//! User-scope Stop hook installer for Claude Code.
//!
//! Writes `~/.claude/hooks/fallow-stop-gate.sh` and merges a Stop hook
//! entry into `~/.claude/settings.json`. Idempotent and reversible.

use std::path::Path;

/// Top-level error type for hook install/uninstall.
#[derive(Debug, thiserror::Error)]
pub enum HookUserError {
    #[error("io error at {path}: {source}")]
    Io { path: String, source: std::io::Error },
    #[error("settings.json malformed at {path}: {source}")]
    Json { path: String, source: serde_json::Error },
}

/// Install the user-scope Stop hook into `home/.claude/`.
pub fn install_at(_home: &Path) -> Result<(), HookUserError> {
    unimplemented!("Task 12 implements this")
}

/// Uninstall the user-scope Stop hook from `home/.claude/`.
pub fn uninstall_at(_home: &Path) -> Result<(), HookUserError> {
    unimplemented!("Task 14 implements this")
}
```

Add module to `crates/cli/src/lib.rs`:

```rust
pub mod hook_user;
```

(If `lib.rs` is the workspace lib for the cli crate, add the line near other `pub mod` declarations. Run `grep -n "^pub mod" crates/cli/src/lib.rs` to find them.)

Add `thiserror = { workspace = true }` to `crates/cli/Cargo.toml` `[dependencies]` if not already present.

- [ ] **Step 5: Add clap flags + dispatch in `main.rs`.** In the `Commands::Init` variant, add fields:

```rust
        /// Install user-scope Stop hook (writes ~/.claude/hooks + settings.json)
        #[arg(long)]
        hook_user: bool,

        /// With --hook-user, uninstall instead of install
        #[arg(long, requires = "hook_user")]
        uninstall: bool,
```

In the dispatch arm for `Init { ... }`, before the existing logic, route to `hook_user`:

```rust
        Commands::Init { hook_user, uninstall, .. } if hook_user => {
            let home = match dirs::home_dir() {
                Some(h) => h,
                None => {
                    eprintln!("error: cannot resolve $HOME");
                    return ExitCode::from(2);
                }
            };
            let result = if uninstall {
                fallow_cli::hook_user::uninstall_at(&home)
            } else {
                fallow_cli::hook_user::install_at(&home)
            };
            return match result {
                Ok(()) => ExitCode::SUCCESS,
                Err(e) => { eprintln!("error: {e}"); ExitCode::from(2) }
            };
        }
```

(Adjust to match the existing dispatch style. If `Commands::Init` is a struct variant, destructure the relevant fields. Run `cargo check -p fallow-cli` after editing to surface mismatches.)

- [ ] **Step 6: Run test to verify it now compiles but fails on `unimplemented!`.**

```bash
cargo test -p fallow-cli --test hook_user_tests 2>&1 | tail -10
```

Expected: panic from `unimplemented!`.

- [ ] **Step 7: Commit.**

```bash
git add crates/cli/src/hook_user.rs crates/cli/src/lib.rs crates/cli/src/main.rs crates/cli/Cargo.toml crates/cli/tests/hook_user_tests.rs Cargo.toml
git commit -S -m "feat(cli): add --hook-user and --uninstall flags + module stub"
```

---

### Task 12: `install_at` happy path (empty settings.json)

**Files:**
- Modify: `crates/cli/src/hook_user.rs`
- Create: `crates/cli/src/setup_hooks/fallow-stop-gate.sh` (already exists from Phase A; re-used)

- [ ] **Step 1: Augment failing test for full happy-path assertions.** In `crates/cli/tests/hook_user_tests.rs`, append:

```rust
#[test]
fn install_creates_dirs_and_correct_mode() {
    use std::os::unix::fs::PermissionsExt;
    let temp = tempfile::tempdir().expect("tempdir");
    let home = temp.path();
    fallow_cli::hook_user::install_at(home).expect("install");

    let hooks_dir = home.join(".claude").join("hooks");
    let script = hooks_dir.join("fallow-stop-gate.sh");
    assert!(hooks_dir.is_dir());
    let mode = std::fs::metadata(&script).unwrap().permissions().mode() & 0o777;
    assert_eq!(mode, 0o755, "script must be 0755, got {:o}", mode);

    let settings_text = std::fs::read_to_string(home.join(".claude").join("settings.json")).unwrap();
    let settings: serde_json::Value = serde_json::from_str(&settings_text).unwrap();
    let stop_arr = settings.pointer("/hooks/Stop").and_then(|v| v.as_array()).expect("Stop array");
    let any = stop_arr.iter().any(|entry| {
        entry.pointer("/hooks/0/command")
            .and_then(|v| v.as_str())
            .map(|s| s.contains("fallow-stop-gate.sh"))
            .unwrap_or(false)
    });
    assert!(any, "Stop array missing fallow-stop-gate entry: {settings_text}");
}
```

- [ ] **Step 2: Run test to verify it fails.**

```bash
cargo test -p fallow-cli --test hook_user_tests install_creates_dirs_and_correct_mode 2>&1 | tail -15
```

Expected: panic from `unimplemented!`.

- [ ] **Step 3: Implement `install_at`.** Replace stub in `crates/cli/src/hook_user.rs`:

```rust
use std::fs;
use std::io::Write;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

const SCRIPT: &str = include_str!("setup_hooks/fallow-stop-gate.sh");
const HOOK_COMMAND: &str = "\"$HOME\"/.claude/hooks/fallow-stop-gate.sh";

fn io_err(path: &Path, source: std::io::Error) -> HookUserError {
    HookUserError::Io { path: path.display().to_string(), source }
}

fn json_err(path: &Path, source: serde_json::Error) -> HookUserError {
    HookUserError::Json { path: path.display().to_string(), source }
}

fn write_atomic(path: &Path, body: &[u8], mode: u32) -> Result<(), HookUserError> {
    let parent = path.parent().expect("path has parent");
    fs::create_dir_all(parent).map_err(|e| io_err(parent, e))?;
    let tmp = parent.join(format!(".{}.tmp", path.file_name().unwrap().to_string_lossy()));
    {
        let mut f = fs::File::create(&tmp).map_err(|e| io_err(&tmp, e))?;
        f.write_all(body).map_err(|e| io_err(&tmp, e))?;
        let mut p = f.metadata().map_err(|e| io_err(&tmp, e))?.permissions();
        p.set_mode(mode);
        f.set_permissions(p).map_err(|e| io_err(&tmp, e))?;
    }
    fs::rename(&tmp, path).map_err(|e| io_err(path, e))?;
    Ok(())
}

fn settings_path(home: &Path) -> PathBuf { home.join(".claude").join("settings.json") }
fn script_path(home: &Path) -> PathBuf { home.join(".claude").join("hooks").join("fallow-stop-gate.sh") }

fn load_settings(path: &Path) -> Result<serde_json::Value, HookUserError> {
    if !path.exists() { return Ok(serde_json::json!({})); }
    let body = fs::read_to_string(path).map_err(|e| io_err(path, e))?;
    if body.trim().is_empty() { return Ok(serde_json::json!({})); }
    serde_json::from_str(&body).map_err(|e| json_err(path, e))
}

fn ensure_stop_entry(settings: &mut serde_json::Value) -> bool {
    use serde_json::{json, Value};
    let hooks = settings.as_object_mut().expect("settings is object")
        .entry("hooks").or_insert(Value::Object(Default::default()));
    let stop = hooks.as_object_mut().expect("hooks is object")
        .entry("Stop").or_insert(Value::Array(Vec::new()));
    let stop_arr = stop.as_array_mut().expect("Stop is array");

    let already = stop_arr.iter().any(|entry| {
        entry.pointer("/hooks").and_then(|h| h.as_array()).map(|hs| {
            hs.iter().any(|h| {
                h.get("command")
                    .and_then(|c| c.as_str())
                    .map(|s| s.contains("fallow-stop-gate.sh"))
                    .unwrap_or(false)
            })
        }).unwrap_or(false)
    });
    if already { return false; }

    stop_arr.push(json!({
        "matcher": "",
        "hooks": [
            {
                "type": "command",
                "command": HOOK_COMMAND,
                "timeout": 130
            }
        ]
    }));
    true
}

pub fn install_at(home: &Path) -> Result<(), HookUserError> {
    let script = script_path(home);
    write_atomic(&script, SCRIPT.as_bytes(), 0o755)?;

    let settings = settings_path(home);
    let mut value = load_settings(&settings)?;
    if value.is_null() { value = serde_json::json!({}); }
    if !value.is_object() {
        return Err(HookUserError::Json {
            path: settings.display().to_string(),
            source: serde_json::from_str::<serde_json::Value>("\"top-level not object\"").unwrap_err(),
        });
    }
    if ensure_stop_entry(&mut value) {
        if settings.exists() {
            let backup = settings.with_extension(format!("json.bak.{}", chrono::Local::now().format("%Y%m%dT%H%M%S")));
            fs::copy(&settings, &backup).map_err(|e| io_err(&backup, e))?;
        }
        let body = serde_json::to_vec_pretty(&value).expect("serialize");
        write_atomic(&settings, &body, 0o644)?;
        eprintln!("✓ Installed user-scope fallow-stop-gate hook.");
    } else {
        eprintln!("ℹ Already installed (no changes to settings.json).");
    }

    Ok(())
}
```

Add `chrono = { workspace = true, default-features = false, features = ["clock"] }` (or use `std::time::SystemTime` if chrono is not in workspace — see step 4 alternative).

- [ ] **Step 4: If chrono unavailable, swap timestamp.** Replace the `with_extension(format!(...))` line with:

```rust
            let secs = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_secs()).unwrap_or(0);
            let backup = settings.with_extension(format!("json.bak.{secs}"));
```

(Confirm chrono in workspace: `grep chrono Cargo.toml | head -3`. If missing, use the secs version.)

- [ ] **Step 5: Run tests.**

```bash
cargo test -p fallow-cli --test hook_user_tests 2>&1 | tail -15
```

Expected: both tests pass.

- [ ] **Step 6: Commit.**

```bash
git add crates/cli/src/hook_user.rs crates/cli/Cargo.toml crates/cli/tests/hook_user_tests.rs
git commit -S -m "feat(cli): hook_user::install_at writes script + merges settings"
```

---

### Task 13: Idempotent install + preserve existing hooks

**Files:**
- Modify: `crates/cli/tests/hook_user_tests.rs`

- [ ] **Step 1: Write failing tests.**

Append to `crates/cli/tests/hook_user_tests.rs`:

```rust
#[test]
fn install_is_idempotent_and_preserves_other_hooks() {
    let temp = tempfile::tempdir().expect("tempdir");
    let home = temp.path();
    let claude = home.join(".claude");
    std::fs::create_dir_all(&claude).unwrap();
    let settings = claude.join("settings.json");
    std::fs::write(&settings, r#"{
      "hooks": {
        "Stop": [
          {"matcher":"","hooks":[{"type":"command","command":"/usr/bin/env hookz-speaker"}]}
        ]
      }
    }"#).unwrap();

    fallow_cli::hook_user::install_at(home).expect("install 1");
    fallow_cli::hook_user::install_at(home).expect("install 2 (idempotent)");

    let body = std::fs::read_to_string(&settings).unwrap();
    let v: serde_json::Value = serde_json::from_str(&body).unwrap();
    let stop = v.pointer("/hooks/Stop").and_then(|s| s.as_array()).unwrap();
    assert_eq!(stop.len(), 2, "must have hookz + fallow-stop-gate, got {body}");

    let entries: Vec<&str> = stop.iter()
        .flat_map(|e| e.pointer("/hooks/0/command").and_then(|c| c.as_str()))
        .collect();
    assert!(entries.iter().any(|s| s.contains("hookz-speaker")), "hookz preserved");
    assert!(entries.iter().any(|s| s.contains("fallow-stop-gate.sh")), "fallow added");
}
```

- [ ] **Step 2: Run test.**

```bash
cargo test -p fallow-cli --test hook_user_tests install_is_idempotent_and_preserves_other_hooks 2>&1 | tail -10
```

Expected: PASS (logic from Task 12 already de-dupes).

If FAIL: inspect the dedupe logic in `ensure_stop_entry` — likely the matcher pattern needs adjustment (e.g., search both `/command` and `/hooks/0/command`). Fix and re-run.

- [ ] **Step 3: Commit.**

```bash
git add crates/cli/tests/hook_user_tests.rs
git commit -S -m "test(cli): assert install idempotency and preservation of other Stop hooks"
```

---

### Task 14: `uninstall_at` + corrupt settings handling

**Files:**
- Modify: `crates/cli/src/hook_user.rs`
- Modify: `crates/cli/tests/hook_user_tests.rs`

- [ ] **Step 1: Write failing tests.**

Append to `crates/cli/tests/hook_user_tests.rs`:

```rust
#[test]
fn uninstall_removes_only_our_entry() {
    let temp = tempfile::tempdir().expect("tempdir");
    let home = temp.path();
    let claude = home.join(".claude");
    std::fs::create_dir_all(&claude).unwrap();
    std::fs::write(claude.join("settings.json"), r#"{
      "hooks": {
        "Stop": [
          {"matcher":"","hooks":[{"type":"command","command":"/usr/bin/env hookz-speaker"}]}
        ]
      }
    }"#).unwrap();

    fallow_cli::hook_user::install_at(home).expect("install");
    fallow_cli::hook_user::uninstall_at(home).expect("uninstall");

    let body = std::fs::read_to_string(claude.join("settings.json")).unwrap();
    let v: serde_json::Value = serde_json::from_str(&body).unwrap();
    let stop = v.pointer("/hooks/Stop").and_then(|s| s.as_array()).unwrap();
    assert_eq!(stop.len(), 1);
    let cmd = stop[0].pointer("/hooks/0/command").and_then(|c| c.as_str()).unwrap();
    assert!(cmd.contains("hookz-speaker"));

    let script = home.join(".claude").join("hooks").join("fallow-stop-gate.sh");
    assert!(!script.exists(), "script must be removed");
}

#[test]
fn install_aborts_cleanly_on_corrupt_settings() {
    let temp = tempfile::tempdir().expect("tempdir");
    let home = temp.path();
    let claude = home.join(".claude");
    std::fs::create_dir_all(&claude).unwrap();
    std::fs::write(claude.join("settings.json"), b"{ this is not json").unwrap();
    let err = fallow_cli::hook_user::install_at(home).unwrap_err();
    assert!(matches!(err, fallow_cli::hook_user::HookUserError::Json { .. }));
}
```

- [ ] **Step 2: Run tests to verify they fail.** `uninstall_removes_only_our_entry` panics on `unimplemented!`. `install_aborts_cleanly_on_corrupt_settings` may pass already.

```bash
cargo test -p fallow-cli --test hook_user_tests 2>&1 | tail -15
```

- [ ] **Step 3: Implement `uninstall_at`.** In `crates/cli/src/hook_user.rs`, replace the `uninstall_at` stub:

```rust
pub fn uninstall_at(home: &Path) -> Result<(), HookUserError> {
    let settings = settings_path(home);
    if settings.exists() {
        let mut value = load_settings(&settings)?;
        let mut changed = false;
        if let Some(stop) = value.pointer_mut("/hooks/Stop").and_then(|s| s.as_array_mut()) {
            let before = stop.len();
            stop.retain(|entry| {
                let owns = entry.pointer("/hooks").and_then(|h| h.as_array()).map(|hs| {
                    hs.iter().any(|h| h.get("command").and_then(|c| c.as_str())
                        .map(|s| s.contains("fallow-stop-gate.sh"))
                        .unwrap_or(false))
                }).unwrap_or(false);
                !owns
            });
            changed = stop.len() != before;
        }
        if changed {
            let body = serde_json::to_vec_pretty(&value).expect("serialize");
            write_atomic(&settings, &body, 0o644)?;
        }
    }

    let script = script_path(home);
    if script.exists() {
        fs::remove_file(&script).map_err(|e| io_err(&script, e))?;
    }
    eprintln!("✓ Uninstalled user-scope fallow-stop-gate hook.");
    Ok(())
}
```

- [ ] **Step 4: Run tests.**

```bash
cargo test -p fallow-cli --test hook_user_tests 2>&1 | tail -15
```

Expected: 5 tests passing (4 install variants + 1 uninstall).

- [ ] **Step 5: Commit.**

```bash
git add crates/cli/src/hook_user.rs crates/cli/tests/hook_user_tests.rs
git commit -S -m "feat(cli): hook_user::uninstall_at + corrupt settings error path"
```

---

### Task 15: CLI dispatch end-to-end test

**Files:**
- Modify: `crates/cli/tests/hook_user_tests.rs`

- [ ] **Step 1: Add CLI-level test that invokes the binary.**

Append to `crates/cli/tests/hook_user_tests.rs`:

```rust
#[test]
fn cli_init_hook_user_invokes_install() {
    let temp = tempfile::tempdir().expect("tempdir");
    let home = temp.path();
    let bin = env!("CARGO_BIN_EXE_fallow");

    let status = std::process::Command::new(bin)
        .args(["init", "--hook-user"])
        .env("HOME", home)
        .status()
        .expect("spawn fallow init");
    assert!(status.success(), "init --hook-user failed: {status}");
    assert!(home.join(".claude").join("hooks").join("fallow-stop-gate.sh").exists());

    let status = std::process::Command::new(bin)
        .args(["init", "--hook-user", "--uninstall"])
        .env("HOME", home)
        .status()
        .expect("spawn fallow init uninstall");
    assert!(status.success());
    assert!(!home.join(".claude").join("hooks").join("fallow-stop-gate.sh").exists());
}
```

- [ ] **Step 2: Run test.**

```bash
cargo test -p fallow-cli --test hook_user_tests cli_init_hook_user_invokes_install 2>&1 | tail -15
```

If FAIL: dispatch in `main.rs` (Task 11) needs adjustment. Likely the destructuring or guard is wrong. Iterate.

If `dirs::home_dir()` ignores `HOME` env on macOS, switch to `std::env::var("HOME").map(PathBuf::from)` in the dispatch arm to make the test deterministic.

- [ ] **Step 3: Commit when passing.**

```bash
git add crates/cli/tests/hook_user_tests.rs crates/cli/src/main.rs
git commit -S -m "test(cli): end-to-end fallow init --hook-user smoke"
```

---

## Phase C — Polish

### Task 16: User-facing documentation

**Files:**
- Create: `docs/hooks/user-scope-stop-hook.md`
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Write user-facing doc.** Create `docs/hooks/user-scope-stop-hook.md`:

````markdown
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
8. `git diff` exceeds `FALLOW_HOOK_MAX_DIFF` files (default 500) → exit 0 with note
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
| `FALLOW_HOOK_MAX_DIFF` | 500 | Skip if `git diff` > N files |
| `FALLOW_HOOK_LOOP_LIMIT` | 3 | Strikes before advisory |
| `FALLOW_HOOK_LOOP_TTL_SECS` | 1800 | Reset count after N idle seconds |
| `FALLOW_HOOK_MIN_VERSION` | 2.61.0 | Binary floor |
| `FALLOW_HOOK_STATE_DIR` | `$CLAUDE_PROJECT_DIR/.claude` | State file dir |
| `FALLOW_HOOK_LOG` | `~/.claude/.fallow-hook.log` | Log path (DEBUG/DRY_RUN) |

## Per-project opt-out

Add to `.fallowrc.json`:

```json
{ "hook": { "disabled": true } }
```

## Uninstall

```bash
fallow init --hook-user --uninstall
```

Removes the script and the Stop array entry. State files in each
project's `.claude/.fallow-hook-state.json` remain — delete manually if
desired.

## Coexistence with `fallow setup-hooks`

The two are complementary:

- **`fallow init --hook-user`** (this doc) — soft, per-turn, user-scope
- **`fallow setup-hooks`** — hard, blocks `git commit/push`, project-scope

Defense in depth: turn-time soft check + commit-time hard gate.
````

- [ ] **Step 2: Add CHANGELOG entry.** In `CHANGELOG.md`, under Unreleased section (create if absent):

```markdown
## Unreleased

### Added
- `fallow init --hook-user` installs a user-scope Claude Code Stop hook
  that runs `fallow audit` after turns editing TS/JS files. Includes
  3-strike anti-loop, graceful degradation when `fallow` is missing,
  and `FALLOW_HOOK_DRY_RUN=1` mode for safe rollout. See
  `docs/hooks/user-scope-stop-hook.md`.
```

- [ ] **Step 3: Commit.**

```bash
git add docs/hooks/user-scope-stop-hook.md CHANGELOG.md
git commit -S -m "docs: user-scope Stop hook installation guide + changelog"
```

---

### Task 17: Final verification + branch ship

**Files:** none modified — verification only.

- [ ] **Step 1: Run full test suite.**

```bash
cargo test --workspace --all-targets 2>&1 | tail -30
```

Expected: zero failures. If anything in workspace broke from the new module: fix and recommit before proceeding.

- [ ] **Step 2: Run clippy + fmt.**

```bash
cargo clippy --workspace --all-targets -- -D warnings 2>&1 | tail -20
cargo fmt --all -- --check
```

Expected: clean. Fix issues if any, commit fixes with `chore: clippy/fmt`.

- [ ] **Step 3: Manual smoke test in real Claude Code session.**

```bash
mkdir /tmp/fallow-hook-smoke && cd /tmp/fallow-hook-smoke
npm init -y
echo 'export const orphan = 1;' > index.ts
git init && git add -A && git commit -m init
fallow init --hook-user
# Then start a Claude Code session in this dir, edit index.ts to add another export, end the turn.
# Verify ~/.claude/.fallow-hook.log shows entries (if FALLOW_HOOK_DEBUG=1).
```

Cleanup:

```bash
fallow init --hook-user --uninstall
rm -rf /tmp/fallow-hook-smoke
```

- [ ] **Step 4: Push branch.**

```bash
git push -u origin feat/user-scope-stop-hook
```

- [ ] **Step 5: Open PR.**

```bash
gh pr create --repo fallow-rs/fallow --title "feat(cli): user-scope Stop hook for Claude Code (fallow init --hook-user)" --body "$(cat <<'EOF'
## Summary

- New `fallow init --hook-user` flag installs `~/.claude/hooks/fallow-stop-gate.sh` and merges a Stop hook entry into `~/.claude/settings.json`
- Hook runs `fallow audit` after Claude Code turns that edited TS/JS files, gating delivery via `{"decision":"block","reason":"…"}` JSON
- 3-strike anti-loop escalates to advisory mode forcing Claude to ask the user
- Graceful degradation: skips when `fallow` missing, version below floor, no project marker, no TS/JS edits, or diff >500 files
- `FALLOW_HOOK_DRY_RUN=1` for safe 1-week rollout before going live

## Spec & plan

- Spec: `docs/superpowers/specs/2026-05-02-fallow-delivery-hook-design.md`
- Plan: `docs/superpowers/plans/2026-05-02-fallow-delivery-hook.md`

## Test plan

- [x] Bash test suite (`crates/cli/tests/fallow_stop_gate/`) covers heuristic, project detection, binary location, version floor, diff size, pass/warn/fail verdicts, 3-strike escalation, session/TTL reset, DRY_RUN
- [x] Rust integration tests cover `install_at`/`uninstall_at`/idempotency/corrupt JSON
- [x] CLI smoke test (`cli_init_hook_user_invokes_install`)
- [x] `cargo test --workspace --all-targets`
- [x] `cargo clippy --workspace --all-targets -- -D warnings`
- [x] `cargo fmt --all -- --check`
- [x] Manual smoke in real Claude Code session
EOF
)"
```

---

## Self-Review Checklist (run after writing this plan)

- [x] **Spec coverage.** Each section of the spec maps to ≥1 task: §3 architecture → Tasks 2–9; §4 heuristic → Task 3; §5 detection → Task 4; §6 state machine → Tasks 7–9; §7 output contract → Tasks 7–9; §8 bootstrap → Tasks 11–14; §9 coexistence → Task 13; §10 env vars → Tasks 2,5–9; §11 rollout → Task 16 doc; §12 tests → Tasks 1–10,12–15; §13 security → covered by atomic writes (Task 12), backup (Task 12), validation (Task 4 RC); §14 YAGNI → respected; §15 risks → mitigated by skip thresholds + degrade graceful; §16 acceptance → Task 17.
- [x] **Placeholder scan.** No "TBD", "TODO", "implement later", or "similar to Task N". All code blocks are complete.
- [x] **Type consistency.** `HookUserError`, `install_at`, `uninstall_at`, `HOOK_COMMAND`, `SCRIPT`, `write_atomic`, `ensure_stop_entry`, `settings_path`, `script_path` used consistently across Tasks 11–14.
- [x] **Bash consistency.** `fallow-stop-gate.sh` symbols `RUNNER`, `BIN_DESC`, `VERSION`, `MIN_VERSION`, `STATE_FILE`, `PREV_STATE`, `PREV_COUNT`, `PREV_TS`, `PREV_LOCKED`, `NOW`, `TTL`, `LOOP_LIMIT`, `NEW_COUNT`, `VERDICT`, `ADVISORY_LOCKED`, `REASON` used consistently across Tasks 2–9.
