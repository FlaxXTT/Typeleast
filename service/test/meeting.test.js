import test from "node:test";
import assert from "node:assert/strict";
import { chmod, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { MAX_MEETING_BYTES, MAX_MEETING_SECONDS, meetingTokenBudget, MeetingJobs } from "../lib/tasks/meeting.js";
import { MossRecognizer } from "../lib/moss-recognizer.js";
import { SpeechModels } from "../lib/speech-models.js";
import { createHandler, ROUTE_PREFIX } from "../lib/http.js";

const wav = (seconds = 1, fill = 3) => {
  const bytes = seconds * 32000;
  const header = Buffer.alloc(44);
  header.write("RIFF", 0); header.writeUInt32LE(36 + bytes, 4); header.write("WAVE", 8); header.write("fmt ", 12); header.writeUInt32LE(16, 16);
  header.writeUInt16LE(1, 20); header.writeUInt16LE(1, 22); header.writeUInt32LE(16000, 24); header.writeUInt32LE(32000, 28);
  header.writeUInt16LE(2, 32); header.writeUInt16LE(16, 34); header.write("data", 36); header.writeUInt32LE(bytes, 40);
  return Buffer.concat([header, Buffer.alloc(bytes, fill)]);
};
const settled = async (jobs, id) => {
  for (let tries = 0; tries < 6000; tries += 1) {
    const state = jobs.status(id);
    if (!["preparing", "transcribing"].includes(state.phase)) return state;
    await new Promise(resolve => setTimeout(resolve, 5));
  }
  throw new Error("job did not finish");
};
const turns = [{ start: 0.1, end: 1, speaker: "S01", text: "先看日志。" }, { start: 1.2, end: 2, speaker: "S02", text: "已经回滚了。" }];

test("a finished job keeps every speaker label and time", async () => {
  let asked;
  const jobs = new MeetingJobs({ recognizer: async () => ({ transcribe: async (audio, language, signal, options) => {
    asked = { language, maxNew: options.maxNew };
    return { text: "先看日志。已经回滚了。", segments: turns, speakers: ["S01", "S02"], detectedLanguage: "zh" };
  } }) });
  const state = await settled(jobs, jobs.start({ audio: wav(600), language: "zh" }));
  assert.equal(state.phase, "done");
  assert.deepEqual(state.result.segments, turns);
  assert.deepEqual(state.result.speakers, ["S01", "S02"]);
  assert.equal(state.result.truncated, false);
  assert.equal(state.seconds, 600);
  assert.deepEqual(asked, { language: "zh", maxNew: 9000 });
});

test("a turn without an end time reports a transcript cut off by the token budget", async () => {
  const jobs = new MeetingJobs({ recognizer: async () => ({ transcribe: async () => ({ segments: [{ start: 0, end: null, speaker: "S01", text: "x" }], speakers: ["S01"], text: "x" }) }) });
  assert.equal((await settled(jobs, jobs.start({ audio: wav() }))).result.truncated, true);
});

test("a recording past the limit, a second job and a missing model are refused plainly", async () => {
  let release;
  const held = new Promise(resolve => { release = resolve; });
  const jobs = new MeetingJobs({ recognizer: async () => ({ transcribe: async () => { await held; return { segments: [] }; } }) });
  const header = wav(1).subarray(0, 44);
  header.writeUInt32LE(36 + (MAX_MEETING_SECONDS + 1) * 32000, 4); header.writeUInt32LE((MAX_MEETING_SECONDS + 1) * 32000, 40);
  assert.throws(() => jobs.start({ audio: Buffer.concat([header, Buffer.alloc((MAX_MEETING_SECONDS + 1) * 32000)]) }), { code: "invalid-audio" });
  const id = jobs.start({ audio: wav() });
  assert.throws(() => jobs.start({ audio: wav() }), { code: "busy" });
  release();
  await settled(jobs, id);
  assert.throws(() => jobs.status("other"), { code: "meeting-not-found" });
  const missing = new MeetingJobs({ recognizer: async () => { throw Object.assign(new Error("no"), { code: "model-not-installed" }); } });
  const state = await settled(missing, missing.start({ audio: wav() }));
  assert.equal(state.phase, "failed");
  assert.equal(state.code, "model-not-installed");
});

test("cancelling stops the engine and forgets the job", async () => {
  let aborted = false;
  const jobs = new MeetingJobs({ recognizer: async () => ({ transcribe: (audio, language, signal) => new Promise((resolve, reject) => {
    signal.addEventListener("abort", () => { aborted = true; reject(signal.reason); });
  }) }) });
  const id = jobs.start({ audio: wav() });
  await new Promise(resolve => setTimeout(resolve, 5));
  assert.equal(jobs.cancel(id), true);
  await new Promise(resolve => setTimeout(resolve, 5));
  assert.equal(aborted, true);
  assert.throws(() => jobs.status(id), { code: "meeting-not-found" });
  assert.equal(jobs.cancel(id), false);
});

test("meetings get their own engine, whichever model dictates", async () => {
  const made = [];
  const models = new SpeechModels({ modelsDir: "/none", selectionPath: join(tmpdir(), "no-such-selection.json"), factory: id => {
    made.push(id);
    return { phase: "ready", prepare: async () => id === "moss-transcribe-diarize" && models.missing ? "missing-model" : "ready" };
  } });
  const first = await models.meetingRecognizer();
  assert.equal(await models.meetingRecognizer(), first);
  assert.notEqual(first, models.current);
  assert.deepEqual(made.filter(id => id === "moss-transcribe-diarize").length, 1);
  models.missing = true;
  await assert.rejects(models.meetingRecognizer(), { code: "model-not-installed" });
});

test("the real recognizer hands the budget to the engine and returns labelled turns", { skip: process.platform !== "darwin" }, async () => {
  const folder = await mkdtemp(join(tmpdir(), "meeting-test-"));
  // Another test file checks the shared temporary folder for leftovers while this one runs.
  process.env.TMPDIR = folder;
  try {
    const binary = join(folder, "engine");
    const log = join(folder, "calls");
    await writeFile(binary, `#!/bin/sh\necho "$@" >> "${log}"\nprintf '[0.1][S01]先看日志。[1.0][1.2][S02]已经回滚了。[2.0]'\n`);
    await chmod(binary, 0o755);
    const speech = { Vad: class { acceptWaveform() {} isEmpty() { return false; } flush() {} } };
    const engine = new MossRecognizer({ modelsDir: folder, modelId: "moss-transcribe-diarize", binary, loadSherpa: () => speech, status: async () => ({ ready: true }) });
    const jobs = new MeetingJobs({ recognizer: async () => { await engine.prepare(); return engine; } });
    const state = await settled(jobs, jobs.start({ audio: wav(300) }));
    assert.deepEqual(state.result.segments, turns);
    assert.match((await import("node:fs")).readFileSync(log, "utf8"), new RegExp(`--max-new ${meetingTokenBudget(300)}\\n$`));
  } finally { await rm(folder, { recursive: true, force: true }); }
});

test("the HTTP routes upload, report and cancel", async () => {
  const TOKEN = "a".repeat(64);
  const service = { meetings: new MeetingJobs({ recognizer: async () => ({ transcribe: async () => ({ segments: turns, speakers: ["S01", "S02"], text: "t" }) }) }) };
  const handler = createHandler({ service, currentToken: async () => TOKEN });
  const call = async (method, path, body = Buffer.alloc(0)) => {
    const handlers = {};
    const req = { method, url: ROUTE_PREFIX + path, headers: { host: "127.0.0.1:9", authorization: `Bearer ${TOKEN}`, "content-length": String(body.length) },
      on(name, fn) { handlers[name] = fn; if (name === "end") setImmediate(() => { if (body.length) handlers.data?.(body); fn(); }); return this; } };
    const out = { status: 0, text: "", headersSent: false };
    const res = { once() {}, writableEnded: false, get headersSent() { return out.headersSent; }, writeHead(status) { out.status = status; out.headersSent = true; }, end(text) { out.text = text; this.writableEnded = true; }, destroy() {} };
    await handler(req, res);
    return { status: out.status, body: JSON.parse(out.text) };
  };
  const started = await call("POST", "/meetings", wav());
  assert.equal(started.status, 202);
  await settled(service.meetings, started.body.id);
  const status = await call("GET", `/meetings/status?id=${started.body.id}`);
  assert.equal(status.status, 200);
  assert.equal(status.body.result.segments[1].speaker, "S02");
  assert.equal((await call("POST", "/meetings/cancel", Buffer.from(JSON.stringify({ id: started.body.id })))).body.cancelled, true);
  assert.equal((await call("GET", `/meetings/status?id=${started.body.id}`)).status, 404);
  assert.equal(MAX_MEETING_BYTES, 44 + MAX_MEETING_SECONDS * 32000);
});
