import test from "node:test";
import assert from "node:assert/strict";
import { completeOpenAI, normalizeRoute, parseRouteHeader, routeLabel } from "../lib/openai-compat.js";
import { failureReason } from "../lib/llm.js";
import { VoicePolishService } from "../lib/service.js";

const ROUTE = { baseURL: "https://api.example.com/v1/", model: "chat-model", apiKey: "sk-test-123456789012" };

function fakeFetch(handler) {
  const calls = [];
  const impl = async (url, init) => {
    assert.equal(init.redirect, "error", "private text must not follow redirects");
    calls.push({ url, init, body: JSON.parse(init.body) });
    return handler(calls.length);
  };
  impl.calls = calls;
  return impl;
}
const ok = (content, finish = "stop") => ({ ok: true, status: 200, json: async () => ({ choices: [{ message: { content }, finish_reason: finish }], usage: { total_tokens: 9 } }) });
const status = (code) => ({ ok: false, status: code, body: { cancel: async () => {} }, json: async () => ({}) });

test("routes are validated: https or loopback http, model and key required", () => {
  const route = normalizeRoute(ROUTE);
  assert.equal(route.baseURL, "https://api.example.com/v1", "trailing slash removed");
  assert.equal(route.host, "api.example.com");
  assert.equal(normalizeRoute({ ...ROUTE, baseURL: "http://api.example.com/v1" }), null, "no clear-text keys over the network");
  assert.ok(normalizeRoute({ baseURL: "http://127.0.0.1:11434/v1", model: "qwen", apiKey: "" }), "a local server needs no key");
  assert.equal(normalizeRoute({ ...ROUTE, apiKey: "" }), null, "a remote service needs a key");
  assert.equal(normalizeRoute({ ...ROUTE, model: "" }), null);
  assert.equal(normalizeRoute({ ...ROUTE, baseURL: "https://user:pass@api.example.com" }), null);
  assert.equal(normalizeRoute("nope"), null);
  assert.equal(routeLabel(route), "custom:api.example.com");
  const header = Buffer.from(JSON.stringify(ROUTE)).toString("base64");
  assert.equal(parseRouteHeader(header).model, "chat-model");
  assert.equal(parseRouteHeader("%%%"), null);
});

test("a completion sends the key as a bearer token and returns the message content", async () => {
  const fetchImpl = fakeFetch(() => ok("整理好的文字"));
  const result = await completeOpenAI({ route: normalizeRoute(ROUTE), system: "S", user: "U", maxTokens: 50, temperature: 0.2, timeoutMs: 2000, fetchImpl });
  assert.equal(result.text, "整理好的文字");
  const call = fetchImpl.calls[0];
  assert.equal(call.url, "https://api.example.com/v1/chat/completions");
  assert.equal(call.init.headers.authorization, "Bearer sk-test-123456789012");
  assert.deepEqual(call.body.messages.map((m) => m.role), ["system", "user"]);
  assert.equal(call.body.max_tokens, 50);
  assert.equal(call.body.temperature, 0.2);
  assert.equal(call.body.stream, false);
});

test("failures are classified, retried only when it can help, and never mention the key", async () => {
  const auth = fakeFetch(() => status(401));
  await assert.rejects(completeOpenAI({ route: normalizeRoute(ROUTE), system: "S", user: "U", timeoutMs: 2000, fetchImpl: auth }), (error) => {
    assert.equal(failureReason(error), "model-error:HTTP_401");
    assert.doesNotMatch(error.message, /sk-test/);
    return true;
  });
  assert.equal(auth.calls.length, 1, "a bad key is not retried");

  const flaky = fakeFetch((n) => (n === 1 ? status(503) : ok("好了")));
  const result = await completeOpenAI({ route: normalizeRoute(ROUTE), system: "S", user: "U", timeoutMs: 2000, fetchImpl: flaky });
  assert.equal(result.text, "好了");
  assert.equal(result.attempts, 2);

  const cut = fakeFetch(() => ok("半句", "length"));
  await assert.rejects(completeOpenAI({ route: normalizeRoute(ROUTE), system: "S", user: "U", timeoutMs: 2000, fetchImpl: cut }), (error) => failureReason(error) === "model-max-tokens");

  const slow = async (url, init) => new Promise((resolve, reject) => init.signal.addEventListener("abort", () => reject(new Error("aborted"))));
  await assert.rejects(completeOpenAI({ route: normalizeRoute(ROUTE), system: "S", user: "U", timeoutMs: 1000, fetchImpl: slow }), (error) => failureReason(error) === "model-timeout");
});

test("the service uses the user's route for that request and records no key", async () => {
  const stored = [];
  const service = new VoicePolishService({
    recognizer: { snapshot: () => ({ ready: true }), transcribe: async () => ({ text: "" }) },
    config: { maxOutputTokens: 400, timeoutMs: 3000, strength: "prompt", redactSecrets: true, logRaw: true, maxAudioBytes: 4194304, maxDurationSeconds: 120, dictionary: [] },
    history: { append: async (entry) => { stored.push(entry); return entry; }, recent: async () => [] },
    logger: { info: () => {}, warn: () => {}, debug: () => {} },
    version: "test",
  });
  const realFetch = globalThis.fetch;
  globalThis.fetch = fakeFetch(() => ok("我们周三把报告发出去。"));
  try {
    const result = await service.polish({ rawText: "我们周二把报告发出去不对周三发出去", strength: "prompt", llm: ROUTE });
    assert.equal(result.fallback, false);
    assert.equal(result.text, "我们周三把报告发出去。");
    assert.equal(result.provider, "custom:api.example.com");
    assert.equal(result.model, "chat-model");
  } finally {
    globalThis.fetch = realFetch;
  }
  assert.doesNotMatch(JSON.stringify(stored), /sk-test/, "history never contains the key");
});

test("thinking is switched off where the provider has a switch, and dropped if refused", async () => {
  const { noThinkingFields } = await import("../lib/openai-compat.js");
  assert.deepEqual(noThinkingFields("api.deepseek.com"), { thinking: { type: "disabled" } });
  assert.deepEqual(noThinkingFields("open.bigmodel.cn"), { thinking: { type: "disabled" } });
  assert.deepEqual(noThinkingFields("dashscope.aliyuncs.com"), { enable_thinking: false });
  assert.deepEqual(noThinkingFields("api.openai.com"), {});

  const deepseek = { baseURL: "https://api.deepseek.com", model: "deepseek-flash", apiKey: "sk-test-123456789012" };
  const sent = fakeFetch(() => ok("好"));
  await completeOpenAI({ route: normalizeRoute(deepseek), system: "S", user: "U", timeoutMs: 2000, fetchImpl: sent });
  assert.deepEqual(sent.calls[0].body.thinking, { type: "disabled" });

  const strict = { baseURL: "https://open.bigmodel.cn/api/paas/v4", model: "glm", apiKey: "sk-test-123456789012" };
  const refusing = fakeFetch((n) => (n === 1 ? status(400) : ok("好")));
  const result = await completeOpenAI({ route: normalizeRoute(strict), system: "S", user: "U", timeoutMs: 2000, fetchImpl: refusing });
  assert.equal(result.text, "好");
  assert.equal(refusing.calls.length, 2);
  assert.equal(refusing.calls[0].body.thinking?.type, "disabled");
  assert.equal(refusing.calls[1].body.thinking, undefined, "retried without the switch");
  const again = fakeFetch(() => ok("好"));
  await completeOpenAI({ route: normalizeRoute(strict), system: "S", user: "U", timeoutMs: 2000, fetchImpl: again });
  assert.equal(again.calls[0].body.thinking, undefined, "not sent to that host again");
});

test("a reply that spent its whole budget thinking is retried once with room to answer", async () => {
  const route = normalizeRoute({ baseURL: "https://api.example.com/v1", model: "thinker", apiKey: "sk-test-123456789012" });
  const thinker = fakeFetch((n) => (n === 1 ? ok("", "length") : ok("整理好了")));
  const result = await completeOpenAI({ route, system: "S", user: "U", maxTokens: 64, timeoutMs: 2000, fetchImpl: thinker });
  assert.equal(result.text, "整理好了");
  assert.equal(thinker.calls[0].body.max_tokens, 64);
  assert.equal(thinker.calls[1].body.max_tokens, 256);
  const always = fakeFetch(() => ok("", "length"));
  await assert.rejects(completeOpenAI({ route, system: "S", user: "U", maxTokens: 64, timeoutMs: 2000, fetchImpl: always }),
    (error) => failureReason(error) === "model-max-tokens");
  assert.equal(always.calls.length, 2, "only one widening retry");
});
