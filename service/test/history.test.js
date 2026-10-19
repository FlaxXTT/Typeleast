import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, readFile, rm, writeFile, mkdir } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { History, textDigest } from "../lib/history.js";

async function withTempDir(run) {
  const dir = await mkdtemp(join(tmpdir(), "voice-polish-history-"));
  try {
    return await run(dir);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
}

test("append and recent round-trip, newest first", async () => {
  await withTempDir(async (dir) => {
    const history = new History({ filePath: join(dir, "history.jsonl"), retentionDays: 14 });
    await history.append({ raw: "one", text: "One." });
    await history.append({ raw: "two", text: "Two." });
    const recent = await history.recent({ limit: 5 });
    assert.deepEqual(recent.map((entry) => entry.raw), ["two", "one"]);
    assert.match(recent[0].id, /^[0-9a-f-]{36}$/);
    assert.equal(typeof recent[0].ts, "number");
  });
});

test("entries beyond the retention window are dropped on the next append", async () => {
  await withTempDir(async (dir) => {
    const history = new History({ filePath: join(dir, "history.jsonl"), retentionDays: 1 });
    history.seed([{ id: "old", ts: Date.now() - 5 * 24 * 3600 * 1000, raw: "ancient", text: "" }]);
    await history.append({ raw: "fresh", text: "" });
    const recent = await history.recent({ limit: 10 });
    assert.deepEqual(recent.map((entry) => entry.raw), ["fresh"]);
    const onDisk = await readFile(join(dir, "history.jsonl"), "utf8");
    assert.ok(!onDisk.includes("ancient"));
  });
});

test("a crash-truncated trailing line is tolerated", async () => {
  await withTempDir(async (dir) => {
    const file = join(dir, "history.jsonl");
    await writeFile(file, '{"id":"a","ts":1,"raw":"good","text":"","fallback":false}\n{"id":"b","ts":2,"ra', "utf8");
    const history = new History({ filePath: file, retentionDays: 14 });
    const recent = await history.recent({ limit: 5 });
    assert.deepEqual(recent.map((entry) => entry.raw), ["good"]);
  });
});

test("a missing file is an empty history, not an error", async () => {
  await withTempDir(async (dir) => {
    const history = new History({ filePath: join(dir, "absent.jsonl"), retentionDays: 14 });
    assert.deepEqual(await history.recent({ limit: 5 }), []);
  });
});

test("pruning also caps total bytes", async () => {
  await withTempDir(async (dir) => {
    const history = new History({ filePath: join(dir, "history.jsonl"), retentionDays: 3650 });
    const big = "x".repeat(200 * 1024);
    history.seed(Array.from({ length: 40 }, (_, index) => ({ id: String(index), ts: Date.now(), raw: big, text: "" })));
    await history.append({ raw: "last", text: "" });
    const bytes = (await readFile(join(dir, "history.jsonl"), "utf8")).length;
    assert.ok(bytes <= 5 * 1024 * 1024, "file stayed within the byte ceiling: " + bytes);
  });
});

test("a fallback's detail is stored, and is null for a clean result", async () => {
  await withTempDir(async (dir) => {
    const file = join(dir, "history.jsonl");
    const history = new History({ filePath: file, retentionDays: 14 });
    await history.append({ raw: "one", text: "One.", fallback: false });
    await history.append({ raw: "two", text: "two", fallback: true, reason: "model-max-tokens", detail: "model output hit its token limit (4712 ms)" });
    const onDisk = (await readFile(file, "utf8")).trim().split("\n").map((line) => JSON.parse(line));
    assert.equal(onDisk[0].detail, null);
    assert.equal(onDisk[1].reason, "model-max-tokens");
    assert.equal(onDisk[1].detail, "model output hit its token limit (4712 ms)");
  });
});


test("legacy words are scrubbed atomically, including fake digest prefixes", async () => {
  await withTempDir(async (dir) => {
    const file = join(dir, "history.jsonl");
    await writeFile(file, JSON.stringify({ raw: "sha256:private sample", text: "fixture words" }) + "\n");
    const history = new History({ filePath: file, retentionDays: 14 });
    assert.equal(await history.scrubText(), 2);
    const saved = JSON.parse(await readFile(file, "utf8"));
    assert.equal(saved.raw, textDigest("sha256:private sample"));
    assert.equal(saved.text, textDigest("fixture words"));
    assert.equal(await history.scrubText(), 0);
  });
});

test("failed scrubbing preserves the original and can retry", async () => {
  await withTempDir(async (dir) => {
    const file = join(dir, "history.jsonl");
    const original = JSON.stringify({ raw: "private fixture", text: "result fixture" }) + "\n";
    await writeFile(file, original);
    await mkdir(file + ".scrub.tmp");
    const history = new History({ filePath: file, retentionDays: 14 });
    await assert.rejects(history.scrubText());
    assert.equal(await readFile(file, "utf8"), original);
    assert.equal((await history.recent())[0].raw, "private fixture");
    await rm(file + ".scrub.tmp", { recursive: true });
    assert.equal(await history.scrubText(), 2);
    assert.ok(!(await readFile(file, "utf8")).includes("private fixture"));
  });
});

test("an unreadable history does not silently become empty", async () => {
  await withTempDir(async (dir) => {
    const history = new History({ filePath: dir, retentionDays: 14 });
    await assert.rejects(history.scrubText());
  });
});
