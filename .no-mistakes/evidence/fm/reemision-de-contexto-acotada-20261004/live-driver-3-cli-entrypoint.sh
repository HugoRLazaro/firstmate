#!/usr/bin/env bash
# Live CLI driver: the real bin/fm-sessionstart-run.sh entry point that the Pi
# extension invokes, driven by hand against a scratch FM_HOME and a real project
# checkout copy, inside a real live harness ancestry.
set -u

WORKTREE=/home/hugorl/.no-mistakes/worktrees/71308d303441/01M4492JVPA4DRTJY8MHJPPX8G
EVID=/home/hugorl/.no-mistakes/evidence/01M4492JVPA4DRTJY8MHJPPX8G
LAB=${FM_CLI_LAB:-/tmp/fm-reemit-cli.$$}
PROJECT=$LAB/project
HOME_DIR=$LAB/home
NONCE=$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')
WAKE_MARKER="CLI_WAKE_LIVE_MARKER-$NONCE"
SLEEP_MARKER="CLI_AGENTS_$NONCE"
RESULTS=$LAB/results.txt

rm -rf "$LAB"
mkdir -p "$PROJECT" "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/config"
git -C "$WORKTREE" archive HEAD | tar -x -C "$PROJECT"
( cd "$PROJECT" && git init -q -b main . && git config user.email fmtest@example.invalid && git config user.name fmtest && git add -A >/dev/null 2>&1 && git commit -q -m lab ) || exit 1

# Bulky digest fixture.
{
  printf 'CLI_CAPTAIN_MARKER-%s\n' "$NONCE"
  for i in $(seq 1 350); do printf 'captain preference %s: durable memory the bounded re-emit must not reprint.\n' "$i"; done
} > "$HOME_DIR/data/captain.md"
{
  printf 'CLI_LEARNINGS_MARKER-%s\n' "$NONCE"
  for i in $(seq 1 500); do printf 'learning %s: a fleet-local fact the bounded re-emit must not reprint.\n' "$i"; done
} > "$HOME_DIR/data/learnings.md"
printf '%s\n' '## Queued' "- CLI_BACKLOG_MARKER-$NONCE a queued item" > "$HOME_DIR/data/backlog.md"
printf 'kind=ship\n' > "$HOME_DIR/state/task-1.meta"
printf 'working: CLI_STATUS_MARKER-%s\n' "$NONCE" > "$HOME_DIR/state/task-1.status"
FM_STATE_OVERRIDE="$HOME_DIR/state" bash -c '
  # shellcheck disable=SC1091
  . "$1"
  fm_wake_append signal "$2" "$3"
' _ "$WORKTREE/bin/fm-wake-lib.sh" "cli-wake-$NONCE" "$WAKE_MARKER: presented by the bounded re-emit and never cut." || exit 1

run() {  # <label> [env assignments...] -- <args...>
  local label=$1; shift
  local envs=()
  while [ "$1" != "--" ]; do envs+=("$1"); shift; done
  shift
  env -u CLAUDECODE -u GROK_AGENT -u FM_PI_HARNESS \
    PI_CODING_AGENT=true FM_ROOT_OVERRIDE="$PROJECT" FM_HOME="$HOME_DIR" \
    FM_GATE_REFUSE_BYPASS=1 "${envs[@]}" \
    "$PROJECT/bin/fm-sessionstart-run.sh" "$@" > "$LAB/$label.out" 2> "$LAB/$label.err"
  printf '%s' "$?" > "$LAB/$label.rc"
}

check() {  # <name> <condition-description> <0/1 result>
  local name=$1 desc=$2 ok=$3
  if [ "$ok" = 0 ]; then printf 'PASS  %-34s %s\n' "$name" "$desc" >> "$RESULTS"
  else printf 'FAIL  %-34s %s\n' "$name" "$desc" >> "$RESULTS"; fi
}
has() { grep -Fq -- "$1" "$2"; }
hasnt() { ! grep -Fq -- "$1" "$2"; }
budgeted() { printf '%s\n' "$1" | LC_ALL=C awk '
    /^CURRENT AGENTS.md - INSTRUCTION REFRESH$/ { skip = 1 }
    /^BOOTSTRAP$/ { skip = 0 }
    /^WAKE QUEUE$/ { skip = 1 }
    skip && (/^SUPERVISION OPERATING INSTRUCTIONS/ || /^RE-EMIT BUDGET: /) { skip = 0 }
    !skip { bytes += length($0) + 1 }
    END { print bytes + 0 }
  '; }

: > "$RESULTS"
printf 'lab=%s nonce=%s\n' "$LAB" "$NONCE" >> "$RESULTS"

# --- 1. true startup, full digest -------------------------------------------
run startup -- --source startup
printf 'startup rc=%s\n' "$(cat "$LAB/startup.rc")" >> "$RESULTS"
check true-startup-digest "full digest prints the bulky context and fleet-state sources" \
  "$( { has CLI_CAPTAIN_MARKER "$LAB/startup.out" && has CLI_LEARNINGS_MARKER "$LAB/startup.out" && has CLI_BACKLOG_MARKER "$LAB/startup.out" && has CLI_STATUS_MARKER "$LAB/startup.out"; } && echo 0 || echo 1 )"
LOCK_PID=$(cat "$HOME_DIR/state/.lock" 2>/dev/null || true)
COMPLETION_PID=$(cat "$HOME_DIR/state/.session-start-complete" 2>/dev/null || true)
printf 'lock_pid=%s completion_pid=%s\n' "$LOCK_PID" "$COMPLETION_PID" >> "$RESULTS"
check true-startup-lock "true startup owns a live lock and records completion for it" \
  "$( { [ -n "$LOCK_PID" ] && [ "$LOCK_PID" = "$COMPLETION_PID" ]; } && echo 0 || echo 1 )"

# --- 2. no baseline of its own: the freshness proof judges the file ---------
rm -f "$HOME_DIR/state/.session-start-agents-baseline" "$HOME_DIR/state/.session-start-agents-refresh."* 2>/dev/null || true
run compact_fresh FM_SESSIONSTART_SESSION_ID=cli-conv-a -- --source compact
printf 'compact_fresh rc=%s\n' "$(cat "$LAB/compact_fresh.rc")" >> "$RESULTS"
check compact-freshness-skip "a file older than this session needs no refresh (real kernel process age)" \
  "$( { hasnt 'CURRENT AGENTS.md - INSTRUCTION REFRESH' "$LAB/compact_fresh.out" && has 'RE-EMIT SIZE' "$LAB/compact_fresh.out"; } && echo 0 || echo 1 )"
check compact-bounded-shape "the compact re-emit names its scope and leaves both bulk digests on disk" \
  "$( { has 'SESSION START (CONTEXT RE-EMIT)' "$LAB/compact_fresh.out" && has 'RE-EMIT SCOPE' "$LAB/compact_fresh.out" && has 'FLEET STATE (NOT REPRINTED)' "$LAB/compact_fresh.out" && has 'CONTEXT (NOT REPRINTED)' "$LAB/compact_fresh.out" && hasnt CLI_CAPTAIN_MARKER "$LAB/compact_fresh.out" && hasnt CLI_LEARNINGS_MARKER "$LAB/compact_fresh.out" && hasnt CLI_BACKLOG_MARKER "$LAB/compact_fresh.out" && hasnt CLI_STATUS_MARKER "$LAB/compact_fresh.out"; } && echo 0 || echo 1 )"
check compact-keeps-lock-and-wake "the bounded re-emit keeps lock verification and drains the queued wake" \
  "$( { has 'lock acquired' "$LAB/compact_fresh.out" && has "$WAKE_MARKER" "$LAB/compact_fresh.out" && has 'SUPERVISION OPERATING INSTRUCTIONS' "$LAB/compact_fresh.out" && has 'NEXT STEP' "$LAB/compact_fresh.out"; } && echo 0 || echo 1 )"
b=$(budgeted "$(cat "$LAB/compact_fresh.out")")
printf 'budgeted_compact_fresh=%s\n' "$b" >> "$RESULTS"
check compact-within-budget "the budgeted bytes stay inside the default 24576 budget ($b)" \
  "$( { [ "$b" -le 24576 ] && [ "$b" -gt 0 ]; } && echo 0 || echo 1 )"
startup_bytes=$(wc -c < "$LAB/startup.out"); compact_bytes=$(wc -c < "$LAB/compact_fresh.out")
printf 'startup_bytes=%s compact_bytes=%s\n' "$startup_bytes" "$compact_bytes" >> "$RESULTS"
check reemit-smaller-than-digest "the bounded re-emit is smaller than the digest it replaces" \
  "$( { [ "$compact_bytes" -lt "$startup_bytes" ]; } && echo 0 || echo 1 )"

# --- 3. a mid-session change is delivered complete, once per content --------
printf 'When asked, answer with %s.\n' "$SLEEP_MARKER" >> "$PROJECT/AGENTS.md"
printf 'CLI_AGENTS_LAST_LINE-%s\n' "$NONCE" >> "$PROJECT/AGENTS.md"
run compact_drift1 FM_SESSIONSTART_SESSION_ID=cli-conv-a -- --source compact
check drift-delivered-once "the changed instruction file is delivered complete on the next compact" \
  "$( { has 'CURRENT AGENTS.md - INSTRUCTION REFRESH' "$LAB/compact_drift1.out" && has "$SLEEP_MARKER" "$LAB/compact_drift1.out" && has "CLI_AGENTS_LAST_LINE-$NONCE" "$LAB/compact_drift1.out"; } && echo 0 || echo 1 )"
b=$(budgeted "$(cat "$LAB/compact_drift1.out")")
printf 'budgeted_compact_drift1=%s\n' "$b" >> "$RESULTS"
check drift-not-charged-to-budget "the instruction refresh stays outside the byte budget ($b budgeted)" \
  "$( { [ "$b" -le 24576 ]; } && echo 0 || echo 1 )"
marker_a="$HOME_DIR/state/.session-start-agents-refresh.cli-conv-a"
check marker-session-bound "the delivery marker is bound to the session identity, not the pid" \
  "$( { [ -f "$marker_a" ] && [ "$(sed -n '1p' "$marker_a")" = cli-conv-a ]; } && echo 0 || echo 1 )"

run compact_drift2 FM_SESSIONSTART_SESSION_ID=cli-conv-a -- --source compact
check drift-withheld-next "the next compact with the same bytes withholds and names the omission" \
  "$( { hasnt 'CURRENT AGENTS.md - INSTRUCTION REFRESH' "$LAB/compact_drift2.out" && hasnt "$SLEEP_MARKER" "$LAB/compact_drift2.out" && has 'AGENTS.md REFRESH: the current bytes' "$LAB/compact_drift2.out" && has "$PROJECT/AGENTS.md" "$LAB/compact_drift2.out" && has 'AGENTS.md refresh withheld (same bytes already delivered)' "$LAB/compact_drift2.out"; } && echo 0 || echo 1 )"

# --- 4. a second conversation in the same process is not denied the bytes ---
run compact_conv_b FM_SESSIONSTART_SESSION_ID=cli-conv-b -- --source compact
check second-conversation-gets-refresh "another conversation in the same process receives the changed file" \
  "$( { has "$SLEEP_MARKER" "$LAB/compact_conv_b.out" && has 'CURRENT AGENTS.md - INSTRUCTION REFRESH' "$LAB/compact_conv_b.out"; } && echo 0 || echo 1 )"

# --- 5. a marker from another identity never suppresses a refresh -----------
printf '%s\n%s\n' 999999 "$(shasum -a 256 "$PROJECT/AGENTS.md" | awk '{print "sha256:" $1}')" \
  > "$HOME_DIR/state/.session-start-agents-refresh.999999"
rm -f "$HOME_DIR/state/.session-start-agents-refresh.$LOCK_PID" 2>/dev/null || true
run compact_foreign -- --source compact
check foreign-marker-no-suppress "a marker written by another identity does not suppress this session" \
  "$( { has "$SLEEP_MARKER" "$LAB/compact_foreign.out" && [ -f "$HOME_DIR/state/.session-start-agents-refresh.$LOCK_PID" ]; } && echo 0 || echo 1 )"

# --- 6. adversarial: an impossible budget is still a hard bound -------------
printf '%s\n' "CLI_SQUEEZED_AGENTS-$NONCE" >> "$PROJECT/AGENTS.md"
run compact_squeezed FM_SESSION_START_REEMIT_BUDGET=1 FM_SESSIONSTART_SESSION_ID=cli-squeeze -- --source compact
printf 'compact_squeezed rc=%s\n' "$(cat "$LAB/compact_squeezed.rc")" >> "$RESULTS"
check budget-floor "a budget below the 8192 floor is raised, not obeyed" \
  "$( { has '8192-byte re-emit budget' "$LAB/compact_squeezed.out"; } && echo 0 || echo 1 )"
check budget-omits-and-names "an over-budget section is replaced by a named read command" \
  "$( { has 'RE-EMIT BUDGET: SUPERVISION OPERATING INSTRUCTIONS omitted' "$LAB/compact_squeezed.out" && has 'fm-supervision-instructions.sh --harness pi' "$LAB/compact_squeezed.out" && hasnt 'SUPERVISION OPERATING INSTRUCTIONS - primary harness: pi' "$LAB/compact_squeezed.out"; } && echo 0 || echo 1 )"
check budget-exceeded-closing "the closing reminder names every omitted section again" \
  "$( { has 'RE-EMIT BUDGET EXCEEDED' "$LAB/compact_squeezed.out"; } && echo 0 || echo 1 )"
check budget-never-cuts-payloads "the budget never cuts the wake queue or the complete instruction refresh" \
  "$( { has "$WAKE_MARKER" "$LAB/compact_squeezed.out" && has "CLI_SQUEEZED_AGENTS-$NONCE" "$LAB/compact_squeezed.out" && has 'NEXT STEP' "$LAB/compact_squeezed.out"; } && echo 0 || echo 1 )"
b=$(budgeted "$(cat "$LAB/compact_squeezed.out")")
printf 'budgeted_compact_squeezed=%s\n' "$b" >> "$RESULTS"
check squeezed-within-floor "the squeezed re-emit stays inside its 8192-byte floor budget ($b)" \
  "$( { [ "$b" -le 8192 ] && [ "$b" -gt 0 ]; } && echo 0 || echo 1 )"

# --- 7. a clear is not bounded: it still reprints everything ----------------
run clear_full -- --source clear
check clear-not-bounded "a clear re-emit still reprints both bulk digests" \
  "$( { has 'CLI_CAPTAIN_MARKER' "$LAB/clear_full.out" && has 'CLI_LEARNINGS_MARKER' "$LAB/clear_full.out" && has 'READ-ONCE CONTRACT' "$LAB/clear_full.out" && hasnt 'RE-EMIT SCOPE' "$LAB/clear_full.out"; } && echo 0 || echo 1 )"

printf '\n' >> "$RESULTS"
{
  printf 'baseline=%s\n' "$(cat "$HOME_DIR/state/.session-start-agents-baseline" 2>/dev/null | tr '\n' ' ')"
} >> "$RESULTS"

cp "$LAB"/results.txt "$EVID/live-cli-results.txt"
for f in startup compact_fresh compact_drift1 compact_drift2 compact_conv_b compact_foreign compact_squeezed clear_full; do
  cp "$LAB/$f.out" "$EVID/live-cli-$f-output.txt"
done
cat "$RESULTS"
