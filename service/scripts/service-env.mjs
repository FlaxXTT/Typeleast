import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { defaultStateDir } from '../lib/paths.js';

/**
 * What the live scripts need: where the running service listens, its token,
 * and the model route to test with.
 *
 * The port comes from <state dir>/runtime.json (a new one on every start).
 * VOICE_POLISH_BASE (e.g. http://127.0.0.1:<port>) overrides it.
 *
 * The route comes from the environment, so a key is never written into a file:
 *   TYPELEAST_LLM_BASE_URL  e.g. https://api.deepseek.com/v1
 *   TYPELEAST_LLM_MODEL     e.g. deepseek-chat
 *   TYPELEAST_LLM_KEY       your API key
 */
export async function serviceBase() {
  const override = process.env.VOICE_POLISH_BASE?.trim();
  if (override) return override.replace(/\/+$/, '');
  let runtime;
  try {
    runtime = JSON.parse(await readFile(join(defaultStateDir(), 'runtime.json'), 'utf8'));
  } catch {
    throw new Error('the TypeLeast service is not running (no runtime.json); start it with npm start or set VOICE_POLISH_BASE');
  }
  if (!Number.isInteger(runtime?.port) || runtime.port <= 0) throw new Error('runtime.json has no port');
  return 'http://127.0.0.1:' + runtime.port;
}

/** The bearer token the service wrote at startup. */
export async function serviceToken() {
  return (await readFile(join(defaultStateDir(), 'api-token'), 'utf8')).trim();
}

/** The model route from the environment; exits with a hint when incomplete. */
export function llmRoute() {
  const route = {
    baseURL: process.env.TYPELEAST_LLM_BASE_URL?.trim() ?? '',
    model: process.env.TYPELEAST_LLM_MODEL?.trim() ?? '',
    apiKey: process.env.TYPELEAST_LLM_KEY?.trim() ?? '',
  };
  if (!route.baseURL || !route.model || !route.apiKey) {
    console.error('Set TYPELEAST_LLM_BASE_URL, TYPELEAST_LLM_MODEL and TYPELEAST_LLM_KEY first (these calls use your API quota).');
    process.exit(2);
  }
  return route;
}
