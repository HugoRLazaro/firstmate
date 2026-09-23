#!/usr/bin/env bash
# fm-edicion.sh - the firstmate half of the /edicion marking route.
#
# The other half is the platform's marking surface (tools/edicion/serve.mjs in
# the project clone): it serves a replica of a real screen and lets the captain
# click a block, write what is wanted, and accumulate marks. This command opens
# that surface, reads the deliveries it leaves in this home's data/edicion/, and
# turns them into real work through the guarded lifecycle paths.
#
# Usage:
#   fm-edicion.sh abrir <pantalla|url> [--proyecto <nombre|ruta>]
#   fm-edicion.sh marcas [--ultimas]
#   fm-edicion.sh aplicar [--fichero <json>]... [--tarea <id>] [--marca <id>]...
#                         [--proyecto <nombre|ruta>]
#                         [--modo <no-mistakes|direct-PR|local-only>]
#   fm-edicion.sh cerrar <fichero> [--descartar <id>]...
#
# Delivery contract (frozen, version 1, shared with the surface):
#   data/edicion/<pantalla>-<AAAAMMDD-HHMMSS>.json plus its readable .md:
#   {version, pantalla, url, capturado_en, huella,
#    marcas: [{id, bloque, ruta, texto_bloque, tipo, texto, creado_en, ancla}]}
#   ancla=estable means the marked block is still where the mark left it.
#   Any other value, "perdida" included, is never applied blindly: the mark is
#   presented with its original context and left pending a decision. A mark
#   without a citable texto_bloque is held back the same way. A pending mark is
#   resolved by delivering it explicitly or by discarding it with
#   `cerrar --descartar <id>`, and the delivery never closes until then.
#
# Surface contract consumed here: the project clone provides
# tools/edicion/serve.mjs, launched from the clone root with FM_EDICION_SALIDA
# pointing at this home's marks directory, and it prints its own
# http://127.0.0.1:<port> address. The screen registry lives in the clone as
# tools/edicion/pantallas.json: a map or array of
# screens, each entry a ruta (or url), so a screen name resolves to its replica.
#
# The route never writes under projects/. `aplicar` writes only data/edicion/
# and the task's own data/<id>/ records, and reaches the fleet only through
# bin/fm-tasks-axi.sh, bin/fm-brief.sh, and bin/fm-send.sh. The notice that a
# delivery arrived rides bin/fm-inbox.sh, which the surface already uses.
#
# Environment:
#   FM_HOME / FM_DATA_OVERRIDE / FM_STATE_OVERRIDE  standard home resolution
#   FM_EDICION_SALIDA            marks directory (default $DATA/edicion)
#   FM_EDICION_PROYECTO          project clone holding the surface
#   FM_EDICION_MODO              delivery mode for a created task
#   FM_EDICION_NO_ABRIR=1        do not open the browser
#   FM_EDICION_ARRANQUE_SEGUNDOS surface startup budget (default 20)
#
# Exit codes: 0 done; 1 runtime failure; 2 refused (usage, malformed or already
# applied delivery); 3 applied with an open question (marks held back).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
SALIDA="${FM_EDICION_SALIDA:-$DATA/edicion}"
PROYECTOS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
SUPERFICIE_REL="tools/edicion/serve.mjs"
REGISTRO_REL="tools/edicion/pantallas.json"
ARRANQUE_SEGUNDOS="${FM_EDICION_ARRANQUE_SEGUNDOS:-20}"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/fm-edicion.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT INT TERM HUP

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {  # <message...>: refused input, nothing mutated
  printf 'fm-edicion: %s\n' "$*" >&2
  exit 2
}

die() {  # <message...>: runtime failure
  printf 'fm-edicion: %s\n' "$*" >&2
  exit 1
}

require_jq() {
  command -v jq >/dev/null 2>&1 ||
    die "jq es necesario para leer las entregas de marcas (instalalo y repite)"
}

fm_edicion_ahora() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# --- delivery naming and lookup --------------------------------------------

# A delivery is exactly <pantalla>-<AAAAMMDD-HHMMSS>.json; the stamp in the
# name is the ordering key, and the strict shape is what keeps sidecars and
# unrelated files out of the listing.
fm_edicion_es_entrega() {  # <basename>
  local base=${1%.json}
  [ "$base" != "$1" ] || return 1
  case "$base" in
    *-????????-??????) : ;;
    *) return 1 ;;
  esac
  local stamp=${base: -15}
  local dia=${stamp%%-*}
  local hora=${stamp#*-}
  case "$dia$hora" in
    *[!0-9]*) return 1 ;;
  esac
  [ "${#dia}" -eq 8 ] && [ "${#hora}" -eq 6 ] || return 1
  local pantalla=${base%-"$stamp"}
  pantalla=${pantalla%-}
  [ -n "$pantalla" ] || return 1
  return 0
}

fm_edicion_estampa() {  # <basename> -> AAAAMMDD-HHMMSS
  local base=${1%.json}
  printf '%s' "${base: -15}"
}

# Deliveries in this home, oldest first. A delivery already applied but not yet
# closed is still listed: its sidecar is what marks it applied.
fm_edicion_entregas() {
  [ -d "$SALIDA" ] || return 0
  local f base stamp
  for f in "$SALIDA"/*.json; do
    [ -f "$f" ] || continue
    base=$(basename "$f")
    fm_edicion_es_entrega "$base" || continue
    stamp=$(fm_edicion_estampa "$base")
    printf '%s\t%s\n' "$stamp" "$f"
  done | LC_ALL=C sort -k1,1 | cut -f2
}

fm_edicion_entrega_path() {  # <name-or-path> -> absolute delivery path; 1 absent, 2 outside the marks directory
  local arg=$1 cand dir salida
  case "$arg" in
    */*)
      fm_edicion_es_entrega "$(basename "$arg")" || return 1
      [ -f "$arg" ] || return 1
      dir=$(cd "$(dirname "$arg")" 2>/dev/null && pwd -P) || return 1
      salida=$(cd "$SALIDA" 2>/dev/null && pwd -P) || return 1
      [ "$dir" = "$salida" ] || return 2
      printf '%s/%s\n' "$dir" "$(basename "$arg")"
      ;;
    *)
      fm_edicion_es_entrega "$arg" || return 1
      cand="$SALIDA/$arg"
      [ -f "$cand" ] || return 1
      printf '%s\n' "$cand"
      ;;
  esac
}

fm_edicion_sidecar() {  # <delivery-path> -> sidecar path
  printf '%s.aplicado.json\n' "${1%.json}"
}

fm_edicion_leer_sidecar() {  # <delivery-path>: sets SIDECAR_TAREA, SIDECAR_ENTREGADAS, SIDECAR_DESCARTADAS
  local side
  side=$(fm_edicion_sidecar "$1")
  SIDECAR_TAREA=
  SIDECAR_ENTREGADAS=
  SIDECAR_DESCARTADAS=
  [ -f "$side" ] || return 1
  SIDECAR_TAREA=$(jq -r '.tarea // ""' "$side" 2>/dev/null || printf '')
  SIDECAR_ENTREGADAS=$(jq -r '(.entregadas // [])[]' "$side" 2>/dev/null || printf '')
  SIDECAR_DESCARTADAS=$(jq -r '(.descartadas // [])[]' "$side" 2>/dev/null || printf '')
  return 0
}

fm_edicion_escribir_sidecar() {  # <delivery> <tarea> <modo> <entregadas-file> <pendientes-file> <descartadas-file>
  local entrega=$1 tarea=$2 modo=$3 entregadas=$4 pendientes=$5 descartadas=$6 side
  side=$(fm_edicion_sidecar "$entrega")
  if [ -f "$side" ]; then
    # A later mark-resolution pass updates only the mark lists: the delivery
    # stays bound to the task it first became.
    jq --arg ahora "$(fm_edicion_ahora)" \
      --rawfile entregadas "$entregadas" \
      --rawfile pendientes "$pendientes" \
      --rawfile descartadas "$descartadas" \
      '.entregadas = ($entregadas | split("\n") | map(select(length > 0)))
       | .pendientes = ($pendientes | split("\n") | map(select(length > 0)))
       | .descartadas = ($descartadas | split("\n") | map(select(length > 0)))
       | .actualizado_en = $ahora' \
      "$side" >"$TMP/sidecar.json" || return 1
  else
    jq -n \
      --arg entrega "$(basename "$entrega")" \
      --arg pantalla "$(jq -r '.pantalla // ""' "$entrega")" \
      --arg tarea "$tarea" \
      --arg modo "$modo" \
      --arg ahora "$(fm_edicion_ahora)" \
      --rawfile entregadas "$entregadas" \
      --rawfile pendientes "$pendientes" \
      --rawfile descartadas "$descartadas" \
      '{
         version: 1,
         entrega: $entrega,
         pantalla: $pantalla,
         tarea: $tarea,
         modo: $modo,
         aplicado_en: $ahora,
         entregadas: ($entregadas | split("\n") | map(select(length > 0))),
         pendientes: ($pendientes | split("\n") | map(select(length > 0))),
         descartadas: ($descartadas | split("\n") | map(select(length > 0)))
       }' >"$TMP/sidecar.json" || return 1
  fi
  mv "$TMP/sidecar.json" "$side"
}

# --- delivery validation and mark records -----------------------------------

fm_edicion_validar() {  # <delivery>: refuses a malformed delivery
  local f=$1
  jq -e '
    (.version == 1)
    and ((.pantalla // "") | (type == "string" and length > 0))
    and ((.marcas // null) | (type == "array" and length > 0))
    and ([.marcas[] | ((.id // "") | (type == "string" and length > 0))
                   and ((.texto // "") | (type == "string" and length > 0))
                   and ([.tipo, .texto_bloque, .ruta, .ancla]
                        | all(. == null or type == "string"))] | all)
  ' "$f" >/dev/null 2>&1 ||
    fail "entrega mal formada: $f (hacen falta version 1, pantalla, y cada marca con id y texto, y los demas campos de texto)"
}

# NUL-separated records, fields joined by 0x1f: id, tipo, bloque, ruta, texto,
# ancla. Text may span lines, so neither newline nor tab can be a separator.
fm_edicion_records() {  # <delivery> [aplicable|revisar|todas]
  local f=$1 clase=${2:-todas}
  case "$clase" in
    aplicable | revisar | todas) : ;;
    *) fail "clase de marca desconocida: $clase" ;;
  esac
  jq -j --arg clase "$clase" '
    .marcas[]?
    | . as $m
    | (($m.ancla // "") == "estable" and ((($m.texto_bloque) // "") | length) > 0) as $aplicable
    | select(
        ($clase == "todas")
        or ($clase == "aplicable" and $aplicable)
        or ($clase == "revisar" and ($aplicable | not))
      )
    | [($m.id // ""), ($m.tipo // ""), ($m.texto_bloque // ""), ($m.ruta // ""), ($m.texto // ""), ($m.ancla // "")]
    | join("\u001f"), "\u0000"
  ' "$f"
}

fm_edicion_campo() {  # <record> <1-based field>
  local rec=$1 n=$2 i
  for ((i = 1; i < n; i++)); do
    rec=${rec#*$'\x1f'}
  done
  printf '%s' "${rec%%$'\x1f'*}"
}

fm_edicion_marca_ids() {  # <delivery> [aplicable|revisar|todas] -> one id per line
  local rec
  while IFS= read -r -d '' rec; do
    fm_edicion_campo "$rec" 1
    printf '\n'
  done < <(fm_edicion_records "$1" "${2:-todas}")
}

fm_edicion_adeudadas() {  # <delivery> -> mark ids neither delivered nor discarded, one per line
  local p=$1
  local ids_file="$TMP/adeudadas-ids.txt" hechas_file="$TMP/adeudadas-hechas.txt"
  fm_edicion_marca_ids "$p" todas | LC_ALL=C sort -u >"$ids_file"
  : >"$hechas_file"
  if fm_edicion_leer_sidecar "$p"; then
    printf '%s\n' "$SIDECAR_ENTREGADAS" | grep . >>"$hechas_file" || true
    printf '%s\n' "$SIDECAR_DESCARTADAS" | grep . >>"$hechas_file" || true
  fi
  LC_ALL=C sort -u "$hechas_file" -o "$hechas_file"
  comm -23 "$ids_file" "$hechas_file"
}

fm_edicion_es_aplicable() {  # <record>
  [ "$(fm_edicion_campo "$1" 6)" = "estable" ] && [ -n "$(fm_edicion_campo "$1" 3)" ]
}

fm_edicion_cuenta() {  # <newline-list>
  printf '%s' "$1" | grep -c . || true
}

# Join a newline list into "a, b, c", dropping duplicates and empty lines.
fm_edicion_unir() {
  awk 'BEGIN { first = 1 } {
    if ($0 == "" || seen[$0]++) next
    if (!first) printf ", "
    printf "%s", $0
    first = 0
  }'
}

# --- readable rendering -----------------------------------------------------

fm_edicion_indentar() {  # <text> <prefix>
  local texto=$1 prefijo=$2
  if [ -n "$texto" ]; then
    printf '%s\n' "$texto" | sed "s/^/$prefijo/"
  fi
}

fm_edicion_listar_marca() {  # <record> <number> <prefix>
  local rec=$1 num=$2 pref=$3
  local id tipo bloque ruta texto
  id=$(fm_edicion_campo "$rec" 1)
  tipo=$(fm_edicion_campo "$rec" 2)
  bloque=$(fm_edicion_campo "$rec" 3)
  ruta=$(fm_edicion_campo "$rec" 4)
  texto=$(fm_edicion_campo "$rec" 5)
  printf '%s%s) marca %s' "$pref" "$num" "$id"
  [ -n "$tipo" ] && printf ' [%s]' "$tipo"
  if [ -n "$bloque" ]; then
    printf ' bloque "%s"' "$bloque"
  else
    printf ' bloque sin texto citado'
  fi
  printf '\n'
  [ -n "$ruta" ] && printf '%s   ruta: %s\n' "$pref" "$ruta"
  printf '%s   pide:\n' "$pref"
  fm_edicion_indentar "$texto" "$pref      "
}

# --- project and surface resolution ----------------------------------------

fm_edicion_proyecto() {  # [<nombre|ruta>] -> clone path; 0 ok, 1 none, 2 ambiguous
  local arg=${1:-} d
  if [ -n "$arg" ]; then
    if [ -d "$arg" ]; then
      (cd "$arg" && pwd -P)
      return 0
    fi
    if [ -d "$PROYECTOS/$arg" ]; then
      (cd "$PROYECTOS/$arg" && pwd -P)
      return 0
    fi
    return 1
  fi
  if [ -n "${FM_EDICION_PROYECTO:-}" ]; then
    [ -d "$FM_EDICION_PROYECTO" ] || return 1
    (cd "$FM_EDICION_PROYECTO" && pwd -P)
    return 0
  fi
  local encontrados=""
  for d in "$PROYECTOS"/*/; do
    [ -d "${d}tools/edicion" ] || continue
    encontrados="${encontrados}$(cd "$d" && pwd -P)"$'\n'
  done
  case "$(fm_edicion_cuenta "$encontrados")" in
    1) printf '%s' "$encontrados" | head -n1 ;;
    0) return 1 ;;
    *) return 2 ;;
  esac
}

fm_edicion_diagnostico_proyecto() {  # <status>
  if [ "${1:-1}" -eq 2 ]; then
    printf 'fm-edicion: hay varios clones con superficie de marcado en %s; pasa --proyecto <nombre|ruta>\n' "$PROYECTOS" >&2
  else
    printf 'fm-edicion: no encuentro un clon de proyecto con tools/edicion en %s; la mitad de plataforma de /edicion todavia no esta instalada, o pasa --proyecto <nombre|ruta> (o FM_EDICION_PROYECTO)\n' \
      "$PROYECTOS" >&2
  fi
  exit 1
}

fm_edicion_registro() {  # <proyecto> -> registry path; 1 when absent
  local proj=$1
  [ -f "$proj/$REGISTRO_REL" ] || return 1
  printf '%s\n' "$proj/$REGISTRO_REL"
}

fm_edicion_pantalla_ruta() {  # <proyecto> <pantalla> -> ruta|url; 1 no registry, 2 unknown
  local proj=$1 pantalla=$2 reg ruta
  reg=$(fm_edicion_registro "$proj") || return 1
  ruta=$(jq -r --arg n "$pantalla" '
    (.pantallas // .) as $p
    | ($p
       | if type == "array" then
           (map(select((.nombre? == $n) or (.pantalla? == $n))) | .[0]
            | if type == "object" then (.ruta // .url // empty) else empty end)
         elif type == "object" then
           (.[$n]
            | if type == "string" then .
              elif type == "object" then (.ruta // .url // empty)
              else empty end)
         else empty end)
    | select(type == "string" and length > 0)
  ' "$reg" 2>/dev/null || true)
  [ -n "$ruta" ] || return 2
  printf '%s\n' "$ruta"
}

# --- surface server ---------------------------------------------------------

fm_edicion_url_responde() {  # <url>
  local url=$1 host port code
  if command -v curl >/dev/null 2>&1; then
    code=$(curl -s -o /dev/null -m 2 -w '%{http_code}' "$url" 2>/dev/null || true)
    case "$code" in
      '' | 000) return 1 ;;
      *) return 0 ;;
    esac
  fi
  host=${url#*://}
  host=${host%%/*}
  port=${host##*:}
  [ "$port" = "$host" ] && port=80
  host=${host%%:*}
  [ -n "$host" ] || return 1
  (exec 3<>"/dev/tcp/$host/$port") 2>/dev/null
}

fm_edicion_servidor_leer() {  # sets SERVIDOR_PID SERVIDOR_URL SERVIDOR_PROYECTO
  local rec="$SALIDA/.servidor"
  SERVIDOR_PID=
  SERVIDOR_URL=
  SERVIDOR_PROYECTO=
  [ -f "$rec" ] || return 1
  SERVIDOR_PID=$(cut -f1 "$rec" 2>/dev/null || printf '')
  SERVIDOR_URL=$(cut -f2 "$rec" 2>/dev/null || printf '')
  SERVIDOR_PROYECTO=$(cut -f3 "$rec" 2>/dev/null || printf '')
  case "$SERVIDOR_PID" in
    '' | *[!0-9]*) return 1 ;;
  esac
  [ -n "$SERVIDOR_URL" ] || return 1
  return 0
}

fm_edicion_servidor_vivo() {  # [<proyecto-esperado>]: 0 when the recorded surface is still serving it
  fm_edicion_servidor_leer || return 1
  kill -0 "$SERVIDOR_PID" 2>/dev/null || return 1
  if [ -n "${1:-}" ] && [ -n "$SERVIDOR_PROYECTO" ] && [ "$SERVIDOR_PROYECTO" != "$1" ]; then
    return 1
  fi
  fm_edicion_url_responde "$SERVIDOR_URL" || return 1
  return 0
}

# Stop a recorded surface that no longer matches the requested project. Only a
# recorded pid that is alive AND still answering on its own recorded URL is
# stopped, so a recycled pid can never be mistaken for the surface.
fm_edicion_servidor_retirar() {
  fm_edicion_servidor_leer || return 0
  kill -0 "$SERVIDOR_PID" 2>/dev/null || return 0
  fm_edicion_url_responde "$SERVIDOR_URL" || return 0
  kill "$SERVIDOR_PID" 2>/dev/null || true
  local waited=0
  while [ "$waited" -lt 5 ] && kill -0 "$SERVIDOR_PID" 2>/dev/null; do
    sleep 1
    waited=$((waited + 1))
  done
  rm -f "$SALIDA/.servidor"
  return 0
}

fm_edicion_servidor_anotar() {  # <pid> <url> <proyecto>
  mkdir -p "$SALIDA"
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$(date +%s)" >"$TMP/.servidor"
  mv "$TMP/.servidor" "$SALIDA/.servidor"
}

fm_edicion_servidor_arrancar() {  # <proyecto>: sets SERVIDOR_PID SERVIDOR_URL
  local proj=$1 serve log pid url waited
  serve="$proj/$SUPERFICIE_REL"
  [ -f "$serve" ] || return 1
  command -v node >/dev/null 2>&1 || die "node es necesario para arrancar la superficie de marcado"
  mkdir -p "$SALIDA"
  log="$SALIDA/.servidor.log"
  : >"$log"
  (
    cd "$proj"
    FM_EDICION_SALIDA="$SALIDA" exec node "$serve"
  ) >>"$log" 2>&1 &
  pid=$!
  url=
  waited=0
  while [ "$waited" -lt "$ARRANQUE_SEGUNDOS" ]; do
    url=$(grep -oE 'https?://[^[:space:]]+' "$log" 2>/dev/null | head -n1 || true)
    [ -n "$url" ] && break
    if ! kill -0 "$pid" 2>/dev/null; then
      printf 'fm-edicion: la superficie de marcado termino al arrancar; salida en %s:\n' "$log" >&2
      tail -n 20 "$log" >&2 || true
      return 1
    fi
    sleep 1
    waited=$((waited + 1))
  done
  if [ -z "$url" ]; then
    kill "$pid" 2>/dev/null || true
    printf 'fm-edicion: la superficie de marcado no dijo su direccion en %s segundos; salida en %s:\n' \
      "$ARRANQUE_SEGUNDOS" "$log" >&2
    tail -n 20 "$log" >&2 || true
    return 1
  fi
  url=$(printf '%s' "$url" | sed 's/[,.;:)]*$//')
  SERVIDOR_PID=$pid
  SERVIDOR_URL=$url
  fm_edicion_servidor_anotar "$pid" "$url" "$proj"
  return 0
}

fm_edicion_abrir_navegador() {  # <url>
  [ "${FM_EDICION_NO_ABRIR:-}" = 1 ] && return 0
  if command -v open >/dev/null 2>&1; then
    open "$url" >/dev/null 2>&1 &
    return 0
  fi
  if command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$url" >/dev/null 2>&1 &
    return 0
  fi
  return 1
}

# --- abrir ------------------------------------------------------------------

cmd_abrir() {
  local arg='' proyecto_arg='' proj='' pantalla='' url='' ruta='' ruta_estado=0 servidor_estado='' proj_estado=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --proyecto)
        [ -n "${2:-}" ] || fail "--proyecto necesita <nombre|ruta>"
        proyecto_arg=$2
        shift 2
        ;;
      --proyecto=*)
        [ -n "${1#--proyecto=}" ] || fail "--proyecto necesita <nombre|ruta>"
        proyecto_arg=${1#--proyecto=}
        shift
        ;;
      -*) fail "opcion desconocida: $1" ;;
      *) arg=$1; shift ;;
    esac
  done
  [ -n "$arg" ] || fail "uso: fm-edicion.sh abrir <pantalla|url> [--proyecto <nombre|ruta>]"
  require_jq

  case "$arg" in
    http://* | https://*)
      url=$arg
      pantalla=$(printf '%s' "${url%%\?*}" | sed 's#/*$##' | sed 's#.*/##')
      ;;
    *)
      pantalla=$arg
      ;;
  esac

  if proj=$(fm_edicion_proyecto "$proyecto_arg"); then
    :
  else
    proj_estado=$?
    [ -n "$url" ] || fm_edicion_diagnostico_proyecto "$proj_estado"
    proj=
  fi

  if [ -z "$url" ]; then
    fm_edicion_registro "$proj" >/dev/null ||
      die "el clon $proj no trae registro de pantallas ($REGISTRO_REL); usa 'abrir <url>' con la direccion de la replica"
    ruta_estado=0
    ruta=$(fm_edicion_pantalla_ruta "$proj" "$pantalla") || ruta_estado=$?
    if [ "$ruta_estado" -ne 0 ]; then
      if [ "$ruta_estado" -eq 1 ]; then
        die "no pude leer el registro de pantallas de $proj"
      fi
      die "la pantalla '$pantalla' no esta en el registro de $proj; abre una URL o anade la pantalla al registro del proyecto"
    fi
    case "$ruta" in
      http://* | https://*) url=$ruta ;;
      *)
        [ -f "$proj/$SUPERFICIE_REL" ] ||
          die "el clon $proj no trae la superficie de marcado ($SUPERFICIE_REL); la mitad de plataforma de /edicion todavia no esta instalada"
        if fm_edicion_servidor_vivo "$proj"; then
          servidor_estado=3
        else
          fm_edicion_servidor_retirar
          fm_edicion_servidor_arrancar "$proj" ||
            die "no pude arrancar la superficie de marcado de $proj"
          servidor_estado=0
        fi
        url="${SERVIDOR_URL%/}/${ruta#/}"
        ;;
    esac
  fi

  if [ -z "$proj" ]; then
    proj=$(fm_edicion_proyecto "" 2>/dev/null || printf '')
  fi
  mkdir -p "$SALIDA"

  printf 'pantalla: %s\n' "$pantalla"
  [ -n "$proj" ] && printf 'proyecto: %s\n' "$proj"
  [ -n "$proj" ] && printf 'superficie: %s\n' "$proj/$SUPERFICIE_REL"
  case "$servidor_estado" in
    0) printf 'servidor: arrancado ahora (pid %s)\n' "${SERVIDOR_PID:-}" ;;
    3) printf 'servidor: ya estaba arrancado (pid %s)\n' "${SERVIDOR_PID:-}" ;;
    *) printf 'servidor: no hace falta arrancarlo para esta direccion\n' ;;
  esac
  printf 'direccion local: %s\n' "$url"
  printf 'las marcas quedaran en: %s\n' "$SALIDA"
  if [ -n "$proj" ] && fm_edicion_registro "$proj" >/dev/null; then
    printf 'registro de pantallas: %s\n' "$(fm_edicion_registro "$proj")"
  fi

  if fm_edicion_url_responde "$url"; then
    :
  else
    printf 'aviso: %s todavia no responde; si el servidor acaba de arrancar, espera unos segundos y recarga\n' "$url"
  fi

  fm_edicion_abrir_navegador "$url" ||
    printf 'aviso: no encontre con que abrir el navegador; abre la direccion a mano\n'
  return 0
}

# --- marcas -----------------------------------------------------------------

cmd_marcas() {
  local ultimas=0 lista='' f='' base='' pantalla='' n_apl='' n_rev='' rec='' num='' num_marks='' tarea='' pendientes=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --ultimas) ultimas=1; shift ;;
      -*) fail "opcion desconocida: $1" ;;
      *) fail "marcas no toma argumentos posicionales: $1" ;;
    esac
  done
  require_jq
  mkdir -p "$SALIDA"

  lista=$(fm_edicion_entregas)
  if [ "$ultimas" = 1 ] && [ -n "$lista" ]; then
    lista=$(printf '%s\n' "$lista" | tail -n1)
  fi
  if [ -z "$lista" ]; then
    printf 'no hay entregas de marcas pendientes en %s\n' "$SALIDA"
    return 0
  fi

  printf 'entregas de marcas en %s:\n\n' "$SALIDA"
  num=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    num=$((num + 1))
    base=$(basename "$f")
    fm_edicion_validar "$f"
    pantalla=$(jq -r '.pantalla // ""' "$f")
    printf '%s) %s\n' "$num" "$base"
    printf '   pantalla: %s\n' "$pantalla"
    printf '   url: %s\n' "$(jq -r '.url // ""' "$f")"
    printf '   capturada: %s\n' "$(jq -r '.capturado_en // ""' "$f")"
    n_apl=$(fm_edicion_marca_ids "$f" aplicable | grep -c . || true)
    n_rev=$(fm_edicion_marca_ids "$f" revisar | grep -c . || true)
    printf '   marcas: %s (%s aplicables, %s en revision)\n' "$((n_apl + n_rev))" "$n_apl" "$n_rev"
    if fm_edicion_leer_sidecar "$f"; then
      tarea=$SIDECAR_TAREA
      pendientes=$(fm_edicion_cuenta "$(fm_edicion_adeudadas "$f")")
      printf '   estado: aplicada a la tarea %s' "$tarea"
      if [ "$pendientes" -gt 0 ]; then
        printf ' (%s marcas pendientes, sin cerrar)' "$pendientes"
      else
        printf ' (lista para cerrar)'
      fi
      printf '\n'
    else
      printf '   estado: pendiente de aplicar\n'
    fi
    num_marks=0
    while IFS= read -r -d '' rec; do
      num_marks=$((num_marks + 1))
      fm_edicion_listar_marca "$rec" "$num_marks" "   "
    done < <(fm_edicion_records "$f" aplicable)
    while IFS= read -r -d '' rec; do
      num_marks=$((num_marks + 1))
      fm_edicion_listar_marca "$rec" "$num_marks" "   "
      printf '   ancla: %s\n' "$(fm_edicion_campo "$rec" 6)"
    done < <(fm_edicion_records "$f" revisar)
    printf '\n'
  done <<EOF
$lista
EOF
  return 0
}

# --- aplicar ----------------------------------------------------------------

# The open question for every held-back mark, with its original context.
fm_edicion_presentar_revisar() {  # [<tarea>] <record>...: records already filtered to held-back marks
  local tarea=${1:-} rec num=0
  shift || true
  printf 'DECISION ABIERTA: %s marca(s) con el ancla perdida.\n' "$#"
  printf 'No se aplican a ciegas: el bloque ya no esta donde la marca lo dejo. Contexto original:\n\n'
  for rec in "$@"; do
    num=$((num + 1))
    printf '%s) marca %s' "$num" "$(fm_edicion_campo "$rec" 1)"
    printf ' [%s]' "$(fm_edicion_campo "$rec" 6)"
    printf '\n'
    printf '   bloque citado: "%s"\n' "$(fm_edicion_campo "$rec" 3)"
    printf '   ruta original: %s\n' "$(fm_edicion_campo "$rec" 4)"
    printf '   se pedia:\n'
    fm_edicion_indentar "$(fm_edicion_campo "$rec" 5)" "      "
    printf '\n'
  done
  printf 'Pregunta abierta: donde esta ahora ese bloque, o se descarta la marca?\n'
  if [ -n "$tarea" ]; then
    printf 'Con la respuesta, entrega la marca a la tarea %s con:\n' "$tarea"
    for rec in "$@"; do
      printf '  fm-edicion.sh aplicar --fichero <entrega> --tarea %s --marca %s\n' "$tarea" "$(fm_edicion_campo "$rec" 1)"
    done
  else
    printf 'Con la respuesta, entrega la marca con:\n'
    for rec in "$@"; do
      printf '  fm-edicion.sh aplicar --fichero <entrega> --marca %s\n' "$(fm_edicion_campo "$rec" 1)"
    done
    printf '  (crea la tarea; usa --tarea <tarea> solo para mandar la marca a una tarea que ya existe)\n'
  fi
  printf 'si la respuesta es descartarla, anotala con: fm-edicion.sh cerrar <entrega> --descartar <id>\n'
  printf 'y despues cierra la entrega con: fm-edicion.sh cerrar <entrega>\n'
}

cmd_aplicar() {
  local ficheros=() tarea='' marcas=() proyecto_arg='' modo_arg='' rc=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --fichero)
        [ -n "${2:-}" ] || fail "--fichero necesita <json>"
        ficheros+=("$2")
        shift 2
        ;;
      --fichero=*)
        [ -n "${1#--fichero=}" ] || fail "--fichero necesita <json>"
        ficheros+=("${1#--fichero=}")
        shift
        ;;
      --tarea)
        [ -n "${2:-}" ] || fail "--tarea necesita <id>"
        tarea=$2
        shift 2
        ;;
      --tarea=*)
        [ -n "${1#--tarea=}" ] || fail "--tarea necesita <id>"
        tarea=${1#--tarea=}
        shift
        ;;
      --marca)
        [ -n "${2:-}" ] || fail "--marca necesita <id>"
        marcas+=("$2")
        shift 2
        ;;
      --marca=*)
        [ -n "${1#--marca=}" ] || fail "--marca necesita <id>"
        marcas+=("${1#--marca=}")
        shift
        ;;
      --proyecto)
        [ -n "${2:-}" ] || fail "--proyecto necesita <nombre|ruta>"
        proyecto_arg=$2
        shift 2
        ;;
      --proyecto=*)
        [ -n "${1#--proyecto=}" ] || fail "--proyecto necesita <nombre|ruta>"
        proyecto_arg=${1#--proyecto=}
        shift
        ;;
      --modo)
        [ -n "${2:-}" ] || fail "--modo necesita <no-mistakes|direct-PR|local-only>"
        modo_arg=$2
        shift 2
        ;;
      --modo=*)
        [ -n "${1#--modo=}" ] || fail "--modo necesita <no-mistakes|direct-PR|local-only>"
        modo_arg=${1#--modo=}
        shift
        ;;
      -*) fail "opcion desconocida: $1" ;;
      *) fail "aplicar no toma argumentos posicionales: $1 (usa --fichero)" ;;
    esac
  done
  require_jq
  mkdir -p "$SALIDA"

  local entregas=() p='' f='' base='' marca='' ids=''
  if [ "${#ficheros[@]}" -gt 0 ]; then
    for f in "${ficheros[@]}"; do
      p=$(fm_edicion_entrega_path "$f") || {
        rc=$?
        if [ "$rc" -eq 2 ]; then
          fail "la entrega '$f' esta fuera de $SALIDA; la ruta nunca escribe fuera del directorio de marcas"
        fi
        fail "no encuentro la entrega '$f' en $SALIDA"
      }
      entregas+=("$p")
    done
  else
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      entregas+=("$p")
    done < <(fm_edicion_entregas)
    if [ "${#entregas[@]}" -eq 0 ]; then
      die "no hay entregas de marcas en $SALIDA; abre la superficie con 'abrir' y marca algo primero"
    fi
  fi

  # Validate every delivery and refuse an unknown mark id before anything is
  # created, so a typo can never silently drop a mark.
  local base='' ids=''
  for p in "${entregas[@]}"; do
    fm_edicion_validar "$p"
    [ "${#marcas[@]}" -gt 0 ] || continue
    ids=$(fm_edicion_marca_ids "$p" todas)
    for marca in "${marcas[@]}"; do
      printf '%s\n' "$ids" | grep -qxF -- "$marca" ||
        fail "la marca '$marca' no esta en $(basename "$p")"
    done
  done

  # An already-applied delivery only takes the explicit mark-resolution path:
  # named deliveries refuse without --marca, while the apply-everything sweep
  # simply leaves them to cerrar.
  local pendientes_aplicar=() explicito=0 adeudadas=''
  [ "${#ficheros[@]}" -gt 0 ] && explicito=1
  for p in "${entregas[@]}"; do
    base=$(basename "$p")
    if fm_edicion_leer_sidecar "$p"; then
      if [ "${#marcas[@]}" -eq 0 ]; then
        if [ "$explicito" = 1 ]; then
          fail "la entrega $base ya se aplico a la tarea $SIDECAR_TAREA; usa --marca <id> para entregar una marca pendiente, o cierra la entrega"
        fi
        continue
      fi
      if [ -z "$tarea" ]; then
        fail "la entrega $base ya tiene tarea ($SIDECAR_TAREA); --marca necesita --tarea <id> para entregar la marca a esa tarea viva"
      fi
      if [ "$tarea" != "$SIDECAR_TAREA" ]; then
        fail "la entrega $base esta ligada a la tarea $SIDECAR_TAREA; --tarea debe ser $SIDECAR_TAREA (recibido '$tarea')"
      fi
      adeudadas=$(fm_edicion_adeudadas "$p")
      for marca in "${marcas[@]}"; do
        printf '%s\n' "$adeudadas" | grep -qxF -- "$marca" ||
          fail "la marca '$marca' ya no esta pendiente en $base: ya se entrego o se descarto"
      done
    fi
    pendientes_aplicar+=("$p")
  done
  entregas=("${pendientes_aplicar[@]}")
  if [ "${#entregas[@]}" -eq 0 ]; then
    printf 'no hay entregas pendientes de aplicar en %s; las que hay ya tienen tarea y esperan cerrar\n' "$SALIDA"
    return 0
  fi

  # Select the marks this call carries. Without --marca that is every
  # applicable mark; with it, exactly the named marks, whatever their anchor,
  # because that is the path a held-back mark takes after a decision. Held-back
  # marks that are not carried are collected for the open question.
  local seleccion="$TMP/seleccion.txt"
  : >"$seleccion"
  local num=0 rec='' id='' seleccionada='' retenidas=() ya_resueltas=''
  for p in "${entregas[@]}"; do
    ya_resueltas=''
    if fm_edicion_leer_sidecar "$p"; then
      ya_resueltas=$(printf '%s\n%s\n' "$SIDECAR_ENTREGADAS" "$SIDECAR_DESCARTADAS")
    fi
    while IFS= read -r -d '' rec; do
      id=$(fm_edicion_campo "$rec" 1)
      seleccionada=0
      if [ "${#marcas[@]}" -gt 0 ]; then
        for marca in "${marcas[@]}"; do
          [ "$id" = "$marca" ] && seleccionada=1
        done
      elif fm_edicion_es_aplicable "$rec"; then
        seleccionada=1
      fi
      if [ "$seleccionada" = 1 ]; then
        num=$((num + 1))
        {
          fm_edicion_listar_marca "$rec" "$num" ""
          printf '\n'
        } >>"$seleccion"
      elif fm_edicion_es_aplicable "$rec"; then
        :
      elif printf '%s\n' "$ya_resueltas" | grep -qxF -- "$id"; then
        :
      else
        retenidas+=("$rec")
      fi
    done < <(fm_edicion_records "$p" todas)
  done

  if [ "$num" -eq 0 ]; then
    if [ "${#retenidas[@]}" -gt 0 ]; then
      fm_edicion_presentar_revisar "${tarea:-}" "${retenidas[@]}"
      printf '\nNo hay ninguna marca aplicable en esta entrega; nada que crear todavia.\n'
      return 3
    fi
    fail "no hay ninguna marca aplicable en las entregas indicadas"
  fi

  # Mode and project: an explicit flag wins, then the environment, then the
  # project's registered posture through the same mechanical consumer firstmate
  # uses at intake.
  local proj='' repo='' modo=''
  proj=$(fm_edicion_proyecto "$proyecto_arg") || fm_edicion_diagnostico_proyecto "$?"
  repo=$(basename "$proj")
  if [ -n "$modo_arg" ]; then
    modo=$modo_arg
  elif [ -n "${FM_EDICION_MODO:-}" ]; then
    modo=${FM_EDICION_MODO}
  else
    modo=$(FM_HOME="$FM_HOME" FM_DATA_OVERRIDE="$DATA" "$SCRIPT_DIR/fm-project-mode.sh" "$repo" 2>/dev/null | awk '{print $1}')
    [ -n "$modo" ] || modo=no-mistakes
  fi
  case "$modo" in
    no-mistakes | direct-PR | local-only) : ;;
    *) fail "--modo debe ser no-mistakes, direct-PR o local-only (recibido '$modo')" ;;
  esac

  local pantallas
  pantallas=$(
    for p in "${entregas[@]}"; do jq -r '.pantalla // ""' "$p"; done | fm_edicion_unir
  )
  local n_pantallas
  n_pantallas=$(printf '%s' "$pantallas" | awk -F', ' '{print NF}')

  local cuerpo="$TMP/cuerpo.txt"
  {
    printf 'Entregas de marcas de esta tarea:\n'
    for p in "${entregas[@]}"; do
      printf -- '- %s (pantalla %s)\n' "$(basename "$p")" "$(jq -r '.pantalla // ""' "$p")"
    done
  } >"$cuerpo"

  local id_final='' encargo=''
  if [ -n "$tarea" ]; then
    local steer="$TMP/steer.txt"
    {
      printf 'Encargo a partir de marcas de pantalla, que se suman al trabajo en curso:\n\n'
      cat "$seleccion"
      printf 'Cada punto es una instruccion vinculante sobre un bloque concreto de la pantalla; aplica literalmente lo pedido en cada uno y no toques nada fuera de los bloques marcados.\n'
      printf 'Si un bloque citado ya no existe tal cual, para y reporta ese punto en vez de adivinar.\n'
    } >"$steer"
    FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
      "$SCRIPT_DIR/fm-send.sh" "$tarea" "$(cat "$steer")" ||
      die "no pude entregar las instrucciones a la tarea $tarea"
    id_final=$tarea
    printf 'marcas entregadas a la tarea %s\n' "$id_final"
  else
    local titulo=''
    titulo=$(printf 'Marcas de pantalla: %s' "$pantallas")
    [ "${#entregas[@]}" -gt 1 ] && titulo="$titulo (${#entregas[@]} entregas)"

    local salida_add=''
    salida_add=$(FM_HOME="$FM_HOME" FM_DATA_OVERRIDE="$DATA" \
      "$SCRIPT_DIR/fm-tasks-axi.sh" add --mint --prefix edicion --kind ship \
      --repo "$repo" --body-file "$cuerpo" "$titulo" 2>&1) ||
      die "no pude crear el elemento de cola: $salida_add"
    id_final=$(printf '%s\n' "$salida_add" | awk '/^ok: added /{print $3; exit}')
    [ -n "$id_final" ] || die "no pude leer el identificador de la tarea creada: $salida_add"

    FM_HOME="$FM_HOME" FM_DATA_OVERRIDE="$DATA" FM_STATE_OVERRIDE="$STATE" \
      "$SCRIPT_DIR/fm-brief.sh" "$id_final" "$repo" --mode "$modo" >/dev/null ||
      die "no pude escribir el encargo de $id_final"

    encargo="$DATA/$id_final/brief.md"
    [ -f "$encargo" ] || die "el encargo de $id_final no se escribio en $encargo"

    local intent="$TMP/intent.txt" spec="$TMP/spec.txt"
    {
      if [ "$n_pantallas" -gt 1 ]; then
        printf 'Marcas hechas sobre las pantallas %s y pedidas, todas de golpe, para que se apliquen en esta tarea.\n' "$pantallas"
      else
        printf 'Marcas hechas sobre la pantalla %s y pedidas, todas de golpe, para que se apliquen en esta tarea.\n' "$pantallas"
      fi
      printf 'Cada punto cita el bloque marcado y lo que se le pide.\n\n'
      cat "$seleccion"
    } >"$intent"
    {
      printf 'Cada punto de arriba es una instruccion vinculante sobre un bloque concreto de la pantalla; aplica literalmente lo pedido en cada uno.\n'
      printf 'Localiza el bloque por el texto citado y, cuando la ruta ayude, por esa ruta; no cambies nada fuera de los bloques marcados.\n'
      printf 'Si un bloque citado ya no existe tal cual, para y reporta ese punto en vez de adivinar.\n'
      printf 'Manten el resto de la pantalla como esta: mismo estilo, mismos componentes, mismos textos no marcados.\n'
      printf 'Registro durable de las entregas: '
      local primero=1
      for p in "${entregas[@]}"; do
        [ "$primero" = 1 ] || printf ', '
        primero=0
        printf 'data/edicion/%s' "$(basename "$p")"
      done
      printf '.\n'
    } >"$spec"

    awk -v intent="$intent" -v spec="$spec" '
      /^\{TASK\}$/ { while ((getline l < intent) > 0) print l; close(intent); next }
      /^\{FIRSTMATE_SPEC\}$/ { while ((getline l < spec) > 0) print l; close(spec); next }
      { print }
    ' "$encargo" >"$TMP/brief.md" || die "no pude rellenar el encargo de $id_final"
    mv "$TMP/brief.md" "$encargo"
    if grep -qE '^\{TASK\}$|^\{FIRSTMATE_SPEC\}$' "$encargo"; then
      die "el encargo de $id_final conserva marcadores sin rellenar"
    fi
    printf 'tarea creada: %s\n' "$id_final"
    printf 'modo: %s (proyecto %s)\n' "$modo" "$repo"
    printf 'encargo: %s\n' "$encargo"
  fi

  # Record the application per delivery: delivered, still-owed and discarded
  # marks, the durable record of what each delivery became.
  local entregadas_file="$TMP/entregadas.txt" pendientes_file="$TMP/pendientes.txt" descartadas_file="$TMP/descartadas.txt" hechas_file="$TMP/hechas.txt" marca_id='' n_entregadas='' n_pendientes=''
  for p in "${entregas[@]}"; do
    : >"$entregadas_file"
    : >"$pendientes_file"
    : >"$descartadas_file"
    while IFS= read -r -d '' rec; do
      marca_id=$(fm_edicion_campo "$rec" 1)
      if [ "${#marcas[@]}" -gt 0 ]; then
        printf '%s\n' "${marcas[@]}" | grep -qxF -- "$marca_id" || continue
      elif ! fm_edicion_es_aplicable "$rec"; then
        continue
      fi
      printf '%s\n' "$marca_id" >>"$entregadas_file"
    done < <(fm_edicion_records "$p" todas)
    fm_edicion_marca_ids "$p" todas >>"$pendientes_file"
    if fm_edicion_leer_sidecar "$p"; then
      while IFS= read -r marca_id; do
        [ -n "$marca_id" ] || continue
        printf '%s\n' "$marca_id" >>"$entregadas_file"
      done <<EOF
$SIDECAR_ENTREGADAS
EOF
      while IFS= read -r marca_id; do
        [ -n "$marca_id" ] || continue
        printf '%s\n' "$marca_id" >>"$descartadas_file"
      done <<EOF
$SIDECAR_DESCARTADAS
EOF
    fi
    LC_ALL=C sort -u "$entregadas_file" -o "$entregadas_file"
    LC_ALL=C sort -u "$descartadas_file" -o "$descartadas_file"
    LC_ALL=C sort -u "$pendientes_file" -o "$pendientes_file"
    cat "$entregadas_file" "$descartadas_file" >"$hechas_file"
    LC_ALL=C sort -u "$hechas_file" -o "$hechas_file"
    comm -23 "$pendientes_file" "$hechas_file" >"$TMP/pendientes-final.txt"
    fm_edicion_escribir_sidecar "$p" "$id_final" "$modo" "$entregadas_file" "$TMP/pendientes-final.txt" "$descartadas_file" ||
      die "no pude anotar la entrega $(basename "$p")"
    n_entregadas=$(grep -c . "$entregadas_file" || true)
    n_pendientes=$(grep -c . "$TMP/pendientes-final.txt" || true)
    printf 'entrega: %s -> %s marcas aplicadas' "$(basename "$p")" "$n_entregadas"
    [ "$n_pendientes" -gt 0 ] && printf ', %s pendientes' "$n_pendientes"
    printf '\n'
  done

  if [ "${#retenidas[@]}" -gt 0 ]; then
    printf '\n'
    fm_edicion_presentar_revisar "$id_final" "${retenidas[@]}"
    return 3
  fi
  printf 'siguiente: cierra las entregas con fm-edicion.sh cerrar <entrega>\n'
  return 0
}

# --- cerrar -----------------------------------------------------------------

cmd_cerrar() {
  local arg='' descartes=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --descartar)
        [ -n "${2:-}" ] || fail "--descartar necesita <id>"
        descartes+=("$2")
        shift 2
        ;;
      --descartar=*)
        [ -n "${1#--descartar=}" ] || fail "--descartar necesita <id>"
        descartes+=("${1#--descartar=}")
        shift
        ;;
      -*) fail "opcion desconocida: $1" ;;
      *)
        [ -z "$arg" ] || fail "cerrar toma una sola entrega"
        arg=$1
        shift
        ;;
    esac
  done
  [ -n "$arg" ] || fail "uso: fm-edicion.sh cerrar <fichero> [--descartar <id>]..."
  require_jq
  local entrega='' rc=0 base='' tarea='' modo='' side='' destino='' cuenta='' marca='' companion=''
  local n_descartadas='' descartadas_lista='' pendientes=''
  entrega=$(fm_edicion_entrega_path "$arg") || {
    rc=$?
    if [ "$rc" -eq 2 ]; then
      fail "la entrega '$arg' esta fuera de $SALIDA; la ruta nunca escribe fuera del directorio de marcas"
    fi
    fail "no encuentro la entrega '$arg' en $SALIDA (o ya esta cerrada)"
  }
  base=$(basename "$entrega")
  fm_edicion_validar "$entrega"
  if ! fm_edicion_leer_sidecar "$entrega"; then
    fail "la entrega $base no se ha aplicado todavia; aplica primero con 'aplicar --fichero $base'"
  fi
  tarea=$SIDECAR_TAREA
  [ -n "$tarea" ] || fail "la entrega $base no tiene tarea anotada; repite 'aplicar --fichero $base'"
  side=$(fm_edicion_sidecar "$entrega")

  local entregadas_file="$TMP/cerrar-entregadas.txt" pendientes_file="$TMP/cerrar-pendientes.txt"
  local descartadas_file="$TMP/cerrar-descartadas.txt" descartes_file="$TMP/cerrar-descartes.txt"
  local restantes_file="$TMP/cerrar-restantes.txt" todas_file="$TMP/cerrar-todas.txt"
  printf '%s\n' "$SIDECAR_ENTREGADAS" | grep . >"$entregadas_file" || true
  fm_edicion_adeudadas "$entrega" >"$pendientes_file"
  printf '%s\n' "$SIDECAR_DESCARTADAS" | grep . >"$descartadas_file" || true
  : >"$descartes_file"
  local d=''
  for d in ${descartes[@]+"${descartes[@]}"}; do
    grep -qxF -- "$d" "$pendientes_file" ||
      fail "la marca '$d' no esta pendiente en $base; solo se descarta una marca sin entregar"
    printf '%s\n' "$d" >>"$descartes_file"
  done
  LC_ALL=C sort -u "$entregadas_file" -o "$entregadas_file"
  LC_ALL=C sort -u "$pendientes_file" -o "$pendientes_file"
  LC_ALL=C sort -u "$descartadas_file" -o "$descartadas_file"
  LC_ALL=C sort -u "$descartes_file" -o "$descartes_file"
  cat "$descartadas_file" "$descartes_file" | LC_ALL=C sort -u >"$todas_file"
  comm -23 "$pendientes_file" "$descartes_file" >"$restantes_file"

  if [ -s "$descartes_file" ]; then
    modo=$(jq -r '.modo // ""' "$side")
    fm_edicion_escribir_sidecar "$entrega" "$tarea" "$modo" "$entregadas_file" "$restantes_file" "$todas_file" ||
      die "no pude anotar los descartes en $base"
    fm_edicion_leer_sidecar "$entrega" || true
    while IFS= read -r d; do
      [ -n "$d" ] || continue
      printf 'descartada: %s\n' "$d"
    done <"$descartes_file"
  fi

  pendientes=$(fm_edicion_cuenta "$(cat "$restantes_file")")
  if [ "$pendientes" -gt 0 ]; then
    printf 'fm-edicion: la entrega %s no se puede cerrar: %s marca(s) siguen pendientes.\n' "$base" "$pendientes" >&2
    printf 'Entrega cada una a la tarea %s con:\n' "$tarea" >&2
    while IFS= read -r marca; do
      [ -n "$marca" ] || continue
      printf '  fm-edicion.sh aplicar --fichero %s --tarea %s --marca %s\n' "$base" "$tarea" "$marca" >&2
    done <"$restantes_file"
    return 2
  fi

  destino="$SALIDA/aplicadas"
  mkdir -p "$destino"
  modo=$(jq -r '.modo // ""' "$side")
  cuenta=$(jq -r '(.entregadas // []) | length' "$side")
  n_descartadas=$(jq -r '(.descartadas // []) | length' "$side")
  descartadas_lista=$(jq -r '(.descartadas // []) | join(", ")' "$side")
  if [ ! -f "$destino/registro.md" ]; then
    printf '# Entregas de marcas cerradas\n\n' >"$destino/registro.md"
  fi
  if [ "$n_descartadas" -gt 0 ]; then
    printf -- '- %s - %s -> tarea %s (%s marcas, %s descartadas: %s, modo %s)\n' \
      "$(fm_edicion_ahora)" "$base" "$tarea" "$cuenta" "$n_descartadas" "$descartadas_lista" "${modo:-sin modo}" >>"$destino/registro.md"
  else
    printf -- '- %s - %s -> tarea %s (%s marcas, modo %s)\n' \
      "$(fm_edicion_ahora)" "$base" "$tarea" "$cuenta" "${modo:-sin modo}" >>"$destino/registro.md"
  fi

  companion="${entrega%.json}.md"
  mv "$entrega" "$destino/$base"
  if [ -f "$companion" ]; then
    mv "$companion" "$destino/${base%.json}.md"
  fi
  mv "$side" "$destino/$(basename "$side")"
  printf 'cerrada: %s -> %s\n' "$base" "$destino"
  if [ "$n_descartadas" -gt 0 ]; then
    printf 'descartadas: %s\n' "$descartadas_lista"
    printf 'resultado: tarea %s (%s marcas, %s descartadas: %s, modo %s)\n' \
      "$tarea" "$cuenta" "$n_descartadas" "$descartadas_lista" "${modo:-sin modo}"
  else
    printf 'resultado: tarea %s (%s marcas, modo %s)\n' "$tarea" "$cuenta" "${modo:-sin modo}"
  fi
  printf 'registro: %s/registro.md\n' "$destino"
  return 0
}

# --- dispatch ---------------------------------------------------------------

case "${1:-}" in
  -h | --help)
    usage
    exit 0
    ;;
  '')
    usage >&2
    exit 2
    ;;
esac

COMANDO=$1
shift
case "$COMANDO" in
  abrir) cmd_abrir "$@" ;;
  marcas) cmd_marcas "$@" ;;
  aplicar) cmd_aplicar "$@" ;;
  cerrar) cmd_cerrar "$@" ;;
  *) fail "subcomando desconocido: $COMANDO (usa abrir, marcas, aplicar o cerrar)" ;;
esac
