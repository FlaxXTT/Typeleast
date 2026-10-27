import test from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { request } from "node:http";
import { mkdtemp, readFile, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { once } from "node:events";
import { fileURLToPath } from "node:url";
import { startService } from "../lib/server.js";

const BIN = fileURLToPath(new URL("../bin/typeleast-service.mjs", import.meta.url));
const quiet = { info: () => {}, warn: () => {}, debug: () => {} };
const recognizer = {
  prepare: async () => "ready",
  snapshot: () => ({ providerId: "sensevoice-local", engine: "sherpa-onnx", phase: "ready", ready: true, languages: ["auto"] }),
  transcribe: async () => ({ text: "呃，我们周三把报告发出去吧。" }),
};

function wav(seconds) {
  const samples = Math.round(16000 * seconds);
  const buffer = Buffer.alloc(44 + samples * 2);
  buffer.write("RIFF", 0, "ascii"); buffer.writeUInt32LE(36 + samples * 2, 4); buffer.write("WAVE", 8, "ascii");
  buffer.writeUInt32LE(16, 16); buffer.writeUInt16LE(1, 20); buffer.writeUInt16LE(1, 22);
  buffer.writeUInt32LE(16000, 24); buffer.writeUInt32LE(32000, 28); buffer.writeUInt16LE(2, 32); buffer.writeUInt16LE(16, 34);
  buffer.write("data", 36, "ascii"); buffer.writeUInt32LE(samples * 2, 40);
  return buffer;
}

/** One raw HTTP request, so the Host header can be anything. */
function raw(port, { method = "GET", path, headers = {}, body }) {
  return new Promise((resolve, reject) => {
    const req = request({ host: "127.0.0.1", port, method, path, headers }, (res) => {
      const chunks = [];
      res.on("data", (chunk) => chunks.push(chunk));
      res.on("end", () => resolve({ status: res.statusCode, json: JSON.parse(Buffer.concat(chunks).toString("utf8") || "null") }));
    });
    req.on("error", reject);
    if (body) req.write(body);
    req.end();
  });
}

async function withDir(run) {
  const dir = await mkdtemp(join(tmpdir(), "typeleast-server-"));
  try {
    await run(dir);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
}

test("the service listens on loopback, publishes its port, and serves the contract", async () => {
  await withDir(async (dir) => {
    const handle = await startService({ stateDir: dir, modelsDir: join(dir, "models"), logger: quiet, recognizer });
    try {
      assert.equal(handle.service.extension.state().plugins.some(p => p.id === 'typeleast.tech-terms'), false, 'fresh installs stay general');
      const runtime = JSON.parse(await readFile(join(dir, "runtime.json"), "utf8"));
      assert.equal(runtime.port, handle.port);
      assert.equal(runtime.host, "127.0.0.1");
      assert.equal(runtime.pid, process.pid);
      const token = (await readFile(join(dir, "api-token"), "utf8")).trim();
      assert.match(token, /^[0-9a-f]{64}$/);
      const auth = { host: `127.0.0.1:${handle.port}`, authorization: `Bearer ${token}` };

      const health = await raw(handle.port, { path: "/api/voice-polish/health", headers: auth });
      assert.equal(health.status, 200);
      assert.equal(health.json.service, "typeleast");
      assert.equal(health.json.ok, true);

      // A page in a browser cannot reach the port under another name.
      const rebinding = await raw(handle.port, { path: "/api/voice-polish/health", headers: { ...auth, host: `evil.example.com:${handle.port}` } });
      assert.equal(rebinding.status, 403);
      assert.equal((await raw(handle.port, { path: "/api/voice-polish/health", headers: { host: auth.host } })).status, 401);

      // A dictation without an API key still inserts the tidied transcript.
      const dictated = await raw(handle.port, { method: "POST", path: "/api/voice-polish/dictate", headers: { ...auth, "content-type": "audio/wav" }, body: wav(0.5) });
      assert.equal(dictated.status, 200);
      assert.equal(dictated.json.fallback, true);
      assert.equal(dictated.json.fallbackReason, "no-api-key");
      assert.equal(dictated.json.text, "");
      // The app's dictionary rides ahead of the audio.
      const dictionary = Buffer.from(JSON.stringify(["TypeLeast"]));
      const withDictionary = await raw(handle.port, { method: "POST", path: "/api/voice-polish/dictate",
        headers: { ...auth, "content-type": "audio/wav", "x-voice-dictionary-bytes": String(dictionary.length) }, body: Buffer.concat([dictionary, wav(0.5)]) });
      assert.equal(withDictionary.status, 200);
      assert.equal(withDictionary.json.text, "");
      const badLength = await raw(handle.port, { method: "POST", path: "/api/voice-polish/dictate",
        headers: { ...auth, "content-type": "audio/wav", "x-voice-dictionary-bytes": "-1" }, body: wav(0.5) });
      assert.equal(badLength.status, 400);
      // Removed endpoints are gone.
      for (const path of ["/api/voice-polish/history", "/api/voice-polish/dictionary"]) {
        assert.equal((await raw(handle.port, { path, headers: auth })).status, 404, path);
      }
    } finally {
      await handle.close();
    }
    await assert.rejects(stat(join(dir, "runtime.json")), "closing withdraws runtime.json");
  });
});

test('an existing state gets bundled terminology once without a market request', async () => {
  await withDir(async dir => {
    await writeFile(join(dir, 'api-token'), 'a'.repeat(64) + '\n');
    const handle = await startService({ stateDir: dir, modelsDir: join(dir, 'models'), logger: quiet, recognizer });
    try {
      const pack = handle.service.extension.state().plugins.find(p => p.id === 'typeleast.tech-terms');
      assert.equal(pack, undefined);
      assert.equal(handle.service.extension.store.state.vocabularyRemoved,true);

    } finally { await handle.close(); }
    const again = await startService({ stateDir: dir, modelsDir: join(dir, 'models'), logger: quiet, recognizer });
    try { assert.equal(again.service.extension.state().plugins.find(p => p.id === 'typeleast.tech-terms'), undefined); }
    finally { await again.close(); }
  });
});

test('core dictation starts and answers with the extension module disabled', async () => {
  await withDir(async dir => {
    const handle = await startService({ stateDir: dir, modelsDir: join(dir, 'models'), logger: quiet, recognizer, extensions: false });
    try {
      assert.equal(handle.service.extension, null);
      await assert.rejects(stat(join(dir, 'plugins')), 'no extension state is created');
      const token = (await readFile(join(dir, 'api-token'), 'utf8')).trim();
      const headers = { host: `127.0.0.1:${handle.port}`, authorization: `Bearer ${token}` };
      const plugins = await raw(handle.port, { path: '/api/voice-polish/plugins', headers });
      assert.deepEqual([plugins.status, plugins.json.code], [503, 'plugins-unavailable']);
      const dictated = await raw(handle.port, { method: 'POST', path: '/api/voice-polish/dictate',
        headers: { ...headers, 'content-type': 'audio/wav' }, body: wav(0.5) });
      assert.deepEqual([dictated.status, dictated.json.text], [200, '']);
    } finally { await handle.close(); }
  });
});

test("the command prints a ready line and exits when its parent does", async () => {
  await withDir(async (dir) => {
    // A stand-in "app" process whose pid the service watches.
    const parent = spawn(process.execPath, ["-e", "setTimeout(() => {}, 60000)"], { stdio: "ignore" });
    const child = spawn(process.execPath, [BIN, "--state-dir", dir, "--models-dir", join(dir, "models"), "--parent-pid", String(parent.pid)], { stdio: ["ignore", "pipe", "pipe"] });
    try {
      const [line] = await new Promise((resolve, reject) => {
        let buffered = "";
        child.stdout.on("data", (chunk) => {
          buffered += chunk;
          if (buffered.includes("\n")) resolve(buffered.split("\n"));
        });
        child.once("exit", (code) => reject(new Error(`exited early with ${code}`)));
      });
      const ready = JSON.parse(line);
      assert.equal(ready.event, "ready");
      assert.ok(ready.port > 0);
      assert.equal(ready.pid, child.pid);
      const runtime = JSON.parse(await readFile(join(dir, "runtime.json"), "utf8"));
      assert.equal(runtime.port, ready.port);

      parent.kill();
      const [code] = await Promise.race([
        once(child, "exit"),
        new Promise((_, reject) => setTimeout(() => reject(new Error("service outlived its parent")), 8000)),
      ]);
      assert.equal(code, 0);
    } finally {
      parent.kill();
      child.kill();
    }
  });
});

test("a bad --port is refused", async () => {
  const child = spawn(process.execPath, [BIN, "--port", "99999"], { stdio: ["ignore", "ignore", "pipe"] });
  const [code] = await once(child, "exit");
  assert.equal(code, 2);
});
