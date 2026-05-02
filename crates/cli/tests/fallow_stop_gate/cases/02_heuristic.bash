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

# 02b — robustness: absolute paths excluded; malformed JSONL line ignored
proj=$(mk_project)
malformed="$(mktemp).jsonl"
cat >"$malformed" <<EOF
{"type":"user","message":{"content":"hi"}}
this is not valid json
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/abs/path/src/utils.ts","old_string":"x","new_string":"y"}}]}}
EOF
out=$(FALLOW_HOOK_DEBUG=1 bash "$SCRIPT" \
  <<<"$(hook_input sess1 "$malformed" "$proj" false)" 2>&1)
rc=$?
assert_exit "$rc" "0" "02b.malformed-line-survived"
assert_contains "$out" "ts/js edits detected" "02b.absolute-path-detected"
rm -f "$malformed"

# Absolute path under node_modules MUST be excluded
nm_path="$(mktemp).jsonl"
cat >"$nm_path" <<EOF
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/Users/x/proj/node_modules/foo/bar.ts","old_string":"x","new_string":"y"}}]}}
EOF
out=$(FALLOW_HOOK_DEBUG=1 bash "$SCRIPT" \
  <<<"$(hook_input sess1 "$nm_path" "$proj" false)" 2>&1)
rc=$?
assert_exit "$rc" "0" "02b.node-modules-abs-excluded-rc"
assert_not_contains "$out" "ts/js edits detected" "02b.node-modules-abs-excluded-msg"
rm -f "$nm_path"

rm -rf "$proj"
