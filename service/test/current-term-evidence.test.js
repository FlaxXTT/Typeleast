import test from 'node:test';
import assert from 'node:assert/strict';
import {VoicePolishService} from '../lib/service.js';
const route={baseURL:'https://api.example.com/v1',model:'fixture',apiKey:'sk-test-123456789012'};
function fixture(replies) {
 const calls=[];
 return {calls,service:new VoicePolishService({config:{redactSecrets:true},recognizer:{snapshot:()=>({ready:true})},fetchImpl:async(_,init)=>{
  calls.push(JSON.parse(init.body));return {ok:true,status:200,json:async()=>({choices:[{message:{content:replies.shift()},finish_reason:'stop'}]})};
 }})};
}
test('a current free-form term explanation can resolve an ASR name through one bounded review',async()=>{
 const f=fixture(['{"status":"ok","text":"我想买 ROG 电脑。"}','{"issues":[]}']);
 const r=await f.service.polish({rawText:'我想买 LG 电脑，我说的这个词指的是玩家国度那个品牌。',strength:'concise',llm:route});
 assert.equal(r.text,'我想买 ROG 电脑。');assert.equal(r.fallback,false);assert.equal(r.clarification,undefined);assert.equal(f.calls.length,2);
});
test('a category alone never authorizes replacing a valid name',async()=>{
 const f=fixture(['{"status":"ok","text":"我想买 ROG 电脑。"}']);
 const r=await f.service.polish({rawText:'我想买 LG 电脑。',strength:'concise',llm:route});
 assert.equal(r.text,'');assert.equal(r.reason,'name-kept');assert.equal(r.clarification.kind,'quality');assert.equal(f.calls.length,1);
});
test('reviewing a name cannot waive number and condition checks',async()=>{
 const f=fixture(['{"status":"ok","text":"我想买 ROG 电脑，预算 20000 元。"}','{"issues":[]}']);
 const r=await f.service.polish({rawText:'我想买 LG 电脑，我说的这个词指的是玩家国度。预算 10000 元。',strength:'concise',llm:route});
 assert.equal(r.text,'');assert.equal(r.clarification.kind,'quality');assert.equal(r.clarification.reason,'invented-fact');assert.equal(f.calls.length,2);
});
