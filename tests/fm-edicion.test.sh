#!/usr/bin/env bash
# tests/fm-edicion.test.sh - the firstmate half of the /edicion marking route.
#
# Covers the route end to end over a fixture project clone and a fixture home:
# abrir resolves a screen from the clone's own registry, starts the marking
# surface, and reuses a surface that is already serving; marcas lists deliveries
# without applying anything; aplicar turns marks into one queue item plus a
# filled brief that quotes every marked block; a lost-anchor mark is never
# applied blindly, is presented with its original context, and keeps its
# delivery open until it is delivered explicitly to a live task; cerrar refuses
# that delivery and later records the closed result. The fixture tasks-axi keeps
# the queue side observable without the real backlog tool.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

EDICION="$ROOT/bin/fm-edicion.sh"
TMP_ROOT=$(fm_test_tmproot fm-edicion)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)

SURFACE_PIDS=()

kill_surfaces() {
  local p
  for p in ${SURFACE_PIDS[@]+"${SURFACE_PIDS[@]}"}; do
    kill "$p" 2>/dev/null || true
  done
}

trap 'kill_surfaces; fm_test_cleanup' EXIT
trap 'kill_surfaces; fm_test_cleanup; exit 130' INT
trap 'kill_surfaces; fm_test_cleanup; exit 143' TERM

# --- fixtures ---------------------------------------------------------------

# make_world <name>: a fixture home with one project clone carrying the marking
# surface, its screen registry, and a fake tasks-axi that logs every add.
make_world() {
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/home/data" "$dir/home/state" "$dir/home/config" \
    "$dir/home/projects/demo-plataforma/tools/edicion" "$dir/fakebin"
  printf -- '- demo-plataforma [local-only] - plataforma de demo (added 2026-09-23)\n' \
    >"$dir/home/data/projects.md"
  cat >"$dir/home/projects/demo-plataforma/tools/edicion/pantallas.json" <<'JSON'
{
  "version": 1,
  "pantallas": [
    { "nombre": "redactar", "ruta": "/preparacion/redactar" },
    { "nombre": "resumen", "ruta": "/preparacion/resumen" }
  ]
}
JSON
  cat >"$dir/home/projects/demo-plataforma/tools/edicion/serve.mjs" <<'JS'
import http from "node:http";
const server = http.createServer((req, res) => {
  res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
  res.end("<html><body><main><h2>Programa de los cursos de creacion</h2></main></body></html>");
});
server.listen(0, "127.0.0.1", () => {
  console.log(`Superficie de marcado en http://127.0.0.1:${server.address().port}/ (Ctrl+C para parar)`);
});
JS
  cat >"$dir/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
set -u
printf 'ARGS %s\n' "$*" >> "$FAKE_TASKS_LOG"
case "${1:-}" in
  add)
    n=$(grep -c '^ARGS add' "$FAKE_TASKS_LOG" || true)
    prev=
    for a in "$@"; do
      if [ "$prev" = --body-file ] && [ -f "$a" ]; then
        cp "$a" "$FAKE_TASKS_LOG.cuerpo.$n"
      fi
      prev=$a
    done
    printf 'ok: added edicion-tarea-%s -> Queued\n' "$n"
    ;;
esac
exit 0
SH
  chmod +x "$dir/fakebin/tasks-axi"
  : >"$dir/tasks.log"
  printf '%s\n' "$dir"
}

# Stubbed tmux so a real fm-send can reach a live local task, the same shape
# tests/fm-send-inbox.test.sh uses.
make_tmux_stub() {
  local dir=$1
  cat >"$dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    [ "$literal" = 1 ] && printf '%s\n' "${1:-}" >> "$FM_SEND_LOG"
    exit 0 ;;
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) printf 'fm-t1\n'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$dir/fakebin/tmux"
  cat >"$dir/fakebin/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$dir/fakebin/sleep"
}

add_live_task() {  # <world> <task-id>
  local dir=$1 id=$2
  make_tmux_stub "$dir"
  fm_write_meta "$dir/home/state/$id.meta" "window=sess:fm-$id" "kind=ship" "harness=claude"
}

# write_delivery <world> <pantalla> <stamp> <mark-json...>
write_delivery() {
  local dir=$1 pantalla=$2 stamp=$3
  shift 3
  local marcas="" m
  for m in "$@"; do
    if [ -n "$marcas" ]; then
      marcas="$marcas,"$'\n'"$m"
    else
      marcas=$m
    fi
  done
  mkdir -p "$dir/home/data/edicion"
  {
    printf '{\n'
    printf '  "version": 1,\n'
    printf '  "pantalla": "%s",\n' "$pantalla"
    printf '  "url": "http://127.0.0.1:4178/preparacion/%s",\n' "$pantalla"
    printf '  "capturado_en": "2026-09-23T18:40:12Z",\n'
    printf '  "huella": "sha256-de-prueba",\n'
    printf '  "marcas": [\n'
    printf '%s\n' "$marcas"
    printf '  ]\n'
    printf '}\n'
  } >"$dir/home/data/edicion/$pantalla-$stamp.json"
  printf '# Entrega de marcas: %s\n' "$pantalla" \
    >"$dir/home/data/edicion/$pantalla-$stamp.md"
}

marca_json() {  # <id> <bloque> <texto_bloque> <tipo> <texto> <ancla>
  printf '    {"id":"%s","bloque":"%s","ruta":"html > body > main > section:nth-of-type(2) > h2","texto_bloque":"%s","tipo":"%s","texto":"%s","creado_en":"2026-09-23T18:41:03Z","ancla":"%s"}' \
    "$1" "$2" "$3" "$4" "$5" "$6"
}

# --- runners ----------------------------------------------------------------

run_edicion() {  # <world> <err-file> [KEY=VAL...] -- <args...>
  local dir=$1 err=$2
  shift 2
  local envs=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do
    envs+=("$1")
    shift
  done
  shift
  : >"$dir/send.log"
  env PATH="$dir/fakebin:$PATH" \
    FM_ROOT_OVERRIDE="$dir/home" FM_HOME="$dir/home" \
    FM_DATA_OVERRIDE="$dir/home/data" FM_STATE_OVERRIDE="$dir/home/state" \
    FM_EDICION_NO_ABRIR=1 FAKE_TASKS_LOG="$dir/tasks.log" \
    FM_SEND_LOG="$dir/send.log" FM_SEND_SETTLE=0 \
    ${envs[@]+"${envs[@]}"} \
    "$EDICION" "$@" 2>"$err"
}

track_surface() {  # <world>
  local dir=$1 rec="$1/home/data/edicion/.servidor" pid
  [ -f "$rec" ] || return 0
  pid=$(cut -f1 "$rec")
  case "$pid" in '' | *[!0-9]*) return 0 ;; esac
  SURFACE_PIDS+=("$pid")
}

record_body() {  # <record>
  bash -c '. "$1"; fm_task_inbox_body "$2"' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$2"
}

brief_of() {  # <world> <task-id>
  printf '%s\n' "$1/home/data/$2/brief.md"
}

sidecar_of() {  # <world> <pantalla> <stamp>
  printf '%s/home/data/edicion/%s-%s.aplicado.json\n' "$1" "$2" "$3"
}

# --- abrir ------------------------------------------------------------------

test_abrir_starts_and_reuses_surface() {
  local dir err out url pid
  dir=$(make_world abrir)
  err="$dir/err"

  out=$(run_edicion "$dir" "$err" -- abrir redactar) ||
    fail "abrir should resolve a screen from the clone registry: $(cat "$err")"
  assert_contains "$out" "proyecto: $dir/home/projects/demo-plataforma" \
    "abrir should name the project clone it opened"
  assert_contains "$out" "servidor: arrancado ahora" \
    "abrir should say it started the surface"
  assert_contains "$out" "las marcas quedaran en: $dir/home/data/edicion" \
    "abrir should say where the marks will land"
  url=$(printf '%s\n' "$out" | awk -F': ' '/^direccion local: /{print $2}')
  case "$url" in
    http://127.0.0.1:*/preparacion/redactar) : ;;
    *) fail "abrir should print the replica address, got '$url'" ;;
  esac
  track_surface "$dir"
  pid=$(cut -f1 "$dir/home/data/edicion/.servidor")
  kill -0 "$pid" 2>/dev/null || fail "the surface should be running after abrir"

  out=$(run_edicion "$dir" "$err" -- abrir resumen) ||
    fail "a second abrir should reuse the running surface: $(cat "$err")"
  assert_contains "$out" "servidor: ya estaba arrancado" \
    "abrir should report an already-running surface instead of starting a second one"
  assert_contains "$out" "http://127.0.0.1:" "/preparacion/resumen" ||
    fail "the second screen should resolve to its own replica path"
  pass "abrir: screen resolution, surface start, and reuse over one running surface"
}

test_abrir_refuses_without_surface_or_screen() {
  local dir err rc
  dir=$(make_world abrir-refuses)
  err="$dir/err"

  run_edicion "$dir" "$err" -- abrir noexiste >/dev/null
  rc=$?
  [ "$rc" -ne 0 ] || fail "an unknown screen should be refused"
  assert_contains "$(cat "$err")" "no esta en el registro" \
    "an unknown screen should name the registry that does not list it"

  rm -f "$dir/home/projects/demo-plataforma/tools/edicion/serve.mjs"
  run_edicion "$dir" "$err" -- abrir redactar >/dev/null
  rc=$?
  [ "$rc" -ne 0 ] || fail "a missing surface should be refused"
  assert_contains "$(cat "$err")" "tools/edicion/serve.mjs" \
    "a missing surface should name the file the platform half must provide"
  pass "abrir: an unknown screen and an absent platform half both refuse loudly"
}

# --- marcas -----------------------------------------------------------------

test_marcas_lists_without_applying() {
  local dir err out rc
  dir=$(make_world marcas)
  err="$dir/err"
  write_delivery "$dir" redactar 20260923-184012 \
    "$(marca_json m-001 b-3f9a1c2e 'Programa de los cursos de creacion' cambio 'lo que se pide, literal' estable)" \
    "$(marca_json m-003 b-9c0d 'Plazos de entrega' cambio 'ahora el plazo es de 20 dias' perdida)"

  out=$(run_edicion "$dir" "$err" -- marcas)
  rc=$?
  expect_code 0 "$rc" "marcas should succeed"
  assert_contains "$out" "redactar-20260923-184012.json" "marcas should list the delivery"
  assert_contains "$out" "Programa de los cursos de creacion" "marcas should show the marked block text"
  assert_contains "$out" "lo que se pide, literal" "marcas should show what the mark asks for"
  assert_contains "$out" "ancla: perdida" "marcas should flag a lost anchor"
  assert_contains "$out" "1 aplicables, 1 en revision" "marcas should count both classes"
  assert_equals "" "$(cat "$dir/tasks.log")" "marcas must not create any work"

  out=$(run_edicion "$dir" "$err" -- marcas --ultimas)
  assert_contains "$out" "redactar-20260923-184012.json" "--ultimas should list the newest delivery"
  pass "marcas: readable listing of a pending delivery, nothing applied"
}

test_marcas_refuses_malformed_delivery() {
  local dir err rc
  dir=$(make_world marcas-rota)
  err="$dir/err"
  mkdir -p "$dir/home/data/edicion"
  printf '{"version":1,"pantalla":"redactar","marcas":[{"id":"m-001"}\n' \
    >"$dir/home/data/edicion/redactar-20260923-185000.json"

  run_edicion "$dir" "$err" -- marcas >/dev/null
  rc=$?
  expect_code 2 "$rc" "marcas should refuse an unreadable delivery"
  assert_contains "$(cat "$err")" "entrega mal formada" \
    "the refusal should name the malformed delivery"
  pass "marcas: an unreadable delivery refuses instead of dying inside jq"
}

test_marcas_and_aplicar_refuse_non_scalar_fields() {
  local dir err rc
  dir=$(make_world escalares)
  err="$dir/err"
  write_delivery "$dir" resumen 20260923-192000 \
    "$(marca_json m-001 b-1 'Resumen de la empresa' cambio 'anade una linea' estable)"
  write_delivery "$dir" redactar 20260923-193000 \
    '{"id":"m-001","bloque":"b-1","ruta":"html > body","texto_bloque":"Programa de los cursos","tipo":["cambio"],"texto":"cambia esto","creado_en":"2026-09-23T18:41:03Z","ancla":"estable"}'

  run_edicion "$dir" "$err" -- marcas >/dev/null
  rc=$?
  expect_code 2 "$rc" "marcas should refuse a delivery whose mark fields are not scalars"
  assert_contains "$(cat "$err")" "entrega mal formada" \
    "the refusal should name the malformed delivery"

  run_edicion "$dir" "$err" -- aplicar >/dev/null
  rc=$?
  expect_code 2 "$rc" "aplicar should refuse a sweep containing a non-scalar delivery"
  assert_contains "$(cat "$err")" "entrega mal formada" \
    "aplicar should name the malformed delivery"
  assert_equals "" "$(cat "$dir/tasks.log")" \
    "a sweep with a malformed delivery must not create a task"
  [ ! -e "$(sidecar_of "$dir" redactar 20260923-193000)" ] ||
    fail "a malformed delivery must not get a sidecar"
  pass "marcas/aplicar: a delivery with non-scalar mark fields refuses loudly"
}

# --- aplicar ----------------------------------------------------------------

test_aplicar_creates_task_and_quotes_blocks() {
  local dir err out rc brief side
  dir=$(make_world aplicar)
  err="$dir/err"
  write_delivery "$dir" redactar 20260923-184012 \
    "$(marca_json m-001 b-3f9a1c2e 'Programa de los cursos de creacion' cambio 'lo que se pide, literal' estable)" \
    "$(marca_json m-002 b-77aa11 'Bases de la convocatoria' quitar 'sobra este parrafo entero' estable)" \
    "$(marca_json m-003 b-9c0d 'Plazos de entrega' cambio 'ahora el plazo es de 20 dias' perdida)"

  out=$(run_edicion "$dir" "$err" -- aplicar)
  rc=$?
  expect_code 3 "$rc" "a delivery with a lost anchor should report the open question"
  assert_contains "$out" "tarea creada: edicion-tarea-1" "aplicar should create the queue item"
  assert_contains "$out" "modo: local-only (proyecto demo-plataforma)" \
    "aplicar should resolve the mode from the project's registered posture"

  assert_contains "$(cat "$dir/tasks.log")" "--kind ship --repo demo-plataforma" \
    "the queue item should be a ship task for the project"
  assert_contains "$(cat "$dir/tasks.log.cuerpo.1")" "redactar-20260923-184012.json" \
    "the queue item body should name the delivery it came from"

  brief=$(brief_of "$dir" edicion-tarea-1)
  assert_present "$brief" "aplicar should write the task brief"
  assert_contains "$(cat "$brief")" "## Captain's intent" "the brief should carry the ask"
  assert_contains "$(cat "$brief")" "Programa de los cursos de creacion" \
    "each instruction should quote the marked block text"
  assert_contains "$(cat "$brief")" "lo que se pide, literal" \
    "each instruction should quote what the mark asks for"
  assert_contains "$(cat "$brief")" "Bases de la convocatoria" \
    "every stable mark should become an instruction"
  assert_contains "$(cat "$brief")" "Delivery contract: mode=local-only" \
    "the brief should record the resolved delivery mode"
  assert_no_grep '{TASK}' "$brief" "the brief should have no leftover placeholder"
  assert_no_grep '{FIRSTMATE_SPEC}' "$brief" "the brief should have no leftover placeholder"
  assert_no_grep 'ahora el plazo es de 20 dias' "$brief" \
    "a lost-anchor mark must never be applied blindly"

  assert_contains "$out" "bloque citado: \"Plazos de entrega\"" \
    "the open question should present the lost mark's original context"
  assert_contains "$out" "ruta original: html > body > main > section:nth-of-type(2) > h2" \
    "the open question should present the lost mark's original route"
  assert_contains "$out" "ahora el plazo es de 20 dias" \
    "the open question should present what that mark asked for"
  assert_contains "$out" "Pregunta abierta" "the open question should actually ask"
  assert_contains "$out" "--tarea edicion-tarea-1 --marca m-003" \
    "the open question for a task-backed delivery should name its task"

  side=$(sidecar_of "$dir" redactar 20260923-184012)
  assert_present "$side" "aplicar should leave the delivery as a durable record"
  assert_equals "m-001 m-002" "$(jq -r '.entregadas | join(" ")' "$side")" \
    "the sidecar should record the delivered marks"
  assert_equals "m-003" "$(jq -r '.pendientes | join(" ")' "$side")" \
    "the sidecar should record the held-back mark"
  assert_equals "edicion-tarea-1" "$(jq -r '.tarea' "$side")" \
    "the sidecar should bind the delivery to its task"
  pass "aplicar: one queue item, one brief quoting every marked block, lost mark held back"
}

test_aplicar_groups_deliveries_into_one_task() {
  local dir err out rc brief
  dir=$(make_world agrupar)
  err="$dir/err"
  write_delivery "$dir" redactar 20260923-184012 \
    "$(marca_json m-001 b-1 'Programa de los cursos de creacion' cambio 'cambia este titulo' estable)"
  write_delivery "$dir" resumen 20260923-184500 \
    "$(marca_json m-001 b-2 'Resumen de la empresa' cambio 'anade una linea al resumen' estable)"

  out=$(run_edicion "$dir" "$err" -- aplicar)
  rc=$?
  expect_code 0 "$rc" "two clean deliveries should apply without an open question"
  assert_equals "1" "$(grep -c '^ARGS add' "$dir/tasks.log" || true)" \
    "grouped deliveries should create exactly one queue item"

  brief=$(brief_of "$dir" edicion-tarea-1)
  assert_contains "$(cat "$brief")" "Programa de los cursos de creacion" \
    "the grouped brief should carry the first delivery's block"
  assert_contains "$(cat "$brief")" "Resumen de la empresa" \
    "the grouped brief should carry the second delivery's block"
  assert_equals "edicion-tarea-1" "$(jq -r '.tarea' "$(sidecar_of "$dir" redactar 20260923-184012)")" \
    "the first delivery should point at the shared task"
  assert_equals "edicion-tarea-1" "$(jq -r '.tarea' "$(sidecar_of "$dir" resumen 20260923-184500)")" \
    "the second delivery should point at the shared task"
  pass "aplicar: several deliveries group into one task and one brief"
}

test_aplicar_refuses_malformed_and_reapplied() {
  local dir err rc
  dir=$(make_world refuses)
  err="$dir/err"
  mkdir -p "$dir/home/data/edicion"
  printf '{"version":1,"pantalla":"redactar","marcas":[{"id":"m-001","ancla":"estable"}]}\n' \
    >"$dir/home/data/edicion/redactar-20260923-190000.json"

  run_edicion "$dir" "$err" -- aplicar >/dev/null
  rc=$?
  [ "$rc" -ne 0 ] || fail "a mark without texto should be refused"
  assert_contains "$(cat "$err")" "mal formada" "the refusal should name the malformed delivery"

  write_delivery "$dir" redactar 20260923-190100 \
    "$(marca_json m-001 b-1 'Bloque estable' cambio 'cambia esto' estable)"
  run_edicion "$dir" "$err" -- aplicar --fichero redactar-20260923-190100.json >/dev/null ||
    fail "the clean delivery should apply: $(cat "$err")"
  run_edicion "$dir" "$err" -- aplicar --fichero redactar-20260923-190100.json >/dev/null
  rc=$?
  [ "$rc" -ne 0 ] || fail "naming an already-applied delivery again should be refused"
  assert_contains "$(cat "$err")" "ya se aplico" \
    "the refusal should say the delivery already has a task"

  run_edicion "$dir" "$err" -- aplicar --fichero redactar-20260923-190100.json --marca m-999 >/dev/null
  rc=$?
  [ "$rc" -ne 0 ] || fail "an unknown mark id should be refused"
  assert_contains "$(cat "$err")" "no esta en" "the refusal should name the unknown mark"
  pass "aplicar: malformed deliveries, repeat application, and unknown marks all refuse"
}

test_aplicar_steers_live_task_and_checks_input() {
  local dir err out rc brief
  dir=$(make_world live)
  err="$dir/err"
  add_live_task "$dir" t1
  write_delivery "$dir" redactar 20260923-191500 \
    "$(marca_json m-001 b-1 'Programa de los cursos de creacion' cambio 'primera linea' estable)" \
    "$(marca_json m-002 b-2 'Bases de la convocatoria' cambio 'linea uno\nlinea dos' estable)"

  out=$(run_edicion "$dir" "$err" -- aplicar --fichero redactar-20260923-191500.json --tarea t1)
  rc=$?
  expect_code 0 "$rc" "steering a live task should succeed"
  assert_equals "" "$(cat "$dir/tasks.log")" \
    "--tarea must not create a queue item"
  assert_contains "$out" "marcas entregadas a la tarea t1" "the steer should name the live task"
  assert_contains "$(record_body _ "$dir/home/state/t1.inbox/001.msg")" "Bases de la convocatoria" \
    "the steer should quote the marked block"
  assert_equals "t1" "$(jq -r '.tarea' "$(sidecar_of "$dir" redactar 20260923-191500)")" \
    "the sidecar should record the live task"

  write_delivery "$dir" resumen 20260923-192000 \
    "$(marca_json m-009 b-9 'Resumen de la empresa' cambio 'linea uno\nlinea dos' estable)"
  run_edicion "$dir" "$err" -- aplicar --fichero resumen-20260923-192000.json --modo inventado >/dev/null
  rc=$?
  expect_code 2 "$rc" "an unknown delivery mode should be refused"
  assert_contains "$(cat "$err")" "--modo debe ser" "the refusal should name the valid modes"

  run_edicion "$dir" "$err" -- aplicar --fichero resumen-20260923-192000.json >/dev/null ||
    fail "the multi-line delivery should apply: $(cat "$err")"
  brief=$(brief_of "$dir" edicion-tarea-1)
  assert_contains "$(cat "$brief")" "linea uno" "a multi-line request should keep its first line"
  assert_contains "$(cat "$brief")" "linea dos" "a multi-line request should keep every line"
  pass "aplicar: --tarea steers a live task, and bad modes and multi-line text are handled"
}

# --- cerrar and the lost-anchor resolution ----------------------------------

test_cerrar_holds_until_lost_mark_is_delivered() {
  local dir err out rc side rec body
  dir=$(make_world cerrar)
  err="$dir/err"
  add_live_task "$dir" t1
  write_delivery "$dir" redactar 20260923-184012 \
    "$(marca_json m-001 b-1 'Programa de los cursos de creacion' cambio 'lo que se pide, literal' estable)" \
    "$(marca_json m-003 b-9c0d 'Plazos de entrega' cambio 'ahora el plazo es de 20 dias' perdida)"

  run_edicion "$dir" "$err" -- aplicar >/dev/null || true
  side=$(sidecar_of "$dir" redactar 20260923-184012)
  assert_present "$side" "the delivery should be applied before closing it"

  run_edicion "$dir" "$err" -- cerrar redactar-20260923-184012.json >/dev/null
  rc=$?
  expect_code 2 "$rc" "a delivery with a held-back mark must not close"
  assert_contains "$(cat "$err")" "no se puede cerrar" "the refusal should say why"
  assert_contains "$(cat "$err")" "--marca m-003" \
    "the refusal should print the exact command that resolves the held-back mark"
  assert_present "$dir/home/data/edicion/redactar-20260923-184012.json" \
    "a refused close must leave the delivery in place"

  out=$(run_edicion "$dir" "$err" -- aplicar --fichero redactar-20260923-184012.json --tarea t1 --marca m-003)
  rc=$?
  expect_code 0 "$rc" "delivering the held-back mark to a live task should succeed"
  assert_contains "$out" "marcas entregadas a la tarea t1" \
    "the resolution should report the live task it reached"
  rec="$dir/home/state/t1.inbox/001.msg"
  assert_present "$rec" "the resolution should land as a durable steer record"
  body=$(record_body _ "$rec")
  assert_contains "$body" "Plazos de entrega" "the steer should quote the marked block"
  assert_contains "$body" "html > body > main > section:nth-of-type(2) > h2" \
    "the steer should carry the original route for re-anchoring"
  assert_contains "$body" "ahora el plazo es de 20 dias" \
    "the steer should carry what the mark asks for"
  assert_equals "" "$(jq -r '.pendientes | join(" ")' "$side")" \
    "the sidecar should clear the delivered mark"

  out=$(run_edicion "$dir" "$err" -- cerrar redactar-20260923-184012.json)
  rc=$?
  expect_code 0 "$rc" "the delivery should close once nothing is held back"
  assert_contains "$out" "resultado: tarea edicion-tarea-1" \
    "the close should record which task the delivery became"
  assert_present "$dir/home/data/edicion/aplicadas/redactar-20260923-184012.json" \
    "the closed delivery should move under aplicadas/"
  assert_present "$dir/home/data/edicion/aplicadas/redactar-20260923-184012.aplicado.json" \
    "the sidecar should move with its delivery"
  assert_contains "$(cat "$dir/home/data/edicion/aplicadas/registro.md")" "edicion-tarea-1" \
    "the ledger should record the result"

  run_edicion "$dir" "$err" -- cerrar redactar-20260923-184012.json >/dev/null
  rc=$?
  [ "$rc" -ne 0 ] || fail "closing a closed delivery should be refused"
  pass "cerrar: a held-back mark blocks the close, its delivery clears it, and the result is recorded"
}

test_marcas_and_aplicar_accept_hyphenated_screen() {
  local dir err out rc side
  dir=$(make_world guion)
  err="$dir/err"
  write_delivery "$dir" redactar-general 20260923-184012 \
    "$(marca_json m-001 b-1 'Programa de los cursos de creacion' cambio 'cambia este titulo' estable)"

  out=$(run_edicion "$dir" "$err" -- marcas)
  rc=$?
  expect_code 0 "$rc" "marcas should list a hyphenated screen delivery"
  assert_contains "$out" "redactar-general-20260923-184012.json" \
    "a hyphenated screen name must not hide its delivery"

  out=$(run_edicion "$dir" "$err" -- aplicar --fichero redactar-general-20260923-184012.json)
  rc=$?
  expect_code 0 "$rc" "aplicar should apply a hyphenated screen delivery: $(cat "$err")"
  assert_contains "$out" "tarea creada: edicion-tarea-1" \
    "the hyphenated delivery should become a task"
  side=$(sidecar_of "$dir" redactar-general 20260923-184012)
  assert_present "$side" "the hyphenated delivery should get its sidecar"
  pass "marcas/aplicar: a hyphenated screen name is a first-class delivery"
}

test_aplicar_refuses_delivery_outside_marks_dir() {
  local dir err rc
  dir=$(make_world fuera)
  err="$dir/err"
  mkdir -p "$dir/ajena"
  printf '{"version":1,"pantalla":"redactar","marcas":[{"id":"m-001","texto_bloque":"Bloque","texto":"cambia esto","ancla":"estable"}]}\n' \
    >"$dir/ajena/redactar-20260923-184012.json"

  run_edicion "$dir" "$err" -- aplicar --fichero "$dir/ajena/redactar-20260923-184012.json" >/dev/null
  rc=$?
  expect_code 2 "$rc" "a delivery outside the marks directory should be refused"
  assert_contains "$(cat "$err")" "$dir/home/data/edicion" \
    "the refusal should name the marks directory"
  assert_contains "$(cat "$err")" "fuera del directorio de marcas" \
    "the refusal should say the route never writes outside the marks directory"
  [ ! -e "$dir/ajena/redactar-20260923-184012.aplicado.json" ] ||
    fail "the route must not write outside the marks directory"
  pass "aplicar: a delivery path outside the marks directory is refused"
}

test_aplicar_keeps_unnamed_applicable_marks_owed() {
  local dir err rc side
  dir=$(make_world debidos)
  err="$dir/err"
  add_live_task "$dir" t1
  write_delivery "$dir" redactar 20260923-184012 \
    "$(marca_json m-001 b-1 'Programa de los cursos de creacion' cambio 'cambia este titulo' estable)" \
    "$(marca_json m-002 b-2 'Bases de la convocatoria' cambio 'quita este parrafo' estable)" \
    "$(marca_json m-003 b-3 'Plazos de entrega' cambio 'plazo de 20 dias' perdida)"

  run_edicion "$dir" "$err" -- aplicar --fichero redactar-20260923-184012.json --tarea t1 --marca m-003 >/dev/null ||
    fail "delivering only the held-back mark should succeed: $(cat "$err")"
  side=$(sidecar_of "$dir" redactar 20260923-184012)
  assert_equals "m-001 m-002" "$(jq -r '.pendientes | join(" ")' "$side")" \
    "applicable marks that were not named must stay pending"

  run_edicion "$dir" "$err" -- cerrar redactar-20260923-184012.json >/dev/null
  rc=$?
  expect_code 2 "$rc" "a delivery with unapplied applicable marks must not close"
  assert_contains "$(cat "$err")" "--marca m-001" \
    "the refusal should print the command for the unapplied applicable mark"
  pass "aplicar: naming one mark leaves every other mark owed"
}

test_cerrar_discards_held_back_marks() {
  local dir err out rc side ledger
  dir=$(make_world descartar)
  err="$dir/err"
  add_live_task "$dir" t1
  write_delivery "$dir" redactar 20260923-184012 \
    "$(marca_json m-003 b-3 'Plazos de entrega' cambio 'plazo de 20 dias' perdida)" \
    "$(marca_json m-004 b-4 'Datos de contacto' cambio 'quita el telefono' perdida)" \
    "$(marca_json m-005 b-5 'Sede de la empresa' cambio 'cambia la sede' perdida)"

  run_edicion "$dir" "$err" -- aplicar --fichero redactar-20260923-184012.json --tarea t1 --marca m-003 >/dev/null
  rc=$?
  expect_code 3 "$rc" "the other held-back marks should stay an open question"
  side=$(sidecar_of "$dir" redactar 20260923-184012)
  assert_equals "m-004 m-005" "$(jq -r '.pendientes | join(" ")' "$side")" \
    "the marks that were not delivered should stay pending"

  run_edicion "$dir" "$err" -- cerrar redactar-20260923-184012.json --descartar m-999 >/dev/null
  rc=$?
  expect_code 2 "$rc" "discarding a mark that is not pending should be refused"
  assert_contains "$(cat "$err")" "no esta pendiente" \
    "the refusal should say the mark is not pending"

  run_edicion "$dir" "$err" -- cerrar redactar-20260923-184012.json --descartar m-004 >/dev/null
  rc=$?
  expect_code 2 "$rc" "a delivery with another mark still pending must not close"
  assert_equals "m-004" "$(jq -r '.descartadas | join(" ")' "$side")" \
    "the discard should be recorded even when the close is refused"
  assert_equals "m-005" "$(jq -r '.pendientes | join(" ")' "$side")" \
    "only the discarded mark should leave the pending list"

  run_edicion "$dir" "$err" -- aplicar --fichero redactar-20260923-184012.json --tarea t1 --marca m-005 >/dev/null ||
    fail "delivering the last held-back mark should succeed: $(cat "$err")"
  assert_equals "m-004" "$(jq -r '.descartadas | join(" ")' "$side")" \
    "a later delivery pass must preserve the discarded mark"

  out=$(run_edicion "$dir" "$err" -- cerrar redactar-20260923-184012.json)
  rc=$?
  expect_code 0 "$rc" "the delivery should close once every mark is delivered or discarded: $(cat "$err")"
  assert_contains "$out" "descartadas: m-004" "cerrar should print the discarded mark"
  assert_contains "$out" "resultado: tarea t1" "the close should name the live task"
  side="$dir/home/data/edicion/aplicadas/redactar-20260923-184012.aplicado.json"
  assert_equals "m-004" "$(jq -r '.descartadas | join(" ")' "$side")" \
    "the closed sidecar should keep the discarded mark"
  ledger="$dir/home/data/edicion/aplicadas/registro.md"
  assert_contains "$(cat "$ledger")" "m-004" "the ledger should name the discarded mark"
  pass "cerrar: a held-back mark can be delivered or discarded, and the close records both"
}

test_aplicar_all_held_back_offers_taskless_resolution() {
  local dir err out rc
  dir=$(make_world solo-revisar)
  err="$dir/err"
  write_delivery "$dir" redactar 20260923-194000 \
    "$(marca_json m-003 b-9c0d 'Plazos de entrega' cambio 'ahora el plazo es de 20 dias' perdida)"

  out=$(run_edicion "$dir" "$err" -- aplicar)
  rc=$?
  expect_code 3 "$rc" "a delivery with only held-back marks should report the open question"
  assert_contains "$out" "nada que crear todavia" \
    "the all-held-back delivery should say no task was created"
  assert_contains "$out" "aplicar --fichero <entrega> --marca m-003" \
    "the open question should print the task-less resolution form"
  assert_contains "$out" "crea la tarea" \
    "the task-less form should say it creates the task"
  assert_equals "" "$(cat "$dir/tasks.log")" \
    "the all-held-back delivery must not create a task yet"

  run_edicion "$dir" "$err" -- aplicar --fichero redactar-20260923-194000.json --marca m-003 >/dev/null ||
    fail "the printed task-less resolution should work: $(cat "$err")"
  assert_equals "1" "$(grep -c '^ARGS add' "$dir/tasks.log" || true)" \
    "the task-less resolution should create the task"
  assert_equals "" "$(jq -r '.pendientes | join(" ")' "$(sidecar_of "$dir" redactar 20260923-194000)")" \
    "the resolution should clear the held-back mark"
  pass "aplicar: an all-held-back delivery offers a resolution that creates its task"
}

test_aplicar_all_held_back_honors_tarea_flag() {
  local dir err out rc side
  dir=$(make_world solo-revisar-tarea)
  err="$dir/err"
  add_live_task "$dir" t1
  write_delivery "$dir" redactar 20260923-195000 \
    "$(marca_json m-003 b-9c0d 'Plazos de entrega' cambio 'ahora el plazo es de 20 dias' perdida)"

  out=$(run_edicion "$dir" "$err" -- aplicar --fichero redactar-20260923-195000.json --tarea t1)
  rc=$?
  expect_code 3 "$rc" "the all-held-back delivery should report the open question"
  assert_contains "$out" "--tarea t1 --marca m-003" \
    "the open question must honor the live task the caller named"
  assert_contains "$out" "a la tarea t1" "the open question should name the live task"
  assert_equals "" "$(cat "$dir/tasks.log")" \
    "the all-held-back delivery must not create a task yet"

  run_edicion "$dir" "$err" -- aplicar --fichero redactar-20260923-195000.json --tarea t1 --marca m-003 >/dev/null ||
    fail "the printed resolution should steer the named live task: $(cat "$err")"
  side=$(sidecar_of "$dir" redactar 20260923-195000)
  assert_equals "t1" "$(jq -r '.tarea' "$side")" \
    "the resolution should bind the delivery to the named task"
  assert_present "$dir/home/state/t1.inbox/001.msg" \
    "the resolution should steer the live task"
  assert_equals "" "$(cat "$dir/tasks.log")" \
    "the resolution must not create a new task"
  pass "aplicar: an all-held-back delivery honors the named live task"
}

test_cerrar_recomputes_owed_marks_from_delivery() {
  local dir err out rc side
  dir=$(make_world crecida)
  err="$dir/err"
  add_live_task "$dir" t1
  write_delivery "$dir" redactar 20260923-196000 \
    "$(marca_json m-001 b-1 'Programa de los cursos de creacion' cambio 'cambia este titulo' estable)"

  run_edicion "$dir" "$err" -- aplicar --fichero redactar-20260923-196000.json >/dev/null ||
    fail "the first mark should apply: $(cat "$err")"
  side=$(sidecar_of "$dir" redactar 20260923-196000)
  assert_equals "m-001" "$(jq -r '.entregadas | join(" ")' "$side")" \
    "the first mark should be delivered"

  jq '.marcas += [{"id":"m-002","bloque":"b-2","ruta":"html > body","texto_bloque":"Bases de la convocatoria","tipo":"cambio","texto":"quita este parrafo","creado_en":"2026-09-23T18:41:03Z","ancla":"estable"}]' \
    "$dir/home/data/edicion/redactar-20260923-196000.json" >"$dir/crecida.json"
  mv "$dir/crecida.json" "$dir/home/data/edicion/redactar-20260923-196000.json"

  out=$(run_edicion "$dir" "$err" -- marcas)
  assert_contains "$out" "1 marcas pendientes, sin cerrar" \
    "marcas should report the appended mark as still owed"

  run_edicion "$dir" "$err" -- cerrar redactar-20260923-196000.json >/dev/null
  rc=$?
  expect_code 2 "$rc" "cerrar should refuse while an appended mark is owed"
  assert_contains "$(cat "$err")" "--marca m-002" \
    "the refusal should print the command for the appended mark"

  run_edicion "$dir" "$err" -- aplicar --fichero redactar-20260923-196000.json --tarea t1 --marca m-002 >/dev/null ||
    fail "delivering the appended mark should succeed: $(cat "$err")"
  assert_equals "m-001 m-002" "$(jq -r '.entregadas | join(" ")' "$side")" \
    "the sidecar should record both delivered marks"

  out=$(run_edicion "$dir" "$err" -- cerrar redactar-20260923-196000.json)
  rc=$?
  expect_code 0 "$rc" "the delivery should close once the appended mark is delivered: $(cat "$err")"
  assert_contains "$(cat "$dir/home/data/edicion/aplicadas/registro.md")" "2 marcas" \
    "the ledger should record both marks"
  pass "cerrar: an appended mark cannot close silently and is delivered before the close"
}

test_edicion_flags_require_values() {
  local dir err rc
  dir=$(make_world banderas)
  err="$dir/err"

  run_edicion "$dir" "$err" -- abrir redactar --proyecto >/dev/null
  rc=$?
  expect_code 2 "$rc" "abrir --proyecto without a value should be refused"
  assert_contains "$(cat "$err")" "--proyecto necesita" \
    "the refusal should name the flag missing its value"

  run_edicion "$dir" "$err" -- aplicar --fichero >/dev/null
  rc=$?
  expect_code 2 "$rc" "aplicar --fichero without a value should be refused"
  assert_contains "$(cat "$err")" "--fichero necesita" \
    "the refusal should name the flag missing its value"

  run_edicion "$dir" "$err" -- aplicar --tarea >/dev/null
  rc=$?
  expect_code 2 "$rc" "aplicar --tarea without a value should be refused"
  assert_contains "$(cat "$err")" "--tarea necesita" \
    "the refusal should name the flag missing its value"

  run_edicion "$dir" "$err" -- cerrar redactar-20260923-184012.json --descartar >/dev/null
  rc=$?
  expect_code 2 "$rc" "cerrar --descartar without a value should be refused"
  assert_contains "$(cat "$err")" "--descartar necesita" \
    "the refusal should name the flag missing its value"
  pass "flags: a missing option value refuses loudly instead of dying under set -e"
}

# --- run --------------------------------------------------------------------

test_abrir_starts_and_reuses_surface
test_abrir_refuses_without_surface_or_screen
test_marcas_lists_without_applying
test_marcas_refuses_malformed_delivery
test_marcas_and_aplicar_refuse_non_scalar_fields
test_aplicar_creates_task_and_quotes_blocks
test_aplicar_groups_deliveries_into_one_task
test_aplicar_refuses_malformed_and_reapplied
test_aplicar_steers_live_task_and_checks_input
test_cerrar_holds_until_lost_mark_is_delivered
test_marcas_and_aplicar_accept_hyphenated_screen
test_aplicar_refuses_delivery_outside_marks_dir
test_aplicar_keeps_unnamed_applicable_marks_owed
test_cerrar_discards_held_back_marks
test_aplicar_all_held_back_offers_taskless_resolution
test_aplicar_all_held_back_honors_tarea_flag
test_cerrar_recomputes_owed_marks_from_delivery
test_edicion_flags_require_values
