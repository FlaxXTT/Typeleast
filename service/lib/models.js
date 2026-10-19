/**
 * The local speech models: which files, where they come from, and how they are
 * checked.
 *
 * Three files, about 241 MB in all, from Hugging Face (the same files DeepSeek
 * Harness ships, byte for byte):
 *
 *   sensevoice/model.int8.onnx   SenseVoice Small, int8 (zh, en, ja, ko, yue)
 *   sensevoice/tokens.txt        its vocabulary
 *   vad/silero_vad.onnx          Silero voice activity detection, to split
 *                                recordings longer than one model window
 *
 * Every file is verified by size and SHA-256 before it is used, whether it was
 * downloaded or copied from another folder. HF_ENDPOINT selects a mirror of
 * huggingface.co (the variable Hugging Face's own tools read).
 *
 * @module typeleast-service/models
 */
import candidates from "./asr-catalog.json" with { type: "json" };
import { createHash } from "node:crypto";
import { createReadStream, createWriteStream } from "node:fs";
import { copyFile, mkdir, readdir, rename, rm, stat } from "node:fs/promises";
import { once } from "node:events";
import { finished } from "node:stream/promises";
import { join } from "node:path";

const SENSEVOICE_REPO = "csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17";

/** The files, their place under the models directory, and their checksums. */
export const MODEL_FILES = [
  {
    id: "sensevoice-model",
    path: ["sensevoice", "model.int8.onnx"],
    repo: SENSEVOICE_REPO,
    revision: "2365baeacb507f821a0c8120fcee3d484dba7a07",
    file: "model.int8.onnx",
    size: 239233841,
    sha256: "c71f0ce00bec95b07744e116345e33d8cbbe08cef896382cf907bf4b51a2cd51",
  },
  {
    id: "sensevoice-tokens",
    path: ["sensevoice", "tokens.txt"],
    repo: SENSEVOICE_REPO,
    revision: "2365baeacb507f821a0c8120fcee3d484dba7a07",
    file: "tokens.txt",
    size: 315894,
    sha256: "f449eb28dc567533d7fa59be34e2abca8784f771850c78a47fb731a31429a1dc",
  },
  {
    id: "silero-vad",
    path: ["vad", "silero_vad.onnx"],
    repo: "csukuangfj/vad",
    revision: "fba88cd2e921609e7675c3aaf51e0b9b295da4bc",
    file: "silero_vad.onnx",
    size: 1807522,
    sha256: "a35ebf52fd3ce5f1469b2a36158dba761bc47b973ea3382b3186ca15b1f5af28",
  },
];

/** Total download size in bytes. */
export const MODELS_TOTAL_BYTES = MODEL_FILES.reduce((sum, file) => sum + file.size, 0);

/** Absolute paths of the three files. */
export function modelPaths(modelsDir) {
  const at = (id) => join(modelsDir, ...MODEL_FILES.find((file) => file.id === id).path);
  return { model: at("sensevoice-model"), tokens: at("sensevoice-tokens"), vad: at("silero-vad") };
}

/**
 * Download URL of one file.
 * @param {object} file - an entry of MODEL_FILES.
 * @param {string} [endpoint] - a huggingface.co mirror; HF_ENDPOINT by default.
 * @returns {string} the URL.
 */
export function downloadUrl(file, endpoint = process.env.HF_ENDPOINT) {
  const base = (endpoint?.trim() || "https://huggingface.co").replace(/\/+$/, "");
  return `${base}/${file.repo}/resolve/${file.revision ?? "main"}/${file.file}`;
}

/**
 * Which files are present with the right size. Sizes only: hashing 240 MB on
 * every start would cost a second; files are hashed when they are installed.
 * @param {string} modelsDir - the models directory.
 * @param {object[]} [files] - the file list (MODEL_FILES; smaller ones in tests).
 * @returns {Promise<{ready: boolean, missing: string[]}>}
 */
export async function modelStatus(modelsDir, files = MODEL_FILES) {
  const missing = [];
  for (const file of files) {
    try {
      const info = await stat(join(modelsDir, ...file.path));
      if (!info.isFile() || info.size !== file.size) missing.push(file.id);
    } catch {
      missing.push(file.id);
    }
  }
  return { ready: missing.length === 0, missing };
}

/** SHA-256 of a file, streamed. */
export async function sha256File(path) {
  const hash = createHash("sha256");
  for await (const chunk of createReadStream(path)) hash.update(chunk);
  return hash.digest("hex");
}

/**
 * Download every missing file, verifying each before it replaces anything.
 * @param {object} options - modelsDir, endpoint, onProgress({received, total, file}), signal, and fetchImpl and files for tests.
 * @returns {Promise<{downloaded: string[]}>}
 */
export async function downloadModels(options) {
  const { modelsDir, endpoint, onProgress, signal, fetchImpl = globalThis.fetch, files = MODEL_FILES } = options;
  const { missing } = await modelStatus(modelsDir, files);
  const todo = [];
  for (const file of files) {
    if (missing.includes(file.id) || await sha256File(join(modelsDir, ...file.path)) !== file.sha256) todo.push(file);
  }
  const total = todo.reduce((sum, file) => sum + file.size, 0);
  let received = 0;
  for (const file of todo) {
    signal?.throwIfAborted();
    const target = join(modelsDir, ...file.path);
    const partial = `${target}.part`;
    await mkdir(join(modelsDir, ...file.path.slice(0, -1)), { recursive: true });
    const url = downloadUrl(file, endpoint);
    let response;
    try {
      response = await fetchImpl(url, { redirect: "follow", signal });
    } catch (error) {
      throw Object.assign(new Error(`could not reach ${new URL(url).host}: ${error instanceof Error ? error.message : String(error)}`), { code: "download-failed" });
    }
    if (!response.ok || !response.body) {
      throw Object.assign(new Error(`${new URL(url).host} answered HTTP ${response.status} for ${file.file}`), { code: "download-failed" });
    }
    const hash = createHash("sha256");
    const out = createWriteStream(partial);
    let size = 0;
    try {
      for await (const chunk of response.body) {
        signal?.throwIfAborted();
        if (size + chunk.length > file.size) throw new Error("file exceeds declared size");
        hash.update(chunk);
        size += chunk.length;
        received += chunk.length;
        onProgress?.({ received, total, file: file.id });
        if (!out.write(chunk)) await once(out, "drain");
      }
      out.end();
      await finished(out);
    } catch (error) {
      out.destroy();
      await rm(partial, { force: true });
      throw Object.assign(new Error(`download of ${file.file} was interrupted: ${error instanceof Error ? error.message : String(error)}`), { code: "download-failed" });
    }
    const digest = hash.digest("hex");
    if (size !== file.size || digest !== file.sha256) {
      await rm(partial, { force: true });
      throw Object.assign(new Error(`${file.file} failed verification (got ${size} bytes, sha256 ${digest.slice(0, 12)}…)`), { code: "checksum-mismatch" });
    }
    if (signal?.aborted) { await rm(partial, { force: true }); signal.throwIfAborted(); }
    await rename(partial, target);
  }
  return { downloaded: todo.map((file) => file.id) };
}

/**
 * Copy the files from a folder that already has them, such as another install
 * or DeepSeek Harness's own model folder. The folder is searched (six levels
 * deep, so ~/.dsh itself works) by file name, and each candidate must match the checksum.
 * @param {object} options - from (a directory), modelsDir, and files for tests.
 * @returns {Promise<{copied: string[], missing: string[]}>}
 */
export async function importModels(options) {
  const { from, modelsDir, files = MODEL_FILES } = options;
  const candidates = await listFiles(from, 6);
  const copied = [];
  const missing = [];
  for (const file of files) {
    const target = join(modelsDir, ...file.path);
    let done = false;
    for (const path of candidates.filter((candidate) => candidate.name === file.file)) {
      const info = await stat(path.full);
      if (info.size !== file.size || (await sha256File(path.full)) !== file.sha256) continue;
      await mkdir(join(modelsDir, ...file.path.slice(0, -1)), { recursive: true });
      await copyFile(path.full, `${target}.part`);
      await rename(`${target}.part`, target);
      copied.push(file.id);
      done = true;
      break;
    }
    if (!done) missing.push(file.id);
  }
  return { copied, missing };
}

/** Files under a directory, up to `depth` levels. */
async function listFiles(dir, depth) {
  const out = [];
  let entries = [];
  try {
    entries = await readdir(dir, { withFileTypes: true });
  } catch {
    return out;
  }
  for (const entry of entries) {
    const full = join(dir, entry.name);
    if (entry.isFile()) out.push({ name: entry.name, full });
    else if (entry.isDirectory() && depth > 1) out.push(...(await listFiles(full, depth - 1)));
  }
  return out;
}


export const DEFAULT_MODEL_ID = "sensevoice-small";
export const MODEL_CATALOG = [
  { id: DEFAULT_MODEL_ID, name: "SenseVoice Small", sourceUrl: `https://huggingface.co/${SENSEVOICE_REPO}`,
    source: "https://github.com/FunAudioLLM/SenseVoice", license: "See publisher terms", files: MODEL_FILES.slice(0, 2) },
  ...candidates,
].map(model => ({ ...model, modelBytes: model.files.reduce((sum, file) => sum + file.size, 0),
  // The v1.13.8 binding supports a FunASR config hint and a Qwen per-stream hint.
  languages: model.id === "fireredasr2-ctc" ? ["auto"] : model.id === "fun-asr-nano" ? ["auto", "zh", "en", "ja"] : ["auto", "zh", "en", "yue", "ja", "ko"],
  canSetLanguage: model.id !== "fireredasr2-ctc" }));

export function modelFor(id = DEFAULT_MODEL_ID) {
  const model = MODEL_CATALOG.find(model => model.id === id);
  if (!model) throw Object.assign(new Error("unknown speech model"), { code: "invalid-model" });
  return model;
}
export function filesForModel(id = DEFAULT_MODEL_ID) {
  return [...modelFor(id).files, MODEL_FILES.find(file => file.id === "silero-vad")];
}
export function recognizerConfig(modelsDir, id, { language = "auto", numThreads = 2 } = {}) {
  const model = modelFor(id);
  const at = file => join(modelsDir, ...model.files.find(entry => entry.file === file).path);
  const config = { featConfig: { sampleRate: 16000, featureDim: 80 },
    modelConfig: { numThreads, provider: "cpu", debug: 0, tokens: "" } };
  switch (id) {
    case "sensevoice-small":
      config.modelConfig.senseVoice = { model: at("model.int8.onnx"), language, useInverseTextNormalization: 1 };
      config.modelConfig.tokens = at("tokens.txt"); break;
    case "fireredasr2-ctc":
      config.modelConfig.fireRedAsrCtc = { model: at("model.int8.onnx") };
      config.modelConfig.tokens = at("tokens.txt"); break;
    case "fun-asr-nano":
      config.modelConfig.funasrNano = { encoderAdaptor: at("encoder_adaptor.int8.onnx"),
        llm: at("llm.int8.onnx"), embedding: at("embedding.int8.onnx"),
        tokenizer: join(modelsDir, id, "Qwen3-0.6B"),
        language: ({ zh: "中文", en: "英文", ja: "日文" })[language] ?? "", itn: 1 }; break;
    case "qwen3-asr-0.6b":
      config.modelConfig.qwen3Asr = { convFrontend: at("conv_frontend.onnx"),
        encoder: at("encoder.int8.onnx"), decoder: at("decoder.int8.onnx"),
        tokenizer: join(modelsDir, id, "tokenizer"), hotwords: "" }; break;
  }
  return config;
}
