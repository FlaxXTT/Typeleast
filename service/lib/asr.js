/**
 * Local speech recognition: SenseVoice through sherpa-onnx, on this computer.
 *
 * The engine is the official sherpa-onnx Node addon (prebuilt for macOS arm64
 * and x64, and Windows x64), the same engine and model DeepSeek Harness uses.
 * Audio never leaves the machine.
 *
 * Recordings longer than one comfortable model window are first split at
 * pauses by Silero VAD, so a two-minute dictation is recognised as a series of
 * sentences rather than one oversized input.
 *
 * The addon is loaded lazily and injected in tests, so everything else in the
 * service runs without it.
 *
 * @module typeleast-service/asr
 */
import { LANGUAGES } from "./config.js";
import { createRequire } from "node:module";
import { downloadModels, modelPaths, modelStatus, DEFAULT_MODEL_ID, filesForModel, modelFor, recognizerConfig } from "./models.js";
import { pcm16ToFloat32, SAMPLE_RATE, withLeadIn } from "./wav.js";

/** Above this many seconds a recording is split at pauses before recognition. */
export const SEGMENT_THRESHOLD_SECONDS = 20;

const optionsFiles = recognizer => recognizer.definition.inventory ?? filesForModel(recognizer.modelId);

/** Silero's window at 16 kHz. */
const VAD_WINDOW = 512;

/** Load the sherpa-onnx addon (CommonJS) from this package's dependencies. */
function loadSherpa() {
  return createRequire(import.meta.url)("sherpa-onnx-node");
}

/** Native model buffers are not counted in V8's small JS heap. The app launches
 * Node with --expose-gc so a replaced model does not wait for JS heap pressure.
 * Yield first so obsolete native handles leave the current stack.
 */
async function collectNativeMemory() {
  if (typeof globalThis.gc !== 'function') return;
  await new Promise(resolve => setImmediate(resolve));
  globalThis.gc();
  await new Promise(resolve => setImmediate(resolve));
}

/** Recogniser state for /health and the apps. */
export class LocalRecognizer {
  /**
   * @param {object} options - modelsDir, numThreads, language, logger, and loadSherpa for tests.
   */
  constructor(options) {
    this.modelsDir = options.modelsDir;
    this.modelId = options.modelId ?? DEFAULT_MODEL_ID;
    this.definition = options.modelDefinition ?? modelFor(this.modelId);
    this.configFactory = options.configFactory ?? (settings => recognizerConfig(this.modelsDir, this.modelId, settings));
    this.numThreads = options.numThreads ?? 2;
    this.language = this.definition.languages.includes(options.language) ? options.language : "auto";
    this.logger = options.logger ?? { info: () => {}, warn: () => {} };
    this.loadSherpa = options.loadSherpa ?? loadSherpa;
    /** missing-model | loading | ready | downloading | error */
    this.phase = "loading";
    this.error = null;
    this.download = null;
    this.recognizer = null;
    this.sherpa = null;
    this.preparing = null;
    this.transcribing = Promise.resolve();
    this.activeLanguage = this.language;
  }

  /**
   * Load the model if its files are present. Safe to call repeatedly: one load
   * runs at a time, and a loaded recogniser is kept.
   * @returns {Promise<string>} the phase afterwards.
   */
  prepare() {
    if (this.recognizer) return Promise.resolve(this.phase);
    if (this.preparing) return this.preparing;
    this.preparing = (async () => {
      try {
        const status = await modelStatus(this.modelsDir, optionsFiles(this));
        if (!status.ready) {
          this.phase = "missing-model";
          this.error = null;
          return this.phase;
        }
        this.phase = "loading";
        this.sherpa = this.loadSherpa();
        const started = Date.now();
        this.recognizer = await this.sherpa.OfflineRecognizer.createAsync(this.configFactory({ language: this.language, numThreads: this.numThreads }));
        this.phase = "ready";
        this.error = null;
        this.logger.info?.("typeleast: speech model loaded in %d ms", Date.now() - started);
      } catch (error) {
        this.phase = "error";
        this.error = error instanceof Error ? error.message : String(error);
        this.logger.warn?.("typeleast: speech model failed to load: %s", this.error);
      } finally {
        this.preparing = null;
      }
      return this.phase;
    })();
    return this.preparing;
  }

  /**
   * Download the model files (when missing), then load them.
   * @param {object} [options] - endpoint (a huggingface.co mirror) and fetchImpl for tests.
   * @returns {Promise<string>} the phase afterwards.
   */
  async downloadAndPrepare(options = {}) {
    if (this.phase === "downloading" || this.phase === "ready") return this.phase;
    this.phase = "downloading";
    this.error = null;
    this.download = { received: 0, total: filesForModel(this.modelId).reduce((sum, file) => sum + file.size, 0) };
    try {
      await downloadModels({
        modelsDir: this.modelsDir,
        files: filesForModel(this.modelId),
        endpoint: options.endpoint,
        fetchImpl: options.fetchImpl,
        onProgress: ({ received, total }) => {
          this.download = { received, total };
        },
      });
      this.download = null;
      this.phase = "loading";
      return await this.prepare();
    } catch (error) {
      this.phase = "error";
      this.error = error instanceof Error ? error.message : String(error);
      this.logger.warn?.("typeleast: model download failed: %s", this.error);
      return this.phase;
    }
  }

  /** The recogniser's state, shaped like the earlier host's `speech` field. */
  snapshot() {
    return {
      providerId: "sensevoice-local",
      engine: "sherpa-onnx",
      phase: this.phase,
      ready: this.phase === "ready",
      languages: this.definition.languages,
      ...(this.error ? { error: this.error } : {}),
      ...(this.download ? { download: { ...this.download } } : {}),
      modelBytes: optionsFiles(this).reduce((sum, file) => sum + file.size, 0),
    };
  }

  /**
   * Recognise one canonical WAV.
   * @param {Buffer} audio - a WAV that passed validateWav().
   * @returns {Promise<{text: string}>}
   */
  transcribe(audio, language = this.language) {
    if (!LANGUAGES.includes(language)) {
      const error = new Error("unsupported recognition language");
      error.code = "invalid-language";
      return Promise.reject(error);
    }
    // One recognizer at a time. Keep a failed request from poisoning the queue.
    const work = this.transcribing.then(() => this.transcribeSerial(audio, language));
    this.transcribing = work.catch(() => {});
    return work;
  }

  async transcribeSerial(audio, language) {
    if (!this.recognizer) {
      void this.prepare();
      const error = new Error(`speech model is not ready (phase: ${this.phase})`);
      error.code = "speech-not-ready";
      throw error;
    }
    if (!this.definition.languages.includes(language)) language = "auto";
    if (language !== this.activeLanguage && !this.modelId.startsWith("qwen3-asr-")) {
      const config = this.configFactory({ language, numThreads: this.numThreads });
      // SenseVoice reads the inherited config on every decode in 1.13.8.
      // FunASR keeps a separate config, so its language hint requires a reload.
      if (this.modelId === DEFAULT_MODEL_ID) this.recognizer.setConfig(config);
      else {
        const next = await this.sherpa.OfflineRecognizer.createAsync(config);
        this.recognizer = next;
        await collectNativeMemory();
      }
      this.activeLanguage = language;
    }
    // A short silent lead-in keeps the recogniser from clipping the first syllable.
    const samples = pcm16ToFloat32(withLeadIn(audio));
    const segments = samples.length / SAMPLE_RATE > SEGMENT_THRESHOLD_SECONDS ? this.split(samples) : [samples];
    const texts = [];
    const detected = [];
    for (const segment of segments) {
      const stream = this.recognizer.createStream();
      if (this.modelId.startsWith("qwen3-asr-") && language !== "auto") {
        stream.setOption("language", ({ zh: "Chinese", en: "English", yue: "Cantonese", ja: "Japanese", ko: "Korean" })[language]);
      }
      stream.acceptWaveform({ sampleRate: SAMPLE_RATE, samples: segment });
      const result = await this.recognizer.decodeAsync(stream);
      const text = String(result?.text ?? "").trim();
      if (text.length > 0) {
        texts.push(text);
        // SenseVoice exposes its detected language as e.g. <|ja|>. Other models may omit it.
        const code = String(result?.lang ?? result?.language ?? "").trim().toLowerCase().replace(/^<\|([^|]+)\|>$/, "$1");
        detected.push(LANGUAGES.includes(code) && code !== "auto" ? code : null);
      }
    }
    const detectedLanguage = detected.length > 0 && detected[0] && detected.every(code => code === detected[0]) ? detected[0] : null;
    return { text: joinSegments(texts), language, detectedLanguage };
  }

  async release() {
    this.recognizer = null;
    this.phase = 'missing-model';
    await collectNativeMemory();
  }

  /**
   * Split a long recording at pauses. Without the VAD model (or if it fails),
   * fixed windows are used instead: worse at word boundaries, never lost audio.
   * @param {Float32Array} samples - the whole recording.
   * @returns {Float32Array[]} speech segments in order.
   */
  split(samples) {
    try {
      const vad = new this.sherpa.Vad(
        {
          sileroVad: {
            model: modelPaths(this.modelsDir).vad,
            threshold: 0.5,
            minSilenceDuration: 0.4,
            minSpeechDuration: 0.25,
            windowSize: VAD_WINDOW,
            maxSpeechDuration: SEGMENT_THRESHOLD_SECONDS,
          },
          sampleRate: SAMPLE_RATE,
          numThreads: 1,
          provider: "cpu",
          debug: 0,
        },
        Math.ceil(samples.length / SAMPLE_RATE) + 5,
      );
      const segments = [];
      const drain = () => {
        while (!vad.isEmpty()) {
          segments.push(Float32Array.from(vad.front(false).samples));
          vad.pop();
        }
      };
      for (let start = 0; start + VAD_WINDOW <= samples.length; start += VAD_WINDOW) {
        vad.acceptWaveform(samples.subarray(start, start + VAD_WINDOW));
        drain();
      }
      vad.flush();
      drain();
      return segments;
    } catch (error) {
      this.logger.warn?.("typeleast: VAD failed, using fixed windows: %s", error instanceof Error ? error.message : String(error));
      return fixedWindows(samples, SEGMENT_THRESHOLD_SECONDS * SAMPLE_RATE);
    }
  }
}

/**
 * Join recognised segments: Chinese and Japanese run together, while a Latin
 * letter or digit on both sides of a joint gets a space.
 * @param {string[]} texts - segment texts in order.
 * @returns {string} the transcript.
 */
export function joinSegments(texts) {
  let out = "";
  for (const text of texts) {
    if (out.length > 0 && /[A-Za-z0-9.,!?]$/.test(out) && /^[A-Za-z0-9]/.test(text)) out += " ";
    out += text;
  }
  return out;
}

/** Cut samples into windows of at most `size`. */
export function fixedWindows(samples, size) {
  const out = [];
  for (let start = 0; start < samples.length; start += size) out.push(samples.subarray(start, Math.min(samples.length, start + size)));
  return out;
}
