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
