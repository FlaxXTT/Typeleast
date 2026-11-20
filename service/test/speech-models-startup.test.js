import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdir, mkdtemp, readFile, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { SpeechModels } from '../lib/speech-models.js';
import { MLX_DEFAULT_MODEL_ID, MLX_MODELS } from '../lib/mlx-models.js';
import { filesForModel } from '../lib/models.js';
import { startService } from '../lib/server.js';

const deferred = () => {
  let resolve;
  const promise = new Promise(done => { resolve = done; });
  return { promise, resolve };
};

async function fixture(t, selected, localASREnabled = true) {
  const dir = await mkdtemp(join(tmpdir(), 'typeleast-startup-'));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const selectionPath = join(dir, 'speech-model.json');
  await writeFile(selectionPath, JSON.stringify({ modelId: selected }));
  const verifyEntered = deferred(), verifyDone = deferred(), loadEntered = deferred(), loadDone = deferred();
  let loads = 0, releases = 0;
  const models = new SpeechModels({ modelsDir: dir, selectionPath, mlxOnly: true, localASREnabled,
    factory: id => {
      let ready = false;
      return {
        snapshot: () => ({ phase: ready ? 'ready' : 'missing-model', ready }),
        prepare: async signal => {
          loads++;
          loadEntered.resolve();
          await loadDone.promise;
          signal.throwIfAborted();
          ready = true;
          return 'ready';
        },
        release: async () => { releases++; ready = false; },
        transcribe: async () => ({ text: id }),
      };
    },
  });
  // The public catalog intentionally hides Mac-only models on Linux. Exercise
  // the Mac lifecycle here with its real data catalog and a fake native worker.
  models.definition = id => {
    const model = MLX_MODELS.find(model => model.id === id);
    if (!model) throw Object.assign(new Error('fixture unknown model'), { code: 'invalid-model' });
    return model;
  };
  models.verify = async () => { verifyEntered.resolve(); await verifyDone.promise; };
  return { dir, models, verifyEntered, verifyDone, loadEntered, loadDone,
    loads: () => loads, releases: () => releases };
}

for (const selected of [MLX_DEFAULT_MODEL_ID, 'mlx-qwen3-asr-0.6b-bf16']) {
  test(`cold startup reports loading throughout verification and worker startup: ${selected}`, async t => {
    const { models, verifyEntered, verifyDone, loadEntered, loadDone } = await fixture(t, selected);
    const preparing = models.prepare();
    assert.equal(models.snapshot().phase, 'loading', 'health must follow startup from the first check');
    assert.equal(models.snapshot().ready, false);
    await verifyEntered.promise;
    assert.equal(models.snapshot().phase, 'loading', 'hashing model weights is still startup');
    assert.equal(models.snapshot().modelId, selected);
    verifyDone.resolve();
    await loadEntered.promise;
    assert.equal(models.snapshot().phase, 'loading', 'loading the saved worker must not expose the unused default');
    assert.equal(models.snapshot().modelId, selected);
    loadDone.resolve();
    await preparing;
    assert.equal(models.snapshot().phase, 'ready');
    assert.equal(models.snapshot().ready, true);
    assert.equal(models.snapshot().modelId, selected);
  });
}

test('repeated startup checks share one preparation without blocking a queued recognition', async t => {
  const { models, verifyEntered, verifyDone, loadEntered, loadDone } = await fixture(t, MLX_DEFAULT_MODEL_ID);
  const first = models.prepare();
  await verifyEntered.promise;
  const second = models.prepare();
  assert.equal(first, second);
  const recognition = models.transcribe(Buffer.alloc(0), 'auto');
  verifyDone.resolve();
  await loadEntered.promise;
  loadDone.resolve();
  await first;
  assert.equal((await recognition).text, MLX_DEFAULT_MODEL_ID);
});

test('a failed verification ends loading and retains the saved selection on disk', async t => {
  const { models } = await fixture(t, MLX_DEFAULT_MODEL_ID);
  models.verify = async () => { throw Object.assign(new Error('fixture missing weights'), { code: 'model-not-installed' }); };
  await models.prepare();
  assert.equal(models.snapshot().phase, 'missing-model');
  assert.equal(models.snapshot().notice, 'saved-model-unavailable');
  assert.deepEqual(JSON.parse(await readFile(models.selectionPath, 'utf8')), { modelId: MLX_DEFAULT_MODEL_ID });
});

test('cloud ASR permits deleting saved local weights while keeping the text service and model preference', async t => {
  const selected = 'mlx-qwen3-asr-0.6b-bf16';
  const f = await fixture(t, selected, false);
  const weights = join(f.dir, ...filesForModel(selected).find(file => file.path.at(-1).endsWith('.safetensors')).path);
  const unrelated = join(dirname(weights), 'notes.txt');
  await mkdir(dirname(weights), { recursive: true });
  await writeFile(weights, 'test weights');
  await writeFile(unrelated, 'keep this file');
  const handle = await startService({ stateDir: f.dir, recognizer: f.models, logger: {} });
  t.after(() => handle.close());
  const token = (await readFile(join(f.dir, 'api-token'), 'utf8')).trim();
  const request = (path, method = 'GET', body) => fetch(
    `http://127.0.0.1:${handle.port}/api/voice-polish${path}`,
    { method, headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' }, body: JSON.stringify(body) });
  const item = async () => (await (await request('/models')).json()).storage.find(model => model.id === selected);
  const remove = () => request('/models/storage/delete', 'POST', { modelId: selected, partialOnly: false });
  await f.models.serial;
  const pausedHealth = await (await request('/health')).json();
  assert.equal(pausedHealth.ok, true);
  assert.equal(pausedHealth.speech.phase, 'disabled');
  assert.equal(pausedHealth.speech.modelId, selected);
  assert.equal(f.loads(), 0);
  assert.equal((await item()).active, false);
  await assert.rejects(f.models.transcribe(Buffer.alloc(0), 'auto'), { code: 'speech-not-ready' });

  const enabled = await request('/models/local-asr', 'PUT', { enabled: true });
  assert.equal(enabled.status, 200);
  f.verifyDone.resolve();
  await f.loadEntered.promise;
  f.loadDone.resolve();
  await f.models.serial;
  assert.equal(f.models.snapshot().ready, true);
  assert.equal(f.loads(), 1);
  assert.equal((await item()).active, true);
  const protectedModel = await remove();
  assert.equal(protectedModel.status, 409);
  assert.equal((await protectedModel.json()).code, 'model-busy');
  assert.equal(await readFile(weights, 'utf8'), 'test weights');

  const disabled = await request('/models/local-asr', 'PUT', { enabled: false });
  assert.equal(disabled.status, 200);
  await f.models.serial;
  assert.equal(f.releases(), 1);
  const health = await (await request('/health')).json();
  assert.equal(health.ok, true);
  assert.equal(health.pid, pausedHealth.pid);
  assert.equal(health.speech.phase, 'disabled');
  assert.equal((await item()).active, false);
  assert.equal((await remove()).status, 200);
  assert.equal(await item(), undefined);
  await assert.rejects(readFile(weights), { code: 'ENOENT' });
  assert.equal(await readFile(unrelated, 'utf8'), 'keep this file');
  const polish = await request('/polish', 'POST', { text: 'The report is ready.', strength: 'prompt' });
  assert.equal(polish.status, 200);
  assert.equal((await polish.json()).text, 'The report is ready.');
  assert.equal(f.loads(), 1);
  assert.deepEqual(JSON.parse(await readFile(f.models.selectionPath, 'utf8')), { modelId: selected });
  f.models.verify = async () => { await readFile(weights); };
  assert.equal((await request('/models/local-asr', 'PUT', { enabled: true })).status, 200);
  await f.models.serial;
  assert.equal(f.models.snapshot().phase, 'missing-model');
  assert.equal(f.loads(), 1);
});

test('rapid cloud and local switches cancel stale model startup and load the latest mode', async t => {
  const f = await fixture(t, MLX_DEFAULT_MODEL_ID);
  const first = f.models.prepare();
  await f.verifyEntered.promise;
  f.models.setLocalEnabled(false);
  f.models.setLocalEnabled(true);
  const replacement = f.models.prepare();
  assert.notEqual(replacement, first);
  f.verifyDone.resolve();
  await f.loadEntered.promise;
  f.loadDone.resolve();
  await replacement;
  assert.equal(f.loads(), 1);
  assert.equal(f.models.snapshot().ready, true);
});
