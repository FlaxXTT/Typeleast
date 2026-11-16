// Run with the packaged Node.js and an isolated state directory. No microphone,
// user credentials, model downloads, or externally installed Node are used.
import assert from 'node:assert/strict';
import { mkdtemp, readFile, realpath, rm } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

const app = process.argv[2];
assert(app, 'a packaged application is required');
const resources = join(app, 'Contents', 'Resources');
assert.equal(await realpath(process.execPath), await realpath(join(resources, 'node', 'bin', 'node')),
  'the smoke check must use the bundled Node.js');
assert(Number(process.versions.node.split('.')[0]) >= 22, 'Node.js 22 or newer is required');
const stateDir = await mkdtemp(join(tmpdir(), 'typeleast-package-runtime-'));
let handle;
try {
  const require = createRequire(join(resources, 'service', 'package.json'));
  const opencc = require('opencc-js');
  assert.equal(opencc.Converter({ from: 'cn', to: 'tw' })('汉字'), '漢字');
  const { startService } = await import(pathToFileURL(join(resources, 'service', 'lib', 'server.js')));
  handle = await startService({ stateDir, modelsDir: join(stateDir, 'models'), logger: {} });
  const token = (await readFile(join(stateDir, 'api-token'), 'utf8')).trim();
  const response = await fetch(`http://127.0.0.1:${handle.port}/api/voice-polish/health`, {
    headers: { authorization: 'Bearer ' + token },
    signal: AbortSignal.timeout(10000),
  });
  assert.equal(response.status, 200);
  const health = await response.json();
  assert.equal(health.service, 'typeleast');
  assert.equal(health.ok, false, 'a clean installation has no downloaded speech model yet');
  assert(['loading', 'missing-model'].includes(health.speech.phase));
  const runtime = JSON.parse(await readFile(join(stateDir, 'runtime.json'), 'utf8'));
  assert.equal(runtime.port, handle.port);
  console.log('PASS: packaged dependencies load and the bundled Node starts the local service without a speech model');
} finally {
  await handle?.close();
  await rm(stateDir, { recursive: true, force: true });
}
