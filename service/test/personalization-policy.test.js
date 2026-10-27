import test from 'node:test';
import assert from 'node:assert/strict';
import {personalizationContext,applyExplicitRules} from '../lib/personalization-policy.js';
import {harnessAddendum} from '../lib/prompt.js';
test('legacy personal and pack vocabulary never reaches a prompt or changes text',async()=>{
 const context=await personalizationContext({personalization:{version:1,rules:[{id:'old',heard:'LG',word:'ROG',enabled:true}]}},['ROG'],{referenceData:()=>({terms:[{word:'ROG'}],aliases:[{heard:'LG',term:'ROG'}]})},'LG 电脑');
 assert.deepEqual(context.dictionary,[]);assert.deepEqual(context.aliases,[]);
 assert.equal(applyExplicitRules({text:'LG 电脑。'},context).text,'LG 电脑。');
 assert.equal(harnessAddendum({dictionary:['ROG'],aliases:[{heard:'LG',term:'ROG'}]}),'');
});
test('wording examples and optional style remain independent of removed vocabulary',async()=>{
 const style={instructions:'Use clear paragraphs.',sourceId:'fake.style'};
 const context=await personalizationContext({personalization:{version:1}},[],{referenceData:()=>({style})});assert.equal(context.style,style);
 const disabled=await personalizationContext({personalization:{version:1,disabled:true}},[],{referenceData:()=>({style})});assert.equal(disabled.style,null);
});
test('a broken optional style does not stop core cleanup',async()=>{
 const context=await personalizationContext({},[],{referenceData(){throw Error('fixture');}});assert.equal(context.style,null);
});
