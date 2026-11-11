import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, writeFile, rename, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { once } from 'node:events';
import { MlxRecognizer } from '../lib/mlx-recognizer.js';
import { SpeechModels, MEETING_MODEL_ID } from '../lib/speech-models.js';
import { MLX_DEFAULT_MODEL_ID } from '../lib/mlx-models.js';
import { startService } from '../lib/server.js';

const enabled = process.platform === 'darwin';
async function fixture(run) {
  const dir = await mkdtemp(join(tmpdir(), 'typeleast-mlx-test-'));
  const worker = join(dir, 'worker');
  const code = `#!${process.execPath}\n` + String.raw`
let buffer = Buffer.alloc(0), length = null, language = null, count = 0;
process.stdout.write(JSON.stringify({ready:true})+'\n');
process.stdin.on('data', data => {
  buffer = Buffer.concat([buffer,data]);
  while (true) {
    if (length === null) { const i=buffer.indexOf(10); if(i<0) return; const header=JSON.parse(buffer.subarray(0,i)); length=header.bytes; language=header.language; buffer=buffer.subarray(i+1); }
    if(buffer.length<length) return;
    const input=buffer.subarray(0,length); buffer=buffer.subarray(length); length=null;
    if(input[0]===2) continue;
    if(input[0]===3) { process.stdout.write('not-json\n'); continue; }
    process.stdout.write(JSON.stringify({text:String(process.pid)+':'+(++count),detectedLanguage:language,segments:[]})+'\n');
  }
});`;
  await writeFile(worker, code, { mode: 0o700 });
  const recognizer = new MlxRecognizer({ modelId: MLX_DEFAULT_MODEL_ID, modelsDir: dir, binary: worker, status: async () => ({ ready: true }) });
  try { await run(recognizer, dir); } finally { await recognizer.release(); await rm(dir, { recursive: true, force: true }); }
}

test('MLX keeps one worker for successive requests and recovers after cancellation', { skip: !enabled }, async () => fixture(async recognizer => {
  assert.equal(await recognizer.prepare(), 'ready');
  const first = await recognizer.transcribe(Buffer.from([1]), 'zh');
  const second = await recognizer.transcribe(Buffer.from([1]));
  const [pid, count] = first.text.split(':');
  assert.equal(count, '1');
  assert.equal(first.language, 'zh', 'a supported explicit Chinese choice reaches the worker');
  assert.equal(first.detectedLanguage, 'zh');
  assert.equal(second.text, `${pid}:2`);
  const unsupported = await recognizer.transcribe(Buffer.from([1]), 'yue');
  assert.equal(unsupported.language, 'auto', 'unsupported saved hints fall back to automatic');
  const abort = new AbortController();
  const pending = recognizer.transcribe(Buffer.from([2]), 'auto', abort.signal);
  setTimeout(() => abort.abort(), 30);
  await assert.rejects(pending, { name: 'AbortError' });
  const third = await recognizer.transcribe(Buffer.from([1]));
  assert.notEqual(third.text.split(':')[0], pid);
  assert.equal(third.text.split(':')[1], '1');
}));

test('MLX rejects corrupted responses and restarts without exposing them', { skip: !enabled }, async () => fixture(async recognizer => {
  await assert.rejects(recognizer.transcribe(Buffer.from([3])), { code: 'model-failed' });
  assert.match((await recognizer.transcribe(Buffer.from([1]))).text, /:\d+$/);
}));

test('MLX missing model never starts a worker', { skip: !enabled }, async () => fixture(async recognizer => {
  recognizer.status = async () => ({ ready: false });
  assert.equal(await recognizer.prepare(), 'missing-model');
  await assert.rejects(recognizer.transcribe(Buffer.from([1])), { code: 'speech-not-ready' });
  assert.equal(recognizer.child, null);
}));

test('Mac catalog rejects ONNX, preserves old selection and still offers meeting download', { skip: !enabled }, async () => fixture(async (_recognizer, dir) => {
  const selectionPath = join(dir, 'selection.json');
  const original = '{"modelId":"qwen3-asr-0.6b"}';
  await writeFile(selectionPath, original);
  const manager = new SpeechModels({ modelsDir: dir, selectionPath, mlxOnly: true });
  assert.equal(await manager.prepare(), 'missing-model');
  assert.equal(manager.snapshot().notice, 'saved-model-unavailable');
  assert.equal(await readFile(selectionPath, 'utf8'), original);
  const catalog = await manager.catalog();
  assert.deepEqual(catalog.models.map(model => model.id).sort(), [MLX_DEFAULT_MODEL_ID, MEETING_MODEL_ID, 'mlx-qwen3-asr-1.7b-8bit', 'mlx-qwen3-asr-0.6b-bf16', 'mlx-qwen3-asr-1.7b-bf16'].sort());
  assert.deepEqual(catalog.templates, []);
  assert.throws(() => manager.start('qwen3-asr-0.6b', { download: false }), { code: 'invalid-model' });
  assert.throws(() => manager.start(MEETING_MODEL_ID, { download: false }), { code: 'invalid-model' });
  manager.start(MEETING_MODEL_ID, { activate: false, fetchImpl: async () => ({ ok: false, status: 503 }) });
  await manager.job;
  assert.equal(manager.operation.phase, 'error');
  assert.equal(manager.operation.error, 'download-failed');
}));

test('cancelling an MLX load preserves the previous selection', { skip: !enabled }, async () => fixture(async (_recognizer, dir) => {
  let started;
  const loading = new Promise(resolve => { started = resolve; });
  const manager = new SpeechModels({ modelsDir: dir, selectionPath: join(dir, 'selection.json'), mlxOnly: true,
    factory: () => ({ snapshot: () => ({ phase: 'ready', ready: true }), release: async () => {},
      prepare: signal => new Promise(resolve => { started(); signal.addEventListener('abort', () => resolve('error'), { once: true }); }) }) });
  manager.verify = async () => {};
  manager.start(MLX_DEFAULT_MODEL_ID, { download: false });
  await loading;
  assert.equal(manager.operation.phase, 'loading');
  manager.cancel(MLX_DEFAULT_MODEL_ID);
  await manager.job;
  assert.equal(manager.operation.phase, 'cancelled');
  assert.equal(manager.activeId, MLX_DEFAULT_MODEL_ID);
  await assert.rejects(readFile(join(dir, 'selection.json')), { code: 'ENOENT' });
}));

test('a saved default MLX model is verified before it is loaded', { skip: !enabled }, async () => fixture(async (_recognizer, dir) => {
  const selectionPath = join(dir, 'selection.json');
  await writeFile(selectionPath, JSON.stringify({ modelId: MLX_DEFAULT_MODEL_ID }));
  let loaded = false;
  const manager = new SpeechModels({ modelsDir: dir, selectionPath, mlxOnly: true,
    factory: () => ({ prepare: async () => { loaded = true; return 'ready'; } }) });
  manager.verify = async () => { throw Object.assign(new Error('bad checksum'), { code: 'checksum-mismatch' }); };
  assert.equal(await manager.prepare(), 'missing-model');
  assert.equal(loaded, false);
  assert.equal(manager.snapshot().notice, 'saved-model-unavailable');
}));

test('closing the service terminates an active MLX worker without waiting for its request', { skip: !enabled }, async () => fixture(async (recognizer, dir) => {
  const quiet = { info() {}, warn() {} };
  const handle = await startService({ stateDir: dir, modelsDir: dir, recognizer, logger: quiet });
  await recognizer.prepare();
  const child = recognizer.child;
  const exit = once(child, 'exit');
  const pending = recognizer.transcribe(Buffer.from([2]));
  await new Promise(resolve => setTimeout(resolve, 20));
  const failed = assert.rejects(pending, { code: 'model-failed' });
  await handle.close();
  await failed;
  const [, signal] = await exit;
  assert.equal(signal, 'SIGKILL');
  assert.equal(recognizer.child, null);
}));

test('shutdown during model verification never starts a new worker afterwards', { skip: !enabled }, async () => fixture(async (_recognizer, dir) => {
  const selectionPath = join(dir, 'selection.json');
  await writeFile(selectionPath, JSON.stringify({ modelId: MLX_DEFAULT_MODEL_ID }));
  let started, finish;
  const verifying = new Promise(resolve => { started = resolve; });
  const gate = new Promise(resolve => { finish = resolve; });
  let launches = 0;
  const manager = new SpeechModels({ modelsDir: dir, selectionPath, mlxOnly: true,
    factory: () => ({ prepare: async () => { launches++; return 'ready'; }, release: async () => {} }) });
  manager.verify = async () => { started(); await gate; };
  const prepare = manager.prepare();
  await verifying;
  await manager.release();
  finish();
  assert.equal(await prepare, 'missing-model');
  assert.equal(launches, 0);
}));

test('cancelling while selection is written preserves the old selection and removes the temporary file', { skip: !enabled }, async () => fixture(async (_recognizer, dir) => {
  const selectionPath = join(dir, 'selection.json');
  const old = '{"modelId":"old-model"}';
  await writeFile(selectionPath, old);
  let writing, resume;
  const started = new Promise(resolve => { writing = resolve; });
  const gate = new Promise(resolve => { resume = resolve; });
  const manager = new SpeechModels({ modelsDir: dir, selectionPath, mlxOnly: true,
    factory: () => ({ prepare: async () => 'ready', release: async () => {} }),
    writeSelectionFile: async (...args) => { await writeFile(...args); writing(); await gate; } });
  manager.verify = async () => {};
  manager.start(MLX_DEFAULT_MODEL_ID, { download: false });
  await started;
  manager.cancel(MLX_DEFAULT_MODEL_ID);
  resume(); await manager.job;
  assert.equal(manager.operation.phase, 'cancelled');
  assert.equal(await readFile(selectionPath, 'utf8'), old);
  await assert.rejects(readFile(selectionPath + '.tmp'), { code: 'ENOENT' });
}));

test('after the atomic selection commit starts cancellation is rejected explicitly', { skip: !enabled }, async () => fixture(async (_recognizer, dir) => {
  const selectionPath = join(dir, 'selection.json');
  let committing, resume;
  const started = new Promise(resolve => { committing = resolve; });
  const gate = new Promise(resolve => { resume = resolve; });
  const manager = new SpeechModels({ modelsDir: dir, selectionPath, mlxOnly: true,
    factory: () => ({ prepare: async () => 'ready', release: async () => {} }),
    commitSelectionFile: async (...args) => { committing(); await gate; await rename(...args); } });
  manager.verify = async () => {};
  manager.start(MLX_DEFAULT_MODEL_ID, { download: false });
  await started;
  assert.equal(manager.operation.phase, 'committing');
  assert.throws(() => manager.cancel(MLX_DEFAULT_MODEL_ID), { code: 'model-busy' });
  resume(); await manager.job;
  assert.equal(manager.operation.phase, 'complete');
  assert.equal(JSON.parse(await readFile(selectionPath, 'utf8')).modelId, MLX_DEFAULT_MODEL_ID);
}));
