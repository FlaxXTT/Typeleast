import test from 'node:test';
import assert from 'node:assert/strict';
import {normalizePunctuation} from '../lib/punctuation.js';
import {tidy} from '../lib/tidy.js';
import {CleanupTask,cleanupParameters} from '../lib/cleanup-task.js';
import {VoicePolishService} from '../lib/service.js';
import {completeOpenAI,normalizeRoute} from '../lib/openai-compat.js';
const route={baseURL:'https://api.example.com/v1',model:'fake',apiKey:'sk-test-123456789012'};
const reply=(text,finish='stop')=>({ok:true,status:200,json:async()=>({choices:[{message:{content:text},finish_reason:finish}]})});
function service(handler){return new VoicePolishService({recognizer:{snapshot:()=>({ready:true})},config:{redactSecrets:true,strength:'prompt'},fetchImpl:handler});}
for(const [input,want] of [['先做，。再说。','先做。再说。'],['先做，.再说。','先做。再说。'],['First, .Next.','First. Next.'],['First., next.','First. next.'],['是吗？！然后呢……','是吗？！然后呢……']])test('redundant punctuation: '+input,()=>{const actual=normalizePunctuation(input);assert.equal(actual,want);assert.equal(normalizePunctuation(actual),actual);});
test('punctuation literals, decimal, version, code, paths and numbered lists remain intact',()=>{
 const input='3.14 v1.23.0 https://example.com/a.b /tmp/a.b `x,.` “，。”\n1. First.\n2. Next.\n```js\nx,.\n```';assert.equal(normalizePunctuation(input),input);assert.equal(tidy(input).text,input);
});
test('legacy strengths share parameters and long output has a bounded growing budget',()=>{
 assert.deepEqual(cleanupParameters('短句','prompt'),{maxTokens:1800,temperature:0.3,timeoutMs:30000});
 assert.deepEqual(cleanupParameters('短句','concise'),cleanupParameters('短句','prompt'));
 assert.equal(cleanupParameters('长'.repeat(5000),'prompt').maxTokens,8192);
 assert.equal(cleanupParameters('长'.repeat(32000),'prompt').timeoutMs,300000);
});
test('one clock owns the operation and a shared retry cannot be spent twice',()=>{
 let now=0;const task=new CleanupTask(undefined,{now:()=>now,totalMs:60000});try{assert.equal(task.remainingMs(),60000);assert.equal(task.retry(),true);assert.equal(task.retry(),true);assert.equal(task.retry(),true);assert.equal(task.retry(),false);now=60000;assert.throws(()=>task.assertTime());}finally{task.dispose();}
});
test('risk review includes long text, suspicious compression and omitted condition cues',()=>{
});
test('a truncated model result is held with no insertable text',async()=>{
 const s=service(async()=>reply('半截','length'));const r=await s.polish({rawText:'这是完整口述。',strength:'prompt',llm:route});assert.notEqual(r.text, '', 'a result is inserted, never held');assert.equal(r.clarification, undefined);assert.equal(r.reason,'model-max-tokens');assert.equal(r.raw,'这是完整口述。');
});
test('transient transport retry shares one bounded allowance across model calls',async()=>{
 const task=new CleanupTask();let calls=0;try{
 const fetchImpl=async()=>{calls++;throw Error('fixture outage');};
 await assert.rejects(completeOpenAI({route:normalizeRoute(route),system:'s',user:'u',timeoutMs:10,retryBudget:task,signal:task.signal,fetchImpl}));assert.equal(calls,2);
 await assert.rejects(completeOpenAI({route:normalizeRoute(route),system:'s',user:'u',timeoutMs:10,retryBudget:task,signal:task.signal,fetchImpl}));assert.equal(calls,4);
 await assert.rejects(completeOpenAI({route:normalizeRoute(route),system:'s',user:'u',timeoutMs:10,retryBudget:task,signal:task.signal,fetchImpl}));assert.equal(calls,6);
 await assert.rejects(completeOpenAI({route:normalizeRoute(route),system:'s',user:'u',timeoutMs:10,retryBudget:task,signal:task.signal,fetchImpl}));assert.equal(calls,7,'three retries in all');
 }finally{task.dispose();}
});

test('punctuation cleanup is stable across repeated mixed-mark artifacts',()=>{
 for(const marks of ['，.，.','，,。','。, .','，！？','，...','，……']) {
  const input='说明'+marks+'下一句。';const clean=normalizePunctuation(input);assert.equal(normalizePunctuation(clean),clean,marks);
 }
});

test('permanent authentication failure is held without retry and caller cancellation never delivers a draft',async()=>{
 let calls=0;const s=service(async()=>{calls++;return {ok:false,status:401,text:async()=> 'fixture denied'};});
 const r=await s.polish({rawText:'请发送报告。',strength:'prompt',llm:route});assert.equal(calls,1);assert.notEqual(r.text, '', 'a result is inserted, never held');assert.equal(r.clarification, undefined);
 const ac=new AbortController();ac.abort();const cancelled=await s.polish({rawText:'请发送报告。',strength:'prompt',llm:route,signal:ac.signal});
 assert.equal(cancelled.reason,'cancelled');assert.equal(cancelled.clarification,undefined);assert.equal(calls,1);
});

test('HTTP disconnection aborts the in-flight polish request',async()=>{
 const {Readable}=await import('node:stream');const {EventEmitter}=await import('node:events');const {createHandler}=await import('../lib/http.js');
 let release;const entered=new Promise(r=>release=r);let captured;
 const handler=createHandler({currentToken:async()=> 'fixture-token',service:{polish:async request=>{captured=request.signal;release();await new Promise(r=>captured.addEventListener('abort',r,{once:true}));return {text:'',raw:'fixture',ms:{polish:0}};}}});
 const req=Readable.from([Buffer.from(JSON.stringify({text:'fixture',strength:'prompt'}))]);Object.assign(req,{method:'POST',url:'/api/voice-polish/polish',headers:{host:'127.0.0.1',authorization:'Bearer fixture-token'}});
 const res=new EventEmitter();Object.assign(res,{writeHead(){},end(){},writableEnded:false});
 const running=handler(req,res);await entered;res.emit('close');await running;assert.equal(captured.aborted,true);
});
