/** A local model executes in a disposable child, without model-provider credentials. */
import { fork } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { inspectLocalModel, localConfig } from './local-models.js';
import { LocalRecognizer } from './asr.js';

export const modelEnvironment = (env = process.env) => Object.fromEntries(['PATH', 'SystemRoot', 'WINDIR', 'TMP', 'TEMP', 'TMPDIR'].filter(k => typeof env[k] === 'string').map(k => [k, env[k]]));
const fail = code => Object.assign(new Error('local speech model could not be used'), { code });

export class LocalModelProcess {
  constructor(description) { this.description = description; this.phase = 'loading'; this.nextId = 0; this.pending = new Map(); }
  snapshot() { return { phase: this.phase, ready: this.phase === 'ready', languages: this.description.languages, modelName: this.description.name, canSetLanguage: this.description.canSetLanguage }; }
  async prepare() {
    if (this.child) return this.phase;
    this.child = fork(fileURLToPath(import.meta.url), ['--local-asr-worker'], { env: modelEnvironment(), execArgv: [], stdio: ['ignore', 'ignore', 'ignore', 'ipc'] });
    this.child.on('message', message => {
      const entry = this.pending.get(message?.id);
      if (!entry) return;
      this.pending.delete(message.id); clearTimeout(entry.timer);
      if (message.ok) entry.resolve(message.value); else entry.reject(fail('model-load-failed'));
    });
    const died = () => { this.phase = 'error'; for (const p of this.pending.values()) { clearTimeout(p.timer); p.reject(fail('model-load-failed')); } this.pending.clear(); };
    this.child.on('error', died); this.child.on('exit', died);
    try { await this.call('prepare', this.description, 180000); this.phase = 'ready'; return this.phase; }
    catch (error) { await this.release(); throw error; }
  }
  call(action, value, timeout = 120000) {
    if (!this.child?.connected) return Promise.reject(fail('speech-not-ready'));
    return new Promise((resolve, reject) => {
      const id = ++this.nextId;
      const timer = setTimeout(() => { this.pending.delete(id); reject(fail('model-timeout')); void this.release(); }, timeout);
      this.pending.set(id, { resolve, reject, timer });
      this.child.send({ id, action, value }, error => { if (error) { clearTimeout(timer); this.pending.delete(id); reject(fail('model-load-failed')); } });
    });
  }
  transcribe(audio, language) {
    if (!Buffer.isBuffer(audio) || audio.length > 4194304) return Promise.reject(fail('invalid-audio'));
    return this.call('transcribe', { audio: audio.toString('base64'), language });
  }
  metrics() { return this.call('metrics', null); }
  async release() {
    this.phase = 'error';
    const child = this.child; this.child = null;
    if (!child) return;
    for (const p of this.pending.values()) { clearTimeout(p.timer); p.reject(fail('model-load-failed')); } this.pending.clear();
    if (child.exitCode !== null || child.signalCode !== null) return;
    await new Promise(resolve => {
      const timer = setTimeout(() => child.kill('SIGKILL'), 2000);
      const done = () => { clearTimeout(timer); resolve(); };
      child.once('exit', done); child.once('error', done); child.kill();
    });
  }
}

if (process.argv[2] === '--local-asr-worker' && process.send) {
  let recognizer;
  process.on('disconnect', () => process.exit(0));
  process.on('message', async ({ id, action, value }) => {
    try {
      let result;
      if (action === 'prepare' && !recognizer) {
        const d = await inspectLocalModel({ name: value.name, family: value.family, directory: value.directory, files: value.files });
        recognizer = new LocalRecognizer({ modelsDir: d.directory, modelId: d.family, modelDefinition: { ...d, files: d.inventory },
          configFactory: options => localConfig(d, options), language: 'auto', numThreads: 2 });
        if (await recognizer.prepare() !== 'ready') throw fail('model-load-failed');
        result = true;
      } else if (action === 'transcribe' && recognizer && typeof value.audio === 'string' && value.audio.length <= 5592412) {
        result = await recognizer.transcribe(Buffer.from(value.audio, 'base64'), value.language);
      } else if (action === 'metrics' && recognizer) {
        result = { rssMiB: Math.round(process.memoryUsage().rss / 1024 ** 2), maxRssMiB: Math.round(process.resourceUsage().maxRSS / 1024) };
      } else throw fail('invalid-local-model');
      process.send({ id, ok: true, value: result });
    } catch { process.send({ id, ok: false }); }
  });
}
