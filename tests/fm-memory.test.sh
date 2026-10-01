#!/usr/bin/env bash
# Tests for bin/fm-memory.sh and the launch floor bin/fm-spawn.sh and
# bin/fm-control.sh ask it for.
#
# On 2026-10-01 a 16 GB host ran out of memory twice in one night and took every
# live worker down with it: jobs the workers had started held 12.8 GB, and
# nothing refused the next launch or told firstmate the host was filling up.
# These cases pin the three behaviors that would have changed that night: a
# launch under the floor is refused before anything is created, firstmate is
# told once per episode, and a heavy job can be run under a cap of its own.
#
# Every case supplies its own reading through FM_MEMINFO_PATH, so no verdict
# here depends on how busy the machine running the suite is.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

MEMORY="$ROOT/bin/fm-memory.sh"
CHECKPOINT="$ROOT/bin/fm-watch-checkpoint.sh"
TMP_ROOT=$(fm_test_tmproot fm-memory)

make_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/config" "$home/data"
  printf '%s\n' "$home"
}

# write_meminfo <file> <available-MB> <swap-free-MB> [swap-total-MB]
write_meminfo() {
  local file=$1 available=$2 swap_free=$3 swap_total=${4:-4096}
  printf '%s\n' \
    'MemTotal:       16374424 kB' \
    'MemFree:          200000 kB' \
    "MemAvailable:   $((available * 1024)) kB" \
    "SwapTotal:      $((swap_total * 1024)) kB" \
    "SwapFree:       $((swap_free * 1024)) kB" > "$file"
}

run_memory() { # <home> <meminfo> <action...>
  local home=$1 meminfo=$2
  shift 2
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" FM_MEMINFO_PATH="$meminfo" "$MEMORY" "$@"
}

# --- guard ------------------------------------------------------------------

test_guard_allows_a_host_above_its_floors() {
  local home out status=0
  home=$(make_home guard-ok)
  write_meminfo "$home/meminfo" 6000 3000
  out=$(run_memory "$home" "$home/meminfo" guard 2>&1) || status=$?
  expect_code 0 "$status" "guard on a healthy host"
  assert_equals "" "$out" "a healthy host should pass the guard silently"
  pass "guard is silent and allows the launch on a host above both floors"
}

test_guard_refuses_under_the_available_floor() {
  local home out status=0
  home=$(make_home guard-low)
  write_meminfo "$home/meminfo" 900 3000
  out=$(run_memory "$home" "$home/meminfo" guard 2>&1) || status=$?
  expect_code 3 "$status" "guard under the available floor"
  assert_contains "$out" "900 MB of memory available" "the refusal should state the reading"
  assert_contains "$out" "2048 MB launch floor" "the refusal should state the floor"
  assert_contains "$out" "FM_MEMORY_GUARD=off" "the refusal should name the override"
  pass "guard refuses under the available floor and names the reading, the floor, and the override"
}

test_guard_refuses_when_swap_is_nearly_gone() {
  local home out status=0
  home=$(make_home guard-swap)
  write_meminfo "$home/meminfo" 6000 100
  out=$(run_memory "$home" "$home/meminfo" guard 2>&1) || status=$?
  expect_code 3 "$status" "guard with swap nearly exhausted"
  assert_contains "$out" "100 MB of swap free of 4096 MB" "the refusal should state the swap reading"
  assert_contains "$out" "512 MB launch floor" "the refusal should state the swap floor"

  # A host with no swap at all has nothing to exhaust: zero free of zero is
  # not a low reading.
  write_meminfo "$home/meminfo" 6000 0 0
  status=0
  out=$(run_memory "$home" "$home/meminfo" guard 2>&1) || status=$?
  expect_code 0 "$status" "guard on a host without swap"
  pass "guard refuses when swap is nearly exhausted, and never on a host that has no swap"
}

test_guard_reads_the_configured_floors() {
  local home out status=0
  home=$(make_home guard-config)
  write_meminfo "$home/meminfo" 900 100
  printf '%s\n' '# this host is small' 'spawn_available_mb=512' 'spawn_swap_free_mb = 0' \
    > "$home/config/memory-floor"
  out=$(run_memory "$home" "$home/meminfo" guard 2>&1) || status=$?
  expect_code 0 "$status" "guard under lowered floors: $out"

  printf '%s\n' 'spawn_available_mb=8000' > "$home/config/memory-floor"
  status=0
  out=$(run_memory "$home" "$home/meminfo" guard 2>&1) || status=$?
  expect_code 3 "$status" "guard under a raised floor"
  assert_contains "$out" "8000 MB launch floor" "the refusal should state the configured floor"
  pass "guard judges the reading against config/memory-floor, and 0 turns one floor off"
}

test_a_malformed_floor_warns_and_uses_the_default() {
  local home out status=0
  home=$(make_home guard-badconfig)
  write_meminfo "$home/meminfo" 6000 3000
  printf '%s\n' 'spawn_available_mb=2GB' 'no_such_floor=5' 'nonsense' > "$home/config/memory-floor"
  out=$(run_memory "$home" "$home/meminfo" guard 2>&1) || status=$?
  expect_code 0 "$status" "a malformed floor must not refuse a launch on a healthy host"
  assert_contains "$out" 'ignoring "spawn_available_mb=2GB"' "the bad value should be named"
  assert_contains "$out" 'unknown key "no_such_floor"' "the unknown key should be named"

  # The default still applies: the bad line did not turn the floor off.
  write_meminfo "$home/meminfo" 900 3000
  status=0
  out=$(run_memory "$home" "$home/meminfo" guard 2>&1) || status=$?
  expect_code 3 "$status" "the default floor should still apply under a malformed config"
  assert_contains "$out" "2048 MB launch floor" "the default floor should be the one enforced"
  pass "a malformed floor is named, never refuses a launch by itself, and leaves the default in force"
}

test_an_unreadable_reading_warns_and_allows() {
  local home out status label
  home=$(make_home guard-unreadable)
  # Each shape is a reading that exists but cannot be trusted.
  printf '%s\n' 'MemTotal: 16374424 kB' 'SwapTotal: 4194304 kB' 'SwapFree: 4194304 kB' > "$home/no-available"
  printf '%s\n' 'MemAvailable: lots kB' 'SwapTotal: 4194304 kB' 'SwapFree: 4194304 kB' > "$home/not-a-number"
  printf '%s\n' 'MemAvailable: 900 MB' 'SwapTotal: 4194304 kB' 'SwapFree: 4194304 kB' > "$home/wrong-unit"
  printf '%s\n' 'MemAvailable: 900000 kB' 'MemAvailable: 9000000 kB' > "$home/twice"
  printf '%s\n' 'MemAvailable: 900000 kB' 'SwapTotal: 4194304 kB' > "$home/half-swap"
  : > "$home/empty"
  mkdir -p "$home/a-directory"
  for label in no-available not-a-number wrong-unit twice half-swap empty a-directory missing; do
    status=0
    out=$(run_memory "$home" "$home/$label" guard 2>&1) || status=$?
    expect_code 0 "$status" "an unreadable reading ($label) must not refuse a launch"
    assert_contains "$out" "memory could not be read" "an unreadable reading ($label) should warn"
    assert_contains "$out" "launching without the memory floor" "the warning ($label) should say the launch continues"
  done
  pass "a missing, empty, malformed, or ambiguous reading warns and lets the launch continue"
}

test_the_override_skips_the_floor_and_says_so() {
  local home out status=0
  home=$(make_home guard-override)
  write_meminfo "$home/meminfo" 100 0
  out=$(FM_MEMORY_GUARD=off run_memory "$home" "$home/meminfo" guard 2>&1) || status=$?
  expect_code 0 "$status" "the explicit override"
  assert_contains "$out" "launch floor skipped (FM_MEMORY_GUARD=off)" "the override should be visible"
  pass "FM_MEMORY_GUARD=off launches under the floor and says the floor was skipped"
}

# --- the launch itself ------------------------------------------------------

make_spawn_case() { # <name> <id>
  local name=$1 id=$2 case_dir home
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  FAKEBIN_DIR=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" codex
  fm_git_worktree "$case_dir/project" "$case_dir/wt" "wt-$name"
  fm_test_spawn_brief "$home" "$id"
  HOME_DIR=$home
  PROJ_DIR="$case_dir/project"
  WT_DIR="$case_dir/wt"
  LAUNCH_LOG="$case_dir/launch.log"
  : > "$LAUNCH_LOG"
}

test_spawn_refuses_under_the_floor_before_creating_anything() {
  local out status=0
  make_spawn_case spawn-low ship-low-a1
  write_meminfo "$HOME_DIR/meminfo" 900 3000
  out=$(FM_MEMINFO_PATH="$HOME_DIR/meminfo" FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" ship-low-a1 "$PROJ_DIR" --mode no-mistakes --yolo off) \
    || status=$?
  expect_code 1 "$status" "a ship spawn under the memory floor"
  assert_contains "$out" "launch refused" "the spawn should relay the refusal"
  assert_contains "$out" "900 MB of memory available" "the spawn refusal should state the reading"
  assert_contains "$out" "2048 MB launch floor" "the spawn refusal should state the floor"
  assert_absent "$HOME_DIR/state/ship-low-a1.meta" "a refused spawn published a task record"
  [ ! -s "$LAUNCH_LOG" ] || fail "a refused spawn still sent a launch command: $(cat "$LAUNCH_LOG")"
  pass "a spawn under the memory floor refuses with the reading and the floor, before any record or launch exists"
}

test_spawn_launches_above_the_floor_and_under_the_override() {
  local out status=0
  make_spawn_case spawn-ok ship-ok-a1
  write_meminfo "$HOME_DIR/meminfo" 6000 3000
  out=$(FM_MEMINFO_PATH="$HOME_DIR/meminfo" FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" ship-ok-a1 "$PROJ_DIR" --mode no-mistakes --yolo off) \
    || status=$?
  expect_code 0 "$status" "a ship spawn above the memory floor: $out"
  [ -s "$LAUNCH_LOG" ] || fail "a healthy spawn sent no launch command"

  make_spawn_case spawn-override ship-over-a1
  write_meminfo "$HOME_DIR/meminfo" 900 3000
  status=0
  out=$(FM_MEMORY_GUARD=off FM_MEMINFO_PATH="$HOME_DIR/meminfo" FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" ship-over-a1 "$PROJ_DIR" --mode no-mistakes --yolo off) \
    || status=$?
  expect_code 0 "$status" "a ship spawn under the floor with the override: $out"
  assert_contains "$out" "launch floor skipped" "the overridden spawn should say the floor was skipped"
  [ -s "$LAUNCH_LOG" ] || fail "an overridden spawn sent no launch command"
  pass "a spawn launches above the floor, and under it only with the explicit override"
}

test_spawn_launches_when_the_reading_is_unreadable() {
  local out status=0
  make_spawn_case spawn-unreadable ship-unr-a1
  printf 'MemAvailable: lots kB\n' > "$HOME_DIR/meminfo"
  out=$(FM_MEMINFO_PATH="$HOME_DIR/meminfo" FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" ship-unr-a1 "$PROJ_DIR" --mode no-mistakes --yolo off) \
    || status=$?
  expect_code 0 "$status" "a ship spawn with an unreadable memory reading: $out"
  assert_contains "$out" "memory could not be read" "the spawn should warn about the unreadable reading"
  [ -s "$LAUNCH_LOG" ] || fail "a spawn with an unreadable reading sent no launch command"
  pass "a spawn with an unreadable memory reading warns and still launches"
}

test_scout_and_secondmate_spawns_are_guarded_too() {
  local out status sm
  make_spawn_case spawn-scout scout-low-a1
  write_meminfo "$HOME_DIR/meminfo" 900 3000
  status=0
  out=$(FM_MEMINFO_PATH="$HOME_DIR/meminfo" FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" scout-low-a1 "$PROJ_DIR" --scout) || status=$?
  expect_code 1 "$status" "a scout spawn under the memory floor"
  assert_contains "$out" "launch refused" "the scout spawn should relay the refusal"

  make_spawn_case spawn-sm sm-low
  write_meminfo "$HOME_DIR/meminfo" 900 3000
  sm="$TMP_ROOT/spawn-sm/secondmate-home"
  mkdir -p "$sm/bin" "$sm/data"
  printf '# Firstmate\n' > "$sm/AGENTS.md"
  printf 'sm-low\n' > "$sm/.fm-secondmate-home"
  printf 'charter for sm-low\n' > "$sm/data/charter.md"
  status=0
  out=$(FM_MEMINFO_PATH="$HOME_DIR/meminfo" FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" sm-low "$sm" --secondmate) || status=$?
  expect_code 1 "$status" "a secondmate spawn under the memory floor"
  assert_contains "$out" "launch refused" "the secondmate spawn should relay the refusal"
  [ ! -s "$LAUNCH_LOG" ] || fail "a refused secondmate spawn still sent a launch command"
  pass "scout and secondmate launches on this host are refused under the floor like a ship launch"
}

test_relaunch_refuses_under_the_floor_before_touching_the_agent() {
  local out status=0 meta_before
  make_spawn_case relaunch-low ship-rel-a1
  write_meminfo "$HOME_DIR/meminfo" 6000 3000
  out=$(FM_MEMINFO_PATH="$HOME_DIR/meminfo" FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" ship-rel-a1 "$PROJ_DIR" --mode no-mistakes --yolo off) \
    || fail "relaunch setup spawn failed: $out"
  meta_before=$(cat "$HOME_DIR/state/ship-rel-a1.meta")
  : > "$LAUNCH_LOG"

  write_meminfo "$HOME_DIR/meminfo" 900 3000
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" HOME="$HOME_DIR/user-home" CLAUDE_CONFIG_DIR='' \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_FAKE_PANE_PATH="$WT_DIR" FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" TMUX="${TMUX:-fake,1,0}" \
    FM_MEMINFO_PATH="$HOME_DIR/meminfo" PATH="$FAKEBIN_DIR:$PATH" \
    "$ROOT/bin/fm-control.sh" ship-rel-a1 relaunch --note "carry on" 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "a relaunch under the memory floor should refuse: $out"
  assert_contains "$out" "under its memory floor" "the relaunch refusal should name the memory floor"
  assert_contains "$out" "900 MB of memory available" "the relaunch refusal should state the reading"
  assert_contains "$out" "before its agent was touched" "the relaunch refusal should say nothing was stopped"
  assert_equals "$meta_before" "$(cat "$HOME_DIR/state/ship-rel-a1.meta")" \
    "a refused relaunch changed the task's durable record"
  [ ! -s "$LAUNCH_LOG" ] || fail "a refused relaunch still sent a launch command"
  pass "a relaunch under the memory floor refuses before the running agent is touched"
}

# --- check ------------------------------------------------------------------

test_check_reports_once_per_episode() {
  local home out
  home=$(make_home check-episode)
  write_meminfo "$home/meminfo" 6000 3000
  out=$(run_memory "$home" "$home/meminfo" check 2>&1)
  assert_equals "" "$out" "a healthy host should produce no report"
  assert_absent "$home/state/.memory-low" "a healthy host opened an episode"

  write_meminfo "$home/meminfo" 1000 200
  out=$(run_memory "$home" "$home/meminfo" check 2>&1)
  assert_contains "$out" "memory low: 1000 MB available, under the 1536 MB floor" "the first low reading should be reported"
  assert_contains "$out" "SwapFree 200 MB of 4096 MB" "the report should carry the swap reading"
  assert_equals 1 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "the report must be exactly one line"
  assert_present "$home/state/.memory-low" "the reported episode was not recorded"

  # Still low, and lower: the same episode, so nothing more is said.
  write_meminfo "$home/meminfo" 400 0
  out=$(run_memory "$home" "$home/meminfo" check 2>&1)
  assert_equals "" "$out" "an episode already reported must not be reported again"

  # Back above the floor but inside the recovery margin: the episode is not
  # over, so a dip straight back under must stay silent.
  write_meminfo "$home/meminfo" 1700 3000
  out=$(run_memory "$home" "$home/meminfo" check 2>&1)
  assert_equals "" "$out" "a reading inside the recovery margin should be silent"
  assert_present "$home/state/.memory-low" "the episode closed inside the recovery margin"
  write_meminfo "$home/meminfo" 1000 3000
  out=$(run_memory "$home" "$home/meminfo" check 2>&1)
  assert_equals "" "$out" "a reading hovering at the floor woke firstmate a second time"

  # Recovered past the margin: the episode closes, and the next drop is news.
  write_meminfo "$home/meminfo" 2000 3000
  out=$(run_memory "$home" "$home/meminfo" check 2>&1)
  assert_equals "" "$out" "recovery itself should be silent"
  assert_absent "$home/state/.memory-low" "recovery did not close the episode"
  write_meminfo "$home/meminfo" 1200 3000
  out=$(run_memory "$home" "$home/meminfo" check 2>&1)
  assert_contains "$out" "memory low: 1200 MB available" "a new episode after recovery should be reported"
  pass "check reports a low-memory episode once, stays silent until it has recovered past the margin, then reports the next one"
}

test_check_is_silent_on_an_unreadable_reading() {
  local home out status=0
  home=$(make_home check-unreadable)
  printf 'MemAvailable: lots kB\n' > "$home/meminfo"
  out=$(run_memory "$home" "$home/meminfo" check 2>&1) || status=$?
  expect_code 0 "$status" "check with an unreadable reading"
  assert_equals "" "$out" "an unreadable reading must not wake firstmate"
  assert_absent "$home/state/.memory-low" "an unreadable reading opened an episode"
  pass "check stays silent, and opens no episode, when the reading cannot be trusted"
}

test_check_honours_the_configured_alert_floor() {
  local home out
  home=$(make_home check-config)
  write_meminfo "$home/meminfo" 3000 3000
  printf 'alert_available_mb=4000\n' > "$home/config/memory-floor"
  out=$(run_memory "$home" "$home/meminfo" check 2>&1)
  assert_contains "$out" "under the 4000 MB floor" "the configured alert floor should be the one reported"
  printf 'alert_available_mb=0\n' > "$home/config/memory-floor"
  write_meminfo "$home/meminfo" 10 0
  out=$(run_memory "$home" "$home/meminfo" check 2>&1)
  assert_equals "" "$out" "an alert floor of 0 should turn the report off"
  pass "check uses the configured alert floor, and 0 turns the report off"
}

test_arm_registers_the_check_and_disarm_removes_it() {
  local home status=0
  home=$(make_home arm)
  FM_HOME="$home" "$MEMORY" arm >/dev/null || status=$?
  expect_code 0 "$status" "arm exit"
  assert_present "$home/state/memory.check.sh" "arm did not write the check shim"
  assert_present "$home/state/memory.check-trust" "arm did not register the check's bytes"
  [ "$(stat -c %a "$home/state/memory.check.sh" 2>/dev/null || stat -f %Lp "$home/state/memory.check.sh")" = 700 ] \
    || fail "the check shim is not mode 700"
  FM_HOME="$home" "$MEMORY" arm >/dev/null || fail "arming twice failed"
  assert_grep 'fm-custom-check-v1' "$home/state/memory.check-trust" "re-arming lost the trust binding"

  : > "$home/state/.memory-low"
  FM_HOME="$home" "$MEMORY" disarm >/dev/null || fail "disarm failed"
  assert_absent "$home/state/memory.check.sh" "disarm left the check shim behind"
  assert_absent "$home/state/memory.check-trust" "disarm left the trust binding behind"
  assert_absent "$home/state/.memory-low" "disarm left the episode record behind"
  pass "arm registers a trusted check and disarm removes every trace"
}

test_arm_refuses_a_symlink_at_the_shim_path() {
  local home status=0
  home=$(make_home arm-symlink)
  printf 'untouched\n' > "$home/target"
  ln -s "$home/target" "$home/state/memory.check.sh"
  FM_HOME="$home" "$MEMORY" arm >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "arm over a symlink"
  assert_equals untouched "$(cat "$home/target")" "arm wrote through a symlink at the shim path"
  assert_absent "$home/state/memory.check-trust" "arm registered a symlinked shim"
  pass "arm refuses a symlink at the shim path instead of writing through it"
}

test_armed_check_wakes_the_watcher_once() {
  local home out err status=0
  # End to end through the real watcher: the armed check must reach it as an
  # ordinary `check:` wake carrying the low-memory line.
  home=$(make_home wake)
  write_meminfo "$home/meminfo" 700 50
  FM_HOME="$home" "$MEMORY" arm >/dev/null || fail "could not arm the memory check"
  out="$home/out.txt"
  err="$home/err.txt"
  env FM_HOME="$home" FM_MEMINFO_PATH="$home/meminfo" FM_CHECK_TIMEOUT=30 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=1 \
    "$CHECKPOINT" --seconds 10 >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "watcher checkpoint exit: $(cat "$err")"
  assert_contains "$(cat "$out")" "check:" "the armed check did not reach the watcher as a check wake"
  assert_contains "$(cat "$out")" "memory low: 700 MB available" "the wake did not carry the low-memory report"
  assert_present "$home/state/.memory-low" "the watcher-run check did not record the episode"
  pass "the armed check reaches the watcher as an ordinary check wake"
}

# --- status -----------------------------------------------------------------

test_status_attributes_a_job_to_its_task() {
  local home out pid
  home=$(make_home status)
  write_meminfo "$home/meminfo" 6000 3000
  mkdir -p "$home/data/task-a1/harness" "$home/wt-a1"
  fm_write_meta "$home/state/task-a1.meta" "worktree=$home/wt-a1"
  ( cd "$home/data/task-a1/harness" && exec sleep 300 ) &
  pid=$!
  sleep 0.3
  out=$(run_memory "$home" "$home/meminfo" status 2>&1)
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  assert_contains "$out" "memory: 6000 MB available, swap 3000 MB free of 4096 MB" "status should print the reading"
  assert_contains "$out" "launch 2048 MB available" "status should print the floors"
  printf '%s\n' "$out" | grep -Eq '1 process\(es\)  task-a1$' \
    || fail "status did not attribute the job working in data/task-a1 to that task: $out"
  pass "status prints the reading and the floors and attributes a job to the task whose directory it works in"
}

# --- run --------------------------------------------------------------------

test_run_starts_the_job_in_a_capped_scope() {
  local home fake out status=0
  home=$(make_home run)
  fake="$home/fake-systemd-run"
  cat > "$fake" <<'SH'
#!/bin/sh
# Records how it was asked to run, then runs the command the way the real
# systemd-run --scope does: in place, with the command's own exit status.
printf '%s\n' "$*" >> "$FAKE_SYSTEMD_LOG"
while [ "$#" -gt 0 ] && [ "$1" != -- ]; do shift; done
shift
exec "$@"
SH
  chmod +x "$fake"
  : > "$home/log"
  out=$(cd "$home" && FAKE_SYSTEMD_LOG="$home/log" FM_MEMORY_SYSTEMD_RUN="$fake" \
    run_memory "$home" "$home/meminfo" run --max-mb 300 -- sh -c 'pwd; exit 7' 2>&1) || status=$?
  expect_code 7 "$status" "run should return the job's own exit status"
  assert_equals "$home" "$out" "run should keep the job in the caller's working directory"
  assert_grep 'MemoryMax=300M' "$home/log" "run did not cap the job's memory"
  assert_grep 'MemorySwapMax=0' "$home/log" "run did not keep the job out of swap"
  assert_grep 'user --scope' "$home/log" "run did not use a user scope"

  # Without --max-mb the cap is the configured job_max_mb.
  printf 'job_max_mb=1234\n' > "$home/config/memory-floor"
  : > "$home/log"
  FAKE_SYSTEMD_LOG="$home/log" FM_MEMORY_SYSTEMD_RUN="$fake" \
    run_memory "$home" "$home/meminfo" run -- true || fail "run with the configured cap failed"
  assert_grep 'MemoryMax=1234M' "$home/log" "run did not use the configured job cap"
  pass "run starts the job in a user scope with a memory cap and no swap, in place, with its own exit status"
}

test_run_without_systemd_still_runs_and_says_it_is_uncapped() {
  local home out status=0
  home=$(make_home run-nosystemd)
  out=$(FM_MEMORY_SYSTEMD_RUN="$home/does-not-exist" \
    run_memory "$home" "$home/meminfo" run -- sh -c 'echo ran; exit 4' 2>&1) || status=$?
  expect_code 4 "$status" "run without systemd should still return the job's exit status"
  assert_contains "$out" "ran" "run without systemd did not run the job"
  assert_contains "$out" "runs with no memory cap" "run without systemd should say the job is uncapped"

  status=0
  out=$(run_memory "$home" "$home/meminfo" run --max-mb lots -- true 2>&1) || status=$?
  expect_code 2 "$status" "run with a malformed cap"
  status=0
  out=$(run_memory "$home" "$home/meminfo" run 2>&1) || status=$?
  expect_code 2 "$status" "run with no command"
  pass "run without a systemd user manager still runs the job and says it is uncapped, and refuses a malformed request"
}

# A real cap, where this host can enforce one: the job that outgrows it dies
# alone and the suite keeps running.
test_run_really_kills_a_job_that_outgrows_its_cap() {
  local home out status=0
  home=$(make_home run-real)
  if ! command -v systemd-run >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1 \
    || ! systemd-run --user --scope --quiet --collect -p MemoryMax=64M -- true >/dev/null 2>&1; then
    pass "SKIP: no systemd user manager with memory limits (or no python3) on this host; the real cap is not exercised here"
    return 0
  fi
  out=$(run_memory "$home" "$home/meminfo" run --max-mb 64 -- \
    python3 -c 'a = bytearray(400 * 1024 * 1024); print("survived")' 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "a job that outgrew its 64 MB cap survived: $out"
  assert_not_contains "$out" survived "a job that outgrew its 64 MB cap ran to completion"
  out=$(run_memory "$home" "$home/meminfo" run --max-mb 64 -- sh -c 'echo fits') \
    || fail "a job inside its cap did not run"
  assert_equals fits "$out" "a job inside its cap did not produce its output"
  pass "a job that outgrows its cap is killed by itself, and a job inside the cap runs normally"
}

test_guard_allows_a_host_above_its_floors
test_guard_refuses_under_the_available_floor
test_guard_refuses_when_swap_is_nearly_gone
test_guard_reads_the_configured_floors
test_a_malformed_floor_warns_and_uses_the_default
test_an_unreadable_reading_warns_and_allows
test_the_override_skips_the_floor_and_says_so
test_spawn_refuses_under_the_floor_before_creating_anything
test_spawn_launches_above_the_floor_and_under_the_override
test_spawn_launches_when_the_reading_is_unreadable
test_scout_and_secondmate_spawns_are_guarded_too
test_relaunch_refuses_under_the_floor_before_touching_the_agent
test_check_reports_once_per_episode
test_check_is_silent_on_an_unreadable_reading
test_check_honours_the_configured_alert_floor
test_arm_registers_the_check_and_disarm_removes_it
test_arm_refuses_a_symlink_at_the_shim_path
test_armed_check_wakes_the_watcher_once
test_status_attributes_a_job_to_its_task
test_run_starts_the_job_in_a_capped_scope
test_run_without_systemd_still_runs_and_says_it_is_uncapped
test_run_really_kills_a_job_that_outgrows_its_cap
