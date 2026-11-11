/** Optional speech model lifecycle. Downloads never replace the running recognizer. */
import { readFile, mkdir, writeFile, rename, rm, lstat } from 'node:fs/promises';
import { dirname } from 'node:path';
import { LocalRecognizer } from './asr.js';
import { DEFAULT_MODEL_ID, MODEL_CATALOG, filesForModel, modelFor, modelStatus, downloadModels, sha256File } from './models.js';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { inspectLocalModel, LOCAL_MODEL_TEMPLATES } from './local-models.js';
import { LocalModelProcess } from './local-recognizer.js';
import { MossRecognizer } from './moss-recognizer.js';
import { MlxRecognizer } from './mlx-recognizer.js';
import { MLX_DEFAULT_MODEL_ID } from './mlx-models.js';

const fail = (code, message) => Object.assign(new Error(message), { code });
export const MEETING_MODEL_ID = 'moss-transcribe-diarize';
export class SpeechModels {
  constructor(options) {
    this.options = options;
    this.modelsDir = options.modelsDir;
    this.selectionPath = options.selectionPath;
    this.writeSelectionFile = options.writeSelectionFile ?? writeFile;
    this.commitSelectionFile = options.commitSelectionFile ?? rename;
    this.local = new Map(); this.registered = new Set();
    this.registryPath = join(dirname(this.selectionPath), 'local-speech-models.json');
    this.mlxOnly = options.mlxOnly ?? process.platform === 'darwin';
    this.defaultId = this.mlxOnly ? MLX_DEFAULT_MODEL_ID : DEFAULT_MODEL_ID;
    this.factory = options.factory ?? (id => {
      if (this.local.has(id)) {
        if (this.mlxOnly) throw fail('invalid-model', 'this Mac requires an MLX speech model');
        return new LocalModelProcess(this.local.get(id));
      }
      const model = modelFor(id);
      if (this.mlxOnly && model.engine !== 'mlx') throw fail('invalid-model', 'this Mac requires an MLX speech model');
      return model.engine === 'mlx' ? new MlxRecognizer({ ...options, modelId: id })
        : model.engine === 'moss' ? new MossRecognizer({ ...options, modelId: id }) : new LocalRecognizer({ ...options, modelId: id });
    });
    this.current = this.factory(this.defaultId);
    this.activeId = this.defaultId;
    this.serial = Promise.resolve();
    this.closed = false;
    this.lifecycle = new AbortController();
    this.operation = null;
    this.notice = null;
    this.beforeActivate = async () => {};
  }
  enqueue(work) {
    const result = this.serial.then(work);
    this.serial = result.catch(() => {});
    return result;
  }
  prepare() { return this.closed ? Promise.resolve('missing-model') : this.enqueue(() => this.prepareSelected()); }
  async prepareSelected() {
    if (this.closed) return 'missing-model';
    try {
      const saved = await readFile(this.registryPath, 'utf8');
      if (saved.length > 200000) throw fail('invalid-local-model', 'local model registry is too large');
      const registry = JSON.parse(saved);
      this.registered = new Set((registry.builtins ?? []).filter(id => MODEL_CATALOG.some(m => m.id === id && (!this.mlxOnly || m.engine === 'mlx'))));
      for (const item of (registry.models ?? []).slice(0, 32)) {
        if (!this.mlxOnly && /^local-[0-9a-f-]{36}$/.test(item.id)) this.local.set(item.id, { ...item, languages: modelFor(item.family).languages, canSetLanguage: modelFor(item.family).canSetLanguage });
      }
    } catch (e) { if (e.code !== 'ENOENT') this.notice = 'local-model-unavailable'; }
    let selected = this.defaultId;
    try { selected = JSON.parse(await readFile(this.selectionPath, 'utf8')).modelId; this.definition(selected); }
    catch (error) {
      if (error.code !== 'ENOENT') this.notice = 'saved-model-unavailable';
      // Legacy installations may already have the default files. Never download or silently
      // replace an explicitly selected but unavailable model.
      if (error.code !== 'ENOENT' || !(await modelStatus(this.modelsDir, filesForModel(this.defaultId))).ready) {
        this.activeId = ''; return 'missing-model';
      }
      selected = this.defaultId;
    }
    if (selected !== this.defaultId) {
      let next;
      try {
        await this.verify(selected);
        this.lifecycle.signal.throwIfAborted();
        next = this.factory(selected);
        if (await next.prepare(this.lifecycle.signal) !== 'ready') throw fail('model-load-failed', 'speech model could not be loaded');
        this.lifecycle.signal.throwIfAborted();
        this.current = next; this.activeId = selected;
        return 'ready';
      } catch { await next?.release?.(); this.notice = 'saved-model-unavailable'; this.activeId = ''; return 'missing-model'; }
    }
    // MLX tokenizer and weights are data, but affect every recognition result.
    // Recheck the pinned inventory before the default model is loaded on restart.
    if (this.mlxOnly) {
      try { await this.verify(this.defaultId); }
      catch { this.notice = 'saved-model-unavailable'; this.activeId = ''; return 'missing-model'; }
    }
    if (this.closed) return 'missing-model';
    return this.current.prepare(this.lifecycle.signal);
  }
  definition(id) {
    const model = this.local.get(id) ?? modelFor(id);
    if (this.mlxOnly && model.engine !== 'mlx' && model.id !== MEETING_MODEL_ID) throw fail('invalid-model', 'this Mac requires an MLX speech model');
    return model;
  }
  transcribe(audio, language, signal) { return this.enqueue(() => {
    if (this.closed) throw fail('speech-not-ready', 'speech service is closed');
    if (!this.activeId) throw fail('speech-not-ready', 'select a speech model first');
    return this.current.transcribe(audio, language, signal);
  }); }
  /** The engine for meetings, kept apart from the dictation model and its queue. */
  async meetingRecognizer() {
    if (this.closed) throw fail('speech-not-ready', 'speech service is closed');
    this.meeting ??= this.options.factory ? this.options.factory(MEETING_MODEL_ID)
      : this.mlxOnly ? new MossRecognizer({ ...this.options, modelId: MEETING_MODEL_ID }) : this.factory(MEETING_MODEL_ID);
    const phase = await this.meeting.prepare();
    if (phase === 'missing-model') throw fail('model-not-installed', 'the meeting model is not installed');
    if (phase !== 'ready') throw fail('meeting-unavailable', 'the meeting engine could not start');
    return this.meeting;
  }
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
    const models = await Promise.all(MODEL_CATALOG.filter(model => this.mlxOnly ? model.engine === 'mlx' || model.id === MEETING_MODEL_ID : model.engine !== 'mlx').map(async model => ({
      id: model.id, name: model.name, modelBytes: model.modelBytes, sourceUrl: model.sourceUrl,
      licenseUrl: model.source, languages: model.languages, canSetLanguage: model.canSetLanguage,
      installed: (await modelStatus(this.modelsDir, filesForModel(model.id))).ready,
      family: model.id, precision: model.precision ?? 'int8', category: this.mlxOnly && model.id === MEETING_MODEL_ID ? 'meeting' : model.id.startsWith('qwen3-asr-') || model.engine ? 'primary' : 'other',
      registered: this.registered.has(model.id), downloadable: model.id.startsWith('qwen3-asr-') || Boolean(model.engine),
    })));
    for (const [id, model] of this.local) models.push({ id, name: model.name, family: model.family, precision: 'local', category: 'other', registered: true, downloadable: false,
      installed: Array.isArray(model.inventory) && (await modelStatus(model.directory, model.inventory)).ready,
      modelBytes: model.modelBytes, languages: model.languages, canSetLanguage: model.canSetLanguage, sourceUrl: '', licenseUrl: '' });
    return { activeModelId: this.activeId, models, storage: await this.storageItems(), operation: this.operation, notice: this.notice,
      templates: this.mlxOnly ? [] : LOCAL_MODEL_TEMPLATES,
      series: this.mlxOnly ? [] : [ { id: 'qwen3-asr-0.6b', name: 'Qwen3-ASR-0.6B', formats: ['int8'] },
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
    if (this.closed) throw fail('speech-not-ready', 'speech service is closed');
    signal = signal ? AbortSignal.any([signal, this.lifecycle.signal]) : this.lifecycle.signal;
    this.definition(id);
    if (this.mlxOnly && id === MEETING_MODEL_ID) throw fail('invalid-model', 'the meeting model cannot be used for dictation');
    signal?.throwIfAborted();
    await this.beforeActivate(signal);
    return this.enqueue(async () => {
      signal?.throwIfAborted();
      await this.verify(id);
      signal?.throwIfAborted();
      if (this.operation?.modelId === id) this.operation.phase = "loading";
      const next = this.factory(id);
      this.candidate = next;
      const temporary = this.selectionPath + '.tmp';
      try {
        if (await next.prepare(signal) !== 'ready') throw fail('model-load-failed', 'speech model could not be loaded');
        signal?.throwIfAborted();
        // Persist only after successful loading. A disk failure leaves the old selection running.
        await mkdir(dirname(this.selectionPath), { recursive: true });
        await this.writeSelectionFile(temporary, JSON.stringify({ modelId: id }) + '\n', { mode: 0o600 });
        signal?.throwIfAborted();
        // Cancellation is accepted until this synchronous commit point. Once
        // rename starts, the operation must finish or report a disk failure.
        if (this.mlxOnly && this.operation?.modelId === id) this.operation.phase = 'committing';
        await this.commitSelectionFile(temporary, this.selectionPath);
      } catch (error) {
        await rm(temporary, { force: true }).catch(() => {});
        await next.release?.();
        this.candidate = null;
        throw error;
      }
      this.candidate = null;
      if (this.closed) { await next.release?.(); return; }
      const previous = this.current;
      this.current = next; this.activeId = id; this.notice = null;
      await previous.release?.();
    });
  }
  start(id = this.defaultId, { endpoint, activate = true, download = true, fetchImpl } = {}) {
    if (this.closed) throw fail('speech-not-ready', 'speech service is closed');
    if (this.storageBusy) throw fail('model-busy', 'storage cleanup is in progress');
    this.definition(id);
    if (this.mlxOnly && id === MEETING_MODEL_ID && activate) throw fail('invalid-model', 'the meeting model cannot be used for dictation');
    if (download && this.local.has(id)) throw fail('invalid-model', 'local models are imported, not downloaded');
    if (this.operation && ['downloading','loading','waiting','committing'].includes(this.operation.phase)) {
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
  downloadAndPrepare(options = {}) { this.start(this.defaultId, options); return this.job; }
  cancel(id) {
    this.definition(id);
    if (!this.operation || this.operation.modelId !== id) return;
    if (this.operation.phase === 'committing') throw fail('model-busy', 'model selection is being saved');
    if (this.operation.phase === 'loading' && !this.mlxOnly) throw fail('model-busy', 'speech model is already loading');
    this.abort?.abort();
  }
  // Only catalogued model files are managed here. Imported paths and user data are never removed.
  async storageFile(path, partial = false) {
    let current = this.modelsDir;
    try {
      const root = await lstat(current);
      if (!root.isDirectory() || root.isSymbolicLink()) return null;
      for (let i = 0; i < path.length; i++) {
        const component = path[i] + (partial && i === path.length - 1 ? '.part' : '');
        if (!component || component === '.' || component === '..' || component.includes('/') || component.includes('\\')) return null;
        current = join(current, component);
        const info = await lstat(current);
        if (info.isSymbolicLink() || (i < path.length - 1 && !info.isDirectory())) return null;
        if (i === path.length - 1) return info.isFile() ? { path: current, size: info.size } : null;
      }
    } catch (error) { if (error.code !== 'ENOENT') throw error; }
    return null;
  }
  async storageItems() {
    let selected = this.activeId;
    try { selected ||= JSON.parse(await readFile(this.selectionPath, 'utf8')).modelId; } catch {}
    const items = [];
    for (const model of MODEL_CATALOG) {
      if (model.id === MEETING_MODEL_ID) continue;
      let bytes = 0, partialBytes = 0;
      for (const file of model.files) {
        bytes += (await this.storageFile(file.path))?.size ?? 0;
        partialBytes += (await this.storageFile(file.path, true))?.size ?? 0;
      }
      if (bytes || partialBytes) items.push({ id: model.id, name: model.name, bytes, partialBytes,
        active: model.id === selected, legacy: this.mlxOnly && model.engine !== 'mlx' });
    }
    return items;
  }
  async clearModelStorage(id, partialOnly) {
    const definition = modelFor(id);
    if (id === MEETING_MODEL_ID || this.local.has(id)) throw fail('invalid-model', 'model cannot be removed here');
    if (this.storageBusy || (this.operation && ['downloading', 'loading', 'waiting', 'committing'].includes(this.operation.phase)))
      throw fail('model-busy', 'another model operation is in progress');
    this.storageBusy = true;
    try {
      return await this.enqueue(async () => {
        let selected = this.activeId;
        try { selected ||= JSON.parse(await readFile(this.selectionPath, 'utf8')).modelId; } catch {}
        if (!partialOnly && id === selected) throw fail('model-busy', 'switch models before deleting the active model');
        for (const file of definition.files) {
          for (const partial of partialOnly ? [true] : [false, true]) {
            const entry = await this.storageFile(file.path, partial);
            if (entry) await rm(entry.path);
          }
        }
      });
    } finally { this.storageBusy = false; }
  }

  async saveRegistry() {
    const models = [...this.local.values()].map(({ id, name, family, directory, files, modelBytes, inventory }) => ({ id, name, family, directory, files, modelBytes, inventory }));
    await mkdir(dirname(this.registryPath), { recursive: true });
    await writeFile(this.registryPath + '.tmp', JSON.stringify({ builtins: [...this.registered], models }) + '\n', { mode: 0o600 });
    await rename(this.registryPath + '.tmp', this.registryPath);
  }
  async registerKnown(id) {
    if (this.mlxOnly) throw fail('invalid-model', 'ONNX model registration is unavailable on this Mac');
    modelFor(id);
    return this.enqueue(async () => {
      await this.verify(id); this.registered.add(id);
      try { await this.saveRegistry(); } catch (e) { this.registered.delete(id); throw e; }
    });
  }
  async inspectLocal(input) { if (this.mlxOnly) throw fail('invalid-model', 'ONNX model registration is unavailable on this Mac'); const m = await inspectLocalModel(input); return { name: m.name, family: m.family, modelBytes: m.modelBytes, dataTypes: m.dataTypes }; }
  registerLocal(input) {
    if (this.mlxOnly) throw fail('invalid-model', 'ONNX model registration is unavailable on this Mac');
    if (this.operation && ['downloading', 'loading', 'waiting', 'committing'].includes(this.operation.phase)) throw fail('model-busy', 'another model operation is running');
    if (this.local.size >= 32) throw fail('invalid-local-model', 'local model limit reached');
    const id = 'local-' + randomUUID();
    this.operation = { modelId: id, phase: 'loading', received: 0, total: 0, error: null };
    this.job = (async () => {
      // Wait before entering the recognizer queue: queued dictations must be able
      // to finish while beforeActivate waits for their pending count to reach zero.
      try { await this.beforeActivate(); } catch (e) {
        this.operation.phase = 'error'; this.operation.error = e.code ?? 'model-load-failed'; return;
      }
      return this.enqueue(async () => {
        let probe;
        try {
          const model = { ...await inspectLocalModel(input), id };
          probe = new LocalModelProcess(model); await probe.prepare();
          this.local.set(id, model);
          try { await this.saveRegistry(); } catch (e) { this.local.delete(id); throw e; }
          this.operation.phase = 'complete';
        } catch (e) { this.operation.phase = 'error'; this.operation.error = e.code ?? 'model-load-failed'; }
        finally { await probe?.release(); }
      });
    })();
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

  /** Abort ongoing work immediately; do not wait behind the recognition queue. */
  async release() {
    if (this.closed) return;
    this.closed = true;
    this.lifecycle.abort();
    this.abort?.abort();
    await Promise.allSettled([this.current?.release?.(), this.candidate?.release?.(), this.meeting?.release?.()]);
  }
}
