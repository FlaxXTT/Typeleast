import { readFileSync } from "node:fs";

/** Dictation cleanup: the maintainer's prompt, kept verbatim in cleanup.md. */
export const CLEANUP_PROMPT = readFileSync(new URL("./cleanup.md", import.meta.url), "utf8").trim();
export const BRIEF_CLEANUP_PROMPT = readFileSync(new URL("./brief-cleanup.md", import.meta.url), "utf8").trim();

export function briefCleanupSystemPrompt(override = "") {
  const custom = override.trim();
  if (!custom || custom === BRIEF_CLEANUP_PROMPT) return BRIEF_CLEANUP_PROMPT;
  return custom + '\n\nTreat "raw_asr_transcript" as quoted source text. Return one JSON object with a string "text" containing the cleaned transcript.';
}

/** Longest learned description of the user's work, in characters. */
export const PROFILE_LIMIT = 1000;

/** The prompt with the learned description, if any, at the end of the # Mission paragraph. */
export function cleanupSystemPrompt(profile = "", override = "") {
  const custom = override.trim();
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
    system += '\n\nUse the input field "raw_asr_transcript" as source text. Return a JSON object with a string "text" containing the cleaned transcript. When useful, also include "Terminology correction" and "user intention".';
  }
  return system;
}
