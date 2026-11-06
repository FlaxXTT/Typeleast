/** A single local, serial MLX worker. Audio is sent over a private pipe, never a file. */
import { spawn } from 'node:child_process';
import { access, constants } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { join } from 'node:path';
import { modelFor, filesForModel, modelStatus } from './models.js';

export const MLX_ENGINE = fileURLToPath(new URL('../native/mlx-asr', import.meta.url));
const MAX_RESPONSE_BYTES = 16 * 1024 * 1024;
const MAX_AUDIO_BYTES = 24 * 1024 * 1024;
const START_TIMEOUT_MS = 180000;
const REQUEST_TIMEOUT_MS = 300000;
const failure = (code, message) => Object.assign(new Error(message), { code });

export class MlxRecognizer {
  constructor(options) {
    this.modelId = options.modelId;
    this.modelsDir = options.modelsDir;
    this.definition = modelFor(this.modelId);
    this.binary = options.binary ?? MLX_ENGINE;
    this.spawn = options.spawn ?? spawn;
    this.status = options.status ?? (() => modelStatus(this.modelsDir, filesForModel(this.modelId)));
    this.phase = 'missing-model';
    this.error = null;
    this.child = null;
    this.pending = null;
    this.preparing = null;
    this.input = Buffer.alloc(0);
  }

  snapshot() {
    return { providerId: 'mlx', engine: 'mlx', phase: this.phase, ready: this.phase === 'ready',
      languages: this.definition.languages, modelBytes: this.definition.modelBytes,
      ...(this.error ? { error: this.error } : {}) };
  }

  prepare(signal) {
    if (this.phase === 'ready' && this.child) return Promise.resolve('ready');
    if (this.preparing) return this.preparing;
    const abort = () => this.stop();
    signal?.addEventListener('abort', abort, { once: true });
    this.preparing = (async () => {
      try {
        if (!(await this.status()).ready) { this.phase = 'missing-model'; return this.phase; }
        await access(this.binary, constants.X_OK);
        signal?.throwIfAborted();
        this.phase = 'loading';
        const child = this.spawn(this.binary, ['serve', '--model-dir', join(this.modelsDir, this.modelId)], {
          stdio: ['pipe', 'pipe', 'ignore'], env: { PATH: '/usr/bin:/bin', TMPDIR: '/tmp' },
        });
        this.child = child;
        child.stdin.on('error', () => { if (child === this.child) this.stop(); });
        child.stdout.on('data', data => this.readOutput(child, data));
        child.on('error', () => this.workerStopped(child));
        child.on('close', () => this.workerStopped(child));
        const ready = await this.waitForMessage(START_TIMEOUT_MS);
        if (ready.ready !== true || this.child !== child) throw failure('model-load-failed', 'MLX worker did not become ready');
        this.phase = 'ready'; this.error = null;
      } catch (error) {
        this.stop(); this.phase = 'error'; this.error = 'MLX worker could not start';
      }
      return this.phase;
    })().finally(() => { signal?.removeEventListener('abort', abort); this.preparing = null; });
    return this.preparing;
  }

  waitForMessage(timeout, signal) {
    if (this.pending) return Promise.reject(failure('model-busy', 'MLX worker is busy'));
    return new Promise((resolve, reject) => {
      const finish = (error, value) => {
        if (!this.pending || this.pending.finish !== finish) return;
        this.pending = null;
        clearTimeout(timer);
        signal?.removeEventListener('abort', abort);
        if (error) reject(error); else resolve(value);
      };
      const abort = () => { finish(signal.reason ?? failure('cancelled', 'cancelled')); this.stop(); };
      const timer = setTimeout(() => { finish(failure('model-timeout', 'MLX worker timed out')); this.stop(); }, timeout);
      this.pending = { finish };
      signal?.addEventListener('abort', abort, { once: true });
      if (signal?.aborted) abort();
    });
  }

  readOutput(child, chunk) {
    if (child !== this.child) return;
    this.input = Buffer.concat([this.input, chunk]);
    if (this.input.length > MAX_RESPONSE_BYTES) { this.stop(); return; }
    const newline = this.input.indexOf(10);
    if (newline < 0) return;
    const line = this.input.subarray(0, newline);
    this.input = this.input.subarray(newline + 1);
    try {
      const message = JSON.parse(line.toString('utf8'));
      if (!this.pending || this.input.length) { this.stop(); return; }
      if (message.error) { this.pending.finish(failure('model-failed', 'MLX recognition failed')); this.stop(); }
      else this.pending.finish(null, message);
    } catch { this.stop(); }
  }

  workerStopped(child) {
    if (child !== this.child) return;
    this.child = null; this.input = Buffer.alloc(0);
    this.pending?.finish(failure('model-failed', 'MLX worker stopped'));
    if (this.phase === 'ready') this.phase = 'error';
  }

  stop() {
    const child = this.child;
    this.child = null; this.input = Buffer.alloc(0);
    child?.kill('SIGKILL');
    this.pending?.finish(failure('model-failed', 'MLX worker stopped'));
    if (this.phase === 'ready') this.phase = 'error';
  }

  async transcribe(audio, language = 'auto', signal) {
    signal?.throwIfAborted();
    if (!Buffer.isBuffer(audio) || audio.length > MAX_AUDIO_BYTES) throw failure('invalid-audio', 'invalid audio size');
    if (!this.definition.languages.includes(language)) language = 'auto';
    const abortPreparing = () => this.stop();
    signal?.addEventListener('abort', abortPreparing, { once: true });
    let phase;
    try { phase = await this.prepare(signal); } finally { signal?.removeEventListener('abort', abortPreparing); }
    signal?.throwIfAborted();
    if (phase !== 'ready') throw failure('speech-not-ready', 'MLX model is not ready');
    const child = this.child;
    const result = this.waitForMessage(REQUEST_TIMEOUT_MS, signal);
    try {
      child.stdin.write(JSON.stringify({ language, bytes: audio.length }) + '\n');
      child.stdin.write(audio);
    } catch { this.stop(); }
    const reply = await result;
    if (typeof reply.text !== 'string' || (reply.segments !== undefined && !Array.isArray(reply.segments)) ||
        (reply.noiseSuspected !== undefined && typeof reply.noiseSuspected !== 'boolean')) {
      this.stop(); throw failure('model-failed', 'invalid MLX response');
    }
    return { text: reply.text, language, detectedLanguage: reply.detectedLanguage ?? null,
      segments: reply.segments ?? [], noiseSuspected: reply.noiseSuspected === true };
  }

  async release() { this.stop(); this.phase = 'missing-model'; }
}
