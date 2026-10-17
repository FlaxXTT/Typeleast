import test from "node:test";
import assert from "node:assert/strict";
import { VoicePolishService } from "../lib/service.js";

const RAW = "um so we should send the report on tuesday, no wait, wednesday";

/** A model that streams one answer, or fails in a configured way. */
function fakeLlm(answer, options = {}) {
  const calls = [];
  return {
    calls,
    listProviders: () => (options.noRoutes ? [] : [{ id: "deepseek-account" }, { id: "openrouter" }]),
    stream: (request) => {
      calls.push(request);
      return (async function* generate() {
        if (options.fail) throw options.fail;
        yield { type: "text-delta", index: 0, text: answer };
        yield { type: "finish", reason: options.finish ?? { kind: "stop" } };
      })();
    },
  };
}

function fakeSpeech(text = "we should send the report on tuesday, no wait, wednesday") {
  const prepared = [];
  return {
    prepared,
    snapshot: () => ({
      providers: [{ id: "sensevoice-local", languages: ["auto", "zh"], preparation: { phase: "ready" } }],
      selection: { providerId: "sensevoice-local", language: "auto" },
    }),
    resolve: ({ audio, language }) => ({ provider: { info: { id: "sensevoice-local" } }, audio, language }),
    transcribe: async () => ({ text, audioSeconds: 1, inferenceSeconds: 0.1 }),
    prepare: (id) => prepared.push(id),
  };
}

function makeService({ llm, speech, config = {}, history } = {}) {
  const stored = [];
  return new VoicePolishService({
    ctx: { llm: llm ?? fakeLlm("Send the report on Wednesday."), speechToText: speech ?? fakeSpeech(), sessions: {} },
    config: { provider: "deepseek-account", model: "deepseek-flash", maxOutputTokens: 400, timeoutMs: 5000, strength: "prompt", contextTurns: 2, contextChars: 500, redactSecrets: true, logRaw: true, maxAudioBytes: 4194304, maxDurationSeconds: 120, dictionary: [], ...config },
    history: history ?? { append: async (entry) => { stored.push(entry); return entry; }, recent: async () => stored },
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

test("a clean transcript is polished and reported as such", async () => {
  const llm = fakeLlm("Send the report on Wednesday.");
  const service = makeService({ llm });
  const result = await service.polish({ rawText: RAW, strength: "prompt" });
  assert.equal(result.fallback, false);
  assert.equal(result.text, "Send the report on Wednesday.");
  assert.equal(result.provider, "deepseek-account");
  assert.equal(llm.calls.length, 1);
  // The call must not claim to belong to a session log.
  assert.equal(llm.calls[0].sessionId, undefined);
  assert.equal(llm.calls[0].purpose, undefined);
  assert.equal(llm.calls[0].model, "deepseek-flash");
});

test("polish calls send reasoningEffort=off unless configured otherwise", async () => {
  const send = async (config) => {
    const llm = fakeLlm("Send the report on Wednesday.");
    await makeService({ llm, config }).polish({ rawText: RAW, strength: "prompt" });
    return llm.calls[0];
  };
  // Unset: the adapter would otherwise think at "high" inside maxOutputTokens.
  assert.equal((await send({})).reasoningEffort, "off");
  assert.equal((await send({ reasoningEffort: "low" })).reasoningEffort, "low");
  // "default" defers to the route's own default by sending nothing.
  assert.equal("reasoningEffort" in (await send({ reasoningEffort: "default" })), false);
  // A fallback route may publish no reasoning metadata, and DSH rejects any
  // explicit effort there, so none is sent.
  assert.equal("reasoningEffort" in (await send({ provider: "retired-route", reasoningEffort: "off" })), false);
});

test("the model prompt is the vendored article prompt plus a dictionary addendum", async () => {
  const llm = fakeLlm("Send the report on Wednesday.");
  const service = makeService({ llm, config: { dictionary: ["SenseVoice", "\u7b2c\u56db\u6279=DSH"] } });
  await service.polish({ rawText: RAW, strength: "prompt", appHint: "com.apple.mail" });
  const request = llm.calls[0];
  // The vendored prompt itself, with its own wording.
  assert.match(request.system, /ASR post-processing expert/);
  assert.match(request.system, /output in JSON format/);
  // Our constraints ride in a delimited addendum, never woven into the upstream text.
  assert.match(request.system, /=== HARNESS ADDENDUM \(not part of the upstream prompt\) ===/);
  assert.match(request.system, /Dictionary entries are hard constraints/);
  assert.match(request.system, /SenseVoice/);
  // The user message is the recognised text alone, as the Article article intends:
  // no app name, no register, no list hints, no earlier dictations.
  const body = request.messages[0].content[0].text;
  assert.equal(body, RAW);
});

test("a JSON reply is unwrapped: only its text is inserted, its reason is recorded", async () => {
  const reply = JSON.stringify({ status: "ok", text: "Send the report on Wednesday.", reason: "Fixed the date and removed filler words." });
  const service = makeService({ llm: fakeLlm(reply) });
  const result = await service.polish({ rawText: RAW, strength: "prompt" });
  assert.equal(result.fallback, false);
  assert.equal(result.text, "Send the report on Wednesday.");
  assert.equal(result.outputMode, "json");
  assert.equal(result.modelNote, "Fixed the date and removed filler words.");
  assert.ok(!result.text.includes("{"), "no braces reach the document");
  assert.ok(!result.text.includes("reason"));
});

test("a malformed JSON reply still yields its text field", async () => {
  const reply = 'Here you go: {"status":"ok","text":"Send the report on Wednesday."} — done';
  const service = makeService({ llm: fakeLlm(reply) });
  const result = await service.polish({ rawText: RAW, strength: "prompt" });
  assert.equal(result.fallback, false);
  assert.equal(result.text, "Send the report on Wednesday.");
  assert.equal(result.outputMode, "regex");
});

test("an unusable reply falls back to the transcript and is counted", async () => {
  const service = makeService({ llm: fakeLlm('{"status":"ok","text": }') });
  const result = await service.polish({ rawText: RAW, strength: "prompt" });
  assert.equal(result.fallback, true);
  assert.equal(result.reason, "output-format");
  assert.match(result.detail, /output-format/);
  assert.equal(service.snapshot().stats.jsonFallback, 1);
});

test("an unreachable model falls back to the raw transcript and says why", async () => {
  const stored = [];
  const history = { append: async (entry) => { stored.push(entry); return entry; }, recent: async () => stored };
  const refused = Object.assign(new Error("connect ECONNREFUSED 127.0.0.1:443"), { code: "ECONNREFUSED" });
  const service = makeService({ history, llm: fakeLlm("", { fail: refused }) });
  const result = await service.polish({ rawText: RAW, strength: "prompt" });
  assert.equal(result.fallback, true);
  assert.equal(result.reason, "model-error:ECONNREFUSED");
  assert.equal(result.text, RAW);
  // A transport failure is retried once, and the detail says so.
  assert.equal(result.attempts, 2);
  assert.match(stored[0].detail, /connect ECONNREFUSED 127\.0\.0\.1:443 \(2 attempts, \d+ ms\)$/);
  assert.equal(stored[0].reason, "model-error:ECONNREFUSED");
});

test("model failures are named by what actually went wrong", async () => {
  const cases = [
    [{ finish: { kind: "max-tokens" } }, "model-max-tokens", /token limit/],
    [{ finish: { kind: "tool-calls" } }, "model-tool-calls", /requested a tool/],
    [{ finish: { kind: "error", failure: { message: "quota exhausted", code: "insufficient_quota" } } }, "model-error:insufficient_quota", /quota exhausted/],
    [{ finish: { kind: "aborted" } }, "model-error:aborted", /aborted/],
    [{ finish: { kind: "content-filter" } }, "model-error:finish-content-filter", /unsupported finish reason/],
  ];
  for (const [options, reason, detail] of cases) {
    const stored = [];
    const history = { append: async (entry) => { stored.push(entry); return entry; }, recent: async () => stored };
    const service = makeService({ history, llm: fakeLlm("Send the report on Wednesday.", options) });
    const result = await service.polish({ rawText: RAW, strength: "prompt" });
    assert.equal(result.fallback, true, reason);
    assert.equal(result.reason, reason);
    assert.match(stored[0].detail, detail, reason);
    assert.equal(service.snapshot().stats.lastError.startsWith(`${reason}: `), true, reason);
  }
});

test("a model that outlives the deadline is reported as a timeout, not as unavailable", async () => {
  // The adapter reacts to the abort with its own generic AbortError, as real
  // fetch-based adapters do; the deadline, not that error, names the failure.
  const llm = {
    listProviders: () => [{ id: "deepseek-account" }],
    stream: (request) => (async function* generate() {
      await new Promise((resolve) => request.signal.addEventListener("abort", resolve, { once: true }));
      throw new DOMException("This operation was aborted", "AbortError");
    })(),
  };
  const stored = [];
  const history = { append: async (entry) => { stored.push(entry); return entry; }, recent: async () => stored };
  const service = makeService({ llm, history, config: { timeoutMs: 30 } });
  const result = await service.polish({ rawText: RAW, strength: "prompt" });
  assert.equal(result.reason, "model-timeout");
  assert.equal(result.attempts, 1, "a timeout is never retried");
  assert.match(stored[0].detail, /^deadline of 30 ms exceeded: This operation was aborted \(\d+ ms\)$/);
});

test("a caller that goes away is reported as cancelled", async () => {
  const controller = new AbortController();
  controller.abort(new Error("client disconnected"));
  const service = makeService({ llm: fakeLlm("Send the report on Wednesday.") });
  const result = await service.polish({ rawText: RAW, strength: "prompt", signal: controller.signal });
  assert.equal(result.fallback, true);
  assert.equal(result.reason, "cancelled");
});

test("an answer that invents content is rejected and the raw transcript is used", async () => {
  // A fabricated number is what the fact guard gates: the model answered a
  // question nobody asked.
  const stored = [];
  const history = { append: async (entry) => { stored.push(entry); return entry; }, recent: async () => stored };
  const service = makeService({ history, llm: fakeLlm("We should send the report on Tuesday, then follow up in 3 days.") });
  const result = await service.polish({ rawText: RAW, strength: "prompt" });
  assert.equal(result.fallback, true);
  assert.equal(result.reason, "invented-fact");
  assert.equal(result.text, RAW, "the raw transcript is what the user gets");
  // The detail carries measurements only, never the invented tokens themselves.
  assert.match(stored[0].detail, /inventedFacts=1/);
  assert.ok(!stored[0].detail.includes("3 days"));
});

test("a rejected answer falls back to the TIDIED transcript, like a model failure does", async () => {
  const raw = "呃，我们周三把报告发出去吧。";
  const service = makeService({ llm: fakeLlm("我们周三把报告发出去，然后3天后跟进。") });
  const result = await service.polish({ rawText: raw, strength: "prompt" });
  assert.equal(result.fallback, true);
  assert.equal(result.reason, "invented-fact");
  assert.equal(result.raw, raw);
  assert.equal(result.text, "我们周三把报告发出去。");
  assert.deepEqual(result.postprocess, ["strip-particles"]);
});

test("recent fallbacks are kept for /health, newest first and capped at five", async () => {
  const service = makeService({ llm: fakeLlm("", { finish: { kind: "max-tokens" } }) });
  for (let index = 0; index < 6; index += 1) {
    await service.polish({ rawText: RAW, strength: "prompt", appHint: `app.${index}` });
  }
  const state = service.snapshot();
  assert.equal(state.stats.modelCalls, 6);
  assert.equal(state.stats.modelFallbacks, 6);
  assert.equal(state.recentFailures.length, 5);
  assert.equal(state.recentFailures[0].app, "app.5");
  assert.equal(state.recentFailures[4].app, "app.1");
  assert.equal(state.recentFailures[0].reason, "model-max-tokens");
  assert.equal(typeof state.recentFailures[0].ms, "number");
  assert.equal(typeof state.recentFailures[0].ts, "number");
  // Dictated text never reaches /health.
  assert.ok(!JSON.stringify(state.recentFailures).includes("wednesday"));
  // The snapshot is detached from the live buffer.
  state.recentFailures[0].reason = "mutated";
  assert.equal(service.snapshot().recentFailures[0].reason, "model-max-tokens");
});

test("a successful polish records no failure detail", async () => {
  const stored = [];
  const history = { append: async (entry) => { stored.push(entry); return entry; }, recent: async () => stored };
  const service = makeService({ history });
  await service.polish({ rawText: RAW, strength: "prompt" });
  assert.equal(stored[0].fallback, false);
  assert.equal(stored[0].detail, null);
  assert.equal(service.snapshot().stats.modelCalls, 1);
  assert.equal(service.snapshot().stats.modelFallbacks, 0);
  assert.deepEqual(service.snapshot().recentFailures, []);
});

test("strength=off skips the model entirely", async () => {
  const llm = fakeLlm("should not be used");
  const service = makeService({ llm });
  const result = await service.polish({ rawText: RAW, strength: "off" });
  assert.equal(result.text, RAW);
  assert.equal(result.fallback, false);
  assert.equal(result.reason, "strength-off");
  assert.equal(llm.calls.length, 0);
});

test("an empty transcript is reported without calling the model", async () => {
  const llm = fakeLlm("nope");
  const service = makeService({ llm });
  const result = await service.polish({ rawText: "   ", strength: "prompt" });
  assert.equal(result.fallback, true);
  assert.equal(result.reason, "empty-transcript");
  assert.equal(llm.calls.length, 0);
});

test("the configured route is used when the caller names a dead route", async () => {
  const llm = fakeLlm("Send the report on Wednesday.");
  const service = makeService({ llm, config: { provider: "retired-route" } });
  const result = await service.polish({ rawText: RAW, strength: "prompt" });
  assert.equal(result.provider, "deepseek-account");
});

test("transcribeAndPolish runs recognition then cleanup and reports both timings", async () => {
  const llm = fakeLlm("Send the report on Wednesday.");
  const service = makeService({ llm, speech: fakeSpeech("send the report on tuesday no wait wednesday") });
  const result = await service.transcribeAndPolish({ audio: wavOfSilence(), language: "en", appHint: "com.apple.mail", requestId: "r1" });
  assert.equal(result.requestId, "r1");
  assert.equal(result.raw, "send the report on tuesday no wait wednesday");
  assert.equal(result.text, "Send the report on Wednesday.");
  assert.equal(result.fallback, false);
  assert.ok(result.ms.total >= 0);
  assert.equal(typeof result.ms.transcribe, "number");
});

test("a recogniser that is still loading is reported, and preparation is kicked off", async () => {
  const speech = {
    snapshot: () => ({ providers: [{ id: "sensevoice-local", preparation: { phase: "unprepared" } }], selection: { providerId: "sensevoice-local" } }),
    prepare: (id) => speech.preparedIds.push(id),
    preparedIds: [],
  };
  const service = makeService({ speech });
  await assert.rejects(
    () => service.transcribeAndPolish({ audio: wavOfSilence() }),
    (error) => error.code === "speech-not-ready",
  );
  assert.deepEqual(speech.preparedIds, ["sensevoice-local"]);
});

test("malformed audio never reaches the recogniser", async () => {
  const service = makeService({});
  await assert.rejects(() => service.transcribeAndPolish({ audio: Buffer.from("garbage that is definitely not audio") }), (error) => error.code === "invalid-audio");
});

test("every attempt is recorded before the caller sees the result", async () => {
  const stored = [];
  const history = { append: async (entry) => { stored.push(entry); return entry; }, recent: async () => stored };
  const service = makeService({ history, llm: fakeLlm("Send the report on Wednesday.") });
  await service.transcribeAndPolish({ audio: wavOfSilence(), appHint: "com.apple.mail", language: "en" });
  assert.equal(stored.length, 1);
  assert.equal(stored[0].fallback, false);
  assert.equal(stored[0].app, "com.apple.mail");
  assert.equal(stored[0].text, "Send the report on Wednesday.");
});

test("logRaw=false stores only digests, never the spoken text", async () => {
  const stored = [];
  const history = { append: async (entry) => { stored.push(entry); return entry; }, recent: async () => stored };
  const service = makeService({ history, config: { logRaw: false } });
  // The model is unreachable here, which also proves a failed attempt is
  // recorded: the digest must exist even though polishing fell back.
  const result = await service.polish({ rawText: RAW, strength: "prompt", signal: undefined });
  assert.equal(typeof result.text, "string");
  assert.equal(stored.length, 1, "one attempt must be recorded whether or not the model answered");
  assert.match(stored[0].raw, /^sha256:[0-9a-f]{16}$/);
  assert.match(stored[0].text, /^sha256:[0-9a-f]{16}$/);
  assert.ok(!JSON.stringify(stored[0]).includes("wednesday"));
});

test("learned corrections are persisted and de-duplicated", async () => {
  const service = makeService({});
  const first = await service.learn({ from: "\u7b2c\u56db\u6279", to: "DSH" });
  assert.deepEqual(first.dictionary, ["\u7b2c\u56db\u6279=DSH"]);
  const second = await service.learn({ from: "\u7b2c\u56db\u6279", to: "DSH Pro" });
  assert.deepEqual(second.dictionary, ["\u7b2c\u56db\u6279=DSH Pro"]);
  await assert.rejects(() => service.learn({ from: "", to: "x" }), /non-empty/);
});

test("snapshot reports readiness, dictionary size and counters", async () => {
  const service = makeService({});
  const before = service.snapshot();
  assert.equal(before.speech.ready, true);
  assert.equal(before.speech.providerId, "sensevoice-local");
  await service.transcribeAndPolish({ audio: wavOfSilence() });
  const after = service.snapshot();
  assert.equal(after.stats.dictations, 1);
  assert.equal(after.stats.polished, 1);
  assert.equal(after.stats.fallback, 0);
  assert.equal(typeof after.promptVersion, "string");
});
test("the target field's text reaches the model in the addendum, redacted", async () => {
  const llm = fakeLlm("Send the report on Wednesday.");
  const service = makeService({ llm });
  await service.polish({
    rawText: RAW,
    appHint: "com.apple.mail",
    fieldContext: { before: "Hi Emma, my token is sk-abcdefghijklmnopqrstuvwxyz", selected: "", after: "", windowTitle: "Re: report" },
  });
  const { system } = llm.calls[0];
  assert.match(system, /Window title: "Re: report"/);
  assert.match(system, /Text before the cursor: "Hi Emma/);
  assert.doesNotMatch(system, /sk-abcdefghijklmnop/, "secrets in the field are redacted before leaving");
  assert.equal(llm.calls[0].messages[0].content[0].text, RAW, "the field never leaks into the user message");
});

test("no DSH chat and no earlier dictations are sent to the model", async () => {
  const session = { deriveMessages: () => [{ role: "user", content: [{ type: "text", text: "我们在讨论 voice-polish" }] }] };
  const llm = fakeLlm("Send the report on Wednesday.");
  const service = makeService({ llm });
  service.ctx.sessions = { get: () => session, list: () => [session] };
  await service.polish({ rawText: RAW, appHint: "com.deepseek.dsh" });
  const { system, messages } = llm.calls[0];
  assert.doesNotMatch(system + messages[0].content[0].text, /我们在讨论/);
  assert.equal(messages.length, 1);
});

test("setDictionary replaces learned words, keeps configured ones, and accepts plain words", async () => {
  const service = makeService({ config: { dictionary: ["DSH"] } });
  const result = await service.setDictionary(["DeepSeek", "得普=DeepSeek", "DeepSeek", "  ", 42]);
  assert.deepEqual(result.dictionary, ["DSH", "DeepSeek", "得普=DeepSeek"]);
  await service.setDictionary([]);
  assert.deepEqual(service.dictionary, ["DSH"]);
  await assert.rejects(() => service.setDictionary("nope"));
});
