import test from 'node:test';
import assert from 'node:assert/strict';
import { relevantEntries } from '../lib/dictionary-relevance.js';

const DICTIONARY = ['DeepSeek', '德普西克=DeepSeek', '章伟', 'Kubernetes', 'TypeLeast', 'JSON', '内部代号凤凰', 'Claude', 'GitHub', '李雷'];

test('entries the dictation mentions, spelled or misheard, are kept', async () => {
  const cases = [
    ['我在用迪普西克写代码', ['DeepSeek', '德普西克=DeepSeek']],
    ['我在用德普西克写代码', ['DeepSeek', '德普西克=DeepSeek']],
    ['请把报告发给张伟', ['章伟']],
    ['部署到酷伯内特斯上', ['Kubernetes']],
    ['typeleast 很好用', ['TypeLeast']],
    ['用杰森传输数据', ['JSON']],
    ['问一下克劳德', ['Claude']],
    ['代码放在吉特哈布上', ['GitHub']],
    ['内部代号凤凰下周上线', ['内部代号凤凰']],
  ];
  for (const [text, expected] of cases) assert.deepEqual(await relevantEntries(DICTIONARY, [text]), expected, text);
});

test('entries unrelated to the dictation are left out', async () => {
  for (const text of ['今天天气不错，我们去吃饭吧', '明天下午三点开会', 'send the report on wednesday']) {
    assert.deepEqual(await relevantEntries(DICTIONARY, [text]), [], text);
  }
  assert.deepEqual(await relevantEntries(DICTIONARY, []), []);
  assert.deepEqual(await relevantEntries(DICTIONARY, [null, '']), []);
  assert.deepEqual(await relevantEntries([], ['章伟']), []);
});

test('the field the user allowed it to read counts as context', async () => {
  assert.deepEqual(await relevantEntries(DICTIONARY, ['回复他', 'Kubernetes 集群升级完成了吗？']), ['Kubernetes']);
});

test('a full dictionary is filtered quickly', async () => {
  const big = Array.from({ length: 2000 }, (_, i) => (i % 2 ? `Term${i}Alpha` : `内部名称${i}`));
  const started = Date.now();
  const kept = await relevantEntries(big, ['这是一段比较长的口述内容，提到了内部名称8。'.repeat(20)]);
  assert.ok(Date.now() - started < 1500, `${Date.now() - started} ms`);
  assert.ok(kept.includes('内部名称8'));
  assert.ok(kept.length < 20, String(kept.length));
});
