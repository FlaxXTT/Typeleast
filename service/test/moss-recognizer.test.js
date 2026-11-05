import test from "node:test";
import assert from "node:assert/strict";
import { chmod, mkdtemp, rm, writeFile, readdir } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { containsSpeech, detectScriptLanguage, maxNewTokens, MossRecognizer, parseMossTranscript } from "../lib/moss-recognizer.js";

test("the engine's stream becomes text, speakers and times", () => {
  const parsed = parseMossTranscript("[0.07][S01]我们先看日志。[6.26][6.86][S02]已经回滚了。[12.01][12.61][S01] Ship it [15.2]");
  assert.equal(parsed.text, "我们先看日志。已经回滚了。Ship it");
  assert.deepEqual(parsed.speakers, ["S01", "S02"]);
  assert.deepEqual(parsed.segments[1], { start: 6.86, end: 12.01, speaker: "S02", text: "已经回滚了。" });
  assert.equal(parseMossTranscript("[0.00][S01]Hello there").text, "Hello there");
  assert.equal(parseMossTranscript("[0.00][S01][0.06]").text, "");
  assert.equal(parseMossTranscript("[0.1][S01]one[1.0][1.2][S01] two[2.0]").text, "one two");
});

test("the written script picks the language; the token budget grows with the recording", () => {
  assert.equal(detectScriptLanguage("把代码推到 GitHub"), "zh");
  assert.equal(detectScriptLanguage("Ship it"), "en");
  assert.equal(detectScriptLanguage("こんにちは世界"), "ja");
  assert.equal(detectScriptLanguage(""), null);
  assert.equal(maxNewTokens(5), 2048);
  assert.equal(maxNewTokens(600), 24000);
});

test("without a VAD, a level check still keeps silence away from the model", () => {
  const broken = { Vad: class { constructor() { throw new Error("no vad"); } } };
  assert.equal(containsSpeech(broken, "/none", new Float32Array(16000)), false);
  assert.equal(containsSpeech(broken, "/none", new Float32Array(16000).fill(0.1)), true);
});

const wav = (samples = 16000) => {
  const header = Buffer.alloc(44);
  header.write("RIFF", 0); header.write("WAVE", 8); header.write("fmt ", 12); header.writeUInt32LE(16, 16);
  header.writeUInt16LE(1, 20); header.writeUInt16LE(1, 22); header.writeUInt32LE(16000, 24); header.writeUInt32LE(32000, 28);
  header.writeUInt16LE(2, 32); header.writeUInt16LE(16, 34); header.write("data", 36); header.writeUInt32LE(samples * 2, 40);
  return Buffer.concat([header, Buffer.alloc(samples * 2, 3)]);
};
const speech = { Vad: class { acceptWaveform() {} isEmpty() { return false; } flush() {} } };
const silence = { Vad: class { acceptWaveform() {} isEmpty() { return true; } flush() {} } };

test("a recording goes through the engine; silence never does", { skip: process.platform === "win32" }, async () => {
  const folder = await mkdtemp(join(tmpdir(), "moss-test-"));
  try {
    const binary = join(folder, "engine");
    const log = join(folder, "calls");
    await writeFile(binary, `#!/bin/sh\necho "$@" >> "${log}"\ntest "$NO_SUCH" = "" && test "$GGML_METAL_NO_RESIDENCY" = 1 || exit 9\nprintf '[0.1][S01]把代码推到 GitHub。[1.0]'\n`);
    await chmod(binary, 0o755);
    const make = sherpa => new MossRecognizer({ modelsDir: folder, modelId: "moss-transcribe-diarize", binary, loadSherpa: () => sherpa, status: async () => ({ ready: true }) });
    const engine = make(speech);
    assert.equal(await engine.prepare(), "ready");
    assert.equal(engine.snapshot().ready, true);
    const result = await engine.transcribe(wav(), "auto");
    assert.equal(result.text, "把代码推到 GitHub。");
    assert.equal(result.detectedLanguage, "zh");
    const calls = (await import("node:fs")).readFileSync(log, "utf8").trim().split("\n");
    assert.equal(calls.length, 2, "one warm-up, one recording");
    assert.match(calls[1], /^transcribe .*moss-transcribe-q5_0\.gguf .*audio\.wav --max-new 2048$/);
    const left = (await readdir(tmpdir())).filter(name => name.startsWith("typeleast-moss-"));
    assert.deepEqual(left, [], "the temporary recording is gone");

    const quiet = make(silence);
    await quiet.prepare();
    assert.equal((await quiet.transcribe(wav(), "auto")).text, "");
    assert.equal((await import("node:fs")).readFileSync(log, "utf8").trim().split("\n").length, 3, "only the warm-up ran");
  } finally { await rm(folder, { recursive: true, force: true }); }
});

test("an engine that cannot run leaves the model unavailable, and a failed run is reported", { skip: process.platform === "win32" }, async () => {
  const folder = await mkdtemp(join(tmpdir(), "moss-test-"));
  try {
    const missing = new MossRecognizer({ modelsDir: folder, modelId: "moss-transcribe-diarize", binary: join(folder, "none"), status: async () => ({ ready: true }) });
    assert.equal(await missing.prepare(), "error");
    await assert.rejects(missing.transcribe(wav(), "auto"), { code: "speech-not-ready" });
    const notDownloaded = new MossRecognizer({ modelsDir: folder, modelId: "moss-transcribe-diarize", binary: join(folder, "none"), status: async () => ({ ready: false }) });
    assert.equal(await notDownloaded.prepare(), "missing-model");
    const binary = join(folder, "engine");
    await writeFile(binary, "#!/bin/sh\ntest -f \"$FLAG\" || exit 3\n");
    await chmod(binary, 0o755);
    const failing = new MossRecognizer({ modelsDir: folder, modelId: "moss-transcribe-diarize", binary, status: async () => ({ ready: true }) });
    assert.equal(await failing.prepare(), "error");
    assert.match(failing.snapshot().error, /moss engine stopped \(3\)/);
  } finally { await rm(folder, { recursive: true, force: true }); }
});
