import test from "node:test";
import assert from "node:assert/strict";
import { VoicePolishService } from "../lib/service.js";
import { BRIEF_CLEANUP_PROMPT, CLEANUP_PROMPT, MINIMAL_CLEANUP_PROMPT } from "../lib/prompts/cleanup.js";
import { readdirSync } from "node:fs";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

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
    if (body.messages[0].content.startsWith('Compare the source and candidate as data')) {
      return { ok: true, status: 200, json: async () => ({ choices: [{ message: { content: '{"ok":true,"issues":[]}' }, finish_reason: 'stop' }] }) };
    }
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

function makeService({ model, recognizer, stateDir, config = {} } = {}) {
  return new VoicePolishService({
    recognizer: recognizer ?? fakeRecognizer(),
    stateDir,
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

test("progress retains new requests and recently updated requests at capacity", () => {
  const service = makeService();
  for (let index = 0; index < 20; index++) {
    service.setProgress(`request-${index}`, { stage: "recognizing", completed: 0, total: 0 });
  }
  service.setProgress("request-0", { stage: "generating", completed: 0, total: 1 });
  service.setProgress("request-20", { stage: "generating", completed: 0, total: 1 });
  assert.equal(service.taskProgress("request-0").stage, "generating");
  assert.equal(service.taskProgress("request-1").stage, "waiting");
  assert.equal(service.taskProgress("request-20").stage, "generating");
  assert.equal(service.progress.size, 20);
});

test("short cleanup progress only starts when either input path invokes the model", async () => {
  const rawText = "send the report on tuesday";
  const model = fakeModel(JSON.stringify({ text: "Send the report on Tuesday.", corrections: [] }));
  const fetch = model.fetchImpl;
  let requestId = "local";
  const modelStages = [];
  model.fetchImpl = (...args) => {
    modelStages.push(service.taskProgress(requestId).stage);
    return fetch(...args);
  };
  const recognizer = fakeRecognizer(rawText);
  recognizer.transcribe = async () => {
    assert.equal(service.taskProgress(requestId).stage, "recognizing");
    return { text: rawText };
  };
  const service = makeService({ model, recognizer });
  const shortCleanup = { maxUnits: 25, fullAbove: 100 };
  await service.transcribeAndPolish({ audio: wavOfSilence(), llm: ROUTE, shortCleanup, requestId });
  requestId = "online";
  await service.polish({ rawText, llm: ROUTE, shortCleanup, requestId });
  requestId = "raw-only";
  await service.polish({ rawText, llm: ROUTE, shortCleanup, requestId, skipCleanup: true });
  assert.deepEqual(modelStages, ["generating", "generating"]);
  assert.equal(service.taskProgress("raw-only").stage, "waiting");
});

test('language conversion uses the recognizer\'s effective language, not an unsupported saved hint', async () => {
  const recognizer = { transcribe: async () => ({ text: '会社の設定', language: 'auto', detectedLanguage: null }) };
  const service = makeService({ recognizer });
  const result = await service.transcribe(Buffer.alloc(0), 'zh');
  assert.equal(result.language, 'auto');
  assert.equal(result.text, '会社の設定');
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

test("without an API key the tidied transcript is held and nothing is called", async () => {
  const model = fakeModel("should not be used");
  const service = makeService({ model });
  const result = await service.polish({ rawText: "呃，我们周三把报告发出去吧。", strength: "prompt" });
  assert.ok(result.fallback || result.uncertain, 'not a clean pass');
  assert.equal(result.reason, "no-api-key");
  assert.equal(result.text, "我们周三把报告发出去。");
  assert.equal(model.calls.length, 0);
  assert.equal(result.reason, "no-api-key");
  // A malformed route counts as no route: it is never half-used.
  const insecure = await service.polish({ rawText: RAW, llm: { ...ROUTE, baseURL: "http://api.example.com/v1" } });
  assert.equal(insecure.reason, "no-api-key");
  assert.equal(model.calls.length, 0);
  assert.notEqual(result.text, '', 'a result is inserted, never held');
  assert.equal(result.clarification, undefined);
});

test("the model gets the cleanup prompt, the learned description and the transcript as JSON", async () => {
  const model = fakeModel("Send the report on Wednesday.");
  const service = makeService({ model });
  await service.polish({ rawText: RAW, strength: "prompt", appHint: "com.apple.mail", llm: ROUTE, profile: "写周报的产品经理" });
  const [system, user] = model.calls[0].body.messages;
  assert.equal(system.role, "system");
  assert.ok(system.content.startsWith("# Profile"));
  assert.match(system.content, /User background \(learned from earlier dictations\): 写周报的产品经理/);
  assert.match(system.content, /Application identifier: "com\.apple\.mail"/);
  assert.doesNotMatch(system.content, /Window title:|Text before the cursor:/);
  assert.equal(user.role, "user");
  assert.deepEqual(JSON.parse(user.content), { raw_asr_transcript: RAW });
  assert.equal(model.calls[0].body.messages.length, 2);
});

test("saving the ASR Engineering prompt changes the next dictation on both recognition paths", async (t) => {
  const stateDir = await mkdtemp(join(tmpdir(), "typeleast-asr-prompt-"));
  t.after(() => rm(stateDir, { recursive: true, force: true }));
  const file = join(stateDir, "asr-engineering.md");
  const model = fakeModel('{"text":"Send the report on Wednesday."}');
  const service = makeService({ model, stateDir });
  const input = { rawText: RAW, llm: ROUTE };
  const currentPrompt = () => model.calls.at(-1).body.messages[0].content;

  await service.polish(input);
  assert.equal(currentPrompt(), CLEANUP_PROMPT);

  await writeFile(file, "  Preserve the original paragraph breaks.  ");
  await service.polish({ ...input, profile: "研究者", fieldContext: { before: "项目邮件" } });
  assert.match(currentPrompt(), /^Preserve the original paragraph breaks\./);
  assert.match(currentPrompt(), /User background .*研究者/);
  assert.match(currentPrompt(), /Return a JSON object with a string "text"/);
  assert.match(currentPrompt(), /Text before the cursor: "项目邮件"/);
  assert.doesNotMatch(currentPrompt(), /# Core Strategies/);

  await writeFile(file, "Keep each sentence short.");
  const result = await service.transcribeAndPolish({ audio: wavOfSilence(), llm: ROUTE });
  assert.equal(result.fallback, false);
  assert.match(currentPrompt(), /^Keep each sentence short\./);

  await service.polish({ ...input, translateTo: "en" });
  assert.doesNotMatch(currentPrompt(), /Keep each sentence short/);

  await rm(file);
  await service.polish(input);
  assert.equal(currentPrompt(), CLEANUP_PROMPT);
});

test("the brief prompt reloads from its own file for both recognition paths", async (t) => {
  const stateDir = await mkdtemp(join(tmpdir(), "typeleast-brief-prompt-"));
  t.after(() => rm(stateDir, { recursive: true, force: true }));
  const file = join(stateDir, "brief-cleanup.md");
  const rawText = "请把测试结果和原始截图一起发给项目组，保留图表的标题和说明，等大家看完之后再约时间讨论，今天不用先下结论。";
  const shortCleanup = { maxUnits: 25, fullAbove: 100 };
  const model = fakeModel(JSON.stringify({ text: rawText }));
  const service = makeService({ model, stateDir, recognizer: fakeRecognizer(rawText) });
  const currentPrompt = () => model.calls.at(-1).body.messages[0].content;
  const input = { rawText, llm: ROUTE, shortCleanup };

  await service.polish(input);
  assert.equal(currentPrompt(), BRIEF_CLEANUP_PROMPT);

  await writeFile(file, "Keep the speaker's pauses as short sentences.");
  await service.polish({ ...input, profile: "Private profile", fieldContext: { before: "Private cursor context" } });
  assert.match(currentPrompt(), /^Keep the speaker's pauses as short sentences\./);
  assert.match(currentPrompt(), /Return one JSON object with a string "text"/);
  assert.doesNotMatch(currentPrompt(), /Private profile|Private cursor context/);

  await writeFile(file, "Keep only paragraph breaks at topic changes.");
  await service.transcribeAndPolish({ audio: wavOfSilence(), llm: ROUTE, shortCleanup });
  assert.match(currentPrompt(), /^Keep only paragraph breaks at topic changes\./);

  await writeFile(join(stateDir, "asr-engineering.md"), "Use the separate full cleanup prompt.");
  await service.polish({ ...input, rawText: rawText + rawText + rawText });
  assert.match(currentPrompt(), /^Use the separate full cleanup prompt\./);

  for (const restored of [BRIEF_CLEANUP_PROMPT, "  \n "]) {
    await writeFile(file, restored);
    await service.polish(input);
    assert.equal(currentPrompt(), BRIEF_CLEANUP_PROMPT);
  }
});

test("a success reply inserts its text; corrections and intention come back for the history", async () => {
  const reply = JSON.stringify({ status: "success", "Terminology correction": [{ asr_error: "哭达", corrected_term: "CUDA", reason: "显存报错" }],
    "user intention": "1. 修复显存溢出", text: "修复 CUDA out of memory。" });
  const service = makeService({ model: fakeModel(reply) });
  const result = await service.polish({ rawText: "修复哭达 out of memory", llm: ROUTE });
  assert.equal(result.fallback, false);
  assert.equal(result.text, "修复 CUDA out of memory。");
  assert.deepEqual(result.corrections, [{ from: "哭达", to: "CUDA", reason: "显存报错" }]);
  assert.equal(result.intention, "1. 修复显存溢出");
});

test("redundant punctuation the model keeps is removed; code and quotes are not touched", async () => {
  const reply = JSON.stringify({ status: "success", text: "禁止二级标题。，话术要简明。，运行 `a.,b` 和“好，。”" });
  const service = makeService({ model: fakeModel(reply) });
  const result = await service.polish({ rawText: "禁止二级标题", llm: ROUTE });
  assert.equal(result.text, "禁止二级标题。话术要简明。运行 `a.,b` 和“好，。”");
});

test("the description of the user's work is built from history items in one call", async () => {
  const model = fakeModel("从事流体仿真，常用 OpenFOAM。");
  const service = makeService({ model });
  const result = await service.buildProfile({ llm: ROUTE, items: [{ corrections: [{ from: "欧喷丰", to: "OpenFOAM" }], intention: "跑 LES" }] });
  assert.equal(result.profile, "从事流体仿真，常用 OpenFOAM。");
  assert.match(model.calls[0].body.messages[1].content, /欧喷丰 → OpenFOAM/);
  assert.deepEqual(await service.buildProfile({ llm: ROUTE, items: [] }), { profile: "" });
  assert.equal(model.calls.length, 1, "nothing to learn from, no call");
  await assert.rejects(service.buildProfile({ llm: null, items: [] }), { code: "no-api-key" });
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
  assert.ok(result.fallback || result.uncertain, 'not a clean pass');
  assert.equal(result.detail, "output-format:unexpected-status");
  const everywhere = JSON.stringify([service.snapshot(), warnings]);
  assert.ok(!everywhere.includes("wednesday report"), everywhere);
});

test("an unusable reply falls back to the transcript and is counted", async () => {
  const service = makeService({ model: fakeModel('{"status":"ok","text": }') });
  const result = await service.polish({ rawText: RAW, strength: "prompt", llm: ROUTE });
  assert.ok(result.fallback || result.uncertain, 'not a clean pass');
  assert.equal(result.reason, "output-format");
  assert.match(result.detail, /output-format/);
  assert.equal(service.snapshot().stats.jsonFallback, 1);
  assert.notEqual(result.text, '', 'a result is inserted, never held');
  assert.equal(result.clarification, undefined);
});

test("an unreachable model falls back to the raw transcript, retried once, and says why", async () => {
  const refused = new TypeError("fetch failed", { cause: Object.assign(new Error("connect ECONNREFUSED"), { code: "ECONNREFUSED" }) });
  const service = makeService({ model: fakeModel("", { fail: refused }) });
  const result = await service.polish({ rawText: RAW, strength: "prompt", llm: ROUTE });
  assert.ok(result.fallback || result.uncertain, 'not a clean pass');
  assert.equal(result.reason, "model-error:NETWORK");
  assert.equal(result.text, RAW);
  assert.equal(result.attempts, 2);
  assert.match(result.detail, /^api\.example\.com unreachable: fetch failed \(2 attempts, \d+ ms\)$/);
  assert.ok(!result.detail.includes(ROUTE.apiKey));
  assert.notEqual(result.text, '', 'a result is inserted, never held');
  assert.equal(result.clarification, undefined);
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
  assert.equal(result.attempts, 2, "a timeout has one shared retry");
  assert.match(result.detail, /^no answer from api\.example\.com within 30 ms/);
  assert.notEqual(result.text, '', 'a result is inserted, never held');
  assert.equal(result.clarification, undefined);
});

test("a caller that goes away is reported as cancelled", async () => {
  const controller = new AbortController();
  controller.abort(new Error("client disconnected"));
  const service = makeService({});
  const result = await service.polish({ rawText: RAW, strength: "prompt", signal: controller.signal, llm: ROUTE });
  assert.ok(result.fallback || result.uncertain, 'not a clean pass');
  assert.equal(result.reason, "cancelled");
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
  assert.equal(service.snapshot().stats.modelCalls, 2);
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

test("a dictation-only cleanup switch preserves the transcript without contacting the model", async () => {
  const model = fakeModel("Send the report on Wednesday.");
  const service = makeService({ model });
  const result = await service.polish({ rawText: RAW, llm: ROUTE, skipCleanup: true });
  assert.equal(result.text, RAW);
  assert.equal(result.fallback, false);
  assert.equal(model.calls.length, 0);
  await service.polish({ rawText: RAW, llm: ROUTE, task: "translation", translateTo: "en", skipCleanup: true });
  assert.ok(model.calls.length > 0);
});

test("short dictation uses the recognized length, ignoring punctuation and counting mixed scripts", async () => {
  const model = fakeModel('{"text":"我用 TypeLeast。"}');
  const spoken = "我用 TypeLeast！";
  const service = makeService({ model, recognizer: fakeRecognizer(spoken) });
  const request = { audio: wavOfSilence(), llm: ROUTE, shortCleanup: { maxUnits: 3 } };
  const short = await service.transcribeAndPolish(request);
  assert.equal(short.text, spoken);
  assert.equal(short.fallback, false);
  assert.equal(model.calls.length, 0);
  const long = await service.transcribeAndPolish({ ...request, shortCleanup: { maxUnits: 2 } });
  assert.equal(long.model, ROUTE.model);
  assert.equal(model.calls.length, 1);
});

test("the small model gets only the short transcript and can lightly format it", async () => {
  const model = fakeModel('{"text":"Meet at 14:30."}');
  const service = makeService({ model });
  const small = { baseURL: "https://small.example.com/v1", model: "small-model", apiKey: "test-key" };
  const result = await service.polish({ rawText: "meet at 14:30", llm: ROUTE,
    shortCleanup: { maxUnits: 4, route: small }, profile: "profile stays private", fieldContext: { before: "private" } });
  assert.equal(result.text, "Meet at 14:30.");
  assert.equal(result.model, small.model);
  assert.equal(model.calls.length, 1);
  assert.equal(model.calls[0].url, `${small.baseURL}/chat/completions`);
  assert.equal(model.calls[0].body.model, small.model);
  assert.deepEqual(JSON.parse(model.calls[0].body.messages[1].content), { transcript: "meet at 14:30" });
  assert.ok(!JSON.stringify(model.calls[0].body).includes("private"));
});

test("small model failures, expansion, and changed numbers return the transcript with no model failover", async () => {
  const rawText = "明天14:30开会";
  const small = { ...ROUTE, model: "small-model" };
  const request = { rawText, llm: ROUTE, shortCleanup: { maxUnits: 12, route: small },
    llmBackups: [{ ...ROUTE, model: "backup" }], hasConfiguredBackups: true };
  for (const model of [fakeModel("", { status: 503 }), fakeModel('{"text":"明天下午14:30开会，请提前准备好所有的资料。"}'),
    fakeModel('{"text":"明天1430开会。"}')]) {
    const result = await makeService({ model }).polish(request);
    assert.equal(result.text, rawText);
    assert.equal(result.fallback, false);
    assert.equal(result.offerFailover, undefined);
    assert.deepEqual(model.calls.map(call => call.body.model), [small.model]);
  }
  const model = fakeModel("unexpected call");
  const result = await makeService({ model }).polish({ ...request, shortCleanup: { maxUnits: 12, route: ROUTE } });
  assert.equal(result.text, rawText);
  assert.equal(model.calls.length, 0);
});

test("short dictation routing leaves explicit translation and assistant on the configured model", async () => {
  for (const task of ["translation", "assistant"]) {
    const model = fakeModel('{"text":"Ready"}');
    const service = makeService({ model });
    await service.polish({ rawText: "准备好了", task, translateTo: task === "translation" ? "en" : undefined,
      llm: ROUTE, shortCleanup: { maxUnits: 12 } });
    assert.ok(model.calls.length > 0);
    assert.ok(model.calls.every(call => call.body.model === ROUTE.model));
  }
});

test("three-tier dictation uses a separate prompt at 25, 26–100, and 101", async () => {
  const shortCleanup = { maxUnits: 25, fullAbove: 100 };
  const llm = { baseURL: "https://api.deepseek.com", model: "deepseek-flash", apiKey: "test-key", reasoningEffort: "low" };
  for (const units of [25, 26, 100, 101]) {
    const rawText = "字".repeat(units) + "。";
    const model = fakeModel(JSON.stringify({ text: rawText }));
    const result = await makeService({ model }).polish({ rawText, llm, shortCleanup, profile: "test profile" });
    assert.equal(result.text, rawText);
    assert.equal(model.calls.length, 1);
    const body = model.calls[0].body;
    assert.equal(body.thinking.type, units <= 100 ? "disabled" : "enabled");
    assert.equal(body.reasoning_effort, units <= 100 ? undefined : "low");
    if (units === 25) assert.equal(body.messages[0].content, MINIMAL_CLEANUP_PROMPT);
    else {
      assert.match(body.messages[0].content, units <= 100 ? /Number only distinct/ : /numbered points/);
    }
    assert.match(body.messages[0].content, /fix (?:clear|likely) ASR errors|repair ASR errors supported by context/i);
    assert.match(body.messages[0].content, /local grammar|make their logic clear|logic easy to follow/i);
    assert.equal(body.messages[0].content.includes("test profile"), units > 100);
  }
});

test("minimal cleanup smooths local wording without rewriting the dictation", async () => {
  const llm = ROUTE;
  const shortCleanup = { maxUnits: 25, fullAbove: 100, useSmallModel: true, route: { ...ROUTE, model: "small" } };
  const fix = (asr_error, corrected_term) => ({ asr_error, corrected_term });
  const cases = [
    ["呃，快递的乌流有点怪。", "呃，快递的物流有点怪。", [fix("乌流", "物流")], true],
    ["呃，想把文见，早尽移过来。", "想把文件尽早移过来。", [fix("文见", "文件"), fix("早尽", "尽早")], true],
    ["呃，今天见", "今天见。", [], true],
    ["这个方案有点野。", "这个方案有点野。", [], true],
    ["请用 Cloud Code 查看项目代码。", "请用 Claude Code 查看项目代码。", [fix("Cloud", "Claude")], true],
    ["天上那片 Claude 把太阳挡住了。", "天上那片 cloud 把太阳挡住了。", [fix("Claude", "cloud")], true],
    ["把备份放到 cloud 存储里。", "把备份放到 cloud 存储里。", [], true],
    ["继续检查这个 cloud code 的结果。", "继续检查这个 cloude code 和 K8s 的结果。", [fix("cloud code", "cloude code 和 K8s")], false],
    ["请查快递的乌流！", "请查询快递的物流。", [fix("乌流", "物流")], "请查快递的物流！"],
    ["明天不开会。", "明天要开会。", [fix("不", "要")], false],
    ["明天有 3 场会。", "明天有 4 场会。", [fix("3", "4")], false],
    ["明天可能开会。", "明天一定开会。", [fix("可能", "一定")], false],
    ["请把项目交给服务台。", "项目已经交给服务台。", [fix("请把项目交给", "项目已经交给")], false],
    ['原话是「快递的乌流」。', '原话是「快递的物流」。', [fix("乌流", "物流")], false],
  ];
  for (const [rawText, text, corrections, accepted] of cases) {
    const model = fakeModel(JSON.stringify({ text, corrections }));
    const service = makeService({ model });
    const result = await service.polish({ rawText, llm, shortCleanup, fieldContext: { before: "Private cursor context" } });
    assert.equal(result.text, typeof accepted === "string" ? accepted : accepted ? text : rawText);
    assert.equal(model.calls.length, 1);
    assert.equal(model.calls[0].body.model, llm.model);
    assert.deepEqual(JSON.parse(model.calls[0].body.messages[1].content), { raw_asr_transcript: rawText });
    assert.equal(result.corrections, undefined);
  }
});

test("the short tier and full tier use supplied nearby text, and all tiers get the current app", async () => {
  const shortCleanup = { maxUnits: 25, fullAbove: 100 };
  for (const units of [25, 26, 101]) {
    const rawText = "字".repeat(units);
    const model = fakeModel(JSON.stringify({ text: rawText }));
    const result = await makeService({ model }).polish({
      rawText, llm: ROUTE, shortCleanup, appHint: "com.example.editor",
      profile: "Context from past sessions",
      fieldContext: { before: "Text beside the cursor" },
    });
    assert.equal(result.text, rawText);
    const system = model.calls[0].body.messages[0].content;
    assert.match(system, /whole utterance/i);
    assert.match(system, /Application identifier: "com\.example\.editor"/);
    assert.match(system, /Honor explicit spelling and self-corrections/);
    assert.equal(system.includes("Text beside the cursor"), units !== 26);
    assert.equal(system.includes("Context from past sessions"), units > 100);
  }
});

test("short mixed-language ASR repairs retain exact replacements if the model also paraphrases", async () => {
  const shortCleanup = { maxUnits: 25, fullAbove: 100 };
  for (const fixture of [
    {
      raw: "我想使用 Cloud Code 去构建这个软件。",
      scene: "使用 Anthropic 的编程代理 Claude Code",
      text: "我想用 Claude Code 构建这个软件。",
      from: "Cloud Code", to: "Claude Code",
    },
    {
      raw: "我打算用 Claude Code 调试集群。",
      scene: "用 Google Cloud 的 Cloud Code 插件调试 Kubernetes 应用",
      text: "我想用 Cloud Code 调试集群。",
      from: "Claude Code", to: "Cloud Code",
    },
  ]) {
    const model = fakeModel(JSON.stringify({ text: fixture.text,
      corrections: [{ asr_error: fixture.from, corrected_term: fixture.to }] }));
    const result = await makeService({ model }).polish({ rawText: fixture.raw, llm: ROUTE, shortCleanup,
      appHint: "com.example.editor",
      fieldContext: { before: "Omitted distant text. " + "Earlier notes. ".repeat(40) + "API key: " + ROUTE.apiKey + " " + fixture.scene,
        selected: "Selected text stays out of the short prompt", windowTitle: "Project notes" },
    });
    assert.equal(result.text, fixture.raw.replace(fixture.from, fixture.to));
    const system = model.calls[0].body.messages[0].content;
    assert.match(system, /Compare plausible sound-alikes/);
    assert.ok(system.includes(fixture.scene));
    assert.match(system, /Window title: "Project notes"/);
    assert.doesNotMatch(system, /Omitted distant text|Selected text stays out|sk-test-123456789012/);
    assert.equal(model.calls.length, 1);
  }
});

test("explicit letters survive cleanup in either direction, regardless of the app", async () => {
  const shortCleanup = { maxUnits: 25, fullAbove: 100 };
  const continuation = "这里是前面已经说过的解释。";
  for (const repeat of [0, 3, 10]) {
    const suffix = "。" + continuation.repeat(repeat);
    for (const [spelled, correct, wrong] of [
      ["C-L-O-U-D", "cloud", "Claude"],
      ["C-L-A-U-D-E", "Claude", "cloud"],
      ["C L O U D", "cloud", "cloudflare"],
      ["Δ-Ε-Λ-Τ-Α", "ΔΕΛΤΑ", "ΔΕΛΤΑΣ"],
    ]) {
      const rawText = "这个词拼成" + spelled + suffix;
      for (const [term, expected] of [[correct, "这个词拼成" + correct + suffix], [wrong, rawText]]) {
        const model = fakeModel(JSON.stringify({ text: "这个词拼成" + term + suffix, corrections: [] }));
        const result = await makeService({ model }).polish({ rawText, llm: ROUTE, shortCleanup, appHint: "com.example.terminal" });
        assert.equal(result.text, expected);
        assert.equal(result.qualityReview, undefined);
        assert.equal(model.calls.length, 1);
      }
    }
  }
});

test("cleanup keeps a corrected word once and discards dictated spelling echoes", async () => {
  const shortCleanup = { maxUnits: 25, fullAbove: 100 };
  for (const repeat of [0, 3, 10]) {
    const rest = "。" + "后面还要检查连接和同步是否正常。".repeat(repeat);
    for (const [raw, draft, corrections] of [
      ["我想打开 Tailscale，p a i r s c a l e", "我想打开 Tailscale，P-A-I-R-S-C-A-L-E", []],
      ["我想打开 Paint，T-A-I-L-S-C-A-L-E", "我想打开 Tailscale，T-A-I-L-S-C-A-L-E",
        [{ asr_error: "Paint", corrected_term: "Tailscale" }]],
    ]) {
      const model = fakeModel(JSON.stringify({ text: draft + rest, corrections }));
      const result = await makeService({ model }).polish({ rawText: raw + rest, llm: ROUTE, shortCleanup });
      assert.equal(result.text, "我想打开 Tailscale" + rest);
      assert.equal(model.calls.length, 1);
    }
  }
});

test("the minimal prompt reloads from its own file", async (t) => {
  const stateDir = await mkdtemp(join(tmpdir(), "typeleast-minimal-prompt-"));
  t.after(() => rm(stateDir, { recursive: true, force: true }));
  await writeFile(join(stateDir, "minimal-cleanup.md"), "Use related terminology to read a short transcript.");
  const rawText = "这是原话。";
  const model = fakeModel(JSON.stringify({ text: rawText, corrections: [] }));
  const service = makeService({ model, stateDir, recognizer: fakeRecognizer(rawText) });
  await service.transcribeAndPolish({ audio: wavOfSilence(), llm: ROUTE, shortCleanup: { maxUnits: 25, fullAbove: 100 } });
  const prompt = model.calls[0].body.messages[0].content;
  assert.match(prompt, /^Use related terminology/);
  assert.match(prompt, /Fix clear ASR errors and local grammar while preserving meaning/);
});

test("a verified thinking toggle applies to full cleanup and keeps brief cleanup lightweight", async () => {
  const llm = { ...ROUTE, baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1",
    thinkingMode: "enabled", thinkingControl: "enableThinking" };
  for (const units of [26, 101]) {
    const rawText = "字".repeat(units) + "。";
    const model = fakeModel(JSON.stringify({ text: rawText }));
    const service = makeService({ model });
    await service.polish({ rawText, llm, shortCleanup: { maxUnits: 25, fullAbove: 100 } });
    assert.equal(model.calls[0].body.enable_thinking, units > 100);
  }
});

test("a brief tier configured for a small model never forwards failures to the main model", async () => {
  const rawText = "字".repeat(26);
  const model = fakeModel("", { status: 503 });
  const briefModel = { ...ROUTE, model: "small-model" };
  const shortCleanup = { maxUnits: 25, fullAbove: 100, useSmallModel: true, route: briefModel };
  const service = makeService({ model });
  const request = { rawText, llm: ROUTE, shortCleanup, hasConfiguredBackups: true };
  const result = await service.polish(request);
  assert.equal(result.text, rawText);
  assert.equal(result.fallback, false);
  await service.polish({ ...request, shortCleanup: { ...shortCleanup, route: null } });
  assert.deepEqual(model.calls.map(call => call.body.model), [briefModel.model]);
});

test("an empty transcript is reported without calling the model", async () => {
  const model = fakeModel("nope");
  const service = makeService({ model });
  const result = await service.polish({ rawText: "   ", strength: "prompt", llm: ROUTE });
  assert.ok(result.fallback || result.uncertain, 'not a clean pass');
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

test("snapshot reports readiness and counters", async () => {
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
  assert.deepEqual(JSON.parse(user.content), { raw_asr_transcript: RAW }, "the field never leaks into the user message");
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

test("the recommendation comes only from the app's official page, read from the network", async () => {
  const page = "<html><script>ignored</script><body>Claude Opus 5.5 is our most capable model. Claude Sonnet 5.5 balances speed.</body>" + " ".repeat(300) + "x".repeat(200) + "</html>";
  const calls = [];
  let answer = JSON.stringify({ model: "Claude Opus 5.5", reason: "适合复杂任务" });
  let online = true;
  const fetchImpl = async (url, init) => {
    calls.push({ url: String(url), body: init.body });
    if (String(url).includes("/chat/completions")) {
      return { ok: true, status: 200, json: async () => ({ choices: [{ message: { content: answer }, finish_reason: "stop" }] }) };
    }
    if (!online) throw new Error("offline");
    return { ok: true, status: 200, url: String(url), text: async () => page };
  };
  const service = new VoicePolishService({ recognizer: fakeRecognizer(), config: { timeoutMs: 1000 }, fetchImpl });
  const task = "重构这个模块，我的密码是 hunter2";

  const none = await service.recommendModel({ llm: ROUTE, appHint: "com.apple.Notes", windowTitle: "", task });
  assert.deepEqual(none, { recommendation: null, notice: "unsupported-app" });
  assert.equal(calls.length, 0);

  const good = await service.recommendModel({ llm: ROUTE, appHint: "com.anthropic.claudefordesktop", windowTitle: "", task });
  assert.deepEqual(good.recommendation, { app: "Claude", model: "Claude Opus 5.5", reason: "适合复杂任务", source: "platform.claude.com" });
  assert.equal(calls[0].url, "https://platform.claude.com/docs/en/models/overview");
  assert.equal(calls[0].body, undefined);
  const sent = calls.find(c => c.url.includes("/chat/completions")).body;
  assert.match(sent, /most capable model/);
  assert.doesNotMatch(sent, /ignored|hunter2/);

  answer = JSON.stringify({ model: "Claude Opus 9", reason: "凭记忆" });
  const invented = await service.recommendModel({ llm: ROUTE, appHint: "com.anthropic.claudefordesktop", task });
  assert.equal(invented.recommendation, null);
  assert.equal(invented.notice, "no-match");

  online = false;
  const titled = await service.recommendModel({ llm: ROUTE, appHint: "com.google.Chrome", windowTitle: "ChatGPT - Google Chrome", task });
  assert.equal(titled.recommendation, null);
  assert.equal(titled.notice, "page-unavailable");
  assert.equal(titled.app, "ChatGPT");
});
