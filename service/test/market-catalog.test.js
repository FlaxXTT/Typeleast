import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { buildCatalog } from '../../market/build-catalog.mjs';
import { validateCatalog } from '../lib/plugins.js';

test('the published catalog is built from market/plugins and passes the app checks', async () => {
  const committed = await readFile(new URL('../../market/catalog.json', import.meta.url), 'utf8');
  assert.equal(committed, await buildCatalog(), 'run: node market/build-catalog.mjs');
  const catalog = validateCatalog(JSON.parse(committed));
  assert.equal(catalog.rejected, 0);
  assert.ok(catalog.plugins.length >= 1);
});
