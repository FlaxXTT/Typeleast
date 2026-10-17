import test from "node:test";
import assert from "node:assert/strict";
import { mkdir, mkdtemp, rm, truncate, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fixedWindows, joinSegments, LocalRecognizer, SEGMENT_THRESHOLD_SECONDS } from "../lib/asr.js";
import { MODEL_FILES } from "../lib/models.js";
import { pcm16ToFloat32 } from "../lib/wav.js";

function wav(seconds, value = 0) {
  const samples = Math.round(16000 * seconds);
  const buffer = Buffer.alloc(44 + samples * 2);
  buffer.write("RIFF", 0, "ascii"); buffer.writeUInt32LE(36 + samples * 2, 4); buffer.write("WAVE", 8, "ascii");
  buffer.writeUInt32LE(16, 16); buffer.writeUInt16LE(1, 20); buffer.writeUInt16LE(1, 22);
  buffer.writeUInt32LE(16000, 24); buffer.writeUInt32LE(32000, 28); buffer.writeUInt16LE(2, 32); buffer.writeUInt16LE(16, 34);
  buffer.write("data", 36, "ascii"); buffer.writeUInt32LE(samples * 2, 40);
  for (let i = 0; i < samples; i += 1) buffer.writeInt16LE(value, 44 + i * 2);
  return buffer;
}

/** A sherpa-onnx stand-in that records what it was given. */
function fakeSherpa({ texts = ["你好"], vadSegments = null } = {}) {
  const decoded = [];
  const configs = [];
  let call = 0;
  return {
    decoded,
    configs,
    OfflineRecognizer: {
      createAsync: async (config) => {
        configs.push(config);
        return {
          createStream: () => {
            const stream = { samples: null, acceptWaveform: ({ samples, sampleRate }) => { stream.samples = samples; stream.rate = sampleRate; } };
            return stream;
          },
          decodeAsync: async (stream) => {
            decoded.push({ length: stream.samples.length, rate: stream.rate });
            return { text: texts[Math.min(call++, texts.length - 1)], lang: "<|zh|>" };
          },
        };
      },
    },
    Vad: class {
      constructor() { this.queue = []; this.fed = 0; }
      acceptWaveform(samples) { this.fed += samples.length; }
      flush() { this.queue = (vadSegments ?? []).map((length) => ({ samples: new Float32Array(length), start: 0 })); }
      isEmpty() { return this.queue.length === 0; }
      front() { return this.queue[0]; }
      pop() { this.queue.shift(); }
    },
  };
}

/** A models folder whose files have the right SIZES (status checks sizes only). */
async function fakeModels(dir) {
  for (const file of MODEL_FILES) {
    await mkdir(join(dir, file.path[0]), { recursive: true });
    const handle = join(dir, ...file.path);
    await writeFile(handle, Buffer.alloc(0));
    await truncate(handle, file.size);
  }
}

async function withDir(run) {
  const dir = await mkdtemp(join(tmpdir(), "typeleast-asr-"));
  try {
    await run(dir);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
}

test("without model files the recogniser says so and refuses to transcribe", async () => {
  await withDir(async (dir) => {
    const recognizer = new LocalRecognizer({ modelsDir: dir, loadSherpa: () => { throw new Error("must not load"); } });
    assert.equal(await recognizer.prepare(), "missing-model");
    const state = recognizer.snapshot();
    assert.equal(state.ready, false);
    assert.equal(state.phase, "missing-model");
    assert.equal(state.modelBytes, 239233841 + 315894 + 1807522);
    await assert.rejects(recognizer.transcribe(wav(1)), (error) => error.code === "speech-not-ready");
  });
});

test("SenseVoice is loaded from the models folder with inverse text normalisation", async () => {
  await withDir(async (dir) => {
    await fakeModels(dir);
    const sherpa = fakeSherpa();
    const recognizer = new LocalRecognizer({ modelsDir: dir, numThreads: 3, language: "zh", loadSherpa: () => sherpa });
    assert.equal(await recognizer.prepare(), "ready");
    assert.equal(await recognizer.prepare(), "ready", "a second prepare keeps the loaded model");
    assert.equal(sherpa.configs.length, 1);
    const { modelConfig, featConfig } = sherpa.configs[0];
    assert.equal(modelConfig.senseVoice.model, join(dir, "sensevoice", "model.int8.onnx"));
    assert.equal(modelConfig.senseVoice.language, "zh");
    assert.equal(modelConfig.senseVoice.useInverseTextNormalization, 1);
    assert.equal(modelConfig.tokens, join(dir, "sensevoice", "tokens.txt"));
    assert.equal(modelConfig.numThreads, 3);
    assert.equal(featConfig.sampleRate, 16000);
    assert.equal(recognizer.snapshot().ready, true);
  });
});

test("a short recording is decoded in one piece, with a lead-in of silence", async () => {
  await withDir(async (dir) => {
    await fakeModels(dir);
    const sherpa = fakeSherpa({ texts: ["  我们周三发出去。 "] });
    const recognizer = new LocalRecognizer({ modelsDir: dir, loadSherpa: () => sherpa });
    await recognizer.prepare();
    const result = await recognizer.transcribe(wav(2));
    assert.equal(result.text, "我们周三发出去。");
    assert.equal(sherpa.decoded.length, 1);
    assert.equal(sherpa.decoded[0].rate, 16000);
    assert.equal(sherpa.decoded[0].length, 16000 * 2 + Math.round(16000 * 0.3), "0.3 s of lead-in comes first");
  });
});

test("a long recording is split at pauses and the pieces are joined", async () => {
  await withDir(async (dir) => {
    await fakeModels(dir);
    const sherpa = fakeSherpa({ texts: ["第一段。", "second part", "third"], vadSegments: [16000 * 8, 16000 * 9, 16000 * 5] });
    const recognizer = new LocalRecognizer({ modelsDir: dir, loadSherpa: () => sherpa });
    await recognizer.prepare();
    const result = await recognizer.transcribe(wav(SEGMENT_THRESHOLD_SECONDS + 5));
    assert.equal(sherpa.decoded.length, 3);
    assert.equal(result.text, "第一段。second part third");
  });
});

test("a load failure is reported, not thrown", async () => {
  await withDir(async (dir) => {
    await fakeModels(dir);
    const recognizer = new LocalRecognizer({ modelsDir: dir, loadSherpa: () => ({ OfflineRecognizer: { createAsync: async () => { throw new Error("bad model file"); } } }) });
    assert.equal(await recognizer.prepare(), "error");
    assert.equal(recognizer.snapshot().error, "bad model file");
  });
});

test("segment joining spaces Latin words and runs CJK together", () => {
  assert.equal(joinSegments(["你好。", "世界"]), "你好。世界");
  assert.equal(joinSegments(["hello", "world"]), "hello world");
  assert.equal(joinSegments(["用 GitHub", "管理代码"]), "用 GitHub管理代码");
  assert.equal(joinSegments([]), "");
  assert.deepEqual(fixedWindows(new Float32Array(10), 4).map((w) => w.length), [4, 4, 2]);
});

test("PCM16 samples become floats in [-1, 1)", () => {
  const samples = pcm16ToFloat32(wav(0.001, -32768));
  assert.equal(samples.length, 16);
  assert.equal(samples[0], -1);
  assert.equal(pcm16ToFloat32(wav(0.001, 16384))[0], 0.5);
});

// Real recognition, when the models are installed (TYPELEAST_MODELS or the default folder).
test("real SenseVoice recognition (skipped without models)", async (t) => {
  const { defaultModelsDir } = await import("../lib/paths.js");
  const { modelStatus } = await import("../lib/models.js");
  const dir = defaultModelsDir();
  if (!(await modelStatus(dir)).ready) {
    t.skip("models not installed; run npm run setup-models");
    return;
  }
  const recognizer = new LocalRecognizer({ modelsDir: dir });
  assert.equal(await recognizer.prepare(), "ready");
  const silence = await recognizer.transcribe(wav(1.5));
  assert.equal(typeof silence.text, "string");
});
