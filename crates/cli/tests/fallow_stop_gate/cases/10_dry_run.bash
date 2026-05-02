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
