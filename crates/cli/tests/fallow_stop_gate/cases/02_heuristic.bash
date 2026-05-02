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
