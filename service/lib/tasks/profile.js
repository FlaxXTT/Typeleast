/**
 * The description of the user's work, learned from the corrections and intentions in the app's
 * history. The app asks once when it starts and keeps the answer.
 *
 * @module typeleast-service/tasks/profile
 */
import { normalizeRoute } from "../openai-compat.js";
import { PROFILE_PROMPT, profileMessage, readProfile } from "../prompts/profile.js";

/**
 * @param {object} request - the route and the history items.
 * @param {(options: object) => Promise<{text: string}>} complete - one model call.
 * @param {(text: string) => string} redact - redaction for what leaves the machine.
 * @returns {Promise<{profile: string}>} at most PROFILE_LIMIT characters, possibly empty.
 */
export async function buildProfile({ llm, items, signal }, complete, redact) {
  const route = llm ? normalizeRoute(llm) : null;
  if (!route) throw Object.assign(new Error("model route required"), { code: "no-api-key" });
  const message = profileMessage(items);
  if (!message) return { profile: "" };
  const result = await complete({ route, system: PROFILE_PROMPT, user: redact(message),
    maxTokens: 1200, temperature: 0.2, timeoutMs: 60000, signal });
  return { profile: readProfile(result.text) };
}
