/**
 * Context for one dictation, and what must never leave the machine with it.
 *
 * The app sends the text around the cursor in the box being dictated into
 * (`x-voice-context`); it helps the model choose spellings and names. Before
 * anything reaches a model provider, credential-shaped strings are replaced.
 *
 * @module typeleast-service/context
 */

/** Patterns that must not reach a model provider. */
const SECRET_PATTERNS = [
  { pattern: /\bsk-[A-Za-z0-9_-]{12,}\b/g, replacement: "[redacted-key]" },
  { pattern: /\b(?:ghp|gho|ghu|github_pat)_[A-Za-z0-9_]{12,}\b/g, replacement: "[redacted-token]" },
  { pattern: /\bxox[baprs]-[A-Za-z0-9-]{8,}\b/g, replacement: "[redacted-token]" },
  { pattern: /\bBearer\s+[A-Za-z0-9._~+/-]{12,}=*/g, replacement: "Bearer [redacted]" },
  // Spoken credentials do not arrive in key=value form: dictation says
  // "my password is hunter2" or "the token is abc123". The keyword may also be
  // separated from the value ("the password for the wifi is ..."), so up to
  // three words may sit between them. Function words are excluded before AND
  // after the connector, because "the password field is on the left" is not a
  // credential and wrongly rewriting it would corrupt what the user said.
  { pattern: /\b((?:password|passwd|passcode|secret|api[-_]?key|access[-_]?token|refresh[-_]?token|auth[-_]?token)\b(?:(?!\b(?:on|in|at|for|from|to|of|the|a|an|is|are|was|were|again|before|after|and|or|but|that|this|it|my|your|our|their)\b)\s+\w+){0,3}\s*(?:(?:is|are|was|were)\s+|[:=]\s*))("(?:[^"]*)"|'(?:[^']*)'|(?!\b(?:on|in|at|for|from|to|of|the|a|an|again|before|after|and|or|but|is|are|was|were|left|right|here|there|not|no|still)\b)[^\s,.;!?]+)/gi, replacement: "$1[redacted]" },
  // A quoted value after a bare keyword is a secret even with no connector:
  // password "hunter2".
  { pattern: /\b((?:password|passwd|passcode|secret|api[-_]?key|token)\s*)("(?:[^"]*)"|'(?:[^']*)')/gi, replacement: "$1[redacted]" },
];

/**
 * Replace credential-shaped strings with placeholders.
 * @param {string} text - candidate text.
 * @returns {string} text safe to send to a provider.
 */
export function redactSecrets(text) {
  let out = String(text ?? "");
  for (const { pattern, replacement } of SECRET_PATTERNS) out = out.replace(pattern, replacement);
  return out;
}

/** Per-field ceilings for the target-field context, in characters. */
export const FIELD_CONTEXT_LIMITS = { before: 800, selected: 400, after: 300, windowTitle: 200 };

/**
 * Decode the `x-voice-context` header: base64 of a JSON object
 * {before, selected, after, windowTitle} describing the text box being dictated into.
 * Anything malformed is dropped rather than failing the dictation.
 * @param {unknown} header - the raw header value.
 * @returns {{before: string, selected: string, after: string, windowTitle: string}|null}
 */
export function parseFieldContext(header) {
  if (typeof header !== "string" || header.length === 0 || header.length > 16 * 1024) return null;
  try {
    return normalizeFieldContext(JSON.parse(Buffer.from(header, "base64").toString("utf8")));
  } catch {
    return null;
  }
}

/**
 * Bound and type-check a field context object; null when it carries no text.
 * Text before the cursor keeps its END (nearest the cursor), the rest their start.
 * @param {unknown} value - candidate object.
 * @returns {{before: string, selected: string, after: string, windowTitle: string}|null}
 */
export function normalizeFieldContext(value) {
  if (value === null || typeof value !== "object") return null;
  const pick = (key) => (typeof value[key] === "string" ? value[key] : "");
  const before = pick("before");
  const out = {
    before: before.length > FIELD_CONTEXT_LIMITS.before ? before.slice(-FIELD_CONTEXT_LIMITS.before) : before,
    selected: pick("selected").slice(0, FIELD_CONTEXT_LIMITS.selected),
    after: pick("after").slice(0, FIELD_CONTEXT_LIMITS.after),
    windowTitle: pick("windowTitle").slice(0, FIELD_CONTEXT_LIMITS.windowTitle),
  };
  return Object.values(out).some((text) => text.trim().length > 0) ? out : null;
}

/**
 * Redact every string of a field context.
 * @param {object|null} context - normalised field context.
 * @param {boolean} redact - whether redaction is enabled.
 * @returns {object|null} the context safe to send to a provider.
 */
export function redactFieldContext(context, redact) {
  if (!context || !redact) return context ?? null;
  return Object.fromEntries(Object.entries(context).map(([key, text]) => [key, redactSecrets(text)]));
}
