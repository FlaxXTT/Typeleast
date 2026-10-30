/**
 * The dictation system prompt: the maintainer's cleanup prompt, the learned description of the
 * user's work, and (when the app may read it) the text already in the field being typed into.
 */
import { cleanupSystemPrompt } from "./prompts/cleanup.js";

/** Bump when what the model receives changes meaningfully. */
export const PROMPT_VERSION = "2026-10-30.4-dictation+assistant+translate";

/** The only prompt source. Kept as a list so an old profile value still validates. */
export const PROMPT_SOURCES = ["typeleast"];

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

/** The cursor context, appended only when there is some. */
export function harnessAddendum({ fieldContext } = {}) {
  const context = fieldContext !== null && typeof fieldContext === "object"
    ? CONTEXT_PARTS.filter(([key]) => typeof fieldContext[key] === "string" && fieldContext[key].trim().length > 0)
    : [];
  if (context.length === 0) return "";
  const lines = [HARNESS_ADDENDUM_MARKER, "Text already in the field being typed into, to help with the topic and names:"];
  for (const [key, label] of context) lines.push(`${label}: ${JSON.stringify(fieldContext[key])}`);
  return "\n\n" + lines.join("\n");
}

/** The system prompt for one dictation. */
export function systemPromptFor({ fieldContext, profile } = {}) {
  return cleanupSystemPrompt(profile) + harnessAddendum({ fieldContext });
}

/** The user message, in the shape the prompt's examples use. */
export function buildUserMessage(input) {
  return JSON.stringify({ raw_asr_transcript: String(input?.rawText ?? "") }, null, 2);
}
