// Check compiled-in UI catalogs without reading user settings or contacting a provider.
import { readFile, readdir } from 'node:fs/promises';
import { resolve } from 'node:path';
import assert from 'node:assert/strict';
const root = resolve(import.meta.dirname, '../..');
const literal = '"(?:\\\\.|[^"\\\\])*"';
const slots = text => [...text.matchAll(/\{[0-9]+\}|%\.[0-9]+f/g)].map(m => m[0]).sort();
for (const [directory, extension, catalogFile, method, entry] of [
  ['apps/macos/Sources', '.swift', 'apps/macos/Sources/L10n.swift', 'L10n.text', new RegExp(`(${literal}): (${literal})`, 'g')],
  ['apps/windows', '.cs', 'apps/windows/TypeLeast.Core/L10n.cs', 'L10n.T', new RegExp(`\\[(${literal})\\] = (${literal})`, 'g')],
]) {
  const catalogText = await readFile(resolve(root, catalogFile), 'utf8');
  const catalog = new Map();
  for (const match of catalogText.matchAll(entry)) {
    const key = JSON.parse(match[1]), value = JSON.parse(match[2]);
    assert(!catalog.has(key), `duplicate translation: ${key}`);
    assert(value.trim(), `empty translation: ${key}`);
    assert.deepEqual(slots(key), slots(value), `format slots differ: ${key}`);
    catalog.set(key, value);
  }
  let calls = 0;
  async function visit(dir) {
    for (const item of await readdir(dir, { withFileTypes: true })) {
      if (['bin', 'obj', 'TypeLeast.Core.Tests'].includes(item.name)) continue;
      const path = resolve(dir, item.name);
      if (item.isDirectory()) { await visit(path); continue; }
      if (!path.endsWith(extension) || path === resolve(root, catalogFile)) continue;
      const source = await readFile(path, 'utf8');
      for (const match of source.matchAll(new RegExp(method.replace('.', '\\.') + `\\((${literal})`, 'g'))) {
        const key = JSON.parse(match[1]);
        assert(catalog.has(key), `missing translation in ${item.name}: ${key}`);
        calls++;
      }
    }
  }
  await visit(resolve(root, directory));
  console.log(`${directory}: ${catalog.size} translations, ${calls} lookups checked`);
}
