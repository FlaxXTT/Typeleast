import { readFileSync } from "node:fs";

/** Dictation cleanup: the maintainer's prompt, kept verbatim in cleanup.md. */
export const CLEANUP_PROMPT = readFileSync(new URL("./cleanup.md", import.meta.url), "utf8").trim();

/** Longest learned description of the user's work, in characters. */
export const PROFILE_LIMIT = 1000;

/** The prompt with the learned description, if any, at the end of the # Mission paragraph. */
export function cleanupSystemPrompt(profile = "") {
  const description = Array.from(String(profile ?? "").replace(/\s+/gu, " ").trim()).slice(0, PROFILE_LIMIT).join("");
  if (!description) return CLEANUP_PROMPT;
  const mission = CLEANUP_PROMPT.indexOf("# Mission");
  const end = CLEANUP_PROMPT.indexOf("\n\n", mission);
  if (mission < 0 || end < 0) return CLEANUP_PROMPT;
  return CLEANUP_PROMPT.slice(0, end) + "\nUser background (learned from earlier dictations): " + description + CLEANUP_PROMPT.slice(end);
}
