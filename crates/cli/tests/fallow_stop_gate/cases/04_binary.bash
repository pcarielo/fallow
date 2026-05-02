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
