import test from 'node:test';
import assert from 'node:assert/strict';
import { VoicePolishService } from '../lib/service.js';
import { BETA_BREAKDOWN_PROMPT, BETA_DRAFT_PROMPT, BETA_INTERVIEW_PROMPT, BETA_LIMITS,
  hasContent, normaliseQuestions, parseJsonReply, boundaryQuestions, BOUNDARY_QUESTIONS } from '../lib/prompts/prompt-beta.js';

const ROUTE = { baseURL: 'https://api.example.com/v1', model: 'm', apiKey: 'test-key' };
const REQUEST = '帮我把会议记录整理成纪要，发给团队看，要详细一点。只读我给的会议记录，不联网，按以往的纪要格式重复做';
const DRAFT = '## 目标\n把会议记录整理成详细纪要，供团队阅读。';
const interview = (questions = [], confirmed = ['整理会议纪要，供团队阅读']) => JSON.stringify({ goal: '整理纪要', confirmed, questions });
function provider(script = {}) {
  const calls = [];
  const fetchImpl = async (_url, init) => {
    const body = JSON.parse(init.body);
    const system = body.messages[0].content;
    const stage = system === BETA_INTERVIEW_PROMPT ? 'interview' : system === BETA_DRAFT_PROMPT ? 'draft'
      : 'other';
    calls.push({ stage, user: body.messages[1].content });
    const value = script[stage] ?? ({ interview: interview(), draft: DRAFT, review: '{"issues":[]}', patch: DRAFT }[stage]);
    const content = typeof value === 'function' ? await value(calls, init) : value;
    return { ok: true, status: 200, json: async () => ({ choices: [{ message: { content }, finish_reason: 'stop' }] }) };
  };
  return { calls, fetchImpl };
}
function serviceFor(p, history = []) {
  return new VoicePolishService({
    recognizer: { snapshot: () => ({ ready: true }) }, fetchImpl: p.fetchImpl,
    config: { maxOutputTokens: 800, timeoutMs: 12000, strength: 'prompt', redactSecrets: true, dictionary: [], maxAudioBytes: 4194304, maxDurationSeconds: 120 },
    logger: { warn() {}, info() {} },
  });
}
const send = (service, rawText = REQUEST, extra = {}) => service.polish({ rawText, strength: 'promptbeta', llm: ROUTE, ...extra });
const finish = (service, id) => send(service, '', { betaSession: id, betaSkip: true });

test('clear information waits for explicit generate and still accepts more context', async () => {
  const p = provider({ interview: calls => interview(calls.length === 1 ? [] : ['客户是哪个群体？']) });
  const history = [], s = serviceFor(p, history);
  const a = await send(s);
  assert.equal(a.text, ''); assert.equal(a.beta.ready, true); assert.equal(a.beta.questions.length,0);
  const b = await send(s, '还想发给客户', { betaSession: a.beta.sessionId });
  assert.equal(b.beta.sessionId, a.beta.sessionId); assert.equal(b.beta.ready, false); assert.equal(b.beta.round, 2);
  assert.deepEqual(p.calls.map(c => c.stage), ['interview', 'interview']);
});

test('multiple rounds retain all answers and recheck newly introduced ambiguity', async () => {
  const p = provider({ interview: calls => interview(calls.length < 4 ? ['请补充用途'] : []) });
  const history = [], s = serviceFor(p, history);
  const first = await send(s);
  for (const answer of ['团队内部阅读', '也给客户看', '客户是售后团队']) {
    const r = await send(s, answer, { betaSession: first.beta.sessionId });
    assert.equal(r.text, '');
  }
  const analysis = JSON.parse(p.calls[3].user);
  assert.deepEqual(analysis.turns.map(t => t.answer), ['团队内部阅读', '也给客户看', '客户是售后团队']);
  const done = await finish(s, first.beta.sessionId);
  assert.equal(done.text, DRAFT);
  assert.deepEqual(JSON.parse(p.calls[4].user).turns, analysis.turns);
  assert.equal(s.betaSessions.has(first.beta.sessionId), false);
  await assert.rejects(send(s, '继续', { betaSession: first.beta.sessionId }), { code: 'beta-expired' });
});

test('silence never generates a draft or silently ends clarification', async () => {
  const p = provider(), history = [], s = serviceFor(p, history);
  for (const raw of ['', '<sil>', '嗯。', 'um, uh']) {
    const r = await send(s, raw); assert.equal(r.text, ''); assert.equal(r.raw, ''); assert.equal(r.reason, 'empty-transcript');
  }
  assert.equal(p.calls.length, 0);
  const first = await send(s);
  for (const raw of ['', '<sil>', '嗯']) {
    const r = await send(s, raw, { betaSession: first.beta.sessionId });
    assert.equal(r.beta.notice, 'empty-transcript'); assert.equal(r.beta.sessionId, first.beta.sessionId);
  }
  assert.equal(p.calls.length, 1);
});

test('explicit generate can finish with unanswered questions without inventing answers', async () => {
  const p = provider({ interview: interview(['给谁看？']) }), s = serviceFor(p);
  const a = await send(s); const done = await finish(s, a.beta.sessionId);
  assert.equal(done.text, DRAFT);
  assert.match(JSON.parse(p.calls[1].user).instruction, /未确认内容列在待确认/);
});

test('malformed interview retains the conversation and does not generate', async () => {
  const p = provider({ interview: 'not JSON' }), history = [], s = serviceFor(p, history);
  const r = await send(s);
  assert.equal(r.beta.notice, 'output-format'); assert.equal(r.text, '');
  assert.equal(p.calls.length, 1);
});

test('failed follow-up does not commit an unaccepted answer; earlier accepted answers survive', async () => {
  const p = provider({ interview: calls => calls.length === 3 ? 'invalid' : interview() }), s = serviceFor(p);
  const a = await send(s);
  await send(s, '已接收的补充', { betaSession: a.beta.sessionId });
  const failed = await send(s, '本轮未接收', { betaSession: a.beta.sessionId });
  assert.equal(failed.beta.notice, 'output-format');
  assert.deepEqual(s.betaSessions.get(a.beta.sessionId).turns.map(t => t.answer), ['已接收的补充']);
});

test('session input has a hard bound and never silently truncates user information', async () => {
  const p = provider(), s = serviceFor(p), a = await send(s);
  const r = await send(s, '甲'.repeat(BETA_LIMITS.inputChars), { betaSession: a.beta.sessionId });
  assert.equal(r.beta.notice, 'beta-input-limit'); assert.equal(s.betaSessions.get(a.beta.sessionId).turns.length, 0);
  assert.equal(p.calls.length, 1);
  await assert.rejects(send(s, '甲'.repeat(BETA_LIMITS.inputChars + 1)), { code: 'invalid-prompt' });
});

test('concurrent answers to one session are rejected rather than mixed', async () => {
  let release;
  const p = provider({ interview: calls => calls.length === 1 ? interview() : new Promise(resolve => { release = () => resolve(interview()); }) });
  const s = serviceFor(p), a = await send(s);
  const running = send(s, '第一份补充', { betaSession: a.beta.sessionId });
  while (!release) await new Promise(resolve => setImmediate(resolve));
  await assert.rejects(send(s, '同时发来的第二份', { betaSession: a.beta.sessionId }), { code: 'model-busy' });
  release(); await running;
  assert.deepEqual(s.betaSessions.get(a.beta.sessionId).turns.map(t => t.answer), ['第一份补充']);
});

test('cancelled sessions cannot be resurrected by a late provider result', async () => {
  let release;
  const p = provider({ interview: calls => calls.length === 1 ? interview() : new Promise(resolve => { release = () => resolve(interview()); }) });
  const s = serviceFor(p), a = await send(s);
  const running = send(s, '本轮补充', { betaSession: a.beta.sessionId });
  while (!release) await new Promise(resolve => setImmediate(resolve));
  s.cancelBeta(a.beta.sessionId); release();
  await assert.rejects(running); assert.equal(s.betaSessions.size, 0);
});

test('distinct sessions keep their own source material', async () => {
  const p = provider(), s = serviceFor(p), a = await send(s, '整理会议记录'), b = await send(s, '整理产品说明');
  assert.notEqual(a.beta.sessionId, b.beta.sessionId);
  await send(s, '给团队看', { betaSession: a.beta.sessionId });
  assert.equal(s.betaSessions.get(b.beta.sessionId).turns.length, 0);
});

test('all rounds and generation redact secrets before calling the provider', async () => {
  const p = provider(), s = serviceFor(p), a = await send(s, REQUEST + '，密码是 fake-pass-one');
  await send(s, '密码是 fake-pass-two', { betaSession: a.beta.sessionId });
  await finish(s, a.beta.sessionId);
  assert.ok(p.calls.every(c => !/fake-pass-(one|two)/.test(c.user)));
});

test('expired sessions and idle capacity are bounded; active operations are not expired', () => {
  const s = serviceFor(provider());
  s.betaSessions.set('old', { created: Date.now() - BETA_LIMITS.sessionMs - 1 });
  s.betaSessions.set('active', { created: 0, busy: true });
  s.pruneBetaSessions(); assert.equal(s.betaSessions.has('old'), false); assert.ok(s.betaSessions.has('active'));
});

test('accepted rounds refresh the idle expiry and normalize questions', async () => {
  const p = provider({ interview: interview(['q', 'q', '', 'b', 'c', 'd', 'e']) }), s = serviceFor(p), a = await send(s);
  s.betaSessions.get(a.beta.sessionId).created = Date.now() - 1000;
  const r = await send(s, '补充内容', { betaSession: a.beta.sessionId });
  assert.equal(r.beta.questions.length, 3); assert.ok(Date.now() - s.betaSessions.get(a.beta.sessionId).created < 1000);
  assert.equal(hasContent('嗯'), false); assert.equal(parseJsonReply('invalid'), null);
  assert.deepEqual(normaliseQuestions(['x', 'x', '']), ['x']);
});

test('the WAV pipeline preserves clarification metadata and suppresses silent raw tokens', async () => {
  const p = provider(), history = [], s = serviceFor(p, history);
  const spoken = [REQUEST, '<sil>'];
  s.recognizer.transcribe = async () => ({ text: spoken.shift() });
  const audio = Buffer.alloc(44 + 3200 * 2);
  audio.write('RIFF'); audio.writeUInt32LE(audio.length - 8, 4); audio.write('WAVE', 8);
  audio.write('fmt ', 12); audio.writeUInt32LE(16, 16); audio.writeUInt16LE(1, 20); audio.writeUInt16LE(1, 22);
  audio.writeUInt32LE(16000, 24); audio.writeUInt32LE(32000, 28); audio.writeUInt16LE(2, 32); audio.writeUInt16LE(16, 34);
  audio.write('data', 36); audio.writeUInt32LE(audio.length - 44, 40);
  const first = await s.transcribeAndPolish({ audio, strength: 'promptbeta', llm: ROUTE });
  assert.ok(first.beta.sessionId); assert.equal(first.text, ''); assert.equal(first.beta.ready, true);assert.equal(first.beta.questions.length,0);
  const silent = await s.transcribeAndPolish({ audio, strength: 'promptbeta', llm: ROUTE, betaSession: first.beta.sessionId });
  assert.equal(silent.beta.notice, 'empty-transcript');
  // A new empty Beta request has no raw ASR token to fall through into a client paste.
  s.recognizer.transcribe = async () => ({ text: '<sil>' });
  const empty = await s.transcribeAndPolish({ audio, strength: 'promptbeta', llm: ROUTE });
  assert.equal(empty.raw, ''); assert.equal(empty.text, ''); assert.equal(p.calls.length, 1);
});



test('assistant asks only model-identified gaps, capped at three, then generates once', async () => {
 const p=provider({interview:interview(['用途？','交付？','期限？','已知限制？'])}), s=serviceFor(p);
 const first=await send(s); assert.equal(first.beta.questions.length,3);
 assert.equal(first.beta.questions[0],'用途？');
 const done=await finish(s,first.beta.sessionId); assert.equal(done.text,DRAFT);
 assert.deepEqual(p.calls.map(x=>x.stage),['interview','draft']);
});
test('failed generation retains the accepted conversation for a retry',async()=>{
 const p=provider({draft:''}),s=serviceFor(p),first=await send(s);
 const held=await finish(s,first.beta.sessionId); assert.equal(held.text,'');assert.ok(held.beta.sessionId);
 assert.ok(s.betaSessions.has(first.beta.sessionId));
});

test('the two boundary questions come first, once, unless the user already covered them', () => {
  assert.deepEqual(boundaryQuestions('帮我写一份产品介绍'), [BOUNDARY_QUESTIONS.scope.zh, BOUNDARY_QUESTIONS.nature.zh]);
  assert.deepEqual(boundaryQuestions('帮我写产品介绍，可以联网查资料，要有创意'), [BOUNDARY_QUESTIONS.reuse.zh], 'creative work asks about existing projects');
  assert.deepEqual(boundaryQuestions('帮我写产品介绍，可以联网查资料，按模板重复做'), [], 'routine work does not');
  assert.deepEqual(boundaryQuestions('帮我做个创新的工具，可以联网，先看看有没有开源项目'), [], 'already covered');
  assert.deepEqual(boundaryQuestions('Write a product page'), [BOUNDARY_QUESTIONS.scope.en, BOUNDARY_QUESTIONS.nature.en]);
  const turns = [{ questions: [BOUNDARY_QUESTIONS.scope.zh, BOUNDARY_QUESTIONS.nature.zh], answer: '不确定' }];
  assert.deepEqual(boundaryQuestions('帮我写一份产品介绍', turns), [], 'an unsure answer is not asked again');
});

test('a selected prompt is broken down into goals and details before any question', async () => {
  const calls = [];
  const service = new VoicePolishService({ recognizer: { snapshot: () => ({ ready: true }) }, config: { strength: 'prompt', dictionary: [], timeoutMs: 5000, maxOutputTokens: 800, redactSecrets: true },
    fetchImpl: async (_, init) => { const body = JSON.parse(init.body); calls.push(body.messages[0].content);
      return { ok: true, status: 200, json: async () => ({ choices: [{ message: { content: JSON.stringify({ goal: '写产品介绍', goals: ['介绍新功能', '吸引试用'], confirmed: ['面向开发者', '不超过 500 字'], questions: [] }) }, finish_reason: 'stop' }] }) }; } });
  const r = await service.polish({ rawText: '你是一名资深文案。请为我们的开发者工具写一篇产品介绍，介绍新功能并吸引试用，面向开发者，不超过 500 字。', strength: 'promptbeta', source: 'selection', llm: ROUTE });
  assert.match(calls[0], /现成的提示词/);
  assert.deepEqual(r.beta.goals, ['介绍新功能', '吸引试用']);
  assert.deepEqual(r.beta.confirmed, ['面向开发者', '不超过 500 字']);
  assert.equal(r.beta.questions[0], BOUNDARY_QUESTIONS.scope.zh, 'the boundaries are still asked first');
});

test('prompt mode guides with the elements of a good prompt and says why each question matters', () => {
  for (const prompt of [BETA_INTERVIEW_PROMPT, BETA_BREAKDOWN_PROMPT]) {
    for (const element of ['为什么做', '背景', '可用的资料', '什么格式', '验收标准', '可参照的例子', '为什么要补']) assert.ok(prompt.includes(element), element);
  }
  for (const section of ['目标与原因', '验收标准', '## 待确认']) assert.ok(BETA_DRAFT_PROMPT.includes(section), section);
  for (const q of Object.values(BOUNDARY_QUESTIONS)) {
    assert.match(q.zh, /（.+）$/u, 'each boundary question says why');
    assert.match(q.en, /\(.+\)$/u);
    assert.ok(q.zh.length <= 200 && q.en.length <= 200, 'within the question length limit');
  }
});
