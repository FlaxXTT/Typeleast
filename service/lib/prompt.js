/**
 * The dictation system prompt: the maintainer's cleanup prompt, the learned description of the
 * user's work, and (when the app may read it) the text already in the field being typed into.
 */
import { cleanupSystemPrompt } from "./prompts/cleanup.js";
import { readFile } from "node:fs/promises";
import { createHash } from "node:crypto";
import { join } from "node:path";

/** Bump when what the model receives changes meaningfully. */
export const PROMPT_VERSION = "2026-11-26.1-dictation+assistant+translate";

const previousCleanupHash = "8cf928f110167c30c9ed8d2ccbcf47823ac9335a5fa487a34524825c3a76f85b";

/** The built-in prompt source, retained for compatibility. */
export const PROMPT_SOURCES = ["typeleast"];

/** The native Settings editor stores overrides alongside the other local state. */
export async function readSavedPrompt(stateDir, filename, logger) {
  try {
    const text = await readFile(join(stateDir, filename), "utf8");
    if (filename === "asr-engineering.md" && createHash("sha256").update(text).digest("hex") === previousCleanupHash) return "";
    return text.trim();
  } catch (error) {
    if (error?.code !== "ENOENT") logger?.warn?.("typeleast: could not read a custom prompt");
    return "";
  }
}

/** The version recorded in history, so a stored result can be traced to the instructions that produced it. */
export function promptVersionFor() {
  return PROMPT_VERSION;
}

/** Context separator; its existing wire text stays compatible with earlier versions. */
export const HARNESS_ADDENDUM_MARKER = "=== HARNESS ADDENDUM (not part of the upstream prompt) ===";

/** Field-context parts, in the order they are shown to the model. */
const CONTEXT_PARTS = [
  ["windowTitle", "Window title"],
  ["before", "Text before the cursor"],
  ["selected", "Selected text (will be replaced)"],
  ["after", "Text after the cursor"],
];

/** The existing app identifier and optionally enabled cursor context. */
export function harnessAddendum({ fieldContext, appHint } = {}) {
  const app = typeof appHint === "string" && /^[\w.-]{1,160}$/.test(appHint) ? appHint : "";
  const context = fieldContext !== null && typeof fieldContext === "object"
    ? CONTEXT_PARTS.filter(([key]) => typeof fieldContext[key] === "string" && fieldContext[key].trim().length > 0)
    : [];
  if (!app && context.length === 0) return "";
  const lines = [HARNESS_ADDENDUM_MARKER, "Quoted scene clues for interpreting the current utterance. Use them to resolve plausible ASR alternatives. Honor explicit spelling and self-corrections. Keep the transcript if ambiguity remains."];
  if (app) lines.push(`Application identifier: ${JSON.stringify(app)}`);
  for (const [key, label] of context) lines.push(`${label}: ${JSON.stringify(fieldContext[key])}`);
  return "\n\n" + lines.join("\n");
}

/** The system prompt for one dictation. */
export function systemPromptFor({ fieldContext, appHint, profile, cleanupOverride } = {}) {
  return cleanupSystemPrompt(profile, cleanupOverride) + harnessAddendum({ fieldContext, appHint });
}

/** The quoted transcript supplied to the system prompt. */
export function buildUserMessage(input) {
  return JSON.stringify({ raw_asr_transcript: String(input?.rawText ?? "") }, null, 2);
}
