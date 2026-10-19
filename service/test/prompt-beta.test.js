import test from "node:test";
import assert from "node:assert/strict";
import { VoicePolishService } from "../lib/service.js";
import { STRENGTHS } from "../lib/config.js";
import {
  BETA_DRAFT_PROMPT, BETA_INTERVIEW_PROMPT, BETA_PATCH_PROMPT, BETA_REVIEW_PROMPT, BETA_LIMITS,
  hasContent, normaliseQuestions, parseJsonReply,
} from "../lib/prompts/prompt-beta.js";

const ROUTE = { baseURL: "https://api.example.com/v1", model: "m", apiKey: "test-key" };
const REQUEST = "帮我写个提示词，让 AI 把会议记录整理成纪要，嗯，要简短，不对，要详细一点，发给团队看";
const DRAFT = "## 目标\n把会议记录整理成纪要，发给团队。\n\n## 输出\n内容详细，分节列出决定和待办。";
const PATCHED = "## 目标\n把会议记录整理成纪要，供团队阅读。\n\n## 输出\n内容详细，分节列出决定和待办。";

/** A fake provider that answers each stage by looking at its system prompt. */
function provider(script) {
  const calls = [];
  const fetchImpl = async (_url, init) => {
    const body = JSON.parse(init.body);
    const system = body.messages[0].content;
    const stage = system === BETA_INTERVIEW_PROMPT ? "interview" : system === BETA_DRAFT_PROMPT ? "draft"
      : system === BETA_REVIEW_PROMPT ? "review" : system === BETA_PATCH_PROMPT ? "patch" : "other";
    calls.push({ stage, user: body.messages[1].content });
    const content = typeof script[stage] === "function" ? script[stage](calls) : script[stage];
    return { ok: true, status: 200, json: async () => ({ choices: [{ message: { content }, finish_reason: "stop" }] }) };
  };
  return { calls, fetchImpl };
}

function makeService(fetchImpl, history = []) {
  return new VoicePolishService({
    recognizer: { snapshot: () => ({ ready: true }), transcribe: async () => ({ text: "" }) },
    fetchImpl,
    config: { maxOutputTokens: 800, timeoutMs: 12000, strength: "prompt", redactSecrets: true, logRaw: true, maxAudioBytes: 4194304, maxDurationSeconds: 120, dictionary: [] },
    history: { append: async (e) => { history.push(e); return e; }, recent: async () => [] },
    logger: { info: () => {}, warn: () => {}, debug: () => {} },
  });
}

const INTERVIEW_WITH_QUESTIONS = JSON.stringify({
  goal: "把会议记录整理成纪要", audience: "团队", success: ["列出决定和待办"], constraints: [],
  output: "", assumptions: [], questions: ["纪要要简短还是详细？", "纪要要简短还是详细？", "  "],
});

test("提示词 Beta 是一档独立的整理强度，原来的提示词模式不变", () => {
  assert.ok(STRENGTHS.includes("promptbeta"));
  assert.ok(STRENGTHS.includes("promptify"));
});

test("采访、起草、审查、修补四份提示词写明了核心规则", () => {
  assert.match(BETA_INTERVIEW_PROMPT, /以最后的说法为准/);
  assert.match(BETA_INTERVIEW_PROMPT, /不要替用户二选一/);
  assert.match(BETA_INTERVIEW_PROMPT, /最多 4 个/);
  assert.match(BETA_DRAFT_PROMPT, /角色与情境[\s\S]*目标[\s\S]*成功标准[\s\S]*约束[\s\S]*工作方式[\s\S]*输出[\s\S]*停止与兜底/);
  assert.match(BETA_DRAFT_PROMPT, /两种说法都不要写进提示词正文/);
  assert.match(BETA_DRAFT_PROMPT, /「必须」「绝不」只留给/);
  assert.match(BETA_DRAFT_PROMPT, /不要写「你是世界顶级专家」/);
  assert.match(BETA_REVIEW_PROMPT, /你只诊断，不修改/);
  assert.match(BETA_PATCH_PROMPT, /最小必要的修改/);
});

test("有关键问题时：先只返回问题，不写入、不记历史；口头回答后起草、审查、修补", async () => {
  const history = [];
  const { calls, fetchImpl } = provider({
    interview: INTERVIEW_WITH_QUESTIONS,
    draft: DRAFT,
    review: JSON.stringify({ issues: [{ type: "ambiguity", quote: "发给团队", why: "用途不清", fix: "写明供团队阅读" }] }),
    patch: PATCHED,
  });
  const service = makeService(fetchImpl, history);
  const first = await service.polish({ rawText: REQUEST, strength: "promptbeta", llm: ROUTE });
  assert.equal(first.text, "");
  assert.deepEqual(first.beta.questions, ["纪要要简短还是详细？"], "去重、去空");
  assert.equal(history.length, 0, "问题阶段不写历史");
  assert.deepEqual(calls.map((c) => c.stage), ["interview"]);

  const second = await service.polish({ rawText: "详细一点", strength: "promptbeta", llm: ROUTE, betaSession: first.beta.sessionId });
  assert.deepEqual(calls.map((c) => c.stage), ["interview", "draft", "review", "patch"]);
  assert.match(calls[1].user, /<request>[\s\S]*会议记录[\s\S]*<\/request>/);
  assert.match(calls[1].user, /<answers>\n详细一点\n<\/answers>/);
  assert.match(calls[3].user, /<issues>/);
  assert.equal(second.text, PATCHED);
  assert.equal(second.fallback, false);
  assert.equal(second.beta.patched, true);
  assert.equal(history.length, 1);
  await assert.rejects(
    service.polish({ rawText: "再答一次", strength: "promptbeta", llm: ROUTE, betaSession: first.beta.sessionId }),
    { code: "beta-expired" }, "会话用一次就作废");
});

test("需求已经清楚时不提问，直接起草；审查没发现问题就不修补", async () => {
  const { calls, fetchImpl } = provider({
    interview: JSON.stringify({ goal: "g", questions: [] }), draft: DRAFT, review: '{"issues":[]}',
  });
  const result = await makeService(fetchImpl).polish({ rawText: REQUEST, strength: "promptbeta", llm: ROUTE });
  assert.deepEqual(calls.map((c) => c.stage), ["interview", "draft", "review"]);
  assert.equal(result.text, DRAFT);
  assert.equal(result.beta.patched, false);
});

test("跳过问题：不需要回答，起草时把没回答的不确定点放进「待确认」", async () => {
  const { calls, fetchImpl } = provider({ interview: INTERVIEW_WITH_QUESTIONS, draft: DRAFT, review: '{"issues":[]}' });
  const service = makeService(fetchImpl);
  const first = await service.polish({ rawText: REQUEST, strength: "promptbeta", llm: ROUTE });
  const done = await service.polish({ rawText: "", strength: "promptbeta", llm: ROUTE, betaSession: first.beta.sessionId, betaSkip: true });
  assert.equal(done.text, DRAFT);
  assert.match(calls[1].user, /用户跳过了这些问题/);
});

test("修补引入编造的数字时，退回审查前的草稿", async () => {
  const { fetchImpl } = provider({
    interview: '{"questions":[]}', draft: DRAFT,
    review: JSON.stringify({ issues: [{ type: "filler", quote: "", why: "x", fix: "y" }] }),
    patch: DRAFT + "\n篇幅控制在 300 字以内。",
  });
  const result = await makeService(fetchImpl).polish({ rawText: REQUEST, strength: "promptbeta", llm: ROUTE });
  assert.equal(result.text, DRAFT);
  assert.equal(result.fallback, false);
});

test("采访回复不是 JSON 时照常起草，不卡住", async () => {
  const { calls, fetchImpl } = provider({ interview: "我觉得需求很清楚", draft: DRAFT, review: "无" });
  const result = await makeService(fetchImpl).polish({ rawText: REQUEST, strength: "promptbeta", llm: ROUTE });
  assert.deepEqual(calls.map((c) => c.stage), ["interview", "draft", "review"]);
  assert.equal(result.text, DRAFT);
});

test("发给服务商之前，口述里的密钥被抹掉", async () => {
  const { calls, fetchImpl } = provider({ interview: '{"questions":[]}', draft: DRAFT, review: '{"issues":[]}' });
  await makeService(fetchImpl).polish({ rawText: REQUEST + "，密码是 fake-pass-123", strength: "promptbeta", llm: ROUTE });
  assert.ok(calls.every((c) => !c.user.includes("fake-pass-123")));
});

test("过期和数量上限：旧会话被清掉", () => {
  const service = makeService(async () => { throw new Error("unused"); });
  service.betaSessions.set("old", { request: "r", spec: null, questions: ["q"], created: Date.now() - BETA_LIMITS.sessionMs - 1 });
  for (let i = 0; i < BETA_LIMITS.sessions + 3; i += 1) service.betaSessions.set(`s${i}`, { request: "r", questions: ["q"], created: Date.now() });
  service.pruneBetaSessions();
  assert.ok(!service.betaSessions.has("old"));
  assert.equal(service.betaSessions.size, BETA_LIMITS.sessions);
  assert.equal(service.cancelBeta("s22"), true);
});

test("录音里没有内容（<sil>、只有语气词）时不调用模型、不出稿；回答没内容就当作跳过", async () => {
  const { calls, fetchImpl } = provider({ interview: INTERVIEW_WITH_QUESTIONS, draft: DRAFT, review: '{"issues":[]}' });
  const service = makeService(fetchImpl);
  for (const rawText of ["<sil>", "嗯。", "um, uh"]) {
    const result = await service.polish({ rawText, strength: "promptbeta", llm: ROUTE });
    assert.equal(result.text, "");
    assert.equal(result.fallbackReason ?? result.reason, "empty-transcript");
  }
  assert.equal(calls.length, 0);
  const first = await service.polish({ rawText: REQUEST, strength: "promptbeta", llm: ROUTE });
  const done = await service.polish({ rawText: "嗯", strength: "promptbeta", llm: ROUTE, betaSession: first.beta.sessionId });
  assert.equal(done.text, DRAFT);
  assert.match(calls[1].user, /用户跳过了这些问题/);
});

test("工具函数：问题最多 4 个，JSON 可从代码块里取出", () => {
  assert.equal(normaliseQuestions(["a", "b", "c", "d", "e"]).length, 4);
  assert.deepEqual(parseJsonReply('```json\n{"questions":["x"]}\n```'), { questions: ["x"] });
  assert.equal(parseJsonReply("not json"), null);
  assert.equal(hasContent("<sil>"), false);
  assert.equal(hasContent("嗯，啊。"), false);
  assert.equal(hasContent("好的"), true);
  assert.equal(hasContent("写个提示词"), true);
});
