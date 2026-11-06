import test from 'node:test';
import assert from 'node:assert/strict';
import { MLX_MODELS, MLX_QWEN_MODELS } from '../lib/mlx-models.js';

test('Qwen MLX models use isolated paths and a pinned official tokenizer', () => {
  assert.deepEqual(MLX_QWEN_MODELS.map(model => model.id), [
    'mlx-qwen3-asr-0.6b-bf16', 'mlx-qwen3-asr-1.7b-bf16',
  ]);
  const ids = new Set(MLX_MODELS.map(model => model.id));
  for (const model of MLX_QWEN_MODELS) {
    assert(ids.has(model.id), 'verified Qwen model must be installable');
    assert.equal(model.engine, 'mlx');
    assert.equal(model.precision, 'bf16');
    assert.deepEqual(model.languages, ['auto', 'zh', 'en', 'ja', 'ko', 'yue']);
    assert.equal(model.canSetLanguage, true);
    assert.equal(new Set(model.files.map(file => file.file)).size, model.files.length);
    for (const file of model.files) {
      assert.equal(file.path[0], model.id);
      assert(!file.path.some(part => part === '..' || part.includes('/') || part.includes('\\')));
      assert(file.size > 0);
      assert.match(file.revision, /^[0-9a-f]{40}$/);
      assert.match(file.sha256, /^[0-9a-f]{64}$/);
    }
    for (const name of ['config.json', 'model.safetensors', 'tokenizer.json'])
      assert(model.files.some(file => file.file === name), `${model.id} requires ${name}`);
    const tokenizer = model.files.find(file => file.file === 'tokenizer.json');
    assert.match(tokenizer.repo, /^Qwen\/Qwen3-ASR-(0\.6B|1\.7B)-hf$/);
    assert.equal(model.modelBytes, model.files.reduce((sum, file) => sum + file.size, 0));
  }
});
