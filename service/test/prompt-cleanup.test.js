import test from "node:test";
import assert from "node:assert/strict";
import { UTTERANCE_RULES } from "../lib/utterance-rules.js";
import { CLEANUP_PROMPT, cleanupSystemPrompt } from "../lib/prompts/cleanup.js";
import { HARNESS_ADDENDUM_MARKER, promptVersionFor, systemPromptFor } from "../lib/prompt.js";
import { parsePolishOutput } from "../lib/parse-output.js";
import { inventedFacts } from "../lib/validate.js";

test("cleanup remains general and keeps the output contract", () => {
  for (const rule of ["# Task", "# Rules", "# Examples", "# Check before answering", "correction", "numbers", "ordinary word", "subject", "everyday sense", "letter by letter", "非常非常"]) {
    assert.ok(CLEANUP_PROMPT.includes(rule), rule);
  }
  assert.match(CLEANUP_PROMPT, /"status":"ok"\|"uncertain"/);
  assert.equal((CLEANUP_PROMPT.match(/^Input: /gm) ?? []).length, 6);
  assert.ok(CLEANUP_PROMPT.includes("三四个") && CLEANUP_PROMPT.includes("never join them"), "an estimate stays an estimate");
  assert.ok(CLEANUP_PROMPT.indexOf("# Examples") < CLEANUP_PROMPT.indexOf("# Check before answering"), "the check comes last");
  for (const specialised of ["Tech Domain", "Python", "杰森", "Claude", "GitHub"]) assert.ok(!CLEANUP_PROMPT.includes(specialised));
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
  assert.match(addendum, /第四批=TypeLeast/);
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
  assert.match(promptVersionFor(), /-cleanup\+concise\+beta\+translate$/);
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
