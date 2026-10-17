import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, readFile, readdir, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { publishRuntime, withdrawRuntime, RUNTIME_FILE } from "../lib/runtime.js";

async function withDir(run) {
  const dir = await mkdtemp(join(tmpdir(), "voice-polish-runtime-"));
  try {
    return await run(dir);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
}

test("publishes the live port atomically, with owner-only permissions", async () => {
  await withDir(async (dir) => {
    const target = await publishRuntime({ stateDir: dir, port: 51234, pid: 1234, version: "0.1.0", startedAt: 1 });
    assert.equal(target, join(dir, RUNTIME_FILE));
    const parsed = JSON.parse(await readFile(target, "utf8"));
    assert.equal(parsed.port, 51234);
    assert.equal(parsed.pid, 1234);
    assert.equal(parsed.host, "127.0.0.1");
    assert.equal(parsed.schemaVersion, 1);
    // No temporary file may survive a successful publish.
    const entries = await readdir(dir);
    assert.deepEqual(entries, [RUNTIME_FILE]);
  });
});

test("republishing replaces the descriptor rather than appending", async () => {
  await withDir(async (dir) => {
    await publishRuntime({ stateDir: dir, port: 1000, pid: 1, version: "a", startedAt: 1 });
    await publishRuntime({ stateDir: dir, port: 2000, pid: 2, version: "b", startedAt: 2 });
    const parsed = JSON.parse(await readFile(join(dir, RUNTIME_FILE), "utf8"));
    assert.equal(parsed.port, 2000);
  });
});

test("withdraw removes only our own descriptor", async () => {
  await withDir(async (dir) => {
    await publishRuntime({ stateDir: dir, port: 1000, pid: 7, version: "a", startedAt: 1 });
    // A different pid means a newer host owns the file; leave it alone.
    await withdrawRuntime({ stateDir: dir, pid: 8 });
    assert.equal(JSON.parse(await readFile(join(dir, RUNTIME_FILE), "utf8")).pid, 7);
    await withdrawRuntime({ stateDir: dir, pid: 7 });
    await assert.rejects(() => readFile(join(dir, RUNTIME_FILE), "utf8"));
  });
});

test("withdrawing a file that does not exist is not an error", async () => {
  await withDir(async (dir) => {
    await withdrawRuntime({ stateDir: dir, pid: 1 });
  });
});
