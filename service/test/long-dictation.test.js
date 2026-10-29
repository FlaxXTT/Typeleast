import test from 'node:test';
import assert from 'node:assert/strict';
import {partitionText, parseEvidence, generateDictation, TEXT_LIMIT} from '../lib/long-dictation.js';
import {taskFor} from '../lib/dictation-task.js';
import {VoicePolishService} from '../lib/service.js';
import {LocalRecognizer} from '../lib/asr.js';
import {validateConfig} from '../lib/config.js';
import {validateWav} from '../lib/wav.js';

const route = {baseURL:'https://api.example.com/v1',model:'fixture',apiKey:'sk-test-123456789012'};
const completion = text => ({ok:true,status:200,json:async()=>({choices:[{message:{content:text},finish_reason:'stop'}]})});

test('partitions preserve every Unicode character and remain bounded', () => {
  const source = ('第一项保留。second item! 🐈\n').repeat(500);
  const parts = partitionText(source);
  assert.equal(parts.join(''),source);
  assert.ok(parts.length>1);
  assert.ok(parts.every(x=>Array.from(x).length<=2500&&!x.includes('\ufffd')));
});

test('cross-segment evidence must quote this complete source', () => {
  assert.deepEqual(parseEvidence('{"evidence":[]}','原文'),[]);
  assert.equal(parseEvidence('{"evidence":[{"quote":"旧说法","meaning":"改名"}]}','本次最终说法'),null);
  assert.equal(parseEvidence('{"evidence":[{"quote":"","meaning":"改名"}]}','原文'),null);
});

test('long generation is serial and receives late corrections in every part', async () => {
  const source='这是要完整保留的内容。'.repeat(600)+'最后纠正：项目名拼作 Z E P H Y R。';
  const evidence=[{quote:'项目名拼作 Z E P H Y R',meaning:'项目名为 ZEPHYR'}];
  let active=0,maxActive=0;const inputs=[], stages=[];
  const result=await generateDictation({source,system:'rules',parameters:{},progress:x=>stages.push(x),call:async(system,user)=>{
    active++;maxActive=Math.max(active,maxActive);await Promise.resolve();
    let text;
    if(user===source)text=JSON.stringify({evidence});
    else {const part=JSON.parse(user);inputs.push(part);text=JSON.stringify({status:'ok',text:part.text});}
    active--;return {text,attempts:1};
  }});
  assert.equal(maxActive,1);assert.equal(result.segmented,true);
  assert.ok(inputs.length>2);assert.ok(inputs.every(x=>x.evidence[0].quote===evidence[0].quote));
  assert.ok(stages.some(x=>x.completed===inputs.length&&x.total===inputs.length));
  assert.ok(JSON.parse(result.text).text.endsWith('Z E P H Y R。'));
});

test('failure in any part never releases a partial result',async()=>{
  let calls=0;
  await assert.rejects(generateDictation({source:'内容。'.repeat(2500),system:'rules',parameters:{},call:async()=>{
    calls++;if(calls===1)return {text:'{"evidence":[]}'};
    if(calls===2)return {text:'{"status":"ok","text":"第一部分。"}'};
    throw Error('fixture interruption');
  }}),/fixture interruption/);
  assert.equal(calls,3);
});

test('legacy strengths select the same task; explicit invalid tasks fail closed',()=>{
  for(const strength of ['prompt','concise','conservative','maximal','off','promptbrief'])assert.equal(taskFor({strength}),'dictation');
  assert.equal(taskFor({strength:'promptbeta'}),'assistant');
  assert.equal(taskFor({translateTo:'en'}),'translation');
  assert.equal(taskFor({task:'dictation',strength:'promptbeta'}),'dictation');
  assert.throws(()=>taskFor({task:'execute'}),{code:'invalid-task'});
});

test('text beyond the supported limit is retained without calling a model',async()=>{
  let calls=0;const service=new VoicePolishService({config:{},recognizer:{snapshot:()=>({})},fetchImpl:async()=>{calls++;}});
  const raw='字'.repeat(TEXT_LIMIT+1);
  const result=await service.polish({rawText:raw,task:'dictation',llm:route});
  assert.equal(calls,0);assert.notEqual(result.text, '', 'a result is inserted, never held');assert.equal(result.raw,raw);
  assert.equal(result.reason,'text-too-long');
});

for(const seconds of [120,300,600])test(`${seconds}-second audio reaches every fixed-window segment in order`,async()=>{
  const audio=Buffer.alloc(44+seconds*32000);
  audio.write('RIFF');audio.writeUInt32LE(audio.length-8,4);audio.write('WAVE',8);audio.write('fmt ',12);
  audio.writeUInt32LE(16,16);audio.writeUInt16LE(1,20);audio.writeUInt16LE(1,22);audio.writeUInt32LE(16000,24);
  audio.writeUInt32LE(32000,28);audio.writeUInt16LE(2,32);audio.writeUInt16LE(16,34);audio.write('data',36);audio.writeUInt32LE(audio.length-44,40);
  const config=validateConfig({}).value;validateWav(audio,config.maxDurationSeconds);
  const r=new LocalRecognizer({modelsDir:'/unused',language:'auto'});
  r.sherpa={Vad:class{constructor(){throw Error('fixture uses lossless fallback');}}};
  let samples=0,parts=0;
  r.recognizer={createStream:()=>({acceptWaveform:x=>{samples+=x.samples.length;}}),decodeAsync:async()=>({text:`part${++parts}`})};
  const result=await r.transcribe(audio,'auto');
  assert.ok(samples>=seconds*16000);assert.ok(parts>=seconds/20);
  assert.match(result.text,/part1\b/);assert.ok(result.text.endsWith(`part${parts}`));
});

test('VAD receives the final partial window before flushing',()=>{
  const r=new LocalRecognizer({modelsDir:'/unused'});let last;
  r.sherpa={Vad:class{
    acceptWaveform(x){last=x;}isEmpty(){return true;}flush(){};
  }};
  const source=new Float32Array(513);source[512]=0.75;r.split(source);
  assert.equal(last.length,512);assert.equal(last[0],0.75);assert.equal(last[1],0);
});

test('cancellation stops recognition before another segment is decoded',async()=>{
  const r=new LocalRecognizer({modelsDir:'/unused'}),controller=new AbortController();let calls=0;
  r.recognizer={createStream:()=>({acceptWaveform:()=>{}}),decodeAsync:async()=>{calls++;controller.abort();return{text:'late'};}};
  r.split=()=>[new Float32Array(320),new Float32Array(320)];
  const audio=Buffer.alloc(44+21*32000);
  await assert.rejects(r.transcribe(audio,'auto',controller.signal));assert.equal(calls,1);
});

test('progress contains stage counts only, expires, and never contains text',()=>{
  const s=new VoicePolishService({config:{},recognizer:{snapshot:()=>({})}});
  s.setProgress('fixture-id',{stage:'generating',completed:1,total:3,raw:'private'});
  assert.deepEqual(s.taskProgress('fixture-id'),{stage:'generating',completed:1,total:3});
  s.progress.get('fixture-id').updated=0;assert.equal(s.taskProgress('fixture-id').stage,'waiting');
});
