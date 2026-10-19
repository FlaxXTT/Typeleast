import test from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdir, mkdtemp, readFile, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { downloadModels, downloadUrl, importModels, MODEL_FILES, MODELS_TOTAL_BYTES, modelPaths, modelStatus } from "../lib/models.js";

const sha = (bytes) => createHash("sha256").update(bytes).digest("hex");
const A = Buffer.from("model bytes ".repeat(100));
const B = Buffer.from("tokens\n".repeat(10));
const FILES = [
  { id: "a", path: ["sensevoice", "model.int8.onnx"], repo: "org/repo", file: "model.int8.onnx", size: A.length, sha256: sha(A) },
  { id: "b", path: ["sensevoice", "tokens.txt"], repo: "org/repo", file: "tokens.txt", size: B.length, sha256: sha(B) },
];

/** fetch that serves the given bytes per file name, in small chunks. */
function serve(contents, seen = []) {
  return async (url) => {
    seen.push(url);
    const name = url.split("/").pop();
    const bytes = contents[name];
    if (!bytes) return { ok: false, status: 404, body: null };
    return {
      ok: true,
      status: 200,
      body: (async function* chunks() {
        for (let start = 0; start < bytes.length; start += 64) yield bytes.subarray(start, start + 64);
      })(),
    };
  };
}

async function withDir(run) {
  const dir = await mkdtemp(join(tmpdir(), "typeleast-models-"));
  try {
    await run(dir);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
}

test("the real file list is the SenseVoice int8 model, its tokens and Silero VAD", () => {
  assert.deepEqual(MODEL_FILES.map((file) => file.file), ["model.int8.onnx", "tokens.txt", "silero_vad.onnx"]);
  assert.ok(MODEL_FILES.every((file) => /^[0-9a-f]{64}$/.test(file.sha256) && file.size > 0));
  assert.equal(MODELS_TOTAL_BYTES, 239233841 + 315894 + 1807522);
  const paths = modelPaths(join("m"));
  assert.equal(paths.model, join("m", "sensevoice", "model.int8.onnx"));
  assert.equal(paths.vad, join("m", "vad", "silero_vad.onnx"));
});

test("downloads come from huggingface.co unless HF_ENDPOINT names a mirror", () => {
  assert.equal(downloadUrl(MODEL_FILES[0], ""), "https://huggingface.co/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/2365baeacb507f821a0c8120fcee3d484dba7a07/model.int8.onnx");
  assert.equal(downloadUrl(MODEL_FILES[2], "https://mirror.example.com/"), "https://mirror.example.com/csukuangfj/vad/resolve/fba88cd2e921609e7675c3aaf51e0b9b295da4bc/silero_vad.onnx");
});

test("missing files are downloaded, verified, and reported with progress", async () => {
  await withDir(async (dir) => {
    assert.deepEqual((await modelStatus(dir, FILES)).missing, ["a", "b"]);
    const seen = [];
    const progress = [];
    await downloadModels({ modelsDir: dir, files: FILES, endpoint: "https://mirror.example.com", fetchImpl: serve({ "model.int8.onnx": A, "tokens.txt": B }, seen), onProgress: (p) => progress.push(p) });
    assert.deepEqual(await readFile(join(dir, "sensevoice", "model.int8.onnx")), A);
    assert.equal((await modelStatus(dir, FILES)).ready, true);
    assert.ok(seen.every((url) => url.startsWith("https://mirror.example.com/org/repo/resolve/main/")));
    assert.equal(progress.at(-1).received, A.length + B.length);
    assert.equal(progress.at(-1).total, A.length + B.length);
    // Present files are not fetched again.
    const again = [];
    await downloadModels({ modelsDir: dir, files: FILES, fetchImpl: serve({}, again) });
    assert.equal(again.length, 0);
  });
});

test("a file with the wrong checksum is rejected and leaves nothing behind", async () => {
  await withDir(async (dir) => {
    const tampered = Buffer.from(A);
    tampered[0] ^= 1;
    await assert.rejects(
      downloadModels({ modelsDir: dir, files: FILES, fetchImpl: serve({ "model.int8.onnx": tampered, "tokens.txt": B }) }),
      (error) => error.code === "checksum-mismatch",
    );
    await assert.rejects(stat(join(dir, "sensevoice", "model.int8.onnx")));
    await assert.rejects(stat(join(dir, "sensevoice", "model.int8.onnx.part")));
  });
});

test("an HTTP error or unreachable host is reported as download-failed", async () => {
  await withDir(async (dir) => {
    await assert.rejects(downloadModels({ modelsDir: dir, files: FILES, fetchImpl: serve({}) }), (error) => error.code === "download-failed" && /HTTP 404/.test(error.message));
    const offline = async () => { throw new TypeError("fetch failed"); };
    await assert.rejects(downloadModels({ modelsDir: dir, files: FILES, fetchImpl: offline }), (error) => error.code === "download-failed" && /could not reach huggingface\.co/.test(error.message));
  });
});

test("files can be imported from another folder layout, checked by hash", async () => {
  await withDir(async (dir) => {
    const from = join(dir, "other", "models", "sensevoice-onnx");
    await mkdir(from, { recursive: true });
    await writeFile(join(from, "model.int8.onnx"), A);
    await writeFile(join(from, "tokens.txt"), Buffer.from("not the same tokens"));
    const target = join(dir, "target");
    const result = await importModels({ from: join(dir, "other"), modelsDir: target, files: FILES });
    assert.deepEqual(result.copied, ["a"]);
    assert.deepEqual(result.missing, ["b"], "a same-named file with other content is not used");
    assert.deepEqual(await readFile(join(target, "sensevoice", "model.int8.onnx")), A);
  });
});

test("same-size corrupted files are downloaded again and nested tokenizers are supported", async () => withDir(async dir => {
  await mkdir(join(dir,'sensevoice'),{recursive:true});
  await writeFile(join(dir,...FILES[0].path),Buffer.alloc(A.length));
  const nested={...FILES[1],path:['nested','tokenizer','tokens.txt']};
  const seen=[];
  await downloadModels({modelsDir:dir,files:[FILES[0],nested],fetchImpl:serve({'model.int8.onnx':A,'tokens.txt':B},seen)});
  assert.equal(seen.length,2);
  assert.deepEqual(await readFile(join(dir,...nested.path)),B);
}));

test("cancelling a download removes its partial file and keeps verified files reusable", async () => withDir(async dir => {
  const controller=new AbortController();
  await assert.rejects(downloadModels({modelsDir:dir,files:FILES,signal:controller.signal,
    fetchImpl:serve({'model.int8.onnx':A,'tokens.txt':B}),onProgress:()=>controller.abort()}));
  await assert.rejects(stat(join(dir,...FILES[0].path)+'.part'));
  await downloadModels({modelsDir:dir,files:FILES,fetchImpl:serve({'model.int8.onnx':A,'tokens.txt':B})});
  const seen=[];
  await downloadModels({modelsDir:dir,files:FILES,fetchImpl:serve({},seen)});
  assert.equal(seen.length,0);
}));
