#!/usr/bin/env node
/** Developer-only comparison. All paths are explicit; no preferences or credentials are read. */
import { parseArgs } from 'node:util';
import { createRequire } from 'node:module';
import { join } from 'node:path';
import { inspectLocalModel } from '../lib/local-models.js';
import { LocalModelProcess } from '../lib/local-recognizer.js';
const { values } = parseArgs({ options: { 'baseline-dir': { type: 'string' }, 'candidate-dir': { type: 'string' }, 'samples-dir': { type: 'string' } } });
if (!values['baseline-dir'] || !values['candidate-dir'] || !values['samples-dir']) throw new Error('Explicit baseline, candidate and public sample directories are required');
const sherpa = createRequire(import.meta.url)('sherpa-onnx-node');
for (const [name, directory, encoder, decoder] of [
  ['Qwen3-ASR-0.6B INT8', values['baseline-dir'], 'encoder.int8.onnx', 'decoder.int8.onnx'],
  ['Qwen3-ASR-1.7B FP16', values['candidate-dir'], 'encoder.onnx', 'decoder.onnx'],
]) {
  const description = await inspectLocalModel({ name, family: 'qwen3-asr-0.6b', directory,
    files: { convFrontend: 'conv_frontend.onnx', encoder, decoder, tokenizer: 'tokenizer' } });
  const worker = new LocalModelProcess(description);
  try {
    const started = performance.now(); await worker.prepare(); const loadMs = Math.round(performance.now() - started);
    for (const language of ['zh', 'en']) {
      const wave = sherpa.readWave(join(values['samples-dir'], `public-${language}.wav`));
      if (wave.sampleRate !== 16000) throw new Error('public samples must be 16 kHz');
      const samples = wave.samples.subarray(0, 16000 * 8), wav = Buffer.alloc(44 + samples.length * 2);
      wav.write('RIFF'); wav.writeUInt32LE(wav.length - 8, 4); wav.write('WAVEfmt ', 8); wav.writeUInt32LE(16, 16);
      wav.writeUInt16LE(1, 20); wav.writeUInt16LE(1, 22); wav.writeUInt32LE(16000, 24); wav.writeUInt32LE(32000, 28);
      wav.writeUInt16LE(2, 32); wav.writeUInt16LE(16, 34); wav.write('data', 36); wav.writeUInt32LE(samples.length * 2, 40);
      samples.forEach((s, i) => wav.writeInt16LE(Math.max(-32768, Math.min(32767, Math.round(s * 32768))), 44 + i * 2));
      const began = performance.now(), result = await worker.transcribe(wav, language);
      console.log(JSON.stringify({ model: name, language, seconds: samples.length / 16000, loadMs, decodeMs: Math.round(performance.now() - began), ...await worker.metrics(), text: result.text }));
      if (!result.text.trim()) throw new Error('empty recognition');
    }
  } finally { await worker.release(); }
}
