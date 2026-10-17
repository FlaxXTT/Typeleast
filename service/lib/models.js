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
    file: "model.int8.onnx",
    size: 239233841,
    sha256: "c71f0ce00bec95b07744e116345e33d8cbbe08cef896382cf907bf4b51a2cd51",
  },
  {
    id: "sensevoice-tokens",
    path: ["sensevoice", "tokens.txt"],
    repo: SENSEVOICE_REPO,
    file: "tokens.txt",
    size: 315894,
    sha256: "f449eb28dc567533d7fa59be34e2abca8784f771850c78a47fb731a31429a1dc",
  },
  {
    id: "silero-vad",
    path: ["vad", "silero_vad.onnx"],
    repo: "csukuangfj/vad",
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
  return `${base}/${file.repo}/resolve/main/${file.file}`;
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
  const todo = files.filter((file) => missing.includes(file.id));
  const total = todo.reduce((sum, file) => sum + file.size, 0);
  let received = 0;
  for (const file of todo) {
    const target = join(modelsDir, ...file.path);
    const partial = `${target}.part`;
    await mkdir(join(modelsDir, file.path[0]), { recursive: true });
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
      await mkdir(join(modelsDir, file.path[0]), { recursive: true });
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
