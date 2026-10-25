import test from "node:test";
import assert from "node:assert/strict";
import { mkdir, mkdtemp, rm, truncate, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fixedWindows, joinSegments, LocalRecognizer, SEGMENT_THRESHOLD_SECONDS } from "../lib/asr.js";
import { MODEL_FILES, modelFor, recognizerConfig } from "../lib/models.js";
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
function fakeSherpa({ texts = ["你好"], vadSegments = null, languages = ["<|zh|>"] } = {}) {
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
          config,
          setConfig: next => configs.push(next),
          createStream: () => {
            const stream = { samples: null, acceptWaveform: ({ samples, sampleRate }) => { stream.samples = samples; stream.rate = sampleRate; } };
            return stream;
          },
          decodeAsync: async (stream) => {
            decoded.push({ length: stream.samples.length, rate: stream.rate });
            const index = call++;
            return { text: texts[Math.min(index, texts.length - 1)], lang: languages[Math.min(index, languages.length - 1)] };
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

test("automatic recognition preserves explicit language metadata, including kana-free Japanese", async () => {
  await withDir(async dir => {
    await fakeModels(dir);
    const sherpa = fakeSherpa({ texts: ["企画書", "软件", "회사", "unknown"], languages: ["<|ja|>", "zh", "ko", ""] });
    const recognizer = new LocalRecognizer({ modelsDir: dir, language: "auto", loadSherpa: () => sherpa });
    await recognizer.prepare();
    const actual = [];
    for (let i = 0; i < 4; i++) actual.push((await recognizer.transcribe(wav(1), "auto")).detectedLanguage);
    assert.deepEqual(actual, ["ja", "zh", "ko", null]);
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
  for (const language of ["en", "auto"]) {
    assert.equal(typeof (await recognizer.transcribe(wav(0.3), language)).text, "string");
    assert.equal(recognizer.activeLanguage, language);
  }
});


test("per-request languages are applied serially and a rejection does not poison recognition", async () => {
  await withDir(async (dir) => {
    await fakeModels(dir);
    const sherpa = fakeSherpa();
    const recognizer = new LocalRecognizer({ modelsDir: dir, loadSherpa: () => sherpa });
    await recognizer.prepare();
    await Promise.all([recognizer.transcribe(wav(1), "en"), recognizer.transcribe(wav(1), "ja")]);
    assert.deepEqual(sherpa.configs.map(c => c.modelConfig.senseVoice.language), ["auto", "en", "ja"]);
    await assert.rejects(recognizer.transcribe(wav(1), "unsupported"), { code: "invalid-language" });
    await recognizer.transcribe(wav(1), "auto");
    assert.equal(sherpa.configs.at(-1).modelConfig.senseVoice.language, "auto");
    await recognizer.transcribe(wav(1), "auto");
    assert.equal(sherpa.configs.length, 4);
  });
});

test("optional models use only supported language hints and keep Qwen hints on their own stream", async () => {
  for (const id of ['fireredasr2-ctc', 'fun-asr-nano', 'qwen3-asr-0.6b']) {
    const hints = [], configs = [];
    const make = async config => {
      configs.push(config);
      return {
        createStream() { return { setOption: (key,value) => hints.push([key,value]), acceptWaveform() {} }; },
        async decodeAsync() { return { text: 'public sample' }; },
      };
    };
    const r = new LocalRecognizer({ modelsDir: '/unused', modelId: id });
    r.sherpa = { OfflineRecognizer: { createAsync: make } };
    r.recognizer = await make(recognizerConfig('/unused',id)); r.phase = 'ready';
    const languages = ['zh','en','yue','ja','ko','auto'];
    const results = await Promise.all(languages.map(language => r.transcribe(wav(1),language)));
    assert.deepEqual(results.map(v=>v.language), languages.map(v=>modelFor(id).languages.includes(v) ? v : 'auto'));
    if (id === 'qwen3-asr-0.6b') {
      assert.equal(configs.length,1,'a per-stream hint must not reload Qwen');
      assert.deepEqual(hints,[['language','Chinese'],['language','English'],['language','Cantonese'],['language','Japanese'],['language','Korean']]);
    } else if (id === 'fun-asr-nano') {
      assert.deepEqual(configs.map(c=>c.modelConfig.funasrNano.language),['','中文','英文','','日文','']);
    } else assert.equal(configs.length,1,'auto-only CTC must not reload for a language preference');
  }
});
