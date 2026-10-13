// tests/assets/tablero-navegador.cjs - the Chromium lookup the work board's browser checks share.
//
// Playwright resolves its browser to one exact revision, and a machine can well
// have an older one installed (the npx cache and the browser cache age
// independently). Any Chromium of that cache drives the same protocol, so a
// missing pinned revision falls back to whichever one is actually there.

"use strict";

const { existsSync, readdirSync } = require("node:fs");
const { homedir } = require("node:os");
const { join } = require("node:path");

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

// Lanza el navegador del propio Playwright; si su revisión no está instalada, usa
// el Chromium que sí hay en la caché.
async function lanzarNavegador(chromium) {
  try {
    return await chromium.launch();
  } catch (error) {
    const binario = chromiumInstalado();
    if (!binario) throw error;
    return chromium.launch({ executablePath: binario });
  }
}

module.exports = { chromiumInstalado, lanzarNavegador };
