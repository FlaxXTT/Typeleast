/**
 * Parse a polishing reply into insertable text.
 *
 * The vendored erduo prompt asks the model to answer with
 * `{ "status": "ok", "text": "...", "reason": "..." }`, but a model does not
 * always comply: it may fence the JSON, add a sentence before it, or ignore the
 * schema entirely. None of those may end up in the user's document — a stray
 * brace or a duplicated answer is worse than falling back to the raw transcript.
 *
 * The parser therefore tries, in order: strict JSON, the `text` field recovered
 * from a malformed body, and finally treating the whole reply as plain text —
 * but only when the reply does not look like JSON at all.
 *
 * @module dsh-voice-polish/parse-output
 */

/** A reply that still looks like JSON after every recovery attempt. */
function looksLikeJson(text) {
  return /^\s*[{[][\s\S]*[}\]]\s*$/u.test(text) || /"status"\s*:/u.test(text) || /"text"\s*:/u.test(text);
}

/** Remove one surrounding markdown fence, if present. */
function stripFence(text) {
  const match = text.match(/^\u0060{3}[A-Za-z0-9_-]*\r?\n([\s\S]*?)\r?\n?\u0060{3}\s*$/u);
  return match ? match[1].trim() : text;
}

/** Decode a JSON string literal captured by regex. */
function decodeJsonString(literal) {
  try {
    return JSON.parse('"' + literal + '"');
  } catch {
    return literal.replace(/\\n/gu, "\n").replace(/\\"/gu, '"');
  }
}

/**
 * Parse one model reply.
 * @param {string} raw - the model's reply.
 * @returns {{ok: boolean, text: string, reason: string|null, mode: "json"|"regex"|"plain"|"none", failure?: string}}
 */
export function parsePolishOutput(raw) {
  const original = String(raw ?? "").trim();
  const stripped = stripFence(original);
  if (stripped.length === 0) return { ok: false, text: "", reason: null, mode: "none", failure: "empty" };

  // 1. Strict JSON.
  try {
    const parsed = JSON.parse(stripped);
    if (parsed !== null && typeof parsed === "object" && !Array.isArray(parsed)) {
      const status = typeof parsed.status === "string" ? parsed.status : undefined;
      const reason = typeof parsed.reason === "string" ? parsed.reason : null;
      if (status !== undefined && status !== "ok") {
        return { ok: false, text: "", reason, mode: "json", failure: `status:${status}` };
      }
      if (typeof parsed.text === "string") {
        const text = parsed.text.trim();
        if (text.length === 0) return { ok: false, text: "", reason, mode: "json", failure: "empty-text" };
        return { ok: true, text, reason, mode: "json" };
      }
      // An object without a text field is not insertable.
      return { ok: false, text: "", reason, mode: "json", failure: "no-text-field" };
    }
  } catch {
    // Fall through to the recovery paths.
  }

  // 2. Recover a text field from a malformed body.
  const field = stripped.match(/"text"\s*:\s*"((?:[^"\\]|\\.)*)"/u);
  if (field !== null) {
    const text = decodeJsonString(field[1]).trim();
    const reasonField = stripped.match(/"reason"\s*:\s*"((?:[^"\\]|\\.)*)"/u);
    const reason = reasonField === null ? null : decodeJsonString(reasonField[1]);
    if (text.length > 0) return { ok: true, text, reason, mode: "regex" };
    return { ok: false, text: "", reason, mode: "regex", failure: "empty-text" };
  }

  // 3. Plain text, but never JSON braces.
  if (looksLikeJson(stripped)) {
    return { ok: false, text: "", reason: null, mode: "none", failure: "unparsable-json" };
  }
  return { ok: true, text: stripped, reason: null, mode: "plain" };
}
