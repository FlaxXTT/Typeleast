import test from 'node:test';
import assert from 'node:assert/strict';
import { normalizeNumbers } from '../lib/number-format.js';
import { validateOutput } from '../lib/validate.js';

const cases = [
  ['报名一百二十三人，增长百分之二十五。', '报名123人，增长25%。'],
  ['需要三四个人，再给五六天，预算七八百元。', '需要三四个人，再给五六天，预算700～800元。'],
  ['十七八岁，二三十分钟，二十三四个。', '17～18岁，20～30分钟，23～24个。'],
  ['二零二六年十月二十一日。', '2026年10月21日。'],
  ['版本三点一二，增长百分之零点五。', '版本3.12，增长0.5%。'],
  ['编号是零零一二三，验证码是一二三四五六。', '编号是00123，验证码是123456。'],
  ['一心一意、三心二意、一刀切、五一劳动节，买一台一汽汽车。', '一心一意、三心二意、一刀切、五一劳动节，买一台一汽汽车。'],
  ['执行 `等待三天`，访问 https://example.com/三天，文件 /tmp/三天。', '执行 `等待三天`，访问 https://example.com/三天，文件 /tmp/三天。'],
  ['引用“三天”，另外需要四天。', '引用“三天”，另外需要四天。'],
  ['金额三万五元，读数不确定。', '金额三万五元，读数不确定。'],
  ['早上九點至下午五點，兩個人。', '早上9點至下午5點，兩個人。'],
  ['第三点需要三千克，预算一万亿元。', '第三点需要三千克，预算一万亿元。'],
  ['请保留中文数字，需要三个人。', '请保留中文数字，需要三个人。'],
  ['不要使用中文数字，需要三个人。', '不要使用中文数字，需要3个人。'],
  ['我想说三点：要快、要准、要便宜。', '我想说三点：要快、要准、要便宜。'],
  ['三个人用两天，读了五页，开了一次会。', '三个人用两天，读了五页，开了一次会。'],
  ['走了三公里，花了五元，他今年八岁。', '走了3公里，花了5元，他今年8岁。'],
  ['三月五号开会，九点半开始。', '3月5号开会，9点半开始。'],
  ['请用阿拉伯数字，三个人两天。', '请用阿拉伯数字，3个人2天。'],
];
for (const [source, expected] of cases) test(`written numbers: ${source}`, () => assert.equal(normalizeNumbers(source), expected));

test('equivalent ranges pass and joined estimates remain invalid', () => {
  const rawText = '我们需要三四个人，还要五六天。';
  assert.equal(validateOutput({ rawText, output: normalizeNumbers(rawText), strength: 'prompt' }).ok, true);
  assert.equal(validateOutput({ rawText, output: '我们需要34个人，还要56天。', strength: 'prompt' }).ok, false);
});
