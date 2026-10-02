// tests/assets/tablero-pantalla.mjs - drives the work board page in a real browser.
//
// tests/fm-tablero-pantalla.test.sh is the only supported caller: it seeds a home,
// starts the server and passes the URL in. Everything a stub cannot prove lives
// here - that the page renders the five columns, that the tabs work, that the
// console stays clean, that a poll does not eat what you are typing, and that
// answering from a card really closes the decision.
//
// Environment:
//   TABLERO_BASE      base URL of the running board (required)
//   TABLERO_CAPTURAS  directory for screenshots; empty means take none
//   TABLERO_MUTAR     "0" to leave the home alone: skips sending and answering,
//                     for a read-only pass over a real home
//
// Exit status: 0 when every check passed, 1 with a report on stderr otherwise.

"use strict";

const { existsSync, mkdirSync, readdirSync } = require("node:fs");
const { homedir } = require("node:os");
const { join } = require("node:path");
const { chromium } = require("playwright");

// Playwright resolves its browser to one exact revision, and a machine can well
// have an older one installed (the npx cache and the browser cache age
// independently). Any Chromium of that cache drives the same protocol, so a
// missing pinned revision falls back to whichever one is actually there.
function chromiumInstalado() {
  const cache = process.env.PLAYWRIGHT_BROWSERS_PATH || join(homedir(), ".cache", "ms-playwright");
  if (!existsSync(cache)) return "";
  const candidatos = [];
  for (const entrada of readdirSync(cache)) {
    if (entrada.startsWith("chromium-")) {
      candidatos.push(join(cache, entrada, "chrome-linux64", "chrome"));
      candidatos.push(join(cache, entrada, "chrome-linux", "chrome"));
    }
    if (entrada.startsWith("chromium_headless_shell-")) {
      candidatos.push(join(cache, entrada, "chrome-headless-shell-linux64", "chrome-headless-shell"));
    }
  }
  return candidatos.find((ruta) => existsSync(ruta)) || "";
}

const BASE = process.env.TABLERO_BASE;
const CAPTURAS = process.env.TABLERO_CAPTURAS || "";
const MUTAR = process.env.TABLERO_MUTAR !== "0";
if (!BASE) {
  console.error("TABLERO_BASE is required");
  process.exit(1);
}
if (CAPTURAS) mkdirSync(CAPTURAS, { recursive: true });

const fallos = [];
const pasos = [];
function comprobar(descripcion, condicion, detalle) {
  if (condicion) pasos.push(descripcion);
  else fallos.push(descripcion + (detalle ? " -> " + detalle : ""));
}

const ANCHOS = [
  { ancho: 1560, alto: 1000, nombre: "1560" },
  { ancho: 1280, alto: 960, nombre: "1280" },
];
const ESTRECHO = { ancho: 420, alto: 900, nombre: "420" };

async function main() {
let navegador;
try {
  navegador = await chromium.launch();
} catch (error) {
  const binario = chromiumInstalado();
  if (!binario) throw error;
  navegador = await chromium.launch({ executablePath: binario });
}
const contexto = await navegador.newContext({ viewport: { width: 1560, height: 1000 } });
const pagina = await contexto.newPage();

// Todo lo que la consola dice, y toda petición que sale de esta página: el
// tablero no puede pedirle nada a nadie de fuera.
const consola = [];
const peticionesExternas = [];
pagina.on("console", (m) => {
  if (m.type() === "error" || m.type() === "warning") consola.push(m.type() + ": " + m.text());
});
pagina.on("pageerror", (e) => consola.push("pageerror: " + e.message));
pagina.on("request", (p) => {
  if (!p.url().startsWith(BASE)) peticionesExternas.push(p.url());
});

let sondeos = 0;
let peticiones = 0;
pagina.on("request", (p) => {
  if (p.url().endsWith("/api/estado")) sondeos += 1;
  if (p.url().endsWith("/api/peticion")) peticiones += 1;
});

async function esperarSondeos(cuantos) {
  const limite = Date.now() + 30000;
  while (sondeos < cuantos && Date.now() < limite) await pagina.waitForTimeout(200);
}

async function captura(nombre, completa = true) {
  if (!CAPTURAS) return;
  await pagina.screenshot({ path: CAPTURAS + "/" + nombre + ".png", fullPage: completa });
}

// ---------------------------------------------------------------- la pantalla

const ausenciaInicial = (await (await fetch(BASE + "/api/estado")).json()).ausencia;
await pagina.goto(BASE, { waitUntil: "networkidle" });
await pagina.waitForSelector(".board .col", { timeout: 15000 });

if (ausenciaInicial) {
  const textoAviso = ((await pagina.textContent("#aviso")) || "").trim();
  comprobar(
    "el modo ausencia se avisa aunque el tablero no traiga otro aviso que enseñar",
    (await pagina.isVisible("#aviso")) && textoAviso.includes("ausencia"),
    JSON.stringify(textoAviso)
  );
}

const nombres = await pagina.$$eval(".col-name", (n) => n.map((e) => e.textContent.trim()));
comprobar(
  "el kanban tiene las cinco columnas con su nombre",
  nombres.length === 5 &&
    nombres[0] === "Ahora mismo" &&
    nombres[1] === "Espera tu respuesta" &&
    nombres[2] === "Terminado, espera subir" &&
    nombres[3] === "Planificado, sin empezar" &&
    nombres[4] === "Terminado y publicado",
  JSON.stringify(nombres)
);

const tarjetas = await pagina.$$eval(".card h3", (n) => n.map((e) => e.textContent.trim()));
comprobar("las tarjetas llevan el título real de la tarea", tarjetas.length > 0 && tarjetas.every((t) => t.length > 2), String(tarjetas.length));

const esperan = await pagina.$$eval(".col:nth-child(2) .card .need", (n) => n.map((e) => e.textContent.trim()));
comprobar("cada tarjeta que espera dice qué necesita del capitán", esperan.length > 0 && esperan.every((t) => t.length > 5), JSON.stringify(esperan.slice(0, 1)));

const titulos = await pagina.$$eval(".card h3", (n) => n.map((e) => e.textContent));
comprobar("ningún título arrastra las anotaciones internas del registro", !titulos.some((t) => /\(repo:|\(kind:|\(hold:/.test(t)));

// Arrastrar a la propia columna no es un movimiento: no se pide nada.
{
  const columna = pagina.locator(".col:nth-child(2)");
  const tarjeta = columna.locator(".card").first();
  if (await tarjeta.count()) {
    await tarjeta.dragTo(columna);
    await pagina.waitForTimeout(300);
    comprobar("soltar una tarjeta en su propia columna no pide moverla", peticiones === 0, String(peticiones));
  }
}
if (MUTAR) {
  const tarjeta = pagina.locator(".col:nth-child(1) .card").first();
  if (await tarjeta.count()) {
    await tarjeta.dragTo(pagina.locator(".col:nth-child(2)"));
    await pagina.waitForTimeout(600);
    comprobar("soltar una tarjeta en otra columna sí pide moverla", peticiones === 1, String(peticiones));
  }
}

const pie = await pagina.textContent(".foot");
comprobar("la pantalla dice que mover y quitar sólo se piden", /piden/i.test(pie) && /firstmate/i.test(pie));

for (const { ancho, alto, nombre } of ANCHOS) {
  await pagina.setViewportSize({ width: ancho, height: alto });
  await pagina.waitForTimeout(300);
  const desborde = await pagina.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
  comprobar(`a ${ancho} de ancho no hay scroll lateral`, desborde <= 1, "sobran " + desborde + "px");
  await captura("kanban-" + nombre);
}

// ------------------------------------------------------------ la vista de lista

await pagina.setViewportSize({ width: 1560, height: 1000 });
await pagina.click('.switch button[data-view="lista"]');
await pagina.waitForSelector(".list .row-top");
const grupos = await pagina.$$eval(".list-group", (n) => n.map((e) => e.textContent));
comprobar("la vista de lista agrupa por etapa", grupos.length === 5, JSON.stringify(grupos.length));
for (const { ancho, alto, nombre } of ANCHOS) {
  await pagina.setViewportSize({ width: ancho, height: alto });
  await pagina.waitForTimeout(250);
  const desborde = await pagina.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
  comprobar(`la lista a ${ancho} tampoco desborda`, desborde <= 1, "sobran " + desborde + "px");
  await captura("lista-" + nombre);
}
await pagina.click('.switch button[data-view="etapas"]');
await pagina.waitForSelector(".board .col");

// ------------------------------------------- responder desde una tarjeta, de verdad

let idRespondida = null;
{
  // El sello de actualización cambia cada minuto, pero un cambio solo del reloj no
  // puede repintar el tablero ni quitarle el foco al textarea que el capitán tiene abierto.
  await pagina.route("**/api/estado", async (ruta) => {
    const cuerpo = await (await ruta.fetch()).json();
    cuerpo.generado_texto = "1 de enero, 00:00";
    await ruta.fulfill({ json: cuerpo });
  });
  const pendientesAntes = Number(await pagina.textContent("#waitN"));
  const tarjeta = pagina.locator(".col:nth-child(2) .card").first();
  await pagina.setViewportSize({ width: 1280, height: 960 });
  await pagina.waitForTimeout(250);
  await tarjeta.locator(".card-top").click();
  await tarjeta.locator("textarea").waitFor({ timeout: 5000 });
  idRespondida = await tarjeta.getAttribute("data-id");
  await tarjeta.locator("textarea").fill("Sí, adelante con lo recomendado.");
  await esperarSondeos(sondeos + 2);
  const conservado = await tarjeta.locator("textarea").inputValue();
  comprobar("el refresco no se lleva lo que estás escribiendo en una tarjeta", conservado === "Sí, adelante con lo recomendado.", JSON.stringify(conservado));
  await pagina.waitForFunction(
    () => (document.getElementById("sub") || {}).textContent.includes("1 de enero"),
    null,
    { timeout: 15000 }
  );
  const enfocado = await pagina.evaluate(() => (document.activeElement || {}).tagName || "");
  comprobar("un cambio solo del reloj no repinta ni le quita el foco a la tarjeta", enfocado === "TEXTAREA", enfocado);

  await captura("tarjeta-responder-1280");

  if (MUTAR) {
  await tarjeta.locator(".btn-primary").click();
  // El cierre pasa por el mecanismo de decisiones de la casa, que tarda unos
  // segundos: se espera al resultado, no a un reloj.
  const cerrada = await pagina
    .waitForFunction(
      ([id, antes]) => {
        const sigue = document.querySelectorAll('.col:nth-child(2) .card[data-id="' + id + '"]').length;
        const ahora = Number(document.getElementById("waitN").textContent);
        return sigue === 0 && ahora === antes - 1;
      },
      [idRespondida, pendientesAntes],
      { timeout: 60000 }
    )
    .then(() => true)
    .catch(() => false);
  const aviso = (await pagina.textContent("#toastT")) || "";
  // La tarjeta no desaparece: la decisión cerrada pasa a «Terminado y publicado».
  comprobar(
    "responder desde la tarjeta cierra la decisión y la saca de las que te esperan",
    cerrada,
    JSON.stringify({ aviso, pendientesAntes, pendientesDespues: Number(await pagina.textContent("#waitN")) })
  );

  // Lo escrito en una tarjeta se ve en la tarjeta: sin contestar mientras firstmate
  // no responda, y contestado cuando responde a esa pregunta concreta. La columna
  // «Terminado y publicado» nace plegada, así que se despliega para verlo.
  await pagina.click(".col:nth-child(5) .fold");
  await pagina.waitForTimeout(350);
  const chipEspera = ((await pagina.textContent(`.card[data-id="${idRespondida}"] .pregunta.p-espera`).catch(() => "")) || "").trim();
  comprobar(
    "la tarjeta dice que lo escrito en ella espera la respuesta de firstmate",
    /firstmate/.test(chipEspera) && !/tu respuesta/i.test(chipEspera),
    JSON.stringify(chipEspera)
  );
  const chipContestada = ((await pagina.textContent('.card[data-id="portales-decidir"] .pregunta.p-contestada').catch(() => "")) || "").trim();
  comprobar("una pregunta ya contestada se ve contestada en su tarjeta", /contest/i.test(chipContestada), JSON.stringify(chipContestada));
  await captura("tarjeta-pregunta-contestada-1280");
  await pagina.click(".col:nth-child(5) .fold");
  await pagina.waitForTimeout(350);
  }
}

// --------------------------------------------------------- la pestaña del chat

await pagina.click("#tabChat");
await pagina.waitForSelector("#panelChat:not([hidden])");
comprobar("el chat vive en su propia pestaña", await pagina.isVisible("#panelChat") && !(await pagina.isVisible("#panelTablero")));

const burbujas = await pagina.$$eval(".chat-log .msg", (n) => n.length);
if (MUTAR) {
  comprobar("la conversación pinta el registro durable", burbujas > 0, String(burbujas));
  const esperando = await pagina.$$eval(".chat-log .state.wait", (n) => n.length);
  comprobar("los mensajes sin respuesta se ven esperando", esperando > 0, String(esperando));
  const respondidos = await pagina.$$eval(".chat-log .state.ok", (n) => n.length);
  comprobar("las respuestas de firstmate se emparejan con su mensaje", respondidos > 0, String(respondidos));
  const cuando = await pagina.$$eval(".chat-log .state.ok", (n) => n.map((e) => e.textContent.trim()));
  comprobar(
    "el mensaje respondido dice a qué hora se le contestó, no sólo que se le contestó",
    cuando.length > 0 && cuando.every((t) => /Respondido a las \d{1,2}:\d{2}/.test(t)),
    JSON.stringify(cuando)
  );
} else {
  const vacio = (await pagina.textContent(".chat-log")) || "";
  comprobar("un tablero que aún no ha hablado dice que no hay nada hablado", burbujas === 0 && vacio.includes("Todavía no hay nada hablado"), vacio.trim());
}

for (const { ancho, alto, nombre } of ANCHOS) {
  await pagina.setViewportSize({ width: ancho, height: alto });
  await pagina.waitForTimeout(250);
  await captura("chat-" + nombre);
}

// Escribir en el chat y comprobar que un sondeo no lo borra.
await pagina.fill("#chatInput", "Esto lo estoy escribiendo yo y no se puede perder.");
await esperarSondeos(sondeos + 2);
const borrador = await pagina.inputValue("#chatInput");
comprobar("el refresco no se lleva lo que estás escribiendo en el chat", borrador === "Esto lo estoy escribiendo yo y no se puede perder.", JSON.stringify(borrador));

if (MUTAR) {
  await pagina.click("#chatSend");
  const llegado = await pagina
    .waitForFunction(
      (texto) =>
        [...document.querySelectorAll(".chat-log .msg.me .bubble")].some((n) => n.textContent.includes(texto)) &&
        document.querySelectorAll(".chat-log .state.wait").length > 0,
      "no se puede perder",
      { timeout: 60000 }
    )
    .then(() => true)
    .catch(() => false);
  const nuevo = await pagina.$$eval(".chat-log .msg.me .bubble", (n) => n.map((e) => e.textContent));
  comprobar("el mensaje libre llega y se queda esperando respuesta", llegado, JSON.stringify(nuevo.slice(-1)));
  const vacio = await pagina.inputValue("#chatInput");
  comprobar("el compositor se vacía después de enviar", vacio === "", JSON.stringify(vacio));
}

// ------------------------------------------------- contador de la pestaña

// El contador de la pestaña de conversación cuenta los mensajes sin contestar.
// El tablero cuenta otra cosa (tareas que esperan tu decisión) y su repintado no
// puede pisarlo. Un clic en una columna repinta el tablero sin tocar la red.
await esperarSondeos(sondeos + 1);
const sinContestar = await pagina.$$eval(".chat-log .state.wait", (n) => n.length);
await pagina.click("#tabTablero");
await pagina.waitForSelector(".board .col");
await pagina.click(".col:nth-child(5) .fold");
const enPestana = await pagina.textContent("#chatPend");
const enTablero = Number(await pagina.textContent("#waitN"));
comprobar(
  "el repintado del tablero no pisa el contador de la pestaña de conversación",
  enPestana === String(sinContestar) && (!MUTAR || enTablero !== sinContestar),
  JSON.stringify({ enPestana, sinContestar, enTablero })
);
await pagina.click(".col:nth-child(5) .fold");
await pagina.waitForTimeout(350);
await pagina.click("#tabChat");
await pagina.waitForSelector("#panelChat:not([hidden])");

// ------------------------------------------------------------- ventana estrecha

await pagina.setViewportSize({ width: ESTRECHO.ancho, height: ESTRECHO.alto });
await pagina.waitForTimeout(300);
let desborde = await pagina.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
comprobar("el chat en el móvil no desborda", desborde <= 1, "sobran " + desborde + "px");
await captura("chat-estrecho-" + ESTRECHO.nombre, false);

await pagina.click("#tabTablero");
await pagina.waitForSelector(".board .col");
await pagina.waitForTimeout(300);
desborde = await pagina.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
comprobar("el kanban en el móvil no desborda", desborde <= 1, "sobran " + desborde + "px");
const columnasEstrecho = await pagina.$$eval(".board .col", (n) => n.length);
comprobar("en el móvil se siguen viendo las cinco columnas", columnasEstrecho === 5, String(columnasEstrecho));
await captura("kanban-estrecho-" + ESTRECHO.nombre, false);

// -------------------------------------------------------------- consola y red

comprobar("la consola no tiene ni un error ni un aviso", consola.length === 0, JSON.stringify(consola.slice(0, 4)));
comprobar("la página no pide nada fuera del propio tablero", peticionesExternas.length === 0, JSON.stringify(peticionesExternas.slice(0, 4)));
comprobar("el tablero se refresca solo por sondeo", sondeos >= 3, String(sondeos) + " sondeos");

await navegador.close();

for (const paso of pasos) console.log("ok - " + paso);
if (fallos.length) {
  for (const fallo of fallos) console.error("not ok - " + fallo);
  process.exitCode = 1;
  return;
}
console.log("ok - todo comprobado, " + pasos.length + " comprobaciones");
}

main().catch((error) => {
  console.error("not ok - la prueba de navegador se rompió: " + error.message);
  process.exitCode = 1;
});
