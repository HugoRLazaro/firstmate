#!/usr/bin/env bash
# shellcheck disable=SC1091
# Behavior tests for bin/fm-merge-bg.sh, the one-call path that hands a
# captain-authorized PR merge to the background and returns at once.
#
# Every run uses a throwaway firstmate home (FM_HOME, also the code root through
# FM_ROOT_OVERRIDE) with stub arm and background scripts, so no real state,
# forge, or watcher is touched.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HELPER="$ROOT/bin/fm-merge-bg.sh"
PR_URL=https://github.com/example/repo/pull/7

# now_ms prints a millisecond timestamp; BSD date lacks %N, so it falls back to
# whole seconds there.
now_ms() {
  local stamp
  stamp=$(date +%s%N 2>/dev/null)
  case "$stamp" in
    *N*|"") echo $(( $(date +%s) * 1000 )) ;;
    *) echo $(( stamp / 1000000 )) ;;
  esac
}

# new_home prints a home with a recording arm stub and a background stub that
# writes its own pid, then becomes a long sleep that the test kills by that pid.
new_home() {
  local home
  home=$(fm_test_tmproot fm-merge-bg)/home || return 1
  mkdir -p "$home/bin" "$home/data" "$home/state" || return 1
  cat > "$home/bin/fm-pr-check.sh" <<EOF
#!/usr/bin/env bash
echo "armed \$*" >> "$home/state/arm.calls"
EOF
  cat > "$home/data/fusion-en-segundo-plano.sh" <<EOF
#!/usr/bin/env bash
echo \$\$ > "$home/state/bg.pid"
echo "bg started \$*"
exec sleep 30
EOF
  chmod +x "$home/bin/fm-pr-check.sh" "$home/data/fusion-en-segundo-plano.sh" || return 1
  printf '%s\n' "$home"
}

test_refuses_without_background_script() {
  local home out rc
  home=$(new_home) || fail "could not build the test home"
  rm -f "$home/data/fusion-en-segundo-plano.sh"
  out=$(FM_HOME="$home" "$HELPER" task-a "$PR_URL" 2>&1)
  rc=$?
  [ "$rc" -eq 3 ] || fail "missing background script must exit 3, got $rc: $out"
  case "$out" in
    *"falta"*"fusion-en-segundo-plano.sh"*) : ;;
    *) fail "missing background script must be named clearly: $out" ;;
  esac
  [ ! -e "$home/state/arm.calls" ] || fail "nothing may be armed when the background script is missing"
  pass "refuses with a clear message and arms nothing when the background script is missing"
}

test_refuses_bad_arguments_before_arming() {
  local home out rc
  home=$(new_home) || fail "could not build the test home"
  out=$(FM_HOME="$home" "$HELPER" task-a https://example.com/not-a-pr 2>&1)
  rc=$?
  [ "$rc" -eq 2 ] || fail "a non-PR URL must exit 2, got $rc: $out"
  out=$(FM_HOME="$home" "$HELPER" ../escape "$PR_URL" 2>&1)
  rc=$?
  [ "$rc" -eq 2 ] || fail "a path-like task id must exit 2, got $rc: $out"
  [ ! -e "$home/state/arm.calls" ] || fail "bad arguments must not arm anything"
  pass "refuses a non-PR URL and a path-like task id before arming"
}

test_returns_at_once_and_records_the_launch() {
  local home start end ms out rc i pid
  home=$(new_home) || fail "could not build the test home"
  start=$(now_ms)
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$home" "$HELPER" task-a "$PR_URL" 2>&1)
  rc=$?
  end=$(now_ms)
  [ "$rc" -eq 0 ] || fail "launch must exit 0, got $rc: $out"
  ms=$(( end - start ))
  [ "$ms" -lt 2000 ] || fail "launch must return in under 2 s, took ${ms} ms"
  case "$out" in
    lanzado:*) : ;;
    *) fail "launch must print one line naming what it started: $out" ;;
  esac
  grep -qx "armed task-a $PR_URL" "$home/state/arm.calls" \
    || fail "launch must arm the PR watch with the task id and URL"
  grep -q "lanzado por fm-merge-bg: task-a $PR_URL" "$home/state/task-a.merge-bg.log" \
    || fail "launch must record itself in the task's merge log"
  for i in $(seq 50); do
    [ -s "$home/state/bg.pid" ] && break
    sleep 0.1
  done
  [ -s "$home/state/bg.pid" ] || fail "the detached background script never started"
  pid=$(cat "$home/state/bg.pid")
  kill -0 "$pid" 2>/dev/null || fail "the background merge must outlive the launch call"
  kill "$pid" 2>/dev/null || true
  pass "launch arms, detaches the background merge, returns in ${ms} ms, and records the launch"
}

test_refuses_without_background_script
test_refuses_bad_arguments_before_arming
test_returns_at_once_and_records_the_launch
