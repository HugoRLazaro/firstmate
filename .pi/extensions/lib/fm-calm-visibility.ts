import {
  getMarkdownTheme,
  type ExtensionAPI,
  UserMessageComponent,
} from "@earendil-works/pi-coding-agent";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
export const CALM_TRANSCRIPT_CLASSES = [
  "genuine-user-prompt",
  "genuine-agent-response",
  "assistant-working-note",
  "assistant-thinking",
  "assistant-tool-call",
  "tool-result",
  "tool-image",
  "user-bash",
  "skill-invocation",
  "custom-message",
  "custom-entry",
  "compaction-summary",
  "branch-summary",
  "working-status",
  "command-status",
  "system-notice",
  "cache-notice",
  "project-trust-warning",
  "synthetic-user",
  "synthetic-assistant",
  "unknown",
] as const;

export type CalmTranscriptClass = (typeof CALM_TRANSCRIPT_CLASSES)[number];

// Calm is on or off. "assistant-working-note" is deliberately absent from the allowlist:
// Calm hides mid-turn assistant working notes, keeping the genuine final reply.
const CALM_VISIBLE_CLASSES = new Set<CalmTranscriptClass>([
  "genuine-user-prompt",
  "genuine-agent-response",
  "working-status",
]);

// Legacy session entries from Calm versions before 2026-07-23 retain this
// presentation type. New operational input stays user-role and is never rerouted.
export const FIRSTMATE_SYNTHETIC_PRESENTATION_TYPE = "firstmate-synthetic-input-presentation";
export const FIRSTMATE_CALM_PRESENTATION_EVENT = "firstmate:calm-presentation";

export type CalmPresentationState = {
  active: boolean;
  stockExportRendering: boolean;
};

export const FIRSTMATE_SYNTHETIC_KINDS = [
  "session-start",
  "watcher",
  "turn-end-guard",
  "away-supervisor",
  "from-firstmate",
  "launch-brief",
  "legacy-operational",
] as const;

export type FirstmateSyntheticKind = (typeof FIRSTMATE_SYNTHETIC_KINDS)[number];
type FirstmateSyntheticPresentation = {
  content: string;
  kind: FirstmateSyntheticKind;
};

let calm = false;
let stockExportRendering = false;

export function calmTranscriptClassIsVisible(itemClass: CalmTranscriptClass): boolean {
  return CALM_VISIBLE_CLASSES.has(itemClass);
}

export function setCalmPresentation(active: boolean): void {
  calm = active;
}

export function setCalmStockExportRendering(active: boolean): void {
  stockExportRendering = active;
}

export function calmPresentationIsActive(): boolean {
  return calm;
}

export function calmPresentationHides(itemClass: CalmTranscriptClass): boolean {
  return calm && !stockExportRendering && !calmTranscriptClassIsVisible(itemClass);
}

// docs/configuration.md "Calm preference (config/calm)" owns the persisted
// value schema and resolution order this shared reader implements. Every
// extension that honors Calm presentation resolves the same file from its own
// extension path, so each one lands on the same effective home and reads the
// same values.
export function calmPreferencePathFor(extensionFile: string): string {
  const codeRoot = resolve(dirname(extensionFile), "../..");
  const fmHome = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || codeRoot;
  const configDirectory = process.env.FM_CONFIG_OVERRIDE || resolve(fmHome, "config");
  return resolve(configDirectory, "calm");
}

export function loadCalmPreference(preferencePath: string): boolean {
  let stored: string;
  try {
    stored = readFileSync(preferencePath, "utf8").trim();
  } catch {
    return false;
  }
  // "max" is the legacy value written by the removed third presentation level,
  // whose behavior is now ordinary Calm; a home upgraded from it restores as on
  // rather than dropping to off.
  return stored === "on" || stored === "max";
}

export function registerFirstmateSyntheticPresentation(pi: ExtensionAPI): void {
  pi.registerEntryRenderer<FirstmateSyntheticPresentation>(
    FIRSTMATE_SYNTHETIC_PRESENTATION_TYPE,
    (entry) => {
      if (calmPresentationHides("synthetic-user")) return undefined;
      const data = entry.data;
      if (!data || typeof data.content !== "string") return undefined;
      return new UserMessageComponent(data.content, getMarkdownTheme());
    },
  );
}
