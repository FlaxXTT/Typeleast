/** Optional speech model lifecycle. Downloads never replace the running recognizer. */
import { readFile, mkdir, writeFile, rename } from 'node:fs/promises';
import { dirname } from 'node:path';
import { LocalRecognizer } from './asr.js';
import { DEFAULT_MODEL_ID, MODEL_CATALOG, filesForModel, modelFor, modelStatus, downloadModels, sha256File } from './models.js';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { inspectLocalModel, LOCAL_MODEL_TEMPLATES } from './local-models.js';
import { LocalModelProcess } from './local-recognizer.js';

const fail = (code, message) => Object.assign(new Error(message), { code });
export class SpeechModels {
  constructor(options) {
    this.options = options;
    this.modelsDir = options.modelsDir;
    this.selectionPath = options.selectionPath;
    this.local = new Map(); this.registered = new Set();
    this.registryPath = join(dirname(this.selectionPath), 'local-speech-models.json');
    this.factory = options.factory ?? (id => this.local.has(id) ? new LocalModelProcess(this.local.get(id)) : new LocalRecognizer({ ...options, modelId: id }));
    this.current = this.factory(DEFAULT_MODEL_ID);
    this.activeId = DEFAULT_MODEL_ID;
    this.serial = Promise.resolve();
    this.operation = null;
    this.notice = null;
    this.beforeActivate = async () => {};
  }
  enqueue(work) {
    const result = this.serial.then(work);
    this.serial = result.catch(() => {});
    return result;
  }
  prepare() { return this.enqueue(() => this.prepareSelected()); }
  async prepareSelected() {
    try {
      const saved = await readFile(this.registryPath, 'utf8');
      if (saved.length > 200000) throw fail('invalid-local-model', 'local model registry is too large');
      const registry = JSON.parse(saved);
      this.registered = new Set((registry.builtins ?? []).filter(id => MODEL_CATALOG.some(m => m.id === id)));
      for (const item of (registry.models ?? []).slice(0, 32)) {
        if (/^local-[0-9a-f-]{36}$/.test(item.id)) this.local.set(item.id, { ...item, languages: modelFor(item.family).languages, canSetLanguage: modelFor(item.family).canSetLanguage });
      }
    } catch (e) { if (e.code !== 'ENOENT') this.notice = 'local-model-unavailable'; }
    let selected = DEFAULT_MODEL_ID;
    try { selected = JSON.parse(await readFile(this.selectionPath, 'utf8')).modelId; this.definition(selected); }
    catch (error) {
      if (error.code !== 'ENOENT') this.notice = 'saved-model-unavailable';
      // Legacy installations may already have the default files. Never download or silently
      // replace an explicitly selected but unavailable model.
      if (error.code !== 'ENOENT' || !(await modelStatus(this.modelsDir, filesForModel(DEFAULT_MODEL_ID))).ready) {
        this.activeId = ''; return 'missing-model';
      }
      selected = DEFAULT_MODEL_ID;
    }
    if (selected !== DEFAULT_MODEL_ID) {
      try {
        await this.verify(selected);
        const next = this.factory(selected);
        if (await next.prepare() !== 'ready') throw fail('model-load-failed', 'speech model could not be loaded');
        this.current = next; this.activeId = selected;
        return 'ready';
      } catch { this.notice = 'saved-model-unavailable'; this.activeId = ''; return 'missing-model'; }
    }
    return this.current.prepare();
  }
  definition(id) { return this.local.get(id) ?? modelFor(id); }
  transcribe(audio, language, signal) { return this.enqueue(() => {
    if (!this.activeId) throw fail('speech-not-ready', 'select a speech model first');
    return this.current.transcribe(audio, language, signal);
  }); }
  snapshot() {
    if (!this.activeId) return { phase: 'missing-model', ready: false, modelId: '', modelName: '', languages: [], canSetLanguage: false, notice: this.notice, operation: this.operation };
    const model = this.definition(this.activeId);
    const state = this.current.snapshot();
    if (!state.ready && this.operation?.modelId === this.activeId) {
      if (this.operation.phase === 'downloading') {
        state.phase = 'downloading'; state.download = { received: this.operation.received, total: this.operation.total };
      } else if (['waiting','loading'].includes(this.operation.phase)) state.phase = 'loading';
      else if (this.operation.phase === 'error') { state.phase = 'error'; state.error = this.operation.error; }
    }
    return { ...state, modelId: model.id, modelName: model.name,
      canSetLanguage: model.canSetLanguage, modelBytes: model.modelBytes,
      operation: this.operation ? { ...this.operation } : null, notice: this.notice };
  }
  async catalog() {
    const models = await Promise.all(MODEL_CATALOG.map(async model => ({
      id: model.id, name: model.name, modelBytes: model.modelBytes, sourceUrl: model.sourceUrl,
      licenseUrl: model.source, languages: model.languages, canSetLanguage: model.canSetLanguage,
      installed: (await modelStatus(this.modelsDir, filesForModel(model.id))).ready,
      family: model.id, precision: model.precision ?? 'int8', category: model.id.startsWith('qwen3-asr-') ? 'primary' : 'other',
      registered: this.registered.has(model.id), downloadable: model.id.startsWith('qwen3-asr-'),
    })));
    for (const [id, model] of this.local) models.push({ id, name: model.name, family: model.family, precision: 'local', category: 'other', registered: true, downloadable: false,
      installed: Array.isArray(model.inventory) && (await modelStatus(model.directory, model.inventory)).ready,
      modelBytes: model.modelBytes, languages: model.languages, canSetLanguage: model.canSetLanguage, sourceUrl: '', licenseUrl: '' });
    return { activeModelId: this.activeId, models, operation: this.operation, notice: this.notice,
      templates: LOCAL_MODEL_TEMPLATES,
      series: [ { id: 'qwen3-asr-0.6b', name: 'Qwen3-ASR-0.6B', formats: ['int8'] },
        { id: 'qwen3-asr-1.7b', name: 'Qwen3-ASR-1.7B', formats: ['fp16'] } ] };
  }
  async verify(id) {
    if (this.local.has(id)) {
      const saved = this.local.get(id);
      const current = await inspectLocalModel({ name: saved.name, family: saved.family, directory: saved.directory, files: saved.files });
      this.local.set(id, { ...current, id }); return;
    }
    const files = filesForModel(id);
    if (!(await modelStatus(this.modelsDir, files)).ready) throw fail('model-not-installed', 'speech model is not installed');
    for (const file of files) {
      if (await sha256File(join(this.modelsDir, ...file.path)) !== file.sha256)
        throw fail('checksum-mismatch', 'speech model verification failed');
    }
  }
  async activate(id, signal) {
    this.definition(id);
    signal?.throwIfAborted();
    await this.beforeActivate(signal);
    return this.enqueue(async () => {
      signal?.throwIfAborted();
      await this.verify(id);
      signal?.throwIfAborted();
      if (this.operation?.modelId === id) this.operation.phase = "loading";
      const next = this.factory(id);
      try {
        if (await next.prepare() !== 'ready') throw fail('model-load-failed', 'speech model could not be loaded');
        // Persist only after successful loading. A disk failure leaves the old selection running.
        await mkdir(dirname(this.selectionPath), { recursive: true });
        await writeFile(this.selectionPath + '.tmp', JSON.stringify({ modelId: id }) + '\n', { mode: 0o600 });
        await rename(this.selectionPath + '.tmp', this.selectionPath);
      } catch (error) { await next.release?.(); throw error; }
      const previous = this.current;
      this.current = next; this.activeId = id; this.notice = null;
      await previous.release?.();
    });
  }
  start(id = DEFAULT_MODEL_ID, { endpoint, activate = true, download = true, fetchImpl } = {}) {
    this.definition(id);
    if (download && this.local.has(id)) throw fail('invalid-model', 'local models are imported, not downloaded');
    if (this.operation && ['downloading','loading','waiting'].includes(this.operation.phase)) {
      if (this.operation.modelId === id) return;
      throw fail('model-busy', 'another speech model operation is in progress');
    }
    this.abort = new AbortController();
    const signal = this.abort.signal;
    this.operation = { modelId: id, phase: download ? 'downloading' : 'waiting', received: 0, total: 0, error: null };
    this.job = (async () => {
      try {
        if (download) await downloadModels({ modelsDir: this.modelsDir, endpoint, files: filesForModel(id), signal, fetchImpl,
          onProgress: ({ received, total }) => { Object.assign(this.operation, { received, total }); } });
        signal.throwIfAborted();
        if (activate) {
          this.operation.phase = 'waiting';
          await this.activate(id, signal);
        }
        this.operation.phase = 'complete';
      } catch (error) {
        this.operation.phase = signal.aborted ? 'cancelled' : 'error';
        this.operation.error = signal.aborted ? null : (error.code ?? 'model-load-failed');
      }
    })();
  }
  downloadAndPrepare(options = {}) { this.start(DEFAULT_MODEL_ID, options); return this.job; }
  cancel(id) {
    this.definition(id);
    if (!this.operation || this.operation.modelId !== id) return;
    if (this.operation.phase === 'loading') throw fail('model-busy', 'speech model is already loading');
    this.abort?.abort();
  }
  async saveRegistry() {
    const models = [...this.local.values()].map(({ id, name, family, directory, files, modelBytes, inventory }) => ({ id, name, family, directory, files, modelBytes, inventory }));
    await mkdir(dirname(this.registryPath), { recursive: true });
    await writeFile(this.registryPath + '.tmp', JSON.stringify({ builtins: [...this.registered], models }) + '\n', { mode: 0o600 });
    await rename(this.registryPath + '.tmp', this.registryPath);
  }
  async registerKnown(id) {
    modelFor(id);
    return this.enqueue(async () => {
      await this.verify(id); this.registered.add(id);
      try { await this.saveRegistry(); } catch (e) { this.registered.delete(id); throw e; }
    });
  }
  async inspectLocal(input) { const m = await inspectLocalModel(input); return { name: m.name, family: m.family, modelBytes: m.modelBytes, dataTypes: m.dataTypes }; }
  registerLocal(input) {
    if (this.operation && ['downloading', 'loading', 'waiting'].includes(this.operation.phase)) throw fail('model-busy', 'another model operation is running');
    if (this.local.size >= 32) throw fail('invalid-local-model', 'local model limit reached');
    const id = 'local-' + randomUUID();
    this.operation = { modelId: id, phase: 'loading', received: 0, total: 0, error: null };
    this.job = this.enqueue(async () => {
      let probe;
      try {
        await this.beforeActivate();
        const model = { ...await inspectLocalModel(input), id };
        probe = new LocalModelProcess(model); await probe.prepare();
        this.local.set(id, model);
        try { await this.saveRegistry(); } catch (e) { this.local.delete(id); throw e; }
        this.operation.phase = 'complete';
      } catch (e) { this.operation.phase = 'error'; this.operation.error = e.code ?? 'model-load-failed'; }
      finally { await probe?.release(); }
    });
    return id;
  }
  async removeLocal(id) {
    return this.enqueue(async () => {
      if (id === this.activeId) throw fail('model-busy', 'switch models before removing the active registration');
      const prior = this.local.get(id), registered = this.registered.has(id);
      this.local.delete(id); this.registered.delete(id);
      try { await this.saveRegistry(); } catch (e) { if (prior) this.local.set(id, prior); if (registered) this.registered.add(id); throw e; }
    });
  }
}
