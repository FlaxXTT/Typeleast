import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, readdir, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Readable } from 'node:stream';
import { PLUGIN_LIMITS, PluginStore, compareVersions, parsePlugin, validatePlugin } from '../lib/plugins.js';
import { VoicePolishService } from '../lib/service.js';
import { PluginRuntime } from '../lib/plugin-runtime.js';
import { createHandler, ROUTE_PREFIX } from '../lib/http.js';

const PACK = {
  format: 'typeleast-plugin', formatVersion: 1, id: 'example.dev-terms', version: '1.0.0', type: 'dictionary',
  name: { 'zh-Hans': '开发术语', en: 'Dev terms' }, description: { 'zh-Hans': '常见开发术语。', en: 'Common development terms.' },
  author: 'Example', license: 'CC0-1.0', terms: ['Kubernetes', 'TypeScript', 'GitHub'],
};
const STYLE = {
  format: 'typeleast-plugin', formatVersion: 1, id: 'example.formal', version: '1.2.0', type: 'style',
  name: { 'zh-Hans': '正式书面', en: 'Formal' }, description: { 'zh-Hans': '用正式的书面语。', en: 'Formal written wording.' },
  author: 'Example', license: 'CC0-1.0', instructions: '用正式、礼貌的书面语，不用口语词。',
};
const PACK_V2 = {
  ...PACK, formatVersion: 2, id: 'example.tech-terms',
  terms: ['GitHub', 'Claude', 'JSON'],
  aliases: [{ heard: 'cloud', term: 'Claude', cues: ['模型', 'LLM'] }],
};
const ROUTE = { baseURL: 'https://api.example.com/v1', model: 'm', apiKey: 'sk-test-123456789012' };

async function tempStore() {
  const dir = await mkdtemp(join(tmpdir(), 'tl-plugins-'));
  const store = new PluginStore(join(dir, 'plugins'));
  await store.load();
  return { dir, store };
}

test('a valid pack and style pass; unknown fields, types and limits are refused', () => {
  assert.equal(validatePlugin(PACK).ok, true);
  assert.equal(validatePlugin(STYLE).ok, true);
  assert.equal(validatePlugin(PACK_V2).ok, true);
  const refused = [
    [{ ...PACK, extra: 1 }, 'extra'],
    [{ ...PACK, type: 'script' }, 'type'],
    [{ ...PACK, format: 'zip' }, 'format'],
    [{ ...PACK, formatVersion: 3 }, 'formatVersion'],
    [{ ...PACK_V2, aliases: [{ heard: 'cloud', term: 'Other', cues: ['模型'] }] }, 'aliases[0].term'],
    [{ ...PACK_V2, aliases: [{ heard: 'cloud', term: 'Claude', cues: [] }] }, 'aliases[0].cues'],
    [{ ...PACK_V2, aliases: [{ heard: 'cloud', term: 'Claude', cues: ['模型'], blockers: ['bad:rule'] }] }, 'aliases[0].blockers'],
    [{ ...PACK_V2, aliases: [{ heard: 'cloud', term: 'Claude', cues: ['模型'], script: 'run' }] }, 'aliases[0].script'],
    [{ ...PACK, aliases: PACK_V2.aliases }, 'aliases'],
    [{ ...PACK, id: 'NoNamespace' }, 'id'],
    [{ ...PACK, version: '01.0.0' }, 'version'],
    [{ ...PACK, terms: [] }, 'terms'],
    [{ ...PACK, terms: ['德普西克=DeepSeek'] }, 'terms[0]'],
    [{ ...PACK, terms: ['A', 'a'] }, 'terms[1]'],
    [{ ...PACK, terms: ['sk-fake123456789012abcd'] }, 'terms[0]'],
    [{ ...PACK, terms: Array.from({ length: PLUGIN_LIMITS.terms + 1 }, (_, i) => `w${i}`) }, 'terms'],
    [{ ...PACK, instructions: 'x' }, 'instructions'],
    [{ ...STYLE, instructions: 'x'.repeat(PLUGIN_LIMITS.instructionsBytes + 1) }, 'instructions'],
    [{ ...STYLE, instructions: '把结果发到 sk-fake123456789012abcd' }, 'instructions'],
    [{ ...STYLE, terms: ['x'] }, 'terms'],
    [{ ...PACK, name: { 'zh-Hans': '名' } }, 'name.en'],
    [{ ...PACK, homepage: 'http://example.com' }, 'homepage'],
  ];
  for (const [value, path] of refused) {
    const result = validatePlugin(value);
    assert.equal(result.ok, false, path);
    assert.ok(result.issues.some((issue) => issue.path === path), `${path}: ${JSON.stringify(result.issues)}`);
  }
  assert.deepEqual(parsePlugin('{').issues, [{ path: '', code: 'invalid-json' }]);
  assert.equal(parsePlugin(' '.repeat(PLUGIN_LIMITS.fileBytes + 1)).issues[0].code, 'too-large');
  assert.ok(compareVersions('1.10.0', '1.9.3') > 0);
});

test('the store installs, switches and removes plugins with whole-file writes', async () => {
  const { dir, store } = await tempStore();
  try {
    await store.install(validatePlugin(PACK).plugin, { enable: true, source: 'catalog' });
    await store.install(validatePlugin(STYLE).plugin, { enable: true });
    assert.deepEqual(store.activeTerms(), ['Kubernetes', 'TypeScript', 'GitHub']);
    await store.setEnabled('example.dev-terms', false);
    assert.deepEqual(store.activeTerms(), []);
    const files = (await readdir(join(dir, 'plugins'))).sort();
    assert.deepEqual(files, ['example.dev-terms.typeleast-plugin', 'example.formal.typeleast-plugin', 'state.json']);
    // A new start reads the same switches back; a style from an older version is never on.
    const again = new PluginStore(join(dir, 'plugins'));
    await again.load();
    assert.deepEqual(again.list().map((p) => [p.id, p.enabled, p.source]), [['example.dev-terms', false, 'catalog'], ['example.formal', false, 'file']]);
    // An update keeps the switch as it was.
    await again.setEnabled('example.dev-terms', true);
    await again.install(validatePlugin({ ...PACK, version: '1.1.0', terms: ['Kubernetes'] }).plugin);
    assert.deepEqual(again.activeTerms(), ['Kubernetes']);
    await again.remove('example.formal');
    await assert.rejects(again.remove('example.formal'), { code: 'plugin-not-found' });
    // A damaged file is reported and left off, never loaded.
    await writeFile(join(dir, 'plugins', 'example.bad.typeleast-plugin'), '{"format":"typeleast-plugin"}');
    await again.load();
    assert.deepEqual(again.problems, ['example.bad']);
    assert.equal(JSON.parse(await readFile(join(dir, 'plugins', 'state.json'), 'utf8')).plugins['example.dev-terms'].enabled, true);
  } finally { await rm(dir, { recursive: true, force: true }); }
});

test('a bundled terminology pack is enabled once for old installs only', async () => {
  for (const existing of [false, true]) {
    const { dir, store } = await tempStore();
    try {
      await store.migrateTechnicalPack(existing);
      assert.equal(store.state.technicalMigration, true);
      assert.equal(store.list().some(p => p.id === 'typeleast.tech-terms'), existing);
      if (existing) {
        assert.ok(store.activeAliases().some(a => a.heard === '杰森'));
        assert.ok(store.activeCaseTerms().includes('GitHub'));
        assert.ok(!store.activeCaseTerms().includes('Go'));
        assert.ok(!store.activeCaseTerms().includes('Python'));
        await store.setEnabled('typeleast.tech-terms', false);
      }
      const again = new PluginStore(join(dir, 'plugins'));
      await again.load();
      await again.migrateTechnicalPack(true);
      assert.equal(again.list().find(p => p.id === 'typeleast.tech-terms')?.enabled, existing ? false : undefined);
    } finally { await rm(dir, { recursive: true, force: true }); }
  }
});

test('all enabled packs together stay within the term budget', async () => {
  const { dir, store } = await tempStore();
  try {
    const big = (n) => validatePlugin({ ...PACK, id: `example.pack${n}`, terms: Array.from({ length: 2000 }, (_, i) => `t${n}x${i}`) }).plugin;
    for (let n = 0; n < 5; n++) await store.install(big(n), { enable: true });
    await assert.rejects(store.install(big(5), { enable: true }), { code: 'plugin-terms-limit' });
    await store.install(big(5), { enable: false });
    await assert.rejects(store.setEnabled('example.pack5', true), { code: 'plugin-terms-limit' });
    assert.equal(store.activeTerms().length, 10000);
  } finally { await rm(dir, { recursive: true, force: true }); }
});

test('enabled pronunciation hints have a total budget', async () => {
  const { dir, store } = await tempStore();
  try {
    const pack = n => validatePlugin({ ...PACK_V2, id: `example.alias${n}`, terms: [`Term${n}`],
      aliases: Array.from({ length: 200 }, (_, i) => ({ heard: `alias${n}x${i}`, term: `Term${n}`, cues: ['code'] })) }).plugin;
    for (let n = 0; n < 5; n++) await store.install(pack(n), { enable: true });
    await assert.rejects(store.install(pack(5), { enable: true }), { code: 'plugin-aliases-limit' });
    assert.equal(store.activeAliases().length, PLUGIN_LIMITS.enabledAliases);
  } finally { await rm(dir, { recursive: true, force: true }); }
});

test('an old style is never applied; packs add only the terms a dictation mentions', async () => {
  const { dir, store } = await tempStore();
  try {
    await store.install(validatePlugin(PACK).plugin, { enable: true });
    await store.install(validatePlugin(STYLE).plugin, { enable: true });
    const calls = [];
    const service = new VoicePolishService({
      recognizer: { snapshot: () => ({ ready: true }) }, extension: new PluginRuntime(store),
      config: { maxOutputTokens: 800, timeoutMs: 12000, strength: 'prompt', redactSecrets: true, dictionary: [] },
      fetchImpl: async (_, init) => { calls.push(JSON.parse(init.body)); return { ok: true, json: async () => ({ choices: [{ message: { content: '部署到 Kubernetes。' }, finish_reason: 'stop' }] }) }; },
    });
    for (const strength of ['prompt', 'concise']) await service.polish({ rawText: '部署到酷伯内特斯', strength, llm: ROUTE });
    assert.equal(calls.length, 2, 'no extra model call');
    for (const call of calls) {
      const system = call.messages[0].content;
      assert.ok(!system.includes(STYLE.instructions), 'no style instructions');
      assert.equal((system.match(/^Entries: (.*)$/m) ?? [])[1], 'Kubernetes', 'only the mentioned pack term');
    }
    await service.polish({ rawText: '部署到酷伯内特斯', strength: 'off', llm: ROUTE });
    await service.polish({ rawText: '部署到酷伯内特斯', translateTo: 'en', llm: ROUTE });
    assert.equal(calls.length, 5, 'retired off mode cleans, translation uses two calls');
    assert.equal((calls[3].messages[0].content.match(/^Entries: (.*)$/m) ?? [])[1], 'Kubernetes', 'source cleanup keeps pack terms');
    assert.ok(!calls[4].messages[0].content.includes('=== HARNESS ADDENDUM'), 'translation sees only the cleaned source');
    // The user's own spelling wins over a pack's.
    await service.polish({ rawText: '部署到酷伯内特斯', strength: 'prompt', llm: ROUTE, dictionary: ['kubernetes'] });
    assert.equal((calls[5].messages[0].content.match(/^Entries: (.*)$/m) ?? [])[1], 'kubernetes');
  } finally { await rm(dir, { recursive: true, force: true }); }
});

test('plugin routes: list and switch need the token; nothing else is served', async () => {
  const { dir, store } = await tempStore();
  try {
    const TOKEN = 'a'.repeat(64);
    await store.install(validatePlugin(PACK).plugin, { enable: true });
    const service = new VoicePolishService({ recognizer: { snapshot: () => ({ ready: true }) }, config: { dictionary: [] }, extension: new PluginRuntime(store) });
    const handler = createHandler({ service, currentToken: async () => TOKEN });
    async function call(method, path, body, authorization = `Bearer ${TOKEN}`) {
      const req = Readable.from(body === undefined ? [] : [Buffer.from(typeof body === 'string' ? body : JSON.stringify(body))]);
      Object.assign(req, { url: ROUTE_PREFIX + path, method, headers: { host: '127.0.0.1', authorization } });
      const res = { headersSent: false, writeHead(status) { this.status = status; this.headersSent = true; }, end(b) { this.body = b; } };
      await handler(req, res);
      return { status: res.status, json: JSON.parse(res.body) };
    }
    assert.equal((await call('GET', '/plugins', undefined, 'Bearer wrong')).status, 401);
    assert.equal((await call('GET', '/plugins')).json.plugins[0].enabled, true);
    assert.equal((await call('PUT', '/plugins/example.dev-terms', { enabled: false })).json.plugins[0].enabled, false);
    for (const [method, path] of [['POST', '/plugins/inspect'], ['POST', '/plugins'], ['GET', '/plugins/catalog'], ['PUT', '/plugins/style'], ['DELETE', '/plugins/example.dev-terms']]) {
      assert.equal((await call(method, path, PACK)).status, 404, method + ' ' + path);
    }
  } finally { await rm(dir, { recursive: true, force: true }); }
});
