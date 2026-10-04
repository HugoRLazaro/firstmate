#!/usr/bin/env bash
# Live driver #3: a real Pi primary where the session is switched (/new) while a
# compaction re-emit is still in flight, so the extension must discard the
# refresh marker it already wrote for the conversation that never received it.
set -u

LAB=/tmp/fm-reemit-live.2378238
EVID=/home/hugorl/.no-mistakes/evidence/01M4492JVPA4DRTJY8MHJPPX8G
SOCKET=fm-reemit-cancel-$$
TSESS=reemitcancel
NONCE=$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')
READY="CANCEL_READY=$NONCE"
DRIFT="CANCEL_DRIFT_AGENTS=$NONCE"
RESULTS=$LAB/cancel-results.txt

log() { printf '%s\n' "$*" | tee -a "$LAB/cancel-driver.log"; }
capture() { tmux -L "$SOCKET" capture-pane -p -t "$TSESS" -S -1200 2>/dev/null || true; }
wait_text() { local want=$1 tries=${2:-240} i=0; while [ "$i" -lt "$tries" ]; do capture | grep -Fq -- "$want" && return 0; sleep 2; i=$((i + 1)); done; return 1; }
send_line() { tmux -L "$SOCKET" send-keys -t "$TSESS" -l "$1"; sleep 1; tmux -L "$SOCKET" send-keys -t "$TSESS" Enter; }
check() { local name=$1 desc=$2 ok=$3; if [ "$ok" = 0 ]; then printf 'PASS  %-28s %s\n' "$name" "$desc" >> "$RESULTS"; else printf 'FAIL  %-28s %s\n' "$name" "$desc" >> "$RESULTS"; fi; }
cleanup() { tmux -L "$SOCKET" kill-server >/dev/null 2>&1 || true; }
trap cleanup EXIT INT TERM

: > "$RESULTS"
mv "$LAB/home/state/.sessionstart-e2e-output" "$LAB/home/state/.sessionstart-e2e-output.run2" 2>/dev/null || true
mv "$LAB/home/state/.sessionstart-e2e-sources" "$LAB/home/state/.sessionstart-e2e-sources.run2" 2>/dev/null || true
rm -f "$LAB/home/state/.session-start-agents-refresh."* 2>/dev/null || true

tmux -L "$SOCKET" new-session -d -s "$TSESS" -c "$LAB/project" -x 220 -y 60 \
  -e "FM_HOME=$LAB/home" -e "FM_ROOT_OVERRIDE=$LAB/project" -e "FM_GATE_REFUSE_BYPASS=1" \
  pi --no-tools -e "$LAB/project/.pi/extensions/fm-primary-turnend-guard.ts" || { log "FAIL: tmux start"; exit 1; }
for _ in $(seq 1 30); do
  if capture | grep -qiE 'trust (this|the|parent)?[[:space:]]*(folder|project)'; then
    tmux -L "$SOCKET" send-keys -t "$TSESS" Enter
  fi
  sleep 1
done
for _ in $(seq 1 180); do [ -s "$LAB/home/state/.session-start-complete" ] && break; sleep 2; done
send_line "Reply with exactly $READY"
wait_text "$READY" 180 || { log "FAIL: first turn never answered"; exit 1; }
sleep 2
SESSION_ID=$(sed -n '1p' "$LAB/home/state/.sessionstart-e2e-sources" | sed 's/.*session=//;s/ .*//')
log "startup done, session=$SESSION_ID"

# Drift so the next compact must emit the refresh and record its marker.
printf '%s\n' "$DRIFT" >> "$LAB/project/AGENTS.md"

send_line '/compact'
# The session_compact event fires after Pi's own compaction; wait for the
# wrapper invocation, then for the in-flight digest to record the delivery
# marker, then switch the conversation immediately: that generation is now
# undelivered.
for _ in $(seq 1 300); do
  grep -q -- 'argv=--source compact' "$LAB/home/state/.sessionstart-e2e-sources" 2>/dev/null && break
  sleep 2
done
marker="$LAB/home/state/.session-start-agents-refresh.$SESSION_ID"
appeared=1
for _ in $(seq 1 750); do
  if [ -f "$marker" ]; then appeared=0; break; fi
  sleep 0.02
done
tmux -L "$SOCKET" send-keys -t "$TSESS" -l '/new'
sleep 0.05
tmux -L "$SOCKET" send-keys -t "$TSESS" Enter
log "marker_appeared=$appeared; /new sent"

sleep 20
capture > "$LAB/cancel-pane.txt"
compact_out="$LAB/home/state/.sessionstart-e2e-output"
compact_end=$(grep -c 'RE-EMIT SIZE' "$compact_out" 2>/dev/null || true)
log "RE-EMIT SIZE occurrences in this run's output: $compact_end"
if [ "$appeared" = 0 ] && [ "${compact_end:-0}" -eq 0 ]; then
  check cancelled-generation-discards-marker \
    "a /new during an undelivered compaction drops that session's marker" \
    "$( { [ ! -e "$marker" ]; } && echo 0 || echo 1 )"
else
  check cancelled-generation-discards-marker \
    "a /new during an undelivered compaction drops that session's marker" \
    1
  printf 'race_lost: marker_appeared=%s compact_completed=%s\n' "$appeared" "${compact_end:-0}" >> "$RESULTS"
fi
cp "$compact_out" "$EVID/live-cancel-injected-output.txt" 2>/dev/null || true
cp "$LAB/cancel-pane.txt" "$EVID/live-cancel-pane.txt" 2>/dev/null || true
cp "$RESULTS" "$EVID/live-cancel-results.txt"
cat "$RESULTS"
log "DONE"
