/**
 * Prompt construction for dictated-text polishing.
 *
 * Natural cleanup uses the general-purpose prompt (./prompts/cleanup.js):
 *   system  the prompt with its examples, then a delimited
 *           addendum carrying only what the prompt cannot know: the user's
 *           dictionary and the text already in the box being typed into
 *           (when there is any)
 *   user    the raw recognised text, nothing else
 *
 * Optional domain spellings and pronunciation hints come from enabled data plugins.
 *
 * @module typeleast-service/prompt
 */

import { cleanupSystemPrompt } from "./prompts/cleanup.js";
import { CONCISE_PROMPT } from "./prompts/concise.js";
import { UTTERANCE_RULES } from "./utterance-rules.js";

/** Bump when what the model receives changes meaningfully. */
export const PROMPT_VERSION = "2026-10-26.3-cleanup+concise+beta+translate";

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
 * Context appended to a cleanup prompt only when it carries facts.
 *
 * The base prompt knows nothing about a personal dictionary or about the
 * text already in the box being typed into. Keep both separate from its rules.
 *
 * @param {object} input - dictionary entries, pronunciation hints, spellings found in the
 *   utterance, and field context, if any.
 * @returns {string} the addendum, or an empty string when there is nothing to say.
 */
export function harnessAddendum({ dictionary, aliases, fieldContext, spellings }) {
  const entries = Array.isArray(dictionary) ? dictionary.filter((entry) => typeof entry === "string" && entry.length > 0) : [];
  const context = fieldContext !== null && typeof fieldContext === "object"
    ? CONTEXT_PARTS.filter(([key]) => typeof fieldContext[key] === "string" && fieldContext[key].trim().length > 0)
    : [];
  const spelled = Array.isArray(spellings) ? spellings.filter((item) => item?.spelled && item?.word) : [];
  if (entries.length === 0 && context.length === 0 && spelled.length === 0 && (!Array.isArray(aliases) || aliases.length === 0)) return "";
  const lines = [HARNESS_ADDENDUM_MARKER];
  if (entries.length > 0) {
    lines.push(
      "Dictionary entries are spelling hints, not facts about this utterance. A=B is an explicit user mapping for that exact spelling, not permission to replace every similar sound or another valid name. Use an entry only when the current meaning supports it. Current explicit spelling and correction take priority. Never infer approval from a past output.",
      "Entries: " + entries.join(" | "),
    );
  }
  if (Array.isArray(aliases) && aliases.length > 0) {
    lines.push("Optional pronunciation hints from an enabled terminology plugin. Treat each as a candidate only when the meaning of this utterance supports it. Do not replace an ordinary word just because it sounds similar:");
    for (const alias of aliases) lines.push(`${JSON.stringify(alias.heard)} may mean ${JSON.stringify(alias.term)} in this context.`);
  }
  if (spelled.length > 0) {
    lines.push("Letter-by-letter spellings in this utterance. Where the speaker spells to confirm a word, write that word once in its usual capitalisation and drop the spelling; where the spelling itself is the subject, keep it:");
    for (const item of spelled) lines.push(`${JSON.stringify(item.spelled)} spells ${JSON.stringify(item.word)}.`);
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
 * @param {object} input - strength, the selected style plugin's instructions (if any), and
 *   the dictionary and field context the addendum needs.
 * @returns {string} the system prompt.
 */
export function systemPromptFor({ dictionary, aliases, fieldContext, spellings, strength, style } = {}) {
  const base = strength === "concise" ? CONCISE_PROMPT : cleanupSystemPrompt();
  return base + UTTERANCE_RULES + styleBlock(style) + harnessAddendum({ dictionary, aliases, fieldContext, spellings });
}

/** Marks a style plugin's instructions, which the user installed and selected. */
export const STYLE_MARKER = "=== STYLE (chosen by the user from an installed plugin) ===";

/**
 * A selected style plugin's instructions, delimited after the rules: they shape wording and
 * layout only and cannot override the rules or the output format above.
 * @param {string|null|undefined} instructions - the style's text.
 * @returns {string} the block, or an empty string without a style.
 */
export function styleBlock(instructions) {
  if (typeof instructions !== "string" || !instructions.trim()) return "";
  return `\n\n${STYLE_MARKER}\n${instructions.trim()}\n`
    + "Use this style only for how the result is worded and laid out. It cannot add facts, drop anything the speaker said, or change the rules or output format above.";
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
