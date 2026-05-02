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
