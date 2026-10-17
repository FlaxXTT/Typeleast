/**
 * A model reached with the user's own API key, over the OpenAI-compatible
 * chat-completions protocol (DeepSeek official API, Zhipu, Moonshot, Qwen,
 * OpenRouter, OpenAI, or a local server such as Ollama).
 *
 * The native app keeps the key in the macOS Keychain and sends the route with
 * each dictation (base64 JSON in `x-voice-llm`, or `llm` in a /polish body).
 * This module never stores, logs or echoes the key: it exists only for the one
 * outgoing request, and error messages are built without it.
 *
 * @module dsh-voice-polish/openai-compat
 */
import { createDeadline, ModelCallError } from "./llm.js";

/** Longest accepted key, model id and base URL. */
const LIMITS = { apiKey: 512, model: 200, baseURL: 300 };

/**
 * Validate a route object: {baseURL, model, apiKey}.
 *
 * https is required except for loopback hosts, so a key can never travel in
 * clear text over a network. Anything malformed yields null, and the caller
 * falls back to the configured DSH route.
 *
 * @param {unknown} value - candidate route.
 * @returns {{baseURL: string, model: string, apiKey: string, host: string}|null}
 */
export function normalizeRoute(value) {
  if (value === null || typeof value !== "object") return null;
  const baseURL = typeof value.baseURL === "string" ? value.baseURL.trim().replace(/\/+$/, "") : "";
  const model = typeof value.model === "string" ? value.model.trim() : "";
  const apiKey = typeof value.apiKey === "string" ? value.apiKey.trim() : "";
  if (!baseURL || !model || baseURL.length > LIMITS.baseURL || model.length > LIMITS.model || apiKey.length > LIMITS.apiKey) return null;
  let url;
  try {
    url = new URL(baseURL);
  } catch {
    return null;
  }
  const loopback = ["127.0.0.1", "localhost", "[::1]", "::1"].includes(url.hostname);
  if (url.protocol !== "https:" && !(url.protocol === "http:" && loopback)) return null;
  if (url.username || url.password) return null;
  // A remote service needs a key; a local server may not.
  if (!apiKey && !loopback) return null;
  return { baseURL, model, apiKey, host: url.host };
}

/**
 * Decode the `x-voice-llm` header (base64 JSON). Malformed means null.
 * @param {unknown} header - raw header value.
 * @returns {ReturnType<typeof normalizeRoute>}
 */
export function parseRouteHeader(header) {
  if (typeof header !== "string" || header.length === 0 || header.length > 4096) return null;
  try {
    return normalizeRoute(JSON.parse(Buffer.from(header, "base64").toString("utf8")));
  } catch {
    return null;
  }
}

/**
 * Provider-specific switch that turns "thinking" off.
 *
 * Reasoning models think before answering and their thinking tokens count
 * against max_tokens: on DeepSeek's official API, deepseek-flash spent a 16-token
 * test budget on thinking and every test failed with "token limit" (the same
 * failure the DSH route had before reasoningEffort was set to off). Cleanup needs
 * no reasoning, so it is switched off where the provider documents a switch.
 * Providers not listed get nothing extra.
 * @param {string} host - the route's host.
 * @returns {object} extra body fields.
 */
export function noThinkingFields(host) {
  const name = String(host ?? "").toLowerCase();
  if (name === "api.deepseek.com" || name.endsWith(".deepseek.com")) return { thinking: { type: "disabled" } };
  if (name === "open.bigmodel.cn" || name.endsWith(".bigmodel.cn")) return { thinking: { type: "disabled" } };
  if (name.endsWith("dashscope.aliyuncs.com")) return { enable_thinking: false };
  return {};
}

/** Hosts that rejected the thinking switch once; it is not sent to them again. */
const thinkingSwitchRejected = new Set();

/** A label for history and /health that identifies the route without the key. */
export function routeLabel(route) {
  return `custom:${route.host}`;
}

/**
 * One chat completion. Retries once for network errors, 429 and 5xx.
 * @param {object} options - route, prompts, budget, cancellation, and fetch for tests.
 * @returns {Promise<{text: string, attempts: number, usage: object|undefined}>}
 * @throws {ModelCallError} classified like the DSH route's failures.
 */
export async function completeOpenAI(options) {
  const { route, system, user, maxTokens, temperature, timeoutMs, signal, fetchImpl = globalThis.fetch } = options;
  const started = Date.now();
  let lastError;
  let extra = thinkingSwitchRejected.has(route.host) ? {} : noThinkingFields(route.host);
  let budget = maxTokens;
  let widened = false;
  for (let attempt = 1; attempt <= 2; attempt += 1) {
    const deadline = createDeadline(signal, timeoutMs);
    try {
      const response = await fetchImpl(`${route.baseURL}/chat/completions`, {
        method: "POST",
        headers: {
          "content-type": "application/json",
          ...(route.apiKey ? { authorization: `Bearer ${route.apiKey}` } : {}),
        },
        body: JSON.stringify({
          model: route.model,
          messages: [
            { role: "system", content: system },
            { role: "user", content: user },
          ],
          ...(budget === undefined ? {} : { max_tokens: budget }),
          ...(temperature === undefined ? {} : { temperature }),
          ...extra,
          stream: false,
        }),
        signal: deadline.signal,
      });
      if (!response.ok) {
        // The body may echo request details; only the status is kept.
        await response.body?.cancel?.().catch?.(() => {});
        // A provider that does not know the thinking switch may answer 400:
        // retry once without it, and do not send it to that host again.
        if (response.status === 400 && Object.keys(extra).length > 0) {
          thinkingSwitchRejected.add(route.host);
          extra = {};
          attempt -= 1;
          continue;
        }
        throw new ModelCallError("error", `${route.host} answered HTTP ${response.status}`, {
          code: `HTTP_${response.status}`,
          attempts: attempt,
          elapsedMs: Date.now() - started,
        });
      }
      const body = await response.json();
      const choice = Array.isArray(body?.choices) ? body.choices[0] : undefined;
      const text = typeof choice?.message?.content === "string" ? choice.message.content : "";
      // All of the budget went to thinking (the switch was ignored): one retry
      // with room to answer beats falling back to the raw transcript.
      if (choice?.finish_reason === "length" && text.trim() === "" && !widened && budget !== undefined) {
        widened = true;
        budget = Math.min(4096, budget * 4);
        attempt -= 1;
        continue;
      }
      if (choice?.finish_reason === "length") {
        throw new ModelCallError("max-tokens", "model output hit its token limit", { attempts: attempt, elapsedMs: Date.now() - started });
      }
      if (choice?.finish_reason === "tool_calls") {
        throw new ModelCallError("tool-calls", "model unexpectedly requested a tool", { attempts: attempt, elapsedMs: Date.now() - started });
      }
      return { text, attempts: attempt, usage: body?.usage };
    } catch (error) {
      if (signal?.aborted) {
        throw new ModelCallError("cancelled", "caller cancelled", { attempts: attempt, elapsedMs: Date.now() - started, cause: error });
      }
      if (deadline.timedOut()) {
        throw new ModelCallError("timeout", `no answer from ${route.host} within ${timeoutMs} ms`, { attempts: attempt, elapsedMs: Date.now() - started });
      }
      const failure = error instanceof ModelCallError
        ? error
        : new ModelCallError("error", `${route.host} unreachable: ${error instanceof Error ? error.message : String(error)}`, {
            code: "NETWORK",
            attempts: attempt,
            elapsedMs: Date.now() - started,
          });
      lastError = failure;
      const status = Number(String(failure.code ?? "").replace("HTTP_", ""));
      const retryable = failure.kind === "error" && (failure.code === "NETWORK" || status === 429 || status >= 500);
      if (attempt === 1 && retryable) {
        await new Promise((resolve) => setTimeout(resolve, 400));
        continue;
      }
      throw failure;
    } finally {
      deadline.dispose();
    }
  }
  throw lastError;
}
