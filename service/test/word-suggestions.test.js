import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { wordSuggestions } from '../lib/word-suggestions.js';

const cases = JSON.parse(readFileSync(new URL('./fixtures/word-suggestions.json', import.meta.url), 'utf8'));
for (const item of cases) {
  test(`word suggestions: ${item.id}`, async () => {
    const result = await wordSuggestions(item.raw, item.cleaned);
    assert.deepEqual(result.map(pair => pair.word), item.expected);
    for (const pair of result) assert.ok(pair.heardAs.length > 0);
  });
}

test('suggestions are bounded, deduplicated and safe for concurrent requests', async () => {
  const raw = Array.from({ length: 12 }, (_, i) => `deepsaek${i}`).join(' 和 ');
  const cleaned = Array.from({ length: 12 }, (_, i) => `DeepSeek${i}`).join(' 和 ');
  const results = await Promise.all(Array.from({ length: 6 }, () => wordSuggestions(raw, cleaned)));
  assert.equal(results[0].length, 8);
  for (const result of results) assert.deepEqual(result, results[0]);
  assert.equal((await wordSuggestions('杰森和杰森', 'JSON 和 JSON')).length, 1);
  assert.deepEqual(await wordSuggestions('甲'.repeat(20000), 'DeepSeek'), []);
  assert.deepEqual(await wordSuggestions(null, undefined), []);
});

test('credential-shaped data and redaction markers cannot become dictionary suggestions', async () => {
  // Explicitly fake credentials, never read from user settings.
  assert.deepEqual(await wordSuggestions('sk-fake123456789012', 'sk-fake123456789013'), []);
  assert.deepEqual(await wordSuggestions('redactedkey', 'sk-fake123456789013'), []);
  assert.deepEqual(await wordSuggestions('密码是 secret123456789', '密码是 secret123456788'), []);
});
