/**
 * What every model call shares: one error type that names why a call failed,
 * a deadline joined with the caller's cancellation, and the short reason and
 * detail strings that history and /health report.
 *
 * The call itself is in openai-compat.js (the user's own API key).
 *
 * @module typeleast-service/llm
 */

/** Timers above this delay are clamped by the platform; keep well below it. */
const MAX_TIMER_DELAY_MS = 2147483647;

/** Longest failure detail kept for history and /health. */
const MAX_DETAIL_CHARS = 200;

/**
 * The one error a model call throws, naming why it failed.
 *
 * `kind` is one of: "timeout" (our deadline fired), "cancelled" (the caller
 * aborted), "max-tokens", "tool-calls", or "error" (anything the provider or
 * transport raised). The original throwable is kept as `cause`.
 */
export class ModelCallError extends Error {
  /**
   * @param {string} kind - failure class, see above.
   * @param {string} message - human-readable description.
   * @param {{code?: string, attempts?: number, elapsedMs?: number, cause?: unknown}} [details]
   */
  constructor(kind, message, details = {}) {
    super(message, details.cause === undefined ? undefined : { cause: details.cause });
    this.name = "ModelCallError";
    this.kind = kind;
    this.code = details.code ?? null;
    this.attempts = details.attempts ?? 1;
    this.elapsedMs = details.elapsedMs ?? null;
  }
}

/**
 * Abort after a delay, joined with the caller's signal.
 * @param {AbortSignal|undefined} caller - caller-owned cancellation.
 * @param {number} timeoutMs - maximum time for the whole call.
 * @returns {{signal: AbortSignal, dispose: () => void, timedOut: () => boolean}}
 */
export function createDeadline(caller, timeoutMs) {
  const controller = new AbortController();
  let timedOut = false;
  const timer = setTimeout(() => {
    timedOut = true;
    controller.abort(new ModelCallError("timeout", `deadline of ${timeoutMs} ms exceeded`));
  }, Math.min(timeoutMs, MAX_TIMER_DELAY_MS));
  const onCallerAbort = () => controller.abort(caller.reason);
  if (caller) {
    if (caller.aborted) onCallerAbort();
    else caller.addEventListener("abort", onCallerAbort, { once: true });
  }
  return {
    signal: controller.signal,
    timedOut: () => timedOut,
    dispose: () => {
      clearTimeout(timer);
      caller?.removeEventListener("abort", onCallerAbort);
    },
  };
}

/**
 * Name a failed model call the way history and /health report it.
 * @param {unknown} error - what the model call threw.
 * @returns {string} model-timeout, cancelled, model-max-tokens, model-tool-calls or model-error:<code>.
 */
export function failureReason(error) {
  if (!(error instanceof ModelCallError)) return `model-error:${errorCode(error) ?? "unknown"}`;
  switch (error.kind) {
    case "timeout":
      return "model-timeout";
    case "cancelled":
      return "cancelled";
    case "max-tokens":
      return "model-max-tokens";
    case "tool-calls":
      return "model-tool-calls";
    default:
      return `model-error:${sanitizeCode(error.code) ?? errorCode(error.cause) ?? "unknown"}`;
  }
}

/**
 * One short line describing a failure: the message, its causes when they add
 * anything, and for a model call how many attempts it took and for how long.
 * @param {unknown} error - the failure.
 * @returns {string} at most MAX_DETAIL_CHARS characters.
 */
export function failureDetail(error) {
  let text = messageOf(error).replace(/^(?:voice-polish|typeleast): /, "");
  // fetch() nests the socket error two levels down ("fetch failed" -> cause).
  let cause = error && typeof error === "object" ? error.cause : undefined;
  for (let depth = 0; depth < 3 && cause !== undefined && cause !== null; depth += 1) {
    const causeText = messageOf(cause).replace(/^(?:voice-polish|typeleast): /, "");
    if (causeText.length > 0 && !text.includes(causeText)) text += `: ${causeText}`;
    cause = typeof cause === "object" ? cause.cause : undefined;
  }
  let suffix = "";
  if (error instanceof ModelCallError) {
    const facts = [];
    if (error.attempts > 1) facts.push(`${error.attempts} attempts`);
    if (typeof error.elapsedMs === "number") facts.push(`${error.elapsedMs} ms`);
    if (facts.length > 0) suffix = ` (${facts.join(", ")})`;
  }
  const room = MAX_DETAIL_CHARS - suffix.length;
  if (text.length > room) text = text.slice(0, room - 1) + "…";
  return text + suffix;
}

/** The most specific machine-readable code a throwable carries, if any. */
function errorCode(error) {
  if (error === null || typeof error !== "object") return null;
  const candidates = [
    error.code,
    error.cause?.code,
    typeof error.status === "number" ? `http-${error.status}` : undefined,
    typeof error.statusCode === "number" ? `http-${error.statusCode}` : undefined,
    error.name !== "Error" ? error.name : undefined,
  ];
  for (const candidate of candidates) {
    const code = sanitizeCode(candidate);
    if (code !== null) return code;
  }
  return null;
}

/** Keep a code safe to embed in a reason string. */
function sanitizeCode(value) {
  if (value === undefined || value === null) return null;
  const code = String(value).replace(/[^A-Za-z0-9_.-]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 48);
  return code.length > 0 ? code : null;
}

/** Narrow an unknown throwable to a printable message. */
function messageOf(error) {
  if (error instanceof Error) return error.message;
  if (error && typeof error === "object" && typeof error.message === "string") return error.message;
  return String(error);
}
