import test from 'node:test';
import assert from 'node:assert/strict';
import { validateOutput } from '../lib/validate.js';
import { missingNames } from '../lib/entity-guard.js';

test('short and long explicit Latin names cannot silently change', () => {
  for (const [rawText, output] of [['买 ROG', '买 LG'], ['我想买一个 ROG 电脑', '我想买一个 LG 电脑。'], ['使用 DeepSeek 和 iPhone', '使用 ChatGPT 和手机']]) {
    assert.equal(validateOutput({ rawText, output, strength: 'prompt' }).reason, 'entity-changed');
  }
});
test('explicit local retractions can remove the withdrawn name', () => {
  assert.deepEqual(missingNames('想买 LG，不对，改成 ROG 电脑', '想买 ROG 电脑'), []);
  assert.deepEqual(missingNames('ROG 电脑。下午开会，不对，改成 LG 显示器', 'LG 显示器'), ['ROG']);
  assert.deepEqual(missingNames('不要 LG 电脑，想买 ROG 电脑', '想买 ROG 电脑'), ['LG']);
  assert.deepEqual(missingNames('提到 LG，引用“不对，改成 ROG”', '提到 ROG'), ['LG']);
  assert.deepEqual(missingNames('ROG 很便宜。买 ROG，不对，改成 LG', '买 LG'), ['ROG']);
  assert.deepEqual(missingNames('想买 LG，拼法是 R-O-G', '想买 ROG'), []);
  assert.deepEqual(missingNames('LG 很便宜。想买 LG，拼法是 R-O-G', '想买 ROG'), ['LG']);
});
test('only explicit matching correction rules authorise a name replacement', () => {
  assert.deepEqual(missingNames('买 LG 电脑', '买 ROG 电脑', ['LG=ROG']), []);
  assert.deepEqual(missingNames('买 LG 电脑', '买 ROG 电脑', ['ROG', '其他=ROG']), ['LG']);
});
test('ordinary sentence case, case normalisation, translation and Beta remain compatible', () => {
  assert.deepEqual(missingNames('Please send the draft. OK.', 'Send the draft.'), []);
  assert.deepEqual(missingNames('使用 ROG 和 GitHub', '使用 rog 和 Github'), []);
  for (const strength of ['translate', 'promptbeta']) assert.equal(validateOutput({ rawText: '使用 ROG', output: '使用电脑', strength }).ok, true);
});
