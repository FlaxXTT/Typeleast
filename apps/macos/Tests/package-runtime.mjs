// Run with the packaged Node.js and an isolated state directory. No microphone,
// user credentials, model downloads, or externally installed Node are used.
import assert from 'node:assert/strict';
import { access, mkdtemp, readFile, realpath, rm, stat } from 'node:fs/promises';
import { constants } from 'node:fs';
import { createRequire } from 'node:module';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

const app = process.argv[2];
assert(app, 'a packaged application is required');
const resources = join(app, 'Contents', 'Resources');
const resourceRoot = await realpath(resources);
const bundledNode = await realpath(join(resources, 'node', 'bin', 'node'));
assert(bundledNode.startsWith(resourceRoot + '/node/'), 'the Node binary must remain inside the app');
assert.equal(await realpath(process.execPath), bundledNode,
  'the smoke check must use the bundled Node.js');
assert(Number(process.versions.node.split('.')[0]) >= 22, 'Node.js 22 or newer is required');
for (const engine of ['mlx-asr', 'moss-transcribe']) {
  const path = join(resources, 'service', 'native', engine);
  await access(path, constants.X_OK);
  assert((await realpath(path)).startsWith(resourceRoot + '/service/native/'));
}
assert((await stat(join(resources, 'service', 'native', 'mlx.metallib'))).size > 0);
const stateDir = await mkdtemp(join(tmpdir(), 'typeleast-package-runtime-'));
let handle;
try {
  const require = createRequire(join(resources, 'service', 'package.json'));
  assert((await realpath(require.resolve('opencc-js'))).startsWith(resourceRoot + '/service/'),
    'runtime dependencies must resolve inside the packaged service');
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
