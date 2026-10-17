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
import { authorize } from "./token.js";
import { WavError } from "./wav.js";
import { normalizeFieldContext, parseFieldContext } from "./context.js";
import { completeOpenAI, normalizeRoute, parseRouteHeader } from "./openai-compat.js";

export const ROUTE_PREFIX = "/api/voice-polish";
export const MAX_JSON_BYTES = 256 * 1024;

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
  const code = error?.code ?? (error instanceof WavError ? "invalid-audio" : "error");
  switch (code) {
    case "payload-too-large":
      return { status: 413, code };
    case "invalid-audio":
    case "audio-too-large":
      return { status: 400, code };
    case "busy":
      return { status: 429, code };
    case "speech-not-ready":
      return { status: 503, code };
    default:
      return { status: 500, code };
  }
}

/**
 * Build the request handler. Dependencies are injected so this module can be
 * exercised in tests without a network listener.
 * @param {object} options - service, token accessor and logger.
 * @returns {(req: object, res: object) => Promise<void>} the route handler.
 */
export function createHandler(options) {
  const { service, logger } = options;
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

      if (route === "/history" && req.method === "GET") {
        const limit = Number(url.searchParams.get("limit") ?? "20");
        const items = await service.readHistory({ limit: Number.isFinite(limit) ? limit : 20 });
        reply(res, 200, { items });
        return;
      }

      if (route === "/learn" && req.method === "POST") {
        const body = JSON.parse((await readBody(req, MAX_JSON_BYTES)).toString("utf8") || "{}");
        reply(res, 200, await service.learn({ from: body.from, to: body.to }));
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

      if (route === "/models/download" && req.method === "POST") {
        // Starts the one-time model download (about 241 MB) in the background;
        // progress shows in /health as speech.download.
        const body = JSON.parse((await readBody(req, MAX_JSON_BYTES)).toString("utf8") || "{}");
        const endpoint = typeof body.endpoint === "string" && /^https:\/\/[^/\s]+/i.test(body.endpoint) ? body.endpoint : undefined;
        void service.recognizer.downloadAndPrepare({ endpoint });
        reply(res, 202, { ok: true, phase: "downloading" });
        return;
      }

      if (route === "/dictionary" && req.method === "GET") {
        reply(res, 200, { dictionary: [...service.dictionary] });
        return;
      }

      if (route === "/dictionary" && req.method === "PUT") {
        const body = JSON.parse((await readBody(req, MAX_JSON_BYTES)).toString("utf8") || "{}");
        reply(res, 200, await service.setDictionary(body.entries));
        return;
      }

      if (route === "/polish" && req.method === "POST") {
        const body = JSON.parse((await readBody(req, MAX_JSON_BYTES)).toString("utf8") || "{}");
        const result = await service.polish({
          rawText: body.text,
          appHint: body.appHint ?? null,
          strength: body.strength,
          fieldContext: normalizeFieldContext(body.fieldContext),
          llm: normalizeRoute(body.llm),
          signal: undefined,
        });
        // service.polish() records the attempt itself.
        reply(res, 200, {
          requestId: body.requestId ?? null,
          text: result.text,
          raw: result.raw,
          fallback: result.fallback,
          fallbackReason: result.reason ?? undefined,
          model: result.model,
          provider: result.provider,
          ms: result.ms,
        });
        return;
      }

      if (route === "/dictate" && req.method === "POST") {
        const audio = await readBody(req, service.config.maxAudioBytes + 46);
        const result = await service.transcribeAndPolish({
          requestId: req.headers["x-request-id"] ?? undefined,
          audio,
          language: req.headers["x-voice-language"] ?? undefined,
          appHint: req.headers["x-voice-app"] ?? null,
          strength: req.headers["x-voice-strength"] ?? undefined,
          fieldContext: parseFieldContext(req.headers["x-voice-context"]),
          llm: parseRouteHeader(req.headers["x-voice-llm"]),
        });
        reply(res, 200, result);
        return;
      }

      reply(res, 404, { error: `unknown endpoint ${url.pathname}`, code: "not-found" });
    } catch (error) {
      const { status, code } = classify(error);
      const detail = error instanceof Error ? error.message : String(error);
      if (status >= 500) logger?.warn?.("typeleast: %s -> %s (%s)", req.url, status, detail);
      if (!res.headersSent) reply(res, status, { error: detail, code });
      else res.destroy();
    }
  };
}
