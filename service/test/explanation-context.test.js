import test from 'node:test';
import assert from 'node:assert/strict';
import { splitExplanation, explanationNameRule } from '../lib/explanation-context.js';
import { VoicePolishService } from '../lib/service.js';
const route = { baseURL: 'https://api.example.com/v1', model: 'fake', apiKey: 'sk-test-123456789012' };
function fixture(text) {
 const calls=[];
 const service=new VoicePolishService({recognizer:{snapshot:()=>({ready:true})},config:{strength:'concise',dictionary:[],timeoutMs:5000,maxOutputTokens:800,redactSecrets:true},logger:{warn(){}},
 fetchImpl:async(_,init)=>{calls.push(JSON.parse(init.body));return {ok:true,status:200,json:async()=>({choices:[{message:{content:JSON.stringify({status:'ok',text})},finish_reason:'stop'}]})};}});
 return {service,calls};
}
test('balanced selected markers separate body from explanation, preserving later conditions',()=>{
 const r=splitExplanation('我想买一台 LG 电脑。补充背景开始ROG 指的是玩家国度那个 ROG补充背景结束预算不超过一万元。','background');
 assert.equal(r.used,true);assert.equal(r.notes[0],'ROG 指的是玩家国度那个 ROG');assert.ok(r.text.includes('预算不超过一万元'));assert.ok(!r.text.includes('玩家国度'));
 assert.deepEqual(explanationNameRule(r.text,r.notes),['LG=ROG']);
});
test('unbalanced, empty and nested notes preserve source and request confirmation',()=>{
 for(const raw of ['正文补充背景开始解释','正文补充背景结束','补充背景开始补充背景开始内容补充背景结束','补充背景开始补充背景结束']) {
  const r=splitExplanation(raw,'background');assert.ok(r.issue,raw);assert.equal(r.text,raw);assert.deepEqual(r.notes,[]);
 }
});
test('other presets, disabled settings and literal English word substrings do not strip content',()=>{
 const raw='正文补充背景开始说明补充背景结束';
 assert.equal(splitExplanation(raw,'aside').text,raw);assert.equal(splitExplanation(raw,'').text,raw);
 assert.equal(splitExplanation('precontext note begins hello','background').used,false);
 assert.deepEqual(splitExplanation('Buy a laptop. Context note begins it is for editing. Context note ends Keep the budget.','background').notes,['it is for editing.']);
});
test('generic or conflicting explanation cannot force a name replacement',()=>{
 assert.deepEqual(explanationNameRule('LG 电脑',['只买中国品牌']),[]);
 assert.deepEqual(explanationNameRule('LG 电脑和 LG 屏幕',['ROG 指的是玩家国度']),[]);
 assert.deepEqual(explanationNameRule('LG 电脑',['LG 和 ROG 是两个品牌']),[]);
});
test('AI cleanup uses explicit explanation once, validates main facts and retains raw evidence',async()=>{
 const raw='我想买 LG 电脑，预算不超过一万元。补充背景开始ROG 指的是玩家国度那个 ROG补充背景结束';
 const f=fixture('我想买 ROG 电脑，预算不超过 10000 元。');
 const r=await f.service.polish({rawText:raw,llm:route,strength:'concise',explanationMarkers:'background',supportsClarification:true});
 assert.equal(r.fallback,false);assert.equal(r.raw,raw);assert.equal(r.text,'我想买 ROG 电脑，预算不超过 10000 元。');assert.equal(r.explanation.used,true);
 assert.equal(f.calls.length,1);assert.ok(!f.calls[0].messages[1].content.includes('玩家国度'));assert.ok(f.calls[0].messages[0].content.includes('玩家国度'));
 assert.deepEqual(r.suggestions,[]);
});
test('unified dictation uses current explanation markers for understanding',async()=>{
 const raw='我想买电脑补充背景开始指的是设备补充背景结束';
 const f=fixture(raw);const r=await f.service.polish({rawText:raw,llm:route,strength:'prompt',explanationMarkers:'background'});
 assert.equal(r.explanation.used,true);assert.equal(f.calls[0].messages[1].content,"我想买电脑");
});
test('incomplete markers remain source text without a continuation question',async()=>{
 const f=fixture('正文。');
 const r=await f.service.polish({rawText:'正文补充背景开始解释',llm:route,strength:'concise',explanationMarkers:'background',supportsClarification:true});
 assert.equal(r.text,'正文。');assert.equal(r.clarification,undefined);assert.equal(f.calls.length,1);
 assert.ok(f.calls[0].messages[1].content.includes('补充背景开始解释'));
 const empty=await f.service.polish({rawText:'补充背景开始只有说明补充背景结束',strength:'concise',explanationMarkers:'background'});
 assert.equal(empty.contextOnly,true);assert.equal(empty.text,'');assert.equal(f.calls.length,1);
});

test('traditional markers and ASR spaces have the same scoped meaning',()=>{
 const r=splitExplanation('正文補 充 背 景 開 始這是說明補充背景結束後續正文','background');
 assert.equal(r.used,true);assert.deepEqual(r.notes,['這是說明']);assert.ok(r.text.includes('後續正文'));
 for(const raw of ['正文'+('补充背景开始解释补充背景结束'.repeat(5)),'正文补充背景开始'+('字'.repeat(4001))+'补充背景结束'])assert.ok(splitExplanation(raw,'background').issue);
});
test('provider cannot copy markers or a full explanation into inserted output',async()=>{
 const raw='请购买电脑。补充背景开始仅仅用于说明这个名称的用途补充背景结束';
 for(const output of [raw,'请购买电脑，仅仅用于说明这个名称的用途。']){
  const f=fixture(output);const r=await f.service.polish({rawText:raw,llm:route,strength:'concise',explanationMarkers:'background'});
  assert.equal(r.fallback,true);assert.equal(r.reason,'explanation-leaked');assert.equal(r.text,'请购买电脑。');
 }
});
test('explanation secrets are redacted before any provider message or scoped name rule',async()=>{
 const f=fixture('请购买电脑。');
 await f.service.polish({rawText:'请购买电脑。补充背景开始测试密码 sk-live-1234567890abcdefghijklmno补充背景结束',llm:route,strength:'concise',explanationMarkers:'background'});
 assert.equal(f.calls.length,1);assert.ok(!JSON.stringify(f.calls).includes('sk-live-1234567890abcdefghijklmno'));
});
test('one-shot marker recovery never asks the user to continue speaking',async()=>{
 const f=fixture('请购买电脑。');const r=await f.service.polish({rawText:'请购买电脑。旁注开始说明',llm:route,strength:'concise',explanationMarkers:'aside',supportsClarification:true});
 assert.equal(r.clarification,undefined);assert.equal(r.text,'请购买电脑。');assert.equal(f.calls.length,1);
});

test('unknown and prototype names are inert and punctuation does not become a body',async()=>{
 for(const selection of ['__proto__','constructor','toString',null,{},'unknown'])assert.equal(splitExplanation('正文',selection).text,'正文');
 const f=fixture('');const r=await f.service.polish({rawText:'，补充背景开始只有解释补充背景结束。',strength:'concise',explanationMarkers:'background'});
 assert.equal(r.contextOnly,true);assert.equal(f.calls.length,0);
 assert.ok(splitExplanation('正文补充背景开始。补充背景结束','background').issue);
});

test('short memo markers are scoped, punctuation-tolerant and ordinary mentions remain literal',()=>{
 const raw='我想买电脑。备注：设备用于剪辑，说完了。预算一万元。';
 const result=splitExplanation(raw,'note');assert.equal(result.used,true);assert.ok(result.text.includes('预算'));assert.ok(!result.text.includes('剪辑'));
 for(const text of ['我已经说完了。','请在备注里写预算。','这是一条备注。','请写“备注”两个字。'])assert.equal(splitExplanation(text,'note').used,false,text);
 assert.equal(splitExplanation('正文补充背景：开始，解释补充背景：结束。后文','note').used,true);
 assert.equal(splitExplanation('正文。備註：解釋，說完了。後文','note').used,true);
 assert.equal(splitExplanation('Buy a laptop. Side note: for work. Back to text. Under 10000.','note').used,true);
 assert.ok(splitExplanation('正文。备注：没有结束','note').issue);
});

test('recorded synthetic ASR outputs parse short and legacy markers without leaking explanation',async()=>{
 const {readFile}=await import('node:fs/promises');const fixture=JSON.parse(await readFile(new URL('./fixtures/explanation-asr-v1.json',import.meta.url),'utf8'));
 for(const item of fixture.cases){const r=splitExplanation(item.raw,'note');assert.equal(r.used,true,item.voice+item.variant);assert.ok(r.text.includes('预算'),item.raw);assert.ok(!r.text.includes('剪辑视频'),item.raw);}
});
