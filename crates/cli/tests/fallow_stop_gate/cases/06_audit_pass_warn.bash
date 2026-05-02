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

# 06b — fallow audit timeout (exit 124) → fail-open with stderr note
proj=$(mk_project)
echo '{}' > "$proj/package.json"
( cd "$proj" && git init -q && git commit --allow-empty -q -m init )

out=$(PATH="$MOCKS:/usr/bin:/bin" \
  FALLOW_MOCK_OUTPUT="$FIXTURES/audit-pass.json" \
  FALLOW_MOCK_EXIT=124 \
  bash "$SCRIPT" <<<"$(hook_input sess1 "$FIXTURES/transcript-edits-ts.jsonl" "$proj" false)" 2>&1)
rc=$?
assert_exit "$rc" "0" "06b.timeout-zero"
assert_contains "$out" "timed out" "06b.timeout-msg"

rm -rf "$proj"

# 06c — audit produces non-JSON garbage → fail-open
proj=$(mk_project)
echo '{}' > "$proj/package.json"
( cd "$proj" && git init -q && git commit --allow-empty -q -m init )

garbage="$(mktemp)"
echo "this is not json at all" > "$garbage"

out=$(PATH="$MOCKS:/usr/bin:/bin" FALLOW_MOCK_OUTPUT="$garbage" \
  bash "$SCRIPT" <<<"$(hook_input sess1 "$FIXTURES/transcript-edits-ts.jsonl" "$proj" false)" 2>&1)
rc=$?
assert_exit "$rc" "0" "06c.no-json-zero"
assert_contains "$out" "no parseable JSON" "06c.no-json-msg"
rm -f "$garbage"

rm -rf "$proj"

# 06d — corrupt state file recovers cleanly
proj=$(mk_project)
echo '{}' > "$proj/package.json"
( cd "$proj" && git init -q && git commit --allow-empty -q -m init )
echo 'this is not valid json' > "$proj/.claude/.fallow-hook-state.json"

out=$(PATH="$MOCKS:/usr/bin:/bin" FALLOW_MOCK_OUTPUT="$FIXTURES/audit-pass.json" \
  FALLOW_HOOK_DEBUG=1 \
  bash "$SCRIPT" <<<"$(hook_input sess1 "$FIXTURES/transcript-edits-ts.jsonl" "$proj" false)" 2>&1)
rc=$?
assert_exit "$rc" "0" "06d.corrupt-state-zero"
assert_contains "$out" "state file corrupt, resetting" "06d.corrupt-state-debug"
assert_state_count "$proj" "0" "06d.corrupt-state-recovers-to-zero"

rm -rf "$proj"
