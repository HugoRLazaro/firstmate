#!/usr/bin/env python3
"""Tablero del trabajo - servidor local, estado real y camino de vuelta.

bin/fm-tablero.sh is the only supported caller for start/stop/status; it owns
home resolution, the pidfile, and the bind/port choice. This module owns the
derivation of the five columns, the durable conversation log, and the three
ways a captain action leaves this machine for firstmate.

Serves, over HTTP on loopback and the machine's Tailscale address only:

  GET  /                    the page
  GET  /pantalla.css        its stylesheet
  GET  /pantalla.js         its behaviour
  GET  /api/estado          the five columns, derived from this home's real state,
                            each card with the state of what the captain wrote in it
  GET  /api/conversacion    the durable conversation, paired question -> answer
  POST /api/responder       {"tarea","texto"}            -> bin/fm-inbox.sh note
                                                            + bin/fm-captain-hold.sh answer
  POST /api/mensaje         {"texto"}                    -> bin/fm-inbox.sh note
  POST /api/peticion        {"tarea","accion","destino"} -> bin/fm-inbox.sh note

Every source of truth is read, never written, except the three commands above:

  <home>/data/backlog.md      tasks, states, captain holds, blocked_by (the path
                              `.tasks.toml` pins for this home; the same file
                              tasks-axi reads and writes)
  <home>/state/<id>.meta      which tasks have a worker on them right now
  <home>/state/<id>.status    the last event each worker reported
  <home>/state/.afk-contract  the away posture, when there is one

Nothing here changes a task's state on its own. Answering a decision closes it
through the existing decision mechanism with the captain's own words, and
moving or removing a card is only a request placed in firstmate's inbox: the
board asks, firstmate does.

A question or an answer written in a card is ALSO a message to firstmate, so it
leaves exactly one note in that inbox, naming the task and carrying the
captain's words verbatim, after the decision mechanism is asked to close or
release anything. The chat and the move/remove requests keep their own single
note, and no action ever writes two.

Usage:
  fm-tablero.py serve --home <home> [--host <addr>]... [--port <n>]
  fm-tablero.py reply --home <home> [--reply-to <id>] [<texto>...]
  fm-tablero.py pairs --home <home>
  fm-tablero.py --help
"""

from __future__ import annotations

import argparse
import fcntl
import json
import os
import re
import signal
import socketserver
import subprocess
import sys
import threading
import time
import tomllib
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

PAGINA = Path(__file__).resolve().parent / "tablero"
MAX_CUERPO = 64 * 1024
MAX_MENSAJES = 300
MAX_RESPUESTA = 8192
SLUG_TAREA = re.compile(r"[A-Za-z0-9._-]+")

MESES = (
    "enero", "febrero", "marzo", "abril", "mayo", "junio",
    "julio", "agosto", "septiembre", "octubre", "noviembre", "diciembre",
)

# Las cinco etapas, en el orden del kanban de izquierda a derecha.
ETAPAS = (
    {"id": "ahora", "nombre": "Ahora mismo", "motivo": "En marcha en este momento",
     "color": "#1d4ed8"},
    {"id": "espera", "nombre": "Espera tu respuesta", "motivo": "Necesita que decidas algo",
     "color": "#b42318"},
    {"id": "subir", "nombre": "Terminado, espera subir", "motivo": "Hecho y probado. Falta tu visto bueno",
     "color": "#0e7490"},
    {"id": "plan", "nombre": "Planificado, sin empezar", "motivo": "Previsto, aún no ha arrancado",
     "color": "#8a929d"},
    {"id": "hecho", "nombre": "Terminado y publicado", "motivo": "Hecho y ya en producción",
     "color": "#0f6f45", "plegada": True},
)
ETAPA_POR_ID = {e["id"]: e for e in ETAPAS}

# Claves que el backlog escribe entre paréntesis al final de la línea de una tarea.
CLAVES_ANOTACION = (
    "repo", "kind", "since", "done", "merged", "reported", "hold", "hold-kind", "hold-until",
    "blocks", "deps", "priority", "deadline", "closed", "link", "links",
    "delivery-state", "blocked-by", "delivery", "origin", "until",
)

SECCION_ESTADO = {
    "in flight": "in_flight",
    "queued": "queued",
    "done": "done",
    "blocked": "blocked",
}


# --------------------------------------------------------------------- backlog


def _paren_que_abre(texto: str, cierre: int) -> int:
    """Índice del paréntesis que abre el paréntesis que cierra en `cierre`, o -1."""
    profundidad = 0
    for i in range(cierre, -1, -1):
        c = texto[i]
        if c == ")":
            profundidad += 1
        elif c == "(":
            profundidad -= 1
            if profundidad == 0:
                return i
    return -1


def _cabeza_y_valor(dentro: str) -> tuple[str, str]:
    """Parte `clave: valor` o `clave valor`, que son las dos formas del backlog."""
    cabeza, sep, valor = dentro.partition(":")
    if sep:
        return cabeza.strip().lower(), valor.strip()
    trozos = dentro.split(None, 1)
    if len(trozos) == 2:
        return trozos[0].strip().lower(), trozos[1].strip()
    return dentro.strip().lower(), ""


def _anotaciones(resto: str) -> tuple[str, dict]:
    """Separa el título de las anotaciones finales `(clave: valor)` o `(clave valor)`.

    Se recorta desde el final y solo mientras el paréntesis que abre corresponda a
    una clave conocida, para no comerse un paréntesis que forme parte del título.
    """
    datos: dict[str, str] = {}
    while resto.endswith(")"):
        abre = _paren_que_abre(resto, len(resto) - 1)
        if abre < 0:
            break
        cabeza, valor = _cabeza_y_valor(resto[abre + 1:-1])
        if not valor or cabeza not in CLAVES_ANOTACION:
            break
        datos[cabeza] = valor
        resto = resto[:abre].rstrip()
    return resto, datos


def parsear_backlog(texto: str) -> list[dict]:
    """Devuelve las tareas del backlog en el orden en que están escritas."""
    tareas: list[dict] = []
    actual: dict | None = None
    seccion = ""
    for linea in texto.splitlines():
        if linea.startswith("## "):
            seccion = linea[3:].strip().lower()
            actual = None
            continue
        m = re.match(r"^- \[( |x)\] (\S+) - (.*)$", linea)
        if m:
            titulo, anot = _anotaciones(m.group(3))
            actual = {
                "id": m.group(2),
                "titulo": titulo.strip(),
                "estado": SECCION_ESTADO.get(seccion, seccion or "desconocido"),
                "anotaciones": anot,
                "cuerpo": [],
            }
            tareas.append(actual)
            continue
        if actual is not None and linea.startswith("  ") and linea.strip():
            actual["cuerpo"].append(linea.strip())
    return tareas


def _retenida(tarea: dict) -> bool:
    anot = tarea["anotaciones"]
    if anot.get("hold"):
        return True
    return any(linea.lower().startswith("captain hold set:") for linea in tarea["cuerpo"])


def _desde_retencion(tarea: dict) -> str | None:
    for linea in tarea["cuerpo"]:
        if linea.lower().startswith("captain hold set:"):
            return linea.split(":", 1)[1].strip()
    return None


def _entregable(tarea: dict) -> str | None:
    for linea in tarea["cuerpo"]:
        bajo = linea.lower()
        if bajo.startswith("deliverable of the finished work:") or bajo.startswith("origin:"):
            return linea.split(":", 1)[1].strip()
    return None


def _recorta(texto: str, limite: int) -> str:
    limpio = re.sub(r"\s+", " ", texto or "").strip()
    if len(limpio) <= limite:
        return limpio
    corte = limpio[:limite]
    punto = max(corte.rfind(". "), corte.rfind("? "), corte.rfind("! "))
    if punto > limite * 0.5:
        return corte[:punto + 1]
    return corte.rstrip() + "…"


# ------------------------------------------------------------------ estado vivo


def leer_meta(ruta: Path) -> dict:
    """Pares clave/valor de un registro del home: `clave=valor` o `clave: valor`."""
    datos: dict[str, str] = {}
    try:
        texto = ruta.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return datos
    for linea in texto.splitlines():
        if "=" in linea:
            clave, _, valor = linea.partition("=")
        elif ":" in linea:
            clave, _, valor = linea.partition(":")
        else:
            continue
        clave = clave.strip()
        if clave:
            datos[clave] = valor.strip()
    return datos


def leer_novedad(state_dir: Path, tarea_id: str) -> dict | None:
    """Último evento escrito en state/<id>.status, leyendo solo la cola."""
    ruta = state_dir / f"{tarea_id}.status"
    try:
        with ruta.open("rb") as fh:
            fh.seek(0, os.SEEK_END)
            tam = fh.tell()
            fh.seek(max(0, tam - 4096))
            crudo = fh.read().decode("utf-8", errors="replace")
        mtime = ruta.stat().st_mtime
    except OSError:
        return None
    ultima = ""
    for linea in crudo.splitlines():
        if linea.strip():
            ultima = linea.strip()
    if not ultima:
        return None
    m = re.match(r"^([a-zA-Z][a-zA-Z_-]*):\s*(.*)$", ultima)
    return {
        "estado": (m.group(1).lower() if m else ""),
        "nota": (m.group(2) if m else ultima),
        "mtime": mtime,
    }


def leer_ausencia(home: Path) -> dict | None:
    contrato = home / "state" / ".afk-contract"
    if not contrato.exists():
        return None
    datos = leer_meta(contrato)
    hasta = (datos.get("expected_return") or "").strip()
    if not hasta or hasta == "-":
        return {"texto": "Estás en modo ausencia: lo que llegue aquí se guarda y firstmate lo verá cuando vuelvas."}
    return {"hasta": hasta, "texto": f"Estás en modo ausencia hasta el {hasta}. Lo que llegue aquí se guarda y firstmate lo verá cuando vuelvas."}


def ruta_backlog(home: Path) -> tuple[Path | None, str | None]:
    """El backlog del home, resuelto como lo resuelve tasks-axi."""
    config = home / ".tasks.toml"
    if config.exists():
        try:
            datos = tomllib.loads(config.read_text(encoding="utf-8"))
        except (OSError, tomllib.TOMLDecodeError) as exc:
            return None, f"No se pudo leer .tasks.toml: {exc}"
        if (datos.get("backend") or "markdown") != "markdown":
            return None, ("Este home guarda el backlog en «" + str(datos.get("backend"))
                          + "», y el tablero sabe leer el backlog de markdown.")
        ruta = datos.get("markdown", {}).get("path") or "data/backlog.md"
        return home / ruta, None
    return home / "data" / "backlog.md", None


# --------------------------------------------------------------- clasificación


def _bloquea_de(tarea: dict, retenida: bool, tiene_encargado: bool) -> str:
    """Lo que la tarjeta tiene parado, sin inventarlo: retenida siempre para algo."""
    anot = tarea["anotaciones"]
    if anot.get("blocks"):
        return "Bloquea: " + _recorta(anot["blocks"], 90)
    if anot.get("blocked-by") and anot["blocked-by"] not in ("-", "none"):
        return "Espera a que termine: " + _recorta(anot["blocked-by"], 90)
    if not retenida:
        return ""
    if tiene_encargado:
        return "Tiene trabajo parado esperando tu respuesta."
    return "Lo que depende de esto está parado hasta que decidas."


def modo_de_respuesta(tarea: dict, tiene_encargado: bool) -> str:
    """Cómo se cierra la llamada al capitán desde el tablero.

    Un encargado en marcha esperando la respuesta es trabajo que sigue: la
    respuesta lo suelta. Sin encargado, la fila es la llamada misma (la pregunta,
    el informe, la decisión) y responder la da por cerrada.
    """
    if tiene_encargado:
        return "soltar"
    return "cerrar"


ACCION_TEXTO = {
    "cerrar": "Al responder, la decisión queda cerrada igual que si se la escribieras en su chat.",
    "soltar": "Al responder, el trabajo que está esperando sigue en marcha con tu respuesta.",
}


def clasificar(tarea: dict, novedad: dict | None, tiene_encargado: bool) -> dict:
    """Etapa, tipo de etiqueta y textos de una tarjeta, a partir del registro real."""
    retenida = _retenida(tarea)
    estado = tarea["estado"]
    tipo_tarea = tarea["anotaciones"].get("kind", tarea["anotaciones"].get("hold-kind", ""))
    tarea["tipo"] = tipo_tarea
    nota = (novedad or {}).get("nota", "")
    estado_novedad = (novedad or {}).get("estado", "")

    if estado == "done":
        etapa, tipo = "hecho", "hecho"
    elif retenida:
        etapa = "espera"
        tipo = "bloquea" if tipo_tarea in ("ship", "scout") else "confirma"
    elif estado == "in_flight" and estado_novedad == "done":
        etapa, tipo = "subir", "subir"
    elif estado == "in_flight":
        etapa, tipo = "ahora", "ahora"
    else:
        etapa, tipo = "plan", "plan"

    tarjeta = {
        "id": tarea["id"],
        "etapa": etapa,
        "tipo": tipo,
        "area": tarea["anotaciones"].get("repo", ""),
        "titulo": _recorta(tarea["titulo"], 220),
        "necesita": "",
        "detalle": "",
        "puntos": [],
        "bloquea": _bloquea_de(tarea, retenida and etapa == "espera", tiene_encargado),
        "quien": "",
        "desde": "",
        "puede_responder": False,
        "respuesta_accion": "",
        "color": ETAPA_POR_ID[etapa]["color"],
    }

    if etapa == "espera":
        motivo = tarea["anotaciones"].get("hold", "")
        tarjeta["necesita"] = _necesita_de(motivo)
        tarjeta["detalle"] = motivo
        tarjeta["puntos"] = _puntos_de(motivo, tarjeta["necesita"])
        desde = _desde_retencion(tarea)
        tarjeta["desde"] = ("Espera desde el " + desde[:10]) if desde else ""
        tarjeta["puede_responder"] = True
        modo = modo_de_respuesta(tarea, tiene_encargado)
        tarjeta["respuesta_modo"] = modo
        tarjeta["respuesta_accion"] = ACCION_TEXTO[modo]
    elif etapa == "ahora":
        tarjeta["necesita"] = "Nada por ahora: te aviso al terminar."
        tarjeta["detalle"] = nota
        tarjeta["quien"] = "Un ayudante de firstmate"
        tarjeta["desde"] = ("Último aviso a las " + _hora(novedad["mtime"])) if novedad else "Sin avisos todavía"
    elif etapa == "subir":
        tarjeta["necesita"] = "Falta tu visto bueno para subirlo."
        tarjeta["detalle"] = nota
        tarjeta["quien"] = "Un ayudante de firstmate"
        tarjeta["desde"] = ("Terminado a las " + _hora(novedad["mtime"])) if novedad else ""
    elif etapa == "plan":
        tarjeta["necesita"] = "Nada por ahora."
        tarjeta["detalle"] = ""
    else:
        entrega = _entregable(tarea)
        tarjeta["necesita"] = "Nada."
        tarjeta["detalle"] = entrega or ""

    return tarjeta


def _frases(texto: str) -> list[str]:
    """Parte un motivo escrito por firstmate en sus frases."""
    if not texto:
        return []
    partes = re.split(r"(?<=[.;:])\s+(?=[A-ZÁÉÍÓÚÜÑ«¿¡(0-9])", texto.strip())
    return [p.strip() for p in partes if p.strip()]


# Lo que convierte una frase en la petición que el capitán tiene delante: una
# pregunta o un verbo de decisión. Es una lectura del motivo que firstmate ya
# escribió ("un motivo conciso que lleva la pregunta y las opciones"), no texto nuevo.
PISTAS_DE_PETICION = re.compile(
    r"(?i)(\?|¿|\bdecidir\b|\bdecision(?:es)?\b|\beliges?\b|\belegir\b|\bdi\b|\bdime\b|"
    r"\bconfirma\b|\bconfírmalo\b|\baprueba\b|\bautoriza\b|\bsí o no\b|\brecomendado\b|"
    r"\bdi cu[aá]l\b|\bqu[eé] hago\b)"
)


def _necesita_de(motivo: str) -> str:
    """La pregunta que el capitán tiene delante, sacada del motivo de la retención.

    La petición suele ir al final ("Di cuál: A / B...", "Decisiones: a... b..."),
    así que se toma la última frase que la anuncia y lo que la sigue.
    """
    frases = _frases(motivo)
    if not frases:
        return "Espera tu respuesta."
    indices = [i for i, f in enumerate(frases) if PISTAS_DE_PETICION.search(f)]
    if not indices:
        return _recorta(frases[0], 190)
    return _recorta(" ".join(frases[indices[-1]:]), 230)


def _puntos_de(motivo: str, necesitado: str) -> list[str]:
    """Las frases del motivo que no forman la pregunta: el detalle que la sostiene."""
    frases = _frases(motivo)
    if len(frases) < 3:
        return []
    sobra = [f for f in frases if f not in necesitado]
    return [_recorta(f, 260) for f in sobra[:8]]


def _hora(epoch: float) -> str:
    return datetime.fromtimestamp(epoch).strftime("%H:%M")


def _texto_generado(ahora: datetime) -> str:
    return f"{ahora.day} de {MESES[ahora.month - 1]}, {ahora:%H:%M}"


def tablero(home: Path, ahora: datetime | None = None) -> dict:
    """El payload de /api/estado: lo que la pantalla pinta, tal cual sale del home."""
    ahora = ahora or datetime.now()
    state_dir = home / "state"
    aviso = None
    ruta, problema = ruta_backlog(home)
    if problema:
        aviso = problema
    tareas: list[dict] = []
    if ruta is not None:
        if ruta.exists():
            tareas = parsear_backlog(ruta.read_text(encoding="utf-8", errors="replace"))
        else:
            aviso = f"No hay backlog en {ruta}."

    nuevas = {}
    for tarea in tareas:
        nuevas[tarea["id"]] = leer_novedad(state_dir, tarea["id"])

    charla = preguntas_de_tarjeta(emparejar(leer_conversacion(home)))
    tarjetas = []
    for tarea in tareas:
        encargado = (state_dir / f"{tarea['id']}.meta").exists()
        tarjeta = clasificar(tarea, nuevas.get(tarea["id"]), encargado)
        tarjeta["pregunta"] = charla.get(tarjeta["id"], {})
        tarjetas.append(tarjeta)

    columnas = []
    for etapa in ETAPAS:
        mias = [t for t in tarjetas if t["etapa"] == etapa["id"]]
        columnas.append({**etapa, "tarjetas": mias})

    preguntan = sum(1 for t in tarjetas if t["etapa"] == "espera")
    bloquean = sum(1 for t in tarjetas if t["etapa"] == "espera" and t["tipo"] == "bloquea")
    return {
        "generado": ahora.astimezone(timezone.utc).isoformat(timespec="seconds"),
        "generado_texto": _texto_generado(ahora),
        "home": str(home),
        "aviso": aviso,
        "ausencia": leer_ausencia(home),
        "cuenta": {
            "preguntan": preguntan,
            "bloquean": bloquean,
            "ahora": sum(1 for t in tarjetas if t["etapa"] == "ahora"),
            "subir": sum(1 for t in tarjetas if t["etapa"] == "subir"),
            "plan": sum(1 for t in tarjetas if t["etapa"] == "plan"),
            "hecho": sum(1 for t in tarjetas if t["etapa"] == "hecho"),
        },
        "columnas": columnas,
    }


# --------------------------------------------------------------- conversación


def _rutas_conversacion(home: Path) -> tuple[Path, Path]:
    directorio = home / "state" / "tablero"
    return directorio / "conversacion.jsonl", directorio / "conversacion.lock"


def _carpeta_privada(home: Path) -> Path:
    carpeta = home / "state" / "tablero"
    carpeta.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(carpeta, 0o700)
    return carpeta


def _abrir_privado(ruta: Path, modo: str, banderas: int):
    fd = os.open(ruta, banderas, 0o600)
    os.fchmod(fd, 0o600)
    return os.fdopen(fd, modo, encoding="utf-8")


def leer_conversacion(home: Path) -> list[dict]:
    ruta, _ = _rutas_conversacion(home)
    if not ruta.exists():
        return []
    mensajes = []
    try:
        with ruta.open(encoding="utf-8", errors="replace") as fh:
            for linea in fh:
                linea = linea.strip()
                if not linea:
                    continue
                try:
                    dato = json.loads(linea)
                except json.JSONDecodeError:
                    continue
                # Sin identificador no se puede emparejar ni contestar, así que no
                # entra: una línea a medio escribir no puede tumbar el tablero.
                if isinstance(dato, dict) and dato.get("texto") and dato.get("id"):
                    mensajes.append(dato)
    except OSError:
        return []
    return mensajes[-MAX_MENSAJES:]


def nuevo_mensaje_id() -> str:
    """El identificador de un mensaje antes de escribirlo, para poder nombrarlo en la nota."""
    return f"m{int(datetime.now(timezone.utc).timestamp() * 1000)}-{os.getpid()}"


def anadir_mensaje(home: Path, de: str, texto: str, tipo: str = "mensaje",
                   tarea: str = "", titulo_tarea: str = "", responde_a: str = "",
                   nota: str = "", mensaje_id: str = "") -> dict:
    """Añade un mensaje al registro durable, con cerrojo y una sola escritura."""
    ruta, cerrojo = _rutas_conversacion(home)
    _carpeta_privada(home)
    ahora = datetime.now(timezone.utc)
    registro = {
        "id": mensaje_id or nuevo_mensaje_id(),
        "ts": ahora.isoformat(timespec="seconds"),
        "de": de,
        "tipo": tipo,
        "texto": texto,
        "tarea": tarea,
        "titulo_tarea": titulo_tarea,
        "nota": nota,
    }
    if responde_a:
        registro["responde_a"] = responde_a
    linea = json.dumps(registro, ensure_ascii=False) + "\n"
    with _abrir_privado(cerrojo, "a+", os.O_RDWR | os.O_CREAT) as candado:
        fcntl.flock(candado, fcntl.LOCK_EX)
        with _abrir_privado(ruta, "a", os.O_WRONLY | os.O_CREAT | os.O_APPEND) as fh:
            fh.write(linea)
            fh.flush()
            os.fsync(fh.fileno())
    return registro


def emparejar(mensajes: list[dict]) -> list[dict]:
    """Pone cada respuesta con su mensaje y marca los que siguen esperando.

    Una respuesta con `responde_a` va a ese mensaje; sin él, al mensaje del
    capitán más antiguo que aún no tenga ninguna respuesta.
    """
    salida = []
    respuestas: dict[str, list[str]] = {}
    pendientes: list[str] = []
    for mensaje in mensajes:
        copia = dict(mensaje)
        copia["respuestas"] = []
        if mensaje.get("de") == "capitan":
            pendientes.append(mensaje["id"])
        elif mensaje.get("de") == "firstmate":
            destino = mensaje.get("responde_a")
            if not destino or destino not in {m["id"] for m in mensajes}:
                destino = pendientes[0] if pendientes else ""
            copia["responde_a"] = destino
            if destino:
                respuestas.setdefault(destino, []).append(mensaje["id"])
                if destino in pendientes:
                    pendientes.remove(destino)
        salida.append(copia)
    for mensaje in salida:
        mensaje["respuestas"] = respuestas.get(mensaje["id"], [])
    return salida


def preguntas_de_tarjeta(mensajes: list[dict]) -> dict[str, dict]:
    """Estado, por tarea, de lo último que el capitán escribió en su tarjeta.

    Un mensaje escrito en una tarjeta nombra su tarea; uno del chat no nombra
    ninguna, y una petición de mover o quitar no es una pregunta al capitán, así
    que la tarjeta sólo mira los mensajes que llevan tarea y no son peticiones.
    Manda el último: mientras no tenga respuesta espera contestación, y en cuanto
    firstmate la contesta queda contestada.
    """
    estado: dict[str, dict] = {}
    for mensaje in mensajes:
        tarea = (mensaje.get("tarea") or "").strip()
        if not tarea or mensaje.get("de") != "capitan":
            continue
        if mensaje.get("tipo") == "peticion":
            continue
        respuestas = mensaje.get("respuestas") or []
        estado[tarea] = {
            "estado": "contestada" if respuestas else "espera",
            "mensaje": mensaje["id"],
            "ts": mensaje.get("ts", ""),
        }
    return estado


# ------------------------------------------------------------------- comandos


def _ejecutar(argumentos: list[str], entrada: str | None = None,
              timeout: int = 180) -> tuple[int, str, str]:
    try:
        proceso = subprocess.run(
            argumentos, input=entrada, capture_output=True, text=True,
            timeout=timeout, check=False,
        )
    except FileNotFoundError:
        return 127, "", f"No existe {argumentos[0]}"
    except subprocess.TimeoutExpired:
        return 124, "", f"{argumentos[0]} tardó más de {timeout}s"
    return proceso.returncode, proceso.stdout, proceso.stderr


def responder_decision(home: Path, tarea: str, texto: str) -> dict:
    """Cierra la decisión con las palabras del capitán, por el mecanismo de la casa."""
    limpio = texto.strip()
    if not limpio:
        return {"ok": False, "error": "La respuesta está vacía."}
    if len(limpio.encode("utf-8")) > MAX_RESPUESTA:
        return {"ok": False, "error": "La respuesta es demasiado larga."}
    carpeta = _carpeta_privada(home)
    decision = carpeta / f"decision-{tarea}.txt"
    with _abrir_privado(decision, "w", os.O_WRONLY | os.O_CREAT | os.O_TRUNC) as fh:
        fh.write(limpio + "\n")

    con_encargado = (home / "state" / f"{tarea}.meta").exists()
    comando = [str(home / "bin" / "fm-captain-hold.sh"), "answer", tarea,
               "--decision-file", str(decision)]
    modo = "cerrar"
    if con_encargado:
        comando.append("--release")
        modo = "soltar"
    codigo, salida, error = _ejecutar(comando)
    if codigo != 0:
        return {"ok": False, "error": (error or salida or "No se pudo cerrar la decisión.").strip()[:600]}
    return {"ok": True, "modo": modo}


def escribir_buzon(home: Path, texto: str) -> tuple[bool, str]:
    """Deja la nota y devuelve si se guardó más el identificador que el buzón anuncia.

    `fm-inbox.sh note` publica la línea `queued <id>`, ese es el único sitio del
    que se lee el identificador: lleva mayúsculas, así que recortarlo de la ruta
    del fichero lo dejaría a medias.
    """
    codigo, salida, error = _ejecutar([str(home / "bin" / "fm-inbox.sh"), "note", "-"], entrada=texto)
    if codigo != 0:
        return False, (error or salida or "El buzón de firstmate rechazó el mensaje.").strip()[:400]
    m = re.search(r"(?m)^queued\s+(\S+)", salida)
    return True, (m.group(1) if m else "")


def texto_peticion(accion: str, tarea: str, titulo: str, columna: str) -> str:
    """El encargo que el tablero deja en el buzón de firstmate.

    El aviso lleva consigo cómo contestar, para que quien lo lea sepa publicar en
    la conversación del tablero sin tener que averiguarlo.
    """
    quien = f"{tarea}" + (f' («{titulo}»)' if titulo else "")
    como_contestar = 'Contesta en el tablero con: bin/fm-tablero.sh reply "<texto>"'
    if accion == "mover":
        return (f"[Tablero] El capitán pide mover la tarea {quien} a la columna «{columna}». "
                f"El tablero no cambia estados por su cuenta: hazlo tú. {como_contestar}")
    return (f"[Tablero] El capitán pide quitar la tarea {quien}. "
            "El tablero no borra nada: confírmalo con él y, si te lo dice, bórrala tú. "
            f"{como_contestar}")


def resumen_peticion(accion: str, columna: str) -> str:
    """Lo que se enseña en la conversación: lo que el capitán pidió, sin jerga interna."""
    if accion == "mover":
        return f"Pedir que muevan esta tarea a «{columna}»."
    return "Pedir que quiten esta tarea del tablero."


def texto_mensaje(texto: str) -> str:
    return ("[Tablero] Mensaje del capitán desde la conversación del tablero:\n"
            + texto.strip()
            + '\n\nContesta en el tablero con: bin/fm-tablero.sh reply "<texto>"')


def texto_tarjeta(tarea: str, titulo: str, texto: str, mensaje_id: str,
                  situacion: str = "") -> str:
    """El aviso que deja en el buzón una pregunta o respuesta escrita en una tarjeta.

    Nombra la tarea a la que se refiere, lleva las palabras del capitán tal cual y
    dice cómo contestar en la conversación emparejado con ese mensaje concreto, que
    ya tiene identificador porque se le pasa el mismo con el que se guardará.
    """
    quien = f"{tarea}" + (f' («{titulo}»)' if titulo else "")
    aviso = f"[Tablero] El capitán escribe en la tarjeta de la tarea {quien}:\n{texto.strip()}"
    if situacion:
        aviso += f"\n\n{situacion}"
    return (aviso
            + f'\n\nContesta en el tablero con: bin/fm-tablero.sh reply --reply-to {mensaje_id} "<texto>"')


# --------------------------------------------------------------------- HTTP


class Manejador(BaseHTTPRequestHandler):
    server_version = "fm-tablero"
    protocol_version = "HTTP/1.1"
    home: Path
    origenes: tuple[str, ...] = ()

    def log_message(self, formato: str, *args) -> None:
        pass

    # -- utilidades ------------------------------------------------------

    def _json(self, datos: dict, codigo: int = 200) -> None:
        cuerpo = json.dumps(datos, ensure_ascii=False).encode("utf-8")
        self.send_response(codigo)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(cuerpo)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(cuerpo)

    def _archivo(self, ruta: Path, tipo: str) -> None:
        try:
            cuerpo = ruta.read_bytes()
        except OSError:
            self.send_error(404, "No está")
            return
        self.send_response(200)
        self.send_header("Content-Type", tipo)
        self.send_header("Content-Length", str(len(cuerpo)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(cuerpo)

    def _origen_ajeno(self) -> bool:
        """Rechaza peticiones que un navegador manda desde otra página."""
        origen = self.headers.get("Origin")
        if not origen:
            return False
        return origen not in self.origenes

    def _cuerpo(self) -> dict:
        try:
            largo = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            return {}
        if largo <= 0 or largo > MAX_CUERPO:
            return {}
        try:
            return json.loads(self.rfile.read(largo).decode("utf-8"))
        except (json.JSONDecodeError, UnicodeDecodeError):
            return {}

    # -- rutas -----------------------------------------------------------

    def do_GET(self) -> None:  # noqa: N802 - nombre que impone http.server
        ruta = self.path.split("?", 1)[0]
        if ruta in ("/", "/index.html"):
            self._archivo(PAGINA / "pantalla.html", "text/html; charset=utf-8")
        elif ruta == "/pantalla.css":
            self._archivo(PAGINA / "pantalla.css", "text/css; charset=utf-8")
        elif ruta == "/pantalla.js":
            self._archivo(PAGINA / "pantalla.js", "text/javascript; charset=utf-8")
        elif ruta == "/api/estado":
            self._json(tablero(self.home))
        elif ruta == "/api/conversacion":
            self._json({"mensajes": emparejar(leer_conversacion(self.home))})
        else:
            self.send_error(404, "No está")

    def do_POST(self) -> None:  # noqa: N802 - nombre que impone http.server
        if self._origen_ajeno():
            self._json({"ok": False, "error": "Petición de otra página."}, 403)
            return
        ruta = self.path.split("?", 1)[0]
        datos = self._cuerpo()
        if not datos:
            self._json({"ok": False, "error": "No llegó nada que hacer."}, 400)
            return
        if ruta == "/api/responder":
            self._responder(datos)
        elif ruta == "/api/mensaje":
            self._mensaje(datos)
        elif ruta == "/api/peticion":
            self._peticion(datos)
        else:
            self.send_error(404, "No está")

    def _responder(self, datos: dict) -> None:
        tarea = str(datos.get("tarea") or "").strip()
        titulo = str(datos.get("titulo") or "")
        limpio = str(datos.get("texto") or "").strip()
        if not tarea:
            self._json({"ok": False, "error": "Falta la tarea."}, 400)
            return
        if not SLUG_TAREA.fullmatch(tarea):
            self._json({"ok": False, "error": "El identificador de la tarea no es válido."}, 400)
            return
        if not limpio:
            self._json({"ok": False, "error": "La respuesta está vacía."}, 400)
            return

        resultado = responder_decision(self.home, tarea, limpio)
        if resultado["ok"]:
            situacion = ("La decisión queda cerrada con estas palabras."
                         if resultado["modo"] == "cerrar"
                         else "El trabajo que esperaba sigue en marcha con ellas.")
        else:
            situacion = "El tablero no ha podido cerrar la decisión: " + resultado["error"]

        # Lo escrito en una tarjeta avisa por el mismo camino que un mensaje del
        # chat, y sólo por uno: mover o quitar ya avisan por su propia petición.
        mensaje_id = nuevo_mensaje_id()
        en_buzon, detalle = escribir_buzon(
            self.home, texto_tarjeta(tarea, titulo, limpio, mensaje_id, situacion))
        anadir_mensaje(self.home, "capitan", limpio, tipo="decision", tarea=tarea,
                       titulo_tarea=titulo, nota=detalle if en_buzon else "",
                       mensaje_id=mensaje_id)

        avisos = []
        if resultado["ok"]:
            avisos.append("Respuesta enviada: la decisión queda cerrada, con tus palabras."
                          if resultado["modo"] == "cerrar"
                          else "Respuesta enviada: el trabajo que esperaba sigue con ella.")
        else:
            avisos.append("Tu mensaje queda guardado, pero la decisión no se ha podido cerrar: "
                          + resultado["error"])
        if en_buzon:
            avisos.append("Firstmate lo tiene ya en su buzón.")
        else:
            avisos.append("Firstmate no ha recibido el aviso (" + detalle
                          + "): escríbele desde la conversación.")
        self._json({"ok": True, "aviso": " ".join(avisos)})

    def _mensaje(self, datos: dict) -> None:
        texto = str(datos.get("texto") or "").strip()
        if not texto:
            self._json({"ok": False, "error": "El mensaje está vacío."}, 400)
            return
        ok, referencia = escribir_buzon(self.home, texto_mensaje(texto))
        if not ok:
            self._json({"ok": False, "error": referencia or "No se pudo dejar el mensaje."}, 502)
            return
        anadir_mensaje(self.home, "capitan", texto, tipo="mensaje", nota=referencia)
        self._json({"ok": True})

    def _peticion(self, datos: dict) -> None:
        tarea = str(datos.get("tarea") or "").strip()
        accion = str(datos.get("accion") or "").strip()
        titulo = str(datos.get("titulo") or "")
        columna = str(datos.get("columna") or datos.get("destino") or "")
        if not tarea or accion not in ("mover", "quitar"):
            self._json({"ok": False, "error": "Petición incompleta."}, 400)
            return
        texto = texto_peticion(accion, tarea, titulo, columna)
        ok, referencia = escribir_buzon(self.home, texto)
        if not ok:
            self._json({"ok": False, "error": referencia or "No se pudo dejar el encargo."}, 502)
            return
        anadir_mensaje(self.home, "capitan", resumen_peticion(accion, columna), tipo="peticion",
                       tarea=tarea, titulo_tarea=titulo, nota=referencia)
        self._json({"ok": True})


class Servidor(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def handle_error(self, peticion, direccion) -> None:
        exc = sys.exc_info()[1]
        if isinstance(exc, (BrokenPipeError, ConnectionResetError)):
            return
        super().handle_error(peticion, direccion)


def servir(home: Path, hosts: list[str], puerto: int) -> int:
    for host in hosts:
        if host in ("0.0.0.0", "::", ""):
            print("fm-tablero: no se abre el tablero a toda la máquina; "
                  "usa su dirección de Tailscale o 127.0.0.1.", file=sys.stderr)
            return 2
    origenes = {f"http://{h}:{puerto}" for h in hosts}
    if any(h in ("127.0.0.1", "localhost", "::1") for h in hosts):
        origenes.update(f"http://{alias}:{puerto}" for alias in ("127.0.0.1", "localhost"))
    clase = type("ManejadorDelHome", (Manejador,), {
        "home": home,
        "origenes": tuple(origenes),
    })
    servidores = []
    for host in hosts:
        try:
            servidores.append(Servidor((host, puerto), clase))
        except OSError as exc:
            for otro in servidores:
                otro.server_close()
            print(f"fm-tablero: no se pudo escuchar en {host}:{puerto}: {exc}", file=sys.stderr)
            return 3

    parar = threading.Event()

    def apagar(_senal, _marco):
        parar.set()

    signal.signal(signal.SIGTERM, apagar)
    signal.signal(signal.SIGINT, apagar)

    hilos = []
    for servidor in servidores:
        hilo = threading.Thread(target=servidor.serve_forever, kwargs={"poll_interval": 0.3}, daemon=True)
        hilo.start()
        hilos.append(hilo)
    print(f"fm-tablero: escuchando en {', '.join(f'{h}:{puerto}' for h in hosts)} (home {home})", flush=True)
    try:
        while not parar.is_set():
            time.sleep(0.3)
    finally:
        for servidor in servidores:
            servidor.shutdown()
            servidor.server_close()
    return 0


# ---------------------------------------------------------------------- CLI


def _resolver_home(valor: str | None) -> Path:
    if valor:
        return Path(valor).resolve()
    del_entorno = os.environ.get("FM_HOME")
    if del_entorno:
        return Path(del_entorno).resolve()
    return Path(__file__).resolve().parent.parent


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="fm-tablero.py", add_help=True,
        description="Servidor local del tablero del trabajo.",
    )

    def con_home(sub_parser):
        sub_parser.add_argument("--home", default=None, help="home operativo (por omisión FM_HOME)")
        return sub_parser

    sub = parser.add_subparsers(dest="orden")

    p_servir = con_home(sub.add_parser("serve", help="servir la página y su API"))
    p_servir.add_argument("--host", action="append", default=[])
    p_servir.add_argument("--port", type=int, default=8787)

    p_responder = con_home(sub.add_parser(
        "reply", help="escribir una respuesta de firstmate en la conversación"))
    p_responder.add_argument("--reply-to", default="", help="id del mensaje del capitán al que contesta")
    p_responder.add_argument("texto", nargs="*")

    con_home(sub.add_parser("pairs", help="imprimir la conversación ya emparejada"))

    args = parser.parse_args(argv)
    home = _resolver_home(getattr(args, "home", None))

    if args.orden == "serve":
        hosts = args.host or ["127.0.0.1"]
        return servir(home, hosts, args.port)

    if args.orden == "reply":
        texto = " ".join(args.texto) if args.texto else sys.stdin.read()
        if not texto.strip():
            print("fm-tablero: hace falta el texto de la respuesta.", file=sys.stderr)
            return 2
        registro = anadir_mensaje(home, "firstmate", texto.strip(),
                                  responde_a=args.reply_to)
        print(f"guardado {registro['id']}" + (f" como respuesta a {args.reply_to}" if args.reply_to else ""))
        return 0

    if args.orden == "pairs":
        print(json.dumps(emparejar(leer_conversacion(home)), ensure_ascii=False, indent=2))
        return 0

    parser.print_help()
    return 0


if __name__ == "__main__":
    sys.exit(main())
