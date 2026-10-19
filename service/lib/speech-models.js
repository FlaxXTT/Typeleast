/** Optional speech model lifecycle. Downloads never replace the running recognizer. */
import { readFile, mkdir, writeFile, rename } from 'node:fs/promises';
import { dirname } from 'node:path';
import { LocalRecognizer } from './asr.js';
import { DEFAULT_MODEL_ID, MODEL_CATALOG, filesForModel, modelFor, modelStatus, downloadModels, sha256File } from './models.js';
import { join } from 'node:path';

const fail = (code, message) => Object.assign(new Error(message), { code });
export class SpeechModels {
  constructor(options) {
    this.options = options;
    this.modelsDir = options.modelsDir;
    this.selectionPath = options.selectionPath;
    this.factory = options.factory ?? (id => new LocalRecognizer({ ...options, modelId: id }));
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
    let selected = DEFAULT_MODEL_ID;
    try { selected = JSON.parse(await readFile(this.selectionPath, 'utf8')).modelId; modelFor(selected); }
    catch (error) { if (error.code !== 'ENOENT') this.notice = 'saved-model-unavailable'; selected = DEFAULT_MODEL_ID; }
    if (selected !== DEFAULT_MODEL_ID) {
      try {
        await this.verify(selected);
        const next = this.factory(selected);
        if (await next.prepare() !== 'ready') throw fail('model-load-failed', 'speech model could not be loaded');
        this.current = next; this.activeId = selected;
        return 'ready';
      } catch { this.notice = 'saved-model-unavailable'; }
    }
    return this.current.prepare();
  }
  transcribe(audio, language) { return this.enqueue(() => this.current.transcribe(audio, language)); }
  snapshot() {
    const model = modelFor(this.activeId);
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
    })));
    return { activeModelId: this.activeId, models, operation: this.operation, notice: this.notice };
  }
  async verify(id) {
    const files = filesForModel(id);
    if (!(await modelStatus(this.modelsDir, files)).ready) throw fail('model-not-installed', 'speech model is not installed');
    for (const file of files) {
      if (await sha256File(join(this.modelsDir, ...file.path)) !== file.sha256)
        throw fail('checksum-mismatch', 'speech model verification failed');
    }
  }
  async activate(id, signal) {
    modelFor(id);
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
    modelFor(id);
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
    modelFor(id);
    if (!this.operation || this.operation.modelId !== id) return;
    if (this.operation.phase === 'loading') throw fail('model-busy', 'speech model is already loading');
    this.abort?.abort();
  }
}
