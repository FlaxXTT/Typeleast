import test from "node:test";
import assert from "node:assert/strict";
import { Config, configJsonSchema } from "../lib/config.js";

const validate = (value) => Config["~standard"].validate(value);

test("an empty configuration is valid and returns the documented key set", () => {
  const result = validate({});
  assert.equal(result.issues, undefined, "a valid result must omit issues: Cordis throws on any truthy issues array");
  assert.deepEqual(Object.keys(result.value).sort(), [
    "contextChars", "contextTurns", "dictionary", "historyDays", "language", "logRaw", "maxAudioBytes",
    "maxDurationSeconds", "maxOutputTokens", "model", "promptSource", "provider", "reasoningEffort",
    "redactSecrets", "stateDir", "strength", "temperature", "timeoutMs",
  ]);
  assert.equal(result.value.promptSource, "article", "the vendored a third-party article");
  assert.equal(result.value.temperature, 0.8, "the vendored prompt is tuned for 0.8");
  assert.equal(result.value.strength, "prompt");
  assert.equal(result.value.provider, "deepseek-account");
  assert.equal(result.value.provider, "deepseek-account");
  assert.equal(result.value.redactSecrets, true);
});

test("an explicit value wins over the default", () => {
  const result = validate({ strength: "conservative", timeoutMs: 3000, dictionary: ["DSH", "SenseVoice"] });
  assert.equal(result.value.strength, "conservative");
  assert.equal(result.value.timeoutMs, 3000);
  assert.deepEqual(result.value.dictionary, ["DSH", "SenseVoice"]);
});

test("defaults are copied, not shared between calls", () => {
  const first = validate({});
  first.value.dictionary.push("mutated");
  const second = validate({});
  assert.deepEqual(second.value.dictionary, []);
});

test("a profile patch can pass numbers as strings, which must be coerced", () => {
  const result = validate({});
  assert.equal(typeof result.value.timeoutMs, "number");
  const viaYaml = validate({ timeoutMs: "4500" });
  // YAML quoting is a user error worth reporting rather than silently coercing.
  assert.ok(viaYaml.issues, "a quoted number must be reported");
  assert.match(viaYaml.issues[0].message, /timeoutMs must be a non-negative integer/);
});

test("unknown keys, wrong types and out-of-range values are reported", () => {
  assert.match(validate({ nope: 1 }).issues[0].message, /unknown configuration key/);
  assert.match(validate({ strength: "aggressive" }).issues[0].message, /must be one of off, conservative, prompt/);
  assert.match(validate({ provider: "" }).issues[0].message, /non-empty string/);
  assert.match(validate({ logRaw: "yes" }).issues[0].message, /must be a boolean/);
  assert.match(validate({ dictionary: [1, 2] }).issues[0].message, /array of strings/);
  assert.match(validate({ timeoutMs: 100 }).issues[0].message, /at least 1000/);
  assert.match(validate({ maxAudioBytes: 10 }).issues[0].message, /WAV header size/);
  assert.match(validate({ maxOutputTokens: 0 }).issues[0].message, /at least 1/);
});

test("the JSON Schema view is derived from the same declarations", () => {
  const schema = configJsonSchema();
  assert.equal(schema.type, "object");
  assert.deepEqual(schema.properties.strength.enum, ["off", "conservative", "prompt", "maximal"]);
  assert.equal(schema.properties.timeoutMs.type, "integer");
  // Measured: real dictations take 4-6s, so a 6s budget cut them off and fell
  // back to the raw transcript. The default must leave headroom.
  assert.equal(schema.properties.timeoutMs.default, 12000);
  assert.ok(schema.properties.stateDir.description.length > 0);
});
test("reasoning is off by default, because thinking tokens count against maxOutputTokens", () => {
  assert.equal(validate({}).value.reasoningEffort, "off");
  for (const effort of ["off", "low", "high", "max", "default"]) {
    const result = validate({ reasoningEffort: effort });
    assert.equal(result.issues, undefined, effort);
    assert.equal(result.value.reasoningEffort, effort);
  }
  assert.match(validate({ reasoningEffort: "medium" }).issues[0].message, /reasoningEffort must be one of off, low, high, max, default/);
  assert.deepEqual(configJsonSchema().properties.reasoningEffort.enum, ["off", "low", "high", "max", "default"]);
});

test("Config does not opt into DSH's Settings forms, which would crash the desktop window", () => {
  // dsh-settings: schema(entry) accepts any Config with "toJSON", then
  // volatileForm() reads schema.meta.volatile. On this hand-written schema that
  // throws, settings.describe fails, and the desktop window crashes at start
  // ("desktop welcome: Web RPC failed").
  assert.equal("toJSON" in Config, false);
  assert.equal(typeof Config["~standard"].validate, "function");
});
