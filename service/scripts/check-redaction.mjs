import { VoicePolishService } from '../lib/service.js';

/**
 * Verify the privacy boundary: what the model provider actually receives.
 * The probe captures the outbound request body rather than trusting the code
 * that builds it. No network: the provider is a stand-in.
 */
let outbound = null;
const service = new VoicePolishService({
  recognizer: { snapshot: () => ({ ready: true }), transcribe: async () => ({ text: '' }) },
  fetchImpl: async (url, init) => {
    outbound = init.body;
    return { ok: true, status: 200, json: async () => ({ choices: [{ message: { content: '{"status":"ok","text":"My API key is [redacted-key] and the password is [redacted].","reason":"redacted"}' }, finish_reason: 'stop' }] }) };
  },
  config: { maxOutputTokens: 400, timeoutMs: 5000, strength: 'prompt', redactSecrets: true, maxAudioBytes: 4194304, maxDurationSeconds: 120, dictionary: [] },
  logger: { info: () => {}, warn: () => {}, debug: () => {} },
  version: 'probe',
});

const rawText = 'my api key is sk-abcdefghijklmnopqrstuvwxyz and the password is hunter2';
const route = { baseURL: 'https://api.example.com/v1', model: 'probe-model', apiKey: 'sk-route-key-not-content' };
const result = await service.polish({
  rawText,
  strength: 'prompt',
  llm: route,
  fieldContext: { before: 'token is ghp_abcdefghijklmnop', selected: '', after: '', windowTitle: '' },
});

if (outbound === null) {
  console.log('FAIL: the model was never called');
  process.exit(1);
}
const checks = [
  ['outbound payload excludes the dictated API key', !outbound.includes('sk-abcdefghijklmnopqrstuvwxyz')],
  ['outbound payload excludes the password', !outbound.includes('hunter2')],
  ['outbound payload shows the key redaction', outbound.includes('[redacted-key]')],
  ['outbound payload shows the password redaction', outbound.includes('[redacted]')],
  ['field context passed to the model is redacted', !outbound.includes('ghp_abcdefghijklmnop')],
  ['the route key travels only in the Authorization header, never in the body', !outbound.includes(route.apiKey)],
  ['outbound payload carries the general cleanup prompt', outbound.includes('整理语音识别文本')],
];
let failures = 0;
for (const [label, ok] of checks) {
  if (!ok) failures += 1;
  console.log((ok ? 'PASS  ' : 'FAIL  ') + label);
}
console.log('');
console.log('final text handed back to the caller: ' + JSON.stringify(result.text));
process.exit(failures === 0 ? 0 : 1);
