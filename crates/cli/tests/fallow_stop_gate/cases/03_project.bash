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

# 03b — TOML/JSONC files surface MVP limitation in debug
proj=$(mk_project)
echo 'hook = { disabled = true }' > "$proj/fallow.toml"
out=$(FALLOW_HOOK_DEBUG=1 bash "$SCRIPT" \
  <<<"$(hook_input sess1 "$FIXTURES/transcript-edits-ts.jsonl" "$proj" false)" 2>&1)
rc=$?
assert_exit "$rc" "0" "03b.toml-progresses"
assert_contains "$out" "hook.disabled not parsed" "03b.toml-debug-mvp"

rm "$proj/fallow.toml"
echo '/* a comment */ {"hook":{"disabled":true}}' > "$proj/.fallowrc.jsonc"
out=$(FALLOW_HOOK_DEBUG=1 bash "$SCRIPT" \
  <<<"$(hook_input sess1 "$FIXTURES/transcript-edits-ts.jsonl" "$proj" false)" 2>&1)
rc=$?
assert_exit "$rc" "0" "03b.jsonc-progresses-when-malformed"

# Pure JSON (.fallowrc.json) still honors hook.disabled (regression check)
rm "$proj/.fallowrc.jsonc"
echo '{"hook":{"disabled":true}}' > "$proj/.fallowrc.json"
out=$(FALLOW_HOOK_DEBUG=1 bash "$SCRIPT" \
  <<<"$(hook_input sess1 "$FIXTURES/transcript-edits-ts.jsonl" "$proj" false)" 2>&1)
rc=$?
assert_exit "$rc" "0" "03b.json-disabled-still-works"
assert_contains "$out" "disabled by .fallowrc" "03b.json-disabled-debug"

rm -rf "$proj"
