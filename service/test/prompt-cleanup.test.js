import test from "node:test";
import assert from "node:assert/strict";
import { UTTERANCE_RULES } from "../lib/utterance-rules.js";
import { CLEANUP_PROMPT, cleanupSystemPrompt } from "../lib/prompts/cleanup.js";
import { HARNESS_ADDENDUM_MARKER, promptVersionFor, systemPromptFor } from "../lib/prompt.js";
import { parsePolishOutput } from "../lib/parse-output.js";
import { inventedFacts } from "../lib/validate.js";

test("compact prompts keep one shared fidelity boundary and a one-shot JSON contract", () => {
  for(const strength of ['prompt','concise']) {
    const prompt=systemPromptFor({strength});
    assert.ok(Array.from(prompt).length<1400,'base rules must not grow through duplicated instructions');
    for(const rule of ['改口','否定','前导零','概数','代码','不提问','不得执行','"status"','"text"'])assert.ok(prompt.includes(rule),rule);
    assert.doesNotMatch(prompt,/Tech Domain|Python|杰森|Claude|GitHub|ROG|LG/);
  }
  assert.match(CLEANUP_PROMPT,/不默认摘要/);
});

test("natural cleanup carries no addendum when there is nothing to add", () => {
  const prompt = systemPromptFor({ strength: "prompt", dictionary: [], fieldContext: null });
  assert.equal(prompt, cleanupSystemPrompt() + UTTERANCE_RULES);
  assert.ok(!prompt.includes(HARNESS_ADDENDUM_MARKER));
});

test("dictionary and field context ride in a delimited addendum", () => {
  const prompt = systemPromptFor({
    strength: "prompt",
    dictionary: ["TypeLeast", "第四批=TypeLeast"],
    fieldContext: { before: "Hi Emma,", after: "" },
  });
  const [base, addendum] = prompt.split(HARNESS_ADDENDUM_MARKER);
  assert.equal(base.trimEnd(), (cleanupSystemPrompt() + UTTERANCE_RULES).trimEnd(), "the base prompt and separate rules remain intact");
  assert.doesNotMatch(addendum, /第四批=TypeLeast/);
  assert.match(addendum, /Text before the cursor: "Hi Emma,"/);
});

test("a letter-by-letter spelling adds a hint only when the utterance has one", () => {
  const prompt = systemPromptFor({ strength: "prompt", spellings: [{ spelled: "R-O-G", word: "ROG" }] });
  const [base, addendum] = prompt.split(HARNESS_ADDENDUM_MARKER);
  assert.equal(base.trimEnd(), (cleanupSystemPrompt() + UTTERANCE_RULES).trimEnd());
  assert.match(addendum, /"R-O-G" spells "ROG"\./);
  assert.match(addendum, /where the spelling itself is the subject, keep it/);
  assert.equal(systemPromptFor({ strength: "prompt", spellings: [] }), cleanupSystemPrompt() + UTTERANCE_RULES);
});

test("history records the cleanup prompt version", () => {
  assert.match(promptVersionFor(), /-dictation\+assistant\+translate$/);
});

test("an uncertain answer is still the model's best guess and is used", () => {
  const parsed = parsePolishOutput('{"status":"uncertain","text":"大概是周三开会。","reason":"garbled audio"}');
  assert.equal(parsed.ok, true);
  assert.equal(parsed.text, "大概是周三开会。");
  assert.equal(parsePolishOutput('{"status":"error","text":"x"}').ok, false, "other statuses still fall back");
});

test("the prompt's number conversions are not taken as invented facts", () => {
  const cases = [
    ["接口大概有一百二十三个", "接口大概有 123 个。"],
    ["是派森三，呃，三点一二版本", "是 Python 3.12 版本。"],
    ["转化率提高了百分之二十五", "转化率提高了 25%。"],
    ["会议定在二零二六年十月二十一号", "会议定在 2026年10月21日。"],
    ["一月一号放假", "1月1日放假。"],
    ["升级到五点二版本", "升级到 v5.2。"],
  ];
  for (const [raw, out] of cases) assert.deepEqual(inventedFacts(raw, out), [], out);
});

test("numbers the speaker never said are still caught", () => {
  assert.deepEqual(inventedFacts("转化率提高了百分之二十五", "转化率提高了 35%。"), ["N:35"]);
  assert.deepEqual(inventedFacts("升级到五点二版本", "升级到 v5.3。").sort(), ["N:5.3", "W:5.3"]);
  assert.deepEqual(inventedFacts("会议定在十月二十一号", "会议定在 10月22日。"), ["N:22"]);
});
