/** Local model descriptions are data, never native configuration or executable code. */
import { stat, realpath } from 'node:fs/promises';
import { isAbsolute, join, relative } from 'node:path';
import { modelFor, recognizerConfig } from './models.js';
import { within, inspectOnnx } from './onnx-files.js';

export const LOCAL_MODEL_TEMPLATES = {
  'sensevoice-small': { model: 'model.int8.onnx', tokens: 'tokens.txt' },
  'fireredasr2-ctc': { model: 'model.int8.onnx', tokens: 'tokens.txt' },
  'fun-asr-nano': { encoderAdaptor: 'encoder_adaptor.int8.onnx', llm: 'llm.int8.onnx', embedding: 'embedding.int8.onnx', tokenizer: 'Qwen3-0.6B' },
  'qwen3-asr-0.6b': { convFrontend: 'conv_frontend.onnx', encoder: 'encoder.int8.onnx', decoder: 'decoder.int8.onnx', tokenizer: 'tokenizer' },
};
const bad = () => Object.assign(new Error('invalid local model description'), { code: 'invalid-local-model' });

export async function inspectLocalModel(input) {
  if (!input || typeof input !== 'object' || Array.isArray(input) || Object.keys(input).some(k => !['name', 'family', 'directory', 'files'].includes(k))) throw bad();
  const { name, family, directory, files } = input;
  const template = LOCAL_MODEL_TEMPLATES[family];
  if (!Object.hasOwn(LOCAL_MODEL_TEMPLATES, family) || typeof name !== 'string' || !name.trim() || name.length > 80 || /[\p{C}]/u.test(name)
    || typeof directory !== 'string' || !isAbsolute(directory) || !files || typeof files !== 'object' || Array.isArray(files)
    || Object.keys(files).length !== Object.keys(template).length || Object.keys(files).some(k => !Object.hasOwn(template, k))) throw bad();
  const root = await realpath(directory), checked = {}, inventory = [], types = new Set();
  for (const role of Object.keys(template)) {
    const value = files[role];
    if (typeof value !== 'string' || !value || value.length > 500 || isAbsolute(value) || value.split(/[\\/]/u).includes('..') || /[\0\r\n]/u.test(value)) throw bad();
    if (role === 'tokenizer') {
      // Only the tokenizer data files the existing adapters consume.
      for (const file of ['merges.txt', 'vocab.json', ...(family === 'fun-asr-nano' ? ['tokenizer.json'] : ['tokenizer_config.json'])]) {
        const path = await within(root, join(value, file));
        const size = (await stat(path)).size;
        if (size <= 0 || size > 32 * 1024 ** 2) throw bad();
        inventory.push({ path: relative(root, path).split(/[\\/]/u), size });
      }
      checked[role] = join(root, value);
    } else {
      const path = await within(root, value), size = (await stat(path)).size;
      if (size <= 0 || size > 12 * 1024 ** 3) throw bad();
      if (role !== 'tokens') {
        if (!path.endsWith('.onnx')) throw bad();
        const graph = await inspectOnnx(root, value);
        for (const t of graph.dataTypes) types.add(t);
        for (const ref of graph.references) inventory.push({ path: relative(root, ref).split(/[\\/]/u), size: (await stat(ref)).size });
      } else if (size > 32 * 1024 ** 2) throw bad();
      checked[role] = path;
      inventory.push({ path: relative(root, path).split(/[\\/]/u), size });
    }
  }
  const unique = [...new Map(inventory.map(f => [f.path.join('/'), f])).values()];
  return { name: name.trim(), family, directory: root, files: { ...files }, inventory: unique,
    modelBytes: unique.reduce((n, f) => n + f.size, 0), dataTypes: [...types], paths: checked,
    languages: modelFor(family).languages, canSetLanguage: modelFor(family).canSetLanguage };
}

export function localConfig(model, { language = 'auto', numThreads = 2 } = {}) {
  const config = recognizerConfig('/unused', model.family, { language, numThreads });
  const p = model.paths;
  if (model.family === 'sensevoice-small') { config.modelConfig.senseVoice.model = p.model; config.modelConfig.tokens = p.tokens; }
  if (model.family === 'fireredasr2-ctc') { config.modelConfig.fireRedAsrCtc.model = p.model; config.modelConfig.tokens = p.tokens; }
  if (model.family === 'fun-asr-nano') Object.assign(config.modelConfig.funasrNano, p);
  if (model.family === 'qwen3-asr-0.6b') Object.assign(config.modelConfig.qwen3Asr, p);
  return config;
}
