import test from "node:test";
import assert from "node:assert/strict";
import { ERDUO_FEW_SHOT, ERDUO_PROMPT, ERDUO_SOURCE, erduoSystemPrompt } from "../lib/prompts/erduo-budget-typeless.js";
import { HARNESS_ADDENDUM_MARKER, promptVersionFor, systemPromptFor } from "../lib/prompt.js";

test("the vendored prompt is the article's text, verbatim", () => {
  // Guards against a future edit quietly "improving" the upstream wording.
  assert.match(ERDUO_PROMPT, /^# Role: ASR Intelligent Cleaning Expert \(Tech Domain\)/);
  assert.match(ERDUO_PROMPT, /# Core Strategies/);
  assert.match(ERDUO_PROMPT, /Phonetic Mapping/);
  assert.match(ERDUO_PROMPT, /output in JSON format/);
  assert.match(ERDUO_PROMPT, /Pangu-style spacing/);
  assert.match(ERDUO_PROMPT, /Do not alter the original meaning, but minor reordering is acceptable/);
  // The two demonstrations that define the JSON schema.
  assert.match(ERDUO_FEW_SHOT, /"status": "ok"/);
  assert.match(ERDUO_FEW_SHOT, /"text":/);
  assert.match(ERDUO_FEW_SHOT, /"reason":/);
  assert.equal(ERDUO_SOURCE.licence, "unspecified");
});

test("the erduo source is the default and carries no addendum when there is nothing to add", () => {
  const prompt = systemPromptFor({ promptSource: undefined, strength: "prompt", dictionary: [], fieldContext: null });
  assert.equal(prompt, erduoSystemPrompt(), "no dictionary and no context means the upstream text plus its few-shot examples");
  assert.ok(!prompt.includes(HARNESS_ADDENDUM_MARKER));
});

test("dictionary and field context ride in a delimited addendum", () => {
  const prompt = systemPromptFor({
    promptSource: "erduo",
    strength: "prompt",
    dictionary: ["TypeLeast", "\u7b2c\u56db\u6279=TypeLeast"],
    fieldContext: { before: "Hi Emma,", after: "" },
  });
  const [base, addendum] = prompt.split(HARNESS_ADDENDUM_MARKER);
  assert.equal(base.trimEnd(), erduoSystemPrompt().trimEnd(), "the upstream part stays byte-identical");
  assert.match(addendum, /\u7b2c\u56db\u6279=TypeLeast/);
  assert.match(addendum, /Text before the cursor: "Hi Emma,"/);
});

test("history records the erduo prompt version", () => {
  assert.match(promptVersionFor(), /-erduo\+promptify$/);
});
