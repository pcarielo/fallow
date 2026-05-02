# 08 — 3-strike escalation: 3rd consecutive fail in same session → advisory_locked
proj=$(mk_project)
echo '{}' > "$proj/package.json"
( cd "$proj" && git init -q && git commit --allow-empty -q -m init )

run_fail() {
  PATH="$MOCKS:/usr/bin:/bin" FALLOW_MOCK_OUTPUT="$FIXTURES/audit-fail-1-introduced.json" \
    FALLOW_MOCK_EXIT=2 \
    bash "$SCRIPT" <<<"$(hook_input sess-loop "$FIXTURES/transcript-edits-ts.jsonl" "$proj" false)"
}

out1=$(run_fail); rc1=$?
out2=$(run_fail); rc2=$?
out3=$(run_fail); rc3=$?

assert_exit "$rc1" "0" "08.r1-zero"
assert_exit "$rc2" "0" "08.r2-zero"
assert_exit "$rc3" "0" "08.r3-zero"

reason1=$(jq -r '.reason' <<<"$out1")
reason2=$(jq -r '.reason' <<<"$out2")
reason3=$(jq -r '.reason' <<<"$out3")

[[ "$reason1" == *"tentativa 1 de 3"* ]] && pass "08.r1-attempt" || fail "08.r1-attempt" ""
[[ "$reason2" == *"tentativa 2 de 3"* ]] && pass "08.r2-attempt" || fail "08.r2-attempt" ""
[[ "$reason3" == *"3× consecutivas"* ]] && pass "08.r3-advisory" || fail "08.r3-advisory" "$reason3"
[[ "$reason3" == *"PARE"* || "$reason3" == *"pare"* ]] && pass "08.r3-stop-instruction" || fail "08.r3-stop-instruction" ""

# Pass after 3rd fail resets count and unlocks advisory
PATH="$MOCKS:/usr/bin:/bin" FALLOW_MOCK_OUTPUT="$FIXTURES/audit-pass.json" FALLOW_MOCK_EXIT=0 \
  bash "$SCRIPT" <<<"$(hook_input sess-loop "$FIXTURES/transcript-edits-ts.jsonl" "$proj" false)" >/dev/null
assert_state_count "$proj" "0" "08.pass-resets-count"
locked=$(jq -r '.advisory_locked' "$proj/.claude/.fallow-hook-state.json")
[ "$locked" = "false" ] && pass "08.pass-unlocks" || fail "08.pass-unlocks" "locked=$locked"

rm -rf "$proj"
