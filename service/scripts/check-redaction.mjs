import { VoicePolishService } from '../lib/service.js';

/**
 * Verify the privacy boundary: what the model provider actually receives.
 * The probe captures the outbound request body rather than trusting the code
 * that builds it. No network: the provider is a stand-in.
 */
const requests = [];
const service = new VoicePolishService({
  recognizer: { snapshot: () => ({ ready: true }), transcribe: async () => ({ text: '' }) },
  fetchImpl: async (_url, init) => {
    const system = JSON.parse(init.body).messages.find(message => message.role === 'system')?.content ?? '';
    requests.push({ body: init.body, system, authorization: new Headers(init.headers).get('authorization') });
    const content = system.includes('Compare the source and candidate')
      ? '{"ok":true,"issues":[]}'
      : '{"status":"ok","text":"My API key is [redacted-key] and the password is [redacted].","reason":"redacted"}';
    return { ok: true, status: 200, json: async () => ({ choices: [{ message: { content }, finish_reason: 'stop' }] }) };
  },
  config: { maxOutputTokens: 400, timeoutMs: 5000, strength: 'prompt', redactSecrets: true, maxAudioBytes: 4194304, maxDurationSeconds: 120, dictionary: [] },
  logger: { info: () => {}, warn: () => {}, debug: () => {} },
  version: 'probe',
});

const rawText = 'my api key is sk-abcdefghijklmnopqrstuvwxyz and the password is hunter2';
const route = { baseURL: 'https://api.example.com/v1', model: 'probe-model', apiKey: 'sk-route-key-not-content' };
await service.polish({
  rawText,
  strength: 'prompt',
  llm: route,
  fieldContext: { before: 'token is ghp_abcdefghijklmnop', selected: '', after: '', windowTitle: '' },
});

const cleanup = requests.find(request => request.system.includes('ASR post-processing expert'));
const review = requests.find(request => request.system.includes('Compare the source and candidate'));
const checks = [
  ['the general cleanup request was sent', Boolean(cleanup)],
  ['the fact review request was sent', Boolean(review)],
  ['all outbound requests exclude the dictated API key and password',
    requests.every(({ body }) => !body.includes('sk-abcdefghijklmnopqrstuvwxyz') && !body.includes('hunter2'))],
  ['cleanup and review receive the redacted API key and password',
    [cleanup, review].every(request => request?.body.includes('my api key is [redacted] and the password is [redacted]'))],
  ['field context passed to the model is redacted', requests.every(({ body }) => !body.includes('ghp_abcdefghijklmnop'))],
  ['the route key travels only in the Authorization header',
    requests.every(({ body, authorization }) => authorization === 'Bearer ' + route.apiKey && !body.includes(route.apiKey))],
];
let failures = 0;
for (const [label, ok] of checks) {
  if (!ok) failures += 1;
  console.log((ok ? 'PASS  ' : 'FAIL  ') + label);
}
process.exit(failures === 0 ? 0 : 1);
