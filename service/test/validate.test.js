import test from "node:test";
import assert from "node:assert/strict";
import { unwrap } from "../lib/validate.js";

const FENCE = String.fromCharCode(96).repeat(3);
const NL = String.fromCharCode(10);

test("unwrap removes code fences and outer quotes but keeps real quotes", () => {
  const fenced = unwrap(FENCE + NL + "hello world" + NL + FENCE);
  assert.equal(fenced.text, "hello world");
  assert.equal(fenced.unwrappedFence, true);
  const quoted = unwrap('"hello world"');
  assert.equal(quoted.text, "hello world");
  assert.equal(quoted.unwrappedQuotes, true);
  assert.equal(unwrap("\u201chello\u201d").text, "hello");
  const sentence = unwrap('He said "go" and left');
  assert.equal(sentence.text, 'He said "go" and left');
  assert.equal(sentence.unwrappedQuotes, false);
  assert.equal(unwrap("plain text").text, "plain text");
});

