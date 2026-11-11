/**
 * A model reached with the user's own API key, over the OpenAI-compatible
 * chat-completions protocol (DeepSeek official API, Zhipu, Moonshot, Qwen,
 * OpenRouter, OpenAI, or a local server such as Ollama).
 *
 * The app keeps the key in the system's credential store (the macOS Keychain,
 * the Windows Credential Manager) and sends the route with each dictation
 * (base64 JSON in `x-voice-llm`, or `llm` in a /polish body). This module
 * never stores, logs or echoes the key: it exists only for the one
 * outgoing request, and error messages are built without it.
 *
 * @module typeleast-service/openai-compat
 */
import { createDeadline, ModelCallError } from "./llm.js";

/** Longest accepted key, model id and base URL. */
const LIMITS = { apiKey: 512, model: 200, baseURL: 300 };

/**
 * Validate a route object: {baseURL, model, apiKey}.
 *
 * https is required except for loopback hosts, so a key can never travel in
 * clear text over a network. Anything malformed yields null, and the caller
 * gets the raw transcript (reason no-api-key).
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
 * test budget on thinking and every test failed with "token limit". Cleanup needs
 * no reasoning, so it is switched off where the provider documents a switch.
 * Providers not listed get nothing extra.
 * @param {string} host - the route's host.
 * @returns {object} extra body fields.
 */
export function noThinkingFields(host, model = "") {
  const name = String(host ?? "").toLowerCase();
  if (isDeepSeekHost(name)) return { thinking: { type: "disabled" } };
  // These official GLM models require thinking and reject disabled mode.
  if (name === "open.bigmodel.cn" && String(model).toLowerCase().startsWith("glm-5.3-flash")) return {};
  if (name === "open.bigmodel.cn" || name.endsWith(".bigmodel.cn")) return { thinking: { type: "disabled" } };
  if (name.endsWith("dashscope.aliyuncs.com")) return { enable_thinking: false };
  return {};
}

function isDeepSeekHost(host) {
  const name = String(host ?? "").toLowerCase();
  return name === "api.deepseek.com" || name.endsWith(".deepseek.com");
}

/** Provider/model combinations that accepted a request only without the thinking switch. */
const thinkingSwitchRejected = new Set();

/** Inspect only a bounded structured error code; never retain provider response text. */
async function contextLimit(response) {
  if (response.status !== 400 || typeof response.body?.getReader !== 'function') return false;
  const reader = response.body.getReader();
  const chunks = []; let size = 0;
  try {
    for (;;) {
      const {done,value} = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > 8192) return false;
      chunks.push(Buffer.from(value));
    }
    const error = JSON.parse(Buffer.concat(chunks).toString('utf8'))?.error;
    return ['context_length_exceeded','context_window_exceeded','input_too_long'].includes(error?.code);
  } catch { return false; }
  finally { await reader.cancel().catch(() => {}); }
}

/** A label for history and /health that identifies the route without the key. */
export function routeLabel(route) {
  return `custom:${route.host}`;
}

/**
 * One chat completion. Retries once for network errors, 429 and 5xx.
 * @param {object} options - route, prompts, budget, cancellation, and fetch for tests.
 * @returns {Promise<{text: string, attempts: number, usage: object|undefined}>}
 * @throws {ModelCallError} with kind timeout, cancelled, max-tokens, tool-calls or error.
 */
export async function completeOpenAI(options) {
  const { route, system, user, maxTokens, temperature, timeoutMs, signal, retryBudget, fetchImpl = globalThis.fetch } = options;
  const maxTransportAttempts = options.maxTransportAttempts === 1 ? 1 : 2;
  const started = Date.now();
  let lastError;
  const modelName = String(route.model ?? "").toLowerCase();
  const openAIQuick = route.host === "api.openai.com" && ["gpt-6-luna", "gpt-6.1-terra"].includes(modelName);
  const kimiK3 = route.host === "api.moonshot.cn" && /^kimi-k3(?:[.-]|$)/u.test(modelName);
  const thinkingKey = `${route.host}\u0000${route.model}`;
  // DeepSeek explicitly supports this switch; dropping it enables thinking by default.
  let extra = !isDeepSeekHost(route.host) && thinkingSwitchRejected.has(thinkingKey) ? {} : noThinkingFields(route.host, route.model);
  let triedWithoutThinkingSwitch = false;
  let budget = maxTokens;
  let widened = false;
  for (let attempt = 1; attempt <= maxTransportAttempts; attempt += 1) {
    retryBudget?.assertTime();
    const deadline = createDeadline(signal, Math.min(timeoutMs, retryBudget?.remainingMs() ?? timeoutMs));
    try {
      const response = await fetchImpl(`${route.baseURL}/chat/completions`, {
        method: "POST",
        redirect: "error",
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
          ...(budget === undefined ? {} : openAIQuick ? { max_completion_tokens: budget } : { max_tokens: budget }),
          ...(temperature === undefined || kimiK3 ? {} : { temperature }),
          ...(openAIQuick ? { reasoning_effort: "none" } : kimiK3 ? { reasoning_effort: "low" } : {}),
          ...extra,
          stream: false,
        }),
        signal: deadline.signal,
      });
      if (!response.ok) {
        if (await contextLimit(response)) throw new ModelCallError('error','provider context limit exceeded',{code:'CONTEXT_LIMIT'});
        // The body may echo request details; only the status is kept.
        await response.body?.cancel?.().catch?.(() => {});
        // Some compatible providers reject the switch. DeepSeek documents it,
        // so an unrelated 400 must never silently enable its thinking mode.
        if (response.status === 400 && Object.keys(extra).length > 0 && !isDeepSeekHost(route.host)) {
          if (retryBudget && !retryBudget.retry()) throw new ModelCallError("error", "provider rejected parameters", {code:"HTTP_400"});
          triedWithoutThinkingSwitch = true;
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
        if (retryBudget && !retryBudget.retry()) throw new ModelCallError("max-tokens", "model output hit its token limit");
        widened = true;
        budget = Math.max(budget, Math.min(8192, budget * 4));
        attempt -= 1;
        continue;
      }
      if (choice?.finish_reason === "length") {
        throw new ModelCallError("max-tokens", "model output hit its token limit", { attempts: attempt, elapsedMs: Date.now() - started });
      }
      if (choice?.finish_reason === "tool_calls") {
        throw new ModelCallError("tool-calls", "model unexpectedly requested a tool", { attempts: attempt, elapsedMs: Date.now() - started });
      }
      if (triedWithoutThinkingSwitch) thinkingSwitchRejected.add(thinkingKey);
      return { text, attempts: attempt, usage: body?.usage };
    } catch (error) {
      if (signal?.aborted) {
        throw new ModelCallError("cancelled", "caller cancelled", { attempts: attempt, elapsedMs: Date.now() - started, cause: error });
      }
      if (deadline.timedOut() && retryBudget && attempt < maxTransportAttempts && retryBudget.retry()) continue;
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
      if (attempt < maxTransportAttempts && retryable && (!retryBudget || retryBudget.retry())) {
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
