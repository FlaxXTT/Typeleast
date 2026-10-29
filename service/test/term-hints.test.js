import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { parsePlugin } from '../lib/plugins.js';
import { relevantAliases, safePackTerms } from '../lib/term-hints.js';
import { wordSuggestions } from '../lib/word-suggestions.js';
import { VoicePolishService } from '../lib/service.js';
import { PluginRuntime } from '../lib/plugin-runtime.js';

const bundled = parsePlugin(await readFile(new URL('../lib/bundled/typeleast.tech-terms.typeleast-plugin', import.meta.url), 'utf8'));
assert.equal(bundled.ok, true);
const pack = bundled.plugin;

test('common words need context in the same utterance and clause', () => {
  const pick = text => relevantAliases(pack.aliases, text).map(a => `${a.heard}=${a.term}`);
  assert.deepEqual(pick('把 prompt 发到 cloud 模型'), ['cloud=Claude']);
  assert.deepEqual(pick('把文件放到 cloud storage'), []);
  assert.deepEqual(pick('把 prompt 发到 cloud storage'), [], 'ordinary cloud meaning blocks the name despite a cue');
  assert.deepEqual(pick('use cloud storage for the model'), []);
  assert.deepEqual(pick('去 cloud 存储。再打开模型。'), []);
  assert.deepEqual(pick('please go ahead'), []);
  assert.deepEqual(pick('用 go 语言写代码'), ['go=Go']);
  assert.deepEqual(pick('metal will rust'), []);
  assert.deepEqual(pick('用 rust 编译源码'), ['rust=Rust']);
  assert.deepEqual(pick('users react to the news'), []);
  assert.deepEqual(pick('用 react 写前端组件'), ['react=React']);
  assert.deepEqual(pick('build a react component'), ['react=React']);
  assert.deepEqual(pick('用 cursor 编辑器'), ['cursor=Cursor']);
  assert.deepEqual(pick('用杰森格式传数据'), ['杰森=JSON']);
  assert.deepEqual(pick('杰森今天来开会'), []);
  assert.deepEqual(pick('派森脚本报错'), ['派森=Python']);
  assert.deepEqual(pick('派森今天来开会'), []);
  assert.deepEqual(relevantAliases(pack.aliases, 'cloud 模型', ['cloud=PrivateModel']), []);
  assert.ok(!safePackTerms(pack.terms).includes('Claude'));
});

test('a disabled pack gives no hints, and a bad suggestion cannot change dictation', async () => {
  const stub = enabled => new VoicePolishService({
    recognizer: { snapshot: () => ({ ready: true }) },
    extension: new PluginRuntime({plugins:new Map([[pack.id,pack]]),state:{plugins:{[pack.id]:{enabled}}},activeStyle:()=>null}),
    config: { dictionary: [], redactSecrets: true },
  });
  const off = await stub(false).buildContext({ dictionary: [] }, '把 prompt 发到 cloud 模型');
  const on = await stub(true).buildContext({ dictionary: [] }, '把 prompt 发到 cloud 模型');
  assert.deepEqual(off.aliases, []);
  assert.deepEqual(on.aliases, [{ heard: 'cloud', term: 'Claude' }]);
  assert.deepEqual((await stub(true).buildContext({ dictionary: [] }, '把 prompt 发到 cloud storage')).aliases, []);
  assert.deepEqual((await stub(true).buildContext({ dictionary: [], fieldContext: { before: '模型' } }, 'cloud storage')).aliases, [], 'cursor text does not trigger alias');
  const result = await stub(true).recordAndReturn({ strength: 'off', dictionary: [] }, { raw: 'github', text: 'github', fallback: false });
  assert.equal(result.text, 'github', 'ordinary references do not rewrite returned text');
  const owned = await stub(true).recordAndReturn({ strength: 'off', dictionary: ['github'] }, { raw: 'github', text: 'github', fallback: false });
  assert.equal(owned.text, 'github', 'a user spelling overrides the enabled pack');
  assert.deepEqual(await wordSuggestions('cloud storage', 'Claude storage'), [], 'do not suggest changing an ordinary word to a brand');
});

test('only a supported alias reaches the provider in the existing model call', async () => {
  const calls = [];
  const service = new VoicePolishService({
    recognizer: { snapshot: () => ({ ready: true }) },
    extension: new PluginRuntime({plugins:new Map([[pack.id,pack]]),state:{plugins:{[pack.id]:{enabled:true}}},activeStyle:()=>null}),
    config: { dictionary: [], redactSecrets: true, maxOutputTokens: 800, timeoutMs: 12000, strength: 'prompt' },
    fetchImpl: async (_, init) => {
      calls.push(JSON.parse(init.body).messages[0].content);
      return { ok: true, json: async () => ({ choices: [{ message: { content: '{"status":"ok","text":"收到。","reason":"简化。"}' }, finish_reason: 'stop' }] }) };
    },
  });
  const llm = { baseURL: 'https://api.example.com/v1', model: 'test', apiKey: 'sk-test-123456789012' };
  // A dictation may add a completeness review; compare each dictation's cleanup call.
  await service.polish({ rawText: '把 prompt 发到 cloud storage', llm });
  const second = calls.length;
  await service.polish({ rawText: '把 prompt 发到 cloud 模型', llm });
  assert.ok(!calls[0].includes('"cloud" may mean "Claude"'));
  assert.ok(calls[second].includes('"cloud" may mean "Claude"'));
  assert.ok(!calls[second].includes('"杰森" may mean "JSON"'));
  assert.ok(!calls[second].includes('storage'), 'blocker lists stay local');
});

test('optional terminology failures leave the dictation path usable', async () => {
  const broken = new VoicePolishService({
    recognizer: { snapshot: () => ({ ready: true }) },
    extension: new PluginRuntime({
      activeTerms: () => { throw new Error('bad plugin'); },
      activeCaseTerms: () => { throw new Error('bad plugin'); },
      activeStyle: () => null,
    }),
    config: { dictionary: [], redactSecrets: true, maxOutputTokens: 800, timeoutMs: 12000, strength: 'prompt' },
    fetchImpl: async () => ({ ok: true, json: async () => ({ choices: [{ message: { content: '{"status":"ok","text":"今天开会。","reason":"补标点。"}' }, finish_reason: 'stop' }] }) }),
  });
  const llm = { baseURL: 'https://api.example.com/v1', model: 'test', apiKey: 'sk-test-123456789012' };
  const result = await broken.polish({ rawText: '今天开会', strength: 'prompt', llm });
  assert.equal(result.text, '今天开会。');
  const raw = await broken.polish({ rawText: '今天开会', strength: 'off' });
  assert.equal(raw.text, '今天开会');
});

test('an extension that fails while choosing a style cannot stop cleanup', async () => {
  const service = new VoicePolishService({
    recognizer: { snapshot: () => ({ ready: true }) },
    extension: { style: () => { throw new Error('bad style'); }, context: () => { throw new Error('bad pack'); },
      normalizeText: () => { throw new Error('bad case terms'); } },
    config: { dictionary: [], redactSecrets: true, maxOutputTokens: 800, timeoutMs: 12000, strength: 'prompt' },
    fetchImpl: async () => ({ ok: true, json: async () => ({ choices: [{ message: { content: '{"status":"ok","text":"今天开会。","reason":"补标点。"}' }, finish_reason: 'stop' }] }) }),
  });
  const result = await service.polish({ rawText: '今天开会', llm: { baseURL: 'https://api.example.com/v1', model: 'test', apiKey: 'sk-test-123456789012' } });
  assert.deepEqual([result.fallback, result.text], [false, '今天开会。']);
});
