import test from "node:test";
import assert from "node:assert/strict";
import { createHandler, hostAllowed, MAX_JSON_BYTES, ROUTE_PREFIX } from "../lib/http.js";
import { VoicePolishService } from "../lib/service.js";

const TOKEN = "a".repeat(64);

const ROUTE = { baseURL: "https://api.example.com/v1", model: "chat-model", apiKey: "sk-test-123456789012" };

/** A service whose model always stops at its token limit. */
function failingService() {
  const stored = [];
  return new VoicePolishService({
    recognizer: {
      snapshot: () => ({ providerId: "sensevoice-local", engine: "sherpa-onnx", phase: "ready", ready: true, languages: ["auto", "zh"] }),
      transcribe: async () => ({ text: "x" }),
    },
    fetchImpl: async () => ({ ok: true, status: 200, json: async () => ({ choices: [{ message: { content: "Send the" }, finish_reason: "length" }] }) }),
    config: { maxOutputTokens: 400, timeoutMs: 5000, strength: "prompt", redactSecrets: true, maxAudioBytes: 4194304, maxDurationSeconds: 120, dictionary: [] },
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
  // The contract both apps decode, plus the documented extras.
  assert.equal(before.json.ok, true);
  assert.equal(before.json.service, "typeleast");
  assert.equal(before.json.version, "test");
  assert.equal(before.json.provider, null, "no cleanup has run yet");
  assert.equal(before.json.model, null);
  assert.deepEqual(before.json.speech, { providerId: "sensevoice-local", engine: "sherpa-onnx", phase: "ready", ready: true, languages: ["auto", "zh"] });
  assert.equal(before.json.strength, "prompt");
  assert.equal(before.json.pending, 0);
  assert.equal(before.json.queue, 0);
  assert.equal(before.json.pid, process.pid);
  assert.deepEqual(before.json.stats, { dictations: 0, polished: 0, fallback: 0, lastError: null, lastMs: null, modelCalls: 0, modelFallbacks: 0, jsonFallback: 0, jsonRecovered: 0 });
  assert.equal(before.json.promptSource, "typeleast");
  assert.equal(before.json.temperature, 0.8);
  assert.deepEqual(before.json.recentFailures, []);

  await service.polish({ rawText: "um so we should send the report on wednesday", strength: "prompt", appHint: "com.apple.mail", llm: ROUTE });
  const after = await call(handler, "/api/voice-polish/health");
  assert.equal(after.json.provider, "custom:api.example.com");
  assert.equal(after.json.model, "chat-model");
  assert.ok(!JSON.stringify(after.json).includes(ROUTE.apiKey), "the key never appears in /health");
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

test("paths outside the route prefix are not served", async () => {
  const handler = createHandler({ service: failingService(), logger: undefined, currentToken: async () => TOKEN });
  for (const path of ["/", "/health", "/api/voice-polishX/health", "/api/other"]) {
    const reply = await call(handler, path);
    assert.equal(reply.status, 404, path);
    assert.equal(reply.json.code, "not-found");
  }
});


test("malformed JSON is a client error and does not echo secrets", async () => {
  const { Readable } = await import("node:stream");
  const handler = createHandler({ service: failingService(), currentToken: async () => TOKEN });
  const req = Readable.from([Buffer.from('{"apiKey":"fake-private-credential"')]);
  req.method = "POST";
  req.url = "/api/voice-polish/polish";
  req.headers = { host: "127.0.0.1:51234", authorization: `Bearer ${TOKEN}` };
  const res = { headersSent: false, writeHead(status) { this.status = status; this.headersSent = true; }, end(body) { this.body = body; } };
  await handler(req, res);
  assert.equal(res.status, 400);
  assert.equal(JSON.parse(res.body).code, "invalid-json");
  assert.ok(!res.body.includes("fake-private-credential"));
});

test("speech model endpoints preserve auth and pass only catalog IDs to lifecycle operations", async () => {
  const { Readable } = await import('node:stream');
  const { modelFor } = await import('../lib/models.js');
  const seen=[];
  const service=failingService();
  service.recognizer.catalog=async()=>({activeModelId:'sensevoice-small',models:[]});
  service.recognizer.start=(id,options)=>{modelFor(id);seen.push({id,...options});};
  service.recognizer.cancel=id=>{modelFor(id);seen.push({cancel:id});};
  const handler=createHandler({service,currentToken:async()=>TOKEN});
  async function request(path,method,body={},headers={}) {
    const req=Readable.from([Buffer.from(JSON.stringify(body))]);
    Object.assign(req,{url:ROUTE_PREFIX+path,method,headers:{host:'127.0.0.1',authorization:`Bearer ${TOKEN}`,...headers}});
    const res={headersSent:false,writeHead(status){this.status=status;this.headersSent=true;},end(body){this.body=body;}};
    await handler(req,res);return res;
  }
  assert.equal((await request('/models','GET')).status,200);
  assert.equal((await request('/models/download','POST')).status,202);
  assert.equal(seen[0].id,'sensevoice-small');
  assert.equal((await request('/models/active','PUT',{modelId:'fun-asr-nano'})).status,202);
  assert.equal(seen[1].download,false);
  assert.equal((await request('/models/download/cancel','POST',{modelId:'fun-asr-nano'})).status,202);
  assert.equal((await request('/models/active','PUT',{modelId:'../../private'})).status,400);
  assert.equal((await request('/models/active','PUT',null)).status,400);
  assert.equal((await request('/models/download','POST',[])).status,400);
  assert.equal((await request('/models/download','POST',{modelId:null})).status,400);
  // A cleared mirror is passed on as "" (huggingface.co), not dropped back to the startup HF_ENDPOINT.
  await request('/models/download','POST',{endpoint:''});
  assert.equal(seen.at(-1).endpoint,'');
  await request('/models/download','POST',{endpoint:'https://hf-mirror.com'});
  assert.equal(seen.at(-1).endpoint,'https://hf-mirror.com');
  await request('/models/download','POST',{});
  assert.equal(seen.at(-1).endpoint,undefined);
  const { downloadUrl } = await import('../lib/models.js');
  assert.match(downloadUrl({ repo: 'a/b', path: 'c' }, ''), /^https:\/\/huggingface\.co\//);
  const denied=await call(handler,ROUTE_PREFIX+'/models',{authorization:'Bearer invalid'});
  assert.equal(denied.status,401);
  let inspected = 0;
  service.recognizer.inspectLocal = async body => { inspected++; if (!body.name) throw Object.assign(new Error('invalid description'), { code: 'invalid-local-model' }); return { name: body.name }; };
  service.recognizer.registerLocal = () => 'local-demo';
  service.recognizer.registerKnown = async id => modelFor(id);
  service.recognizer.removeLocal = async () => {};
  assert.equal((await request('/models/local/inspect', 'POST', { name: 'Fictional model' }, { authorization: 'Bearer invalid' })).status, 401);
  assert.equal(inspected, 0, 'no model inspection before authentication');
  assert.equal((await request('/models/local/inspect', 'POST', { name: 'Fictional model' })).status, 200);
  assert.equal((await request('/models/local/inspect', 'POST', {})).status, 400);
  assert.equal((await request('/models/local/register', 'POST', {})).status, 202);
  assert.equal((await request('/models/register-known', 'POST', { modelId: 'sensevoice-small' })).status, 200);
  assert.equal((await request('/models/local/remove', 'POST', { modelId: 'local-demo' })).status, 200);
  assert.equal((await request('/models/local/remove', 'POST', null)).status, 400);
});

test("Prompt Beta endpoints: skip and cancel take a session id; an expired one is 410", async () => {
  const { Readable } = await import("node:stream");
  const service = failingService();
  const seen = [];
  service.polish = async (request) => {
    seen.push(request);
    if (request.betaSession === "gone") throw Object.assign(new Error("expired"), { code: "beta-expired" });
    if (request.betaSession === "waiting") return { text: "", raw: "r", fallback: false, ms: {}, beta: { sessionId: "waiting", questions: [], confirmed: ["用户的信息"], round: 3, ready: true, notice: "beta-validation" } };
    return { text: "## 目标\nx", raw: "r", fallback: false, ms: {} };
  };
  service.cancelBeta = (id) => id === "live";
  const handler = createHandler({ service, currentToken: async () => TOKEN });
  async function post(path, body) {
    const req = Readable.from([Buffer.from(JSON.stringify(body))]);
    Object.assign(req, { url: ROUTE_PREFIX + path, method: "POST", headers: { host: "127.0.0.1", authorization: `Bearer ${TOKEN}` } });
    const res = { headersSent: false, writeHead(status) { this.status = status; this.headersSent = true; }, end(b) { this.body = b; } };
    await handler(req, res);
    return res;
  }
  const done = await post("/prompts/beta/finish", { sessionId: "live" });
  assert.equal(done.status, 200);
  assert.equal(JSON.parse(done.body).text, "## 目标\nx");
  assert.equal(seen[0].betaSkip, true);
  assert.equal(seen[0].strength, "promptbeta");
  const pending = JSON.parse((await post("/prompts/beta/finish", { sessionId: "waiting" })).body);
  assert.equal(pending.text, "");
  assert.equal(pending.beta.sessionId, "waiting");
  assert.equal(pending.beta.round, 3);
  assert.equal(pending.beta.notice, "beta-validation");
  assert.deepEqual(pending.beta.confirmed, ["用户的信息"]);
  assert.equal((await post("/prompts/beta/finish", { sessionId: "gone" })).status, 410);
  assert.equal(JSON.parse((await post("/prompts/beta/cancel", { sessionId: "live" })).body).cancelled, true);
});

test("翻译和语言变体：/dictate 读请求头，/polish 读请求体，结果带上目标语言", async () => {
  const { Readable } = await import("node:stream");
  const service = failingService();
  const seen = [];
  service.transcribeAndPolish = async (request) => { seen.push(request); return { text: "Hello", raw: "你好", fallback: false, translated: "en", ms: {} }; };
  service.polish = async (request) => { seen.push(request); return { text: "Hello", raw: "你好", fallback: false, translated: "en", ms: {} }; };
  const handler = createHandler({ service, currentToken: async () => TOKEN });
  async function post(path, body, headers = {}) {
    const req = Readable.from([body]);
    Object.assign(req, { url: ROUTE_PREFIX + path, method: "POST", headers: { host: "127.0.0.1", authorization: `Bearer ${TOKEN}`, ...headers } });
    const res = { headersSent: false, writeHead(status) { this.status = status; this.headersSent = true; }, end(b) { this.body = b; } };
    await handler(req, res);
    return res;
  }
  const dictated = await post("/dictate", Buffer.alloc(64), { "x-voice-translate": "en", "x-voice-variants": "zh=tw,en=gb" });
  assert.equal(dictated.status, 200);
  assert.equal(seen[0].translateTo, "en");
  assert.equal(seen[0].variants, "zh=tw,en=gb");
  const polished = await post("/polish", Buffer.from(JSON.stringify({ text: "你好", translateTo: "en", variants: { zh: "hk" } })));
  assert.equal(JSON.parse(polished.body).translated, "en");
  assert.equal(seen[1].translateTo, "en");
  assert.deepEqual(seen[1].variants, { zh: "hk" });
});

test("身份校验：带启动密钥时 /health 用 HMAC 回答挑战；没有密钥或挑战格式不对时不回答", async () => {
  const { createHmac, randomBytes } = await import("node:crypto");
  const { proofFor } = await import("../lib/http.js");
  const key = randomBytes(32).toString("hex");
  const challenge = randomBytes(16).toString("hex");
  assert.equal(proofFor(key, challenge).proof, createHmac("sha256", Buffer.from(key, "hex")).update(challenge).digest("hex"));
  assert.deepEqual(proofFor(null, challenge), {});
  assert.deepEqual(proofFor(key, "not hex!"), {});
  const service = failingService();
  service.snapshot = () => ({ speech: { ready: true }, version: "x", provider: null, model: null, strength: "prompt", dictionarySize: 0, pending: 0, queue: 0 });
  const handler = createHandler({ service, currentToken: async () => TOKEN, proofKey: key });
  const res = { headersSent: false, writeHead(status) { this.status = status; this.headersSent = true; }, end(b) { this.body = b; } };
  await handler({ url: ROUTE_PREFIX + "/health", method: "GET", headers: { host: "127.0.0.1", authorization: `Bearer ${TOKEN}`, "x-typeleast-challenge": challenge } }, res);
  assert.equal(JSON.parse(res.body).proof, proofFor(key, challenge).proof);
});
