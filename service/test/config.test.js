import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { configJsonSchema, loadConfig, validateConfig } from "../lib/config.js";

test("an empty configuration is valid and returns the documented key set", () => {
  const result = validateConfig({});
  assert.deepEqual(result.issues, []);
  assert.deepEqual(Object.keys(result.value).sort(), [
    "dictionary", "historyDays", "language", "logRaw", "maxAudioBytes", "maxDurationSeconds",
    "maxOutputTokens", "numThreads", "redactSecrets", "strength", "temperature", "timeoutMs",
  ]);
  assert.equal(result.value.temperature, 0.8, "the vendored prompt is tuned for 0.8");
  assert.equal(result.value.strength, "prompt");
  assert.equal(result.value.redactSecrets, true);
  assert.equal(result.value.numThreads, 2);
});

test("no model, provider or key is configured in the service", () => {
  // The route and key travel with each request from the app; nothing here may hold one.
  for (const key of ["provider", "model", "apiKey", "baseURL"]) {
    assert.match(validateConfig({ [key]: "x" }).issues[0].message, /unknown configuration key/);
  }
});

test("an explicit value wins over the default", () => {
  const result = validateConfig({ strength: "conservative", timeoutMs: 8000, dictionary: ["TypeLeast", "SenseVoice"] });
  assert.equal(result.value.strength, "conservative");
  assert.equal(result.value.timeoutMs, 8000);
  assert.deepEqual(result.value.dictionary, ["TypeLeast", "SenseVoice"]);
  assert.deepEqual(result.issues, []);
});

test("defaults are copied, not shared between calls", () => {
  const first = validateConfig({});
  first.value.dictionary.push("mutated");
  assert.deepEqual(validateConfig({}).value.dictionary, []);
});

test("bad values are reported and keep their defaults, never fatal", () => {
  const cases = [
    [{ nope: 1 }, /unknown configuration key/, null],
    [{ strength: "aggressive" }, /must be one of off, conservative, prompt/, ["strength", "prompt"]],
    [{ logRaw: "yes" }, /must be a boolean/, ["logRaw", true]],
    [{ dictionary: [1, 2] }, /array of strings/, ["dictionary", []]],
    [{ timeoutMs: "4500" }, /non-negative integer/, ["timeoutMs", 12000]],
    [{ timeoutMs: 100 }, /at least 1000/, ["timeoutMs", 12000]],
    [{ maxAudioBytes: 10 }, /WAV header size/, ["maxAudioBytes", 4194304]],
    [{ maxOutputTokens: 0 }, /at least 1/, ["maxOutputTokens", 800]],
    [{ numThreads: 64 }, /between 1 and 16/, ["numThreads", 2]],
  ];
  for (const [input, message, kept] of cases) {
    const result = validateConfig(input);
    assert.match(result.issues[0].message, message, JSON.stringify(input));
    if (kept) assert.deepEqual(result.value[kept[0]], kept[1], JSON.stringify(input));
  }
  assert.match(validateConfig({ timeoutMs: 4000 }).issues[0].message, /below 6000/);
});

test("the JSON Schema view is derived from the same declarations", () => {
  const schema = configJsonSchema();
  assert.equal(schema.type, "object");
  assert.deepEqual(schema.properties.strength.enum, ["off", "conservative", "prompt", "maximal", "promptify", "promptbeta"]);
  assert.equal(schema.properties.timeoutMs.type, "integer");
  // Measured: real dictations take 4-6s, so a 6s budget cut them off and fell
  // back to the raw transcript. The default must leave headroom.
  assert.equal(schema.properties.timeoutMs.default, 12000);
});

test("config.json is read from the state directory; missing or malformed means defaults", async () => {
  const dir = await mkdtemp(join(tmpdir(), "typeleast-config-"));
  try {
    assert.deepEqual((await loadConfig(dir)).issues, [], "no file is fine");
    await writeFile(join(dir, "config.json"), JSON.stringify({ timeoutMs: 15000, dictionary: ["TypeLeast"] }));
    const loaded = await loadConfig(dir);
    assert.equal(loaded.value.timeoutMs, 15000);
    assert.deepEqual(loaded.value.dictionary, ["TypeLeast"]);
    await writeFile(join(dir, "config.json"), "{ not json");
    const broken = await loadConfig(dir);
    assert.equal(broken.value.timeoutMs, 12000);
    assert.match(broken.issues[0].message, /could not be read/);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});
