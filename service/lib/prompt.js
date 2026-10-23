/**
 * Prompt construction for dictated-text polishing.
 *
 * Natural cleanup uses the project's own prompt (./prompts/cleanup.js):
 *   system  the prompt with its examples, exactly as written, then a delimited
 *           addendum carrying only what the prompt cannot know: the user's
 *           dictionary and the text already in the box being typed into
 *           (when there is any)
 *   user    the raw recognised text, nothing else
 *
 * The earlier built-in prompt set (strength tiers, list detection, per-app
 * register, a list of common English terms) was removed at the user's request.
 *
 * @module typeleast-service/prompt
 */

import { cleanupSystemPrompt } from "./prompts/cleanup.js";
import { CONCISE_PROMPT } from "./prompts/concise.js";
import { UTTERANCE_RULES } from "./utterance-rules.js";

/** Bump when what the model receives changes meaningfully. */
export const PROMPT_VERSION = "2026-10-25.1-cleanup+concise+beta+translate";

/** The only prompt source. Kept as a list so an old profile value still validates. */
export const PROMPT_SOURCES = ["typeleast"];

/**
 * The version recorded in history, so a stored result can be traced to the
 * instructions that produced it.
 * @returns {string} the version string.
 */
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

/**
 * Context appended to the owner's cleanup prompt only when it carries facts.
 *
 * The cleanup prompt knows nothing about a personal dictionary or about the
 * text already in the box being typed into. The section is delimited so a
 * reader (or a test) can strip it and compare the rest with the owner's text
 * byte for byte.
 *
 * @param {object} input - dictionary entries and field context, if any.
 * @returns {string} the addendum, or an empty string when there is nothing to say.
 */
export function harnessAddendum({ dictionary, fieldContext }) {
  const entries = Array.isArray(dictionary) ? dictionary.filter((entry) => typeof entry === "string" && entry.length > 0) : [];
  const context = fieldContext !== null && typeof fieldContext === "object"
    ? CONTEXT_PARTS.filter(([key]) => typeof fieldContext[key] === "string" && fieldContext[key].trim().length > 0)
    : [];
  if (entries.length === 0 && context.length === 0) return "";
  const lines = [HARNESS_ADDENDUM_MARKER];
  if (entries.length > 0) {
    lines.push(
      "Dictionary entries are hard constraints. \"A=B\" means: wherever A, or anything that sounds like A, was recognised, write B. An entry without \"=\" is a spelling to use exactly whenever that word is meant.",
      "Entries: " + entries.join(" | "),
    );
  }
  if (context.length > 0) {
    lines.push("The text already in the box being typed into is below. Use it only to choose correct spellings, names and terminology, and to continue in the same style. Never copy it into the output.");
    for (const [key, label] of context) lines.push(`${label}: ${JSON.stringify(fieldContext[key])}`);
  }
  return "\n\n" + lines.join("\n");
}

/**
 * The system prompt for one request: the cleanup prompt, or for the "concise"
 * strength (精简整理) the concise rewriter. Both get the same addendum
 * (dictionary and field context).
 * @param {object} input - strength, and the dictionary and field context the addendum needs.
 * @returns {string} the system prompt.
 */
export function systemPromptFor({ dictionary, fieldContext, strength } = {}) {
  const base = strength === "concise" ? CONCISE_PROMPT : cleanupSystemPrompt();
  return base + UTTERANCE_RULES + harnessAddendum({ dictionary, fieldContext });
}

/**
 * The user message: the raw recognised text, as the cleanup prompt requires. The
 * prompt already states that everything received is content to be optimised,
 * not a question.
 * @param {object} input - carries rawText.
 * @returns {string} the user-message body.
 */
export function buildUserMessage(input) {
  return String(input?.rawText ?? "");
}
