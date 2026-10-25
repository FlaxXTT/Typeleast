import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile, rm, symlink } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { inspectOnnx } from '../lib/onnx-files.js';
import { inspectLocalModel } from '../lib/local-models.js';
import { LocalModelProcess, modelEnvironment } from '../lib/local-recognizer.js';

function varint(n) { const b = []; do { let c = n % 128; n = Math.floor(n / 128); if (n) c |= 128; b.push(c); } while (n); return Buffer.from(b); }
function field(n, value) { const b = Buffer.isBuffer(value) ? value : Buffer.from(value); return Buffer.concat([varint(n * 8 + 2), varint(b.length), b]); }
const graph = content => field(7, content);
const external = file => graph(field(5, field(13, Buffer.concat([field(1, 'location'), field(2, file)]))));
async function fixture(run) { const root = await mkdtemp(join(tmpdir(), 'typeleast-import-test-')); try { await run(root); } finally { await rm(root, { recursive: true, force: true }); } }

test('model children receive no provider keys, service token or injection variables', () => {
  assert.deepEqual(modelEnvironment({ PATH: '/bin', API_KEY: 'fake-key', TYPELEAST_HOME: '/fake-state', NODE_OPTIONS: '--inspect', DYLD_INSERT_LIBRARIES: '/fake-library' }), { PATH: '/bin' });
});

test('ONNX inspection finds external weights without executing a model', () => fixture(async root => {
  await writeFile(join(root, 'weights.data'), Buffer.alloc(4));
  await writeFile(join(root, 'encoder.onnx'), external('weights.data'));
  assert.equal((await inspectOnnx(root, 'encoder.onnx')).references.length, 1);
}));
test('ONNX inspection rejects absolute, traversal, symlink and custom-domain references', () => fixture(async root => {
  for (const location of ['../outside.data', '/outside.data', 'C:\\outside.data']) {
    await writeFile(join(root, 'encoder.onnx'), external(location));
    await assert.rejects(inspectOnnx(root, 'encoder.onnx'));
  }
  await writeFile(join(root, 'custom.onnx'), graph(field(1, field(7, 'evil.domain'))));
  await assert.rejects(inspectOnnx(root, 'custom.onnx'), { code: 'invalid-local-model' });
  if (process.platform !== 'win32') {
    await symlink(tmpdir(), join(root, 'escape'));
    await writeFile(join(root, 'escape.onnx'), external('escape/nonexistent.data'));
    await assert.rejects(inspectOnnx(root, 'escape.onnx'));
  }
}));
test('truncated graphs and excessive lengths fail before native code is loaded', () => fixture(async root => {
  for (const bytes of [Buffer.from([58, 127, 1, 2]), Buffer.from('not a model')]) {
    await writeFile(join(root, 'bad.onnx'), bytes);
    await assert.rejects(inspectOnnx(root, 'bad.onnx'));
  }
}));
test('a local model accepts only data and the selected adapter file mapping', () => fixture(async root => {
  const model = { name: 'Fictional model', family: 'sensevoice-small', directory: root, files: { model: 'model.onnx', tokens: 'tokens.txt' } };
  await writeFile(join(root, 'model.onnx'), graph(field(2, 'fixture')));
  await writeFile(join(root, 'tokens.txt'), 'test 1\n');
  const inspected = await inspectLocalModel(model);
  assert.equal(inspected.inventory.length, 2);
  for (const value of [{ ...model, command: 'anything' }, { ...model, family: 'unknown' }, { ...model, files: { ...model.files, library: 'evil.dylib' } }]) {
    await assert.rejects(inspectLocalModel(value), { code: 'invalid-local-model' });
  }
}));
test('a bad native load fails inside a child and does not create a model selection', () => fixture(async root => {
  const model = { name: 'Broken fixture', family: 'sensevoice-small', directory: root, files: { model: 'bad.onnx', tokens: 'tokens.txt' } };
  await writeFile(join(root, 'bad.onnx'), graph(field(2, 'fixture')));
  await writeFile(join(root, 'tokens.txt'), 'test 1\n');
  const process = new LocalModelProcess(await inspectLocalModel(model));
  try { await assert.rejects(process.prepare()); assert.equal(process.snapshot().ready, false); }
  finally { await process.release(); }
}));
