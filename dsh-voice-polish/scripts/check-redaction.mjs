import { VoicePolishService } from '../lib/service.js';

/**
 * Verify the privacy boundary: what the model actually receives.
 * The probe captures the raw outbound payload rather than trying to re-parse it.
 */
let outbound = null;
const service = new VoicePolishService({
  ctx: {
    llm: {
      listProviders: () => [{ id: 'deepseek-account' }],
      stream: (request) => {
        outbound = request.messages[0].content[0].text;
        return (async function* () {
          yield { type: 'text-delta', index: 0, text: 'My API key is [redacted-key] and the password is [redacted].' };
          yield { type: 'finish', reason: { kind: 'stop' } };
        })();
      },
    },
    speechToText: {},
    sessions: {},
  },
  config: { provider: 'deepseek-account', model: 'deepseek-flash', maxOutputTokens: 400, timeoutMs: 5000, strength: 'prompt', contextTurns: 2, contextChars: 500, redactSecrets: true, logRaw: true, maxAudioBytes: 4194304, maxDurationSeconds: 120, dictionary: [] },
  history: { append: async (entry) => entry, recent: async () => [{ raw: 'token is ghp_abcdefghijklmnop', text: 'Token is [redacted-token].' }] },
  logger: { info: () => {}, warn: () => {}, debug: () => {} },
  version: 'probe',
});

const rawText = 'my api key is sk-abcdefghijklmnopqrstuvwxyz and the password is hunter2';
const result = await service.polish({ rawText, strength: 'prompt' });

if (outbound === null) {
  console.log('FAIL: the model was never called');
  process.exit(1);
}
const checks = [
  ['outbound payload excludes the API key', !outbound.includes('sk-abcdefghijklmnopqrstuvwxyz')],
  ['outbound payload excludes the password', !outbound.includes('hunter2')],
  ['outbound payload shows the key redaction', outbound.includes('[redacted-key]')],
  ['outbound payload shows the password redaction', outbound.includes('[redacted]')],
  ['context passed to the model is redacted', !outbound.includes('ghp_abcdefghijklmnop')],
  ['outbound payload still carries the task framing', outbound.includes('clean-up-transcript')],
  ['outbound payload still carries the in/out instruction', /Return only the cleaned-up transcript/.test(outbound)],
];
let failures = 0;
for (const [label, ok] of checks) {
  if (!ok) failures += 1;
  console.log((ok ? 'PASS  ' : 'FAIL  ') + label);
}
console.log('');
console.log('outbound payload as the provider would see it:');
console.log(outbound);
console.log('');
console.log('final text handed back to the caller: ' + JSON.stringify(result.text));
process.exit(failures === 0 ? 0 : 1);
