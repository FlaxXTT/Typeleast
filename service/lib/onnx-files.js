/** Inspect ONNX protobuf structure without executing the model or reading weight data. */
import { open, realpath, stat } from 'node:fs/promises';
import { dirname, isAbsolute, relative, resolve, sep } from 'node:path';

const invalid = () => Object.assign(new Error('unsupported or unsafe local model files'), { code: 'invalid-local-model' });
export async function within(root, file) {
  const base = await realpath(root), full = await realpath(resolve(base, file));
  const rel = relative(base, full);
  if (!rel || rel === '..' || rel.startsWith('..' + sep) || isAbsolute(rel) || !(await stat(full)).isFile()) throw invalid();
  return full;
}

export async function inspectOnnx(root, file) {
  const full = await within(root, file), fd = await open(full, 'r');
  const references = new Set(), domains = new Set(), dataTypes = new Set();
  let fieldCount = 0, graphs = 0, cacheStart = -1, cache = Buffer.alloc(0);
  const size = (await fd.stat()).size;
  async function bytes(pos, count) {
    if (count > 65536 || count < 0 || pos + count > size) throw invalid();
    if (pos < cacheStart || pos + count > cacheStart + cache.length) {
      cache = Buffer.alloc(Math.min(65536, size - pos)); cacheStart = pos;
      if ((await fd.read(cache, 0, cache.length, pos)).bytesRead !== cache.length) throw invalid();
    }
    return cache.subarray(pos - cacheStart, pos - cacheStart + count);
  }
  async function integer(cursor, end, wide = false) {
    let n = 0, power = 1;
    for (let i = 0; i < 10 && cursor.pos < end; i++) {
      const c = (await bytes(cursor.pos++, 1))[0]; n += (c & 127) * power;
      if (!wide && !Number.isSafeInteger(n)) throw invalid();
      if (!(c & 128)) return n;
      power *= 128;
    }
    throw invalid();
  }
  async function walk(start, end, kind, depth = 0) {
    if (depth > 24) throw invalid();
    const c = { pos: start }, entry = {};
    while (c.pos < end) {
      if (++fieldCount > 300000) throw invalid();
      const tag = await integer(c, end), field = Math.floor(tag / 8), wire = tag % 8;
      if (!field) throw invalid();
      if (wire === 0) {
        const v = await integer(c, end, true);
        if (kind === 'tensor' && field === 2) dataTypes.add(v);
        continue;
      }
      if (wire === 1 || wire === 5) { c.pos += wire === 1 ? 8 : 4; if (c.pos > end) throw invalid(); continue; }
      if (wire !== 2) throw invalid();
      const length = await integer(c, end), at = c.pos, to = at + length;
      if (to > end) throw invalid();
      c.pos = to;
      let child;
      if (kind === 'model') {
        if (field === 7) { child = 'graph'; graphs++; }
        if (field === 25) throw invalid(); // Unreviewed local function definitions are not supported.
      } else if (kind === 'graph') child = ({ 1: 'node', 5: 'tensor', 15: 'sparse' })[field];
      else if (kind === 'node') {
        if (field === 5) child = 'attribute';
        if (field === 7) domains.add((await bytes(at, length)).toString('utf8'));
      } else if (kind === 'attribute') child = ({ 5: 'tensor', 6: 'graph', 10: 'tensor', 11: 'graph', 22: 'sparse', 23: 'sparse' })[field];
      else if (kind === 'sparse') { if (field === 1 || field === 2) child = 'tensor'; }
      else if (kind === 'tensor' && field === 13) child = 'external';
      else if (kind === 'external' && (field === 1 || field === 2)) entry[field] = (await bytes(at, length)).toString('utf8');
      if (child) await walk(at, to, child, depth + 1);
    }
    if (kind === 'external' && entry[1] === 'location') {
      if (!entry[2] || isAbsolute(entry[2]) || /^[A-Za-z]:|\\|\0/u.test(entry[2])) throw invalid();
      const checked = await within(root, relative(await realpath(root), resolve(dirname(full), entry[2])));
      references.add(checked);
    }
  }
  try {
    if (size < 4 || size > 12 * 1024 ** 3) throw invalid();
    await walk(0, size, 'model');
    if (graphs !== 1 || [...domains].some(d => !['', 'ai.onnx', 'ai.onnx.ml', 'com.microsoft'].includes(d))) throw invalid();
    return { references: [...references], dataTypes: [...dataTypes], domains: [...domains] };
  } finally { await fd.close(); }
}
