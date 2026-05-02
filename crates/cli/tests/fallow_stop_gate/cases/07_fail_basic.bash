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

# 07b — broader filter coverage: unused_class_members + HealthFinding render correctly
proj=$(mk_project)
echo '{}' > "$proj/package.json"
( cd "$proj" && git init -q && git commit --allow-empty -q -m init )

out=$(PATH="$MOCKS:/usr/bin:/bin" FALLOW_MOCK_OUTPUT="$FIXTURES/audit-fail-mixed.json" \
  FALLOW_MOCK_EXIT=2 \
  bash "$SCRIPT" <<<"$(hook_input sess1 "$FIXTURES/transcript-edits-ts.jsonl" "$proj" false)")
rc=$?
assert_exit "$rc" "0" "07b.mixed-fail-zero"

reason=$(jq -r '.reason' <<<"$out" 2>/dev/null || true)
[[ "$reason" == *"defunctMethod"* ]] && pass "07b.unused-class-member-rendered" \
  || fail "07b.unused-class-member-rendered" "no defunctMethod in: $reason"
[[ "$reason" == *"bigFunction"* ]] && pass "07b.health-finding-name-rendered" \
  || fail "07b.health-finding-name-rendered" "no bigFunction in: $reason"
[[ "$reason" == *"src/widget.ts:17"* ]] && pass "07b.class-member-line" \
  || fail "07b.class-member-line" ""
[[ "$reason" == *"src/foo.ts:42"* ]] && pass "07b.health-line" \
  || fail "07b.health-line" ""

rm -rf "$proj"
