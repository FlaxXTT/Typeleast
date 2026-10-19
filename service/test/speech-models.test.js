import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, writeFile, rm, mkdir } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { SpeechModels } from '../lib/speech-models.js';
import { MODEL_CATALOG, DEFAULT_MODEL_ID, filesForModel, recognizerConfig } from '../lib/models.js';

async function fixture(run, options = {}) {
  const dir = await mkdtemp(join(tmpdir(), 'typeleast-model-selection-'));
  const events = [];
  const manager = new SpeechModels({ modelsDir: dir, selectionPath: join(dir, 'selection.json'), factory: id => ({
    prepare: async () => { events.push('load:'+id); return options.fail === id ? 'error' : 'ready'; },
    snapshot: () => ({ phase:'ready', ready:true }),
    transcribe: async () => { events.push('decode:'+id); await options.decode?.(); return { text:id }; },
  }) });
  manager.verify = async id => { events.push('verify:'+id); };
  try { await run(manager, dir, events); } finally { await rm(dir, {recursive:true, force:true}); }
}

test('model catalog has only approved fixed candidates and unique checked files', () => {
  assert.deepEqual(MODEL_CATALOG.map(m=>m.id), ['sensevoice-small','fireredasr2-ctc','fun-asr-nano','qwen3-asr-0.6b']);
  for(const m of MODEL_CATALOG) {
    const config=recognizerConfig('/models',m.id);
    assert.equal(config.modelConfig.provider,'cpu');
    for(const f of filesForModel(m.id)) {
      assert.match(f.sha256,/^[0-9a-f]{64}$/);
      assert(f.size>0);
      assert(!f.path.some(p=>p==='..'));
      if(m.id!==DEFAULT_MODEL_ID && f.id!=='silero-vad') assert.match(f.revision,/^[0-9a-f]{40}$/);
    }
  }
  assert.throws(()=>recognizerConfig('/models','unknown'),{code:'invalid-model'});
});

test('default remains SenseVoice and a successful switch survives restart', async()=>fixture(async(m,dir)=>{
  await m.prepare();
  assert.equal(m.activeId,DEFAULT_MODEL_ID);
  m.start('fireredasr2-ctc',{download:false});
  await m.job;
  assert.equal(m.operation.phase,'complete');
  assert.equal(m.activeId,'fireredasr2-ctc');
  assert.equal(JSON.parse(await readFile(join(dir,'selection.json'),'utf8')).modelId,'fireredasr2-ctc');
  m.activeId=DEFAULT_MODEL_ID;
  await m.prepare();
  assert.equal(m.activeId,'fireredasr2-ctc');
}));

test('failed model load retains the running model and persisted selection', async()=>fixture(async(m,dir)=>{
  await writeFile(join(dir,'selection.json'),JSON.stringify({modelId:DEFAULT_MODEL_ID}));
  m.start('fun-asr-nano',{download:false}); await m.job;
  assert.equal(m.operation.phase,'error');
  assert.equal(m.operation.error,'model-load-failed');
  assert.equal(m.activeId,DEFAULT_MODEL_ID);
  assert.equal(JSON.parse(await readFile(join(dir,'selection.json'),'utf8')).modelId,DEFAULT_MODEL_ID);
},{fail:'fun-asr-nano'}));

test('switch is queued after recognition and new recognition uses the new model', async()=>{
  let release; const gate=new Promise(r=>{release=r;});
  await fixture(async(m,_dir,events)=>{
    const decoding=m.transcribe(Buffer.alloc(0),'auto');
    const switching=m.activate('qwen3-asr-0.6b');
    await new Promise(r=>setImmediate(r));
    assert(!events.includes('load:qwen3-asr-0.6b'));
    release(); await decoding; await switching;
    assert.equal((await m.transcribe(Buffer.alloc(0),'auto')).text,'qwen3-asr-0.6b');
  },{decode:()=>gate});
});

test('duplicate actions do not start a second load and other models report busy', async()=>fixture(async m=>{
  let release; m.beforeActivate=()=>new Promise(r=>{release=r;});
  m.start('fireredasr2-ctc',{download:false}); const job=m.job;
  m.start('fireredasr2-ctc',{download:false}); assert.equal(m.job,job);
  assert.throws(()=>m.start('fun-asr-nano',{download:false}),{code:'model-busy'});
  m.cancel('fireredasr2-ctc');
  release(); await job;
  assert.equal(m.operation.phase,'cancelled'); assert.equal(m.activeId,DEFAULT_MODEL_ID);
}));

test('invalid saved selection falls back with a visible notice', async()=>fixture(async(m,dir)=>{
  await writeFile(join(dir,'selection.json'),'{"modelId":"unexpected"}');
  await m.prepare(); assert.equal(m.activeId,DEFAULT_MODEL_ID);
  assert.equal(m.snapshot().notice,'saved-model-unavailable');
}));

test('persistence failure does not replace the running recognizer', async()=>fixture(async(m,dir)=>{
  await mkdir(join(dir,'selection.json'));
  m.start('qwen3-asr-0.6b',{download:false}); await m.job;
  assert.equal(m.operation.phase,'error'); assert.equal(m.activeId,DEFAULT_MODEL_ID);
}));

test('the current model stays usable during download, cancellation permits a new attempt', async()=>fixture(async m=>{
  let started;
  const fetching = new Promise(resolve=>{started=resolve;});
  m.start('fun-asr-nano',{fetchImpl:async(_url,{signal})=>{
    started();
    return new Promise((_resolve,reject)=>signal.addEventListener('abort',()=>reject(signal.reason),{once:true}));
  }});
  await fetching;
  assert.equal(m.snapshot().ready,true);
  assert.equal((await m.transcribe(Buffer.alloc(0),'auto')).text,DEFAULT_MODEL_ID);
  m.cancel('fun-asr-nano'); await m.job;
  assert.equal(m.operation.phase,'cancelled');
  m.start('fun-asr-nano',{download:false}); await m.job;
  assert.equal(m.operation.phase,'complete');
  assert.equal(m.activeId,'fun-asr-nano');
}));

test('an unavailable saved candidate falls back without loading it', async()=>fixture(async(m,dir,events)=>{
  await writeFile(join(dir,'selection.json'),'{"modelId":"fun-asr-nano"}');
  m.verify=async()=>{throw Object.assign(new Error('missing'),{code:'model-not-installed'});};
  await m.prepare();
  assert.deepEqual(events,['load:sensevoice-small']);
  assert.equal(m.snapshot().notice,'saved-model-unavailable');
  assert.equal(m.activeId,DEFAULT_MODEL_ID);
}));
