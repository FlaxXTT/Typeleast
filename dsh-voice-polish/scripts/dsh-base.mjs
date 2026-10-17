import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { DEFAULT_STATE_DIR } from '../lib/config.js';

/**
 * Where the running DSH host listens, and the token it expects, for the live
 * scripts. DSH binds a new port on each launch and the plugin publishes it to
 * <state dir>/runtime.json, so no port is written into a script.
 *
 * VOICE_POLISH_BASE (e.g. http://127.0.0.1:<port>) overrides the discovery.
 * Paths come from node:path, so this works the same on macOS and Windows.
 */
export async function dshBase() {
  const override = process.env.VOICE_POLISH_BASE?.trim();
  if (override) return override.replace(/\/+$/, '');
  let runtime;
  try {
    runtime = JSON.parse(await readFile(join(DEFAULT_STATE_DIR, 'runtime.json'), 'utf8'));
  } catch {
    throw new Error('DSH is not running (no runtime.json); start DSH or set VOICE_POLISH_BASE');
  }
  if (!Number.isInteger(runtime?.port) || runtime.port <= 0) throw new Error('runtime.json has no port');
  return 'http://127.0.0.1:' + runtime.port;
}

/** The bearer token the host wrote at startup. */
export async function dshToken() {
  return (await readFile(join(DEFAULT_STATE_DIR, 'api-token'), 'utf8')).trim();
}
