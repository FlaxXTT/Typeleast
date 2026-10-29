import test from "node:test";
import assert from "node:assert/strict";
import { approximateNumbers, chineseNumeral, contentLength, coverage, inventedFacts, novelty, stripListMarkers, translationInventedNumbers, unwrap, validateOutput } from "../lib/validate.js";

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

test("contentLength ignores punctuation and whitespace", () => {
  assert.equal(contentLength("Hello, world!"), 10);
  assert.equal(contentLength("\u4f60\u597d\uff0c\u4e16\u754c\u3002"), 4);
});

test("coverage measures restatement and novelty measures additions", () => {
  const raw = "we should send the report on tuesday, no wait, on wednesday";
  const compressed = "Send the report on Wednesday.";
  assert.ok(coverage(raw, compressed) < 0.6, "compression lowers coverage");
  assert.equal(novelty(raw, compressed), 0, "compression introduces nothing");
  const invented = "The quarterly revenue grew by twelve percent.";
  assert.equal(coverage(raw, invented), 0);
  assert.equal(novelty(raw, invented), 1, "a wholly new answer is entirely novel");
});

/** The behavioural contract of the validator, as a table of observed modes. */
const CASES = [
  {
    label: "a resolved self-correction is accepted even though it restates little",
    rawText: "um so we should send the report on tuesday, no wait, wednesday",
    output: "Send the report on Wednesday.",
    ok: true,
  },
  {
    label: "filler removal alone is accepted",
    rawText: "um uh so basically we need to ship the feature by friday",
    output: "We need to ship the feature by Friday.",
    ok: true,
  },
  {
    label: "a dictated list becomes bullets",
    rawText: "so we need to do three things first update the parser second add tests third write the docs",
    output: "We need to do three things:" + NL + "- Update the parser" + NL + "- Add tests" + NL + "- Write the docs",
    ok: true,
  },
  {
    label: "a dictated request becomes a structured prompt",
    rawText: "i want you to refactor the auth module it should use the new token helper and keep the existing api and add tests",
    output: "Refactor the auth module." + NL + NL + "- Use the new token helper." + NL + "- Keep the existing API." + NL + "- Add tests.",
    ok: true,
  },
  {
    label: "an invented deadline is rejected",
    rawText: "we need to finish the migration before the release next month",
    output: "We need to finish the migration, and I will confirm by Friday at 3pm.",
    ok: false,
    reason: "invented-fact",
  },
  {
    label: "an invented number is rejected",
    rawText: "\u5e2e\u6211\u505a\u4e00\u4e2a\u8bed\u97f3\u8f93\u5165\u8f6f\u4ef6",
    output: "\u5e2e\u6211\u505a\u4e00\u4e2a\u8bed\u97f3\u8f93\u5165\u8f6f\u4ef6\uff0c\u9884\u7b97\u4e0d\u8d85\u8fc7\u4e24\u5343\u5143\u3002",
    ok: false,
    reason: "invented-fact",
  },
  {
    label: "translating the text is rejected as a language change",
    rawText: "\u6211\u4eec\u9700\u8981\u5728\u4e0b\u4e2a\u6708\u53d1\u5e03\u524d\u5b8c\u6210\u8fc1\u79fb\uff0c\u8fd9\u4ef6\u4e8b\u5f88\u91cd\u8981",
    output: "We need to finish the migration before next month's release; this matters a lot.",
    ok: false,
    reason: "language-changed",
  },
  {
    label: "a truncated answer is rejected as too short",
    rawText: "please send the quarterly report to the finance team on Wednesday morning",
    output: "Send it.",
    ok: false,
    reason: "output-too-short",
  },
  {
    label: "an empty answer is rejected",
    rawText: "send the report on wednesday please",
    output: "   ",
    ok: false,
    reason: "empty-output",
  },
  {
    label: "a short utterance has no structure to validate",
    rawText: "sounds good",
    output: "Sounds good.",
    ok: true,
  },
];

for (const row of CASES) {
  test(row.label, () => {
    const verdict = validateOutput({ rawText: row.rawText, output: row.output, strength: "prompt" });
    assert.equal(verdict.ok, row.ok, verdict.ok ? "accepted" : "rejected: " + verdict.reason);
    if (row.reason) assert.equal(verdict.reason, row.reason);
    if (!row.ok) assert.equal(verdict.text, unwrap(row.output).text, "the candidate is still returned for diagnostics");
  });
}

test("a padded answer is rejected, for whichever reason fires first", () => {
  // Padding to 20x the source trips both the length band and the novelty band;
  // either diagnosis is correct, and pinning one would make the test brittle.
  const verdict = validateOutput({
    rawText: "send it on wednesday please",
    output: "send it on wednesday please " + "and also remember to book the room ".repeat(20),
    strength: "prompt",
  });
  assert.equal(verdict.ok, false);
  assert.ok(["invented-content", "invented-fact", "output-too-long"].includes(verdict.reason), verdict.reason);
});

test("a fenced answer is unwrapped and accepted, and the unwrapping is reported", () => {
  const verdict = validateOutput({
    rawText: "the answer is to restart the service and then check the logs",
    output: FENCE + NL + "Restart the service, then check the logs." + NL + FENCE,
    strength: "prompt",
  });
  assert.equal(verdict.ok, true, verdict.reason);
  assert.equal(verdict.text, "Restart the service, then check the logs.");
  assert.equal(verdict.metrics.unwrappedFence, true);
});

test("conservative mode tolerates less restatement loss than prompt mode", () => {
  // Heavy compression reads as faithful under prompt mode and as drift under
  // conservative mode, which is the intended difference between the two.
  const rawText = "so we need to do three things first update the parser second add tests third write the docs";
  const compressed = "Update the parser, add tests, write the docs.";
  const both = (output) => ({
    conservative: validateOutput({ rawText, output, strength: "conservative" }).ok,
    prompt: validateOutput({ rawText, output, strength: "prompt" }).ok,
  });
  // A rewrite that keeps most of the content is accepted by both.
  assert.deepEqual(both("We need to do three things: update the parser, add tests, and write the docs."), { conservative: true, prompt: true });
  // A rewrite that drops most of it is drift for conservative, and allowed under
  // prompt because the user asked for bold restructuring; fabrication is what the
  // fact guard polices in that mode.
  const partial = both("Update the parser and add tests.");
  assert.equal(partial.conservative, false, "conservative demands the whole content survive");
  assert.equal(partial.prompt, true, "prompt mode accepts the condensation");
});

test("every verdict carries metrics a log reader can act on", () => {
  const verdict = validateOutput({ rawText: "send the report on wednesday morning", output: "Send the report on Wednesday morning.", strength: "prompt" });
  for (const key of ["rawLength", "outputLength", "coverage", "novelty", "ratio", "outputUnits", "outputUnitRatio"]) {
    assert.equal(typeof verdict.metrics[key], "number", "missing metric " + key);
  }
});
test("numbered list labels are layout, not invented numbers", () => {
  const cases = [
    ["我要做三件事第一更新解析器第二加测试第三写文档", "我要做三件事：\n1. 更新解析器\n2. 加测试\n3. 写文档"],
    ["首先把登录页改一下其次把注册流程简化最后加上找回密码", "1. 修改登录页\n2. 简化注册流程\n3. 加上找回密码"],
    ["so we need to do three things first update the parser second add tests third write the docs", "We need to do three things:\n1. Update the parser.\n2. Add tests.\n3. Write the docs."],
  ];
  for (const [rawText, output] of cases) {
    const verdict = validateOutput({ rawText, output, strength: "prompt" });
    assert.equal(verdict.ok, true, output + " -> " + verdict.reason);
  }
  assert.equal(stripListMarkers("1. 甲\n2) 乙\n3、丙\n一、丁\n- 戊"), "甲\n乙\n丙\n丁\n戊");
  assert.equal(stripListMarkers("1.5 倍"), "1.5 倍", "a decimal at line start is a number, not a label");
});

test("Chinese numerals and digits state the same fact", () => {
  assert.deepEqual(["两", "十二", "二十三", "一百零五", "二零二六", "三千"].map(chineseNumeral), [2, 12, 23, 105, 2026, 3000]);
  assert.equal(chineseNumeral("abc"), null);
  assert.deepEqual(inventedFacts("我们有两个平台要支持", "我们有 2 个平台要支持。"), []);
  assert.deepEqual(inventedFacts("这个功能有问题", "这个功能有一个问题。"), [], "the indefinite 一个 is not a fact");
  assert.deepEqual(inventedFacts("帮我做一个语音输入软件", "帮我做一个语音输入软件，预算不超过两千元，周五前完成。"), ["N:2000", "D:周五"]);
});

test("two neighbouring numbers are an estimate, not one number", () => {
  const ranges = (text) => approximateNumbers(text).map(({ lo, hi }) => [lo, hi]);
  assert.deepEqual(ranges("我要三四个"), [[3, 4]]);
  assert.deepEqual(ranges("来了十七八个人，大概二三十分钟，七八百块，二十三四岁，一两天，三五天"), [[17, 18], [20, 30], [700, 800], [23, 24], [1, 2], [3, 5]]);
  assert.deepEqual(ranges("验证码是一二三四五六"), [], "a code read digit by digit is not an estimate");
  assert.deepEqual(ranges("房间乱七八糟"), [], "an idiom is not an estimate");
  assert.deepEqual(ranges("三十四个"), [], "thirty-four is one number");

  assert.deepEqual(inventedFacts("我要三四个苹果", "我要 34 个苹果。"), ["N:34"], "three or four is not 34");
  assert.deepEqual(inventedFacts("来了十七八个同学", "来了 178 个同学。"), ["N:178"]);
  assert.deepEqual(inventedFacts("我要三四个苹果", "我要三四个苹果。"), []);
  assert.deepEqual(inventedFacts("我要三四个苹果", "我要 3 到 4 个苹果。"), []);
  assert.deepEqual(inventedFacts("我要三个或者四个", "我要三四个。"), []);
  assert.deepEqual(inventedFacts("我要三个或者四个", "我要 34 个。"), ["N:34"]);
  assert.deepEqual(inventedFacts("验证码是一二三四五六", "验证码是 123456。"), []);
  assert.deepEqual(translationInventedNumbers("我要三四个苹果", "I want 3 or 4 apples."), []);
  assert.deepEqual(translationInventedNumbers("我要三四个苹果", "I want 34 apples."), ["34"]);
});

test("a count that matches the list it introduces is structure, not invention", () => {
  const raw = "呃这个需求是这样的首先登录页要改一下其次注册流程要简化最后要加一个找回密码的功能";
  assert.equal(validateOutput({ rawText: raw, output: "这个需求包括以下三点：\n1. 修改登录页\n2. 简化注册流程\n3. 增加找回密码功能", strength: "prompt" }).ok, true);
  assert.equal(validateOutput({ rawText: raw, output: "这个需求包括以下四点：\n1. 修改登录页\n2. 简化注册流程\n3. 增加找回密码功能", strength: "prompt" }).reason, "invented-fact", "a wrong count is still invented");
});

test("spelling out English words in a Chinese sentence is not a translation", async () => {
  const { languageChanged } = await import("../lib/validate.js");
  const raw = "我在iphone上用n记的笔记";
  assert.equal(validateOutput({ rawText: raw, output: "我在 iPhone 上用 Notion 记的笔记。", strength: "prompt" }).ok, true);
  assert.equal(validateOutput({ rawText: "把周可的image推到registry上", output: "把 Docker 的 image 推到 registry 上。", strength: "prompt" }).ok, true);
  assert.equal(languageChanged("我们下个月发布前要完成迁移", "We need to finish the migration before next month's release."), true);
  assert.equal(languageChanged("we need to finish the migration before the release", "我们需要在发布前完成迁移。"), true);
  assert.equal(languageChanged("这个PR的CI挂了", "这个 PR 的 CI 挂了。"), false);
});
