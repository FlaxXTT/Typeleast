/**
 * Prompt construction for dictated-text polishing: the Article prompt, and only it.
 *
 * The user chose Article's "a third-party article" prompt as the one set of
 * instructions (see ./prompts/article-budget-reference.js and THIRD-PARTY-NOTICES.md).
 * The request follows the article's design:
 *   system  the article's prompt and its two demonstrations, byte for byte,
 *           then a delimited addendum carrying only the facts the upstream
 *           prompt cannot know: the user's dictionary and the text already in
 *           the box being typed into (when there is any)
 *   user    the raw recognised text, nothing else
 *
 * The earlier built-in prompt set (strength tiers, list detection, per-app
 * register, a list of common English terms) was removed at the user's request.
 *
 * @module typeleast-service/prompt
 */

import { articleSystemPrompt } from "./prompts/article-budget-reference.js";
import { promptifySystemPrompt } from "./prompts/promptify.js";

/** Bump when what the model receives changes meaningfully. */
export const PROMPT_VERSION = "2026-10-19.5-article+subject+promptify+beta";

/** The only prompt source. Kept as a list so an old profile value still validates. */
export const PROMPT_SOURCES = ["article"];

/**
 * The version recorded in history, so a stored result can be traced to the
 * instructions that produced it.
 * @returns {string} the version string.
 */
export function promptVersionFor() {
  return PROMPT_VERSION;
}

/** Marker that separates the vendored prompt from our own additions. */
export const HARNESS_ADDENDUM_MARKER = "=== HARNESS ADDENDUM (not part of the upstream prompt) ===";

/** Field-context parts, in the order they are shown to the model. */
const CONTEXT_PARTS = [
  ["windowTitle", "Window title"],
  ["before", "Text before the cursor"],
  ["selected", "Selected text (will be replaced)"],
  ["after", "Text after the cursor"],
];

/**
 * Our additions, appended to the vendored prompt only when they carry facts.
 *
 * The upstream prompt knows nothing about a personal dictionary or about the
 * text already in the box being typed into. The section is delimited so a
 * reader (or a test) can strip it and compare the rest with the upstream text
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
 * The system prompt for one request: Article's cleanup prompt, or for the
 * "promptify" strength (提示词模式) the structured-prompt rewriter. Both get the
 * same addendum (dictionary and field context).
 * @param {object} input - strength, the user's prompt-mode settings, and the dictionary and field context the addendum needs.
 * @returns {string} the system prompt.
 */
export function systemPromptFor({ dictionary, fieldContext, strength, promptify } = {}) {
  const base = strength === "promptify" ? promptifySystemPrompt(promptify) : articleSystemPrompt();
  return base + harnessAddendum({ dictionary, fieldContext });
}

/**
 * The user message: the raw recognised text, as the article intends. The
 * prompt already states that everything received is content to be optimised,
 * not a question.
 * @param {object} input - carries rawText.
 * @returns {string} the user-message body.
 */
export function buildUserMessage(input) {
  return String(input?.rawText ?? "");
}
