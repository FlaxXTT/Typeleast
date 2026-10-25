import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, readdir, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Readable } from 'node:stream';
import { CATALOG_MIRRORS, CATALOG_URLS, PLUGIN_LIMITS, PluginStore, catalogSources, compareVersions, fetchCatalog, parsePlugin, pluginDigest, validatePlugin } from '../lib/plugins.js';
import { STYLE_MARKER, systemPromptFor } from '../lib/prompt.js';
import { VoicePolishService } from '../lib/service.js';
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
    await store.install(validatePlugin(STYLE).plugin, { enable: false });
    assert.deepEqual(store.activeTerms(), ['Kubernetes', 'TypeScript', 'GitHub']);
    assert.equal(store.activeStyle(), null);
    await store.selectStyle('example.formal');
    assert.equal(store.activeStyle().id, 'example.formal');
    await store.setEnabled('example.dev-terms', false);
    assert.deepEqual(store.activeTerms(), []);
    const files = (await readdir(join(dir, 'plugins'))).sort();
    assert.deepEqual(files, ['example.dev-terms.typeleast-plugin', 'example.formal.typeleast-plugin', 'state.json']);
    // A new start reads the same switches back.
    const again = new PluginStore(join(dir, 'plugins'));
    await again.load();
    assert.deepEqual(again.list().map((p) => [p.id, p.enabled, p.source]), [['example.dev-terms', false, 'catalog'], ['example.formal', true, 'file']]);
    // An update keeps the switch as it was.
    await again.setEnabled('example.dev-terms', true);
    await again.install(validatePlugin({ ...PACK, version: '1.1.0', terms: ['Kubernetes'] }).plugin);
    assert.deepEqual(again.activeTerms(), ['Kubernetes']);
    await again.remove('example.formal');
    assert.equal(again.activeStyle(), null);
    await assert.rejects(again.remove('example.formal'), { code: 'plugin-not-found' });
    await assert.rejects(again.selectStyle('example.dev-terms'), { code: 'plugin-not-found' });
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

test('a selected style rides in the one model call; packs add only the terms a dictation mentions', async () => {
  const { dir, store } = await tempStore();
  try {
    await store.install(validatePlugin(PACK).plugin, { enable: true });
    await store.install(validatePlugin(STYLE).plugin, { enable: true });
    const calls = [];
    const service = new VoicePolishService({
      recognizer: { snapshot: () => ({ ready: true }) }, plugins: store,
      config: { maxOutputTokens: 800, timeoutMs: 12000, strength: 'prompt', redactSecrets: true, dictionary: [] },
      fetchImpl: async (_, init) => { calls.push(JSON.parse(init.body)); return { ok: true, json: async () => ({ choices: [{ message: { content: '部署到 Kubernetes。' }, finish_reason: 'stop' }] }) }; },
    });
    for (const strength of ['prompt', 'concise']) await service.polish({ rawText: '部署到酷伯内特斯', strength, llm: ROUTE });
    assert.equal(calls.length, 2, 'no extra model call');
    for (const call of calls) {
      const system = call.messages[0].content;
      assert.ok(system.includes(STYLE_MARKER) && system.includes(STYLE.instructions));
      assert.ok(system.indexOf(STYLE_MARKER) < system.indexOf('=== HARNESS ADDENDUM'), 'style before the addendum');
      assert.equal((system.match(/^Entries: (.*)$/m) ?? [])[1], 'Kubernetes', 'only the mentioned pack term');
    }
    await service.polish({ rawText: '部署到酷伯内特斯', strength: 'off', llm: ROUTE });
    await service.polish({ rawText: '部署到酷伯内特斯', translateTo: 'en', llm: ROUTE });
    assert.equal(calls.length, 5, 'retired off mode cleans, translation uses two calls');
    assert.ok(!calls[3].messages[0].content.includes(STYLE_MARKER), 'translation source cleanup takes no selected style');
    assert.equal((calls[3].messages[0].content.match(/^Entries: (.*)$/m) ?? [])[1], 'Kubernetes', 'source cleanup keeps pack terms');
    assert.ok(!calls[4].messages[0].content.includes('=== HARNESS ADDENDUM'), 'translation sees only the cleaned source');
    // The user's own spelling wins over a pack's.
    await service.polish({ rawText: '部署到酷伯内特斯', strength: 'prompt', llm: ROUTE, dictionary: ['kubernetes'] });
    assert.equal((calls[5].messages[0].content.match(/^Entries: (.*)$/m) ?? [])[1], 'kubernetes');
    assert.equal(systemPromptFor({ strength: 'prompt' }), systemPromptFor({ strength: 'prompt', style: '  ' }), 'no style, no block');
  } finally { await rm(dir, { recursive: true, force: true }); }
});

function catalogResponse(body, { status = 200 } = {}) {
  const text = typeof body === 'string' ? body : JSON.stringify(body);
  return { ok: status === 200, status, headers: new Headers({ 'content-length': String(Buffer.byteLength(text)) }), body: Readable.toWeb(Readable.from([Buffer.from(text)])) };
}

test('the catalog is read from the official addresses first, once, without redirects', async () => {
  const seen = [];
  const catalog = { format: 'typeleast-catalog', formatVersion: 1, generatedAt: '2026-10-24T00:00:00Z', plugins: [PACK, STYLE, { ...PACK, id: 'bad id' }] };
  const result = await fetchCatalog({ fetchImpl: async (url, init) => { seen.push([url, init.redirect, Object.keys(init.headers).sort().join(',')]); return catalogResponse(catalog); } });
  assert.deepEqual(seen, [[CATALOG_URLS[0], 'error', 'accept,user-agent']]);
  assert.deepEqual(result.plugins.map((p) => p.id), ['example.dev-terms', 'example.formal']);
  assert.equal(result.rejected, 1);
  // The site down: the official GitHub copy is next; no mirror is contacted.
  const tried = [];
  const official = await fetchCatalog({ fetchImpl: async (url) => { tried.push(url); if (tried.length === 1) throw new Error('down'); return catalogResponse(catalog); } });
  assert.deepEqual(tried, CATALOG_URLS);
  assert.equal(official.mirrored, false);
  await assert.rejects(fetchCatalog({ fetchImpl: async () => catalogResponse('x', { status: 503 }) }), { code: 'market-offline' });
  await assert.rejects(fetchCatalog({ fetchImpl: async () => catalogResponse({ format: 'other' }) }), { code: 'market-protocol-unsupported' });
  await assert.rejects(fetchCatalog({ fetchImpl: async () => catalogResponse('x'.repeat(PLUGIN_LIMITS.catalogBytes + 1)) }), { code: 'market-too-large' });
});

test('both official addresses blocked: the mirrors are tried in order and the result says so', async () => {
  const catalog = { format: 'typeleast-catalog', formatVersion: 1, plugins: [PACK] };
  const tried = [];
  const result = await fetchCatalog({ fetchImpl: async (url) => { tried.push(url); if (CATALOG_URLS.includes(url)) throw new Error('blocked'); return catalogResponse(catalog); } });
  assert.deepEqual(tried, [...CATALOG_URLS, CATALOG_MIRRORS[0]]);
  assert.equal(result.mirrored, true);
  assert.equal(result.source, 'fastly.jsdelivr.net');
  assert.ok(CATALOG_MIRRORS.some((url) => url.startsWith('https://ghfast.top/https://raw.githubusercontent.com/')), 'the updater\'s GitHub proxies are mirrors too');
  // 只用 GitHub: never a mirror. 优先镜像: mirrors first.
  assert.deepEqual(catalogSources('github').map((s) => s.url), CATALOG_URLS);
  assert.equal(catalogSources('mirror')[0].url, CATALOG_MIRRORS[0]);
  const githubOnly = [];
  await assert.rejects(fetchCatalog({ mode: 'github', fetchImpl: async (url) => { githubOnly.push(url); throw new Error('blocked'); } }), { code: 'market-offline' });
  assert.deepEqual(githubOnly, CATALOG_URLS);
});

test('an address that hangs does not hold up the next one, and the rest are cancelled', async () => {
  const catalog = { format: 'typeleast-catalog', formatVersion: 1, plugins: [PACK] };
  const aborted = [];
  const hang = (url, signal) => new Promise((_, reject) => signal.addEventListener('abort', () => { aborted.push(url); reject(new Error('aborted')); }));
  const result = await fetchCatalog({ staggerMs: 20, fetchImpl: async (url, init) => url === CATALOG_MIRRORS[0] ? catalogResponse(catalog) : hang(url, init.signal) });
  assert.equal(result.source, 'fastly.jsdelivr.net');
  assert.deepEqual(aborted.sort(), [...CATALOG_URLS].sort(), 'the silent official addresses are cancelled once a mirror answers');
  await assert.rejects(fetchCatalog({ timeoutMs: 60, staggerMs: 10, fetchImpl: async (url, init) => hang(url, init.signal) }), { code: 'market-offline' });
});

test('the market route follows the app\'s source setting and reports a mirrored catalog', async () => {
  const { dir, store } = await tempStore();
  try {
    const TOKEN = 'b'.repeat(64);
    const urls = [];
    const service = new VoicePolishService({
      recognizer: { snapshot: () => ({ ready: true }) }, plugins: store, config: { dictionary: [] },
      fetchImpl: async (url) => { urls.push(url); return catalogResponse({ format: 'typeleast-catalog', formatVersion: 1, plugins: [STYLE] }); },
    });
    const handler = createHandler({ service, currentToken: async () => TOKEN });
    const call = async (path) => {
      const req = Readable.from([]);
      Object.assign(req, { url: ROUTE_PREFIX + path, method: 'GET', headers: { host: '127.0.0.1', authorization: `Bearer ${TOKEN}` } });
      const res = { headersSent: false, writeHead(status) { this.status = status; this.headersSent = true; }, end(b) { this.body = b; } };
      await handler(req, res);
      return { status: res.status, json: JSON.parse(res.body) };
    };
    const mirrored = await call('/plugins/catalog?sources=mirror');
    assert.equal(mirrored.json.mirrored, true);
    assert.equal(urls[0], CATALOG_MIRRORS[0]);
    const official = await call('/plugins/catalog?sources=nonsense');
    assert.equal(official.json.mirrored, false, 'an unknown setting reads as auto');
    assert.equal(urls[1], CATALOG_URLS[0]);
  } finally { await rm(dir, { recursive: true, force: true }); }
});

test('plugin routes: inspect, install, switch, market and remove need the token', async () => {
  const { dir, store } = await tempStore();
  try {
    const TOKEN = 'a'.repeat(64);
    let fetches = 0;
    let published = [STYLE];
    const service = new VoicePolishService({
      recognizer: { snapshot: () => ({ ready: true }) }, plugins: store, config: { dictionary: [] },
      fetchImpl: async () => { fetches++; return catalogResponse({ format: 'typeleast-catalog', formatVersion: 1, plugins: published }); },
    });
    const handler = createHandler({ service, currentToken: async () => TOKEN });
    async function call(method, path, body, authorization = `Bearer ${TOKEN}`) {
      const req = Readable.from(body === undefined ? [] : [Buffer.from(typeof body === 'string' ? body : JSON.stringify(body))]);
      Object.assign(req, { url: ROUTE_PREFIX + path, method, headers: { host: '127.0.0.1', authorization } });
      const res = { headersSent: false, writeHead(status) { this.status = status; this.headersSent = true; }, end(b) { this.body = b; } };
      await handler(req, res);
      return { status: res.status, json: JSON.parse(res.body) };
    }
    assert.equal((await call('GET', '/plugins', undefined, 'Bearer wrong')).status, 401);
    const inspected = await call('POST', '/plugins/inspect', PACK);
    assert.equal(inspected.json.plugin.termCount, 3);
    assert.equal(inspected.json.installedVersion, null);
    assert.equal(store.list().length, 0, 'inspecting installs nothing');
    assert.equal((await call('POST', '/plugins/inspect', { ...PACK, type: 'script' })).json.code, 'plugin-invalid');
    assert.equal((await call('POST', '/plugins?enable=1', PACK)).status, 409, 'no install without the fingerprint of what was shown');
    assert.equal((await call('POST', `/plugins?enable=1&digest=${inspected.json.plugin.digest}`, { ...PACK, terms: ['Other'] })).json.code, 'plugin-changed');
    assert.equal(store.list().length, 0);
    assert.equal((await call('POST', `/plugins?enable=1&digest=${inspected.json.plugin.digest}`, PACK)).json.plugins[0].enabled, true);
    assert.equal((await call('PUT', '/plugins/example.dev-terms', { enabled: false })).json.plugins[0].enabled, false);
    assert.equal(fetches, 0, 'nothing reaches the network before the market opens');
    const market = await call('GET', '/plugins/catalog');
    assert.equal(fetches, 1);
    assert.deepEqual(market.json.plugins.map((p) => [p.id, p.installedVersion]), [['example.formal', null]]);
    const shown = market.json.plugins[0];
    assert.equal(shown.digest, pluginDigest(validatePlugin(STYLE).plugin));
    // The catalog changes after the confirmation was opened: the old confirmation installs nothing.
    published = [{ ...STYLE, version: '2.0.0', instructions: '完全不同的说明。' }];
    assert.equal((await call('GET', '/plugins/catalog')).json.plugins[0].version, '2.0.0');
    const stale = await call('POST', '/plugins/catalog/install', { id: 'example.formal', enable: true, digest: shown.digest });
    assert.deepEqual([stale.status, stale.json.code], [409, 'plugin-changed']);
    assert.ok(!store.list().some((p) => p.id === 'example.formal'), 'nothing installed from a stale confirmation');
    assert.equal((await call('POST', '/plugins/catalog/install', { id: 'example.formal', enable: true })).status, 409, 'a fingerprint is required');
    published = [STYLE];
    const current = (await call('GET', '/plugins/catalog')).json.plugins[0];
    const installed = await call('POST', '/plugins/catalog/install', { id: 'example.formal', enable: true, digest: current.digest });
    assert.equal(installed.json.style, 'example.formal');
    assert.equal(installed.json.plugins.find((p) => p.id === 'example.formal').source, 'catalog');
    assert.equal(installed.json.plugins.find((p) => p.id === 'example.formal').version, '1.2.0');
    assert.equal((await call('POST', '/plugins/catalog/install', { id: 'example.missing' })).status, 404);
    assert.equal((await call('PUT', '/plugins/style', { id: null })).json.style, null);
    assert.equal((await call('DELETE', '/plugins/example.dev-terms')).json.plugins.length, 1);
    assert.equal((await call('DELETE', '/plugins/example.dev-terms')).status, 404);
    assert.equal(fetches, 3, 'one catalog read per opening or refresh, nothing else');
  } finally { await rm(dir, { recursive: true, force: true }); }
});
