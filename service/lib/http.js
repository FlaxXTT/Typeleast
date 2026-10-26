/**
 * Loopback HTTP surface for the dictation apps.
 *
 * The server listens on 127.0.0.1 only (server.js). On top of that:
 *   - the Host header must be loopback (a DNS-rebinding guard: a web page in a
 *     browser cannot reach this port under another name);
 *   - every request needs the private bearer token, compared in constant time;
 *   - bodies are bounded before they are buffered.
 *
 * @module typeleast-service/http
 */
import { createHmac } from "node:crypto";
import { authorize } from "./token.js";
import { WavError } from "./wav.js";
import { normalizeFieldContext, parseFieldContext } from "./context.js";
import { completeOpenAI, normalizeRoute, parseRouteHeader } from "./openai-compat.js";
import { learnedWord } from "./edit-correction.js";

export const ROUTE_PREFIX = "/api/voice-polish";
export const MAX_JSON_BYTES = 256 * 1024;
/** The app's dictionary, sent with each dictation ahead of the audio (2000 entries of up to 120 characters). */
export const MAX_DICTIONARY_BYTES = 1024 * 1024;

const LOOPBACK_HOSTS = new Set(["127.0.0.1", "localhost", "[::1]", "::1"]);

/** Reject requests whose Host header is not loopback. */
export function hostAllowed(req) {
  const header = req.headers?.host;
  if (typeof header !== "string" || header.length === 0) return false;
  const name = header.startsWith("[") ? header.slice(0, header.indexOf("]") + 1) : header.split(":")[0];
  return LOOPBACK_HOSTS.has(name.toLowerCase());
}

/** Write a JSON reply. */
function reply(res, status, body) {
  const json = JSON.stringify(body);
  res.writeHead(status, { "content-type": "application/json; charset=utf-8", "content-length": Buffer.byteLength(json) });
  res.end(json);
}

/** Buffer a request body with a hard ceiling. */
function readBody(req, limit) {
  return new Promise((resolve, reject) => {
    const declared = Number(req.headers["content-length"]);
    if (Number.isFinite(declared) && declared > limit) {
      const error = new Error("request body too large");
      error.status = 413;
      error.code = "payload-too-large";
      reject(error);
      return;
    }
    const chunks = [];
    let size = 0;
    req.on("data", (chunk) => {
      size += chunk.length;
      if (size > limit) {
        const error = new Error("request body too large");
        error.status = 413;
        error.code = "payload-too-large";
        req.destroy();
        reject(error);
        return;
      }
      chunks.push(chunk);
    });
    req.on("end", () => resolve(Buffer.concat(chunks)));
    req.on("error", reject);
  });
}

/** Translate a thrown value into an HTTP status and code. */
function classify(error) {
  if (error instanceof SyntaxError) return { status: 400, code: "invalid-json" };
  const code = error?.code ?? (error instanceof WavError ? "invalid-audio" : "error");
  switch (code) {
    case "payload-too-large":
      return { status: 413, code };
    case "invalid-model":
    case "invalid-local-model":
    case "invalid-language":
    case "invalid-prompt":
      return { status: 400, code };
    case "invalid-audio":
    case "audio-too-large":
      return { status: 400, code };
    case "model-busy":
    case "plugin-terms-limit":
    case "plugin-changed":
      return { status: 409, code };
    case "plugin-not-found":
      return { status: 404, code };
    case "plugins-unavailable":
      return { status: 503, code };
    case "beta-expired":
      return { status: 410, code };
    case "busy":
      return { status: 429, code };
    case "speech-not-ready":
      return { status: 503, code };
    default:
      return { status: 500, code };
  }
}

/** The HMAC answer to the app's challenge, or nothing when there is no key or no valid challenge. */
export function proofFor(proofKey, challenge) {
  if (!proofKey || typeof challenge !== "string" || !/^[0-9a-f]{32,128}$/.test(challenge)) return {};
  return { proof: createHmac("sha256", Buffer.from(proofKey, "hex")).update(challenge).digest("hex") };
}

/**
 * Build the request handler. Dependencies are injected so this module can be
 * exercised in tests without a network listener.
 * @param {object} options - service, token accessor and logger.
 * @returns {(req: object, res: object) => Promise<void>} the route handler.
 */
export function createHandler(options) {
  const { service, logger } = options;
  // Shared with the app that started this process (see bin/typeleast-service.mjs).
  const proofKey = typeof options.proofKey === "string" && options.proofKey.length > 0 ? options.proofKey : null;
  const currentToken = options.currentToken;

  return async function handle(req, res) {
    try {
      if (!hostAllowed(req)) {
        reply(res, 403, { error: "requests must address a loopback host", code: "forbidden-host" });
        return;
      }
      const token = await currentToken();
      if (!authorize(token, req.headers.authorization)) {
        reply(res, 401, { error: "missing or invalid bearer token", code: "unauthorized" });
        return;
      }
      const url = new URL(req.url ?? "/", "http://127.0.0.1");
      if (url.pathname !== ROUTE_PREFIX && !url.pathname.startsWith(ROUTE_PREFIX + "/")) {
        reply(res, 404, { error: `unknown endpoint ${url.pathname}`, code: "not-found" });
        return;
      }
      const route = url.pathname.slice(ROUTE_PREFIX.length) || "/";

      if (route === "/health" && req.method === "GET") {
        const state = service.snapshot();
        reply(res, 200, {
          ok: state.speech.ready,
          service: "typeleast",
          version: state.version,
          provider: state.provider,
          model: state.model,
          speech: state.speech,
          strength: state.strength,
          dictionarySize: state.dictionarySize,
          pending: state.pending,
          queue: state.queue,
          pid: process.pid,
          ...proofFor(proofKey, req.headers["x-typeleast-challenge"]),
          // Added fields only: the native client decodes the ones above. These
          // say why polishing fell back, which `ok` (recogniser readiness) does not.
          promptSource: state.promptSource,
          promptVersion: state.promptVersion,
          temperature: state.temperature,
          stats: state.stats,
          recentFailures: state.recentFailures,
        });
        return;
      }

      if (route === "/test-llm" && req.method === "POST") {
        // One tiny call to check a user-supplied route. Nothing is recorded in
        // history, and the key is never echoed back.
        const body = JSON.parse((await readBody(req, MAX_JSON_BYTES)).toString("utf8") || "{}");
        const llm = normalizeRoute(body.llm);
        if (!llm) {
          reply(res, 400, { ok: false, error: "base URL must be https (or http to this computer), and model and key are required", code: "invalid-route" });
          return;
        }
        const started = Date.now();
        try {
          const result = await completeOpenAI({
            route: llm,
            system: "Reply with exactly: OK",
            user: "ping",
            maxTokens: 64,
            timeoutMs: 20000,
          });
          reply(res, 200, { ok: true, ms: Date.now() - started, model: llm.model, sample: String(result.text).slice(0, 40) });
        } catch (error) {
          // A reply cut off at the token limit still proves the address, key and
          // model all work; the model just thinks before answering.
          if (error?.kind === "max-tokens") {
            reply(res, 200, { ok: true, ms: Date.now() - started, model: llm.model, code: "thinking", note: "model thinks before answering" });
            return;
          }
          reply(res, 200, { ok: false, ms: Date.now() - started, code: error?.code ?? error?.kind ?? "error", error: error instanceof Error ? error.message : String(error) });
        }
        return;
      }

      if (route === "/models" && req.method === "GET") {
        reply(res, 200, await service.recognizer.catalog());
        return;
      }
      if (['/models/local/inspect', '/models/local/register', '/models/local/remove', '/models/register-known'].includes(route) && req.method === 'POST') {
        const body = JSON.parse((await readBody(req, MAX_JSON_BYTES)).toString('utf8') || '{}');
        if (route === '/models/local/inspect') reply(res, 200, await service.recognizer.inspectLocal(body));
        else if (route === '/models/local/register') reply(res, 202, { ok: true, modelId: service.recognizer.registerLocal(body) });
        else {
          if (typeof body?.modelId !== 'string') throw Object.assign(new Error('invalid model id'), { code: 'invalid-model' });
          if (route === '/models/register-known') await service.recognizer.registerKnown(body.modelId);
          else await service.recognizer.removeLocal(body.modelId);
          reply(res, 200, { ok: true });
        }
        return;
      }
      if (["/models/download", "/models/active", "/models/download/cancel"].includes(route)
          && req.method === (route === "/models/active" ? "PUT" : "POST")) {
        const body = JSON.parse((await readBody(req, MAX_JSON_BYTES)).toString("utf8") || "{}");
        if (!body || Array.isArray(body) || typeof body !== "object") {
          reply(res, 400, { error: "model request must be an object", code: "invalid-model" }); return;
        }
        const modelId = body.modelId === undefined ? "sensevoice-small" : body.modelId;
        // An empty mirror means huggingface.co itself, even if the service started with HF_ENDPOINT:
        // clearing the setting takes effect without a restart. No field keeps the startup default.
        const endpoint = typeof body.endpoint !== "string" ? undefined
          : body.endpoint.trim() === "" ? "" : /^https:\/\/[^/\s]+/i.test(body.endpoint) ? body.endpoint : undefined;
        if (route === "/models/download/cancel") service.recognizer.cancel(modelId);
        else if (typeof service.recognizer.start === "function") {
          service.recognizer.start(modelId, { endpoint, activate: route === "/models/active" || body.activate !== false, download: route !== "/models/active" });
        } else await service.recognizer.downloadAndPrepare({ endpoint });
        reply(res, 202, { ok: true, phase: "accepted" });
        return;
      }

      if (route === "/polish" && req.method === "POST") {
        const body = JSON.parse((await readBody(req, MAX_JSON_BYTES)).toString("utf8") || "{}");
        const result = await service.polish({
          rawText: body.text,
          supportsClarification: body.supportsClarification === true,
          explanationMarkers: typeof body.explanationMarkers === "string" ? body.explanationMarkers : null,
          preferenceExamples: Array.isArray(body.preferenceExamples) ? body.preferenceExamples : null,
          language: typeof body.language === "string" ? body.language : "auto",
          appHint: body.appHint ?? null,
          strength: body.strength,
          fieldContext: normalizeFieldContext(body.fieldContext),
          llm: normalizeRoute(body.llm),
          translateTo: typeof body.translateTo === "string" ? body.translateTo : null,
          variants: body.variants ?? null,
          dictionary: Array.isArray(body.dictionary) ? body.dictionary : null,
          signal: undefined,
        });
        // service.polish() records the attempt itself.
        reply(res, 200, {
          requestId: body.requestId ?? null,
          text: result.text,
          raw: result.raw,
          suggestions: result.suggestions ?? [],
          fallback: result.fallback,
          fallbackReason: result.reason ?? undefined,
          model: result.model,
          provider: result.provider,
          ms: result.ms,
          ...(result.translated ? { translated: result.translated } : {}),
          ...(result.clarification ? { clarification: result.clarification } : {}),
          ...(result.explanation ? { explanation: result.explanation } : {}),
          ...(result.contextOnly ? { contextOnly: true } : {}),
        });
        return;
      }

      // Extensions are an optional route module. Core HTTP has no plugin parser.
      if (route.startsWith("/plugins")) {
        if (!service.extension) throw Object.assign(new Error("plugins unavailable"), { code: "plugins-unavailable" });
        if (await service.extension.handleHttp({ route, req, res, url, readBody, reply, maxJsonBytes: MAX_JSON_BYTES })) return;
      }

      if (route === "/learned-word" && req.method === "POST") {
        // A fix the user made right after a paste: the word to add to the dictionary, or null.
        // The field text is only compared here, never stored or logged.
        const body = JSON.parse((await readBody(req, MAX_JSON_BYTES)).toString("utf8") || "{}");
        reply(res, 200, { word: await learnedWord(body?.inserted, body?.edited) });
        return;
      }

      if (route === "/dictate" && req.method === "POST") {
        // The body is the app's dictionary (x-voice-dictionary-bytes of JSON, may be 0) then the WAV.
        const dictionaryBytes = Number(req.headers["x-voice-dictionary-bytes"] ?? "0");
        if (!Number.isInteger(dictionaryBytes) || dictionaryBytes < 0 || dictionaryBytes > MAX_DICTIONARY_BYTES) {
          reply(res, 400, { error: "invalid-dictionary" });
          return;
        }
        const body = await readBody(req, service.config.maxAudioBytes + 46 + dictionaryBytes);
        let dictionary = null;
        if (dictionaryBytes > 0) {
          try { dictionary = JSON.parse(body.subarray(0, dictionaryBytes).toString("utf8")); } catch { dictionary = null; }
          if (!Array.isArray(dictionary)) {
            reply(res, 400, { error: "invalid-dictionary" });
            return;
          }
        }
        const audio = body.subarray(dictionaryBytes);
        const result = await service.transcribeAndPolish({
          dictionary,
          supportsClarification: req.headers["x-voice-clarification"] === "1",
          explanationMarkers: req.headers["x-voice-explanation-markers"] ?? null,
          requestId: req.headers["x-request-id"] ?? undefined,
          audio,
          language: req.headers["x-voice-language"] ?? undefined,
          appHint: req.headers["x-voice-app"] ?? null,
          strength: req.headers["x-voice-strength"] ?? undefined,
          fieldContext: parseFieldContext(req.headers["x-voice-context"]),
          llm: parseRouteHeader(req.headers["x-voice-llm"]),
          betaSession: req.headers["x-voice-beta-session"] || null,
          translateTo: req.headers["x-voice-translate"] || null,
          variants: req.headers["x-voice-variants"] || null,
        });
        reply(res, 200, result);
        return;
      }

      // Prompt Beta: generate without answering the questions, or forget them.
      if ((route === "/prompts/beta/finish" || route === "/prompts/beta/cancel") && req.method === "POST") {
        const body = JSON.parse((await readBody(req, MAX_JSON_BYTES)).toString("utf8") || "{}");
        const sessionId = typeof body?.sessionId === "string" ? body.sessionId : "";
        if (route === "/prompts/beta/cancel") {
          reply(res, 200, { ok: true, cancelled: service.cancelBeta(sessionId) });
          return;
        }
        const result = await service.polish({
          rawText: "",
          appHint: req.headers["x-voice-app"] ?? null,
          strength: "promptbeta",
          llm: parseRouteHeader(req.headers["x-voice-llm"]),
          betaSession: sessionId,
          betaSkip: true,
          variants: req.headers["x-voice-variants"] || null,
          signal: undefined,
        });
        reply(res, 200, {
          requestId: null, text: result.text, raw: result.raw, fallback: result.fallback,
          fallbackReason: result.reason ?? undefined, model: result.model, provider: result.provider,
          suggestions: result.suggestions ?? [],
          strength: "promptbeta", ms: result.ms, ...(result.beta ? { beta: result.beta } : {}),
        });
        return;
      }

      reply(res, 404, { error: `unknown endpoint ${url.pathname}`, code: "not-found" });
    } catch (error) {
      const { status, code } = classify(error);
      // JSON parser errors may include submitted keys or text. Never echo the input.
      const detail = code === "invalid-json" ? "invalid JSON body" : status >= 500 ? "internal service error" : error instanceof Error ? error.message : String(error);
      if (status >= 500) logger?.warn?.("typeleast: request failed (%s)", code);
      if (!res.headersSent) reply(res, status, { error: detail, code });
      else res.destroy();
    }
  };
}
