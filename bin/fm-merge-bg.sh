#!/usr/bin/env bash
# Hand a captain-authorized PR merge to the background and return at once.
#
# Usage: fm-merge-bg.sh <task-id> <pr-url>
#
# Arms the PR watch (bin/fm-pr-check.sh), then starts the home's local
# background merge script ($FM_HOME/data/fusion-en-segundo-plano.sh) fully
# detached. That script waits for the checks to go green, updates the branch
# when needed, and merges through bin/fm-pr-merge.sh. This helper prints one
# line and exits, so the chat is never blocked waiting for checks.
#
# Run it only after the captain has authorized this merge. The arm pretool
# check (bin/fm-arm-command-policy.mjs) denies long sleeps and merge retry loops
# in the chat and points here instead.
#
# Launch record: $FM_HOME/state/<task-id>.merge-bg.log, written before this
# helper returns. The background script appends its own rounds to the same log.
# A home without data/fusion-en-segundo-plano.sh is refused before anything is
# armed, because that script is local firstmate material and is not in the repo.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FM_HOME="${FM_HOME:-$ROOT}"
STATE="$FM_HOME/state"
BG="$FM_HOME/data/fusion-en-segundo-plano.sh"

if [ "$#" -ne 2 ]; then
  echo "uso: fm-merge-bg.sh <task-id> <pr-url>" >&2
  exit 2
fi
ID=$1
URL=$2

case "$ID" in
  ""|.*|*/*|*..*|*[!A-Za-z0-9._-]*) echo "error: id de tarea no valido: $ID" >&2; exit 2 ;;
esac
case "$URL" in
  https://*/pull/*|https://*/merge_requests/*) : ;;
  *) echo "error: no parece una PR ni una MR: $URL" >&2; exit 2 ;;
esac

if [ ! -f "$BG" ]; then
  echo "error: falta $BG; esta instalacion no tiene el script local de fusion en segundo plano, asi que no he armado ni fusionado nada. Crea ese script o fusiona a mano con bin/fm-pr-merge.sh cuando la PR este limpia." >&2
  exit 3
fi

mkdir -p "$STATE"
LOG="$STATE/$ID.merge-bg.log"

# Arm the watch first, as the background script does. A failure is reported
# and does not stop the merge, which records its own outcome.
if ! "$FM_HOME/bin/fm-pr-check.sh" "$ID" "$URL" >>"$LOG" 2>&1; then
  echo "aviso: no he podido armar la vigilancia de la PR; la fusion sigue en segundo plano" >&2
fi

printf '%s lanzado por fm-merge-bg: %s %s\n' "$(date -Is)" "$ID" "$URL" >>"$LOG"
FM_HOME="$FM_HOME" nohup bash "$BG" "$ID" "$URL" </dev/null >>"$LOG" 2>&1 &
PID=$!
disown "$PID" 2>/dev/null || true

printf 'lanzado: fusion de %s en segundo plano (pid %s); el aviso llega cuando entre. Registro: %s\n' "$ID" "$PID" "$LOG"
