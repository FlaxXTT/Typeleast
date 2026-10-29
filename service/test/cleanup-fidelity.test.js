import test from 'node:test';
import assert from 'node:assert/strict';
import { VoicePolishService } from '../lib/service.js';

const route = { baseURL: 'https://api.example.com/v1', model: 'fixture', apiKey: 'sk-test-123456789012' };
function fixture(replies) {
  const calls = [];
  const service = new VoicePolishService({ recognizer: { snapshot: () => ({ ready: true }) },
    config: { maxOutputTokens: 800, timeoutMs: 12000, strength: 'prompt', redactSecrets: true, dictionary: [] },
    logger: { info() {}, warn() {}, debug() {} },
    fetchImpl: async (_, request) => {
      calls.push(JSON.parse(request.body));
      const text = replies.shift();
      return { ok: true, json: async () => ({ choices: [{ message: { content: JSON.stringify({ status: 'ok', text, reason: 'fictional test' }) }, finish_reason: 'stop' }] }) };
    },
  });
  return { service, calls };
}

test('the model writes numbers; nothing rewrites them afterwards', async () => {
  const { service, calls } = fixture(['至少三四个人，再给五六天，预算不超过三万元。']);
  const result = await service.polish({ rawText: '至少三四个人，再给五六天，预算不超过三万元。', strength: 'prompt', llm: route });
  assert.equal(result.fallback, false, result.reason);
  assert.equal(result.text, '至少三四个人，再给五六天，预算不超过三万元。');
  assert.equal(calls.length, 1);
});

test('explicit name correction and mixed languages preserve the user request', async () => {
  const { service, calls } = fixture(['请用 ROG 电脑测试 API，不要执行 delete 命令。']);
  const result = await service.polish({ rawText: '请用 LG，不对，ROG 电脑测试 API，不要执行 delete 命令。', strength: 'prompt', llm: route });
  assert.equal(result.fallback, false, result.reason);
  assert.equal(result.text, '请用 ROG 电脑测试 API，不要执行 delete 命令。');
  assert.match(calls[0].messages[0].content, /问题和指令按原意写出/);
  assert.match(calls[0].messages[0].content, /从开头到结尾/);
});

test('translation receives the formatted source in its second call', async () => {
  const { service, calls } = fixture(['需要三四个人。', 'We need 3 to 4 people.']);
  const result = await service.polish({ rawText: '需要三四个人。', strength: 'prompt', translateTo: 'en', llm: route });
  assert.equal(result.fallback, false, result.reason);
  assert.equal(calls.length, 2);
  assert.equal(calls[1].messages[1].content, '需要三四个人。');
});
