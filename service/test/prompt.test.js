import test from "node:test";
import assert from "node:assert/strict";
import { erduoSystemPrompt } from "../lib/prompts/erduo-budget-typeless.js";
import { buildUserMessage, HARNESS_ADDENDUM_MARKER, PROMPT_SOURCES, PROMPT_VERSION, systemPromptFor } from "../lib/prompt.js";

test("erduo is the only prompt source", () => {
  assert.deepEqual(PROMPT_SOURCES, ["erduo"]);
  assert.match(PROMPT_VERSION, /-erduo\+subject\+promptify$/);
});

test("the user message is the recognised text and nothing else", () => {
  assert.equal(buildUserMessage({ rawText: "我想说三点，第一要快", appHint: "com.apple.mail", dictionary: ["TypeLeast"] }), "我想说三点，第一要快");
  assert.equal(buildUserMessage({}), "");
});

test("without a dictionary or field context the system prompt is exactly the upstream text", () => {
  assert.equal(systemPromptFor({ dictionary: [], fieldContext: null }), erduoSystemPrompt());
  assert.equal(systemPromptFor(), erduoSystemPrompt());
});

test("the addendum carries only the dictionary and the non-empty parts of the field", () => {
  const prompt = systemPromptFor({
    dictionary: ["DeepSeek", "得普=DeepSeek"],
    fieldContext: { before: "Hi Emma,", selected: "", after: "  ", windowTitle: "New Message" },
  });
  const [upstream, addendum] = prompt.split(HARNESS_ADDENDUM_MARKER);
  assert.equal(upstream.trimEnd(), erduoSystemPrompt().trimEnd());
  assert.match(addendum, /Entries: DeepSeek \| 得普=DeepSeek/);
  assert.match(addendum, /Window title: "New Message"/);
  assert.match(addendum, /Text before the cursor: "Hi Emma,"/);
  assert.doesNotMatch(addendum, /Selected text|Text after the cursor/, "empty parts are left out");
  assert.doesNotMatch(addendum, /numbered list|register|commonEnglishTerms/, "nothing of the removed built-in prompt");
});
