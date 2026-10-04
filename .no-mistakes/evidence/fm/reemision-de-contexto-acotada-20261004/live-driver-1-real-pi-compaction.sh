#!/usr/bin/env bash
# Live driver: real Pi primary session, real session-start wrapper through the
# real Pi extension, real /compact, observing the bounded re-emit.
set -u

WORKTREE=/home/hugorl/.no-mistakes/worktrees/71308d303441/01M4492JVPA4DRTJY8MHJPPX8G
EVID=/home/hugorl/.no-mistakes/evidence/01M4492JVPA4DRTJY8MHJPPX8G
LAB=${FM_LIVE_LAB:-/tmp/fm-reemit-live.$$}
SOCKET=fm-reemit-live-$$
TSESS=reemit
NONCE=$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')
OLD_MARKER="AGENTS_LIVE_MARKER=old-$NONCE"
NEW_MARKER="AGENTS_LIVE_MARKER=new-$NONCE"
READY_MARKER="LIVE_START_READY=$NONCE"
WAKE_MARKER="WAKE_LIVE_MARKER=$NONCE"
CAPTAIN_MARKER="CAPTAIN_LOOP_MARKER-$NONCE"
LEARNINGS_MARKER="LEARNINGS_LOOP_MARKER-$NONCE"
BACKLOG_MARKER="BACKLOG_LOOP_MARKER-$NONCE"
STATUS_MARKER="TASK_STATUS_LOOP_MARKER-$NONCE"

mkdir -p "$EVID"
rm -rf "$LAB"
mkdir -p "$LAB/project" "$LAB/home/state" "$LAB/home/data" "$LAB/home/config"

log() { printf '%s\n' "$*" | tee -a "$LAB/driver.log"; }
note() { printf '%s\n' "$*" >> "$LAB/driver.log"; }
capture() { tmux -L "$SOCKET" capture-pane -p -t "$TSESS" -S -1200 2>/dev/null || true; }
wait_text() {  # <text> [attempts]
  local want=$1 tries=${2:-240} i=0
  while [ "$i" -lt "$tries" ]; do
    capture | grep -Fq -- "$want" && return 0
    sleep 2
    i=$((i + 1))
  done
  return 1
}
wait_line_count() {  # <text> <min> [attempts]
  local want=$1 min=$2 tries=${3:-240} i=0 n
  while [ "$i" -lt "$tries" ]; do
    n=$(capture | grep -Fc -- "$want" || true)
    [ "$n" -ge "$min" ] && return 0
    sleep 2
    i=$((i + 1))
  done
  return 1
}
wait_file() {  # <path> [attempts]
  local path=$1 tries=${2:-240} i=0
  while [ "$i" -lt "$tries" ]; do
    [ -s "$path" ] && return 0
    sleep 2
    i=$((i + 1))
  done
  return 1
}
wait_invocation() {  # <source> <min-count> [attempts]
  local src=$1 min=$2 tries=${3:-240} i=0 n
  while [ "$i" -lt "$tries" ]; do
    n=$(grep -c -- "argv=--source $src" "$LAB/home/state/.sessionstart-e2e-sources" 2>/dev/null || true)
    [ "${n:-0}" -ge "$min" ] && return 0
    sleep 2
    i=$((i + 1))
  done
  return 1
}
send_line() {
  tmux -L "$SOCKET" send-keys -t "$TSESS" -l "$1"
  sleep 1
  tmux -L "$SOCKET" send-keys -t "$TSESS" Enter
}
cleanup() { tmux -L "$SOCKET" kill-server >/dev/null 2>&1 || true; }
trap cleanup EXIT INT TERM

log "lab=$LAB nonce=$NONCE"
# --- isolated project checkout at the change under test ----------------------
git -C "$WORKTREE" archive HEAD | tar -x -C "$LAB/project"
(
  cd "$LAB/project" || exit 1
  git init -q -b main .
  git config user.email fmtest@example.invalid
  git config user.name fmtest
  # Initial instruction contract: identifiable and larger than the re-emit budget.
  {
    printf 'When asked exactly "Which validation contract marker is active?", reply with exactly "%s" and no other text.\n' "$OLD_MARKER"
    printf 'OLD_AGENTS_FIRST_LINE\n'
    for i in $(seq 1 700); do printf 'OLD_INSTRUCTION_LINE %s: a line the native session-start instruction cache already holds.\n' "$i"; done
    printf 'OLD_AGENTS_LAST_LINE\n'
  } > AGENTS.md
  printf '%s\n' '{"compaction":{"keepRecentTokens":200}}' > .pi/settings.json
  git add -A >/dev/null 2>&1
  git commit -q -m "lab: initial instruction contract"
) || { log "FAIL: project setup"; exit 1; }

# --- scratch FM_HOME with a deliberately bulky full digest -------------------
{
  printf '%s\n' "$CAPTAIN_MARKER"
  for i in $(seq 1 350); do printf 'captain preference %s: durable curated memory the bounded re-emit must not reprint.\n' "$i"; done
} > "$LAB/home/data/captain.md"
{
  printf '%s\n' "$LEARNINGS_MARKER"
  for i in $(seq 1 500); do printf 'learning %s: a dated fleet-local fact the bounded re-emit must not reprint.\n' "$i"; done
} > "$LAB/home/data/learnings.md"
printf '%s\n' '- demo [no-mistakes] - a demo project (added 2026-07-01)' > "$LAB/home/data/projects.md"
printf '%s\n' '## Queued' "- $BACKLOG_MARKER a queued item" > "$LAB/home/data/backlog.md"
for i in 1 2 3; do
  printf 'kind=ship\n' > "$LAB/home/state/task-$i.meta"
  printf 'working: %s %s\n' "$STATUS_MARKER" "$i" > "$LAB/home/state/task-$i.status"
done

# --- recorder shim: preserve argv, capture what the extension received -------
mv "$LAB/project/bin/fm-sessionstart-run.sh" "$LAB/project/bin/.fm-sessionstart-run.real.sh"
cat > "$LAB/project/bin/fm-sessionstart-run.sh" <<'SH'
#!/usr/bin/env bash
set -o pipefail
set -u
state="${FM_HOME:?}/state"
printf 'argv=%s session=%s pid=%s\n' "$*" "${FM_SESSIONSTART_SESSION_ID:-absent}" "$$" >> "$state/.sessionstart-e2e-sources"
"$(dirname "$0")/.fm-sessionstart-run.real.sh" "$@" | tee -a "$state/.sessionstart-e2e-output"
exit "${PIPESTATUS[0]}"
SH
chmod +x "$LAB/project/bin/fm-sessionstart-run.sh"

# --- start the real Pi primary ----------------------------------------------
tmux -L "$SOCKET" new-session -d -s "$TSESS" -c "$LAB/project" -x 220 -y 60 \
  -e "FM_HOME=$LAB/home" -e "FM_ROOT_OVERRIDE=$LAB/project" -e "FM_GATE_REFUSE_BYPASS=1" \
  pi --no-tools -e "$LAB/project/.pi/extensions/fm-primary-turnend-guard.ts" \
  || { log "FAIL: tmux start"; exit 1; }
log "pi started"

# Accept the isolated lab's trust prompt if Pi asks.
for _ in $(seq 1 30); do
  if capture | grep -qiE 'trust (this|the|parent)?[[:space:]]*(folder|project)'; then
    tmux -L "$SOCKET" send-keys -t "$TSESS" Enter
  fi
  sleep 1
done

wait_file "$LAB/home/state/.session-start-complete" 180 \
  || { log "FAIL: true startup never completed"; capture > "$LAB/fail-startup-pane.txt"; exit 1; }
log "true startup completion record present"
send_line "Reply with exactly $READY_MARKER"
wait_text "$READY_MARKER" 180 || { log "FAIL: first turn never answered"; capture > "$LAB/fail-first-turn-pane.txt"; exit 1; }
sleep 2
capture > "$LAB/pane-01-after-startup.txt"
log "first turn answered"
grep -F -- 'argv=--source startup' "$LAB/home/state/.sessionstart-e2e-sources" | tee -a "$LAB/driver.log"
[ -f "$LAB/home/state/.session-start-agents-baseline" ] || { log "FAIL: no true-start baseline"; exit 1; }

# --- queue a wake that arrived after startup, then drift AGENTS.md -----------
FM_STATE_OVERRIDE="$LAB/home/state" bash -c '
  # shellcheck disable=SC1091
  . "$1"
  fm_wake_append signal "$2" "$3"
' _ "$WORKTREE/bin/fm-wake-lib.sh" "live-wake-$NONCE" "$WAKE_MARKER: presented only by the bounded re-emit after compaction." \
  || { log "FAIL: wake append"; exit 1; }
{
  printf 'When asked exactly "Which validation contract marker is active?", reply with exactly "%s" and no other text.\n' "$NEW_MARKER"
  printf 'NEW_AGENTS_FIRST_LINE\n'
  for i in $(seq 1 700); do printf 'NEW_INSTRUCTION_LINE %s: an instruction line a stale native cache does not have yet.\n' "$i"; done
  printf 'NEW_AGENTS_LAST_LINE\n'
} > "$LAB/project/AGENTS.md"
log "wake queued and AGENTS.md drifted"

# --- real compaction #1 ------------------------------------------------------
send_line '/compact'
wait_text 'Compacted from' 300 || { log "FAIL: first compaction never finished"; capture > "$LAB/fail-compact1-pane.txt"; exit 1; }
wait_invocation startup 1 60
wait_invocation compact 1 180 || { log "FAIL: compact wrapper never invoked"; exit 1; }
sleep 6
capture > "$LAB/pane-02-after-compact1.txt"
log "first compaction done"

# --- ask the instruction marker AFTER the compaction, then compact #2 --------
send_line 'Which validation contract marker is active?'
wait_line_count "$NEW_MARKER" 1 180 \
  || { log "WARN: model did not echo the drifted marker after compaction"; capture > "$LAB/fail-marker-pane.txt"; }
sleep 2
capture > "$LAB/pane-03-marker-after-compact1.txt"

send_line '/compact'
wait_text 'Compacted from' 300 || { log "FAIL: second compaction never finished"; capture > "$LAB/fail-compact2-pane.txt"; exit 1; }
wait_invocation compact 2 180 || { log "FAIL: second compact wrapper never invoked"; exit 1; }
sleep 6
capture > "$LAB/pane-04-after-compact2.txt"
log "second compaction done"

# --- split the captured wrapper output into per-invocation blocks ------------
awk -v dir="$LAB" '
  /^argv=/ { n++; file=sprintf("%s/block-%02d.txt", dir, n); print > file; next }
  { if (n > 0) print >> file }
' "$LAB/home/state/.sessionstart-e2e-output"
log "captured invocation blocks:"
ls -l "$LAB"/block-*.txt >> "$LAB/driver.log" 2>&1
cp "$LAB/home/state/.sessionstart-e2e-output" "$EVID/live-reemit-injected-output.txt"
cp "$LAB/home/state/.sessionstart-e2e-sources" "$EVID/live-reemit-invocations.txt"
{
  printf 'OLD_MARKER=%s\nNEW_MARKER=%s\nREADY_MARKER=%s\nWAKE_MARKER=%s\n' "$OLD_MARKER" "$NEW_MARKER" "$READY_MARKER" "$WAKE_MARKER"
} > "$EVID/live-reemit-lab-markers.txt"
for f in "$LAB"/pane-*.txt; do cp "$f" "$EVID/$(basename "${f%.txt}").txt"; done
log "evidence copied to $EVID"
log "DONE lab=$LAB"
