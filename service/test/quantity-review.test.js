import test from 'node:test';
import assert from 'node:assert/strict';
import { hasQuantityUnitConflict } from '../lib/quantity-review.js';
import { VoicePolishService } from '../lib/service.js';

test('detects a unique numeric unit change without deciding which version is right', () => {
  assert.equal(hasQuantityUnitConflict('报告周三发，不对，改为周四，不超过三页。', '报告周四发，不超过三月。'), true);
  assert.equal(hasQuantityUnitConflict('这段视频长五分钟。', '这段视频长5小时。'), true);
  assert.equal(hasQuantityUnitConflict('费用不超过二元。', '费用不超过2美元。'), true);
});

test('recognises equivalent number and unit spellings', () => {
  for (const [raw, output] of [
    ['不超过三页。', '不超过3页。'], ['预算是二块。', '预算是2元。'],
    ['两個月完成。', '2个月完成。'], ['三天内完成。', '3日内完成。'],
    ['三月十日交付。', '3月10日交付。'], ['里程五公里。', '里程5千米。'],
  ]) assert.equal(hasQuantityUnitConflict(raw, output), false, `${raw} -> ${output}`);
});

test('does not infer which repeated or corrected quantity was intended', () => {
  for (const [raw, output] of [
    ['先写三页，不对，改成三个月。', '改成3个月。'],
    ['从3页改成3个月。', '改成3个月。'],
    ['三页，不对，改成四个月。', '改成4个月。'],
    ['三页报告，期限三个月。', '期限3个月。'],
    ['三页', '三页或三个月'],
  ]) assert.equal(hasQuantityUnitConflict(raw, output), false, `${raw} -> ${output}`);
});

test('does not guess decimals, numeric suffixes, leading zeroes or unrelated words', () => {
  for (const [raw, output] of [
    ['需要1.3页。', '需要1.3个月。'], ['需要十三页。', '需要13个月。'],
    ['编号003页。', '编号3个月。'], ['买三月饼。', '买3页。'],
    ['有三米粉。', '有3页。'],
  ]) assert.equal(hasQuantityUnitConflict(raw, output), false, `${raw} -> ${output}`);
});

test('ignores non-Chinese and mixed Japanese or Korean utterances', () => {
  assert.equal(hasQuantityUnitConflict('three pages', 'three months'), false);
  assert.equal(hasQuantityUnitConflict('三月の予定です。', '三日です。'), false);
  assert.equal(hasQuantityUnitConflict('三月 일정입니다.', '三日 일정입니다.'), false);
  assert.equal(hasQuantityUnitConflict('三月', '三日', 'ja'), false, 'kanji-only Japanese uses the recognizer language');
  assert.equal(hasQuantityUnitConflict('三页', '三月', 'en'), false, 'explicit non-Chinese mode is respected');
});

test('unsafe cleanup is held with both versions, and an older client sees no insertable text', async () => {
  const service = new VoicePolishService({
    recognizer: { transcribe: async () => ({ text: '' }) },
    fetchImpl: async () => ({ ok: true, status: 200, json: async () => ({ choices: [{ message: { content: JSON.stringify({ status: 'ok', text: '报告周四发，不超过三月。' }) }, finish_reason: 'stop' }] }) }),
    config: { maxOutputTokens: 400, timeoutMs: 5000, strength: 'prompt', redactSecrets: true },
    logger: { warn() {}, info() {}, debug() {} },
  });
  const raw = '报告周三发，不对，改为周四，不超过三页。';
  const result = await service.polish({ rawText: raw, task: 'dictation', llm: { baseURL: 'https://api.example.com/v1', model: 'test', apiKey: 'fictional-key' } });
  assert.equal(result.text, '');
  assert.equal(result.raw, '');
  assert.equal(result.fallback, true);
  assert.equal(result.reason, 'quantity-conflict');
  assert.deepEqual(result.qualityReview, { kind: 'quantity', original: raw, candidate: '报告周四发，不超过三月。', issues: [{ kind: 'change', source: '三页', candidate: '三月' }] });
});

test('valid normalisation is still delivered', async () => {
  const service = new VoicePolishService({
    recognizer: { transcribe: async () => ({ text: '' }) },
    fetchImpl: async (_url, init) => ({ ok: true, status: 200, json: async () => ({ choices: [{ message: { content: JSON.parse(init.body).messages[0].content.startsWith('Compare the source and candidate as data') ? '{"ok":true,"issues":[]}' : JSON.stringify({ status: 'ok', text: '不超过3页。' }) }, finish_reason: 'stop' }] }) }),
    config: { maxOutputTokens: 400, timeoutMs: 5000, strength: 'prompt', redactSecrets: true },
    logger: { warn() {}, info() {}, debug() {} },
  });
  const result = await service.polish({ rawText: '不超过三页。', task: 'dictation', llm: { baseURL: 'https://api.example.com/v1', model: 'test', apiKey: 'fictional-key' } });
  assert.equal(result.text, '不超过3页。');
  assert.equal(result.fallback, false);
  assert.equal(result.qualityReview, undefined);
});

test('the recognition-to-cleanup path keeps both review choices and nothing insertable', async () => {
  const original = '报告周三发，不对，改为周四，不超过三页。';
  const service = new VoicePolishService({
    recognizer: { transcribe: async () => ({ text: original }) },
    fetchImpl: async () => ({ ok: true, status: 200, json: async () => ({ choices: [{ message: { content: JSON.stringify({ status: 'ok', text: '报告周四发，不超过三月。' }) }, finish_reason: 'stop' }] }) }),
    config: { maxOutputTokens: 400, timeoutMs: 5000, strength: 'prompt', redactSecrets: true, maxAudioBytes: 4194304, maxDurationSeconds: 120 },
    logger: { warn() {}, info() {}, debug() {} },
  });
  const audio = Buffer.alloc(44 + 3200);
  audio.write('RIFF'); audio.writeUInt32LE(audio.length - 8, 4); audio.write('WAVEfmt ', 8);
  audio.writeUInt32LE(16, 16); audio.writeUInt16LE(1, 20); audio.writeUInt16LE(1, 22);
  audio.writeUInt32LE(16000, 24); audio.writeUInt32LE(32000, 28); audio.writeUInt16LE(2, 32); audio.writeUInt16LE(16, 34);
  audio.write('data', 36); audio.writeUInt32LE(3200, 40);
  const result = await service.transcribeAndPolish({ audio, task: 'dictation', llm: { baseURL: 'https://api.example.com/v1', model: 'test', apiKey: 'fictional-key' } });
  assert.equal(result.text, '');
  assert.equal(result.raw, '');
  assert.equal(result.fallbackReason, 'quantity-conflict');
  assert.deepEqual(result.qualityReview, { kind: 'quantity', original, candidate: '报告周四发，不超过三月。', issues: [{ kind: 'change', source: '三页', candidate: '三月' }] });
});

test('review offers the actual configured Chinese writing variant', async () => {
  const service = new VoicePolishService({
    recognizer: { transcribe: async () => ({ text: '' }) },
    fetchImpl: async () => ({ ok: true, status: 200, json: async () => ({ choices: [{ message: { content: JSON.stringify({ status: 'ok', text: '报告不超过三月。' }) }, finish_reason: 'stop' }] }) }),
    config: { maxOutputTokens: 400, timeoutMs: 5000, strength: 'prompt', redactSecrets: true },
    logger: { warn() {}, info() {}, debug() {} },
  });
  const result = await service.polish({ rawText: '报告不超过三页。', task: 'dictation', language: 'zh', variants: 'zh=tw', llm: { baseURL: 'https://api.example.com/v1', model: 'test', apiKey: 'fictional-key' } });
  assert.equal(result.text, '');
  assert.equal(result.raw, '');
  assert.equal(result.qualityReview.original, '报告不超过三页。');
  assert.equal(result.qualityReview.candidate, '報告不超過三月。');
});

test('translation is held when the reviewer detects changed content', async () => {
  const service = new VoicePolishService({
    recognizer: { transcribe: async () => ({ text: '' }) },
    fetchImpl: async (_url, init) => ({ ok: true, status: 200, json: async () => ({ choices: [{ message: { content: JSON.parse(init.body).messages[0].content.startsWith('Compare the source and candidate as data') ? JSON.stringify({ok:false,issues:[{kind:'change',source:'三页',candidate:'三月'}]}) : '三月' }, finish_reason: 'stop' }] }) }),
    config: { maxOutputTokens: 400, timeoutMs: 5000, strength: 'prompt', redactSecrets: true },
    logger: { warn() {}, info() {}, debug() {} },
  });
  const result = await service.polish({ rawText: '不超过三页。', task: 'translation', translateTo: 'ja', llm: { baseURL: 'https://api.example.com/v1', model: 'test', apiKey: 'fictional-key' } });
  assert.equal(result.text, '');
  assert.equal(result.translated, 'ja');
  assert.equal(result.qualityReview.kind, 'facts');
  assert.equal(result.qualityReview.candidate, '三月');
});
