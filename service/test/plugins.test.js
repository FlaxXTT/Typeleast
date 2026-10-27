import {Readable} from 'node:stream';
import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp,writeFile,readFile,rm,stat} from 'node:fs/promises';
import {join} from 'node:path';
import {tmpdir} from 'node:os';
import {createServer} from 'node:http';
import {PluginStore,parsePlugin,pluginDigest,fetchCatalog,CATALOG_FORMAT,CATALOG_URLS,CATALOG_MIRRORS,catalogSources,PLUGIN_LIMITS,compareVersions} from '../lib/plugins.js';
import {PluginRuntime} from '../lib/plugin-runtime.js';
import {createHandler} from '../lib/http.js';
const STYLE={format:'typeleast-plugin',formatVersion:1,id:'example.formal',version:'1.0.0',type:'style',name:{'zh-Hans':'正式表达',en:'Formal'},description:{'zh-Hans':'简洁表达。',en:'Clear wording.'},author:'Example',license:'CC0-1.0',instructions:'Use clear sentences.'};
const PACK={...STYLE,id:'example.legacy',type:'dictionary',terms:['Legacy'],instructions:undefined};
async function directory(work){const dir=await mkdtemp(join(tmpdir(),'typeleast-plugin-retirement-'));try{await work(dir);}finally{await rm(dir,{recursive:true,force:true});}}
test('styles remain valid; vocabulary packs, unknown fields and executable payloads are refused',()=>{
 assert.equal(parsePlugin(JSON.stringify(STYLE)).ok,true);
 for(const p of [PACK,{...PACK,formatVersion:2,aliases:[]},{...STYLE,script:'run()'},{...STYLE,permissions:['filesystem']},{...STYLE,instructions:'x'.repeat(PLUGIN_LIMITS.instructionsBytes+1)},{...STYLE,formatVersion:9},{...STYLE,instructions:'sk-test-123456789012345678901234567890'}])assert.equal(parsePlugin(JSON.stringify(p)).ok,false);
 assert.equal(parsePlugin('{broken').ok,false);
});
test('plugin versions and confirmed-content digest remain stable',()=>{
 assert.ok(compareVersions('1.10.0','1.9.0')>0);assert.equal(pluginDigest(STYLE),pluginDigest({...STYLE}));assert.notEqual(pluginDigest(STYLE),pluginDigest({...STYLE,instructions:'Changed.'}));
});
test('installed style survives restart and can be removed',()=>directory(async dir=>{
 const store=new PluginStore(dir);await store.load();await store.migrateTechnicalPack(true);await store.install(STYLE,{enable:true});assert.equal(store.activeStyle().id,STYLE.id);
 const next=new PluginStore(dir);await next.load();await next.migrateTechnicalPack(true);assert.equal(next.activeStyle().id,STYLE.id);await next.remove(STYLE.id);assert.equal(next.activeStyle(),null);
}));
test('retirement deletes only managed vocabulary and cache, keeps styles and cannot resurrect packs',()=>directory(async dir=>{
 await writeFile(join(dir,PACK.id+'.typeleast-plugin'),JSON.stringify(PACK));await writeFile(join(dir,STYLE.id+'.typeleast-plugin'),JSON.stringify(STYLE));
 await writeFile(join(dir,'state.json'),JSON.stringify({plugins:{[PACK.id]:{enabled:true},[STYLE.id]:{source:'file'}},style:STYLE.id}));await writeFile(join(dir,'catalog-cache.json'),'old catalog');
 const store=new PluginStore(dir);await store.load();await store.migrateTechnicalPack(true);assert.equal(store.activeStyle().id,STYLE.id);await assert.rejects(stat(join(dir,PACK.id+'.typeleast-plugin')));await assert.rejects(stat(join(dir,'catalog-cache.json')));
 const again=new PluginStore(dir);await again.load();await again.migrateTechnicalPack(true);assert.deepEqual(again.list().map(x=>x.id),[STYLE.id]);
 await assert.rejects(again.install(PACK));
}));
test('malformed installed file is retained without disabling a valid style',()=>directory(async dir=>{
 await writeFile(join(dir,'unknown.broken.typeleast-plugin'),'{broken');const store=new PluginStore(dir);await store.load();await store.migrateTechnicalPack();assert.equal(store.state.vocabularyRemoved,false);await store.install(STYLE,{enable:true});assert.equal(store.activeStyle().id,STYLE.id);assert.equal(await readFile(join(dir,'unknown.broken.typeleast-plugin'),'utf8'),'{broken');
}));
test('catalog uses approved addresses, no user payload, and rejects redirects',async()=>{
 const calls=[];const catalog=await fetchCatalog({version:'test',fetchImpl:async(url,init)=>{calls.push({url,init});return {ok:true,status:200,text:async()=>JSON.stringify({format:CATALOG_FORMAT,formatVersion:1,plugins:[STYLE,PACK]})};}});
 assert.equal(calls[0].url,CATALOG_URLS[0]);assert.equal(calls[0].init.redirect,'error');assert.equal(calls[0].init.body,undefined);assert.equal(catalog.plugins.length,1);
});
test('runtime supplies only optional style data',()=>directory(async dir=>{
 const store=new PluginStore(dir);await store.load();await store.install(STYLE,{enable:true});const runtime=new PluginRuntime(store);assert.equal(runtime.referenceData().style.sourceId,STYLE.id);assert.equal(runtime.referenceData().terms,undefined);
}));
test('plugin routes retain bearer authentication and refuse vocabulary inspection',()=>directory(async dir=>{
 const store=new PluginStore(dir);await store.load();const service={extension:new PluginRuntime(store)};
 const server=createServer(createHandler({service,currentToken:async()=> 'fixture-token',logger:{warn(){}}}));await new Promise(r=>server.listen(0,'127.0.0.1',r));
 const url='http://127.0.0.1:'+server.address().port+'/api/voice-polish/plugins';
 try{assert.equal((await fetch(url)).status,401);const headers={authorization:'Bearer fixture-token','content-type':'application/json'};assert.equal((await fetch(url+'/inspect',{method:'POST',headers,body:JSON.stringify(PACK)})).status,400);const inspect=await fetch(url+'/inspect',{method:'POST',headers,body:JSON.stringify(STYLE)});assert.equal(inspect.status,200);}finally{server.closeAllConnections();await new Promise(r=>server.close(r));}
}));

function catalogResponse(body, { status = 200 } = {}) {
  const text = typeof body === 'string' ? body : JSON.stringify(body);
  return { ok: status === 200, status, headers: new Headers({ 'content-length': String(Buffer.byteLength(text)) }), body: Readable.toWeb(Readable.from([Buffer.from(text)])) };
}

test('the catalog is read from the official addresses first, once, without redirects', async () => {
  const seen = [];
  const catalog = { format: 'typeleast-catalog', formatVersion: 1, generatedAt: '2026-10-24T00:00:00Z', plugins: [PACK, STYLE, { ...PACK, id: 'bad id' }] };
  const result = await fetchCatalog({ fetchImpl: async (url, init) => { seen.push([url, init.redirect, Object.keys(init.headers).sort().join(',')]); return catalogResponse(catalog); } });
  assert.deepEqual(seen, [[CATALOG_URLS[0], 'error', 'accept,user-agent']]);
  assert.deepEqual(result.plugins.map((p) => p.id), ['example.formal']);
  assert.equal(result.rejected, 2);
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


test('style schema rejects traversal, insecure links, controls, unknown locales and oversized files',()=>{
 for(const p of [{...STYLE,id:'../escape'},{...STYLE,version:'01.0.0'},{...STYLE,homepage:'http://example.com'},{...STYLE,name:{en:'Name'}},{...STYLE,instructions:'bad\u0000value'},{...STYLE,name:{...STYLE.name,fr:'Name'}}])assert.equal(parsePlugin(JSON.stringify(p)).ok,false);
 assert.equal(parsePlugin(' '.repeat(PLUGIN_LIMITS.fileBytes+1)).ok,false);
});
