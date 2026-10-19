#!/usr/bin/env node
/** Real model smoke test. Explicit folders prevent use of private app state.
 * node scripts/check-asr-models.mjs --models-dir <cache> --state-dir <isolated-state> --download
 * A fixed public sherpa example is downloaded to state-dir; --sample-file accepts public/synthetic audio instead.
 * Each model runs in a separate child so native memory is released before the next model.
 */
import { parseArgs } from 'node:util';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';
import { spawnSync } from 'node:child_process';
import { MODEL_CATALOG, downloadModels, filesForModel, modelFor } from '../lib/models.js';
import { SpeechModels } from '../lib/speech-models.js';

const { values } = parseArgs({ options: {
  'models-dir': { type: 'string' }, 'state-dir': { type: 'string' },
  'sample-file': { type: 'string' }, 'model-id': { type: 'string' },
  download: { type: 'boolean', default: false }, worker: { type: 'boolean', default: false },
} });
if (!values['models-dir'] || !values['state-dir']) throw new Error('Explicit --models-dir and --state-dir are required');
const modelsDir = resolve(values['models-dir']), stateDir = resolve(values['state-dir']);
await mkdir(stateDir, { recursive: true });
const ids = values['model-id'] ? [modelFor(values['model-id']).id] : MODEL_CATALOG.map(m => m.id);
const sample = values['sample-file'] ? resolve(values['sample-file']) : join(stateDir, 'public-1.wav');
const sampleSource = 'https://huggingface.co/csukuangfj2/sherpa-onnx-fire-red-asr2-ctc-zh_en-int8-2026-02-25/resolve/423be1acfdc5d8aaa5a485fb6263fe4ea8570b06/test_wavs/1.wav';

if (!values.worker) {
  if (!values['sample-file']) {
    try { await readFile(sample); } catch (error) {
      if (error.code !== 'ENOENT') throw error;
      const response = await fetch(sampleSource, { signal: AbortSignal.timeout(60000) });
      if (!response.ok) throw new Error(`public sample HTTP ${response.status}`);
      const bytes = Buffer.from(await response.arrayBuffer());
      if (bytes.length < 32044 || bytes.length > 2_000_000 || bytes.toString('ascii', 0, 4) !== 'RIFF') throw new Error('invalid public sample');
      await writeFile(sample, bytes);
    }
  }
  console.log(JSON.stringify({ sample: values['sample-file'] ? 'explicit public/synthetic file' : sampleSource }));
  for (const id of ids) {
    if (values.download) {
      let last = -1;
      await downloadModels({ modelsDir, files: filesForModel(id), onProgress: ({received,total}) => {
        const step = Math.floor(received / total * 10);
        if (step !== last) { last = step; console.log(JSON.stringify({ id, downloadedPercent: step * 10 })); }
      } });
    }
    const child = spawnSync(process.execPath, ['--expose-gc', fileURLToPath(import.meta.url), '--worker', '--model-id', id,
      '--models-dir', modelsDir, '--state-dir', join(stateDir, id), '--sample-file', sample], { stdio: 'inherit', timeout: 600000 });
    if (child.error || child.status !== 0) throw child.error ?? new Error(`${id} failed: exit ${child.status}, signal ${child.signal}`);
  }
} else {
  const id = ids[0];
  const sherpa = createRequire(import.meta.url)('sherpa-onnx-node');
  const wave = sherpa.readWave(sample);
  if (wave.sampleRate !== 16000 || wave.samples.length < 16000 || wave.samples.length > 16000 * 20) throw new Error('sample must be nonempty 16 kHz speech of 1–20 seconds');
  if (!wave.samples.some(v => Math.abs(v) > 0.01)) throw new Error('sample contains no audible signal');
  const pcm = Buffer.alloc(wave.samples.length * 2);
  wave.samples.forEach((v,i) => pcm.writeInt16LE(Math.round(Math.max(-1, Math.min(32767 / 32768, v)) * 32768), i*2));
  const wav = Buffer.alloc(44 + pcm.length);
  wav.write('RIFF'); wav.writeUInt32LE(36+pcm.length,4); wav.write('WAVE',8); wav.write('fmt ',12);
  wav.writeUInt32LE(16,16); wav.writeUInt16LE(1,20); wav.writeUInt16LE(1,22); wav.writeUInt32LE(16000,24);
  wav.writeUInt32LE(32000,28); wav.writeUInt16LE(2,32); wav.writeUInt16LE(16,34); wav.write('data',36); wav.writeUInt32LE(pcm.length,40); pcm.copy(wav,44);
  const manager = new SpeechModels({ modelsDir, selectionPath: join(stateDir,'speech-model.json'), numThreads: 2 });
  const start = performance.now();
  manager.start(id, { download: false }); await manager.job;
  if (manager.operation.phase !== 'complete' || !manager.snapshot().ready || manager.activeId !== id) throw new Error(`activation failed: ${manager.operation.error}`);
  const loadMs = performance.now() - start;
  const selected = JSON.parse(await readFile(join(stateDir,'speech-model.json'),'utf8'));
  if (selected.modelId !== id) throw new Error('selection was not saved');
  // Includes all existing language values. Unsupported values must resolve to auto.
  for (const language of ['auto','zh','en','yue','ja','ko','auto']) {
    const began = performance.now();
    const result = await manager.transcribe(wav, language);
    if (!result.text.trim()) throw new Error(`${id} returned no text for ${language}`);
    const expected = modelFor(id).languages.includes(language) ? language : 'auto';
    if (result.language !== expected) throw new Error('effective language mismatch');
    console.log(JSON.stringify({ id, language, effectiveLanguage: result.language, verifyAndLoadMs: Math.round(loadMs),
      decodeMs: Math.round(performance.now()-began), audioSeconds: wave.samples.length/16000,
      rssMiB: Math.round(process.memoryUsage().rss/1024/1024), maxRssMiB: Math.round(process.resourceUsage().maxRSS/1024), text: result.text }));
  }
}
