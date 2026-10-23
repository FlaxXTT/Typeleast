import test from "node:test";
import assert from "node:assert/strict";
import { systemPromptFor } from "../lib/prompt.js";
import { validateOutput, factTokens } from "../lib/validate.js";
import { STRENGTHS, validateConfig } from "../lib/config.js";
import { VoicePolishService } from "../lib/service.js";

const RAW = "嗯那个帮我写一个周报吧，就是这周主要做了登录页的改版，然后还修了几个bug，呃要发给我们老板看的，不要太长";
const GOOD = "一、请帮我写一份本周工作周报，发给老板，篇幅简短。\n\n二、本周完成了登录页改版，并修复了几个 bug。";

test("提示词模式是一档可配置的整理强度", () => {
  assert.ok(STRENGTHS.includes("promptify"));
  assert.deepEqual(validateConfig({ strength: "promptify" }).issues, []);
});

test("普通模式一次生成编号与自然段，不补角色模板，不伪称联网", () => {
  const system = systemPromptFor({ strength: "promptify" });
  assert.match(system, /一次性/);
  assert.match(system, /自然段穿插编号/);
  assert.match(system, /不使用角色、背景、任务/);
  assert.match(system, /没把握就保留用户的描述/);
  assert.match(system, /没有联网检索能力/);
  assert.match(systemPromptFor({ strength: "promptify", dictionary: ["TypeLeast"] }), /HARNESS ADDENDUM[\s\S]*TypeLeast/);
});

test("普通模式编号与自然段输出通过事实校验", () => {
  const verdict = validateOutput({ rawText: RAW, output: GOOD, strength: "promptify" });
  assert.equal(verdict.ok, true, JSON.stringify(verdict.metrics));
});

test("编造的数字、时间、日期会被拒绝", () => {
  for (const extra of ["篇幅控制在 300 字以内。", "周五下午前完成。", "还修复了 12 个 bug。", "截止到 2026-11-01。"]) {
    const verdict = validateOutput({ rawText: RAW, output: GOOD + "\n" + extra, strength: "promptify" });
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
    config: { maxOutputTokens: 800, timeoutMs: 12000, strength: "prompt", redactSecrets: true, maxAudioBytes: 4194304, maxDurationSeconds: 120, dictionary: [] },
    logger: { info: () => {}, warn: () => {}, debug: () => {} },
  });
  const route = { baseURL: "https://api.example.com/v1", model: "m", apiKey: "sk-test-123456789012" };
  const result = await service.polish({ rawText: RAW, strength: "promptify", llm: route });
  assert.equal(result.fallback, false);
  assert.match(result.text, /^一、/);
  assert.doesNotMatch(result.text, /^## /m);
  assert.equal(calls.length, 1, "普通模式一次调用完成");
  assert.equal(calls[0].max_tokens, 1600);
  assert.match(calls[0].messages[0].content, /忠实的口述整理者/);
  await service.polish({ rawText: RAW, strength: "prompt", llm: route });
  assert.equal(calls[1].max_tokens, 800, "其他档不变");
});

test("自然整理包含「统一主语」规则，在示例之前；提示词模式不受影响", () => {
  const system = systemPromptFor({ strength: "prompt" });
  assert.ok(system.indexOf("## 6. Subject Consolidation") < system.indexOf("# Few-Shot Examples"), "在示例之前");
  assert.match(system, /Subject Consolidation/);
  assert.doesNotMatch(systemPromptFor({ strength: "promptify" }), /Subject Consolidation/, "提示词模式不受影响");
});

test("提示词模式的设置：默认锁定、结尾追加、可替换、可一键恢复，并能持久化", async () => {
  const { mkdtemp, rm, readFile } = await import("node:fs/promises");
  const { tmpdir } = await import("node:os");
  const { join } = await import("node:path");
  const dir = await mkdtemp(join(tmpdir(), "typeleast-promptify-"));
  const make = () => new VoicePolishService({
    recognizer: { snapshot: () => ({ ready: true }), transcribe: async () => ({ text: "" }) },
    config: { maxOutputTokens: 800, timeoutMs: 12000, strength: "prompt", redactSecrets: true, maxAudioBytes: 4194304, maxDurationSeconds: 120, dictionary: [] },
    logger: { info: () => {}, warn: () => {}, debug: () => {} },
    promptifyPath: join(dir, "promptify.json"),
  });
  try {
    const service = make();
    const start = service.promptifySettings();
    assert.equal(start.modified, false);
    assert.equal(start.effective, start.default);

    // 追加：默认内容保持不变，追加内容在结尾单独一节。
    let s = await service.setPromptify({ appendix: "所有提示词都用英文写。" });
    assert.ok(s.effective.startsWith(s.default));
    assert.ok(s.effective.endsWith("# 补充要求\n所有提示词都用英文写。"));
    assert.equal(s.modified, false);

    // 替换默认：追加内容仍然保留在结尾。
    s = await service.setPromptify({ override: "你是我的提示词助手。" });
    assert.equal(s.modified, true);
    assert.ok(s.effective.startsWith("你是我的提示词助手。"));
    assert.match(s.effective, /# 补充要求\n所有提示词都用英文写。$/);

    // 重启后仍在。
    const reloaded = make();
    await reloaded.loadPromptify();
    assert.equal(reloaded.promptifySettings().modified, true);
    assert.match(await readFile(join(dir, "promptify.json"), "utf8"), /你是我的提示词助手/);

    // 一键恢复默认。
    s = await reloaded.setPromptify({ override: null });
    assert.equal(s.modified, false);
    assert.ok(s.effective.startsWith(s.default));

    // 把默认内容原样保存不算修改；空的替换被拒绝。
    assert.equal((await reloaded.setPromptify({ override: s.default })).modified, false);
    await assert.rejects(reloaded.setPromptify({ override: "   " }), (e) => e.code === "invalid-prompt");

    // 实际请求用的是生效的提示词。
    assert.match(systemPromptFor({ strength: "promptify", promptify: { appendix: "A", override: "B" } }), /^B\n\n# 补充要求\nA/);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("提示词模式允许按追加要求换语言（例如用英文写），但仍拦截编造的数字", () => {
  const english = "## Role\nYou are a Python engineer.\n\n## Task\nWrite a quicksort in Python.\n\n## Output Format\nComplete code with a short explanation.";
  assert.equal(validateOutput({ rawText: "呃，帮我写一个快速排序，用 Python。", output: english, strength: "promptify" }).ok, true);
  assert.equal(validateOutput({ rawText: "呃，帮我写一个快速排序，用 Python。", output: english + "\nKeep it under 50 lines.", strength: "promptify" }).reason, "invented-fact");
  assert.equal(validateOutput({ rawText: "我们周三把报告发出去，然后跟进客户的反馈意见。", output: "We will send the report on Wednesday and follow up on the client's feedback.", strength: "prompt" }).reason, "language-changed", "普通整理仍然禁止翻译");
});

test("手动编辑 promptify.json 后不用重启，下一次整理就把新内容提交给模型", async () => {
  const { mkdtemp, rm, writeFile, utimes } = await import("node:fs/promises");
  const { tmpdir } = await import("node:os");
  const { join } = await import("node:path");
  const dir = await mkdtemp(join(tmpdir(), "typeleast-promptify-"));
  const file = join(dir, "promptify.json");
  const calls = [];
  const service = new VoicePolishService({
    recognizer: { snapshot: () => ({ ready: true }), transcribe: async () => ({ text: "" }) },
    fetchImpl: async (url, init) => {
      calls.push(JSON.parse(init.body));
      return { ok: true, status: 200, json: async () => ({ choices: [{ message: { content: GOOD }, finish_reason: "stop" }] }) };
    },
    config: { maxOutputTokens: 800, timeoutMs: 12000, strength: "prompt", redactSecrets: true, maxAudioBytes: 4194304, maxDurationSeconds: 120, dictionary: [] },
    logger: { info: () => {}, warn: () => {}, debug: () => {} },
    promptifyPath: file,
  });
  const route = { baseURL: "https://api.example.com/v1", model: "m", apiKey: "sk-test-123456789012" };
  try {
    await service.loadPromptify();
    await service.polish({ rawText: RAW, strength: "promptify", llm: route });
    assert.doesNotMatch(calls[0].messages[0].content, /# 补充要求/);

    // 用文本编辑器改文件：加一条追加要求。
    await writeFile(file, JSON.stringify({ appendix: "每个小节都用无序列表。", override: null }), "utf8");
    const later = new Date(Date.now() + 5000);
    await utimes(file, later, later);
    await service.polish({ rawText: RAW, strength: "promptify", llm: route });
    assert.match(calls[1].messages[0].content, /# 补充要求\n每个小节都用无序列表。$/m);
    assert.equal((await service.promptifySettings()).appendix, "每个小节都用无序列表。");

    // 文件写坏了：退回默认提示词，整理照常进行。
    await writeFile(file, "{ 坏掉的 JSON", "utf8");
    const later2 = new Date(Date.now() + 10000);
    await utimes(file, later2, later2);
    await service.polish({ rawText: RAW, strength: "promptify", llm: route });
    assert.doesNotMatch(calls[2].messages[0].content, /# 补充要求/);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("普通模式的中文编号不算新增事实，用户没说过的数量仍会拦截", () => {
  const rawText = "请帮我把设置分组，常用模式放到容易切换的位置";
  const output = "一、请将设置按用途分组。\n\n二、将常用整理模式放在便于切换的位置。";
  assert.equal(validateOutput({ rawText, output, strength: "promptify" }).ok, true);
  assert.equal(validateOutput({ rawText, output: output + "\n三、限 512 字。", strength: "promptify" }).reason, "invented-fact");
});

test("配置文件中原样保留的默认提示词仍算默认，追加内容不丢失", async () => {
  const { mkdtemp, writeFile, rm } = await import("node:fs/promises");
  const { tmpdir } = await import("node:os");
  const { join } = await import("node:path");
  const { PROMPTIFY_PROMPT } = await import("../lib/prompts/promptify.js");
  const dir = await mkdtemp(join(tmpdir(), "typeleast-config-"));
  try {
    const file = join(dir, "promptify.json");
    await writeFile(file, JSON.stringify({ appendix: "保留这条补充", override: PROMPTIFY_PROMPT + "\n" }));
    const service = new VoicePolishService({ config: {}, promptifyPath: file });
    await service.loadPromptify();
    assert.equal(service.promptifySettings().modified, false);
    assert.equal(service.promptifySettings().appendix, "保留这条补充");
  } finally { await rm(dir, { recursive: true, force: true }); }
});

test("提示词文件只有本人可读", { skip: process.platform === "win32" }, async () => {
  const { mkdtemp, rm, stat, writeFile } = await import("node:fs/promises");
  const { tmpdir } = await import("node:os");
  const { join } = await import("node:path");
  const dir = await mkdtemp(join(tmpdir(), "typeleast-private-"));
  try {
    // A file left by an older version, readable by others, is tightened on the next write.
    await writeFile(join(dir, "promptify.json"), "{}\n", { mode: 0o644 });
    const service = new VoicePolishService({
      config: { dictionary: [] },
      promptifyPath: join(dir, "promptify.json"),
      logger: { info: () => {}, warn: () => {}, debug: () => {} },
    });
    await service.setPromptify({ appendix: "用英文写。" });
    assert.equal((await stat(join(dir, "promptify.json"))).mode & 0o777, 0o600);
  } finally { await rm(dir, { recursive: true, force: true }); }
});
