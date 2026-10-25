import test from "node:test";
import assert from "node:assert/strict";
import { VoicePolishService } from "../lib/service.js";
import { UTTERANCE_RULES } from "../lib/utterance-rules.js";
import { CLEANUP_PROMPT } from "../lib/prompts/cleanup.js";
import { readdirSync } from "node:fs";

const RAW = "um so we should send the report on tuesday, no wait, wednesday";
const ROUTE = { baseURL: "https://api.example.com/v1", model: "chat-model", apiKey: "sk-test-123456789012" };

/**
 * An OpenAI-compatible endpoint that answers once per call, or fails in a
 * configured way. `calls` holds each request body.
 */
function fakeModel(answer, options = {}) {
  const calls = [];
  const fetchImpl = async (url, init) => {
    const body = JSON.parse(init.body);
    calls.push({ url, body, headers: init.headers });
    if (options.hang) {
      await new Promise((resolve) => init.signal.addEventListener("abort", resolve, { once: true }));
      throw new DOMException("This operation was aborted", "AbortError");
    }
    if (init.signal?.aborted) throw new DOMException("This operation was aborted", "AbortError");
    if (options.fail) throw options.fail;
    if (options.status) return { ok: false, status: options.status, body: { cancel: async () => {} } };
    return {
      ok: true,
      status: 200,
      json: async () => ({ choices: [{ message: { content: answer }, finish_reason: options.finish ?? "stop" }], usage: { total_tokens: 10 } }),
    };
  };
  return { calls, fetchImpl };
}

function fakeRecognizer(text = "we should send the report on tuesday, no wait, wednesday", options = {}) {
  return {
    snapshot: () => ({ providerId: "sensevoice-local", engine: "sherpa-onnx", phase: options.phase ?? "ready", ready: (options.phase ?? "ready") === "ready", languages: ["auto", "zh"] }),
    transcribe: async () => {
      if (options.notReady) throw Object.assign(new Error("speech model is not ready (phase: loading)"), { code: "speech-not-ready" });
      return { text };
    },
  };
}

function makeService({ model, recognizer, config = {} } = {}) {
  return new VoicePolishService({
    recognizer: recognizer ?? fakeRecognizer(),
    fetchImpl: (model ?? fakeModel("Send the report on Wednesday.")).fetchImpl,
    config: { maxOutputTokens: 400, timeoutMs: 5000, strength: "prompt", redactSecrets: true, maxAudioBytes: 4194304, maxDurationSeconds: 120, dictionary: [], ...config },
    logger: { info: () => {}, warn: () => {}, debug: () => {} },
    version: "test",
  });
}

function wavOfSilence(seconds = 0.2) {
  const samples = Math.round(16000 * seconds);
  const buffer = Buffer.alloc(44 + samples * 2);
  buffer.write("RIFF", 0, "ascii"); buffer.writeUInt32LE(36 + samples * 2, 4); buffer.write("WAVE", 8, "ascii");
  buffer.writeUInt32LE(16, 16); buffer.writeUInt16LE(1, 20); buffer.writeUInt16LE(1, 22);
  buffer.writeUInt32LE(16000, 24); buffer.writeUInt32LE(32000, 28); buffer.writeUInt16LE(2, 32); buffer.writeUInt16LE(16, 34);
  buffer.write("data", 36, "ascii"); buffer.writeUInt32LE(samples * 2, 40);
  return buffer;
}

test('dictation returns local suggestions without an additional model call', async () => {
  const model = fakeModel('用 JSON 传输。');
  const service = makeService({ model, recognizer: fakeRecognizer('用杰森传输') });
  const result = await service.transcribeAndPolish({ audio: wavOfSilence(), strength: 'prompt', llm: ROUTE });
  assert.equal(result.fallback, false);
  assert.equal(result.text, '用 JSON 传输。');
  assert.deepEqual(result.suggestions, [{ word: 'JSON', heardAs: '杰森' }]);
  assert.equal(model.calls.length, 1);
});

test('optional suggestion failure preserves dictation, does not retry or log user text', async () => {
  const model = fakeModel('用 JSON 传输。');
  const service = makeService({ model, recognizer: fakeRecognizer('用杰森传输') });
  const logs = [];
  service.logger = { info: (...args) => logs.push(args), warn: (...args) => logs.push(args), debug: (...args) => logs.push(args) };
  service.suggestionEngine = async () => { throw new Error('private-demo-text'); };
  const result = await service.transcribeAndPolish({ audio: wavOfSilence(), strength: 'prompt', llm: ROUTE });
  assert.equal(result.fallback, false);
  assert.equal(result.text, '用 JSON 传输。');
  assert.deepEqual(result.suggestions, []);
  assert.equal(model.calls.length, 1);
  assert.ok(!JSON.stringify(logs).includes('private-demo-text'));
});

test('suggestions are skipped for fallback, translation and pending Beta', async () => {
  const service = makeService();
  let calls = 0;
  service.suggestionEngine = async () => { calls++; return [{ word: 'JSON', heardAs: '杰森' }]; };
  for (const [request, extra] of [
    [{}, { fallback: true }],
    [{ translateTo: 'en' }, {}], [{}, { translated: 'en' }],
    [{ strength: 'promptbeta' }, { beta: { sessionId: 'waiting' } }],
  ]) {
    const result = await service.recordAndReturn(request, { raw: '杰森', text: 'JSON', fallback: false, ...extra });
    assert.deepEqual(result.suggestions, []);
  }
  assert.equal(calls, 0);
  const final = await service.recordAndReturn({ strength: 'promptbeta' }, { raw: '杰森', text: 'JSON', fallback: false, beta: { reviewed: true } });
  assert.equal(final.suggestions[0].word, 'JSON');
  assert.equal(calls, 1);
});

test("a clean transcript is polished with the user's own route", async () => {
  const model = fakeModel("Send the report on Wednesday.");
  const service = makeService({ model });
  const result = await service.polish({ rawText: RAW, strength: "prompt", llm: ROUTE });
  assert.equal(result.fallback, false);
  assert.equal(result.text, "Send the report on Wednesday.");
  assert.equal(result.provider, "custom:api.example.com");
  assert.equal(result.model, "chat-model");
  assert.equal(model.calls.length, 1);
  assert.equal(model.calls[0].url, "https://api.example.com/v1/chat/completions");
  assert.equal(model.calls[0].body.model, "chat-model");
  assert.equal(service.snapshot().provider, "custom:api.example.com", "/health names the last route, never the key");
  assert.ok(!JSON.stringify(service.snapshot()).includes(ROUTE.apiKey));
});

test("legacy cleanup selections send only the owner's prompt and cannot restore the removed prompt", async () => {
  assert.deepEqual(readdirSync(new URL("../lib/prompts/", import.meta.url)).sort(),
    ["cleanup.js", "concise.js", "prompt-beta.js", "translate.js"], "only the project's own prompts ship");
  for (const strength of ["prompt", "conservative", "maximal"]) {
    const model = fakeModel("我们周三开会。");
    const service = makeService({ model, config: { strength, promptSource: "legacy-article" } });
    const result = await service.polish({ rawText: "我们周三开会。", strength, llm: ROUTE });
    assert.equal(result.fallback, false, strength);
    assert.equal(model.calls.length, 1, strength);
    assert.deepEqual(model.calls[0].body.messages, [
      { role: "system", content: CLEANUP_PROMPT + UTTERANCE_RULES },
      { role: "user", content: "我们周三开会。" },
    ], strength);
    assert.equal(service.snapshot().promptSource, "typeleast");
  }
});

test("without an API key the tidied transcript is returned and nothing is called", async () => {
  const model = fakeModel("should not be used");
  const service = makeService({ model });
  const result = await service.polish({ rawText: "呃，我们周三把报告发出去吧。", strength: "prompt" });
  assert.equal(result.fallback, true);
  assert.equal(result.reason, "no-api-key");
  assert.equal(result.text, "我们周三把报告发出去。");
  assert.equal(model.calls.length, 0);
  assert.equal(result.reason, "no-api-key");
  // A malformed route counts as no route: it is never half-used.
  const insecure = await service.polish({ rawText: RAW, llm: { ...ROUTE, baseURL: "http://api.example.com/v1" } });
  assert.equal(insecure.reason, "no-api-key");
  assert.equal(model.calls.length, 0);
});

test("the model prompt is the cleanup prompt plus a dictionary addendum", async () => {
  const model = fakeModel("Send the report on Wednesday.");
  const service = makeService({ model, config: { dictionary: ["Wednesday", "第四批=TypeLeast"] } });
  await service.polish({ rawText: RAW, strength: "prompt", appHint: "com.apple.mail", llm: ROUTE });
  const [system, user] = model.calls[0].body.messages;
  assert.equal(system.role, "system");
  assert.match(system.content, /speech recognition transcripts/);
  assert.match(system.content, /Return only one JSON object/);
  // Our constraints ride in a delimited addendum, never woven into the prompt text.
  assert.match(system.content, /=== HARNESS ADDENDUM \(not part of the upstream prompt\) ===/);
  assert.match(system.content, /Dictionary entries are hard constraints/);
  assert.match(system.content, /Entries: Wednesday$/m);
  // The user message is the recognised text alone.
  assert.equal(user.role, "user");
  assert.equal(user.content, RAW);
  assert.equal(model.calls[0].body.messages.length, 2);
});

test("a JSON reply is unwrapped: only its text is inserted, its reason is recorded", async () => {
  const reply = JSON.stringify({ status: "ok", text: "Send the report on Wednesday.", reason: "Fixed the date and removed filler words." });
  const service = makeService({ model: fakeModel(reply) });
  const result = await service.polish({ rawText: RAW, strength: "prompt", llm: ROUTE });
  assert.equal(result.fallback, false);
  assert.equal(result.text, "Send the report on Wednesday.");
  assert.equal(result.outputMode, "json");
  assert.equal(result.modelNote, "Fixed the date and removed filler words.");
  assert.ok(!result.text.includes("{"), "no braces reach the document");
});

test("a malformed JSON reply still yields its text field", async () => {
  const reply = 'Here you go: {"status":"ok","text":"Send the report on Wednesday."} — done';
  const service = makeService({ model: fakeModel(reply) });
  const result = await service.polish({ rawText: RAW, strength: "prompt", llm: ROUTE });
  assert.equal(result.fallback, false);
  assert.equal(result.text, "Send the report on Wednesday.");
  assert.equal(result.outputMode, "regex");
});

test("a status the model made up stays out of /health and the log", async () => {
  const warnings = [];
  const service = makeService({ model: fakeModel(JSON.stringify({ status: "send the wednesday report", text: "x" })) });
  service.logger = { info: () => {}, warn: (...args) => warnings.push(args.join(" ")), debug: () => {} };
  const result = await service.polish({ rawText: RAW, strength: "prompt", llm: ROUTE });
  assert.equal(result.fallback, true);
  assert.equal(result.detail, "output-format:unexpected-status");
  const everywhere = JSON.stringify([service.snapshot(), warnings]);
  assert.ok(!everywhere.includes("wednesday report"), everywhere);
});

test("an unusable reply falls back to the transcript and is counted", async () => {
  const service = makeService({ model: fakeModel('{"status":"ok","text": }') });
  const result = await service.polish({ rawText: RAW, strength: "prompt", llm: ROUTE });
  assert.equal(result.fallback, true);
  assert.equal(result.reason, "output-format");
  assert.match(result.detail, /output-format/);
  assert.equal(service.snapshot().stats.jsonFallback, 1);
});

test("an unreachable model falls back to the raw transcript, retried once, and says why", async () => {
  const refused = new TypeError("fetch failed", { cause: Object.assign(new Error("connect ECONNREFUSED"), { code: "ECONNREFUSED" }) });
  const service = makeService({ model: fakeModel("", { fail: refused }) });
  const result = await service.polish({ rawText: RAW, strength: "prompt", llm: ROUTE });
  assert.equal(result.fallback, true);
  assert.equal(result.reason, "model-error:NETWORK");
  assert.equal(result.text, RAW);
  assert.equal(result.attempts, 2);
  assert.match(result.detail, /^api\.example\.com unreachable: fetch failed \(2 attempts, \d+ ms\)$/);
  assert.ok(!result.detail.includes(ROUTE.apiKey));
});

test("model failures are named by what actually went wrong", async () => {
  const cases = [
    [fakeModel("Send the", { finish: "length" }), "model-max-tokens", /token limit/],
    [fakeModel("", { finish: "tool_calls" }), "model-tool-calls", /requested a tool/],
    [fakeModel("", { status: 401 }), "model-error:HTTP_401", /HTTP 401/],
    [fakeModel("", { status: 503 }), "model-error:HTTP_503", /HTTP 503 \(2 attempts/],
  ];
  for (const [model, reason, detail] of cases) {
      const service = makeService({ model });
    const result = await service.polish({ rawText: RAW, strength: "prompt", llm: ROUTE });
    assert.equal(result.fallback, true, reason);
    assert.equal(result.reason, reason);
    assert.match(result.detail, detail, reason);
    assert.equal(service.snapshot().stats.lastError.startsWith(`${reason}: `), true, reason);
  }
});

test("a model that outlives the deadline is reported as a timeout and not retried", async () => {
  const service = makeService({ model: fakeModel("", { hang: true }), config: { timeoutMs: 30 } });
  const result = await service.polish({ rawText: RAW, strength: "prompt", llm: ROUTE });
  assert.equal(result.reason, "model-timeout");
  assert.equal(result.attempts, 1, "a timeout is never retried");
  assert.match(result.detail, /^no answer from api\.example\.com within 30 ms \(\d+ ms\)$/);
});

test("a caller that goes away is reported as cancelled", async () => {
  const controller = new AbortController();
  controller.abort(new Error("client disconnected"));
  const service = makeService({});
  const result = await service.polish({ rawText: RAW, strength: "prompt", signal: controller.signal, llm: ROUTE });
  assert.equal(result.fallback, true);
  assert.equal(result.reason, "cancelled");
});

test("an answer that invents content is rejected and the raw transcript is used", async () => {
  const service = makeService({ model: fakeModel("We should send the report on Tuesday, then follow up in 3 days.") });
  const result = await service.polish({ rawText: RAW, strength: "prompt", llm: ROUTE });
  assert.equal(result.fallback, true);
  assert.equal(result.reason, "invented-fact");
  assert.equal(result.text, RAW, "the raw transcript is what the user gets");
  // The detail carries measurements only, never the invented tokens themselves.
  assert.match(result.detail, /inventedFacts=1/);
  assert.ok(!result.detail.includes("3 days"));
});

test("a rejected answer falls back to the TIDIED transcript, like a model failure does", async () => {
  const raw = "呃，我们周三把报告发出去吧。";
  const service = makeService({ model: fakeModel("我们周三把报告发出去，然后3天后跟进。") });
  const result = await service.polish({ rawText: raw, strength: "prompt", llm: ROUTE });
  assert.equal(result.fallback, true);
  assert.equal(result.reason, "invented-fact");
  assert.equal(result.raw, raw);
  assert.equal(result.text, "我们周三把报告发出去。");
  assert.deepEqual(result.postprocess, ["strip-particles"]);
});

test("recent fallbacks are kept for /health, newest first and capped at five", async () => {
  const service = makeService({ model: fakeModel("Send the", { finish: "length" }) });
  for (let index = 0; index < 6; index += 1) {
    await service.polish({ rawText: RAW, strength: "prompt", appHint: `app.${index}`, llm: ROUTE });
  }
  const state = service.snapshot();
  assert.equal(state.stats.modelCalls, 6);
  assert.equal(state.stats.modelFallbacks, 6);
  assert.equal(state.recentFailures.length, 5);
  assert.equal(state.recentFailures[0].app, "app.5");
  assert.equal(state.recentFailures[4].app, "app.1");
  assert.equal(state.recentFailures[0].reason, "model-max-tokens");
  assert.equal(typeof state.recentFailures[0].ms, "number");
  // Dictated text never reaches /health.
  assert.ok(!JSON.stringify(state.recentFailures).includes("wednesday"));
  // The snapshot is detached from the live buffer.
  state.recentFailures[0].reason = "mutated";
  assert.equal(service.snapshot().recentFailures[0].reason, "model-max-tokens");
});

test("a successful polish records no failure detail", async () => {
  const service = makeService({});
  const result = await service.polish({ rawText: RAW, strength: "prompt", llm: ROUTE });
  assert.equal(result.fallback, false);
  assert.equal(result.detail ?? null, null);
  assert.equal(service.snapshot().stats.modelCalls, 1);
  assert.equal(service.snapshot().stats.modelFallbacks, 0);
  assert.deepEqual(service.snapshot().recentFailures, []);
});

test("retired strength=off uses natural cleanup instead of skipping the model", async () => {
  const model = fakeModel('{"status":"ok","text":"' + RAW + '","reason":"kept"}');
  const service = makeService({ model });
  const result = await service.polish({ rawText: RAW, strength: "off", llm: ROUTE });
  assert.equal(result.text, RAW);
  assert.equal(result.fallback, false);
  assert.equal(result.reason, null);
  assert.equal(model.calls.length, 1);
});

test("an empty transcript is reported without calling the model", async () => {
  const model = fakeModel("nope");
  const service = makeService({ model });
  const result = await service.polish({ rawText: "   ", strength: "prompt", llm: ROUTE });
  assert.equal(result.fallback, true);
  assert.equal(result.reason, "empty-transcript");
  assert.equal(model.calls.length, 0);
});

test("transcribeAndPolish runs local recognition then cleanup and reports both timings", async () => {
  const service = makeService({ recognizer: fakeRecognizer("send the report on tuesday no wait wednesday") });
  const result = await service.transcribeAndPolish({ audio: wavOfSilence(), language: "en", appHint: "com.apple.mail", requestId: "r1", llm: ROUTE });
  assert.equal(result.requestId, "r1");
  assert.equal(result.raw, "send the report on tuesday no wait wednesday");
  assert.equal(result.text, "Send the report on Wednesday.");
  assert.equal(result.fallback, false);
  assert.ok(result.ms.total >= 0);
  assert.equal(typeof result.ms.transcribe, "number");
});

test("a recogniser that is still loading is reported as speech-not-ready", async () => {
  const service = makeService({ recognizer: fakeRecognizer("x", { notReady: true, phase: "loading" }) });
  await assert.rejects(
    () => service.transcribeAndPolish({ audio: wavOfSilence(), llm: ROUTE }),
    (error) => error.code === "speech-not-ready",
  );
  assert.equal(service.snapshot().speech.ready, false);
  assert.equal(service.snapshot().speech.phase, "loading");
});

test("malformed audio never reaches the recogniser", async () => {
  const service = makeService({});
  await assert.rejects(() => service.transcribeAndPolish({ audio: Buffer.from("garbage that is definitely not audio") }), (error) => error.code === "invalid-audio");
});

test("the app's dictionary comes with each request and joins config.json's", async () => {
  const model = fakeModel("Send the report on Wednesday.");
  const service = makeService({ model, recognizer: fakeRecognizer("send the typeleast report to deep seek on wednesday"), config: { dictionary: ["TypeLeast"] } });
  await service.transcribeAndPolish({ audio: wavOfSilence(), llm: ROUTE, dictionary: ["DeepSeek", "得普=DeepSeek", "TypeLeast", "  ", 42] });
  const system = model.calls[0].body.messages[0].content;
  for (const entry of ["TypeLeast", "DeepSeek", "得普=DeepSeek"]) assert.ok(system.includes(entry), entry);
  // Nothing is kept between requests.
  assert.deepEqual(service.dictionary, ["TypeLeast"]);
  await service.transcribeAndPolish({ audio: wavOfSilence(), llm: ROUTE });
  assert.ok(!model.calls[1].body.messages[0].content.includes("DeepSeek"));
});

test("only the dictionary entries this dictation mentions reach the model", async () => {
  const model = fakeModel("请把报告发给章伟。");
  const service = makeService({ model, recognizer: fakeRecognizer("请把报告发给张伟"), config: { dictionary: ["内部代号凤凰"] } });
  await service.transcribeAndPolish({ audio: wavOfSilence(), llm: ROUTE, dictionary: ["章伟", "Kubernetes", "李雷", "迪普西克=DeepSeek"] });
  // The cleanup prompt's own examples mention some terms, so look at the dictionary line alone.
  const entriesLine = (call) => (call.body.messages[0].content.match(/^Entries: (.*)$/m) ?? [])[1] ?? null;
  assert.equal(entriesLine(model.calls[0]), "章伟", "a homophone of what was said is kept, nothing else");
  // Nothing related means no dictionary in the request at all.
  await service.polish({ rawText: "明天下午三点开会", strength: "prompt", llm: ROUTE, dictionary: ["章伟", "Kubernetes"] });
  assert.equal(entriesLine(model.calls[1]), null);
  assert.ok(!model.calls[1].body.messages[0].content.includes("Dictionary entries"));
  // The field the user allowed it to read counts too.
  await service.polish({ rawText: "回复他", strength: "prompt", llm: ROUTE, dictionary: ["Kubernetes"],
    fieldContext: { before: "Kubernetes 集群升级完成了吗？", selected: "", after: "", windowTitle: "" } });
  assert.equal(entriesLine(model.calls[2]), "Kubernetes");
});

test("entries marked 「不发给模型」 never reach the model; their heard-as spellings are fixed locally", async () => {
  const model = fakeModel("请把报告发给张为。");
  const service = makeService({ model, recognizer: fakeRecognizer("请把报告发给张为") });
  const result = await service.transcribeAndPolish({ audio: wavOfSilence(), llm: ROUTE, dictionary: ["报告", { local: "张为=章伟" }, { local: "内部代号凤凰" }] });
  const request = JSON.stringify(model.calls[0].body);
  for (const secret of ["章伟", "张为=", "凤凰"]) assert.ok(!request.includes(secret), secret);
  assert.equal(result.text, "请把报告发给章伟。");
  // A local rule also applies when no model route is configured.
  const withoutRoute = await service.polish({ rawText: "发给张为", strength: "prompt", dictionary: [{ local: "张为=章伟" }] });
  assert.equal(withoutRoute.text, "发给章伟");
  const { applyLocalEntries } = await import("../lib/service.js");
  assert.equal(applyLocalEntries("Use deep seek, not deep seeker.", [["deep seek", "DeepSeek"]]), "Use DeepSeek, not deep seeker.");
});

test("a request's dictionary is bounded, trimmed and de-duplicated", async () => {
  const { dictionaryFrom, DICTIONARY_LIMITS } = await import("../lib/service.js");
  assert.deepEqual(dictionaryFrom(["A"], [" B ", "B", "A", "", null, "x".repeat(200)]), ["A", "B", "x".repeat(DICTIONARY_LIMITS.entryLength)]);
  assert.equal(dictionaryFrom([], Array.from({ length: 3000 }, (_, i) => `w${i}`)).length, DICTIONARY_LIMITS.entries);
  assert.deepEqual(dictionaryFrom(["A"], "not a list"), ["A"]);
});

test("snapshot reports readiness, dictionary size and counters", async () => {
  const service = makeService({});
  const before = service.snapshot();
  assert.equal(before.speech.ready, true);
  assert.equal(before.speech.providerId, "sensevoice-local");
  await service.transcribeAndPolish({ audio: wavOfSilence(), llm: ROUTE });
  const after = service.snapshot();
  assert.equal(after.stats.dictations, 1);
  assert.equal(after.stats.polished, 1);
  assert.equal(after.stats.fallback, 0);
  assert.equal(typeof after.promptVersion, "string");
});

test("the target field's text reaches the model in the addendum, redacted", async () => {
  const model = fakeModel("Send the report on Wednesday.");
  const service = makeService({ model });
  await service.polish({
    rawText: RAW,
    appHint: "com.apple.mail",
    llm: ROUTE,
    fieldContext: { before: "Hi Emma, my token is sk-abcdefghijklmnopqrstuvwxyz", selected: "", after: "", windowTitle: "Re: report" },
  });
  const [system, user] = model.calls[0].body.messages;
  assert.match(system.content, /Window title: "Re: report"/);
  assert.match(system.content, /Text before the cursor: "Hi Emma/);
  assert.doesNotMatch(system.content, /sk-abcdefghijklmnop/, "secrets in the field are redacted before leaving");
  assert.equal(user.content, RAW, "the field never leaks into the user message");
});

test("a dictated secret is redacted before it reaches the model", async () => {
  const model = fakeModel("my api key is [redacted-key]");
  const service = makeService({ model });
  await service.polish({ rawText: "my api key is sk-abcdefghijklmnopqrstuvwxyz", llm: ROUTE });
  assert.doesNotMatch(JSON.stringify(model.calls[0].body), /sk-abcdefghijklmnop/);
});

test("dictation language reaches recognition and invalid languages do not run recognition", async () => {
  const languages = [];
  const service = makeService({ recognizer: {
    snapshot: () => ({ ready: true }),
    transcribe: async (_audio, language) => { languages.push(language); return { text: "hello" }; },
  } });
  for (const language of ["auto", "zh", "en", "yue", "ja", "ko"]) {
    await service.transcribeAndPolish({ audio: wavOfSilence(), language, strength: "prompt" });
  }
  assert.deepEqual(languages, ["auto", "zh", "en", "yue", "ja", "ko"]);
  await assert.rejects(service.transcribeAndPolish({ audio: wavOfSilence(), language: "bad" }), { code: "invalid-language" });
  assert.equal(languages.length, 6);
});


test("dictionary secrets are redacted in the actual provider payload", async () => {
  const model = fakeModel("hello");
  const service = makeService({ model, config: { dictionary: ["密码是 fake-secret-123", "sk-test-abcdefghijklmnop"] } });
  await service.polish({ rawText: "hello", llm: ROUTE });
  const payload = JSON.stringify(model.calls);
  assert.ok(!payload.includes("fake-secret-123"));
  assert.ok(!payload.includes("sk-test-abcdefghijklmnop"));
});
