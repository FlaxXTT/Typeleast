import test from 'node:test';
import assert from 'node:assert/strict';
import { skipForMemory } from '../scripts/asr-test-policy.mjs';

test('memory skips require explicit permission and apply only to this large Mac model', () => {
  const fixture = { id: 'qwen3-asr-1.7b-fp16', platform: 'darwin', memoryBytes: 7 * 1024 ** 3, allowed: true };
  assert.equal(skipForMemory(fixture), true);
  assert.equal(skipForMemory({ ...fixture, allowed: false }), false);
  assert.equal(skipForMemory({ ...fixture, memoryBytes: 16 * 1024 ** 3 }), false);
  for (const platform of ['win32', 'linux']) assert.equal(skipForMemory({ ...fixture, platform }), false);
  for (const id of ['qwen3-asr-0.6b', 'sensevoice-small', 'other']) assert.equal(skipForMemory({ ...fixture, id }), false);
});
