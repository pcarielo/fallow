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
