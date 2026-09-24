#!/usr/bin/env bash
# Live end-to-end drive of bin/fm-teardown.sh's post-return Treehouse pool prune
# (teardown-pool-prune) against the real treehouse binary.
#
# Each scenario builds a throwaway firstmate home + git remote + real Treehouse
# pool under /tmp, then runs the real bin/fm-teardown.sh. Transcripts, pool
# snapshots and assertions land in the evidence directory.
#
# Usage: driver.sh <evidence-dir>
set -u

WT_ROOT=/home/hugorl/.no-mistakes/worktrees/71308d303441/01M3AMHC7C6SMB3X55CHE4TJS3
TEARDOWN=${FM_PP_TEARDOWN:-$WT_ROOT/bin/fm-teardown.sh}
EVID=${1:?usage: driver.sh <evidence-dir>}
WORK=/tmp/fm-pool-prune-live
rm -rf "$WORK"
mkdir -p "$WORK" "$EVID"

FAILED=0
pass() { printf 'ok   - %s\n' "$*"; }
fail() { printf 'FAIL - %s\n' "$*"; FAILED=1; }
info() { printf '     %s\n' "$*"; }

# --- sandbox ---------------------------------------------------------------

make_fakebin() {  # <case-dir>
  local fb=$1/fakebin
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fb/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []" ; exit 0 ;;
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
  cat > "$fb/gh" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
  cat > "$fb/no-mistakes" <<'SH'
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
  chmod +x "$fb"/tmux "$fb"/gh-axi "$fb"/gh "$fb"/no-mistakes
}

# Build a realistic home: bare origin, project clone, real Treehouse pool with
# <n> leased slots, fresh watcher beacon. Echoes the case dir.
make_case() {  # <name> <n-slots>
  local name=$1 slots=$2 case_dir
  case_dir="$WORK/$name"
  mkdir -p "$case_dir/state" "$case_dir/config" "$case_dir/data" "$case_dir/pool" "$case_dir/home/state"
  make_fakebin "$case_dir"
  git init -q --bare "$case_dir/origin.git"
  git -C "$case_dir/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$case_dir/origin.git" "$case_dir/_seed" 2>/dev/null
  git -C "$case_dir/_seed" -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m "origin baseline"
  git -C "$case_dir/_seed" push -q origin main
  rm -rf "$case_dir/_seed"
  git clone -q "$case_dir/origin.git" "$case_dir/project"
  git -C "$case_dir/project" remote set-head origin main 2>/dev/null || true
  local i w
  for ((i = 1; i <= slots; i++)); do
    w=$(cd "$case_dir/project" && TREEHOUSE_ROOT="$case_dir/pool" treehouse get --lease --no-fetch 2>/dev/null) \
      || { echo "make_case: treehouse get failed" >&2; return 1; }
    printf '%s\n' "$w" > "$case_dir/slot$i.path"
  done
  touch "$case_dir/state/.last-watcher-beat"
  printf '%s\n' "$case_dir"
}

# Land files on a slot: commit <size> MiB of payload on a task branch and push it
# to origin's default branch, so the copy is genuine landed work. Args:
# <case-dir> <slot-path> <task-id> <size-mib> <file>
land_slot() {
  local case_dir=$1 wt=$2 id=$3 mib=$4 file=$5
  (
    cd "$wt" || exit 1
    git fetch -q origin || exit 1
    git checkout -q -B "fm/$id" origin/main || exit 1
    head -c "$((mib * 1048576))" /dev/urandom > "$file" || exit 1
    git add -- "$file" || exit 1
    git -c user.email=t@t -c user.name=t commit -q -m "landed work for $id" || exit 1
    git push -q origin "HEAD:main" || exit 1
  ) || return 1
  git -C "$case_dir/project" fetch -q origin
}

write_task_meta() {  # <case-dir> <task-id> <slot-path> [extra key=val...]
  local case_dir=$1 id=$2 wt=$3
  shift 3
  {
    printf 'window=firstmate:fm-%s\n' "$id"
    printf 'endpoint_task_id=%s\n' "$id"
    printf 'worktree=%s\n' "$wt"
    printf 'project=%s\n' "$case_dir/project"
    printf 'kind=ship\n'
    printf 'mode=local-only\n'
    printf "spawn_gen=live-pool-prune-%s\n" "$id"
    local kv
    for kv in "$@"; do printf '%s\n' "$kv"; done
  } > "$case_dir/state/$id.meta"
}

snapshot_pool() {  # <case-dir> <label>  -> writes <label>.du / <label>.status
  local case_dir=$1 label=$2
  du -sh "$case_dir/pool" > "$case_dir/$label.du" 2>&1
  du -sk "$case_dir/pool" | cut -f1 > "$case_dir/$label.kb"
  ( cd "$case_dir/project" && TREEHOUSE_ROOT="$case_dir/pool" treehouse status ) \
    > "$case_dir/$label.status" 2>&1
}

run_teardown_live() {  # <case-dir> <task-id> <out-prefix>
  local case_dir=$1 id=$2 prefix=$3 rc
  FM_ROOT_OVERRIDE="$WT_ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_DATA_OVERRIDE="$case_dir/data" \
  FM_CONFIG_OVERRIDE="$case_dir/config" \
  FM_GATE_REFUSE_BYPASS=1 \
  FM_HOME="$case_dir/home" \
  TREEHOUSE_ROOT="$case_dir/pool" \
  PATH="$case_dir/fakebin:$PATH" \
    "$TEARDOWN" "$id" > "$case_dir/$prefix.stdout" 2> "$case_dir/$prefix.stderr"
  rc=$?
  printf '%s\n' "$rc"
}

# --- scenarios -------------------------------------------------------------

scenario_accumulated_backlog_is_reclaimed() {
  local case_dir s1 s2 s3 s4 rc
  case_dir=$(make_case accumulated-backlog 4) || { fail "sandbox setup"; return; }
  s1=$(cat "$case_dir/slot1.path"); s2=$(cat "$case_dir/slot2.path")
  s3=$(cat "$case_dir/slot3.path"); s4=$(cat "$case_dir/slot4.path")
  land_slot "$case_dir" "$s1" task-x1 16 alpha.bin   || { fail "land x1"; return; }
  land_slot "$case_dir" "$s2" task-old1 16 bravo.bin || { fail "land old1"; return; }
  land_slot "$case_dir" "$s3" task-old2 16 charlie.bin || { fail "land old2"; return; }
  # Slots 2 and 3 are copies earlier closes returned to the pool before this
  # change existed: landed, unleased, and stale - exactly the accumulation the
  # captain had to prune by hand.
  ( cd "$case_dir/project" && TREEHOUSE_ROOT="$case_dir/pool" treehouse return --force "$s2" >/dev/null 2>&1 )     || { fail "return old1"; return; }
  ( cd "$case_dir/project" && TREEHOUSE_ROOT="$case_dir/pool" treehouse return --force "$s3" >/dev/null 2>&1 )     || { fail "return old2"; return; }
  printf 'in use and dirty\n' > "$s4/scratch.txt"
  write_task_meta "$case_dir" task-x1 "$s1"
  snapshot_pool "$case_dir" before
  rc=$(run_teardown_live "$case_dir" task-x1 t1)
  snapshot_pool "$case_dir" after

  {
    echo "== case: $case_dir"
    echo "== slot1(task-x1, landed, closed now): $s1"
    echo "== slot2/slot3(landed copies returned by earlier closes, still in the pool):"
    echo "   $s2"
    echo "   $s3"
    echo "== slot4(in use, leased+dirty): $s4"
    echo "== teardown exit: $rc"
    echo "== before"; cat "$case_dir/before.du"; cat "$case_dir/before.status"
    echo "== stdout"; cat "$case_dir/t1.stdout"
    echo "== stderr"; cat "$case_dir/t1.stderr"
    echo "== after"; cat "$case_dir/after.du"; cat "$case_dir/after.status"
    echo "== slot1/2/3 exist: $([ -e "$s1" ] && echo yes || echo no)/$([ -e "$s2" ] && echo yes || echo no)/$([ -e "$s3" ] && echo yes || echo no)"
    echo "== slot4 exists: $([ -e "$s4" ] && echo yes || echo no), scratch intact: $([ -f "$s4/scratch.txt" ] && echo yes || echo no)"
  } > "$case_dir/report.txt"

  [ "$rc" = 0 ] || fail "the close over an accumulated backlog exited $rc"
  grep -Fq 'freed' "$case_dir/t1.stdout" || fail "no reclaimed amount reported"
  grep -Eq '\(3 copies\)' "$case_dir/t1.stdout" || fail "the accumulated copies were not reported as 3 copies"
  [ ! -e "$s1" ] || fail "the closed task's copy is still in the pool"
  [ ! -e "$s2" ] || fail "a previously returned stale copy is still in the pool"
  [ ! -e "$s3" ] || fail "a previously returned stale copy is still in the pool"
  [ -e "$s4" ] && [ -f "$s4/scratch.txt" ] || fail "the in-use copy was destroyed"
  cp "$case_dir/report.txt" "$EVID/scenario-accumulated-backlog-reclaimed.txt"
  pass "one close reclaimed the accumulated backlog (3 stale copies) and left the in-use copy"
}

scenario_closing_two_landed_tasks() {
  local case_dir s1 s2 s3 rc1 rc2
  case_dir=$(make_case two-landed-tasks 3) || { fail "sandbox setup"; return; }
  s1=$(cat "$case_dir/slot1.path"); s2=$(cat "$case_dir/slot2.path"); s3=$(cat "$case_dir/slot3.path")
  land_slot "$case_dir" "$s1" task-x1 64 alpha.bin || { fail "land x1"; return; }
  land_slot "$case_dir" "$s2" task-x2 32 beta.bin  || { fail "land x2"; return; }
  # A copy another task is actively using: leased and dirty. Prune must skip it.
  printf 'in use and dirty\n' > "$s3/scratch.txt"
  write_task_meta "$case_dir" task-x1 "$s1"
  write_task_meta "$case_dir" task-x2 "$s2"
  snapshot_pool "$case_dir" before
  rc1=$(run_teardown_live "$case_dir" task-x1 t1)
  snapshot_pool "$case_dir" after1
  rc2=$(run_teardown_live "$case_dir" task-x2 t2)
  snapshot_pool "$case_dir" after2

  {
    echo "== case: $case_dir"
    echo "== pool: $case_dir/pool (real treehouse $(treehouse --version 2>/dev/null))"
    echo "== slot1(task-x1, 64MiB landed): $s1"
    echo "== slot2(task-x2, 32MiB landed): $s2"
    echo "== slot3(bystander, leased+dirty): $s3"
    echo
    echo "== before"; cat "$case_dir/before.du"; cat "$case_dir/before.status"
    echo "== teardown task-x1 (exit $rc1) stdout"; cat "$case_dir/t1.stdout"
    echo "== teardown task-x1 stderr"; cat "$case_dir/t1.stderr"
    echo "== after task-x1"; cat "$case_dir/after1.du"; cat "$case_dir/after1.status"
    echo "== teardown task-x2 (exit $rc2) stdout"; cat "$case_dir/t2.stdout"
    echo "== teardown task-x2 stderr"; cat "$case_dir/t2.stderr"
    echo "== after task-x2"; cat "$case_dir/after2.du"; cat "$case_dir/after2.status"
    echo
    echo "== slot1 exists: $([ -e "$s1" ] && echo yes || echo no)"
    echo "== slot2 exists: $([ -e "$s2" ] && echo yes || echo no)"
    echo "== slot3 exists: $([ -e "$s3" ] && echo yes || echo no)"
    echo "== slot3 scratch intact: $([ -f "$s3/scratch.txt" ] && echo yes || echo no)"
    echo "== task-x1 record exists: $([ -e "$case_dir/state/task-x1.meta" ] && echo yes || echo no)"
    echo "== task-x2 record exists: $([ -e "$case_dir/state/task-x2.meta" ] && echo yes || echo no)"
  } > "$case_dir/report.txt"

  [ "$rc1" = 0 ] || fail "close task-x1 exited $rc1"
  [ "$rc2" = 0 ] || fail "close task-x2 exited $rc2"
  grep -Fq 'pool prune for the worktree pool freed' "$case_dir/t1.stdout" || fail "task-x1 close did not report a freed pool copy"
  grep -Fq 'pool prune for the worktree pool freed' "$case_dir/t2.stdout" || fail "task-x2 close did not report a freed pool copy"
  grep -Fq 'pool prune freed' "$case_dir/t1.stdout" || fail "task-x1 completion line lacks the freed amount"
  grep -Fq 'pool prune freed' "$case_dir/t2.stdout" || fail "task-x2 completion line lacks the freed amount"
  [ ! -e "$s1" ] || fail "task-x1's returned copy is still in the pool"
  [ ! -e "$s2" ] || fail "task-x2's returned copy is still in the pool"
  [ -e "$s3" ] || fail "the in-use copy was destroyed by the prune"
  [ -f "$s3/scratch.txt" ] || fail "the in-use copy's uncommitted work was destroyed"
  grep -Fq "$s3" "$case_dir/after2.status" || fail "the in-use copy vanished from the pool listing"
  grep -Fq "$s1" "$case_dir/after2.status" && fail "task-x1's returned copy is still listed in the pool"
  grep -Fq "$s2" "$case_dir/after2.status" && fail "task-x2's returned copy is still listed in the pool"
  [ ! -e "$case_dir/state/task-x1.meta" ] || fail "task-x1's record survived the close"
  [ ! -e "$case_dir/state/task-x2.meta" ] || fail "task-x2's record survived the close"
  # Pool must be back to the single in-use copy: no per-task accumulation.
  local before_kb after_kb
  before_kb=$(cat "$case_dir/before.kb")
  after_kb=$(cat "$case_dir/after2.kb")
  # before had both landed copies + bystander; after has only the bystander.
  [ "$after_kb" -lt "$before_kb" ] || fail "the pool did not shrink after two closes (before=${before_kb}KiB after=${after_kb}KiB)"
  cp "$case_dir/report.txt" "$EVID/scenario-closing-two-landed-tasks.txt"
  cp "$case_dir/t1.stdout" "$EVID/scenario-close-task-x1.stdout"
  cp "$case_dir/t1.stderr" "$EVID/scenario-close-task-x1.stderr"
  cp "$case_dir/t2.stdout" "$EVID/scenario-close-task-x2.stdout"
  cp "$case_dir/t2.stderr" "$EVID/scenario-close-task-x2.stderr"
  pass "two landed closes each pruned their returned copy and reported the freed disk; the in-use copy survived"
}

scenario_unlanded_refusal_does_not_prune() {
  local case_dir s1 s2 rc
  case_dir=$(make_case unlanded-refusal 2) || { fail "sandbox setup"; return; }
  s1=$(cat "$case_dir/slot1.path"); s2=$(cat "$case_dir/slot2.path")
  (
    cd "$s1" || exit 1
    git checkout -q -b fm/task-x1 || exit 1
    printf 'work that never landed\n' > unlanded.txt
    git add unlanded.txt
    git -c user.email=t@t -c user.name=t commit -q -m "unlanded work"
  ) || { fail "unlanded setup"; return; }
  printf 'other task copy\n' > "$s2/scratch.txt"
  write_task_meta "$case_dir" task-x1 "$s1"
  snapshot_pool "$case_dir" before
  rc=$(run_teardown_live "$case_dir" task-x1 t1)
  snapshot_pool "$case_dir" after

  {
    echo "== case: $case_dir"
    echo "== slot1(task-x1, unlanded unpushed commit): $s1"
    echo "== teardown exit: $rc"
    echo "== stdout"; cat "$case_dir/t1.stdout"
    echo "== stderr"; cat "$case_dir/t1.stderr"
    echo "== slot1 exists: $([ -e "$s1" ] && echo yes || echo no)"
    echo "== slot1 still leased:"; cat "$case_dir/after.status"
    echo "== task-x1 record exists: $([ -e "$case_dir/state/task-x1.meta" ] && echo yes || echo no)"
  } > "$case_dir/report.txt"

  [ "$rc" = 1 ] || fail "unlanded close did not refuse (exit $rc)"
  grep -Fq 'REFUSED' "$case_dir/t1.stderr" || fail "unlanded close printed no refusal"
  grep -Fq 'pool prune' "$case_dir/t1.stdout" "$case_dir/t1.stderr" 2>/dev/null && fail "the pool was pruned without an accepted return"
  [ -e "$s1" ] || fail "the refused task's copy was pruned anyway"
  grep -Fq "$s1" "$case_dir/after.status" || fail "the refused task's copy is no longer leased"
  [ -e "$case_dir/state/task-x1.meta" ] || fail "the refused task's record was removed"
  cp "$case_dir/report.txt" "$EVID/scenario-unlanded-refusal-no-prune.txt"
  pass "an unlanded close refused and pruned nothing"
}

scenario_reassigned_slot_left_untouched() {
  local case_dir s1 s2 rc slot_dir
  case_dir=$(make_case reassigned-slot 2) || { fail "sandbox setup"; return; }
  s1=$(cat "$case_dir/slot1.path"); s2=$(cat "$case_dir/slot2.path")
  land_slot "$case_dir" "$s1" task-x1 16 alpha.bin || { fail "land x1"; return; }
  # The real slot-owner claim for the slot says another task now holds it.
  slot_dir=$(dirname "$s1")
  printf 'task=task-other\nhome=/tmp/other-home\n' > "$slot_dir/.fm-slot-owner"
  write_task_meta "$case_dir" task-x1 "$s1"
  snapshot_pool "$case_dir" before
  rc=$(run_teardown_live "$case_dir" task-x1 t1)
  snapshot_pool "$case_dir" after

  {
    echo "== case: $case_dir"
    echo "== slot1(task-x1 record, but claimed by task-other): $s1"
    echo "== teardown exit: $rc"
    echo "== stdout"; cat "$case_dir/t1.stdout"
    echo "== stderr"; cat "$case_dir/t1.stderr"
    echo "== slot1 exists: $([ -e "$s1" ] && echo yes || echo no)"
    echo "== slot1 still leased:"; cat "$case_dir/after.status"
    echo "== task-x1 record exists: $([ -e "$case_dir/state/task-x1.meta" ] && echo yes || echo no)"
  } > "$case_dir/report.txt"

  [ "$rc" = 0 ] || fail "reassigned-slot close exited $rc"
  grep -Fq 'left to task task-other' "$case_dir/t1.stdout" || fail "close did not report the reassigned slot"
  grep -Fq 'pool prune' "$case_dir/t1.stdout" && fail "a reassigned slot triggered a pool prune"
  [ -e "$s1" ] || fail "the reassigned slot was destroyed"
  [ -e "$slot_dir/.fm-slot-owner" ] || fail "the other task's slot claim was stripped"
  [ ! -e "$case_dir/state/task-x1.meta" ] || fail "the record was not cleaned up"
  cp "$case_dir/report.txt" "$EVID/scenario-reassigned-slot-no-prune.txt"
  pass "a slot claimed by another task was left alone and no prune ran"
}

scenario_prune_that_reclaims_nothing_still_completes() {
  local case_dir s1 s2 rc slot_dir
  case_dir=$(make_case prune-reclaims-nothing 2) || { fail "sandbox setup"; return; }
  s1=$(cat "$case_dir/slot1.path"); s2=$(cat "$case_dir/slot2.path")
  land_slot "$case_dir" "$s1" task-x1 16 alpha.bin || { fail "land x1"; return; }
  # Make the returned copy really unremovable for the real treehouse: its slot
  # directory loses write permission, so prune lists it as unsafe and reclaims
  # nothing. The return itself still succeeds (the copy stays writable).
  slot_dir=$(dirname "$s1")
  chmod 555 "$slot_dir"
  write_task_meta "$case_dir" task-x1 "$s1"
  snapshot_pool "$case_dir" before
  rc=$(run_teardown_live "$case_dir" task-x1 t1)
  snapshot_pool "$case_dir" after
  chmod 755 "$slot_dir" 2>/dev/null || true

  {
    echo "== case: $case_dir"
    echo "== slot1(task-x1, landed, but its slot dir is unwritable so treehouse cannot remove it)"
    echo "== teardown exit: $rc"
    echo "== stdout"; cat "$case_dir/t1.stdout"
    echo "== stderr"; cat "$case_dir/t1.stderr"
    echo "== slot1 exists: $([ -e "$s1" ] && echo yes || echo no)"
    echo "== task-x1 record exists: $([ -e "$case_dir/state/task-x1.meta" ] && echo yes || echo no)"
  } > "$case_dir/report.txt"

  [ "$rc" = 0 ] || fail "a non-reclaiming prune failed the close (exit $rc)"
  grep -Fq 'teardown task-x1 complete' "$case_dir/t1.stdout" || fail "the close did not complete"
  [ ! -e "$case_dir/state/task-x1.meta" ] || fail "the record survived the close"
  grep -Fq 'pool prune' "$case_dir/t1.stdout" || fail "the non-reclaiming prune was not reported"
  cp "$case_dir/report.txt" "$EVID/scenario-prune-reclaims-nothing-still-completes.txt"
  pass "a real prune that reclaimed nothing was reported honestly and the close still completed"
}

echo "=== live pool-prune drive against treehouse $(treehouse --version 2>/dev/null)"
echo "=== evidence dir: $EVID"
scenario_accumulated_backlog_is_reclaimed
scenario_closing_two_landed_tasks
scenario_unlanded_refusal_does_not_prune
scenario_reassigned_slot_left_untouched
scenario_prune_that_reclaims_nothing_still_completes
echo
if [ "$FAILED" = 0 ]; then echo "ALL SCENARIOS PASSED"; else echo "SCENARIO FAILURES PRESENT"; fi
exit "$FAILED"
