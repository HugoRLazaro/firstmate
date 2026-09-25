#!/usr/bin/env bash
# fm-tablero.sh - arranca, para y consulta el tablero del trabajo de este home.
#
# The board is a small server on THIS machine that reads this home's real state
# (backlog, workers under way, captain holds) and lets the captain answer from
# his phone. bin/fm-tablero.py owns the derivation, the durable conversation
# log, and the three captain actions, each of which leaves exactly one note in
# firstmate's inbox: answering a card also closes or releases its decision
# through the house mechanism; this script owns home resolution, the process,
# the bind address, and the pidfile.
#
# It never writes to a project, never changes a task, and never opens the board
# to the internet: unless told otherwise it listens on the machine's Tailscale
# address plus loopback, so the board is reachable from the captain's own
# devices on his private network and from nowhere else. Nothing listening means
# no board, which is an acceptable state.
#
# Usage:
#   fm-tablero.sh start          arrancarlo y decir con qué dirección se abre
#   fm-tablero.sh stop           pararlo
#   fm-tablero.sh status         si está arrancado y con qué dirección
#   fm-tablero.sh url            solo la dirección para el móvil
#   fm-tablero.sh reply <texto>  publicar una respuesta de firstmate en la conversación
#   fm-tablero.sh reply --reply-to <id> <texto>
#   fm-tablero.sh --help
#
# Configuration, each read from config/ or the matching environment variable:
#   config/tablero-port    FM_TABLERO_PORT    por omisión 8787
#   config/tablero-bind    FM_TABLERO_BIND    direcciones separadas por espacios;
#                                             por omisión la de Tailscale y 127.0.0.1
#
# Environment:
#   FM_HOME   operational home whose data/ and state/ the board reads.
#
# Files under this home, all private and gitignored:
#   state/tablero/servidor.pid     el proceso arrancado
#   state/tablero/servidor.json    con qué direcciones quedó arrancado
#   state/tablero/servidor.log     lo que el servidor escribe
#   state/tablero/conversacion.jsonl   la conversación, durable
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SELF_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
TABLERO_DIR="$STATE/tablero"
PIDFILE="$TABLERO_DIR/servidor.pid"
INFOFILE="$TABLERO_DIR/servidor.json"
LOGFILE="$TABLERO_DIR/servidor.log"
APLICACION="$SELF_DIR/fm-tablero.py"

die() {
  printf 'fm-tablero: %s\n' "$*" >&2
  exit 1
}

info() {
  printf '%s\n' "$*"
}

need_python() {
  command -v python3 >/dev/null 2>&1 || die "hace falta python3 y no está en el PATH"
  [ -r "$APLICACION" ] || die "falta $APLICACION"
}

# La dirección de Tailscale de esta máquina, que es la que el capitán usa desde el móvil.
tailscale_ip() {
  local ip=""
  if command -v tailscale >/dev/null 2>&1; then
    ip="$(tailscale ip -4 2>/dev/null | head -n1 || true)"
  fi
  if [ -z "$ip" ] && command -v ip >/dev/null 2>&1; then
    ip="$(ip -4 addr show tailscale0 2>/dev/null | awk '/inet /{sub(/\/.*/,"",$2); print $2; exit}')"
  fi
  printf '%s' "$ip"
}

puerto() {
  local valor=""
  if [ -r "$FM_HOME/config/tablero-port" ]; then
    valor="$(head -n1 "$FM_HOME/config/tablero-port" | tr -d '[:space:]')"
  fi
  valor="${FM_TABLERO_PORT:-$valor}"
  printf '%s' "${valor:-8787}"
}

direcciones() {
  local valor=""
  if [ -r "$FM_HOME/config/tablero-bind" ]; then
    valor="$(head -n1 "$FM_HOME/config/tablero-bind")"
  fi
  valor="${FM_TABLERO_BIND:-$valor}"
  if [ -n "$valor" ]; then
    printf '%s' "$valor"
    return
  fi
  local ip
  ip="$(tailscale_ip)"
  if [ -n "$ip" ]; then
    printf '%s 127.0.0.1' "$ip"
  else
    printf '%s' "127.0.0.1"
  fi
}

dir_movil() {
  local ip host
  ip="$(tailscale_ip)"
  [ -n "$ip" ] || return 0
  # Solo se anuncia desde el móvil si de verdad se escucha en Tailscale.
  for host in $(direcciones); do
    if [ "$host" = "$ip" ]; then
      printf 'http://%s:%s' "$ip" "$(puerto)"
      return 0
    fi
  done
}

dir_local() {
  printf 'http://127.0.0.1:%s' "$(puerto)"
}

proceso_vivo() {
  local pid
  [ -s "$PIDFILE" ] || return 1
  pid="$(cat "$PIDFILE" 2>/dev/null || true)"
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  kill -0 "$pid" 2>/dev/null
}

escucha() {
  local host=$1 puerto_p=$2
  (exec 3<>"/dev/tcp/$host/$puerto_p") 2>/dev/null || return 1
  exec 3<&- 2>/dev/null || true
  exec 3>&- 2>/dev/null || true
  return 0
}

cmd_start() {
  need_python
  mkdir -p "$TABLERO_DIR"
  if proceso_vivo; then
    info "El tablero ya estaba arrancado (pid $(cat "$PIDFILE"))."
    cmd_url
    return 0
  fi

  local hosts port ip
  hosts="$(direcciones)"
  port="$(puerto)"
  ip="$(tailscale_ip)"

  local -a argumentos=(serve --home "$FM_HOME" --port "$port")
  local host
  for host in $hosts; do
    argumentos+=(--host "$host")
  done

  : >"$LOGFILE"
  nohup python3 "$APLICACION" "${argumentos[@]}" >>"$LOGFILE" 2>&1 &
  local pid=$!
  printf '%s\n' "$pid" >"$PIDFILE"

  local intento
  for ((intento = 0; intento < 60; intento++)); do
    if ! kill -0 "$pid" 2>/dev/null; then
      rm -f "$PIDFILE"
      printf 'fm-tablero: el servidor se cayó al arrancar:\n' >&2
      tail -n 5 "$LOGFILE" >&2 || true
      return 1
    fi
    # Basta con que conteste la dirección local: las demás se abren en el mismo proceso.
    if escucha 127.0.0.1 "$port"; then
      break
    fi
    sleep 0.2
  done
  if ! escucha 127.0.0.1 "$port"; then
    printf 'fm-tablero: el servidor no llegó a escuchar en el puerto %s:\n' "$port" >&2
    tail -n 5 "$LOGFILE" >&2 || true
    return 1
  fi

  python3 - "$INFOFILE" "$pid" "$FM_HOME" "$port" "$hosts" <<'PY'
import json, sys, time
destino, pid, home, puerto, hosts = sys.argv[1:6]
json.dump({
    "pid": int(pid),
    "home": home,
    "puerto": int(puerto),
    "hosts": hosts.split(),
    "arrancado": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
}, open(destino, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
PY

  info "Tablero arrancado (pid $pid), leyendo $FM_HOME."
  if [ -n "$ip" ]; then
    info "  Desde el móvil:  $(dir_movil)"
  else
    info "  AVISO: esta máquina no tiene dirección de Tailscale ahora mismo,"
    info "         así que el tablero solo se abre desde aquí: $(dir_local)"
  fi
  info "  Desde aquí:      $(dir_local)"
  info "  Para pararlo:    bin/fm-tablero.sh stop"
}

cmd_stop() {
  if ! proceso_vivo; then
    rm -f "$PIDFILE"
    info "El tablero no estaba arrancado."
    return 0
  fi
  local pid intento
  pid="$(cat "$PIDFILE")"
  kill "$pid" 2>/dev/null || true
  for ((intento = 0; intento < 50; intento++)); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  if kill -0 "$pid" 2>/dev/null; then
    die "el tablero (pid $pid) no se dejó parar; míralo a mano"
  fi
  rm -f "$PIDFILE"
  info "Tablero parado."
}

cmd_status() {
  if proceso_vivo; then
    info "Arrancado (pid $(cat "$PIDFILE")), leyendo $FM_HOME."
    info "  Desde el móvil:  $(dir_movil)"
    info "  Desde aquí:      $(dir_local)"
    info "  Su registro:     $LOGFILE"
  else
    info "Parado. No hay tablero abierto."
  fi
}

cmd_url() {
  local movil
  movil="$(dir_movil)"
  if [ -n "$movil" ]; then
    info "$movil"
    return 0
  fi
  info "$(dir_local)"
}

cmd_reply() {
  need_python
  python3 "$APLICACION" reply --home "$FM_HOME" "$@"
}

usage() {
  awk '/^# Usage:/{p=1} /^# Configuration/{p=0} p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  printf '\nEste home: %s\n' "$FM_HOME"
}

case "${1-}" in
  start)  shift; cmd_start "$@" ;;
  stop)   shift; cmd_stop "$@" ;;
  status) shift; cmd_status "$@" ;;
  url)    shift; cmd_url "$@" ;;
  reply)  shift; cmd_reply "$@" ;;
  ''|--help|-h|help) usage ;;
  *) die "orden desconocida: $1 (mira --help)" ;;
esac
