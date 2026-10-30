/**
 * Parse a polishing reply into insertable text.
 *
 * The cleanup prompt's examples answer with
 * `{ "status": "success", "Terminology correction": [...], "user intention": "...", "text": "..." }`;
 * "ok" and "uncertain" are accepted too. Only `text` is inserted; the corrections and the
 * intention go to the app's history. A model does not
 * always comply: it may fence the JSON, add a sentence before it, or ignore the
 * schema entirely. None of those may end up in the user's document — a stray
 * brace or a duplicated answer is worse than falling back to the raw transcript.
 *
 * The parser therefore tries, in order: strict JSON, the `text` field recovered
 * from a malformed body, and finally treating the whole reply as plain text —
 * but only when the reply does not look like JSON at all.
 *
 * @module typeleast-service/parse-output
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

/** Bounded corrections and intention from a reply, for the app's history. */
function learned(parsed) {
  const list = parsed["Terminology correction"] ?? parsed.corrections;
  const corrections = (Array.isArray(list) ? list : []).slice(0, 40).flatMap((item) => {
    const from = typeof item?.asr_error === "string" ? item.asr_error.trim().slice(0, 120) : "";
    const to = typeof item?.corrected_term === "string" ? item.corrected_term.trim().slice(0, 120) : "";
    const why = typeof item?.reason === "string" ? item.reason.trim().slice(0, 300) : "";
    return from && to ? [{ from, to, ...(why ? { reason: why } : {}) }] : [];
  });
  const intention = parsed["user intention"] ?? parsed.intention;
  return {
    ...(corrections.length ? { corrections } : {}),
    ...(typeof intention === "string" && intention.trim() ? { intention: intention.trim().slice(0, 2000) } : {}),
  };
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
      if (status !== undefined && !["ok", "uncertain", "success"].includes(status)) {
        // The status is the model's own text and may repeat what was dictated: it never
        // goes into the failure code, which reaches the logs, /health and history.
        return { ok: false, text: "", reason, mode: "json", failure: "unexpected-status" };
      }
      if (typeof parsed.text === "string") {
        const text = parsed.text.trim();
        if (text.length === 0) return { ok: false, text: "", reason, mode: "json", failure: "empty-text" };
        return { ok: true, text, reason, mode: "json", ...learned(parsed) };
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
