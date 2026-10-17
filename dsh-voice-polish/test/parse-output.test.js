import test from "node:test";
import assert from "node:assert/strict";
import { parsePolishOutput } from "../lib/parse-output.js";

test("a well-formed reply yields text and reason", () => {
  const result = parsePolishOutput(JSON.stringify({ status: "ok", text: "Send the report.", reason: "Removed filler words." }));
  assert.equal(result.ok, true);
  assert.equal(result.text, "Send the report.");
  assert.equal(result.reason, "Removed filler words.");
  assert.equal(result.mode, "json");
});

test("a fenced reply is unwrapped before parsing", () => {
  const fenced = "```json\n" + JSON.stringify({ status: "ok", text: "Push the code to GitHub." }) + "\n```";
  const result = parsePolishOutput(fenced);
  assert.equal(result.ok, true);
  assert.equal(result.text, "Push the code to GitHub.");
});

test("a non-ok status is not inserted", () => {
  const result = parsePolishOutput(JSON.stringify({ status: "error", text: "should not appear", reason: "model refused" }));
  assert.equal(result.ok, false);
  assert.equal(result.text, "");
  assert.match(result.failure, /status:error/);
});

test("a malformed body still yields its text field", () => {
  const broken = 'Sure! {"status":"ok","text":"We should ship it Friday.","reason":"fixed"} hope that helps';
  const result = parsePolishOutput(broken);
  assert.equal(result.ok, true);
  assert.equal(result.text, "We should ship it Friday.");
  assert.equal(result.mode, "regex");
});

test("plain prose passes through unchanged", () => {
  const result = parsePolishOutput("We should ship it Friday.");
  assert.equal(result.ok, true);
  assert.equal(result.text, "We should ship it Friday.");
  assert.equal(result.mode, "plain");
});

test("unparsable JSON never reaches the document as braces", () => {
  const result = parsePolishOutput('{"status": "ok", "text": }');
  assert.equal(result.ok, false);
  assert.equal(result.text, "");
  assert.equal(result.failure, "unparsable-json");
});

test("an empty text field is rejected", () => {
  assert.equal(parsePolishOutput(JSON.stringify({ status: "ok", text: "   " })).failure, "empty-text");
  assert.equal(parsePolishOutput("   ").failure, "empty");
});

test("an object without a text field is rejected", () => {
  const result = parsePolishOutput(JSON.stringify({ status: "ok", reason: "done" }));
  assert.equal(result.ok, false);
  assert.equal(result.failure, "no-text-field");
});
