#!/usr/bin/env node
// Black-box contract runner. It imports no TypeLeast production module.
import { createServer, request as httpRequest } from 'node:http';
import { spawn } from 'node:child_process';
import { readFile, mkdtemp, mkdir, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const args = process.argv.slice(2);
const separator = args.indexOf('--');
const options = separator < 0 ? args : args.slice(0, separator);
const target = separator < 0 ? [] : args.slice(separator + 1);
const groupAt = options.indexOf('--group');
const group = groupAt < 0 ? null : options[groupAt + 1];
const fixtureAt = options.indexOf('--fixture');
const fixturePath = fixtureAt < 0 ? join(here, 'v1.json') : options[fixtureAt + 1];
const jsonOutput = options.includes('--json');
if (options.some((item, index) => item !== '--json' && item !== '--group' && item !== '--fixture' && (index === 0 || !['--group', '--fixture'].includes(options[index - 1]))) || groupAt >= 0 && !group || fixtureAt >= 0 && !fixturePath || !target.length) {
  process.stderr.write('Usage: node tests/conformance/run.mjs [--group NAME] [--fixture FILE] [--json] -- PROGRAM [ARG ...]\n');
  process.exit(2);
}

const fixture = JSON.parse(await readFile(fixturePath, 'utf8'));
if (fixture.version !== 1 || !Array.isArray(fixture.cases)) throw new Error('Unsupported contract fixture');
const selected = fixture.cases.filter(item => !group || item.group === group);
if (group && !selected.length) throw new Error(`Unknown or empty group: ${group}`);

const fakeKey = 'sk-test-conformance-only';
const results = [];
for (const scenario of selected) {
  const started = Date.now();
  try {
    await runScenario(scenario);
    results.push({ id: scenario.id, group: scenario.group, status: 'pass', ms: Date.now() - started });
  } catch (error) {
    results.push({ id: scenario.id, group: scenario.group, status: 'fail', ms: Date.now() - started, error: String(error.message ?? error) });
  }
}
const groups = [...new Set(selected.map(item => item.group))];
const summary = Object.fromEntries(groups.map(name => {
  const cases = results.filter(item => item.group === name);
  return [name, { passed: cases.filter(item => item.status === 'pass').length, failed: cases.filter(item => item.status === 'fail').length, skipped: 0 }];
}));
if (jsonOutput) process.stdout.write(JSON.stringify({ fixtureVersion: fixture.version, summary, results }, null, 2) + '\n');
else {
  for (const item of results) process.stdout.write(`${item.status === 'pass' ? 'PASS' : 'FAIL'} ${item.group}/${item.id}${item.error ? `: ${item.error}` : ''}\n`);
  for (const [name, count] of Object.entries(summary)) process.stdout.write(`${name}: ${count.passed} passed, ${count.failed} failed, ${count.skipped} skipped\n`);
}
if (results.some(item => item.status === 'fail')) process.exitCode = 1;

async function runScenario(scenario) {
  const root = await mkdtemp(join(tmpdir(), 'typeleast-contract-'));
  const stateDir = join(root, 'state');
  const modelsDir = join(root, 'models');
  await mkdir(stateDir);
  await mkdir(modelsDir);
  for (const name of ['appdata', 'localappdata', 'xdg', 'tmp']) await mkdir(join(root, name));
  for (const [name, content] of Object.entries(scenario.preloadFiles ?? {})) {
    if (name.includes('..') || name.startsWith('/')) throw new Error('Unsafe fixture path');
    const path = join(stateDir, name);
    await mkdir(dirname(path), { recursive: true });
    await writeFile(path, typeof content === 'string' ? content : JSON.stringify(content));
  }
  let model;
  let service;
  let lastDigest = '';
  let lastSession = '';
  try {
    model = await fakeModelServer(scenario.modelReplies ?? []);
    service = await startTarget(target, root, stateDir, modelsDir);
    for (const [index, step] of scenario.steps.entries()) {
      const context = `${scenario.id} step ${index + 1}`;
      if (step.restart) {
        await service.stop();
        service = await startTarget(target, root, stateDir, modelsDir);
        continue;
      }
      if (step.file) {
        const value = await readFile(join(stateDir, step.file), 'utf8');
        check(value, step.expect, context);
        continue;
      }
      const route = { baseURL: `http://127.0.0.1:${model.port}/v1`, model: 'contract-model', apiKey: fakeKey };
      const rawBody = step.wavId ? wavWithId(step.wavId) : step.rawBody !== undefined ? step.rawBody : step.body === undefined ? '' : JSON.stringify(replace(step.body, route, lastSession));
      const requestStep = { ...step, path: step.path.replace('$LAST_DIGEST', encodeURIComponent(lastDigest)), headers: replace(step.headers ?? {}, route, lastSession) };
      if (step.wavId) requestStep.headers['content-type'] = 'audio/wav';
      const response = await call(service.port, service.token, requestStep, rawBody);
      check(response, step.expect, context);
      if (step.saveDigest) lastDigest = response.json?.plugin?.digest ?? '';
      if (step.saveSession) lastSession = response.json?.beta?.sessionId ?? '';
      const expectedCalls = step.expect?.modelCalls;
      if (expectedCalls !== undefined) equal(model.calls.length, expectedCalls, `${context} modelCalls`);
      for (const [callIndex, wanted] of (step.expect?.modelUsers ?? []).entries()) {
        const actual = model.calls[callIndex]?.body?.messages?.find(message => message.role === 'user')?.content;
        if (wanted === '$REQUEST_BODY_TEXT') equal(actual, step.body.text, `${context} model user ${callIndex}`);
        else equal(actual, wanted, `${context} model user ${callIndex}`);
      }
      for (const { index: callIndex, fragment } of step.expect?.modelUsersContain ?? []) {
        const actual = model.calls[callIndex]?.body?.messages?.find(message => message.role === 'user')?.content;
        if (typeof actual !== 'string' || !actual.includes(fragment)) throw new Error(`${context}: model user ${callIndex} misses ${JSON.stringify(fragment)}`);
      }
      for (const wanted of step.expect?.modelSystemsContain ?? []) {
        if (!model.calls.some(call => call.body.messages?.some(message => message.role === 'system' && message.content.includes(wanted)))) {
          throw new Error(`${context}: no model system message contains ${JSON.stringify(wanted)}`);
        }
      }
    }
    if (scenario.expectLogExcludes) {
      for (const fragment of scenario.expectLogExcludes) {
        if (service.stderr.includes(fragment)) throw new Error(`${scenario.id}: stderr contains forbidden test data`);
      }
    }
  } finally {
    await service?.stop();
    await model?.close();
    await rm(root, { recursive: true, force: true });
  }
}

function replace(value, route, session) {
  if (value === '$FAKE_LLM') return route;
  if (value === '$FAKE_LLM_HEADER') return Buffer.from(JSON.stringify(route)).toString('base64');
  if (value === '$LAST_SESSION') return session;
  if (Array.isArray(value)) return value.map(item => replace(item, route, session));
  if (value && typeof value === 'object') return Object.fromEntries(Object.entries(value).map(([key, item]) => [key, replace(item, route, session)]));
  return value;
}

function wavWithId(id) {
  if (!Number.isInteger(id) || id < 1 || id > 32767) throw new Error('invalid fixture WAV id');
  const samples = 1600;
  const out = Buffer.alloc(44 + samples * 2);
  out.write('RIFF', 0); out.writeUInt32LE(out.length - 8, 4); out.write('WAVE', 8);
  out.write('fmt ', 12); out.writeUInt32LE(16, 16); out.writeUInt16LE(1, 20);
  out.writeUInt16LE(1, 22); out.writeUInt32LE(16000, 24); out.writeUInt32LE(32000, 28);
  out.writeUInt16LE(2, 32); out.writeUInt16LE(16, 34); out.write('data', 36);
  out.writeUInt32LE(samples * 2, 40); out.writeInt16LE(id, 44);
  return out;
}

async function fakeModelServer(replies) {
  const calls = [];
  const server = createServer(async (req, res) => {
    const chunks = [];
    for await (const chunk of req) chunks.push(chunk);
    let body;
    try { body = JSON.parse(Buffer.concat(chunks).toString('utf8')); } catch { body = {}; }
    calls.push({ path: req.url, headers: req.headers, body });
    const answer = replies[calls.length - 1] ?? { text: 'OK' };
    const status = typeof answer === 'object' && answer.status ? answer.status : 200;
    res.writeHead(status, { 'content-type': 'application/json' });
    if (status !== 200) res.end(JSON.stringify({ error: { message: 'test provider failure' } }));
    else res.end(JSON.stringify({ choices: [{ message: { content: typeof answer === 'string' ? answer : answer.text }, finish_reason: 'stop' }] }));
  });
  await new Promise((resolveListen, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', resolveListen); });
  return { port: server.address().port, calls, close: () => new Promise(resolveClose => server.close(resolveClose)) };
}

async function startTarget(command, root, stateDir, modelsDir) {
  // Pass only the runtime basics. Never copy the caller's Key, proxy or app state.
  const env = {
    PATH: process.env.PATH ?? '',
    HOME: root,
    USERPROFILE: root,
    APPDATA: join(root, 'appdata'),
    LOCALAPPDATA: join(root, 'localappdata'),
    XDG_CONFIG_HOME: join(root, 'xdg'),
    TMPDIR: join(root, 'tmp'),
    TMP: join(root, 'tmp'),
    TEMP: join(root, 'tmp'),
    TYPELEAST_HOME: stateDir,
    TYPELEAST_MODELS: modelsDir,
    LANG: 'C.UTF-8',
  };
  if (process.platform === 'win32') {
    for (const key of ['SystemRoot', 'WINDIR', 'COMSPEC', 'PATHEXT']) if (process.env[key]) env[key] = process.env[key];
  }
  const child = spawn(command[0], [...command.slice(1), '--state-dir', stateDir, '--models-dir', modelsDir, '--port', '0'], {
    cwd: process.cwd(), env, stdio: ['ignore', 'pipe', 'pipe'], shell: false,
  });
  let stderr = '';
  child.stderr.on('data', chunk => { stderr = (stderr + chunk.toString('utf8')).slice(-12000); });
  let stdout = '';
  let ready;
  let token;
  try {
    ready = await new Promise((resolveReady, reject) => {
      const timer = setTimeout(() => reject(new Error(`service did not become ready: ${stderr.slice(-300)}`)), 10000);
      child.on('error', error => { clearTimeout(timer); reject(error); });
      child.on('exit', code => { clearTimeout(timer); reject(new Error(`service exited ${code}: ${stderr.slice(-300)}`)); });
      child.stdout.on('data', chunk => {
        stdout += chunk.toString('utf8');
        const newline = stdout.indexOf('\n');
        if (newline < 0) return;
        clearTimeout(timer);
        try { resolveReady(JSON.parse(stdout.slice(0, newline))); } catch { reject(new Error('first stdout line is not ready JSON')); }
      });
    });
    if (ready.event !== 'ready' || !Number.isInteger(ready.port) || ready.port <= 0) throw new Error('invalid ready line');
    token = (await readFile(join(stateDir, 'api-token'), 'utf8')).trim();
    if (!token) throw new Error('missing API token');
  } catch (error) {
    child.kill('SIGKILL');
    throw error;
  }
  return {
    port: ready.port, token, get stderr() { return stderr; },
    stop: () => new Promise(resolveStop => {
      if (child.exitCode !== null) return resolveStop();
      const timer = setTimeout(() => { child.kill('SIGKILL'); resolveStop(); }, 3000);
      child.once('exit', () => { clearTimeout(timer); resolveStop(); });
      child.kill('SIGTERM');
    }),
  };
}

function call(port, token, step, body) {
  return new Promise((resolveCall, reject) => {
    const headers = { Host: `127.0.0.1:${port}`, Authorization: `Bearer ${token}`, ...step.headers };
    if (step.auth === 'missing') delete headers.Authorization;
    if (step.auth === 'wrong') headers.Authorization = 'Bearer wrong-test-token';
    if (step.body !== undefined || step.rawBody !== undefined) headers['Content-Type'] = 'application/json';
    const req = httpRequest({ hostname: '127.0.0.1', port, path: step.path, method: step.method ?? 'GET', headers, timeout: 10000 }, res => {
      const chunks = [];
      res.on('data', chunk => chunks.push(chunk));
      res.on('end', () => {
        const raw = Buffer.concat(chunks).toString('utf8');
        let json;
        try { json = JSON.parse(raw); } catch { json = null; }
        resolveCall({ status: res.statusCode, json, raw });
      });
    });
    req.on('error', reject);
    req.on('timeout', () => req.destroy(new Error('HTTP request timed out')));
    req.end(body);
  });
}

function check(actual, expected = {}, label) {
  const printable = typeof actual === 'string' ? actual : JSON.stringify(actual);
  for (const [path, wanted] of Object.entries(expected.fields ?? {})) {
    const got = path.split('.').reduce((value, key) => value?.[key], actual);
    equal(got, wanted, `${label} ${path}`);
  }
  for (const path of expected.present ?? []) {
    const got = path.split('.').reduce((value, key) => value?.[key], actual);
    if (got === undefined || got === null) throw new Error(`${label} missing ${path}`);
  }
  for (const fragment of expected.contains ?? []) if (!printable.includes(fragment)) throw new Error(`${label} missing ${JSON.stringify(fragment)}`);
  for (const fragment of expected.excludes ?? []) if (printable.includes(fragment)) throw new Error(`${label} contains forbidden ${JSON.stringify(fragment)}`);
}

function equal(actual, expected, label) {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) throw new Error(`${label}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
}
