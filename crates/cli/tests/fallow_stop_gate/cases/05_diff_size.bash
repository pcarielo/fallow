# 05 — diff size skip: > FALLOW_HOOK_MAX_DIFF skips audit (tracked + untracked counted)
proj=$(mk_project)
echo '{}' > "$proj/package.json"
( cd "$proj" && git init -q && git commit --allow-empty -q -m init )

# Stage 600 fake files to exceed default 500 threshold (TRACKED via git add -A)
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

# MAX_DIFF=0 disables the check entirely
out=$(PATH="$MOCKS:/usr/bin:/bin" FALLOW_HOOK_MAX_DIFF=0 FALLOW_HOOK_DEBUG=1 bash "$SCRIPT" \
  <<<"$(hook_input sess1 "$FIXTURES/transcript-edits-ts.jsonl" "$proj" false)" 2>&1)
rc=$?
assert_exit "$rc" "0" "05.zero-disables"
assert_not_contains "$out" "diff exceeds" "05.zero-no-skip"

rm -rf "$proj"

# 05b — untracked-only mass refactor IS counted (I-1 fix)
proj=$(mk_project)
echo '{}' > "$proj/package.json"
( cd "$proj" && git init -q && git add package.json && git commit -q -m init )

# 600 untracked .ts files (NOT staged) — should still trip threshold via I-1
mkdir "$proj/new"
for i in $(seq 1 600); do touch "$proj/new/n$i.ts"; done

out=$(PATH="$MOCKS:/usr/bin:/bin" FALLOW_HOOK_DEBUG=1 bash "$SCRIPT" \
  <<<"$(hook_input sess1 "$FIXTURES/transcript-edits-ts.jsonl" "$proj" false)" 2>&1)
rc=$?
assert_exit "$rc" "0" "05b.untracked-mass-zero"
assert_contains "$out" "diff exceeds" "05b.untracked-mass-msg"
assert_contains "$out" "0 tracked + 600 untracked" "05b.untracked-mass-breakdown"

rm -rf "$proj"

# 05c — fresh repo with no HEAD: rev-parse guard prevents stderr noise (I-2 fix)
proj=$(mk_project)
echo '{}' > "$proj/package.json"
( cd "$proj" && git init -q )  # NO commit, HEAD does not resolve

out=$(PATH="$MOCKS:/usr/bin:/bin" FALLOW_HOOK_DEBUG=1 bash "$SCRIPT" \
  <<<"$(hook_input sess1 "$FIXTURES/transcript-edits-ts.jsonl" "$proj" false)" 2>&1)
rc=$?
assert_exit "$rc" "0" "05c.no-head-zero"
assert_not_contains "$out" "integer expression expected" "05c.no-head-no-bash-error"
assert_not_contains "$out" "diff exceeds" "05c.no-head-no-skip"

rm -rf "$proj"

# 05d — invalid FALLOW_HOOK_MAX_DIFF defaults to 500 silently (I-3 fix)
proj=$(mk_project)
echo '{}' > "$proj/package.json"
( cd "$proj" && git init -q && git commit --allow-empty -q -m init )

# Empty value
out=$(PATH="$MOCKS:/usr/bin:/bin" FALLOW_HOOK_MAX_DIFF= FALLOW_HOOK_DEBUG=1 bash "$SCRIPT" \
  <<<"$(hook_input sess1 "$FIXTURES/transcript-edits-ts.jsonl" "$proj" false)" 2>&1)
rc=$?
assert_exit "$rc" "0" "05d.empty-max-diff-zero"
assert_not_contains "$out" "integer expression expected" "05d.empty-no-bash-error"

# Garbage value
out=$(PATH="$MOCKS:/usr/bin:/bin" FALLOW_HOOK_MAX_DIFF=banana FALLOW_HOOK_DEBUG=1 bash "$SCRIPT" \
  <<<"$(hook_input sess1 "$FIXTURES/transcript-edits-ts.jsonl" "$proj" false)" 2>&1)
rc=$?
assert_exit "$rc" "0" "05d.garbage-max-diff-zero"
assert_not_contains "$out" "integer expression expected" "05d.garbage-no-bash-error"

rm -rf "$proj"
