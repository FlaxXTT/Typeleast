import test from 'node:test';
import assert from 'node:assert/strict';
import { hasRepetitionLoop } from '../lib/asr-review.js';
import { VoicePolishService } from '../lib/service.js';
import { startService } from '../lib/server.js';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';

test('long recognition loops are held for review, not normal repetitions', () => {
  assert.equal(hasRepetitionLoop('前文' + '我'.repeat(80)), true);
  assert.equal(hasRepetitionLoop('数字' + '123456'.repeat(20)), true);
  assert.equal(hasRepetitionLoop('哈哈哈哈，好的，好的，我们稍后再说。'), false);
  assert.equal(hasRepetitionLoop('1234567890'.repeat(5)), false);
  assert.equal(hasRepetitionLoop(''), false);
});

function wav() {
  const size = 3200, audio = Buffer.alloc(44 + size);
  audio.write('RIFF', 0); audio.writeUInt32LE(36 + size, 4); audio.write('WAVEfmt ', 8);
  audio.writeUInt32LE(16, 16); audio.writeUInt16LE(1, 20); audio.writeUInt16LE(1, 22);
  audio.writeUInt32LE(16000, 24); audio.writeUInt32LE(32000, 28);
  audio.writeUInt16LE(2, 32); audio.writeUInt16LE(16, 34);
  audio.write('data', 36); audio.writeUInt32LE(size, 40);
  return audio;
}

test('suspected noise is never auto-insertable even in an older client', async () => {
  let modelCalls = 0;
  const service = new VoicePolishService({
    recognizer: { transcribe: async () => ({ text: '测试候选', language: 'auto', noiseSuspected: true }) },
    config: { maxAudioBytes: 100000, maxDurationSeconds: 120 },
    fetchImpl: async () => { modelCalls += 1; throw new Error('unexpected model call'); },
  });
  const reply = await service.transcribeAndPolish({ audio: wav(), task: 'dictation', language: 'auto' });
  assert.equal(reply.text, '');
  assert.equal(reply.raw, '');
  assert.equal(reply.noiseSuspected, true);
  assert.equal(reply.noiseCandidate, '测试候选');
  assert.equal(reply.fallbackReason, 'suspected-noise');
  assert.equal(modelCalls, 0);
});

test('an extreme recognition repetition is held without dropping its candidate', async () => {
  const candidate = '123'.repeat(60);
  const service = new VoicePolishService({
    recognizer: { transcribe: async () => ({ text: candidate, language: 'auto' }) },
    config: { maxAudioBytes: 100000, maxDurationSeconds: 120 },
  });
  const reply = await service.transcribeAndPolish({ audio: wav(), task: 'dictation', language: 'auto' });
  assert.equal(reply.text, '');
  assert.equal(reply.raw, '');
  assert.equal(reply.noiseCandidate, candidate);
  assert.equal(reply.fallbackReason, 'recognition-repetition');
});

test('noise with no recognized text does not open a review or call the model', async () => {
  let modelCalls = 0;
  const service = new VoicePolishService({
    recognizer: { transcribe: async () => ({ text: '', language: 'auto', noiseSuspected: true }) },
    config: { maxAudioBytes: 100000, maxDurationSeconds: 120 },
    fetchImpl: async () => { modelCalls += 1; throw new Error('unexpected model call'); },
  });
  const reply = await service.transcribeAndPolish({ audio: wav(), task: 'dictation', language: 'auto' });
  assert.equal(reply.text, '');
  assert.equal(reply.raw, '');
  assert.notEqual(reply.noiseSuspected, true);
  assert.equal(reply.fallbackReason, 'empty-transcript');
  assert.equal(modelCalls, 0);
});

test('the HTTP response holds a suspected transcript for old and new clients', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'typeleast-noise-http-'));
  const recognizer = {
    prepare: async () => 'ready',
    snapshot: () => ({ ready: true, phase: 'ready' }),
    transcribe: async () => ({ text: '虚构语音', language: 'auto', noiseSuspected: true }),
  };
  const quiet = { info() {}, warn() {}, debug() {} };
  let handle;
  try {
    handle = await startService({ stateDir: dir, modelsDir: join(dir, 'models'), recognizer, logger: quiet });
    const token = (await readFile(join(dir, 'api-token'), 'utf8')).trim();
    const response = await fetch(`http://127.0.0.1:${handle.port}/api/voice-polish/dictate`, {
      method: 'POST', headers: { authorization: `Bearer ${token}`, 'content-type': 'audio/wav' }, body: wav(),
    });
    assert.equal(response.status, 200);
    const result = await response.json();
    assert.equal(result.text, '');
    assert.equal(result.raw, '');
    assert.equal(result.noiseSuspected, true);
    assert.equal(result.noiseCandidate, '虚构语音');
  } finally {
    await handle?.close();
    await rm(dir, { recursive: true, force: true });
  }
});
