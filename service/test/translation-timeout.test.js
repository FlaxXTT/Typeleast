import test from 'node:test';
import assert from 'node:assert/strict';
import { setImmediate } from 'node:timers/promises';
import { VoicePolishService } from '../lib/service.js';

const primary = { baseURL: 'https://primary.example/v1', model: 'fixture', apiKey: 'fixture-key' };
const backup = { ...primary, baseURL: 'https://backup.example/v1' };
const reply = text => ({ ok: true, status: 200, json: async () => ({
  choices: [{ message: { content: text }, finish_reason: 'stop' }],
}) });

function slowService(t, { delay = 45000, config = {} } = {}) {
  t.mock.timers.enable({ apis: ['setTimeout', 'Date'], now: 0 });
  const calls = [];
  const service = new VoicePolishService({
    recognizer: { snapshot: () => ({ ready: true, phase: 'ready' }) },
    config,
    fetchImpl: async (url, init) => {
      const body = JSON.parse(init.body);
      calls.push({ url, signal: init.signal });
      if (body.messages[0].content.startsWith('Compare the source')) return reply('{"ok":true,"issues":[]}');
      return new Promise((resolve, reject) => {
        const abort = () => { clearTimeout(timer); reject(init.signal.reason); };
        const timer = setTimeout(() => {
          init.signal.removeEventListener('abort', abort);
          resolve(reply('译文。'));
        }, typeof delay === 'function' ? delay(url) : delay);
        init.signal.addEventListener('abort', abort, { once: true });
        if (init.signal.aborted) abort();
      });
    },
  });
  const controller = new AbortController();
  const start = request => {
    const result = service.polish({ rawText: 'Hello world.', llm: primary, translateTo: 'zh',
      signal: controller.signal, ...request });
    t.after(async () => { controller.abort(); await result; });
    return result;
  };
  const advance = async ms => { t.mock.timers.tick(ms); await setImmediate(); };
  return { service, calls, controller, start, advance };
}

for (const [name, options] of [
  ['a single provider', {}],
  ['deferred backup credentials', { hasConfiguredBackups: true }],
  ['an available backup', { llmBackups: [backup] }],
]) {
  test(`a 45-second translation completes on the primary with ${name}`, async t => {
    const { calls, start, advance } = slowService(t);
    const result = start(options);
    await advance(15000);
    assert.equal(calls.length, 1, 'a slow translation must not switch provider after ten seconds');
    await advance(15001);
    assert.equal(calls.length, 1, 'a slow translation must not restart after thirty seconds');
    await advance(14999);
    const response = await result;
    assert.equal(response.fallback, false);
    assert.equal(response.text, '译文。');
    assert.equal(response.switchedProvider, undefined);
    assert.equal(calls.length, 1);
  });
}

test('an explicit shorter timeout still limits translation and offers deferred failover', async t => {
  const { start, advance } = slowService(t, { config: { timeoutMs: 5000 } });
  const result = start({ hasConfiguredBackups: true });
  await advance(5000);
  const response = await result;
  assert.equal(response.reason, 'model-timeout');
  assert.equal(response.offerFailover, true);
  assert.equal(response.raw, 'Hello world.');
});

test('a translation that exceeds ninety seconds can still switch to a working backup', async t => {
  const { start, advance, calls } = slowService(t, {
    delay: url => url.startsWith(primary.baseURL) ? 120000 : 45000,
  });
  const result = start({ llmBackups: [backup] });
  await advance(90000);
  assert.equal(calls.length, 2);
  assert.equal(calls[0].signal.aborted, true);
  assert.equal(calls[1].url, backup.baseURL + '/chat/completions');
  await advance(45000);
  const response = await result;
  assert.equal(response.fallback, false);
  assert.equal(response.switchedProvider, true);
  assert.equal(response.text, '译文。');
});

test('all translation batches share the five-minute deadline', async t => {
  const { start, advance, calls } = slowService(t, { delay: 160000 });
  const result = start({ rawText: Array(9).fill('a'.repeat(2000)).join('\n') });
  await advance(160000);
  assert.equal(calls.length, 2, 'the next batch starts only after the first one completes');
  await advance(140000);
  const response = await result;
  assert.equal(response.reason, 'model-timeout');
  assert.equal(calls[1].signal.aborted, true);
  assert.equal(response.ms.total, 300000);
});

test('cancelling translation stops the provider without trying a backup', async t => {
  const { start, advance, calls, controller } = slowService(t);
  const result = start({ llmBackups: [backup] });
  await advance(15000);
  controller.abort();
  const response = await result;
  assert.equal(response.reason, 'cancelled');
  assert.equal(calls.length, 1);
  assert.equal(calls[0].signal.aborted, true);
});

test('ordinary dictation keeps its fast deferred failover', async t => {
  const { start, advance } = slowService(t);
  const result = start({ translateTo: null, hasConfiguredBackups: true });
  await advance(12000);
  const response = await result;
  assert.equal(response.reason, 'model-timeout');
  assert.equal(response.offerFailover, true);
});
