import test from "node:test";
import assert from "node:assert/strict";
import { systemPromptFor } from "../lib/prompt.js";
import { validateOutput, factTokens } from "../lib/validate.js";
import { canonicalStrength, STRENGTHS, validateConfig } from "../lib/config.js";
import { CONCISE_PROMPT } from "../lib/prompts/concise.js";
import { VoicePolishService } from "../lib/service.js";

const RAW = "嗯那个帮我写一个周报吧，就是这周主要做了登录页的改版，然后还修了几个bug，呃要发给我们老板看的，不要太长";
const GOOD = "请写一份本周周报，发给老板，篇幅简短。\n1. 完成登录页改版。\n2. 修复了几个 bug。";
const ROUTE = { baseURL: "https://api.example.com/v1", model: "m", apiKey: "sk-test-123456789012" };

function service(calls, content = GOOD) {
  return new VoicePolishService({
    recognizer: { snapshot: () => ({ ready: true }), transcribe: async () => ({ text: "" }) },
    fetchImpl: async (url, init) => {
      calls.push(JSON.parse(init.body));
      return { ok: true, status: 200, json: async () => ({ choices: [{ message: { content }, finish_reason: "stop" }] }) };
    },
    config: { maxOutputTokens: 800, timeoutMs: 12000, strength: "prompt", redactSecrets: true, maxAudioBytes: 4194304, maxDurationSeconds: 120, dictionary: [] },
    logger: { info: () => {}, warn: () => {}, debug: () => {} },
  });
}

test("精简整理是一档整理强度，旧的提示词档按精简整理处理", () => {
  assert.ok(STRENGTHS.includes("concise"));
  assert.deepEqual(validateConfig({ strength: "concise" }).issues, []);
  for (const retired of ["promptbrief", "promptify"]) {
    assert.ok(!STRENGTHS.includes(retired), retired);
    assert.equal(canonicalStrength(retired), "concise");
  }
  assert.equal(canonicalStrength("prompt"), "prompt");
  assert.equal(canonicalStrength(undefined), undefined);
});

test("精简整理用自己的提示词，带上词典；标准整理不受影响", () => {
  const system = systemPromptFor({ strength: "concise", dictionary: ["TypeLeast"] });
  assert.ok(system.startsWith(CONCISE_PROMPT));
  assert.match(CONCISE_PROMPT, /重排/);
  assert.match(CONCISE_PROMPT, /条件、否定、数字/);
  assert.match(CONCISE_PROMPT, /不默认摘要/);
  assert.match(CONCISE_PROMPT, /实质信息、用途/);
  assert.match(system, /HARNESS ADDENDUM[\s\S]*TypeLeast/);
  const standard = systemPromptFor({ strength: "prompt" });
  assert.doesNotMatch(standard, /# Examples|ROG|LG/, "individual cases belong in tests, not the generalized prompt");
  assert.doesNotMatch(system, /Subject Consolidation/);
});

test("精简整理给模型更多输出空间；旧的提示词档发来时也走精简整理", async () => {
  const calls = [];
  const svc = service(calls);
  for (const strength of ["concise", "promptify", "promptbrief"]) {
    const result = await svc.polish({ rawText: RAW, strength, llm: ROUTE });
    assert.equal(result.fallback, false, strength);
    assert.equal(result.text, GOOD, strength);
  }
  assert.equal(calls.length, 3, "一次调用完成");
  for (const call of calls) {
    assert.equal(call.max_tokens, 1800);
    assert.ok(call.messages[0].content.startsWith(CONCISE_PROMPT));
  }
  await svc.polish({ rawText: RAW, strength: "prompt", llm: ROUTE });
  assert.equal(calls[3].max_tokens, 1800, "标准整理不变");
});

test("精简整理的编号输出通过事实校验，编造的数字、时间、日期仍被拒绝", () => {
  assert.equal(validateOutput({ rawText: RAW, output: GOOD, strength: "concise" }).ok, true);
  for (const extra of ["篇幅控制在 300 字以内。", "周五下午前完成。", "还修复了 12 个 bug。", "截止到 2026-11-01。"]) {
    const verdict = validateOutput({ rawText: RAW, output: GOOD + "\n" + extra, strength: "concise" });
    assert.equal(verdict.reason, "invented-fact", extra);
  }
  const rawText = "请帮我把设置分组，常用模式放到容易切换的位置";
  const output = "一、请将设置按用途分组。\n\n二、将常用整理模式放在便于切换的位置。";
  assert.equal(validateOutput({ rawText, output, strength: "concise" }).ok, true, "中文编号不算新增事实");
  assert.equal(validateOutput({ rawText, output: output + "\n三、限 512 字。", strength: "concise" }).reason, "invented-fact");
});

test("用中文数用户自己说过的事项只在精简整理里放宽；精简整理也不能换语言", () => {
  assert.equal(validateOutput({ rawText: RAW, output: "涵盖这两项工作。", strength: "prompt" }).ok, false, "标准整理仍然严格");
  const english = "Write a short weekly report for my boss.\n1. Redesigned the login page.\n2. Fixed several bugs.";
  assert.equal(validateOutput({ rawText: RAW, output: english, strength: "concise" }).reason, "language-changed");
});

test("同义的日期词算同一个", () => {
  assert.deepEqual([...factTokens("这周")], [...factTokens("本周")]);
  assert.deepEqual([...factTokens("星期五")], [...factTokens("周五")]);
});
