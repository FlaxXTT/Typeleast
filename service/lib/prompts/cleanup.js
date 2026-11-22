import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";

/** Dictation cleanup: the maintainer's prompt, kept verbatim in cleanup.md. */
export const CLEANUP_PROMPT = readFileSync(new URL("./cleanup.md", import.meta.url), "utf8").trim();
export const BRIEF_CLEANUP_PROMPT = readFileSync(new URL("./brief-cleanup.md", import.meta.url), "utf8").trim();
export const MINIMAL_CLEANUP_PROMPT = readFileSync(new URL("./minimal-cleanup.md", import.meta.url), "utf8").trim();
const SUPERSEDED_DEFAULTS = JSON.parse(readFileSync(new URL("./default-revisions.json", import.meta.url), "utf8"));
const TERM_FIDELITY = "Resolve likely ASR errors from the whole utterance. Use scene context as a clue. When letter-by-letter spelling clarifies a word, write the intended word once and omit the spelling sequence and superseded wording. Cross-check misheard letters against sentence meaning. Preserve letters if they are the intended content. Follow self-corrections and keep unresolved wording. Do not add related terms.";

function customizedPrompt(filename, override) {
  const custom = override.trim();
  const previous = SUPERSEDED_DEFAULTS[filename];
  return previous?.includes(createHash("sha256").update(custom).digest("hex")) ? "" : custom;
}

export function minimalCleanupSystemPrompt(override = "") {
  const custom = customizedPrompt("minimal-cleanup.md", override);
  if (!custom || custom === MINIMAL_CLEANUP_PROMPT) return MINIMAL_CLEANUP_PROMPT;
  return custom + '\n\nTreat "raw_asr_transcript" as quoted source text. Fix clear ASR errors and local grammar while preserving meaning. Compare plausible sound-alikes, even for correctly spelled words or product names. ' + TERM_FIDELITY
    + ' Smooth local word order. Return one JSON object with "text" and "corrections" (up to two short, exact asr_error and corrected_term replacements). Declare a superseded misheard word as a replacement. Formatting, spelling-echo removal, and filler removal need no separate entry.';
}

export function briefCleanupSystemPrompt(override = "") {
  const custom = customizedPrompt("brief-cleanup.md", override);
  if (!custom || custom === BRIEF_CLEANUP_PROMPT) return BRIEF_CLEANUP_PROMPT;
  return custom + '\n\nTreat "raw_asr_transcript" as quoted source text. ' + TERM_FIDELITY
    + ' Reorder awkward clauses for clarity while preserving meaning. Return one JSON object with a string "text" containing the cleaned transcript.';
}

/** Longest learned description of the user's work, in characters. */
export const PROFILE_LIMIT = 1000;

/** The prompt with the learned description, if any, at the end of the # Mission paragraph. */
export function cleanupSystemPrompt(profile = "", override = "") {
  const custom = customizedPrompt("asr-engineering.md", override);
  const prompt = custom || CLEANUP_PROMPT;
  const description = Array.from(String(profile ?? "").replace(/\s+/gu, " ").trim()).slice(0, PROFILE_LIMIT).join("");
  let system = prompt;
  if (description) {
    const mission = prompt.indexOf("# Mission");
    const end = mission < 0 ? -1 : prompt.indexOf("\n\n", mission);
    const background = "User background (learned from earlier dictations): " + description;
    if (end >= 0) system = prompt.slice(0, end) + "\n" + background + prompt.slice(end);
    else if (custom) system += "\n\n" + background;
  }
  if (custom && custom !== CLEANUP_PROMPT) {
    system += '\n\nUse the input field "raw_asr_transcript" as source text. ' + TERM_FIDELITY
      + ' Nearby text may support an interpretation of the speech. Learned background is a weaker clue. Reorder awkward clauses for clarity while preserving meaning.'
      + ' Return a JSON object with a string "text" containing the cleaned transcript. When useful, also include "Terminology correction" and "user intention".';
  }
  return system;
}
