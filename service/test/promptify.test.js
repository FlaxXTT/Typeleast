import test from "node:test";
import assert from "node:assert/strict";
import { systemPromptFor } from "../lib/prompt.js";
import { validateOutput, factTokens } from "../lib/validate.js";
import { STRENGTHS, validateConfig } from "../lib/config.js";
import { VoicePolishService } from "../lib/service.js";

const RAW = "嗯那个帮我写一个周报吧，就是这周主要做了登录页的改版，然后还修了几个bug，呃要发给我们老板看的，不要太长";
const GOOD = [
  "## 角色", "你是一位擅长工作汇报的职场写作助手。", "",
  "## 背景", "我这周主要完成了登录页的改版，还修复了几个 bug。这份周报要发给老板。", "",
  "## 任务", "帮我写一份本周的工作周报。", "",
  "## 要求", "- 涵盖登录页改版和 bug 修复这两项工作。", "- 篇幅简短。", "",
  "## 语气与受众", "面向老板，语气专业、简洁。", "",
  "## 输出格式", "一段简短的总结，加上分点正文。",
].join("\n");

test("提示词模式是一档可配置的整理强度", () => {
  assert.ok(STRENGTHS.includes("promptify"));
  assert.deepEqual(validateConfig({ strength: "promptify" }).issues, []);
});

test("提示词模式用固定的 CO-STAR 加角色结构，并写明补全和不编造的规则", () => {
  const system = systemPromptFor({ strength: "promptify" });
  for (const heading of ["## 角色", "## 背景", "## 任务", "## 要求", "## 语气与受众", "## 输出格式"]) assert.ok(system.includes(heading), heading);
  assert.match(system, /可以自行补全：角色、语气与受众、输出格式/);
  assert.match(system, /绝不编造：数字、日期/);
  assert.match(system, /整节省略/);
  assert.doesNotMatch(system, /ASR post-processing expert/, "不是 Article 整理的提示词");
  assert.match(systemPromptFor({ strength: "prompt" }), /ASR post-processing expert/, "其他档仍用 Article");
  // 词典和输入框上下文照常附加。
  assert.match(systemPromptFor({ strength: "promptify", dictionary: ["TypeLeast"] }), /HARNESS ADDENDUM[\s\S]*TypeLeast/);
});

test("合理补全角色、语气、格式的提示词能通过校验", () => {
  const verdict = validateOutput({ rawText: RAW, output: GOOD, strength: "promptify" });
  assert.equal(verdict.ok, true, JSON.stringify(verdict.metrics));
});

test("编造的数字、时间、日期会被拒绝", () => {
  for (const extra of ["篇幅控制在 300 字以内。", "周五下午前完成。", "还修复了 12 个 bug。", "截止到 2026-11-01。"]) {
    const verdict = validateOutput({ rawText: RAW, output: GOOD.replace("- 篇幅简短。", "- " + extra), strength: "promptify" });
    assert.equal(verdict.ok, false, extra);
    assert.equal(verdict.reason, "invented-fact", extra);
  }
});

test("用中文数用户自己说过的事项不算编造，只在提示词模式里放宽", () => {
  assert.equal(validateOutput({ rawText: RAW, output: GOOD, strength: "promptify" }).ok, true);
  assert.equal(validateOutput({ rawText: RAW, output: "涵盖这两项工作。", strength: "prompt" }).ok, false, "普通整理仍然严格");
});

test("同义的日期词算同一个", () => {
  assert.deepEqual([...factTokens("这周")], [...factTokens("本周")]);
  assert.deepEqual([...factTokens("星期五")], [...factTokens("周五")]);
});

test("提示词模式给模型更多输出空间和时间", async () => {
  const calls = [];
  const service = new VoicePolishService({
    recognizer: { snapshot: () => ({ ready: true }), transcribe: async () => ({ text: "" }) },
    fetchImpl: async (url, init) => {
      calls.push(JSON.parse(init.body));
      return { ok: true, status: 200, json: async () => ({ choices: [{ message: { content: GOOD }, finish_reason: "stop" }] }) };
    },
    config: { maxOutputTokens: 800, timeoutMs: 12000, strength: "prompt", redactSecrets: true, logRaw: true, maxAudioBytes: 4194304, maxDurationSeconds: 120, dictionary: [] },
    history: { append: async (e) => e, recent: async () => [] },
    logger: { info: () => {}, warn: () => {}, debug: () => {} },
  });
  const route = { baseURL: "https://api.example.com/v1", model: "m", apiKey: "sk-test-123456789012" };
  const result = await service.polish({ rawText: RAW, strength: "promptify", llm: route });
  assert.equal(result.fallback, false);
  assert.match(result.text, /^## 角色/);
  assert.match(result.text, /## 输出格式/);
  assert.equal(calls[0].max_tokens, 1600);
  assert.match(calls[0].messages[0].content, /提示词工程师/);
  await service.polish({ rawText: RAW, strength: "prompt", llm: route });
  assert.equal(calls[1].max_tokens, 800, "其他档不变");
});
