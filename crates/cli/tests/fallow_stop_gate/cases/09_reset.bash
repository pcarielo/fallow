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

# Force TTL expiry by hand-editing last_ts to 2h ago
ts_old=$(($(date +%s) - 7200))
jq --argjson t "$ts_old" '.last_ts = $t' "$proj/.claude/.fallow-hook-state.json" > "$proj/.claude/.fallow-hook-state.json.tmp"
mv "$proj/.claude/.fallow-hook-state.json.tmp" "$proj/.claude/.fallow-hook-state.json"

PATH="$MOCKS:/usr/bin:/bin" FALLOW_MOCK_OUTPUT="$FIXTURES/audit-fail-1-introduced.json" FALLOW_MOCK_EXIT=2 \
  bash "$SCRIPT" <<<"$(hook_input sess-B "$FIXTURES/transcript-edits-ts.jsonl" "$proj" false)" >/dev/null
assert_state_count "$proj" "1" "09.ttl-expiry-resets"

rm -rf "$proj"
