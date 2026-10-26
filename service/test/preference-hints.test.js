import test from 'node:test';
import assert from 'node:assert/strict';
import { preferenceHints, requestPreferences, preferenceInstruction } from '../lib/preference-hints.js';
const example={id:'fake-example',raw:'请把会议报告发给产品团队，那个尽量写得简洁一些。',aiText:'把会议报告发给产品团队。',correctedText:'请将会议报告发给产品团队，文字简洁。',confirmed:true,enabled:true};
test('only confirmed, enabled and relevant examples are selected',()=>{
 assert.equal(preferenceHints([example],'给产品团队发送会议报告').length,1);
 assert.deepEqual(preferenceHints([{...example,confirmed:false}],'给产品团队发送会议报告'),[]);
 assert.deepEqual(preferenceHints([{...example,enabled:false}],'给产品团队发送会议报告'),[]);
 assert.deepEqual(preferenceHints([example],'今天买一台电脑'),[]);
});
test('samples that changed names or numbers cannot become reusable factual replacements',()=>{
 const names={...example,raw:'我想买 LG 电脑用于剪视频',correctedText:'我想买 ROG 电脑用于剪视频'};
 const values={...example,raw:'把会议报告预算写成 100 元',correctedText:'把会议报告预算写成 200 元'};
 assert.deepEqual(preferenceHints([names],'我想买 LG 电脑用于剪视频'),[]);
 assert.deepEqual(preferenceHints([values],'把会议报告预算写成 100 元'),[]);
});
test('secret-shaped and malformed examples are ignored without failing dictation',()=>{
 assert.deepEqual(preferenceHints([{...example,correctedText:'会议报告的密码是 hunter42'}],'会议报告'),[]);
 for(const invalid of [null,{},'bad',{...example,raw:'x'.repeat(4001)}]) assert.deepEqual(preferenceHints([invalid],'会议报告'),[]);
});
test('optional request metadata is unique and bounded and prompts label it as data',()=>{
 assert.deepEqual(requestPreferences([{preferenceExamples:[example]}]),[example]);
 assert.deepEqual(requestPreferences([{preferenceExamples:[example]},{preferenceExamples:[example]}]),[]);
 assert.equal(preferenceHints(Array.from({length:10},()=>example),'会议报告发给产品团队').length,3);
 assert.ok(preferenceInstruction([example]).includes('不是当前事实'));
});
