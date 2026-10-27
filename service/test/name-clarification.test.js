import test from 'node:test';
import assert from 'node:assert/strict';
import { VoicePolishService, dictionaryFrom, localEntriesFrom } from '../lib/service.js';
import { nameClarification, clarificationSource, clarificationRule } from '../lib/name-clarification.js';
import { missingNames } from '../lib/entity-guard.js';
import { systemPromptFor } from '../lib/prompt.js';
import { parsePolishOutput } from '../lib/parse-output.js';

const route = { baseURL: 'https://api.example.com/v1', model: 'fake', apiKey: 'sk-test-not-a-real-credential' };
function fixture(answer) {
  const calls = [];
  let suggestions = 0;
  const service = new VoicePolishService({
    recognizer: { snapshot: () => ({ ready: true }), transcribe: async () => ({ text: '它的拼法是 R-O-G' }) },
    config: { dictionary: [], strength: 'concise', maxOutputTokens: 800, timeoutMs: 12000, redactSecrets: true },
    suggestionEngine: async () => { suggestions++; return [{ word: 'ROG', heardAs: 'LG' }]; },
    logger: { warn() {}, info() {} },
    fetchImpl: async (_url, init) => {
      calls.push(JSON.parse(init.body));
      return { ok: true, status: 200, json: async () => ({ choices: [{ message: { content: JSON.stringify(answer) }, finish_reason: 'stop' }] }) };
    },
  });
  return { service, calls, suggestions: () => suggestions };
}
const raw = '我想买 LG 电脑，指那个品牌，名字没说清。';
const pending = { status: 'uncertain', text: raw, reason: 'name', clarification: { question: '请补充名称的全称或拼写。', evidence: 'LG' } };

test('name question requires bounded evidence present in the current utterance', () => {
  assert.ok(nameClarification(pending.clarification, raw));
  for (const invalid of [null, [], {}, { question: 'x', evidence: 'not in source' }, { question: 'x'.repeat(241), evidence: 'LG' }, { question: '\u0000', evidence: 'LG' }])
    assert.equal(nameClarification(invalid, raw), null);
});

test('ordinary modes retain uncertain source names without a confirmation or learning', async () => {
  const f = fixture(pending);
  const result = await f.service.polish({ rawText: raw, llm: route, supportsClarification: true });
  assert.equal(result.text, "");
  assert.equal(result.raw, raw);
  assert.equal(result.reason,'name-kept');
  assert.equal(result.clarification.kind,"quality");
  assert.deepEqual(result.suggestions, []);
  assert.equal(f.suggestions(), 0);
  assert.equal(f.calls.length, 1);
});

test('older clients get the same conservative one-pass name result', async () => {
  const result = await fixture(pending).service.polish({rawText:raw,llm:route});
  assert.equal(result.fallback,true);assert.equal(result.reason,'name-kept');
  assert.equal(result.text,"");assert.equal(result.clarification.kind,"quality");
});

test('an unsupported brand substitution returns the source without a question', async () => {
  const f = fixture({ status: 'ok', text: '我想买 ROG 电脑。' });
  const result = await f.service.polish({ rawText: '我想买 LG 电脑', llm: route, supportsClarification: true });
  assert.equal(result.text, '');
  assert.equal(result.clarification.kind,"quality");
  assert.equal(f.suggestions(), 0);
});

test('translation stops before its second call when source name needs confirmation', async () => {
  const f = fixture(pending);
  const result = await f.service.polish({ rawText: raw, llm: route, translateTo: 'en', supportsClarification: true });
  assert.equal(f.calls.length, 1);
  assert.equal(result.text, '');
  assert.equal(result.clarification.target, 'en');
});

test('fabricated clarification evidence cannot release an unsupported name', async () => {
  const result=await fixture({...pending,text:'我想买 ROG 电脑。',clarification:{question:'Which?',evidence:'玩家国度'}}).service.polish({rawText:raw,llm:route,supportsClarification:true});
  assert.equal(result.text,"");assert.equal(result.reason,'name-kept');assert.equal(result.clarification.kind,"quality");
});

test('automatic dictionary entries cannot authorise replacing a valid different name', () => {
  const auto = dictionaryFrom([], [{ word: 'ROG', heardAs: 'LG', source: 'auto' }]);
  assert.deepEqual(auto, []);
  assert.deepEqual(dictionaryFrom([], [{ word: 'LG=ROG', source: 'auto' }]), []);
  assert.deepEqual(dictionaryFrom([], [{ word: 'ROG', heardAs: 'LG=ROG', source: 'manual' }]), []);
  assert.deepEqual(missingNames('LG 电脑', 'ROG 电脑', auto), ['LG']);
  const manual = dictionaryFrom([], [{ word: 'ROG', heardAs: 'LG', source: 'manual' }]);
  assert.deepEqual(manual, []);
  assert.deepEqual(missingNames('LG 电脑', 'ROG 电脑', manual), ['LG']);
});

test('continuation metadata is bounded, unique, and excluded from dictionary hints', () => {
  assert.equal(clarificationSource([{ clarificationSource: raw }]), raw);
  assert.deepEqual(dictionaryFrom([], [{ clarificationSource: raw }]), []);
  assert.equal(clarificationSource(['word']), '');
  for (const entries of [[{ clarificationSource: 1 }], [{ clarificationSource: 'x'.repeat(32001) }], [{ clarificationSource: 'x' }, { clarificationSource: 'y' }]])
    assert.throws(() => clarificationSource(entries), { code: 'invalid-prompt' });
});

test('explicit current spelling resolves a competing name without permanent dictionary changes', async () => {
  const f = fixture({ status: 'ok', text: '我想买 ROG 电脑。' });
  const result = await f.service.polish({ rawText: '我想买 LG 电脑，它的拼法是 R-O-G', llm: route, supportsClarification: true });
  assert.equal(result.fallback, false);
  assert.equal(result.clarification, undefined);
  assert.equal(result.text, '我想买 ROG 电脑。');
});

test('general prompts describe evidence and constraints, without hardcoded brand examples', () => {
  for (const strength of ['concise', 'prompt']) {
    const prompt = systemPromptFor({ strength });
    assert.doesNotMatch(prompt, /\bROG\b|\bLG\b|玩家国度|败家之眼|# Examples|^Input:/mu);
    assert.match(prompt, /证据|evidence/);
    assert.match(prompt,/不猜、不提问/);
    if(strength==='concise')assert.match(prompt,/找词/);
  }
});

test('malformed clarification envelopes cannot leak draft text through JSON recovery', () => {
  const parsed = parsePolishOutput('{"status":"uncertain","text":"guessed brand","clarification":{"question":"Which?"');
  assert.equal(parsed.ok, false);
  assert.equal(parsed.text, '');
});

test('an explicit spoken answer resolves only the held name and only for this request', () => {
  const entries = [{ clarificationSource: raw, clarificationEvidence: 'LG' }];
  for (const answer of ['ROG', '是 ROG', '不对，是 ROG', '它的拼法是 R-O-G']) {
    assert.deepEqual(clarificationRule(entries, answer), [{ word: 'ROG', heardAs: 'LG', source: 'manual' }], answer);
  }
  for (const answer of ['是不是 ROG', '可能是 ROG', '只买中国品牌', '不是 ROG', '预算 10000 元'])
    assert.deepEqual(clarificationRule(entries, answer), [], answer);
  assert.deepEqual(clarificationRule([{ clarificationSource: raw, clarificationEvidence: 'missing' }], 'ROG'), []);
  assert.equal(entries.length, 1, 'no mutation or persistence of a new rule');
});

// Exercise the real HTTP decoder and response envelope without a listening socket.
import { Readable } from 'node:stream';
import { createHandler } from '../lib/http.js';
async function post(service, path, body, headers = {}) {
  const req = Readable.from([body]);
  Object.assign(req, { method: 'POST', url: '/api/voice-polish' + path,
    headers: { host: '127.0.0.1:51234', authorization: 'Bearer test-only-token', ...headers } });
  const res = { headersSent: false, writeHead(status) { this.status = status; this.headersSent = true; },
    end(text) { this.json = JSON.parse(text); }, destroy() {} };
  await createHandler({ service, currentToken: async () => 'test-only-token' })(req, res);
  return res;
}
function silentWav() {
  const b = Buffer.alloc(44 + 3200);
  b.write('RIFF'); b.writeUInt32LE(b.length - 8, 4); b.write('WAVE', 8); b.write('fmt ', 12);
  b.writeUInt32LE(16, 16); b.writeUInt16LE(1, 20); b.writeUInt16LE(1, 22);
  b.writeUInt32LE(16000, 24); b.writeUInt32LE(32000, 28); b.writeUInt16LE(2, 32); b.writeUInt16LE(16, 34);
  b.write('data', 36); b.writeUInt32LE(b.length - 44, 40);
  return b;
}

test('HTTP ordinary polish delivers the source directly instead of a name question', async () => {
  const f = fixture(pending);
  const res = await post(f.service, '/polish', Buffer.from(JSON.stringify({ text: raw, llm: route, supportsClarification: true })));
  assert.equal(res.status, 200);
  assert.equal(res.json.text, "");
  assert.equal(res.json.clarification.kind,"quality");
  assert.deepEqual(res.json.suggestions, []);
});

test('HTTP voice continuation carries current confirmation, without teaching a permanent mapping', async () => {
  const f = fixture({ status: 'ok', text: '我想买 ROG 电脑。' });
  f.service.config.maxAudioBytes = 4194304;
  f.service.config.maxDurationSeconds = 120;
  f.service.recognizer.transcribe = async () => ({ text: 'ROG' });
  const metadata = Buffer.from(JSON.stringify([{ clarificationSource: '我想买 LG 电脑', clarificationEvidence: 'LG' }]));
  const res = await post(f.service, '/dictate', Buffer.concat([metadata, silentWav()]), {
    'x-voice-dictionary-bytes': String(metadata.length), 'x-voice-clarification': '1',
    'x-voice-llm': Buffer.from(JSON.stringify(route)).toString('base64'), 'x-voice-language': 'zh', 'x-voice-strength': 'concise',
  });
  assert.equal(res.status, 200);
  assert.equal(res.json.fallback, false);
  assert.equal(res.json.text, '我想买 ROG 电脑。');
  assert.equal(res.json.raw, '我想买 LG 电脑\nROG');
  assert.equal(res.json.clarification, undefined);
  assert.deepEqual(f.service.dictionary, [], 'no permanent dictionary mutation');
});

test('automatic local rules and repeated ambiguous names cannot force broad replacement', () => {
  assert.deepEqual(localEntriesFrom([{ local: 'LG=ROG', source: 'auto' }]), []);
  assert.deepEqual(localEntriesFrom([{ local: 'LG=ROG', source: 'manual' }]), []);
  assert.deepEqual(clarificationRule([{ clarificationSource: 'LG 电脑和 LG 屏幕', clarificationEvidence: 'LG' }], 'ROG'), []);
});
