#!/usr/bin/env bash
# Live drive of the legacy-accepted completion line touched by teardown-pool-prune.
# Builds a throwaway firstmate home + git remote + real Treehouse pool, writes a
# legacy task record (no spawn_gen / dead endpoint), and runs the real
# bin/fm-teardown.sh --legacy-record so both the accepted-legacy text and the
# pool-prune summary must land on the same completion line.
#
# Usage: legacy-line-live.sh <evidence-dir>
set -u

WT_ROOT=/home/hugorl/.no-mistakes/worktrees/71308d303441/01M3AMHC7C6SMB3X55CHE4TJS3
TEARDOWN=$WT_ROOT/bin/fm-teardown.sh
EVID=${1:?usage: legacy-line-live.sh <evidence-dir>}
WORK=/tmp/fm-pool-prune-legacy-line
rm -rf "$WORK"
mkdir -p "$WORK" "$EVID"

FAILED=0
pass() { printf 'ok   - %s\n' "$*"; }
fail() { printf 'FAIL - %s\n' "$*"; FAILED=1; }

case_dir="$WORK/legacy-line"
mkdir -p "$case_dir/state" "$case_dir/config" "$case_dir/data" "$case_dir/pool" \
  "$case_dir/home/state" "$case_dir/fakebin"
# The legacy acceptance path only engages when this home owns a markdown backlog
# (fm_backlog_transition_applies), which the real tasks-axi seeds here.
PATH="/home/hugorl/.npm-global/bin:$PATH"
export PATH

cat > "$case_dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []" ; exit 0 ;;
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
cat > "$case_dir/fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  axi)
    shift
    case "${1:-}" in
      status) exit 0 ;;
      abort) exit 0 ;;
    esac
    ;;
  runs) exit 0 ;;
esac
exit 0
SH
chmod +x "$case_dir/fakebin"/*

git init -q --bare "$case_dir/origin.git"
git -C "$case_dir/origin.git" symbolic-ref HEAD refs/heads/main
git clone -q "$case_dir/origin.git" "$case_dir/_seed" 2>/dev/null
git -C "$case_dir/_seed" -c user.email=t@t -c user.name=t \
  commit -q --allow-empty -m "origin baseline"
git -C "$case_dir/_seed" push -q origin main
rm -rf "$case_dir/_seed"
git clone -q "$case_dir/origin.git" "$case_dir/project"
git -C "$case_dir/project" remote set-head origin main 2>/dev/null || true

wt=$(cd "$case_dir/project" && TREEHOUSE_ROOT="$case_dir/pool" treehouse get --lease --no-fetch 2>/dev/null) \
  || fail "legacy-line: treehouse could not hand out a slot"
bystander=$(cd "$case_dir/project" && TREEHOUSE_ROOT="$case_dir/pool" treehouse get --lease --no-fetch 2>/dev/null) \
  || fail "legacy-line: treehouse could not hand out a second slot"

# Land 16 MiB of real work on origin/main, then leave the copy returned and stale.
(
  cd "$wt" || exit 1
  git fetch -q origin || exit 1
  git checkout -q -b fm/task-x1 origin/main || exit 1
  head -c $((16 * 1048576)) /dev/urandom > legacy.bin || exit 1
  git add legacy.bin || exit 1
  git -c user.email=t@t -c user.name=t commit -q -m "landed legacy work" || exit 1
  git push -q origin HEAD:main || exit 1
) || fail "legacy-line: could not land the task commit"
git -C "$case_dir/project" fetch -q origin
printf 'in use and dirty\n' > "$bystander/scratch.txt"

# Legacy record: no spawn_gen, so --legacy-record resolves the incarnation; the
# stubbed tmux reads as agent-less so the endpoint classifies as missing/dead.
{
  printf 'window=firstmate:fm-task-x1\n'
  printf 'endpoint_task_id=task-x1\n'
  printf 'worktree=%s\n' "$wt"
  printf 'project=%s\n' "$case_dir/project"
  printf 'kind=ship\n'
  printf 'mode=local-only\n'
  printf 'harness=codex\n'
} > "$case_dir/state/task-x1.meta"
printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' \
  > "$case_dir/data/backlog.md"
tasks-axi add task-x1 "legacy line fixture task" --kind ship \
  --file "$case_dir/data/backlog.md" >/dev/null \
  || fail "legacy-line: could not seed the backlog row"
tasks-axi start task-x1 --file "$case_dir/data/backlog.md" >/dev/null \
  || fail "legacy-line: could not start the backlog row"
touch "$case_dir/state/.last-watcher-beat"

before_du=$(du -sh "$case_dir/pool" | cut -f1)

FM_ROOT_OVERRIDE="$WT_ROOT" \
FM_STATE_OVERRIDE="$case_dir/state" \
FM_DATA_OVERRIDE="$case_dir/data" \
FM_CONFIG_OVERRIDE="$case_dir/config" \
FM_GATE_REFUSE_BYPASS=1 \
FM_HOME="$case_dir/home" \
TREEHOUSE_ROOT="$case_dir/pool" \
PATH="$case_dir/fakebin:$PATH" \
  "$TEARDOWN" task-x1 --legacy-record > "$case_dir/stdout" 2> "$case_dir/stderr"
rc=$?

after_du=$(du -sh "$case_dir/pool" | cut -f1)
after_status=$(cd "$case_dir/project" && TREEHOUSE_ROOT="$case_dir/pool" treehouse status 2>&1)

{
  echo "== case: $case_dir (real treehouse $(treehouse --version 2>/dev/null))"
  echo "== legacy record has no spawn_gen; endpoint stubbed agent-less (missing)"
  echo "== slot (task-x1, 16MiB landed): $wt"
  echo "== bystander (leased+dirty): $bystander"
  echo "== teardown --legacy-record exit: $rc"
  echo "== pool before: $before_du / after: $after_du"
  echo "== stdout"; cat "$case_dir/stdout"
  echo "== stderr"; cat "$case_dir/stderr"
  echo "== slot exists: $([ -e "$wt" ] && echo yes || echo no)"
  echo "== bystander exists: $([ -e "$bystander" ] && echo yes || echo no); scratch intact: $([ -f "$bystander/scratch.txt" ] && echo yes || echo no)"
  echo "== treehouse status"; printf '%s\n' "$after_status"
  echo "== completion line:"; grep '^teardown task-x1 complete' "$case_dir/stdout"
} > "$case_dir/report.txt"

[ "$rc" = 0 ] || fail "the legacy-accepted close exited $rc"
grep -Fq 'legacy record accepted without spawn_gen' "$case_dir/stdout" \
  || fail "the legacy acceptance text vanished from the completion line"
grep -Eq '^teardown task-x1 complete \(.*legacy record accepted without spawn_gen: endpoint [a-z]+, incarnation legacy-.*; pool prune freed .*\(1 copy\)\)$' "$case_dir/stdout" \
  || fail "the completion line did not carry both the legacy incarnation and the pool-prune summary"
grep -Fq 'teardown: pool prune for the worktree pool freed' "$case_dir/stdout" \
  || fail "the reclaimed amount was not reported for the legacy close"
[ ! -e "$wt" ] || fail "the returned copy was not reclaimed for the legacy close"
[ -f "$bystander/scratch.txt" ] || fail "the in-use copy beside it was destroyed"

cp "$case_dir/report.txt" "$EVID/scenario-legacy-record-completion-line.txt"
if [ "$FAILED" = 0 ]; then
  pass "a legacy-accepted close pruned its returned copy and the completion line carried both facts"
else
  echo "SCENARIO FAILURES PRESENT"
fi
exit "$FAILED"
