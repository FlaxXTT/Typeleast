import test from 'node:test';
import assert from 'node:assert/strict';
import { Readable } from 'node:stream';
import { correction, learnedWord, similarity, MIN_SIMILARITY, MAX_EDIT_CHARS } from '../lib/edit-correction.js';
import { pinyinConverter } from '../lib/word-suggestions.js';
import { createHandler, ROUTE_PREFIX } from '../lib/http.js';

test('correction finds the one replaced span and grows it to a word', () => {
  assert.deepEqual(correction('我在用得普西克写代码', '我在用DeepSeek写代码'),
    { from: '得普西克', to: 'DeepSeek', coreFrom: '得普西克', coreTo: 'DeepSeek' });
  assert.equal(correction('use kubernetis now', 'use kubernetes now')?.to, 'kubernetes');
  assert.equal(correction('这家公式很好', '这家公司很好')?.to, '司', 'a one-character Chinese fix stays one character');
  assert.equal(correction('Hello DeepSeak.', 'Hello DeepSeek.')?.to, 'DeepSeek');
  assert.equal(correction('try node.js now', 'try Node.js now')?.to, 'Node.js');
  assert.equal(correction('开会', '开个会'), null, 'a pure insertion is not a correction');
  assert.equal(correction('结果分析的数据图不要给我矢量图', '结果分析的数据图给我矢量图'), null, 'a pure deletion is not a correction');
  assert.equal(correction('好', '好'), null);
  assert.equal(correction('一二三四五六七八九十一二三四五六七', '甲乙丙丁戊己庚辛壬癸甲乙丙丁戊己庚'), null, 'longer than one word');
});

test('a fix is learned only when it sounds like what was recognised', async () => {
  assert.equal(await learnedWord('我在用得普西克写代码', '我在用DeepSeek写代码'), 'DeepSeek');
  assert.equal(await learnedWord('请尽快练习我', '请尽快联系我'), '联系', 'a Chinese homophone fix');
  assert.equal(await learnedWord('我在看因特耳的财报', '我在看英特尔的财报'), '英特尔');
  assert.equal(await learnedWord('我们下周把报告发出去', '我们明天把报告发出去'), null, 'a content edit');
  assert.equal(await learnedWord('明天开会', '后天开会'), null);
  // One changed character: its word is unknown, so neither 「给章」 nor 「看英」 is learned.
  assert.equal(await learnedWord('请把数据图发给张伟', '请把数据图发给章伟'), null);
  assert.equal(await learnedWord('我在看因特尔的财报', '我在看英特尔的财报'), null);
  assert.equal(await learnedWord('打开迪普西克设置', '打开深度求索设置'), null, 'a different Chinese name, not a sound-alike');
  assert.equal(await learnedWord('我们下周把报告发出去', '请在周五之前提交季度预算'), null, 'a rewritten sentence');
  assert.equal(await learnedWord('use kubernetis now', 'use kubernetes now'), 'kubernetes');
  assert.equal(await learnedWord('Hello DeepSeak.', 'Hello DeepSeek.'), 'DeepSeek');
  assert.equal(await learnedWord('meet on Monday please', 'meet on Friday please'), null, 'a different English word');
  const convert = await pinyinConverter();
  assert.ok(similarity('第四批', 'DSH', convert) >= MIN_SIMILARITY, 'acronym initials count as sound-alike');
});

test('nothing private or oversized becomes a dictionary word', async () => {
  // Explicitly fake credentials, never read from user settings.
  assert.equal(await learnedWord('key abc123', 'key xyz789'), null);
  assert.equal(await learnedWord('token sk-fake123456789012', 'token sk-fake123456789013'), null);
  assert.equal(await learnedWord('a'.repeat(MAX_EDIT_CHARS + 1), 'b'), null);
  assert.equal(await learnedWord('第一行\n第二行', '第一行\n第二\n行'), null);
  for (const [inserted, edited] of [[null, 'x'], ['x', undefined], [1, 2], [{}, []]]) assert.equal(await learnedWord(inserted, edited), null);
});

test('/learned-word answers with the word or null and needs the token', async () => {
  const TOKEN = 'a'.repeat(64);
  const handler = createHandler({ service: {}, currentToken: async () => TOKEN });
  async function post(body, authorization = `Bearer ${TOKEN}`) {
    const req = Readable.from([Buffer.from(body)]);
    Object.assign(req, { url: ROUTE_PREFIX + '/learned-word', method: 'POST', headers: { host: '127.0.0.1', authorization } });
    const res = { headersSent: false, writeHead(status) { this.status = status; this.headersSent = true; }, end(b) { this.body = b; } };
    await handler(req, res);
    return { status: res.status, json: JSON.parse(res.body) };
  }
  assert.deepEqual(await post(JSON.stringify({ inserted: '请尽快练习我', edited: '请尽快联系我' })), { status: 200, json: { word: '联系' } });
  assert.deepEqual(await post(JSON.stringify({ inserted: '明天开会', edited: '后天开会' })), { status: 200, json: { word: null } });
  assert.deepEqual(await post('null'), { status: 200, json: { word: null } });
  assert.equal((await post('{"inserted":"x"')).json.code, 'invalid-json');
  assert.equal((await post('{}', 'Bearer wrong')).status, 401);
});
