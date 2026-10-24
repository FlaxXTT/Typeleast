// Build market/catalog.json from market/plugins/*.typeleast-plugin, checking every file with
// the same rules the app uses. Run after adding or changing a plugin:
//     node market/build-catalog.mjs
import { readdir, readFile, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { CATALOG_FORMAT, parsePlugin } from '../service/lib/plugins.js';

const root = fileURLToPath(new URL('.', import.meta.url));

/** The catalog text for the plugins folder; throws on the first file that fails the checks. */
export async function buildCatalog(dir = root + 'plugins/') {
  const names = (await readdir(dir)).filter((name) => name.endsWith('.typeleast-plugin')).sort();
  const plugins = [];
  for (const name of names) {
    const result = parsePlugin(await readFile(dir + name, 'utf8'));
    if (!result.ok) throw new Error(`${name}: ${result.issues.map((i) => `${i.path} ${i.code}`).join(', ')}`);
    if (`${result.plugin.id}.typeleast-plugin` !== name) throw new Error(`${name}: the file name must be <id>.typeleast-plugin`);
    plugins.push(result.plugin);
  }
  return JSON.stringify({ format: CATALOG_FORMAT, formatVersion: 1, plugins }, null, 2) + '\n';
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  await writeFile(root + 'catalog.json', await buildCatalog());
  console.log('market/catalog.json written');
}
