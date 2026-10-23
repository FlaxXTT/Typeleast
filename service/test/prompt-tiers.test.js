import test from 'node:test';
import assert from 'node:assert/strict';
import { VoicePolishService } from '../lib/service.js';
import { systemPromptFor } from '../lib/prompt.js';
import { validateOutput } from '../lib/validate.js';
import { PROMPTIFY_PROMPT, BRIEF_PROMPT } from '../lib/prompts/promptify.js';
import { UTTERANCE_RULES } from '../lib/utterance-rules.js';
import { translatePrompt } from '../lib/prompts/translate.js';
import { STRENGTHS, validateConfig } from '../lib/config.js';

test('plain and legacy standard tiers are distinct and use the existing strength field', () => {
  assert.ok(STRENGTHS.includes('promptbrief'));
  assert.deepEqual(validateConfig({ strength: 'promptbrief' }).issues, []);
  assert.ok(systemPromptFor({ strength: 'promptbrief' }).startsWith(BRIEF_PROMPT));
  assert.ok(systemPromptFor({ strength: 'promptify' }).startsWith(PROMPTIFY_PROMPT));
  const custom = { override: 'My existing standard prompt', appendix: 'My existing appendix' };
  assert.ok(systemPromptFor({ strength: 'promptify', promptify: custom }).startsWith(custom.override));
  assert.doesNotMatch(systemPromptFor({ strength: 'promptbrief', promptify: custom }), /My existing/);
  assert.match(BRIEF_PROMPT, /积极压缩/);
  assert.match(BRIEF_PROMPT, /否定、例外、数字/);
  assert.match(BRIEF_PROMPT, /用户明确要求表格/);
  assert.match(BRIEF_PROMPT, /不输出角色、背景、任务/);
  assert.match(BRIEF_PROMPT, /保留请求的语气、对象和用途/);
});

test('all one-shot modes and translation receive scoped correction and term-restoration rules', () => {
  for (const strength of ['prompt', 'conservative', 'maximal', 'promptify', 'promptbrief']) {
    assert.ok(systemPromptFor({ strength }).includes(UTTERANCE_RULES), strength);
  }
  assert.ok(translatePrompt('en').includes(UTTERANCE_RULES));
  assert.match(UTTERANCE_RULES, /只处理本次口述/);
  assert.match(UTTERANCE_RULES, /连续改口/);
  assert.match(UTTERANCE_RULES, /引号内引用/);
  assert.match(UTTERANCE_RULES, /无法唯一确定/);
});

const samples = [
  ['周三开会，不对，周四，不对，改成周五下午，地点还是线上', '周五下午线上开会。'],
  ['我不需要表格，不对，我需要表格，但不要图表', '需要表格，不要图表。'],
  ['这个结果不对，需要修复，不要改其他功能', '这个结果不对，需要修复，不要改其他功能。'],
  ['这个函数会调用它自己处理更小的问题，我忘了术语怎么说', '这个函数使用递归处理更小的问题。'],
  ['帮我给初学者写一段说明，讲那个函数调用它自己处理更小问题的办法，我忘了专业词，不要给代码', '请为初学者写一段递归（函数调用自身）的说明，不要给代码。'],
  ['先说做移动端页面。上一句不要了，改成只做桌面端设置页，不新增功能', '只做桌面端设置页，不新增功能。'],
  ['那个负责管理容器的工具我忘了名字，部署时需要用它，不确定是哪款', '部署需要容器管理工具，具体名称待确认。'],
];
for (const strength of ['prompt', 'promptbrief', 'promptify']) {
  for (const [rawText, output] of samples) {
    test(`${strength}: scoped correction or restoration passes the actual pipeline: ${output}`, async () => {
      let calls = 0;
      const service = new VoicePolishService({
        recognizer: { snapshot: () => ({ ready: true }) },
        config: { maxOutputTokens: 800, timeoutMs: 12000, strength: 'prompt', redactSecrets: true, dictionary: [] },
        fetchImpl: async (_, init) => {
          calls++;
          const request = JSON.parse(init.body);
          assert.ok(request.messages[0].content.includes(UTTERANCE_RULES));
          return { ok: true, json: async () => ({ choices: [{ message: { content: output }, finish_reason: 'stop' }] }) };
        },
      });
      const result = await service.polish({ rawText, strength, llm: { baseURL: 'https://api.example.com/v1', model: 'demo', apiKey: 'sk-test-123456789012' } });
      assert.equal(result.fallback, false, result.reason);
      assert.equal(result.text, output);
      assert.equal(calls, 1);
    });
  }
}

test('aggressive plain compression keeps fact checks and does not demand a role template', () => {
  const rawText = '那个我想把好多杂乱的设置分一下组，就是按用途分组，常用的模式呢要随时能切换，不要中断录音';
  const output = '1. 设置按用途分组。\n2. 常用模式可随时切换，不中断录音。';
  assert.equal(validateOutput({ rawText, output, strength: 'promptbrief' }).ok, true);
  assert.equal(validateOutput({ rawText, output: output + '\n限 512 字。', strength: 'promptbrief' }).reason, 'invented-fact');
});

test('raw mode still skips the model and does not resolve names or rewrite corrections', async () => {
  let calls = 0;
  const service = new VoicePolishService({ config: { strength: 'off' }, fetchImpl: async () => { calls++; throw Error('must not call'); } });
  const result = await service.polish({ rawText: '周三不对周四开会', strength: 'off' });
  assert.ok(result.text.includes('不对'));
  assert.equal(calls, 0);
});
