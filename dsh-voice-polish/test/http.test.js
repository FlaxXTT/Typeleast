import test from "node:test";
import assert from "node:assert/strict";
import { createHandler, hostAllowed, MAX_JSON_BYTES, ROUTE_PREFIX } from "../lib/http.js";
import { VoicePolishService } from "../lib/service.js";

const TOKEN = "a".repeat(64);

/** A service whose model always stops at its token limit. */
function failingService() {
  const stored = [];
  return new VoicePolishService({
    ctx: {
      llm: {
        listProviders: () => [{ id: "deepseek-account" }],
        stream: () => (async function* generate() {
          yield { type: "text-delta", index: 0, text: "Send the" };
          yield { type: "finish", reason: { kind: "max-tokens" } };
        })(),
      },
      speechToText: {
        snapshot: () => ({
          providers: [{ id: "sensevoice-local", languages: ["auto", "zh"], preparation: { phase: "standby" } }],
          selection: { providerId: "sensevoice-local" },
        }),
      },
      sessions: {},
    },
    config: { provider: "deepseek-account", model: "deepseek-flash", maxOutputTokens: 400, timeoutMs: 5000, strength: "prompt", contextTurns: 2, contextChars: 500, redactSecrets: true, logRaw: true, maxAudioBytes: 4194304, maxDurationSeconds: 120, dictionary: [] },
    history: { append: async (entry) => { stored.push(entry); return entry; }, recent: async () => stored },
    logger: { info: () => {}, warn: () => {}, debug: () => {} },
    version: "test",
  });
}

/** Drive the handler with an in-memory request and capture the reply. */
async function call(handler, path, headers = {}) {
  const res = {
    status: null,
    body: "",
    headersSent: false,
    writeHead(status) { this.status = status; this.headersSent = true; },
    end(text) { this.body = text; },
    destroy() {},
  };
  await handler({ method: "GET", url: path, headers: { host: "127.0.0.1:51234", authorization: `Bearer ${TOKEN}`, ...headers } }, res);
  return { status: res.status, json: JSON.parse(res.body) };
}

test("only loopback authorities are accepted", () => {
  // The endpoint is unauthenticated from the browser's perspective until the
  // bearer token is checked, so a DNS-rebinding guard runs first: a request that
  // resolves evil.example.com to 127.0.0.1 still carries the foreign Host header.
  const allowed = [
    { host: "127.0.0.1:51234" },
    { host: "127.0.0.1" },
    { host: "localhost:3099" },
    { host: "LOCALHOST" },
    { host: "[::1]:3099" },
  ];
  for (const headers of allowed) assert.equal(hostAllowed({ headers }), true, JSON.stringify(headers));
  const refused = [
    { host: "evil.example.com" },
    { host: "evil.example.com:3099" },
    { host: "127.0.0.1.evil.com" },
    { host: "localhost.evil.com" },
    { host: "0.0.0.0:3099" },
    { host: "" },
    {},
  ];
  for (const headers of refused) assert.equal(hostAllowed({ headers }), false, JSON.stringify(headers));
});

test("the route prefix and body ceiling are the documented ones", () => {
  assert.equal(ROUTE_PREFIX, "/api/voice-polish");
  assert.equal(MAX_JSON_BYTES, 256 * 1024);
});

test("/health keeps the fields the native client decodes and adds failure details", async () => {
  const service = failingService();
  const handler = createHandler({ service, logger: undefined, currentToken: async () => TOKEN });

  const before = await call(handler, "/api/voice-polish/health");
  assert.equal(before.status, 200);
  // The frozen contract (DshClient.HealthResponse plus the documented extras).
  assert.equal(before.json.ok, true);
  assert.equal(before.json.version, "test");
  assert.equal(before.json.provider, "deepseek-account");
  assert.equal(before.json.model, "deepseek-flash");
  assert.deepEqual(before.json.speech, { providerId: "sensevoice-local", phase: "standby", ready: true, languages: ["auto", "zh"] });
  assert.equal(before.json.strength, "prompt");
  assert.equal(before.json.dictionarySize, 0);
  assert.equal(before.json.pending, 0);
  assert.equal(before.json.queue, 0);
  assert.equal(before.json.pid, process.pid);
  assert.equal(before.json.reasoningEffort, "off");
  assert.deepEqual(before.json.stats, { dictations: 0, polished: 0, fallback: 0, lastError: null, lastMs: null, modelCalls: 0, modelFallbacks: 0, jsonFallback: 0, jsonRecovered: 0 });
  assert.equal(before.json.promptSource, "erduo");
  assert.equal(before.json.temperature, 0.8);
  assert.deepEqual(before.json.recentFailures, []);

  await service.polish({ rawText: "um so we should send the report on wednesday", strength: "prompt", appHint: "com.apple.mail" });
  const after = await call(handler, "/api/voice-polish/health");
  assert.equal(after.json.stats.modelCalls, 1);
  assert.equal(after.json.stats.modelFallbacks, 1);
  assert.match(after.json.stats.lastError, /^model-max-tokens: model output hit its token limit \(\d+ ms\)$/);
  assert.equal(after.json.recentFailures.length, 1);
  const [failure] = after.json.recentFailures;
  assert.equal(failure.reason, "model-max-tokens");
  assert.match(failure.detail, /token limit/);
  assert.equal(failure.app, "com.apple.mail");
  assert.equal(failure.strength, "prompt");
  assert.equal(typeof failure.ms, "number");
  assert.equal(typeof failure.ts, "number");
  assert.ok(!JSON.stringify(after.json).includes("wednesday"), "dictated text never appears in /health");
});

test("/health still requires the bearer token", async () => {
  const handler = createHandler({ service: failingService(), logger: undefined, currentToken: async () => TOKEN });
  const denied = await call(handler, "/api/voice-polish/health", { authorization: `Bearer ${"b".repeat(64)}` });
  assert.equal(denied.status, 401);
  assert.equal(denied.json.code, "unauthorized");
  assert.equal(denied.json.recentFailures, undefined);
});
