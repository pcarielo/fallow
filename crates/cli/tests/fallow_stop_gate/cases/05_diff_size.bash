# 05 — diff size skip: > FALLOW_HOOK_MAX_DIFF skips audit
proj=$(mk_project)
echo '{}' > "$proj/package.json"
( cd "$proj" && git init -q && git commit --allow-empty -q -m init )

# Stage 600 fake files to exceed default 500 threshold
mkdir "$proj/many"
for i in $(seq 1 600); do touch "$proj/many/f$i.ts"; done
( cd "$proj" && git add -A )

out=$(PATH="$MOCKS:/usr/bin:/bin" FALLOW_HOOK_DEBUG=1 bash "$SCRIPT" \
  <<<"$(hook_input sess1 "$FIXTURES/transcript-edits-ts.jsonl" "$proj" false)" 2>&1)
rc=$?
assert_exit "$rc" "0" "05.huge-diff-zero"
assert_contains "$out" "diff exceeds" "05.huge-diff-msg"

# Override threshold to 1000 → should not skip on size
out=$(PATH="$MOCKS:/usr/bin:/bin" FALLOW_HOOK_MAX_DIFF=1000 FALLOW_HOOK_DEBUG=1 bash "$SCRIPT" \
  <<<"$(hook_input sess1 "$FIXTURES/transcript-edits-ts.jsonl" "$proj" false)" 2>&1)
rc=$?
assert_exit "$rc" "0" "05.large-but-under-threshold-zero"
assert_not_contains "$out" "diff exceeds" "05.large-but-under-threshold-no-msg"

rm -rf "$proj"
