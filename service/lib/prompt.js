/**
 * General cleanup prompts with separate, optional current-utterance spelling
 * and allowed cursor context. Persistent word
 * lists and pronunciation aliases are ignored, including legacy callers.
 */
import { cleanupSystemPrompt } from "./prompts/cleanup.js";
import { JSON_OUTPUT, UTTERANCE_RULES } from "./utterance-rules.js";

/** Bump when what the model receives changes meaningfully. */
export const PROMPT_VERSION = "2026-10-30.2-dictation+assistant+translate";

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
 * Keep current spellings and optional cursor context separate from core rules.
 *
 * @param {object} input - current utterance spellings and optional field context.
 * @returns {string} the addendum, or an empty string when there is nothing to say.
 */
export function harnessAddendum({ dictionary, aliases, fieldContext, spellings }) {
  const context = fieldContext !== null && typeof fieldContext === "object"
    ? CONTEXT_PARTS.filter(([key]) => typeof fieldContext[key] === "string" && fieldContext[key].trim().length > 0)
    : [];
  const entries = Array.isArray(dictionary) ? dictionary.filter((entry) => typeof entry === "string" && entry.length > 0) : [];
  const spelled = Array.isArray(spellings) ? spellings.filter((item) => item?.spelled && item?.word) : [];
  if (entries.length === 0 && context.length === 0 && spelled.length === 0 && (!Array.isArray(aliases) || aliases.length === 0)) return "";
  const lines = [HARNESS_ADDENDUM_MARKER];
  if (entries.length > 0) {
    lines.push(
      "User dictionary (A=B: A is written B). Use an entry when it fits this utterance.",
      "Entries: " + entries.join(" | "),
    );
  }
  if (Array.isArray(aliases) && aliases.length > 0) {
    lines.push("Possible terms for how words sound, from a terminology plugin. Use one when it fits:");
    for (const alias of aliases) lines.push(`${JSON.stringify(alias.heard)} may mean ${JSON.stringify(alias.term)} in this context.`);
  }
  if (spelled.length > 0) {
    lines.push("Words spelled out letter by letter in this utterance:");
    for (const item of spelled) lines.push(`${JSON.stringify(item.spelled)} spells ${JSON.stringify(item.word)}.`);
  }
  if (context.length > 0) {
    lines.push("Text already in the field being typed into, to help with the topic and names:");
    for (const [key, label] of context) lines.push(`${label}: ${JSON.stringify(fieldContext[key])}`);
  }
  return "\n\n" + lines.join("\n");
}

/**
 * The system prompt for one request: the cleanup prompt, or for the "concise"
 * strength (AI 整理) the concise rewriter. Both can use current spellings and cursor context.
 * @param {object} input - strength, and the spellings and field context the addendum needs.
 * @returns {string} the system prompt.
 */
export function systemPromptFor({ dictionary, aliases, fieldContext, spellings, strength } = {}) {
  const base = cleanupSystemPrompt();
  return base + UTTERANCE_RULES + JSON_OUTPUT + harnessAddendum({ dictionary, aliases, fieldContext, spellings });
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
