#!/usr/bin/env bash
# tests/fm-tablero-pantalla.test.sh - the work board in a real browser.
#
# tests/assets/tablero-pantalla.cjs owns what is checked; this script only finds
# the browser, seeds a home whose columns and conversation are known, starts the
# real server through the shipped command, and hands the URL over. Everything a
# stub cannot prove is here: that the five columns and the two tabs render, that
# the console stays clean, that a poll does not eat what the captain is writing,
# and that answering from a card really closes the decision in the backlog.
#
# Chromium comes from a Playwright install; where there is none this case skips
# rather than passing quietly over a page nothing looked at.
#
# Environment:
#   FM_TABLERO_CAPTURAS   directory for the screenshots; unset means take none
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }

# Playwright is normally installed globally or dropped in the npx cache; neither
# is on Node's default resolution path, so both are looked for explicitly.
MOTOR=""
for candidato in \
  "$(npm root -g 2>/dev/null)/playwright" \
  "$HOME"/.npm/_npx/*/node_modules/playwright; do
  if [ -d "$candidato" ]; then MOTOR=$candidato; break; fi
done
if [ -z "$MOTOR" ]; then
  caso=$(cd "$ROOT" && node -e "try{console.log(require.resolve('playwright'))}catch(e){process.exit(1)}" 2>/dev/null) || caso=""
  [ -n "$caso" ] || { echo "skip: live: playwright absent"; exit 0; }
fi

TABLERO="$ROOT/bin/fm-tablero.sh"
TMP_ROOT=$(fm_test_tmproot fm-tablero-pantalla-tests)
SERVIDOR_PID=""

# shellcheck disable=SC2329 # invoked indirectly through the EXIT/INT/TERM trap below.
cleanup() {
  [ -n "$SERVIDOR_PID" ] || return 0
  kill "$SERVIDOR_PID" 2>/dev/null || true
  fm_test_cleanup
}
trap cleanup EXIT INT TERM

HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/data" "$HOME_DIR/state"
ln -s "$ROOT/bin" "$HOME_DIR/bin"
cp "$ROOT/.tasks.toml" "$HOME_DIR/.tasks.toml"
cat > "$HOME_DIR/data/backlog.md" <<'MD'
# Backlog

## In flight
- [ ] motor-de-aditivas - Motor de conflictos que en realidad se suman (repo: licitaciones-platform) (kind: ship) (since 2026-09-25)
  Deliverable of the finished work: report data/motor-de-aditivas/report.md
- [ ] barra-por-sobres - Barra por sobres y «Qué se pide» en la Hoja (repo: licitaciones-platform) (kind: ship) (since 2026-09-25)
## Queued
- [ ] aditivas-decidir - Checklist: decidir el modo del veredicto aditivo (repo: licitaciones-platform) (kind: captain) (since 2026-09-24) (hold: Medido el 24-sep: 8 de 14 conflictos eran dos partes que se complementan. Decisiones: a. se implementa el veredicto aditivo y en qué modo, con umbral 0,8? b. se aplica ya al expediente de prueba? c. la acción reutiliza el tipo que ya existe, recomendado?) (hold-kind: captain)
  Captain hold set: 2026-09-24T07:50:00Z
- [ ] portales-decidir - Portales: plan de cambios en la entrada (repo: licitaciones-platform) (kind: captain) (since 2026-09-24) (hold: Plan en data/plan-cambios-portales. D1 Catalunya: completo técnico con aviso, recomendado, o parcial. D2 PLACSP: lector nuevo apagado, recomendado. Di cuál.) (hold-kind: captain)
  Captain hold set: 2026-09-24T12:13:03Z
- [ ] avisar-herramienta-rota - Avisar al arrancar si una herramienta está rota (repo: firstmate) (kind: ship) (since 2026-09-25)
## Done
- [x] resumen-ancho - El resumen ocupa todo el recuadro (repo: licitaciones-platform) (kind: ship) (done 2026-09-25)
  local main
- [x] radar-frases - Radar sin las dos frases que sobraban (repo: licitaciones-platform) (kind: ship) (done 2026-09-25)
  local main
MD
printf 'window=default:w1:p1\nharness=pi\nproject=/home/firstmate/projects/licitaciones-platform\n' > "$HOME_DIR/state/motor-de-aditivas.meta"
printf 'done: ready in branch fm/motor-de-aditivas\n' > "$HOME_DIR/state/motor-de-aditivas.status"
printf 'window=default:w1:p2\nharness=pi\n' > "$HOME_DIR/state/barra-por-sobres.meta"
printf 'working: paso 3 en marcha\n' > "$HOME_DIR/state/barra-por-sobres.status"
printf 'entered: 2026-09-25T10:00:00Z\nexpected_return: 2026-09-26\n' > "$HOME_DIR/state/.afk-contract"

# La conversación es durable, así que se siembra escribiéndola con el propio
# comando del tablero: primero un mensaje del capitán, luego su respuesta.
PUERTO=$(python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
)

FM_HOME="$HOME_DIR" FM_TABLERO_BIND=127.0.0.1 FM_TABLERO_PORT="$PUERTO" "$TABLERO" start >/dev/null \
  || fail "arrancar el tablero para la prueba de navegador"
SERVIDOR_PID=$(cat "$HOME_DIR/state/tablero/servidor.pid")

# Un mensaje del capitán y su respuesta, ya emparejados, más uno sin responder.
BASE="http://127.0.0.1:$PUERTO"
pide_chat() {  # <texto>
  python3 - "$BASE/api/mensaje" "$1" <<'PY'
import json, sys, urllib.request
cuerpo = json.dumps({"texto": sys.argv[2]}).encode()
peticion = urllib.request.Request(sys.argv[1], data=cuerpo, method="POST")
peticion.add_header("Content-Type", "application/json")
urllib.request.urlopen(peticion, timeout=20).read()
PY
}

pide_chat "¿Cómo va lo del motor de conflictos? ¿Se puede ya aplicar al expediente de prueba?"
FM_HOME="$HOME_DIR" "$TABLERO" reply "Medido: 8 de los 14 conflictos eran dos partes que se complementan. Te lo dejo en la tarjeta." >/dev/null
pide_chat "Y para el móvil, ¿me lo puedo llevar de una en una?"

# Una pregunta escrita en la tarjeta de otra tarea, ya contestada por firstmate:
# así la pantalla tiene que enseñar las dos caras, sin contestar y contestada.
pide_tarjeta() {  # <tarea> <texto>
  python3 - "$BASE/api/responder" "$1" "$2" <<'PY'
import json, sys, urllib.request
cuerpo = json.dumps({"tarea": sys.argv[2], "texto": sys.argv[3]}).encode()
peticion = urllib.request.Request(sys.argv[1], data=cuerpo, method="POST")
peticion.add_header("Content-Type", "application/json")
urllib.request.urlopen(peticion, timeout=20).read()
PY
}
pide_tarjeta "portales-decidir" "¿El plan de portales lo cierro yo o lo cierras tú?"
ID_TARJETA=$(python3 - "$BASE/api/conversacion" <<'PY'
import json, sys, urllib.request
d = json.load(urllib.request.urlopen(sys.argv[1], timeout=20))["mensajes"]
print([m["id"] for m in d if m.get("tarea") == "portales-decidir"][-1])
PY
)
FM_HOME="$HOME_DIR" "$TABLERO" reply --reply-to "$ID_TARJETA" \
  "Lo cierro yo: te dejo el plan en la tarjeta cuando lo tenga." >/dev/null

MOTOR_DIR=$(dirname "$MOTOR")
if [ -n "${FM_TABLERO_CAPTURAS:-}" ]; then
  export TABLERO_CAPTURAS="$FM_TABLERO_CAPTURAS"
else
  unset TABLERO_CAPTURAS
fi
export TABLERO_BASE="$BASE"
export TABLERO_MUTAR=1
export NODE_PATH="$MOTOR_DIR${NODE_PATH:+:$NODE_PATH}"

if ! node "$ROOT/tests/assets/tablero-pantalla.cjs"; then
  fail "la pantalla en un navegador de verdad"
fi
pass "la pantalla se comporta en un navegador de verdad, sin errores en la consola"

# El home acaba con la decisión cerrada y el mensaje del capitán en su buzón:
# eso es lo que hace que la prueba valga y no sea sólo pintura.
assert_grep "- [x] aditivas-decidir" "$HOME_DIR/data/backlog.md" \
  "responder desde la tarjeta cierra la decisión en el backlog"
assert_grep "Sí, adelante con lo recomendado." "$HOME_DIR/data/backlog.md" \
  "la respuesta del capitán queda escrita con sus palabras"
grep -rqF "móvil" "$HOME_DIR/state/inbox/" \
  || fail "el mensaje escrito en el chat de la página tiene que llegar al buzón"
pass "lo escrito en la página llega al backlog y al buzón de firstmate"

exit 0
