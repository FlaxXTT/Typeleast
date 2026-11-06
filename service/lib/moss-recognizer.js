/**
 * MOSS-Transcribe-Diarize, run by the moss-transcribe engine bundled with the Mac app (sherpa-onnx
 * cannot run this model). One short-lived process per recording: the model is memory-mapped in
 * well under a second, and nothing stays in memory between dictations.
 *
 * The engine writes `[start][S01]text[end]` for each speaker turn. Dictation uses the text;
 * meetings (tasks/meeting.js) use the speaker and the times kept per segment.
 *
 * @module typeleast-service/moss-recognizer
 */
import { spawn } from "node:child_process";
import { access, chmod, mkdtemp, rm, writeFile, constants } from "node:fs/promises";
import { createRequire } from "node:module";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { joinSegments } from "./asr.js";
import { filesForModel, modelFor, modelPaths, modelStatus } from "./models.js";
import { pcm16ToFloat32, SAMPLE_RATE } from "./wav.js";

/** Bundled by apps/macos/build.sh next to the service's lib folder. */
export const MOSS_ENGINE = fileURLToPath(new URL("../native/moss-transcribe", import.meta.url));

const MAX_OUTPUT_BYTES = 16 * 1024 * 1024;
/** The first run of a new engine build compiles its GPU shaders. */
const WARM_UP_TIMEOUT_MS = 180000;
/** Silero's window at 16 kHz. */
const VAD_WINDOW = 512;

/** Split the engine's stream into speaker turns. A last turn may lack its end time. */
export function parseMossTranscript(raw) {
  const source = String(raw ?? "").trim();
  const segments = [];
  for (const match of source.matchAll(/\[(\d+(?:\.\d+)?)\]\[(S\d+)\]([\s\S]*?)(?:\[(\d+(?:\.\d+)?)\]|(?=\[\d+(?:\.\d+)?\]\[S\d+\])|$)/gu)) {
    const text = match[3].trim();
    if (text) segments.push({ start: Number(match[1]), end: match[4] === undefined ? null : Number(match[4]), speaker: match[2], text });
  }
  const speakers = [...new Set(segments.map(segment => segment.speaker))];
  return { text: joinSegments(segments.map(segment => segment.text)), segments, speakers };
}

/** The engine has no language output: enough to choose the Chinese written variant. */
export function detectScriptLanguage(text) {
  if (/[぀-ヿ]/u.test(text)) return "ja";
  if (/[가-힯]/u.test(text)) return "ko";
  if (/[㐀-鿿]/u.test(text)) return "zh";
  return /[A-Za-z]/u.test(text) ? "en" : null;
}

/** Room for the longest recording's transcript; the engine stops as soon as it is done. */
export function maxNewTokens(seconds) {
  return Math.max(2048, Math.ceil(seconds * 40));
}

/** Whether any speech is in the audio. Without speech this model can invent a sentence. */
export function containsSpeech(sherpa, vadModel, samples) {
  try {
    const vad = new sherpa.Vad({
      sileroVad: { model: vadModel, threshold: 0.5, minSilenceDuration: 0.4, minSpeechDuration: 0.25, windowSize: VAD_WINDOW, maxSpeechDuration: 20 },
      sampleRate: SAMPLE_RATE, numThreads: 1, provider: "cpu", debug: 0,
    }, Math.ceil(samples.length / SAMPLE_RATE) + 5);
    for (let start = 0; start + VAD_WINDOW <= samples.length; start += VAD_WINDOW) {
      vad.acceptWaveform(samples.subarray(start, start + VAD_WINDOW));
      if (!vad.isEmpty()) return true;
    }
    vad.flush();
    return !vad.isEmpty();
  } catch {
    // No VAD: a level check still stops silence, which is what makes the model invent text.
    let sum = 0;
    for (const sample of samples) sum += sample * sample;
    return samples.length > 0 && Math.sqrt(sum / samples.length) > 0.005;
  }
}

function silentWav(seconds = 1) {
  const bytes = seconds * SAMPLE_RATE * 2;
  const header = Buffer.alloc(44);
  header.write("RIFF", 0); header.writeUInt32LE(36 + bytes, 4); header.write("WAVEfmt ", 8);
  header.writeUInt32LE(16, 16); header.writeUInt16LE(1, 20); header.writeUInt16LE(1, 22);
  header.writeUInt32LE(SAMPLE_RATE, 24); header.writeUInt32LE(SAMPLE_RATE * 2, 28);
  header.writeUInt16LE(2, 32); header.writeUInt16LE(16, 34); header.write("data", 36); header.writeUInt32LE(bytes, 40);
  return Buffer.concat([header, Buffer.alloc(bytes)]);
}

const failure = (code, message) => Object.assign(new Error(message), { code });

export class MossRecognizer {
  /** @param {object} options - modelsDir, modelId, logger; binary, loadSherpa, status for tests. */
  constructor(options) {
    this.modelsDir = options.modelsDir;
    this.modelId = options.modelId;
    this.definition = modelFor(this.modelId);
    this.logger = options.logger ?? { info: () => {}, warn: () => {} };
    this.binary = options.binary ?? MOSS_ENGINE;
    // The Mac build no longer bundles ONNX. containsSpeech uses its local
    // energy-based silence guard when no VAD backend is available.
    this.loadSherpa = options.loadSherpa ?? (() => process.platform === 'darwin' ? null : createRequire(import.meta.url)("sherpa-onnx-node"));
    this.status = options.status ?? (() => modelStatus(this.modelsDir, filesForModel(this.modelId)));
    this.phase = "loading";
    this.error = null;
    this.preparing = null;
  }

  get modelPath() {
    return join(this.modelsDir, ...this.definition.files[0].path);
  }

  snapshot() {
    return {
      providerId: "moss-transcribe", engine: "moss-transcribe", phase: this.phase, ready: this.phase === "ready",
      languages: this.definition.languages, modelBytes: this.definition.modelBytes,
      ...(this.error ? { error: this.error } : {}),
    };
  }

  /** Check the engine and the files, and run once so the first dictation does not compile shaders. */
  prepare() {
    if (this.phase === "ready") return Promise.resolve(this.phase);
    if (this.preparing) return this.preparing;
    this.preparing = (async () => {
      try {
        if (!(await this.status()).ready) { this.phase = "missing-model"; this.error = null; return this.phase; }
        await access(this.binary, constants.X_OK);
        this.phase = "loading";
        const started = Date.now();
        await this.withTemporaryWav(silentWav(), path => this.run(path, 2048, AbortSignal.timeout(WARM_UP_TIMEOUT_MS)));
        this.phase = "ready"; this.error = null;
        this.logger.info?.("typeleast: moss engine ready in %d ms", Date.now() - started);
      } catch (error) {
        this.phase = "error";
        this.error = error instanceof Error ? error.message : String(error);
        this.logger.warn?.("typeleast: moss engine failed: %s", this.error);
      } finally {
        this.preparing = null;
      }
      return this.phase;
    })();
    return this.preparing;
  }

  /** @param {object} [options] - maxNew: generated tokens allowed, when the caller knows better. */
  async transcribe(audio, language = "auto", signal, options = {}) {
    if (this.phase !== "ready") {
      void this.prepare();
      throw failure("speech-not-ready", `speech model is not ready (phase: ${this.phase})`);
    }
    signal?.throwIfAborted();
    const samples = pcm16ToFloat32(audio);
    let hasSpeech = true;
    try {
      hasSpeech = containsSpeech(this.loadSherpa(), modelPaths(this.modelsDir).vad, samples);
    } catch (error) {
      this.logger.warn?.("typeleast: speech check unavailable: %s", error instanceof Error ? error.message : String(error));
    }
    if (!hasSpeech) return { text: "", language, detectedLanguage: null, segments: [], speakers: [] };
    const raw = await this.withTemporaryWav(audio, path => this.run(path, options.maxNew ?? maxNewTokens(samples.length / SAMPLE_RATE), signal));
    const parsed = parseMossTranscript(raw);
    return { ...parsed, language, detectedLanguage: detectScriptLanguage(parsed.text) };
  }

  async release() {
    this.phase = "missing-model";
  }

  /** The engine takes a path; the private folder holding the recording goes straight afterwards. */
  async withTemporaryWav(audio, work) {
    const folder = await mkdtemp(join(tmpdir(), "typeleast-moss-"));
    try {
      await chmod(folder, 0o700);
      const path = join(folder, "audio.wav");
      await writeFile(path, audio, { mode: 0o600 });
      return await work(path);
    } finally {
      await rm(folder, { recursive: true, force: true });
    }
  }

  run(wavPath, maxNew, signal) {
    return new Promise((resolve, reject) => {
      // GGML_METAL_NO_RESIDENCY: with residency sets, ggml aborts on its way out and leaves a crash report.
      const child = spawn(this.binary, ["transcribe", this.modelPath, wavPath, "--max-new", String(maxNew)], {
        env: { PATH: "/usr/bin:/bin", TMPDIR: tmpdir(), GGML_METAL_NO_RESIDENCY: "1", MTD_THREADS: "4" },
        stdio: ["ignore", "pipe", "ignore"],
      });
      const chunks = [];
      let size = 0;
      const stop = () => child.kill("SIGKILL");
      signal?.addEventListener("abort", stop, { once: true });
      child.stdout.on("data", chunk => {
        size += chunk.length;
        if (size > MAX_OUTPUT_BYTES) stop(); else chunks.push(chunk);
      });
      child.on("error", error => {
        signal?.removeEventListener("abort", stop);
        reject(failure("model-load-failed", error.message));
      });
      child.on("close", (code, killed) => {
        signal?.removeEventListener("abort", stop);
        if (signal?.aborted) return reject(signal.reason ?? failure("cancelled", "cancelled"));
        const output = Buffer.concat(chunks).toString("utf8");
        // The transcript is finished before the engine exits: a crash on the way out loses nothing.
        if (code === 0 || (parseMossTranscript(output).segments.length > 0 && size <= MAX_OUTPUT_BYTES)) return resolve(output);
        reject(failure("model-load-failed", `moss engine stopped (${code ?? killed})`));
      });
    });
  }
}
