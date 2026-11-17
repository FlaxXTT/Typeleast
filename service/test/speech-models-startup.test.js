import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { SpeechModels } from '../lib/speech-models.js';
import { MLX_DEFAULT_MODEL_ID, MLX_MODELS } from '../lib/mlx-models.js';

const deferred = () => {
  let resolve;
  const promise = new Promise(done => { resolve = done; });
  return { promise, resolve };
};

async function fixture(t, selected) {
  const dir = await mkdtemp(join(tmpdir(), 'typeleast-startup-'));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const selectionPath = join(dir, 'speech-model.json');
  await writeFile(selectionPath, JSON.stringify({ modelId: selected }));
  const verifyEntered = deferred(), verifyDone = deferred(), loadEntered = deferred(), loadDone = deferred();
  const models = new SpeechModels({ modelsDir: dir, selectionPath, mlxOnly: true,
    factory: id => {
      let ready = false;
      return {
        snapshot: () => ({ phase: ready ? 'ready' : 'missing-model', ready }),
        prepare: async () => { loadEntered.resolve(); await loadDone.promise; ready = true; return 'ready'; },
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
  return { models, verifyEntered, verifyDone, loadEntered, loadDone };
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
  const { readFile } = await import('node:fs/promises');
  assert.deepEqual(JSON.parse(await readFile(models.selectionPath, 'utf8')), { modelId: MLX_DEFAULT_MODEL_ID });
});
