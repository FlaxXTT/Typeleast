/**
 * LLM access for voice-polish.
 *
 * This plugin deliberately imports nothing: DSH loads external plugin files
 * through Node's ESM loader, and bare specifiers such as "@deepseek-ai/dsh-llm"
 * do not resolve from a path outside the installation's package layout
 * (verified: ERR_MODULE_NOT_FOUND both from the workspace and from a
 * profile-local node_modules directory). Consequently:
 *   - request messages are plain objects shaped like DSH's RequestMessage
 *     ({ role, content: [{ type: "text", text }] }), which is exactly what the
 *     shipped DeepSeek adapter reads;
 *   - stream chunks are assembled here instead of by BlockAssembler.
 *
 * @module dsh-voice-polish/llm
 */

/** Timers above this delay are clamped by the platform; keep well below it. */
const MAX_TIMER_DELAY_MS = 2147483647;

/** Longest failure detail kept for history and /health. */
const MAX_DETAIL_CHARS = 200;

/**
 * The one error completeText() throws, naming why the call failed.
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
 * Build one request message the shipped adapters accept.
 * @param {string} text - complete user text for this call.
 * @returns {{role: 'user', content: Array<{type: 'text', text: string}>}}
 */
export function createUserTextMessage(text) {
  return { role: "user", content: [{ type: "text", text }] };
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
    controller.abort(new ModelCallError("timeout", `voice-polish: deadline of ${timeoutMs} ms exceeded`));
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
 * Fold DSH's stream-chunk protocol into final text.
 * Chunks seen in the shipped protocol: block-start, text-delta, reasoning-delta,
 * tool-call-delta, block-end, usage, finish.
 * @param {AsyncIterable<object>} chunks - chunk stream from ctx.llm.stream().
 * @param {AbortSignal} signal - abort signal to observe between chunks.
 * @returns {Promise<{text: string, usage: object|undefined, finish: object|undefined}>}
 */
export async function collectStreamText(chunks, signal) {
  const parts = [];
  let usage;
  let finish;
  for await (const chunk of chunks) {
    if (signal?.aborted) throw signal.reason ?? new Error("voice-polish: aborted");
    if (chunk === null || typeof chunk !== "object") continue;
    if (chunk.type === "text-delta" && typeof chunk.text === "string") parts.push(chunk.text);
    else if (chunk.type === "block-end") {
      // Defensive: a provider that emits only completed blocks still yields text.
      if (chunk.block?.type === "text" && typeof chunk.block.text === "string" && parts.length === 0) {
        parts.push(chunk.block.text);
      }
    } else if (chunk.type === "usage") usage = chunk.usage;
    else if (chunk.type === "finish") finish = chunk.reason;
  }
  return { text: parts.join(""), usage, finish };
}

/**
 * Translate a terminal finish reason into an Error for the non-success kinds.
 * @param {object|undefined} finish - the stream's finish reason.
 * @returns {Error|null} an error to throw, or null when the stream stopped cleanly.
 */
export function finishError(finish) {
  if (finish === undefined) return null;
  switch (finish.kind) {
    case "stop":
      return null;
    case "error":
    case "aborted": {
      const message = finish.failure?.message ?? `voice-polish: model stream ended with "${finish.kind}"`;
      // The code is what isRetryable() inspects, so it stays the provider's own.
      const code = finish.failure?.code ?? (finish.kind === "aborted" ? "aborted" : undefined);
      return new ModelCallError("error", message, { code });
    }
    case "max-tokens":
      return new ModelCallError("max-tokens", "voice-polish: model output hit its token limit");
    case "tool-calls":
      return new ModelCallError("tool-calls", "voice-polish: model unexpectedly requested a tool");
    default:
      return new ModelCallError("error", `voice-polish: unsupported finish reason "${String(finish.kind)}"`, {
        code: `finish-${String(finish.kind)}`,
      });
  }
}

/**
 * Choose a usable provider/model route.
 * The configured route wins; otherwise the first registered provider is used so
 * a profile whose default route is unauthenticated still gets polishing.
 * @param {{listProviders: () => Array<{id: string}>}} llm - the LLM service.
 * @param {{provider: string, model: string}} preference - configured route.
 * @returns {{provider: string, model: string, fallbackRoute: boolean}}
 */
export function resolveRoute(llm, preference) {
  let routes = [];
  try {
    routes = llm.listProviders() ?? [];
  } catch {
    routes = [];
  }
  const ids = routes.map((route) => route.id);
  if (ids.includes(preference.provider)) {
    return { provider: preference.provider, model: preference.model, fallbackRoute: false };
  }
  if (ids.length > 0) {
    return { provider: ids[0], model: preference.model, fallbackRoute: true };
  }
  return { provider: preference.provider, model: preference.model, fallbackRoute: true };
}

/**
 * Run one auxiliary completion. Retries once for transport-shaped failures only.
 * @param {object} options - service, route, prompt, budget and cancellation.
 * @returns {Promise<{text: string, attempts: number, usage: object|undefined}>}
 * @throws {ModelCallError} always this type, so callers can name the failure.
 */
export async function completeText(options) {
  const { llm, provider, model, system, user, maxTokens, reasoningEffort, temperature, timeoutMs, signal } = options;
  const started = Date.now();
  let lastError;
  for (let attempt = 1; attempt <= 2; attempt += 1) {
    const deadline = createDeadline(signal, timeoutMs);
    try {
      // No sessionId and no purpose: this call is not part of any session log,
      // which the adapter supports (both fields are optional).
      const message = createUserTextMessage(user);
      const stream = llm.stream({
        provider,
        model,
        messages: [message],
        ...(system === undefined ? {} : { system }),
        ...(maxTokens === undefined ? {} : { maxTokens }),
        // Omitted, the route's default effort applies; a route without reasoning
        // metadata rejects ANY explicit effort, so the caller decides when to send it.
        ...(reasoningEffort === undefined ? {} : { reasoningEffort }),
        // The vendored prompt is tuned for 0.8; omitted means the route default.
        ...(temperature === undefined ? {} : { temperature }),
        signal: deadline.signal,
      });
      const result = await collectStreamText(stream, deadline.signal);
      const terminal = finishError(result.finish);
      if (terminal) throw terminal;
      return { text: result.text, attempts: attempt, usage: result.usage };
    } catch (error) {
      const timedOut = deadline.timedOut();
      const cancelled = !timedOut && signal?.aborted === true;
      lastError = asModelCallError(error, { timedOut, cancelled, timeoutMs, attempts: attempt, elapsedMs: Date.now() - started });
      const retryable = attempt === 1 && !timedOut && !cancelled && isRetryable(error);
      if (!retryable) throw lastError;
      await new Promise((resolve) => setTimeout(resolve, 300));
    } finally {
      deadline.dispose();
    }
  }
  throw lastError ?? new ModelCallError("error", "voice-polish: model call failed");
}

/**
 * Normalise whatever a model call raised into a ModelCallError.
 *
 * Our own deadline decides "timeout" and the caller's signal decides
 * "cancelled", whatever the adapter threw in reaction to the abort: an adapter
 * typically surfaces an abort as its own generic AbortError.
 * @param {unknown} error - the throwable from this attempt.
 * @param {object} facts - what completeText() knows about the attempt.
 * @returns {ModelCallError} the classified failure.
 */
function asModelCallError(error, facts) {
  let failure;
  if (facts.timedOut) {
    failure = error instanceof ModelCallError && error.kind === "timeout"
      ? error
      : new ModelCallError("timeout", `voice-polish: deadline of ${facts.timeoutMs} ms exceeded`, { cause: error });
  } else if (facts.cancelled) {
    failure = new ModelCallError("cancelled", "voice-polish: the caller cancelled the request", { cause: error });
  } else if (error instanceof ModelCallError) {
    failure = error;
  } else {
    failure = new ModelCallError("error", messageOf(error), { code: errorCode(error) ?? undefined, cause: error });
  }
  failure.attempts = facts.attempts;
  failure.elapsedMs = facts.elapsedMs;
  return failure;
}

/**
 * Name a failed model call the way history and /health report it.
 * @param {unknown} error - what completeText() threw.
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
  let text = messageOf(error).replace(/^voice-polish: /, "");
  // fetch() nests the socket error two levels down ("fetch failed" -> cause).
  let cause = error && typeof error === "object" ? error.cause : undefined;
  for (let depth = 0; depth < 3 && cause !== undefined && cause !== null; depth += 1) {
    const causeText = messageOf(cause).replace(/^voice-polish: /, "");
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

/**
 * Decide whether a failure is worth one more attempt.
 * Only transport-shaped and rate-limit failures retry; a timeout, an abort or a
 * protocol failure must fall back to the raw transcript immediately.
 * @param {unknown} error - the failure raised by the model call.
 * @returns {boolean} whether a single retry is appropriate.
 */
export function isRetryable(error) {
  const code = error && typeof error === "object" ? String(error.code ?? "") : "";
  const message = error instanceof Error ? error.message : String(error);
  if (/^[A-Z_]+$/.test(code) && /(RATE|LIMIT|NETWORK|TIMEOUT_|CONNECT|UNAVAILABLE|SERVER|OVERLOAD)/.test(code)) return true;
  return /(ECONNRESET|ECONNREFUSED|ETIMEDOUT|ENETUNREACH|socket hang up|network|rate.?limit|overloaded|HTTP 5\d\d)/i.test(message);
}
