# 01 — input parsing: stop_hook_active=true short-circuits; missing fields don't crash
proj=$(mk_project)

out=$(bash "$SCRIPT" <<<"$(hook_input sess1 /dev/null "$proj" true)" 2>&1)
rc=$?
assert_exit "$rc" "0" "01.stop-active-exits-zero"

out=$(bash "$SCRIPT" <<<'{}' 2>&1)
rc=$?
assert_exit "$rc" "0" "01.empty-input-fail-open"

rm -rf "$proj"
