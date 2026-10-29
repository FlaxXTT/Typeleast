import test from 'node:test';
import assert from 'node:assert/strict';
import {personalizationContext,applyExplicitRules,readPolicy} from '../lib/personalization-policy.js';
import {VoicePolishService} from '../lib/service.js';
const extension={referenceData:()=>({terms:[{word:'ROG',sourceId:'fake.pack',label:'Test pack'},{word:'LG',sourceId:'fake.pack'}],aliases:[{heard:'阿欧鸡',term:'ROG',cues:['电脑'],blockers:[],sourceId:'fake.pack'}]})};
const policy=(extra={})=>({version:1,excluded:[],rules:[],...extra});
test('exclusions filter all term and alias sources without changing current speech',async()=>{
 const raw='ROG 电脑与 LG 屏幕';const c=await personalizationContext({personalization:policy({excluded:['ＲＯＧ']})},['ROG','LG'],extension,raw);
 assert.ok(!c.dictionary.includes('ROG'));assert.ok(c.dictionary.includes('LG'));assert.equal(raw,'ROG 电脑与 LG 屏幕');assert.ok(!c.aliases.some(x=>x.term==='ROG'));
 const restored=await personalizationContext({personalization:policy()},['ROG'],extension,raw);assert.ok(restored.dictionary.includes('ROG'));
});
test('reference provenance stays separate and disabled requests use no data',async()=>{
 const c=await personalizationContext({personalization:policy()},['ROG'],extension,'ROG 电脑');
 assert.ok(c.trace.references.some(x=>x.source==='personal'));assert.ok(c.trace.references.some(x=>x.source==='extension'&&x.sourceId==='fake.pack'));
 const disabled=await personalizationContext({personalization:policy({disabled:true})},['ROG'],extension,'ROG');assert.deepEqual(disabled.dictionary,[]);
});
test('old requests never acquire explicit rule privileges',()=>{
 assert.deepEqual(readPolicy({rules:[{enabled:true,heard:'LG',word:'ROG',id:'old'}]}).rules,[]);
 assert.deepEqual(readPolicy(policy({excluded:['ROG'],rules:[{enabled:true,heard:'LG',word:'ROG',id:'a'}]})).rules,[]);
});
test('explicit local rule records reversible changes and current corrections take priority',async()=>{
 const r={id:'fake-rule',heard:'Acmee',word:'Acme',enabled:true};
 const context=await personalizationContext({personalization:policy({rules:[r]})},[],null,'联系 Acmee');
 const result=applyExplicitRules({raw:'联系 Acmee',text:'联系 Acmee。'},context,'联系 Acmee','prompt');
 assert.equal(result.text,'联系 Acme。');assert.equal(result.personalization.beforeReplacements,'联系 Acmee。');assert.equal(result.personalization.replacements[0].id,r.id);
 for(const raw of ['不是 Acme，是 Acmee','如果联系 Acmee，就通知我','Acmee and Acme']){
  const ctx=await personalizationContext({personalization:policy({rules:[r]})},[],null,raw);
  const unchanged=applyExplicitRules({raw,text:raw},ctx,raw,'concise');assert.equal(unchanged.text,raw);assert.equal(unchanged.personalization.replacements.length,0);
 }
});
test('broken packs and invalid optional state do not stop core cleanup',async()=>{
 const ctx=await personalizationContext({personalization:{version:1,excluded:'bad',rules:[null,{}]}},['Acme'],{referenceData(){throw Error('fixture')}},'Acme');assert.deepEqual(ctx.dictionary,[]);assert.equal(ctx.trace.disabled,true);
 const intact=await personalizationContext({personalization:policy()},['Acme'],{referenceData(){throw Error('fixture')}},'Acme');assert.deepEqual(intact.dictionary,['Acme']);
});
test('service legacy manual pairs remain soft references, no automatic word learning or forced replacement',async()=>{
 const calls=[];const service=new VoicePolishService({recognizer:{snapshot:()=>({ready:true})},config:{strength:'prompt',dictionary:[],timeoutMs:5000,maxOutputTokens:800,redactSecrets:true},logger:{warn(){}},fetchImpl:async(_,init)=>{calls.push(JSON.parse(init.body));return {ok:true,status:200,json:async()=>({choices:[{message:{content:JSON.stringify({status:'ok',text:'我想买 LG 电脑。'})},finish_reason:'stop'}]})};}});
 const result=await service.polish({rawText:'我想买 LG 电脑',strength:'prompt',dictionary:['LG=ROG',{local:'LG=ROG'}],llm:{baseURL:'https://api.example.com/v1',model:'fake',apiKey:'sk-test-123456789012'}});
 assert.equal(result.text,'我想买 LG 电脑。');assert.deepEqual(result.suggestions,[]);assert.ok(!calls[0].messages[0].content.includes('LG=ROG'));
});

test('conflicting and chained rules cannot silently choose a different final term',async()=>{
 const conflict=policy({rules:[{id:'a',heard:'Acmee',word:'Acme',enabled:true},{id:'b',heard:'Acmee',word:'Other',enabled:true}]});
 const c=await personalizationContext({personalization:conflict},[],null,'联系 Acmee');
 const r=applyExplicitRules({raw:'联系 Acmee',text:'联系 Acmee。'},c,'联系 Acmee','prompt');assert.equal(r.text,'联系 Acmee。');assert.equal(r.personalization.replacements.length,0);assert.equal(r.personalization.blocked.length,2);
});
test('exclusions never leave the local policy envelope and disabled retry uses no examples or style',async()=>{
 const calls=[];
 const service=new VoicePolishService({recognizer:{snapshot:()=>({ready:true})},extension,config:{strength:'concise',dictionary:[],timeoutMs:5000,maxOutputTokens:800,redactSecrets:true},logger:{warn(){}},fetchImpl:async(_,init)=>{calls.push(JSON.parse(init.body));return {ok:true,status:200,json:async()=>({choices:[{message:{content:JSON.stringify({status:'ok',text:'请发送会议报告。'})},finish_reason:'stop'}]})};}});
 const example={id:'fixture',raw:'请发送会议报告',aiText:'发送报告',correctedText:'请发送会议报告。',confirmed:true,enabled:true};
 const result=await service.polish({rawText:'请发送会议报告',strength:'concise',dictionary:['PrivateBlockedTerm',{personalization:policy({disabled:true,excluded:['PrivateBlockedTerm']})}],preferenceExamples:[example],llm:{baseURL:'https://api.example.com/v1',model:'fake',apiKey:'sk-test-123456789012'}});
 const serialized=JSON.stringify(calls[0].messages);assert.ok(!serialized.includes('PrivateBlockedTerm'));assert.ok(!serialized.includes('USER-CONFIRMED WORDING'));assert.ok(!serialized.includes('Use short sentences.'));assert.equal(calls.length,1);assert.equal(result.personalization.disabled,true);
});
test('a result inserted without confirmation keeps the one-shot personalization opt-out',async()=>{
 const service=new VoicePolishService({recognizer:{snapshot:()=>({ready:true})},config:{dictionary:[]}});
 const result=await service.polish({rawText:'正文。备注：缺少结束词',strength:'concise',explanationMarkers:'note',supportsClarification:true,personalization:policy({disabled:true})});
 assert.equal(result.clarification,undefined);
 assert.deepEqual(result.personalization.references,[],'nothing personal is used');
});

test('removing a personal term differs from excluding its extension sources',async()=>{
 const removed=await personalizationContext({personalization:policy()},[],extension,'ROG 电脑');assert.ok(removed.dictionary.includes('ROG'));
 const blocked=await personalizationContext({personalization:policy({excluded:['ROG']})},[],extension,'ROG 电脑');assert.ok(!blocked.dictionary.includes('ROG'));
});
test('case-only correction also needs explicit permission and reports a real change',async()=>{
 const context=await personalizationContext({personalization:policy({rules:[{id:'case',heard:'acmecorp',word:'AcmeCorp',enabled:true}]})},[],null,'ask acmecorp');
 const result=applyExplicitRules({raw:'ask acmecorp',text:'ask acmecorp'},context,'ask acmecorp','prompt');assert.equal(result.text,'ask AcmeCorp');assert.equal(result.personalization.replacements.length,1);
});

test('malformed optional provider data falls back without dropping the current text',async()=>{
 const service=new VoicePolishService({recognizer:{snapshot:()=>({ready:true})},config:{dictionary:[],redactSecrets:true},extension:{referenceData:()=>null}});
 // A faulty provider getter loses only its optional influence.
 service.extension={referenceData:()=>({get terms(){throw Error('fixture provider failure');}})};
 const request={personalization:policy()};const context=await service.buildContext(request,'保留当前文字');
 assert.deepEqual(context.dictionary,[]);assert.equal(request._personalization.trace.disabled,true);
});
