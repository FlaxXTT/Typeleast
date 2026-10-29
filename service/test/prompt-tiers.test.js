import test from 'node:test';
import assert from 'node:assert/strict';
import { VoicePolishService } from '../lib/service.js';
import { systemPromptFor } from '../lib/prompt.js';
import { validateOutput } from '../lib/validate.js';
import { CONCISE_PROMPT } from '../lib/prompts/concise.js';
import { UTTERANCE_RULES } from '../lib/utterance-rules.js';
import { translatePrompt } from '../lib/prompts/translate.js';
import { STRENGTHS, validateConfig } from '../lib/config.js';

test('legacy strengths use one shared dictation prompt', () => {
  assert.ok(STRENGTHS.includes('concise'));
  assert.deepEqual(validateConfig({ strength: 'concise' }).issues, []);
  assert.ok(systemPromptFor({ strength: 'concise' }).startsWith(CONCISE_PROMPT));
  assert.equal(systemPromptFor({strength:"concise"}),systemPromptFor({strength:"prompt"}));
});

test('all one-shot cleanup modes receive scoped correction and term-restoration rules', () => {
  for (const strength of ['prompt', 'conservative', 'maximal', 'concise']) {
    assert.ok(systemPromptFor({ strength }).includes(UTTERANCE_RULES), strength);
  }
  assert.match(translatePrompt('en'), /已经整理好的原语言文本/);
  assert.match(UTTERANCE_RULES, /处理本次口述/);
  assert.match(UTTERANCE_RULES, /明确改口/);
  assert.match(UTTERANCE_RULES, /引用和强调/);
  assert.match(UTTERANCE_RULES, /证据不足保留识别结果/);
  assert.match(UTTERANCE_RULES, /明确拼出的，也要对照上下文核对/);
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
for (const strength of ['prompt', 'concise', 'promptify']) {
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

test('aggressive concise compression keeps fact checks and does not demand a role template', () => {
  const rawText = '那个我想把好多杂乱的设置分一下组，就是按用途分组，常用的模式呢要随时能切换，不要中断录音';
  const output = '1. 设置按用途分组。\n2. 常用模式可随时切换，不中断录音。';
  assert.equal(validateOutput({ rawText, output, strength: 'concise' }).ok, true);
  assert.equal(validateOutput({ rawText, output: output + '\n限 512 字。', strength: 'concise' }).reason, 'invented-fact');
});
