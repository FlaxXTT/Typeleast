/**
 * Context assembly for one dictation.
 *
 * The feature's premise is that corrections come from context rather than from
 * a single isolated sentence, so this module gathers three things: the recent
 * conversation, the speaker's own recent dictations, and the spelling
 * dictionary — then bounds the total so the polishing call stays fast.
 *
 * @module dsh-voice-polish/context
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

/** The DSH app's own bundle id: its chat history is only relevant when dictating into it. */
export const DSH_BUNDLE_ID = "com.deepseek.dsh";

/**
 * Whether recent DSH conversation is relevant to this dictation. It is when the
 * text is going into DSH itself (or the caller is DSH's own button, which sends no
 * app); for Mail, WeChat or an editor it is noise that misleads the correction.
 * @param {string|null|undefined} appHint - destination bundle id.
 * @returns {boolean} whether to include conversation context.
 */
export function wantsConversation(appHint) {
  return !appHint || appHint === DSH_BUNDLE_ID;
}

/**
 * Flatten one DSH message into plain text, or null when it carries none.
 * @param {object} message - a session message ({ role, content }).
 * @returns {string|null} the text blocks joined, or null.
 */
function messageText(message) {
  if (message === null || typeof message !== "object") return null;
  if (message.role !== "user" && message.role !== "assistant") return null;
  const blocks = Array.isArray(message.content) ? message.content : [];
  const parts = [];
  for (const block of blocks) {
    if (block?.type === "text" && typeof block.text === "string" && block.text.trim().length > 0) parts.push(block.text.trim());
  }
  return parts.length === 0 ? null : parts.join(" ");
}

/**
 * Collect the most recent conversation turns within a character budget.
 * @param {object} options - session lookup, budget and cancellation.
 * @returns {Array<{role: string, text: string}>} oldest-to-newest turns.
 */
export function conversationContext(options) {
  const { ctx, sessionId, turns, charBudget, redact } = options;
  const session = resolveSession(ctx, sessionId);
  if (!session) return [];
  let messages = [];
  try {
    messages = typeof session.deriveMessages === "function" ? session.deriveMessages() : [];
  } catch {
    return [];
  }
  const collected = [];
  let used = 0;
  for (let index = messages.length - 1; index >= 0 && collected.length < turns; index -= 1) {
    const text = messageText(messages[index]);
    if (text === null) continue;
    const bounded = text.length > charBudget ? text.slice(-charBudget) : text;
    if (used + bounded.length > charBudget && collected.length > 0) break;
    used += bounded.length;
    collected.push({ role: messages[index].role, text: redact ? redactSecrets(bounded) : bounded });
  }
  return collected.reverse();
}

/**
 * Find one session object across the shapes DSH can expose.
 * @param {object} ctx - plugin context.
 * @param {string|undefined} sessionId - hint from the caller.
 * @returns {object|null} a Session-like object exposing deriveMessages().
 */
export function resolveSession(ctx, sessionId) {
  try {
    if (sessionId && typeof ctx.sessions?.get === "function") {
      const session = ctx.sessions.get(sessionId);
      if (session) return session;
    }
    const initiator = ctx.agents?.currentInitiator?.();
    if (initiator?.session) return initiator.session;
    if (typeof ctx.sessions?.list === "function") {
      const all = ctx.sessions.list() ?? [];
      if (all.length > 0) return all[all.length - 1];
    }
  } catch {
    // Context is best-effort: a missing session must never fail a dictation.
  }
  return null;
}

/**
 * Turn stored history entries into short context pairs.
 *
 * Input is the order History.recent() returns (newest first, because that is
 * what a menu renders); the output is chronological, matching how a
 * conversation is supplied to a model.
 *
 * @param {Array<object>} entries - newest-first history entries.
 * @param {object} options - shaping options.
 * @returns {Array<{raw: string, cleaned: string}>} oldest-to-newest pairs.
 */
export function dictationContext(entries, options = {}) {
  const { redact = true, maxChars = 400 } = options;
  const maxEntries = options.maxEntries ?? 12;

  // This function is order-preserving: whatever order the caller supplies is the
  // order it returns. History.recent() supplies newest-first, and the polish
  // prompt presents that list newest-first, so the model sees "the last few
  // things the speaker said" without a hidden reversal.
  //
  // Entries with no transcript are dropped: there is nothing to compare against.
  const pairs = [];
  for (const entry of entries) {
    const raw = String(entry.raw ?? "").trim();
    if (raw.length === 0) continue;
    const cleaned = String(entry.text ?? "").trim();
    pairs.push({
      raw: redact ? redactSecrets(raw) : raw,
      cleaned: redact ? redactSecrets(cleaned) : cleaned,
    });
    if (pairs.length >= maxEntries) break;
  }

  // Trim from the END while the budget is exceeded, so the most recent pairs
  // survive. A single pair is always kept: an empty context is less useful than
  // one oversized one.
  let total = pairs.reduce((sum, pair) => sum + pair.raw.length + pair.cleaned.length, 0);
  while (pairs.length > 1 && total > maxChars) {
    const removed = pairs.pop();
    total -= removed.raw.length + removed.cleaned.length;
  }
  return pairs;
}
