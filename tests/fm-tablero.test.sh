#!/usr/bin/env bash
# tests/fm-tablero.test.sh - behavior tests for the work board
# (bin/fm-tablero.sh, bin/fm-tablero.py, bin/tablero/pantalla.*).
#
# The board's whole value is that what it shows and what it does come from this
# home's real state, so every case here runs a real server against a real home
# under a temp root and drives it over HTTP and the CLI. Nothing is asserted
# about the module's source text.
#
# What is pinned:
#   - the five columns really are computed from backlog + state/<id>.meta +
#     state/<id>.status, one case per column, plus the ask the captain sees
#   - answering a decision calls the decision mechanism with the captain's own
#     words: once through a recording shim (portable, proves the exact argv and
#     the verbatim file) and once through the REAL bin/fm-captain-hold.sh
#     against a real held task, where the words must land in the backlog
#   - a held task with a worker on it is released instead of closed
#   - a free chat message really reaches firstmate's inbox and its wake queue
#   - the reply command publishes firstmate's answer and pairs it with the
#     captain's message, by oldest-unanswered and by explicit id
#   - moving and removing a card only ASK: the request reaches the inbox and the
#     backlog is left exactly as it was
#   - start/stop/status, and the refusal to listen on 0.0.0.0
#
# The page itself (rendering, tabs, console, refresh keeping the draft) is
# proved with a real browser in tests/fm-tablero-pantalla.test.sh.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }

TABLERO="$ROOT/bin/fm-tablero.sh"
TMP_ROOT=$(fm_test_tmproot fm-tablero-tests)
SERVIDORES=()

# shellcheck disable=SC2329 # invoked indirectly through the EXIT/INT/TERM trap below.
cleanup() {
  local pid
  for pid in "${SERVIDORES[@]:-}"; do
    [ -n "$pid" ] || continue
    kill "$pid" 2>/dev/null || true
  done
  fm_test_cleanup
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------- utilería

puerto_libre() {
  python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
}

# pide <metodo> <url> [cuerpo-json]: the HTTP response body, error or not.
pide() {  # <metodo> <url> [cuerpo-json] [origin]
  python3 - "$1" "$2" "${3-}" "${4-}" <<'PY'
import sys, urllib.error, urllib.request
metodo, url, cuerpo, origen = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
datos = cuerpo.encode("utf-8") if cuerpo else None
peticion = urllib.request.Request(url, data=datos, method=metodo)
if datos:
    peticion.add_header("Content-Type", "application/json")
if origen:
    peticion.add_header("Origin", origen)
try:
    with urllib.request.urlopen(peticion, timeout=30) as respuesta:
        sys.stdout.write(respuesta.read().decode("utf-8"))
except urllib.error.HTTPError as error:
    sys.stdout.write(error.read().decode("utf-8"))
PY
}

# estado <puerto>: /api/estado on stdout, nonzero on transport failure.
estado() {
  pide GET "http://127.0.0.1:$1/api/estado"
}

# comprobar_json <url> <descripcion> <programa-python>: fetches the URL and hands
# the JSON to the program, which fails the test by raising, so a case can assert
# several fields at once without shell quoting gymnastics.
comprobar_json() {
  local url=$1 descripcion=$2 programa=$3 salida
  if ! salida=$(pide GET "$url" | python3 -c "$programa" 2>&1); then
    fail "$descripcion"$'\n'"$salida"
  fi
  pass "$descripcion${salida:+ ($salida)}"
}

comprobar() {  # <puerto> <descripcion> <programa>
  comprobar_json "http://127.0.0.1:$1/api/estado" "$2" "$3"
}

comprobar_charla() {  # <puerto> <descripcion> <programa>
  comprobar_json "http://127.0.0.1:$1/api/conversacion" "$2" "$3"
}

escucha() {  # <puerto> [host]
  local host=${2:-127.0.0.1}
  (exec 3<>"/dev/tcp/$host/$1") 2>/dev/null
}

# nuevo_home <nombre> <real|shim>: a home with a fresh backlog and state dir.
# `real` links this repo's own bin/ so the genuine fm-inbox.sh and
# fm-captain-hold.sh are the ones called; `shim` installs recorders instead.
nuevo_home() {
  local nombre=$1 modo=${2:-shim} home
  home="$TMP_ROOT/$nombre"
  mkdir -p "$home/data" "$home/state"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  if [ "$modo" = real ]; then
    ln -s "$ROOT/bin" "$home/bin"
  else
    mkdir -p "$home/bin"
    cat > "$home/bin/fm-inbox.sh" <<'SH'
#!/usr/bin/env bash
# Recorder for `note -`: keeps the argv, the whole body, and each note on its
# own numbered file, so a case can assert note by note and count the calls.
printf '%s\n' "$*" >> "$FM_HOME/recorder-inbox-argv.txt"
numero=$(grep -c '' "$FM_HOME/recorder-inbox-argv.txt")
cuerpo=$(cat)
printf '%s' "$cuerpo" >> "$FM_HOME/recorder-inbox-cuerpo.txt"
mkdir -p "$FM_HOME/recorder-notas"
printf '%s' "$cuerpo" > "$FM_HOME/recorder-notas/$numero.note"
# La misma forma que publica el fm-inbox.sh de verdad: `queued <id>`.
printf 'queued 20260925-0abc%03d\n' "$numero"
printf '  %s\n' "$(printf '%s' "$cuerpo" | tr '\n\t' '  ' | cut -c1-100)"
SH
    cat > "$home/bin/fm-captain-hold.sh" <<'SH'
#!/usr/bin/env bash
# Recorder for `answer`: keeps the argv and the last decision file's exact bytes.
printf '%s\n' "$*" >> "$FM_HOME/recorder-hold-argv.txt"
while [ $# -gt 0 ]; do
  if [ "$1" = "--decision-file" ]; then
    cat "$2" > "$FM_HOME/recorder-hold-decision.txt"
  fi
  shift
done
echo "answered: recorder"
SH
    chmod +x "$home/bin/"*.sh
  fi
  printf '%s\n' "$home"
}

# arrancar <home> <puerto>: start through the shipped command and remember the pid.
arrancar() {  # <home> <puerto> [bind]
  local home=$1 puerto=$2 bind=${3:-127.0.0.1} salida
  salida=$(FM_HOME="$home" FM_TABLERO_BIND="$bind" FM_TABLERO_PORT="$puerto" \
    "$TABLERO" start 2>&1) || fail "arrancar el tablero: $salida"
  assert_contains "$salida" "Tablero arrancado" "start dice que quedó arrancado"
  if [ -s "$home/state/tablero/servidor.pid" ]; then
    SERVIDORES+=("$(cat "$home/state/tablero/servidor.pid")")
  fi
  local intento
  for ((intento = 0; intento < 40; intento++)); do
    escucha "$puerto" "$bind" && return 0
    sleep 0.25
  done
  fail "el tablero no escuchó en el puerto $puerto"
}

backlog_de() {  # <home> <contenido>
  printf '%s\n' "$2" > "$1/data/backlog.md"
}

# solo_panel <puerto>: the part of /api/estado that must not change when the only
# thing that happened was a request, so the clock cannot make the case flaky.
solo_panel() {
  estado "$1" | python3 -c '
import json, sys
d = json.load(sys.stdin)
print(json.dumps({"columnas": d["columnas"], "cuenta": d["cuenta"]}, ensure_ascii=False, sort_keys=True))
'
}

# ------------------------------------------------- escenario: las cinco columnas

HOME_A=$(nuevo_home columnas)
backlog_de "$HOME_A" '# Backlog

## In flight
- [ ] tarea-ahora - Un trabajo en marcha (repo: firstmate) (kind: ship) (since 2026-09-25)
- [ ] tarea-subir - Un trabajo terminado (repo: firstmate) (kind: ship) (since 2026-09-25)
  Deliverable of the finished work: report data/tarea-subir/report.md
## Queued
- [ ] tarea-espera - Una decision que espera (repo: licitaciones-platform) (kind: captain) (since 2026-09-24) (hold: Se midio el asunto el 24-sep. Decision: dime si sigo con la opcion A o con la B. Sin respuesta no se toca nada.) (hold-kind: captain)
  Captain hold set: 2026-09-24T10:00:00Z
- [ ] tarea-plan - Un trabajo previsto (repo: firstmate) (kind: ship) (since 2026-09-25)
## Done
- [x] tarea-hecha - Algo ya publicado (repo: firstmate) (kind: ship) (done 2026-09-25) (merged 2026-07-06)
  local main'
printf 'working: paso 2 en marcha\n' > "$HOME_A/state/tarea-ahora.status"
printf 'window=default:w1:p1\nharness=pi\n' > "$HOME_A/state/tarea-ahora.meta"
printf 'done: ready in branch fm/tarea-subir\n' > "$HOME_A/state/tarea-subir.status"
printf 'window=default:w1:p2\nharness=pi\n' > "$HOME_A/state/tarea-subir.meta"

PUERTO_A=$(puerto_libre)
arrancar "$HOME_A" "$PUERTO_A"

comprobar "$PUERTO_A" "cada tarjeta cae en su columna según el estado real" '
import json, sys
d = json.load(sys.stdin)
sitio = {t["id"]: c["id"] for c in d["columnas"] for t in c["tarjetas"]}
assert sitio == {
    "tarea-ahora": "ahora",
    "tarea-subir": "subir",
    "tarea-espera": "espera",
    "tarea-plan": "plan",
    "tarea-hecha": "hecho",
}, sitio
print("5/5")
'

comprobar "$PUERTO_A" "la cabecera cuenta lo que espera al capitán y lo que tiene parado" '
import json, sys
d = json.load(sys.stdin)["cuenta"]
assert d["preguntan"] == 1, d
assert d["ahora"] == 1 and d["subir"] == 1 and d["plan"] == 1 and d["hecho"] == 1, d
assert d["bloquean"] == 0, d
print(json.dumps(d, ensure_ascii=False))
'

comprobar "$PUERTO_A" "la tarjeta que espera enseña la pregunta y se puede responder" '
import json, sys
d = json.load(sys.stdin)
tarjeta = [t for c in d["columnas"] for t in c["tarjetas"] if t["id"] == "tarea-espera"][0]
assert "opcion A o con la B" in tarjeta["necesita"], tarjeta["necesita"]
assert tarjeta["puede_responder"] is True, tarjeta
assert tarjeta["bloquea"], tarjeta
assert "cerrada" in tarjeta["respuesta_accion"], tarjeta["respuesta_accion"]
assert "2026-09-24" in tarjeta["desde"], tarjeta["desde"]
assert tarjeta["area"] == "licitaciones-platform", tarjeta["area"]
assert "repo:" not in tarjeta["titulo"], tarjeta["titulo"]
'

comprobar "$PUERTO_A" "una fila ya aterrizada con merged al final se lee sin arrastrar anotaciones" '
import json, sys
d = json.load(sys.stdin)
tarjeta = [t for c in d["columnas"] for t in c["tarjetas"] if t["id"] == "tarea-hecha"][0]
assert tarjeta["area"] == "firstmate", tarjeta
assert tarjeta["titulo"] == "Algo ya publicado", tarjeta["titulo"]
print("merged")
'

comprobar "$PUERTO_A" "el trabajo terminado trae lo que dijo su ayudante al acabar" '
import json, sys
d = json.load(sys.stdin)
tarjeta = [t for c in d["columnas"] for t in c["tarjetas"] if t["id"] == "tarea-subir"][0]
assert "ready in branch fm/tarea-subir" in tarjeta["detalle"], tarjeta["detalle"]
assert tarjeta["puede_responder"] is False, tarjeta
'

comprobar "$PUERTO_A" "el trabajo en marcha dice quién está con él y sin inventarse nada" '
import json, sys
d = json.load(sys.stdin)
tarjeta = [t for c in d["columnas"] for t in c["tarjetas"] if t["id"] == "tarea-ahora"][0]
assert tarjeta["quien"] == "Un ayudante de firstmate", tarjeta["quien"]
assert "paso 2 en marcha" in tarjeta["detalle"], tarjeta["detalle"]
assert tarjeta["desde"].startswith("Último aviso"), tarjeta["desde"]
'

comprobar "$PUERTO_A" "el ausente se anuncia solo cuando hay modo ausencia" '
import json, sys
d = json.load(sys.stdin)
assert d["ausencia"] is None, d["ausencia"]
'
printf 'entered: 2026-09-25T10:00:00Z\nexpected_return: 2026-09-26\n' > "$HOME_A/state/.afk-contract"
comprobar "$PUERTO_A" "el modo ausencia sale del contrato del home" '
import json, sys
d = json.load(sys.stdin)
assert d["ausencia"] and "2026-09-26" in d["ausencia"]["texto"], d["ausencia"]
'
rm -f "$HOME_A/state/.afk-contract"

HOME_SIN=$(nuevo_home sin-backlog)
: > "$HOME_SIN/data/backlog.md"
rm -f "$HOME_SIN/data/backlog.md"
rmdir "$HOME_SIN/data"
PUERTO_SIN=$(puerto_libre)
arrancar "$HOME_SIN" "$PUERTO_SIN"
comprobar "$PUERTO_SIN" "sin backlog el tablero lo dice en vez de inventarse tarjetas" '
import json, sys
d = json.load(sys.stdin)
assert d["aviso"] and "backlog" in d["aviso"].lower(), d["aviso"]
assert all(not c["tarjetas"] for c in d["columnas"]), d["columnas"]
'

# ------------------------------------------ escenario: responder cierra de verdad

HOME_B=$(nuevo_home responder)
backlog_de "$HOME_B" '# Backlog

## Queued
- [ ] tarea-decision - Una decision que espera (repo: firstmate) (kind: captain) (since 2026-09-24) (hold: Decision: dime si A o B) (hold-kind: captain)
  Captain hold set: 2026-09-24T10:00:00Z
- [ ] tarea-trabajo - Trabajo parado por una decision (repo: firstmate) (kind: ship) (since 2026-09-24) (hold: Decisiones: a. se construye? b. en que modo?) (hold-kind: captain)
  Captain hold set: 2026-09-24T11:00:00Z'
printf 'window=default:w2:p1\nharness=pi\n' > "$HOME_B/state/tarea-trabajo.meta"

PUERTO_B=$(puerto_libre)
arrancar "$HOME_B" "$PUERTO_B"

DECISION=$'Sí, adelante con A: «con acentos» y dos\nlíneas.'
CUERPO=$(python3 -c 'import json,sys; print(json.dumps({"tarea":"tarea-decision","texto":sys.argv[1],"titulo":"Una decision que espera"}))' "$DECISION")
RESPUESTA=$(pide POST "http://127.0.0.1:$PUERTO_B/api/responder" "$CUERPO")
assert_contains "$RESPUESTA" '"ok": true' "responder contesta que sí"

assert_equals "answer tarea-decision --decision-file $HOME_B/state/tablero/decision-tarea-decision.txt" \
  "$(cat "$HOME_B/recorder-hold-argv.txt")" \
  "la respuesta llama al mecanismo de decisión con la tarea y su fichero"
assert_equals "$DECISION" "$(cat "$HOME_B/recorder-hold-decision.txt")" \
  "las palabras del capitán llegan al fichero tal cual, con acentos y saltos de línea"
pass "las palabras del capitán llegan al mecanismo de decisión tal cual, con acentos y saltos de línea"
assert_contains "$RESPUESTA" "queda cerrada" "el tablero dice que la decisión queda cerrada"
pass "el tablero confirma que la decisión queda cerrada"

PERMISOS=$(python3 - "$HOME_B/state/tablero" <<'PY'
import os, stat, sys
tablero = sys.argv[1]
modo = stat.S_IMODE(os.stat(tablero).st_mode)
assert modo == 0o700, oct(modo)
for nombre in ("conversacion.jsonl", "conversacion.lock"):
    modo = stat.S_IMODE(os.stat(os.path.join(tablero, nombre)).st_mode)
    assert modo == 0o600, (nombre, oct(modo))
print("700/600")
PY
) || fail "la conversación durable y su carpeta deben ser de sólo el dueño"
assert_contains "$PERMISOS" "700/600" "la conversación durable y su carpeta son de sólo el dueño"
pass "la conversación durable y su carpeta se guardan con permisos de dueño"

# Un encargado en marcha esperando la respuesta es trabajo que sigue: se suelta.
CUERPO_TRABAJO=$(python3 -c 'import json; print(json.dumps({"tarea":"tarea-trabajo","texto":"a. si, se construye"}))')
pide POST "http://127.0.0.1:$PUERTO_B/api/responder" "$CUERPO_TRABAJO" >/dev/null
assert_equals "answer tarea-trabajo --decision-file $HOME_B/state/tablero/decision-tarea-trabajo.txt --release" \
  "$(tail -n 1 "$HOME_B/recorder-hold-argv.txt")" \
  "con un ayudante en marcha la respuesta suelta el trabajo en vez de cerrarlo"
pass "con un ayudante en marcha la respuesta suelta el trabajo en vez de cerrarlo"

# Una respuesta vacía no llama a nada.
ANTES=$(wc -l < "$HOME_B/recorder-hold-argv.txt")
pide POST "http://127.0.0.1:$PUERTO_B/api/responder" '{"tarea":"tarea-decision","texto":"   "}' >/dev/null
assert_equals "$ANTES" "$(wc -l < "$HOME_B/recorder-hold-argv.txt")" \
  "una respuesta vacía no llega al mecanismo de decisión"
pass "una respuesta vacía no llega al mecanismo de decisión"

ANTES=$(wc -l < "$HOME_B/recorder-hold-argv.txt")
MALA=$(pide POST "http://127.0.0.1:$PUERTO_B/api/responder" \
  '{"tarea":"x/y","texto":"Esto no puede tocar ningún fichero."}' 2>/dev/null || true)
assert_contains "$MALA" '"ok": false' \
  "una tarea que no es un identificador válido se rechaza con una respuesta, sin cortar la conexión"
assert_equals "$ANTES" "$(wc -l < "$HOME_B/recorder-hold-argv.txt")" \
  "una tarea que no es un identificador válido no llega al mecanismo de decisión"
pass "una tarea inválida se rechaza limpiamente y no escribe nada"

# Lo escrito en una tarjeta avisa al buzón igual que un mensaje del chat: una sola
# nota por envío, con la tarea, las palabras del capitán tal cual y el camino de
# vuelta emparejado con ese mensaje concreto.
assert_equals "2" "$(grep -c '' "$HOME_B/recorder-inbox-argv.txt")" \
  "cada envío desde una tarjeta deja exactamente una nota, sin duplicarla"
pass "cada envío desde una tarjeta deja exactamente una nota, sin duplicarla"
assert_contains "$(cat "$HOME_B/recorder-notas/1.note")" "tarea-decision" \
  "la nota de la tarjeta nombra la tarea a la que se refiere"
assert_contains "$(cat "$HOME_B/recorder-notas/1.note")" "$DECISION" \
  "la nota lleva las palabras del capitán tal cual, con acentos y saltos de línea"
pass "la nota de la tarjeta nombra la tarea y lleva las palabras del capitán tal cual"
ID_TARJETA=$(pide GET "http://127.0.0.1:$PUERTO_B/api/conversacion" | python3 -c '
import json, sys
d = json.load(sys.stdin)["mensajes"]
print([m["id"] for m in d if m["tarea"] == "tarea-decision"][0])')
assert_grep "--reply-to $ID_TARJETA" "$HOME_B/recorder-notas/1.note" \
  "la nota dice cómo contestar emparejado con ese mensaje de la tarjeta"
assert_grep "La decisión queda cerrada con estas palabras." "$HOME_B/recorder-notas/1.note" \
  "la nota cuenta que el tablero ya cerró la decisión con ellas"
pass "la nota de la tarjeta dice cómo contestar emparejado y qué hizo el tablero"
NOTA_DEL_MENSAJE=$(pide GET "http://127.0.0.1:$PUERTO_B/api/conversacion" | python3 -c '
import json, sys
d = json.load(sys.stdin)["mensajes"]
print([m["nota"] for m in d if m.get("tarea") == "tarea-decision"][0])')
assert_equals "20260925-0abc001" "$NOTA_DEL_MENSAJE" \
  "el mensaje de la tarjeta guarda la referencia de la nota que dejó"
assert_contains "$(cat "$HOME_B/recorder-notas/2.note")" "a. si, se construye" \
  "la nota del trabajo que se suelta lleva sus palabras"
assert_grep "El trabajo que esperaba sigue en marcha con ellas." "$HOME_B/recorder-notas/2.note" \
  "la nota del trabajo que se suelta dice que sigue en marcha"
pass "lo escrito en una tarjeta con trabajo en marcha también llega al buzón"

# ------------------------------- escenario: el mecanismo de decisión, de verdad

if "$ROOT/bin/fm-tasks-axi.sh" --help >/dev/null 2>&1; then
  HOME_C=$(nuevo_home decision-real real)
  backlog_de "$HOME_C" '# Backlog

## Queued
- [ ] tarea-cierra-de-verdad - Una decision real (repo: firstmate) (kind: captain) (since 2026-09-24) (hold: Decisión: dime si sigo con A o con B) (hold-kind: captain)
  Captain hold set: 2026-09-24T10:00:00Z'
  PUERTO_C=$(puerto_libre)
  arrancar "$HOME_C" "$PUERTO_C"

  PALABRAS="Sigo con la opción B, y no toques A."
  CUERPO_C=$(python3 -c 'import json,sys; print(json.dumps({"tarea":"tarea-cierra-de-verdad","texto":sys.argv[1]}))' "$PALABRAS")
  RESPUESTA_C=$(pide POST "http://127.0.0.1:$PUERTO_C/api/responder" "$CUERPO_C")
  assert_contains "$RESPUESTA_C" '"ok": true' "responder cierra la decisión con el mecanismo real"

  HOY=$(date +%Y-%m-%d)
  assert_grep "- [x] tarea-cierra-de-verdad" "$HOME_C/data/backlog.md" \
    "la tarea queda cerrada en el backlog del home"
  assert_grep "$PALABRAS" "$HOME_C/data/backlog.md" \
    "las palabras exactas del capitán quedan escritas en el backlog"
  assert_grep "Resolution recorded by fm-captain-hold." "$HOME_C/data/backlog.md" \
    "queda el registro de resolución del mecanismo de decisiones"
  assert_grep "(done $HOY)" "$HOME_C/data/backlog.md" "la tarea queda cerrada con su fecha"
  pass "responder cierra de verdad la decisión: el backlog queda cerrado con las palabras del capitán"
else
  echo "skip: live: no hay tasks-axi, así que el cierre real de la decisión no se puede probar aquí"
fi

# --------------------- escenario: la tarjeta despierta a firstmate de verdad

HOME_E=$(nuevo_home tarjeta real)
backlog_de "$HOME_E" '# Backlog

## Queued
- [ ] tarea-tarjeta - Una decision escrita en su tarjeta (repo: firstmate) (kind: captain) (since 2026-09-25) (hold: Decisión: dime si borro las ramas de prueba o espero) (hold-kind: captain)
  Captain hold set: 2026-09-25T20:00:00Z
- [ ] tarea-suelta - Una tarea que ya no espera nada (repo: firstmate) (kind: ship) (since 2026-09-25)'
PUERTO_E=$(puerto_libre)
arrancar "$HOME_E" "$PUERTO_E"

# La pregunta del capitán, con la misma forma que la que se perdió de verdad.
PREGUNTA_TARJETA='¿Esto no lo hiciste ya antes?'
pide POST "http://127.0.0.1:$PUERTO_E/api/responder" \
  "$(python3 -c 'import json,sys; print(json.dumps({"tarea":"tarea-tarjeta","texto":sys.argv[1],"titulo":"Una decision escrita en su tarjeta"}))' "$PREGUNTA_TARJETA")" >/dev/null

NOTA=$(find "$HOME_E/state/inbox" -maxdepth 1 -name '*.note' -print -quit 2>/dev/null)
assert_present "${NOTA:-$HOME_E/state/inbox/NO-HAY-NOTA}" \
  "una pregunta escrita en la tarjeta deja su nota durable en el buzón de firstmate"
assert_grep "tarea-tarjeta" "${NOTA:-/dev/null}" "la nota de la tarjeta nombra la tarea"
assert_grep "$PREGUNTA_TARJETA" "${NOTA:-/dev/null}" "la nota lleva la pregunta del capitán tal cual"
assert_grep "check" "$HOME_E/state/.wake-queue" "la pregunta despierta a firstmate con su aviso"
pass "la pregunta escrita en una tarjeta deja su nota durable en el buzón y despierta a firstmate"

ID_E=$(pide GET "http://127.0.0.1:$PUERTO_E/api/conversacion" | python3 -c '
import json, sys
d = json.load(sys.stdin)["mensajes"]
print([m["id"] for m in d if m["de"] == "capitan"][-1])')
assert_grep "--reply-to $ID_E" "${NOTA:-/dev/null}" \
  "la nota dice cómo contestar emparejado con ese mensaje de la tarjeta"
assert_grep "La decisión queda cerrada con estas palabras." "${NOTA:-/dev/null}" \
  "la nota cuenta que el tablero ya cerró la decisión"
pass "la nota de la tarjeta dice cómo contestar emparejado y qué hizo el tablero"

ID_NOTA=$(basename "${NOTA:-x}" .note)
NOTA_DEL_MENSAJE=$(pide GET "http://127.0.0.1:$PUERTO_E/api/conversacion" | python3 -c '
import json, sys
d = json.load(sys.stdin)["mensajes"]
print([m["nota"] for m in d if m.get("tarea") == "tarea-tarjeta"][0])')
assert_equals "$ID_NOTA" "$NOTA_DEL_MENSAJE" \
  "el mensaje de la tarjeta guarda la referencia de la nota que dejó en el buzón"
pass "la conversación guarda la referencia de la nota que dejó la tarjeta"

comprobar "$PUERTO_E" "la tarjeta dice que su pregunta espera la respuesta de firstmate" '
import json, sys
d = json.load(sys.stdin)
tarjeta = [t for c in d["columnas"] for t in c["tarjetas"] if t["id"] == "tarea-tarjeta"][0]
assert tarjeta["pregunta"]["estado"] == "espera", tarjeta.get("pregunta")
print("espera")
'

FM_HOME="$HOME_E" "$TABLERO" reply --reply-to "$ID_E" "No: aquello era la limpieza de espacio. Esto sigue pendiente." >/dev/null

comprobar_charla "$PUERTO_E" "la respuesta de firstmate se empareja con la pregunta hecha en la tarjeta" '
import json, sys
d = json.load(sys.stdin)["mensajes"]
pregunta = [m for m in d if m.get("tarea") == "tarea-tarjeta" and m["de"] == "capitan"][-1]
assert pregunta["respuestas"], d
respuesta = [m for m in d if m["id"] == pregunta["respuestas"][0]][0]
assert "sigue pendiente" in respuesta["texto"], respuesta
assert respuesta["responde_a"] == pregunta["id"], respuesta
print("emparejado")
'

comprobar "$PUERTO_E" "la tarjeta pasa a contestada en cuanto firstmate responde" '
import json, sys
d = json.load(sys.stdin)
tarjeta = [t for c in d["columnas"] for t in c["tarjetas"] if t["id"] == "tarea-tarjeta"][0]
assert tarjeta["pregunta"]["estado"] == "contestada", tarjeta.get("pregunta")
print("contestada")
'

assert_equals "1" "$(find "$HOME_E/state/inbox" -maxdepth 1 -name '*.note' | wc -l)" \
  "cerrar la decisión y avisar no duplica la nota de la tarjeta"
pass "la tarjeta deja una sola nota aunque el tablero cierre la decisión"

# Una tarjeta que ya no espera nada no puede cerrar nada, pero lo que escribe el
# capitán no se pierde: queda guardado, avisado y dicho en el aviso.
AVISO_SUELTA=$(pide POST "http://127.0.0.1:$PUERTO_E/api/responder" \
  '{"tarea":"tarea-suelta","texto":"Una pregunta sobre algo que ya no espera nada."}')
assert_contains "$AVISO_SUELTA" '"ok": true' \
  "una tarjeta sin decisión que cerrar no pierde la pregunta del capitán"
assert_contains "$AVISO_SUELTA" "no se ha podido cerrar" \
  "el aviso dice claramente que la decisión no se cerró"
assert_grep "Una pregunta sobre algo que ya no espera nada." \
  "$(find "$HOME_E/state/inbox" -maxdepth 1 -name '*.note' -newer "$NOTA" -print -quit)" \
  "la pregunta llega al buzón aunque la decisión no se pueda cerrar"
pass "una tarjeta sin nada que cerrar guarda y avisa igual la pregunta del capitán"

# -------------------------------------- escenario: el chat y el buzón de firstmate

HOME_D=$(nuevo_home buzon real)
backlog_de "$HOME_D" '# Backlog

## Queued
- [ ] tarea-quieta - Un trabajo previsto (repo: firstmate) (kind: ship) (since 2026-09-25)'
PUERTO_D=$(puerto_libre)
arrancar "$HOME_D" "$PUERTO_D"

MENSAJE="Propuesta nueva: ¿y si el radar mirase también los lunes?"
pide POST "http://127.0.0.1:$PUERTO_D/api/mensaje" \
  "$(python3 -c 'import json,sys; print(json.dumps({"texto":sys.argv[1]}))' "$MENSAJE")" >/dev/null

NOTA=$(find "$HOME_D/state/inbox" -maxdepth 1 -name '*.note' -print -quit 2>/dev/null)
assert_present "${NOTA:-$HOME_D/state/inbox/NO-HAY-NOTA}" "el mensaje deja una nota durable en el buzón de firstmate"
assert_grep "$MENSAJE" "${NOTA:-/dev/null}" "la nota lleva el mensaje del capitán"
assert_grep "Tablero" "${NOTA:-/dev/null}" "la nota dice de dónde viene"
assert_grep "check" "$HOME_D/state/.wake-queue" "el mensaje despierta a firstmate con su aviso"
pass "el mensaje libre deja su nota durable en el buzón y despierta a firstmate"

comprobar_charla "$PUERTO_D" "la conversación guarda el mensaje del capitán sin respuesta todavía" '
import json, sys
d = json.load(sys.stdin)
capitan = [m for m in d["mensajes"] if m["de"] == "capitan"]
assert len(capitan) == 1 and capitan[0]["respuestas"] == [], d
assert "lunes" in capitan[0]["texto"], capitan
print("1 esperando")
'

# ------------------------------- escenario: la respuesta de firstmate empareja

SALIDA=$(FM_HOME="$HOME_D" "$TABLERO" reply "Sí: lo pruebo y te digo el resultado.") \
  || fail "el comando de respuesta tiene que funcionar: $SALIDA"
assert_contains "$SALIDA" "guardado" "reply confirma que guardó la respuesta"

comprobar_charla "$PUERTO_D" "la respuesta de firstmate se empareja con el mensaje que la esperaba" '
import json, sys
d = json.load(sys.stdin)["mensajes"]
capitan = [m for m in d if m["de"] == "capitan"][0]
primates = [m for m in d if m["de"] == "firstmate"]
assert len(primates) == 1, d
assert primates[0]["responde_a"] == capitan["id"], d
assert capitan["respuestas"] == [primates[0]["id"]], d
print("emparejado")
'

# Un segundo mensaje del capitán y una respuesta dirigida con --reply-to.
pide POST "http://127.0.0.1:$PUERTO_D/api/mensaje" \
  "$(python3 -c 'import json,sys; print(json.dumps({"texto":sys.argv[1]}))' "Otra cosa distinta, para el segundo.")" >/dev/null
SEGUNDO=$(pide GET "http://127.0.0.1:$PUERTO_D/api/conversacion" | python3 -c '
import json, sys
d = json.load(sys.stdin)["mensajes"]
print([m["id"] for m in d if m["de"] == "capitan"][-1])')
FM_HOME="$HOME_D" "$TABLERO" reply --reply-to "$SEGUNDO" "Contesto a esa en concreto." >/dev/null

comprobar_charla "$PUERTO_D" "--reply-to contesta al mensaje que se le dice, no al más viejo" '
import json, sys
d = json.load(sys.stdin)["mensajes"]
segundo = [m for m in d if m["de"] == "capitan"][-1]
primero = [m for m in d if m["de"] == "capitan"][0]
assert len(segundo["respuestas"]) == 1, d
assert len(primero["respuestas"]) == 1, d
respuesta = [m for m in d if m["id"] == segundo["respuestas"][0]][0]
assert respuesta["texto"] == "Contesto a esa en concreto.", respuesta
print("dirigido")
'

comprobar_charla "$PUERTO_D" "la conversación sobrevive a un reinicio del servidor" '
import json, sys
d = json.load(sys.stdin)["mensajes"]
assert len([m for m in d if m["de"] == "capitan"]) == 2, d
assert len([m for m in d if m["de"] == "firstmate"]) == 2, d
print("4 mensajes")
'

# ---------------------------- escenario: mover y quitar sólo lo piden

PANEL_ANTES=$(solo_panel "$PUERTO_D")
BACKLOG_ANTES=$(cat "$HOME_D/data/backlog.md")

pide POST "http://127.0.0.1:$PUERTO_D/api/peticion" \
  '{"tarea":"tarea-quieta","accion":"mover","destino":"ahora","columna":"Ahora mismo","titulo":"Un trabajo previsto"}' >/dev/null
pide POST "http://127.0.0.1:$PUERTO_D/api/peticion" \
  '{"tarea":"tarea-quieta","accion":"quitar","titulo":"Un trabajo previsto"}' >/dev/null

assert_equals "$BACKLOG_ANTES" "$(cat "$HOME_D/data/backlog.md")" \
  "mover y quitar no tocan el backlog: sólo lo piden"
assert_equals "$PANEL_ANTES" "$(solo_panel "$PUERTO_D")" \
  "mover y quitar no cambian ninguna columna"
pass "mover y quitar no tocan el backlog ni cambian ninguna columna: sólo lo piden"

PETICIONES=$(cat "$HOME_D"/state/inbox/*.note)
assert_contains "$PETICIONES" "pide mover la tarea tarea-quieta" "el encargo de mover llega al buzón"
assert_contains "$PETICIONES" "Ahora mismo" "el encargo de mover dice a qué columna"
assert_contains "$PETICIONES" "pide quitar la tarea tarea-quieta" "el encargo de quitar llega al buzón"
assert_contains "$PETICIONES" "confírmalo con él" "el encargo de quitar pide confirmación antes de borrar"
pass "mover y quitar dejan su encargo en el buzón, con la confirmación del borrado pedida"
assert_equals "4" "$(find "$HOME_D/state/inbox" -maxdepth 1 -name '*.note' | wc -l)" \
  "cada mensaje del chat y cada encargo deja una sola nota, sin duplicar ninguna"
pass "el chat y las peticiones de mover y quitar siguen dejando una nota cada uno"

comprobar_charla "$PUERTO_D" "las dos peticiones quedan en la conversación como lo que son" '
import json, sys
d = json.load(sys.stdin)["mensajes"]
clases = [m["tipo"] for m in d if m["de"] == "capitan"]
assert clases.count("peticion") == 2, clases
assert clases.count("mensaje") == 2, clases
pedido = [m for m in d if m["tipo"] == "peticion"][0]
assert "muevan" in pedido["texto"] and "jerga" not in pedido["texto"], pedido
print("2 peticiones")
'

assert_contains "$(pide POST "http://127.0.0.1:$PUERTO_D/api/mensaje" \
  '{"texto":"La misma página abierta como localhost también escribe."}' "http://localhost:$PUERTO_D")" \
  '"ok": true' "la propia página servida como localhost puede escribir"
pass "la propia página servida como localhost puede escribir: el alias de loopback no se rechaza"
assert_contains "$(pide POST "http://127.0.0.1:$PUERTO_D/api/mensaje" \
  '{"texto":"Esto viene de otra página."}' "http://otra-pagina.example")" \
  '"ok": false' "una página ajena sigue sin poder escribir en el tablero"
pass "una página ajena sigue rechazada aunque el alias local se acepte"

# ------------------------------------------- escenario: arrancar, parar, estado

assert_contains "$(FM_HOME="$HOME_D" FM_TABLERO_BIND=127.0.0.1 FM_TABLERO_PORT="$PUERTO_D" "$TABLERO" status)" \
  "Arrancado" "status dice que está arrancado"
pass "status dice que está arrancado"
assert_equals "http://127.0.0.1:$PUERTO_D" \
  "$(FM_HOME="$HOME_D" FM_TABLERO_BIND=127.0.0.1 FM_TABLERO_PORT="$PUERTO_D" "$TABLERO" url)" \
  "url dice con qué dirección se abre desde esta máquina"

if python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.2", 0))' 2>/dev/null; then
  HOME_F=$(nuevo_home bind-sin-loopback)
  backlog_de "$HOME_F" '# Backlog'
  PUERTO_F=$(puerto_libre)
  arrancar "$HOME_F" "$PUERTO_F" 127.0.0.2
  assert_contains "$(FM_HOME="$HOME_F" FM_TABLERO_BIND=127.0.0.2 FM_TABLERO_PORT="$PUERTO_F" "$TABLERO" status)" \
    "http://127.0.0.2:$PUERTO_F" \
    "con un bind sin loopback, status anuncia la dirección que sí escucha"
  pass "con un bind sin loopback el tablero arranca y anuncia la dirección que escucha"
  FM_HOME="$HOME_F" "$TABLERO" stop >/dev/null
else
  echo "skip: live: esta máquina no puede escuchar en 127.0.0.2"
fi

FM_HOME="$HOME_A" "$TABLERO" stop >/dev/null
sleep 0.5
if escucha "$PUERTO_A"; then
  fail "después de pararlo no debe quedar nada escuchando"
fi
pass "stop lo para de verdad y deja de escuchar"
assert_contains "$(FM_HOME="$HOME_A" FM_TABLERO_PORT="$PUERTO_A" "$TABLERO" status)" \
  "Parado" "status dice que está parado"

assert_contains "$(FM_HOME="$HOME_A" "$TABLERO" --help)" "start" "la ayuda nombra start"
pass "la ayuda nombra start, stop, status, url y reply"

FUERA=$(FM_HOME="$HOME_A" FM_TABLERO_BIND=0.0.0.0 FM_TABLERO_PORT="$(puerto_libre)" \
  "$TABLERO" start 2>&1 || true)
assert_contains "$FUERA" "Tailscale" "no se abre el tablero a toda la máquina"
pass "no se abre el tablero a toda la máquina: sólo a Tailscale y a esta máquina"

exit 0
