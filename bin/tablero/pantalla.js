"use strict";
/* Tablero del trabajo - capa de pantalla.
 *
 * Todo lo que se ve sale de GET /api/estado, que lee el estado real del home.
 * La pantalla no inventa columnas ni estados: pinta lo que el servidor calcula.
 * Lo único que guarda el navegador es lo tuyo y de esta sesión: qué vista
 * prefieres, qué columnas tienes plegadas y los borradores que aún no has
 * enviado, para que un refresco no se lleve por delante lo que estás escribiendo.
 */

const MS = 4000;              // cada cuánto se vuelve a preguntar al servidor
const BORRADORES = "tablero-supervision-borradores";
const PREFERENCIAS = "tablero-supervision-vista";

const ICONO = {
  reloj: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.6" aria-hidden="true"><circle cx="8" cy="8" r="6.2"/><path d="M8 4.4V8l2.5 1.6"/></svg>',
  visto: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M3 8.4l3.2 3.2L13 4.8"/></svg>',
  flecha: '<svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M3.5 10h11M10.5 5.5L15 10l-4.5 4.5"/></svg>',
  chevron: '<svg class="chev" viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M6 8l4 4 4-4"/></svg>',
  mover: '<svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M4 7h9M10.5 4.5L13 7l-2.5 2.5M16 13H7M9.5 10.5L7 13l2.5 2.5"/></svg>',
  papelera: '<svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M4.5 6.5h11M8 6.5V4.8h4v1.7M6.5 6.5l.7 8.2h5.6l.7-8.2"/></svg>'
};

const TIPOS = {
  bloquea: { label: "Bloquea trabajo", cls: "k-bloquea" },
  confirma: { label: "Espera tu decisión", cls: "k-confirma" },
  sinprisa: { label: "Sin prisa", cls: "k-sinprisa" },
  subir: { label: "Listo para subir", cls: "k-subir" },
  ahora: { label: "En marcha", cls: "k-ahora" },
  plan: { label: "Sin empezar", cls: "k-plan" },
  hecho: { label: "Publicado", cls: "k-hecho" }
};

const main = document.getElementById("main");
const menu = document.getElementById("menu");
const dlg = document.getElementById("dlg");
const toastEl = document.getElementById("toast");
const toastT = document.getElementById("toastT");
const chatLog = document.getElementById("chatLog");
const chatInput = document.getElementById("chatInput");
const chatSend = document.getElementById("chatSend");
const subEl = document.getElementById("sub");
const avisoEl = document.getElementById("aviso");

let estado = null;              // último /api/estado
let huellaEstado = "";          // para no repintar si nada cambió
let conversacion = [];
let huellaChat = "";
let vista = "etapas";
let abiertas = new Set();
let plegadas = new Set();
let borradores = {};
let menuDe = null;
let menuEtapa = null;
let arrastrando = null;
let tareaQuitar = null;
let temporizadorToast = 0;

/* ------------------------------------------------------------ preferencias */

function leerPreferencias() {
  let guardado = {};
  try { guardado = JSON.parse(localStorage.getItem(PREFERENCIAS)) || {}; } catch (e) { guardado = {}; }
  return guardado;
}

function guardarPreferencias() {
  try {
    localStorage.setItem(PREFERENCIAS, JSON.stringify({ vista, plegadas: [...plegadas], abiertas: [...abiertas], pestana: pestanaActual() }));
  } catch (e) { /* sin memoria del navegador: sigue funcionando */ }
}

function leerBorradores() {
  try { borradores = JSON.parse(localStorage.getItem(BORRADORES)) || {}; } catch (e) { borradores = {}; }
}

function guardarBorradores() {
  try { localStorage.setItem(BORRADORES, JSON.stringify(borradores)); } catch (e) { /* nada */ }
}

/* ------------------------------------------------------------------ utilería */

function el(tag, cls, texto) {
  const n = document.createElement(tag);
  if (cls) n.className = cls;
  if (texto !== undefined && texto !== null) n.textContent = texto;
  return n;
}

function hora(iso) {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "";
  return d.toLocaleTimeString("es-ES", { hour: "2-digit", minute: "2-digit" });
}

function dia(iso) {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "";
  return d.toLocaleDateString("es-ES", { day: "numeric", month: "long" });
}

async function pedir(ruta, opciones) {
  const r = await fetch(ruta, opciones);
  let datos = null;
  try { datos = await r.json(); } catch (e) { datos = null; }
  if (!r.ok) throw new Error((datos && datos.error) || ("El servidor contestó " + r.status));
  return datos;
}

function aviso(texto) {
  if (!texto) { avisoEl.hidden = true; avisoEl.textContent = ""; return; }
  avisoEl.hidden = false;
  avisoEl.textContent = texto;
}

function toast(texto) {
  toastT.textContent = texto;
  toastEl.classList.add("show");
  clearTimeout(temporizadorToast);
  temporizadorToast = setTimeout(() => toastEl.classList.remove("show"), 5200);
}

/* ------------------------------------------------------------------ pestañas */

function pestanaActual() {
  return document.body.dataset.vista === "chat" ? "chat" : "tablero";
}

function ponerPestana(nombre) {
  const chat = nombre === "chat";
  const entrando = chat && pestanaActual() !== "chat";
  document.body.dataset.vista = chat ? "chat" : "tablero";
  document.getElementById("tabTablero").setAttribute("aria-selected", chat ? "false" : "true");
  document.getElementById("tabChat").setAttribute("aria-selected", chat ? "true" : "false");
  document.getElementById("panelTablero").hidden = chat;
  document.getElementById("panelChat").hidden = !chat;
  document.title = chat ? "Conversación - Tablero del trabajo" : "Tablero del trabajo";
  guardarPreferencias();
  // Solo al entrar en la pestaña se empieza por el mensaje más reciente; a
  // partir de ahí la posición la decide quien lee, no los refrescos.
  if (entrando) {
    chatLog.scrollTop = chatLog.scrollHeight;
    // En el móvil, enfocar el cuadro de texto abriría el teclado y taparía la conversación.
    if (window.matchMedia("(pointer: fine)").matches) chatInput.focus({ preventScroll: true });
  }
}

/* ------------------------------------------------------------------ kanban */

function pintar(datos) {
  const columnas = datos.columnas || [];
  const modoLista = vista === "lista";

  if (modoLista) {
    main.replaceChildren(pintarLista(columnas));
  } else {
    const board = el("div", "board");
    // Una columna plegada se queda en franja, como en el diseño aprobado.
    board.style.gridTemplateColumns = columnas
      .map((col) => (col.plegada && plegadas.has(col.id) ? "52px" : "minmax(0, 1fr)"))
      .join(" ");
    columnas.forEach((col) => board.appendChild(pintarColumna(col)));
    main.replaceChildren(board);
  }

  document.getElementById("waitN").textContent = String(datos.cuenta.preguntan || 0);
  document.getElementById("waitT").textContent =
    (datos.cuenta.preguntan || 0) === 1 ? "espera tu respuesta" : "esperan tu respuesta";

  const pill = document.getElementById("blockPill");
  if (datos.cuenta.bloquean > 0) {
    document.getElementById("blockT").textContent =
      datos.cuenta.bloquean === 1 ? "1 cosa de trabajo parada esperándote" : datos.cuenta.bloquean + " cosas de trabajo paradas esperándote";
    pill.hidden = false;
  } else {
    pill.hidden = true;
  }

  subEl.textContent = datos.generado_texto ? "Actualizado el " + datos.generado_texto + "." : "";
  aviso(datos.aviso);
}

function pintarColumna(col) {
  const colEl = el("section", "col");
  if (col.plegada) colEl.classList.add("quiet");
  if (plegadas.has(col.id)) colEl.classList.add("folded");

  const cab = el("div", "col-head");
  const titulo = el("div", "col-title");
  const punto = el("span", "sec-dot");
  punto.style.background = col.color;
  titulo.appendChild(punto);
  titulo.appendChild(el("span", "col-name", col.nombre));
  titulo.appendChild(el("span", "sec-n", String(col.tarjetas.length)));

  const boton = el("button", "fold");
  boton.type = "button";
  boton.title = plegadas.has(col.id) ? "Desplegar " + col.nombre : "Plegar " + col.nombre;
  boton.setAttribute("aria-expanded", plegadas.has(col.id) ? "false" : "true");
  boton.innerHTML = ICONO.chevron;
  boton.addEventListener("click", () => {
    if (plegadas.has(col.id)) plegadas.delete(col.id); else plegadas.add(col.id);
    guardarPreferencias();
    if (estado) pintar(estado);
  });
  titulo.appendChild(boton);
  cab.appendChild(titulo);
  cab.appendChild(el("p", "col-why", col.motivo));
  colEl.appendChild(cab);

  const cuerpo = el("div", "col-body");
  if (col.tarjetas.length === 0) {
    cuerpo.appendChild(el("p", "empty", "Nada por aquí."));
  } else {
    col.tarjetas.forEach((t) => cuerpo.appendChild(pintarTarjeta(t)));
  }
  const pista = el("div", "drop-hint", "Pedir que se mueva aquí");
  cuerpo.appendChild(pista);
  colEl.appendChild(cuerpo);

  colEl.addEventListener("dragover", (ev) => {
    if (!arrastrando || arrastrando === col.id) return;
    ev.preventDefault();
    colEl.classList.add("over");
  });
  colEl.addEventListener("dragleave", () => colEl.classList.remove("over"));
  colEl.addEventListener("drop", (ev) => {
    ev.preventDefault();
    colEl.classList.remove("over");
    if (arrastrando && arrastrando !== col.id) pedirMover(arrastrando, col);
  });
  return colEl;
}

// Lo que escribiste en esta tarjeta: si firstmate ya contestó en la conversación
// o sigue sin contestar. Es distinto de "Espera tu respuesta", que es al revés:
// ahí quien tiene que contestar eres tú.
function chipPregunta(p) {
  const espera = p.estado === "espera";
  const chip = el("span", "pregunta " + (espera ? "p-espera" : "p-contestada"));
  chip.innerHTML = (espera ? ICONO.reloj : ICONO.visto) +
    (espera ? "Espera respuesta de firstmate" : "Firstmate ya te contestó");
  chip.title = espera
    ? "Lo que escribiste en esta tarjeta sigue sin contestar en la conversación del tablero."
    : "Firstmate contestó en la conversación del tablero a lo que escribiste en esta tarjeta.";
  return chip;
}

function pintarTarjeta(t) {
  const tipo = TIPOS[t.tipo] || TIPOS.plan;
  const abierta = abiertas.has(t.id);

  const card = el("article", "card");
  card.dataset.id = t.id;
  card.style.setProperty("--accent", t.color || "#9aa0aa");
  if (abierta) card.classList.add("open");
  card.draggable = true;
  card.addEventListener("dragstart", (ev) => {
    arrastrando = t.id;
    card.classList.add("dragging");
    document.body.classList.add("dragging-on");
    if (ev.dataTransfer) ev.dataTransfer.setData("text/plain", t.id);
  });
  card.addEventListener("dragend", () => {
    arrastrando = null;
    card.classList.remove("dragging");
    document.body.classList.remove("dragging-on");
    document.querySelectorAll(".col.over").forEach((c) => c.classList.remove("over"));
  });

  const arriba = el("button", "card-top");
  arriba.type = "button";
  arriba.setAttribute("aria-expanded", abierta ? "true" : "false");

  const meta = el("div", "meta");
  const etiqueta = el("span", "kind " + tipo.cls);
  etiqueta.textContent = tipo.label;
  meta.appendChild(etiqueta);
  if (t.area) meta.appendChild(el("span", "area", t.area));
  if (t.pregunta && t.pregunta.estado) meta.appendChild(chipPregunta(t.pregunta));
  arriba.appendChild(meta);
  arriba.appendChild(el("h3", null, t.titulo));
  if (t.necesita) {
    const p = el("p", "need");
    p.textContent = t.necesita;
    arriba.appendChild(p);
  }
  if (t.bloquea) {
    const p = el("p", "blocks");
    p.textContent = t.bloquea;
    arriba.appendChild(p);
  }
  const quien = [];
  if (t.quien) quien.push(t.quien);
  if (t.desde) quien.push(t.desde);
  if (quien.length) {
    const caja = el("div", "who");
    quien.forEach((q) => caja.appendChild(el("span", "chip", q)));
    arriba.appendChild(caja);
  }
  arriba.addEventListener("click", () => {
    if (abiertas.has(t.id)) abiertas.delete(t.id); else abiertas.add(t.id);
    guardarPreferencias();
    card.classList.toggle("open");
    arriba.setAttribute("aria-expanded", card.classList.contains("open") ? "true" : "false");
  });
  card.appendChild(arriba);

  const mas = el("div", "more");
  const dentro = el("div");
  const cuerpo = el("div", "more-in");
  cuerpo.appendChild(relleno(t, card));
  dentro.appendChild(cuerpo);
  mas.appendChild(dentro);
  card.appendChild(mas);
  return card;
}

function relleno(t, card) {
  const caja = el("div");
  if (t.detalle) caja.appendChild(el("p", "what", t.detalle));
  if (t.puntos && t.puntos.length) {
    const ul = el("ul", "opts");
    t.puntos.forEach((o) => ul.appendChild(el("li", null, o)));
    caja.appendChild(ul);
  }

  if (t.puede_responder) {
    const area = el("textarea");
    area.rows = 3;
    area.placeholder = "Escribe aquí tu respuesta…";
    area.value = borradores[t.id] || "";
    area.addEventListener("input", () => {
      borradores[t.id] = area.value;
      guardarBorradores();
    });
    caja.appendChild(area);

    const acciones = el("div", "actions");
    const enviar = el("button", "btn btn-primary");
    enviar.type = "button";
    enviar.innerHTML = "Enviar" + ICONO.flecha;
    enviar.disabled = !area.value.trim();
    area.addEventListener("input", () => { enviar.disabled = !area.value.trim(); });
    enviar.addEventListener("click", () => responder(t, area.value, enviar));
    area.addEventListener("keydown", (ev) => {
      if (ev.key === "Enter" && (ev.metaKey || ev.ctrlKey)) {
        ev.preventDefault();
        if (!enviar.disabled) enviar.click();
      }
    });
    acciones.appendChild(enviar);
    acciones.appendChild(el("span", "push"));
    acciones.appendChild(botonMover(t));
    acciones.appendChild(botonQuitar(t));
    caja.appendChild(acciones);

    const pista = el("p", "accion-nota", t.respuesta_accion || "");
    caja.appendChild(pista);
  } else {
    const acciones = el("div", "actions");
    acciones.appendChild(botonMover(t));
    acciones.appendChild(botonQuitar(t));
    caja.appendChild(acciones);
  }
  return caja;
}

function botonMover(t) {
  const b = el("button", "btn btn-ghost");
  b.type = "button";
  b.innerHTML = ICONO.mover + "Mover";
  b.addEventListener("click", (ev) => {
    ev.stopPropagation();
    abrirMenu(t, ev.currentTarget);
  });
  return b;
}

function botonQuitar(t) {
  const b = el("button", "btn btn-danger");
  b.type = "button";
  b.innerHTML = ICONO.papelera + "Quitar";
  b.addEventListener("click", (ev) => {
    ev.stopPropagation();
    tareaQuitar = t;
    document.getElementById("dlgCard").textContent = t.titulo;
    dlg.showModal();
  });
  return b;
}

/* --------------------------------------------------------------- vista lista */

function pintarLista(columnas) {
  const caja = el("div", "list");
  columnas.forEach((col) => {
    const cab = el("div", "list-group");
    const punto = el("span", "sec-dot");
    punto.style.background = col.color;
    cab.appendChild(punto);
    cab.appendChild(el("span", null, col.nombre));
    cab.appendChild(el("span", "sec-n", String(col.tarjetas.length)));
    cab.appendChild(el("span", "grp-why", col.motivo));
    caja.appendChild(cab);
    if (col.tarjetas.length === 0) {
      const vacio = el("div", "row");
      vacio.appendChild(el("p", "empty", "Nada por aquí."));
      caja.appendChild(vacio);
      return;
    }
    col.tarjetas.forEach((t) => caja.appendChild(pintarFila(t)));
  });
  return caja;
}

function pintarFila(t) {
  const tipo = TIPOS[t.tipo] || TIPOS.plan;
  const fila = el("div", "row");
  fila.dataset.id = t.id;
  fila.style.setProperty("--accent", t.color || "#9aa0aa");
  if (abiertas.has(t.id)) fila.classList.add("open");

  const arriba = el("button", "row-top");
  arriba.type = "button";
  const etiqueta = el("span", "kind " + tipo.cls);
  etiqueta.textContent = tipo.label;
  arriba.appendChild(etiqueta);

  const titulo = el("div", "row-title");
  if (t.area) titulo.appendChild(el("span", "area", t.area));
  titulo.appendChild(document.createTextNode(t.titulo));
  arriba.appendChild(titulo);

  const necesidad = el("div", "row-need");
  necesidad.appendChild(document.createTextNode(t.necesita || ""));
  if (t.pregunta && t.pregunta.estado) necesidad.appendChild(chipPregunta(t.pregunta));
  if (t.bloquea) necesidad.appendChild(el("span", "blk", t.bloquea));
  if (t.quien || t.desde) {
    necesidad.appendChild(el("span", "blk who-line", [t.quien, t.desde].filter(Boolean).join(" · ")));
  }
  arriba.appendChild(necesidad);

  const chev = el("span");
  chev.innerHTML = ICONO.chevron;
  arriba.appendChild(chev.firstChild);

  arriba.addEventListener("click", () => {
    if (abiertas.has(t.id)) abiertas.delete(t.id); else abiertas.add(t.id);
    guardarPreferencias();
    fila.classList.toggle("open");
  });
  fila.appendChild(arriba);

  const mas = el("div", "more");
  const dentro = el("div");
  const cuerpo = el("div", "more-in");
  cuerpo.appendChild(relleno(t, fila));
  dentro.appendChild(cuerpo);
  mas.appendChild(dentro);
  fila.appendChild(mas);
  return fila;
}

/* ------------------------------------------------------------------- menú mover */

function abrirMenu(t, ancla) {
  menuDe = t;
  menu.replaceChildren();
  menu.appendChild(el("div", "menu-title", "Pedir que se mueva a…"));
  (estado ? estado.columnas : []).forEach((col) => {
    const b = el("button");
    b.type = "button";
    b.appendChild(el("span", "sec-dot")).style.background = col.color;
    b.appendChild(el("span", null, col.nombre));
    if (col.id === t.etapa) { b.disabled = true; b.appendChild(el("span", "menu-ya", "ya está aquí")); }
    b.addEventListener("click", () => { cerrarMenu(); pedirMover(t.id, col); });
    menu.appendChild(b);
  });
  menu.classList.add("show");
  const r = ancla.getBoundingClientRect();
  const ancho = 280;
  let izq = Math.min(r.left, window.innerWidth - ancho - 12);
  menu.style.left = Math.max(12, izq) + "px";
  const alto = menu.offsetHeight;
  let arriba = r.bottom + 6;
  if (arriba + alto > window.innerHeight - 12) arriba = Math.max(12, r.top - alto - 6);
  menu.style.top = arriba + "px";
}

function cerrarMenu() {
  menu.classList.remove("show");
  menuDe = null;
  menuEtapa = null;
}

/* ------------------------------------------------------------- camino de vuelta */

async function responder(t, texto, boton) {
  const limpio = texto.trim();
  if (!limpio) return;
  // Cerrar una decisión pasa por el mecanismo de la casa y puede tardar unos
  // segundos: el botón lo dice para que no parezca que no ha pasado nada.
  const rotulo = boton.innerHTML;
  boton.disabled = true;
  boton.textContent = "Enviando…";
  try {
    const r = await pedir("/api/responder", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ tarea: t.id, texto: limpio, titulo: t.titulo })
    });
    delete borradores[t.id];
    guardarBorradores();
    toast(r.aviso || "Respuesta enviada: la decisión queda cerrada.");
    await cargar(true);
    await cargarConversacion(true);
  } catch (e) {
    boton.disabled = false;
    boton.innerHTML = rotulo;
    toast("No se pudo enviar: " + e.message);
  }
}

async function pedirMover(id, col) {
  const t = tarjetaPorId(id);
  if (!t) return;
  try {
    const r = await pedir("/api/peticion", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ tarea: id, accion: "mover", destino: col.id, titulo: t.titulo, columna: col.nombre })
    });
    toast(r.aviso || ("Pedido a firstmate: mover a «" + col.nombre + "». Él lo hará."));
    await cargarConversacion(true);
  } catch (e) {
    toast("No se pudo pedir: " + e.message);
  }
}

async function pedirQuitar(t) {
  try {
    const r = await pedir("/api/peticion", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ tarea: t.id, accion: "quitar", titulo: t.titulo })
    });
    toast(r.aviso || "Pedido a firstmate: que la quite. Te lo confirmará antes de borrar nada.");
    await cargarConversacion(true);
  } catch (e) {
    toast("No se pudo pedir: " + e.message);
  }
}

function tarjetaPorId(id) {
  if (!estado) return null;
  for (const col of estado.columnas) {
    for (const t of col.tarjetas) if (t.id === id) return t;
  }
  return null;
}

/* --------------------------------------------------------------- conversación */

async function cargarConversacion(urgente) {
  let datos;
  try {
    datos = await pedir("/api/conversacion");
  } catch (e) {
    return;
  }
  const huella = JSON.stringify(datos.mensajes);
  if (!urgente && huella === huellaChat) return;
  huellaChat = huella;
  conversacion = datos.mensajes || [];
  pintarConversacion();
}

function pintarConversacion() {
  // Repintar vacía la lista un instante: se guarda dónde estaba quien lee para
  // devolverle exactamente ahí, salvo que ya estuviera al final siguiendo lo nuevo.
  const pegadoAbajo = chatLog.scrollHeight - chatLog.scrollTop - chatLog.clientHeight < 90;
  const posicion = chatLog.scrollTop;
  chatLog.replaceChildren();
  if (conversacion.length === 0) {
    const vacio = el("p", "empty", "Todavía no hay nada hablado. Escribe abajo y firstmate lo recibe.");
    chatLog.appendChild(vacio);
  }
  let ultimoDia = "";
  conversacion.forEach((m) => {
    const d = dia(m.ts);
    if (d && d !== ultimoDia) {
      ultimoDia = d;
      chatLog.appendChild(el("div", "day", d));
    }
    chatLog.appendChild(burbuja(m));
  });

  const esperando = conversacion.filter((m) => m.de === "capitan" && !m.respuestas.length).length;
  const globo = document.getElementById("chatHeadPend");
  globo.textContent = esperando === 1 ? "1 esperando respuesta" : esperando + " esperando respuesta";
  globo.hidden = esperando === 0;
  const pestana = document.getElementById("chatPend");
  pestana.textContent = String(esperando);
  pestana.hidden = esperando === 0;

  const pie = document.getElementById("composerHint");
  pie.textContent = esperando > 0
    ? "Firstmate tiene " + esperando + " mensaje" + (esperando > 1 ? "s" : "") + " tuyo" + (esperando > 1 ? "s" : "") + " por contestar. Intro envía."
    : "Intro envía. Mayúsculas e Intro, otra línea.";

  chatLog.scrollTop = pegadoAbajo ? chatLog.scrollHeight : posicion;
}

function burbuja(m) {
  const deMi = m.de === "capitan";
  const caja = el("div", "msg " + (deMi ? "me" : "fm"));
  caja.dataset.id = m.id;

  if (!deMi) {
    const quien = el("div", "who-fm");
    quien.appendChild(el("span", "av", "fm"));
    quien.appendChild(el("span", null, "firstmate"));
    quien.appendChild(el("time", null, hora(m.ts)));
    caja.appendChild(quien);
  }

  const texto = el("div", "bubble");
  if (m.responde_a) {
    const cita = el("button", "quote");
    cita.type = "button";
    const original = conversacion.find((x) => x.id === m.responde_a);
    cita.textContent = original
      ? "Tu mensaje de las " + hora(original.ts) + ": " + recorte(original.texto)
      : "Tu mensaje anterior";
    cita.addEventListener("click", () => destacar(m.responde_a));
    texto.appendChild(cita);
  }
  texto.appendChild(document.createTextNode(m.texto));
  caja.appendChild(texto);

  const meta = el("div", "msg-meta");
  if (deMi && m.tipo !== "mensaje") meta.appendChild(el("span", "state tipo", tipoDeMensaje(m)));
  meta.appendChild(el("span", null, hora(m.ts)));
  if (deMi) {
    const respuestas = m.respuestas || [];
    const estadoMsg = el(respuestas.length ? "button" : "span", "state " + (respuestas.length ? "ok" : "wait"));
    if (respuestas.length) {
      // `respuestas` lleva identificadores, no fechas: la hora sale del mensaje
      // que contestó, y si ya no está en la conversación cargada, no se inventa.
      const ultima = conversacion.find((x) => x.id === respuestas[respuestas.length - 1]);
      estadoMsg.type = "button";
      estadoMsg.innerHTML = ICONO.visto + "Respondido" + (ultima ? " a las " + hora(ultima.ts) : "");
      estadoMsg.addEventListener("click", () => destacar(respuestas[respuestas.length - 1]));
    } else {
      estadoMsg.innerHTML = ICONO.reloj + "Esperando respuesta";
    }
    meta.appendChild(estadoMsg);
  } else {
    meta.appendChild(el("span", "state", tipoDeMensaje(m)));
  }
  caja.appendChild(meta);
  return caja;
}

function tipoDeMensaje(m) {
  if (m.tipo === "decision") return "Escrito en la tarjeta de «" + (m.titulo_tarea || "una tarea") + "»";
  if (m.tipo === "peticion") return "Encargo recibido";
  return "";
}

function recorte(texto) {
  const t = (texto || "").replace(/\s+/g, " ").trim();
  return t.length > 70 ? t.slice(0, 70) + "…" : t;
}

function destacar(id) {
  const nodo = chatLog.querySelector('[data-id="' + id + '"]');
  if (!nodo) return;
  nodo.classList.add("flash");
  nodo.scrollIntoView({ block: "center", behavior: "smooth" });
  setTimeout(() => nodo.classList.remove("flash"), 1400);
}

async function enviarMensaje() {
  const texto = chatInput.value.trim();
  if (!texto) return;
  chatSend.disabled = true;
  try {
    const r = await pedir("/api/mensaje", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ texto })
    });
    chatInput.value = "";
    ajustarAlto();
    toast(r.aviso || "Enviado a firstmate. Te contesta aquí cuando le toque el turno.");
    await cargarConversacion(true);
    chatLog.scrollTop = chatLog.scrollHeight;
  } catch (e) {
    toast("No se pudo enviar: " + e.message);
  }
  chatSend.disabled = !chatInput.value.trim();
}

function ajustarAlto() {
  chatInput.style.height = "auto";
  chatInput.style.height = Math.min(144, chatInput.scrollHeight) + "px";
  chatSend.disabled = !chatInput.value.trim();
}

/* -------------------------------------------------------------------- carga */

async function cargar(urgente) {
  let datos;
  try {
    datos = await pedir("/api/estado");
  } catch (e) {
    aviso("No se pudo leer el estado: " + e.message);
    return;
  }
  const huella = JSON.stringify({ c: datos.columnas, n: datos.cuenta, g: datos.generado_texto, a: datos.aviso, u: datos.ausencia });
  if (!urgente && huella === huellaEstado) return;
  huellaEstado = huella;
  estado = datos;
  tono(datos);
  pintar(datos);
}

function tono(datos) {
  if (!datos.ausencia) return;
  /* El modo ausencia no cambia lo que se puede hacer aquí: el tablero sigue
     recibiendo. Solo se avisa, para que el capitán sepa qué esperar. */
  const texto = datos.ausencia.texto || "Estás en modo ausencia.";
  aviso(texto);
}

function conectar() {
  const guardado = leerPreferencias();
  vista = guardado.vista === "lista" ? "lista" : "etapas";
  plegadas = new Set(Array.isArray(guardado.plegadas) ? guardado.plegadas : ["hecho"]);
  abiertas = new Set(Array.isArray(guardado.abiertas) ? guardado.abiertas : []);
  leerBorradores();

  document.querySelectorAll(".switch button").forEach((b) => {
    b.setAttribute("aria-pressed", b.dataset.view === vista ? "true" : "false");
    b.addEventListener("click", () => {
      vista = b.dataset.view;
      guardarPreferencias();
      document.querySelectorAll(".switch button").forEach((o) =>
        o.setAttribute("aria-pressed", o.dataset.view === vista ? "true" : "false"));
      if (estado) pintar(estado);
    });
  });

  document.querySelectorAll(".tab").forEach((b) => {
    b.addEventListener("click", () => ponerPestana(b.dataset.vista));
  });

  document.addEventListener("keydown", (ev) => {
    if (ev.key === "Escape") {
      if (menu.classList.contains("show")) { cerrarMenu(); return; }
      if (document.body.dataset.vista === "chat") ponerPestana("tablero");
    }
  });
  document.addEventListener("click", (ev) => {
    if (menu.classList.contains("show") && !menu.contains(ev.target)) cerrarMenu();
  });
  window.addEventListener("resize", cerrarMenu);
  window.addEventListener("scroll", cerrarMenu, true);

  dlg.addEventListener("close", () => {
    if (dlg.returnValue === "yes" && tareaQuitar) pedirQuitar(tareaQuitar);
    tareaQuitar = null;
  });

  document.getElementById("composer").addEventListener("submit", (ev) => {
    ev.preventDefault();
    enviarMensaje();
  });
  chatInput.addEventListener("input", ajustarAlto);
  chatInput.addEventListener("keydown", (ev) => {
    if (ev.key === "Enter" && !ev.shiftKey) {
      ev.preventDefault();
      enviarMensaje();
    }
  });

  if (guardado.pestana === "chat") ponerPestana("chat");

  cargar(true).then(() => pintarConversacion());
  cargarConversacion(true);
  setInterval(() => { cargar(false); }, MS);
  setInterval(() => { cargarConversacion(false); }, MS);
}

conectar();
