#!/usr/bin/env bash
# Live driver #2: a real Pi primary whose instruction file PREDATES the process,
# with a foreign baseline (what a resumed session finds), so the freshness proof
# must skip the refresh - then a real mid-session change, so it must deliver.
set -u

LAB=/tmp/fm-reemit-live.2378238
EVID=/home/hugorl/.no-mistakes/evidence/01M4492JVPA4DRTJY8MHJPPX8G
SOCKET=fm-reemit-fresh-$$
TSESS=reemitfresh
NONCE=$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')
READY="FRESH_READY=$NONCE"
DRIFT="FRESH_DRIFT_AGENTS=$NONCE"
DRIFT_LAST="FRESH_DRIFT_LAST=$NONCE"
RESULTS=$LAB/freshness-results.txt

log() { printf '%s\n' "$*" | tee -a "$LAB/freshness-driver.log"; }
capture() { tmux -L "$SOCKET" capture-pane -p -t "$TSESS" -S -1500 2>/dev/null || true; }
wait_text() { local want=$1 tries=${2:-240} i=0; while [ "$i" -lt "$tries" ]; do capture | grep -Fq -- "$want" && return 0; sleep 2; i=$((i + 1)); done; return 1; }
wait_invocation() { local src=$1 min=$2 tries=${3:-240} i=0 n; while [ "$i" -lt "$tries" ]; do n=$(grep -c -- "argv=--source $src" "$LAB/home/state/.sessionstart-e2e-sources" 2>/dev/null || true); [ "${n:-0}" -ge "$min" ] && return 0; sleep 2; i=$((i + 1)); done; return 1; }
send_line() { tmux -L "$SOCKET" send-keys -t "$TSESS" -l "$1"; sleep 1; tmux -L "$SOCKET" send-keys -t "$TSESS" Enter; }
check() { local name=$1 desc=$2 ok=$3; if [ "$ok" = 0 ]; then printf 'PASS  %-30s %s\n' "$name" "$desc" >> "$RESULTS"; else printf 'FAIL  %-30s %s\n' "$name" "$desc" >> "$RESULTS"; fi; }
has() { grep -Fq -- "$1" "$2"; }
hasnt() { ! grep -Fq -- "$1" "$2"; }
cleanup() { tmux -L "$SOCKET" kill-server >/dev/null 2>&1 || true; }
trap cleanup EXIT INT TERM

: > "$RESULTS"
# Keep the previous run's captures; start clean for this one.
mv "$LAB/home/state/.sessionstart-e2e-output" "$LAB/home/state/.sessionstart-e2e-output.run1" 2>/dev/null || true
mv "$LAB/home/state/.sessionstart-e2e-sources" "$LAB/home/state/.sessionstart-e2e-sources.run1" 2>/dev/null || true
rm -f "$LAB/home/state/.session-start-agents-refresh."* 2>/dev/null || true

# The instruction file's change time is read before the session process starts.
stat -c 'agents_ctime_before_pi=%z' "$LAB/project/AGENTS.md" >> "$RESULTS"
log "waiting 8s so the instruction file provably predates the new session process"
sleep 8

tmux -L "$SOCKET" new-session -d -s "$TSESS" -c "$LAB/project" -x 220 -y 60 \
  -e "FM_HOME=$LAB/home" -e "FM_ROOT_OVERRIDE=$LAB/project" -e "FM_GATE_REFUSE_BYPASS=1" \
  pi --no-tools -e "$LAB/project/.pi/extensions/fm-primary-turnend-guard.ts" || { log "FAIL: tmux start"; exit 1; }
for _ in $(seq 1 30); do
  if capture | grep -qiE 'trust (this|the|parent)?[[:space:]]*(folder|project)'; then
    tmux -L "$SOCKET" send-keys -t "$TSESS" Enter
  fi
  sleep 1
done
log "pi started; pid ancestry recorded in lock"

for _ in $(seq 1 180); do
  [ -s "$LAB/home/state/.session-start-complete" ] && break
  sleep 2
done
send_line "Reply with exactly $READY"
wait_text "$READY" 180 || { log "FAIL: first turn never answered"; capture > "$LAB/fresh-fail-first-pane.txt"; exit 1; }
sleep 2
capture > "$LAB/fresh-pane-01-startup.txt"
log "startup done"

# Simulate a resumed/manually started session: the only baseline on disk belongs
# to another process, so this session has no baseline of its own.
printf '999999\n%s\n' "sha256:$(shasum -a 256 "$LAB/project/AGENTS.md" | awk '{print $1}')" \
  > "$LAB/home/state/.session-start-agents-baseline"

send_line '/compact'
wait_text 'Compacted from' 300 || { log "FAIL: compaction 1 never finished"; capture > "$LAB/fresh-fail-compact1-pane.txt"; exit 1; }
wait_invocation compact 1 180 || { log "FAIL: compact wrapper never invoked"; exit 1; }
sleep 6
capture > "$LAB/fresh-pane-02-compact1.txt"
log "compaction 1 done"

# Split this run's output on its own section banners: startup digest first,
# then the compaction re-emit.
awk -v dir="$LAB" -v tag=fresh1 '
  /^SESSION START/ { n++; file=sprintf("%s/%s-block-%02d.txt", dir, tag, n) }
  n > 0 { print >> file }
' "$LAB/home/state/.sessionstart-e2e-output"
SIZE1=$(wc -c < "$LAB/home/state/.sessionstart-e2e-output")

# --- drift the file after the process started, then compact again ------------
{
  printf 'When asked exactly "Which validation contract marker is active?", reply with exactly "%s" and no other text.\n' "$DRIFT"
  printf '%s\n' "$DRIFT_LAST"
} >> "$LAB/project/AGENTS.md"
send_line '/compact'
wait_text 'Compacted from' 300 || { log "FAIL: compaction 2 never finished"; capture > "$LAB/fresh-fail-compact2-pane.txt"; exit 1; }
wait_invocation compact 2 180 || { log "FAIL: second compact wrapper never invoked"; exit 1; }
sleep 6
capture > "$LAB/fresh-pane-03-compact2.txt"
tail -c "+$((SIZE1 + 1))" "$LAB/home/state/.sessionstart-e2e-output" > "$LAB/fresh2-block-01.txt"
log "compaction 2 done"

# --- assertions --------------------------------------------------------------
f1=$LAB/fresh1-block-02.txt   # compact #1 (block 01 is the startup digest)
f2=$LAB/fresh2-block-01.txt   # compact #2 (everything appended after compaction #1)
# Fall back to the whole raw stream if the split landed differently.
[ -s "$f1" ] || f1=$LAB/fresh-run2-output-raw.txt
[ -s "$f2" ] || f2=$LAB/home/state/.sessionstart-e2e-output

check freshness-skips-predating-file \
  "a file older than this real session needs no refresh" \
  "$( { hasnt 'CURRENT AGENTS.md - INSTRUCTION REFRESH' "$f1" && has 'AGENTS.md refresh 0 bytes' "$f1" && has 'SESSION START (CONTEXT RE-EMIT)' "$f1"; } && echo 0 || echo 1 )"
check freshness-delivers-post-start-change \
  "a real change after the process started is delivered complete once" \
  "$( { has 'CURRENT AGENTS.md - INSTRUCTION REFRESH' "$f2" && has "$DRIFT" "$f2" && has "$DRIFT_LAST" "$f2"; } && echo 0 || echo 1 )"

cp "$LAB/home/state/.sessionstart-e2e-output" "$EVID/live-freshness-injected-output.txt"
cp "$LAB/home/state/.sessionstart-e2e-sources" "$EVID/live-freshness-invocations.txt"
cp "$LAB/fresh-pane-01-startup.txt" "$EVID/live-freshness-pane-startup.txt" 2>/dev/null || true
cp "$LAB/fresh-pane-02-compact1.txt" "$EVID/live-freshness-pane-compact1.txt" 2>/dev/null || true
cp "$LAB/fresh-pane-03-compact2.txt" "$EVID/live-freshness-pane-compact2.txt" 2>/dev/null || true
cp "$RESULTS" "$EVID/live-freshness-results.txt"
cat "$RESULTS"
log "DONE"
