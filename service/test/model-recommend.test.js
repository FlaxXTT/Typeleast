import test from 'node:test';
import assert from 'node:assert/strict';
import { ModelRecommender, modelSourceFor, documentedProductSettings, pageText } from '../lib/tasks/model-recommend.js';

const route = {baseURL:'https://api.example.com/v1', model:'fictional', apiKey:'test-only-key'};
const claudePage = 'Available models Opus 4.6 and Sonnet 4.6. '.repeat(5)
  + ' Adjust effort level Model Levels Opus 4.6 and Sonnet 4.6 low medium high max. '
  + 'Adaptive reasoning: On Opus 4.6 and Sonnet 4.6 this can be configured. Toggle for the current session Press Option+T.';
const codexPage = 'Codex GPT-6 Astra offers task reasoning levels. '.repeat(6)
  + 'GPT-6 Astra Model ID gpt-6-astra Reasoning low medium high xhigh max Input price $10 ' + 'GPT-6.1 Sol Model ID gpt-6.1-sol Reasoning low medium high xhigh max Input price $2';
function harness(page, reply, redirect = '', now = Date.now) {
  let pageCalls = 0, modelCalls = 0, lastOptions, lastFetchOptions;
  const recommender = new ModelRecommender({
    fetchImpl: async (url, options) => { pageCalls++; lastFetchOptions = options; return {ok:true,url:redirect || url,text:async()=>page}; },
    complete: async options => { modelCalls++; lastOptions = options; return {text:JSON.stringify(reply)}; },
    redact: text => text.replace('fictional-secret','[redacted]'),
    now,
  });
  return {recommender, stats:()=>({pageCalls,modelCalls,lastOptions,lastFetchOptions})};
}

test('identifies the target product rather than its API or a different app', () => {
  assert.equal(modelSourceFor('com.openai.codex','').id,'codex');
  assert.equal(modelSourceFor('com.openai.chat','').id,'openai');
  assert.equal(modelSourceFor('com.apple.Terminal','Claude Code').id,'claude-code');
  assert.notEqual(modelSourceFor('com.google.Chrome','Claude Code - unrelated search')?.id,'claude-code');
  assert.notEqual(modelSourceFor('com.google.Chrome','Codex - unrelated search')?.id,'codex');
  assert.equal(modelSourceFor('com.anthropic.claudefordesktop','Claude').id,'claude');
});

test('only emits documented product and model settings in the existing model call', async () => {
  const h=harness(claudePage,{model:'Opus 4.6',reason:'复杂任务',effort:'high',thinking:'on',effortReason:'约束较多'});
  const result=await h.recommender.recommend({llm:route,appHint:'com.apple.Terminal',windowTitle:'Claude Code',task:'实现 fictional-secret'});
  assert.equal(result.recommendation.effort,'high');
  assert.equal(result.recommendation.thinking,'on');
  assert.equal(result.recommendation.effortReason,'约束较多');
  assert.equal(result.recommendation.capabilitySource,'https://code.claude.com/docs/en/model-config');
  assert.equal(h.stats().modelCalls,1);
  assert.equal(h.stats().pageCalls,1);
  assert.equal(JSON.parse(h.stats().lastOptions.user).task,'实现 [redacted]');
});

test('same provider API page is not evidence that a desktop product has those controls', async () => {
  const page='Opus 4.6 low medium high adaptive reasoning. '.repeat(10);
  const h=harness(page,{model:'Opus 4.6',reason:'test',effort:'high',thinking:'adaptive',effortReason:'test'});
  const result=await h.recommender.recommend({llm:route,appHint:'com.anthropic.claudefordesktop',task:'虚构任务'});
  assert.equal(result.recommendation.model,'Opus 4.6');
  assert.equal(result.recommendation.effort,undefined);
  assert.equal(result.recommendation.thinking,undefined);
  assert.equal(result.recommendation.effortReason,undefined);
  assert.equal(result.recommendation.capabilitySource,undefined);
});

test('unverified models, settings, and ambiguous product pages fail closed', async () => {
  for (const [model,effort,thinking] of [['Opus 4.6','max','adaptive'],['Opus 4.6','LOW ','other'],['Sonnet 4.5','high','adaptive']]) {
    const h=harness(claudePage + ' Sonnet 4.5', {model,reason:'test',effort,thinking,effortReason:'because'});
    const result=await h.recommender.recommend({llm:route,appHint:'com.apple.Terminal',windowTitle:'Claude Code',task:'虚构任务'});
    if (model==='Opus 4.6' && effort==='LOW ') { assert.equal(result.recommendation.effort,'low'); assert.equal(result.recommendation.thinking,undefined); }
    else { assert.equal(result.recommendation.effort,undefined); assert.equal(result.recommendation.thinking,undefined); assert.equal(result.recommendation.capabilitySource,undefined); }
  }
  assert.deepEqual(documentedProductSettings({id:'claude-code',url:'https://code.claude.com/docs/en/model-config'},'Opus 4.6','Opus 4.6 medium high'),{effort:[],thinking:[]});
});

test('current documented Claude Code models support effort without inventing a thinking switch', async () => {
  const page = claudePage + ' Adjust effort level Model Levels Opus 5.5, Sonnet 5.5, Haiku 5.5, Opus 5, Sonnet 5, Opus 4.8, and Opus 4.7 low medium high xhigh max. ';
  const h=harness(page,{model:'Sonnet 5.5',reason:'test',effort:'high',thinking:'off',effortReason:'复杂任务'});
  const result=await h.recommender.recommend({llm:route,appHint:'com.apple.Terminal',windowTitle:'Claude Code',task:'虚构任务'});
  assert.equal(result.recommendation.effort,'high');
  assert.equal(result.recommendation.thinking,undefined);
});

test('Codex recommends only settings documented for that exact model', async () => {
  const h=harness(codexPage,{model:'GPT-6 Astra',reason:'test',effort:'medium',thinking:'on',effortReason:'兼顾速度和难度'});
  const result=await h.recommender.recommend({llm:route,appHint:'com.openai.codex',task:'虚构任务'});
  assert.equal(result.recommendation.effort,'medium');
  assert.equal(result.recommendation.thinking,undefined);
  assert.match(result.recommendation.capabilitySource,/^https:\/\/help\.openai\.com\//u);
  assert.match(result.recommendation.capabilityModelSource,/gpt-6-astra/u);
  const unsupported=harness(codexPage,{model:'GPT-6 Astra',effort:'max',thinking:'off'});
  const second=await unsupported.recommender.recommend({llm:route,appHint:'com.openai.codex',task:'虚构任务'});
  assert.equal(second.recommendation.effort,undefined);
  assert.equal(second.recommendation.thinking,undefined);
  const sol=harness(codexPage,{model:'GPT-6.1 Sol',effort:'high',thinking:'on'});
  const third=await sol.recommender.recommend({llm:route,appHint:'com.openai.codex',task:'虚构任务'});
  assert.equal(third.recommendation.effort,'high');
  assert.equal(third.recommendation.thinking,undefined);
  assert.equal(third.recommendation.capabilityBasis,'verified-reference');
  assert.equal(third.recommendation.capabilityVerifiedAt,'2026-11-06');
});

test('expired or future-dated Codex product evidence cannot yield settings', async () => {
  for (const iso of ['2027-02-04T00:00:00Z','2026-11-05T23:59:59Z']) {
    const h=harness(codexPage,{model:'GPT-6.1 Sol',effort:'high',thinking:'on',effortReason:'test'},'',()=>Date.parse(iso));
    const result=await h.recommender.recommend({llm:route,appHint:'com.openai.codex',task:'虚构任务'});
    assert.equal(result.recommendation.model,'GPT-6.1 Sol');
    assert.equal(result.recommendation.effort,undefined);
    assert.equal(result.recommendation.capabilitySource,undefined);
    assert.equal(result.recommendation.capabilityBasis,undefined);
    assert.equal(JSON.parse(h.stats().lastOptions.user).settingsEvidence,undefined);
    assert.equal(h.stats().modelCalls,1);
  }
});

test('long Claude Code pages retain the relevant capability section within the bound', () => {
  const result=pageText('intro '.repeat(5000)+' Adjust effort level Opus 4.6 and Sonnet 4.6 low medium high max.','claude-code');
  assert.ok(result.length <= 24000);
  assert.match(result,/Opus 4\.6 and Sonnet 4\.6 low medium high/u);
});

test('cross-domain redirects are not treated as official evidence', async () => {
  const h=harness(claudePage,{model:'Opus 4.6'},'https://example.com/not-official');
  const result=await h.recommender.recommend({llm:route,appHint:'com.apple.Terminal',windowTitle:'Claude Code',task:'虚构任务'});
  assert.equal(result.notice,'page-unavailable');
  assert.equal(h.stats().modelCalls,0);
  assert.equal(h.stats().pageCalls,1);
  assert.equal(h.stats().lastFetchOptions.redirect,'manual');
});

test('only follows same-origin HTTPS redirects and never requests another origin', async () => {
  const seen=[];
  const source={id:'claude-code',url:'https://code.claude.com/docs/en/model-config.md'};
  const model=new ModelRecommender({
    fetchImpl:async (url, options)=>{seen.push({url,redirect:options.redirect});if(seen.length===1)return {ok:false,status:302,url,headers:{get:()=>'/docs/en/model-config-v2.md'}};return {ok:true,status:200,url,text:async()=>claudePage};},
    complete:async()=>({text:'{}'}),redact:x=>x,
  });
  assert.ok(await model.page(source));
  assert.equal(seen.length,2);
  assert.equal(seen[0].redirect,'manual');
  assert.equal(seen[1].url,'https://code.claude.com/docs/en/model-config-v2.md');
  const targets=['https://evil.example/steal','http://code.claude.com/x','https://code.claude.com:8443/x','https://user@code.claude.com/x'];
  for(const target of targets) {
    const requested=[];
    const bad=new ModelRecommender({fetchImpl:async (url,options)=>{requested.push(url);return {ok:false,status:302,url,headers:{get:()=>target}};},complete:async()=>({text:'{}'}),redact:x=>x});
    assert.equal(await bad.page(source),null);
    assert.deepEqual(requested,[source.url]);
  }
});
