
/**
 * End-to-end smoke test for the loopback dictation contract.
 *
 * Runs against a real DSH composition (see make-harness.mjs) with the real local
 * recogniser. The language model is exercised indirectly: if it is unreachable the
 * request must still succeed with the raw transcript marked as a fallback.
 */
import { readFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { assertCanonical, buildToneWav } from './make-tone-wav.mjs';

const PORT = Number(process.env.VOICE_POLISH_PORT ?? 3099);
const STATE = process.env.VOICE_POLISH_STATE ?? join(tmpdir(), 'voice-polish-harness', 'state');
const BASE = 'http://127.0.0.1:' + PORT + '/api/voice-polish';

let failures = 0;
const check = (label, ok, detail) => {
  console.log((ok ? 'PASS  ' : 'FAIL  ') + label + (detail === undefined ? '' : ' -- ' + detail));
  if (!ok) failures += 1;
};

const token = (await readFile(join(STATE, 'api-token'), 'utf8')).trim();
check('token file has the documented shape', /^[a-f0-9]{64}$/.test(token), token.length + ' chars');
const auth = { authorization: 'Bearer ' + token };

const noAuth = await fetch(BASE + '/health');
check('GET /health without a token is 401', noAuth.status === 401, 'status ' + noAuth.status);
const badToken = await fetch(BASE + '/health', { headers: { authorization: 'Bearer deadbeef' } });
check('GET /health with a wrong token is 401', badToken.status === 401, 'status ' + badToken.status);

// Note: fetch() always sends the URL's own Host, so the DNS-rebinding fence
// cannot be exercised from here. scripts/probe-host.mjs unit-tests the predicate
// and the plan's acceptance run uses:
//   curl -H 'Host: evil.example.com' -H "Authorization: Bearer <token>" .../health
// which must answer 403.

const health = await fetch(BASE + '/health', { headers: auth });
const healthBody = await health.json();
check('GET /health is 200 with a token', health.status === 200, JSON.stringify(healthBody.speech));
check('health names the configured route', healthBody.provider === 'deepseek-account' && healthBody.model === 'deepseek-flash', healthBody.provider + '/' + healthBody.model);
check('health reports the recogniser and its phase', typeof healthBody.speech?.providerId === 'string' && typeof healthBody.speech?.phase === 'string', (healthBody.speech?.providerId ?? '?') + ':' + (healthBody.speech?.phase ?? '?'));
console.log('      recogniser languages: ' + ((healthBody.speech?.languages ?? []).join(',') || 'n/a') + '  ready=' + healthBody.speech?.ready);

const unknown = await fetch(BASE + '/nope', { headers: auth });
check('unknown endpoint is 404', unknown.status === 404, 'status ' + unknown.status);
const wrongMethod = await fetch(BASE + '/dictate', { headers: auth });
check('GET /dictate is 404', wrongMethod.status === 404, 'status ' + wrongMethod.status);

const notAudio = await fetch(BASE + '/dictate', {
  method: 'POST',
  headers: { ...auth, 'content-type': 'audio/wav' },
  body: Buffer.from('this is not a wave file at all'),
});
const notAudioBody = await notAudio.json();
check('non-WAV body is 400 invalid-audio', notAudio.status === 400 && notAudioBody.code === 'invalid-audio', 'status ' + notAudio.status + ' code ' + notAudioBody.code);

// A 16 kHz canonical clip from the shared builder, which asserts its own header.
const goodAudio = buildToneWav(1);
assertCanonical(goodAudio);

const wrongRate = Buffer.from(goodAudio);
wrongRate.writeUInt32LE(44100, 24);
const badRate = await fetch(BASE + '/dictate', { method: 'POST', headers: { ...auth, 'content-type': 'audio/wav' }, body: wrongRate });
const badRateBody = await badRate.json();
check('44.1 kHz audio is rejected', badRate.status === 400 && /16000/.test(badRateBody.error), badRateBody.error);

const silent = await fetch(BASE + '/dictate', {
  method: 'POST',
  headers: { ...auth, 'content-type': 'audio/wav', 'x-voice-language': 'zh', 'x-voice-app': 'com.example.test' },
  body: goodAudio,
});
const silentBody = await silent.json();
  // A tone is not speech, so the expected outcome is a 200 with an empty
  // transcript and an explicit empty-transcript fallback, or a 503 while the
  // recogniser models are still being prepared.
const toneHandled = (silent.status === 200 && silentBody.raw === '') || (silent.status === 503 && silentBody.code === 'speech-not-ready');
check('canonical WAV reaches the recogniser (200 empty transcript, or 503 while models load)', toneHandled, 'status ' + silent.status + ' ' + JSON.stringify(silentBody).slice(0, 200));

const dictateRaw = '\u55ef \u90a3\u4e2a \u6211\u4eec \u5468\u4e8c \u53d1\u51fa\u53bb \u4e0d\u5bf9 \u5468\u4e09 \u53d1\u51fa\u53bb';
const polish = await fetch(BASE + '/polish', {
  method: 'POST',
  headers: { ...auth, 'content-type': 'application/json' },
  body: JSON.stringify({ text: dictateRaw, appHint: 'com.example.test', strength: 'prompt' }),
});
const polishBody = await polish.json();
check('/polish is 200', polish.status === 200, 'status ' + polish.status);
check('/polish always returns the raw transcript', polishBody.raw === dictateRaw, JSON.stringify(polishBody.raw));
check('/polish states fallback explicitly', typeof polishBody.fallback === 'boolean' && (polishBody.fallback === true ? typeof polishBody.fallbackReason === 'string' : typeof polishBody.text === 'string'), 'fallback=' + polishBody.fallback + ' reason=' + (polishBody.fallbackReason ?? '-'));
console.log('      polished text: ' + JSON.stringify(polishBody.text));
console.log('      ms: ' + JSON.stringify(polishBody.ms));

const off = await fetch(BASE + '/polish', {
  method: 'POST',
  headers: { ...auth, 'content-type': 'application/json' },
  body: JSON.stringify({ text: 'hello world', strength: 'off' }),
});
const offBody = await off.json();
check('strength=off returns the raw text unchanged', offBody.text === 'hello world' && offBody.fallback === false, JSON.stringify(offBody.text));

const history = await fetch(BASE + '/history?limit=10', { headers: auth });
const historyBody = await history.json();
check('GET /history is 200 with items', history.status === 200 && Array.isArray(historyBody.items), (historyBody.items?.length ?? 0) + ' items');
check('history entries carry the documented fields', (historyBody.items ?? []).every((item) => 'id' in item && 'ts' in item && 'raw' in item && 'text' in item && 'fallback' in item), JSON.stringify(historyBody.items?.[0] ?? null).slice(0, 160));

const learn = await fetch(BASE + '/learn', {
  method: 'POST',
  headers: { ...auth, 'content-type': 'application/json' },
  body: JSON.stringify({ from: '\u7b2c\u56db\u6279', to: 'DSH' }),
});
const learnBody = await learn.json();
check('POST /learn adds a dictionary entry', learn.status === 200 && Array.isArray(learnBody.dictionary) && learnBody.dictionary.some((e) => e.includes('DSH')), JSON.stringify(learnBody.dictionary));
const dictionaryFile = await readFile(join(STATE, 'dictionary.json'), 'utf8').catch(() => null);
check('learned dictionary is persisted to disk', dictionaryFile !== null && dictionaryFile.includes('DSH'), dictionaryFile === null ? 'missing file' : 'written');

const huge = await fetch(BASE + '/polish', {
  method: 'POST',
  headers: { ...auth, 'content-type': 'application/json', 'content-length': String(512 * 1024) },
  body: JSON.stringify({ text: 'x'.repeat(512 * 1024) }),
}).catch((error) => ({ status: 0, error }));
check('oversized JSON body is refused', huge.status === 413 || huge.status === 0, 'status ' + huge.status);

console.log('');
console.log(failures === 0 ? 'ALL CHECKS PASSED' : failures + ' CHECK(S) FAILED');
process.exit(failures === 0 ? 0 : 1);
