# 00 — smoke: script exists, runs, FALLOW_HOOK_DISABLED short-circuits
proj=$(mk_project)

out=$(FALLOW_HOOK_DISABLED=1 bash "$SCRIPT" <<<"$(hook_input sess1 /dev/null "$proj" false)" 2>&1)
rc=$?
assert_exit "$rc" "0" "00.disabled-exits-zero"
assert_empty "$out" "00.disabled-no-output"

rm -rf "$proj"
