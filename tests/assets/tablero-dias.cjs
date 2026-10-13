// tests/assets/tablero-dias.cjs - the day selector of the work board, in a real browser.
//
// tests/fm-tablero-pantalla.test.sh is the only supported caller: it seeds a home
// with cards on two days and passes its URL in. What each check expects comes
// from the board's own /api/estado, never from a fixture, so the same script
// also reads a real home.
//
// Environment:
//   TABLERO_BASE      base URL of the running board (required)
//   TABLERO_CAPTURAS  directory for screenshots; empty means take none
//
// Exit status: 0 when every check passed, 1 with a report on stderr otherwise.

"use strict";

const { mkdirSync } = require("node:fs");
const { chromium } = require("playwright");
const { lanzarNavegador } = require("./tablero-navegador.cjs");

const BASE = process.env.TABLERO_BASE;
const CAPTURAS = process.env.TABLERO_CAPTURAS || "";
if (!BASE) {
  console.error("TABLERO_BASE is required");
  process.exit(1);
}
if (CAPTURAS) mkdirSync(CAPTURAS, { recursive: true });

const fallos = [];
const pasos = [];
function comprobar(descripcion, condicion, detalle) {
  if (condicion) pasos.push(descripcion);
  else fallos.push(descripcion + (detalle !== undefined ? " -> " + JSON.stringify(detalle) : ""));
}

async function estado(consulta = "") {
  return (await fetch(BASE + "/api/estado" + consulta)).json();
}

function tarjetas(datos) {
  return datos.columnas.reduce((n, c) => n + c.tarjetas.length, 0);
}

// Espera a que `leer()` dé `valor` (los refrescos y las respuestas tardan un poco) y
// devuelve la última lectura, sea cual sea, para que la comprobación la cuente tal cual.
async function hasta(valor, leer, limite = 15000) {
  const fin = Date.now() + limite;
  let lectura = await leer();
  while (lectura !== valor && Date.now() < fin) {
    await new Promise((r) => setTimeout(r, 200));
    lectura = await leer();
  }
  return lectura;
}

async function main() {
  const porDefecto = await estado();
  const todo = await estado("?dia=todo");
  const dias = todo.dias;
  if (dias.length < 2) {
    console.error("not ok - hacen falta tarjetas en dos días para probar el selector (hay " + dias.length + ")");
    process.exitCode = 1;
    return;
  }
  const defecto = porDefecto.dia_defecto;
  const otro = dias.find((d) => d.id !== defecto);
  const datosOtro = await estado("?dia=" + otro.id);
  const pendientesFuera = porDefecto.fuera.esperan;

  const navegador = await lanzarNavegador(chromium);
  const consola = [];
  const peticionesExternas = [];
  const pagina = await (await navegador.newContext({ viewport: { width: 1280, height: 960 } })).newPage();
  pagina.on("console", (m) => {
    if (m.type() === "error" || m.type() === "warning") consola.push(m.type() + ": " + m.text());
  });
  pagina.on("pageerror", (e) => consola.push("pageerror: " + e.message));
  pagina.on("request", (p) => {
    if (!p.url().startsWith(BASE)) peticionesExternas.push(p.url());
  });
  const captura = async (nombre, completa = true, quien = pagina) => {
    if (!CAPTURAS) return;
    await quien.screenshot({ path: CAPTURAS + "/" + nombre + ".png", fullPage: completa });
  };
  const tarjetasEnPantalla = () => pagina.$$eval(".card", (n) => n.length);
  const esperanEnPantalla = () => pagina.textContent("#waitN").then((t) => Number(t.trim()));

  // ------------------------------------------------ por defecto, sin tocar nada

  await pagina.goto(BASE, { waitUntil: "networkidle" });
  await pagina.waitForSelector(".board .col", { timeout: 15000 });
  const valorInicial = await pagina.inputValue("#diaSelect");
  comprobar("sin tocar nada, el selector enseña el día más reciente", valorInicial === porDefecto.dia_activo, valorInicial);
  comprobar(
    "por defecto se ven sólo las tarjetas de ese día",
    (await hasta(tarjetas(porDefecto), tarjetasEnPantalla)) === tarjetas(porDefecto),
    await tarjetasEnPantalla()
  );
  comprobar(
    "el contador de esperan tu respuesta cuenta lo que se ve",
    (await hasta(porDefecto.cuenta.preguntan, esperanEnPantalla)) === porDefecto.cuenta.preguntan,
    await esperanEnPantalla()
  );

  const opciones = await pagina.$$eval("#diaSelect option", (n) => n.map((o) => o.value));
  const esperadas = ["todo", ...dias.map((d) => d.id)];
  if (todo.sin_fecha.tarjetas > 0) esperadas.push("sin-fecha");
  comprobar(
    "el selector ofrece Todo, cada día con tarjetas y Sin fecha si hay alguna",
    esperadas.every((v) => opciones.includes(v)) && opciones.length === esperadas.length,
    opciones
  );

  const avisoVisible = await pagina.isVisible("#diaFuera");
  const avisoTexto = avisoVisible ? (await pagina.textContent("#diaFuera")).trim() : "";
  comprobar(
    "las tarjetas que esperan tu respuesta en otros días se avisan junto al selector",
    pendientesFuera > 0
      ? avisoVisible && avisoTexto.includes(String(pendientesFuera))
      : !avisoVisible,
    avisoTexto
  );
  await captura("dias-defecto");

  // ------------------------------------------- el aviso lleva a lo que queda fuera

  if (pendientesFuera > 0) {
    await pagina.click("#diaFuera");
    const leerDia = () => pagina.inputValue("#diaSelect");
    comprobar("pulsar el aviso pasa el selector a Todo", (await hasta("todo", leerDia)) === "todo", await leerDia());
    comprobar(
      "tras pulsar el aviso se ven todas las tarjetas que esperan tu respuesta",
      (await hasta(todo.cuenta.preguntan, esperanEnPantalla)) === todo.cuenta.preguntan,
      await esperanEnPantalla()
    );
    comprobar(
      "tras pulsar el aviso están en pantalla las tarjetas de todos los días",
      (await hasta(tarjetas(todo), tarjetasEnPantalla)) === tarjetas(todo),
      await tarjetasEnPantalla()
    );
    comprobar(
      "tras pulsar el aviso ya no queda ninguna pregunta fuera",
      (await hasta(false, () => pagina.isVisible("#diaFuera"))) === false,
      await pagina.textContent("#diaFuera")
    );
    await pagina.selectOption("#diaSelect", defecto);
    await hasta(tarjetas(porDefecto), tarjetasEnPantalla);
  }

  // ----------------------------------------------------------- elegir un día

  await pagina.selectOption("#diaSelect", "todo");
  comprobar(
    "elegir Todo enseña todas las tarjetas",
    (await hasta(tarjetas(todo), tarjetasEnPantalla)) === tarjetas(todo),
    await tarjetasEnPantalla()
  );
  comprobar(
    "con Todo no queda ninguna pregunta fuera de lo que se ve",
    !(await pagina.isVisible("#diaFuera")),
    await pagina.textContent("#diaFuera")
  );

  await pagina.selectOption("#diaSelect", otro.id);
  comprobar(
    "elegir otro día enseña sólo sus tarjetas",
    (await hasta(tarjetas(datosOtro), tarjetasEnPantalla)) === tarjetas(datosOtro),
    await tarjetasEnPantalla()
  );
  comprobar(
    "los contadores siguen al día elegido",
    (await hasta(datosOtro.cuenta.preguntan, esperanEnPantalla)) === datosOtro.cuenta.preguntan,
    await esperanEnPantalla()
  );
  await captura("dias-elegido");

  // ----------------------------------------------- lo elegido sobrevive al refresco

  await pagina.reload({ waitUntil: "networkidle" });
  await pagina.waitForSelector(".board .col", { timeout: 15000 });
  comprobar(
    "al recargar, el navegador recuerda el día que elegiste",
    (await pagina.inputValue("#diaSelect")) === otro.id,
    await pagina.inputValue("#diaSelect")
  );
  comprobar(
    "tras recargar se siguen viendo sólo las tarjetas de ese día",
    (await hasta(tarjetas(datosOtro), tarjetasEnPantalla)) === tarjetas(datosOtro),
    await tarjetasEnPantalla()
  );

  // El día más reciente se guarda como «reciente», no como fecha: lo que cambie
  // mañana es lo que enseña el tablero, no lo que se quedó de hoy.
  await pagina.selectOption("#diaSelect", defecto);
  const guardado = await pagina.evaluate(() => {
    try {
      return JSON.parse(localStorage.getItem("tablero-supervision-vista")).dia;
    } catch (e) {
      return null;
    }
  });
  comprobar("elegir el día más reciente se guarda como «reciente»", guardado === "reciente", guardado);

  // ----------------------------------------- el refresco no cierra el desplegable

  await pagina.evaluate(() => { window.__selector = document.getElementById("diaSelect"); });
  await pagina.waitForTimeout(9000);
  comprobar(
    "un refresco de la página no reemplaza el selector abierto",
    await pagina.evaluate(() => document.getElementById("diaSelect") === window.__selector),
    "el selector cambió de nodo"
  );
  comprobar(
    "el refresco no le quita el día que elegiste",
    (await pagina.inputValue("#diaSelect")) === defecto,
    await pagina.inputValue("#diaSelect")
  );

  // ------------------------------------------------------ el móvil, 420 px

  const movil = await (await navegador.newContext({ viewport: { width: 420, height: 900 } })).newPage();
  movil.on("pageerror", (e) => consola.push("pageerror movil: " + e.message));
  await movil.goto(BASE, { waitUntil: "networkidle" });
  await movil.waitForSelector(".board .col", { timeout: 15000 });
  const desborde = await movil.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
  comprobar("el tablero con el selector no desborda en el móvil", desborde <= 1, "sobran " + desborde + "px");
  const caja = await movil.locator("#diaSelect").boundingBox();
  comprobar(
    "el selector cabe en el móvil y se toca bien (44 px o más)",
    caja !== null && caja.height >= 44 && caja.x >= 0 && caja.x + caja.width <= 420,
    caja
  );
  if (await movil.isVisible("#diaFuera")) {
    const aviso = await movil.locator("#diaFuera").boundingBox();
    comprobar(
      "el aviso de lo que queda fuera cabe en el móvil y se toca bien (44 px o más)",
      aviso !== null && aviso.height >= 44 && aviso.x >= 0 && aviso.x + aviso.width <= 420,
      aviso
    );
  }
  await movil.click("#tabChat");
  comprobar(
    "en la pestaña de conversación el selector de día no ocupa sitio",
    !(await movil.isVisible("#diaSelect")),
    "sigue visible"
  );
  await movil.click("#tabTablero");
  comprobar("al volver al tablero el selector vuelve", await movil.isVisible("#diaSelect"));
  await captura("dias-estrecho", false, movil);

  comprobar("la consola no tiene ni un error ni un aviso", consola.length === 0, consola.slice(0, 4));
  comprobar("la página no pide nada fuera del propio tablero", peticionesExternas.length === 0, peticionesExternas.slice(0, 4));

  await navegador.close();

  for (const paso of pasos) console.log("ok - " + paso);
  if (fallos.length) {
    for (const fallo of fallos) console.error("not ok - " + fallo);
    process.exitCode = 1;
    return;
  }
  console.log("ok - el selector de día comprobado, " + pasos.length + " comprobaciones");
}

main().catch((error) => {
  console.error("not ok - la prueba del selector de día se rompió: " + error.message);
  process.exitCode = 1;
});
