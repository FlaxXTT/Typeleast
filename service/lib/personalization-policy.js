/** Per-request policy. Optional packs provide data; only this module grants its effect. */
import { relevantEntries } from './dictionary-relevance.js';
import { relevantAliases, safePackTerms } from './term-hints.js';
import { redactSecrets } from './context.js';
import { validateOutput } from './validate.js';

const key = value => String(value ?? '').normalize('NFKC').trim().toLowerCase();
const word = value => typeof value === 'string' && value.trim().length > 0 && value.length <= 120 && !/[\p{Cc}=]/u.test(value) ? value.trim() : null;
const target = value => String(value).split('=').at(-1).trim();
const literal = value => value.replace(/[.*+?^${}()|[\]\\]/gu,'\\$&');
const pattern = value => new RegExp(/[\u3400-\u9fff]/u.test(value) ? literal(value) : `(?<![\\p{L}\\p{N}_])${literal(value)}(?![\\p{L}\\p{N}_])`,'giu');
const constrained = text => /不|没|别|纠正|改口|说错|而是|改成|改为|拼写|逐字|如果|除非|只|必须|至少|至多|\b(?:no|not|never|instead|unless|if|only|must|spelled|spell|rather|i mean|actually|wait|at least|at most)\b/iu.test(text);
export function requestPolicy(request) {
  if (request.personalization !== undefined) return request.personalization;
  const blocks = (Array.isArray(request.dictionary) ? request.dictionary : []).filter(x => x && typeof x === 'object' && Object.hasOwn(x,'personalization'));
  return blocks.length === 1 ? blocks[0].personalization : blocks.length > 1 ? {version:1,disabled:true} : null;
}
export function readPolicy(input) {
  // Bad optional state never expands privileges or stops speech.
  if (!input) return {disabled:false,excluded:new Set(),rules:[]};
  if (typeof input !== 'object' || input.version !== 1) return { disabled:true, excluded:new Set(), rules:[] };
  if ((input.excluded!==undefined&&!Array.isArray(input.excluded))||(input.rules!==undefined&&!Array.isArray(input.rules)))return {disabled:true,excluded:new Set(),rules:[]};
  const excluded = new Set((Array.isArray(input.excluded) ? input.excluded : []).slice(0,512).filter(word).map(key));
  const rules=[];
  for(const rule of (Array.isArray(input.rules) ? input.rules : []).slice(0,128)) {
    if(!rule || rule.enabled!==true || !word(rule.heard) || !word(rule.word) || typeof rule.id!=='string' || !rule.id || rule.id.length>80)continue;
    if(excluded.has(key(rule.heard))||excluded.has(key(rule.word))||rule.heard===rule.word)continue;
    if(redactSecrets(rule.heard)!==rule.heard||redactSecrets(rule.word)!==rule.word)continue;
    rules.push({id:rule.id,heard:rule.heard,word:rule.word});
  }
  const conflicts=rules.filter(rule=>rules.some(other=>key(other.heard)===key(rule.heard)&&key(other.word)!==key(rule.word)));
  return {disabled:input.disabled===true,excluded,rules:rules.filter(rule=>!conflicts.includes(rule)).sort((a,b)=>b.heard.length-a.heard.length),blocked:conflicts.map(rule=>({...rule,reason:'conflicting-rules'}))};
}
export async function personalizationContext(request, configured, extension, rawText) {
  const policy=readPolicy(requestPolicy(request));
  const trace={disabled:policy.disabled,references:[],replacements:[],blocked:policy.blocked??[]};
  if(policy.disabled)return {dictionary:[],aliases:[],style:null,policy,trace};
  const candidates=[];
  for(const entry of configured) {
    const spelling=word(target(entry));
    if(spelling&&!policy.excluded.has(key(spelling)))candidates.push({word:spelling,source:'personal',sourceId:'personal'});
  }
  let pack={terms:[],aliases:[],style:null};
  try { pack=extension?.referenceData?.() ?? pack; } catch { /* An optional pack is not a dependency of speech. */ }
  for(const entry of (Array.isArray(pack.terms)?pack.terms:[]).slice(0,2000)) {
    if(!entry||!word(entry.word)||policy.excluded.has(key(entry.word)))continue;
    if(!safePackTerms([entry.word]).length)continue;
    const owned = candidates.find(x=>x.source==='personal' && key(x.word)===key(entry.word));
    candidates.push({word:owned?.word??entry.word,source:'extension',sourceId:String(entry.sourceId??'extension').slice(0,80),label:String(entry.label??'').slice(0,120)});
  }
  const texts=[rawText,...Object.values(request.fieldContext??{}).filter(x=>typeof x==='string')];
  const selected=await relevantEntries([...new Set(candidates.map(x=>x.word))],texts);
  const aliases=(Array.isArray(pack.aliases)?pack.aliases:[]).filter(x=>x&&word(x.heard)&&word(x.term)&&!policy.excluded.has(key(x.heard))&&!policy.excluded.has(key(x.term)));
  const activeAliases=relevantAliases(aliases,rawText,selected);
  for(const item of candidates.filter(x=>selected.includes(x.word))) {
    if(redactSecrets(item.word)!==item.word)continue;
    trace.references.push({kind:'term',...item});
  }
  for(const item of activeAliases) {
    const source=aliases.find(x=>x.heard===item.heard&&x.term===item.term);
    trace.references.push({kind:'alias',word:item.term,heard:item.heard,source:'extension',sourceId:source?.sourceId??'extension',label:source?.label??''});
  }
  // Exclusions also apply to whole examples, not only vocabulary lists.
  const excludedText=text=>[...policy.excluded].some(term=>pattern(term).test(String(text).normalize('NFKC')));
  const examples=Array.isArray(request.preferenceExamples)?request.preferenceExamples:null;
  if(examples)request.preferenceExamples=examples.filter(x=>x&&![x.raw,x.aiText,x.correctedText].some(v=>typeof v==='string'&&excludedText(v)));
  const style=pack.style&&typeof pack.style.instructions==='string'&&!excludedText(pack.style.instructions)&&redactSecrets(pack.style.instructions)===pack.style.instructions?pack.style:null;
  return {dictionary:selected,aliases:activeAliases,style,policy,trace,excludedText};
}
export function applyExplicitRules(result, context, rawText, strength) {
  const trace=context?.trace??{disabled:false,references:[],replacements:[],blocked:[]};
  if(!context||context.policy.disabled||result.fallback||result.translated||result.beta?.sessionId||strength==='promptbeta')return {...result,personalization:trace};
  const original=result.text;
  for(const rule of context.policy.rules) {
    if(trace.replacements.some(prior=>pattern(rule.heard).test(prior.word))) {trace.blocked.push({...rule,reason:'chained-rule'});continue;}
    if(!pattern(rule.heard).test(rawText)||!pattern(rule.heard).test(result.text))continue;
    if(constrained(rawText)||(key(rule.word)!==key(rule.heard)&&pattern(rule.word).test(rawText))) {trace.blocked.push({...rule,reason:'current-input-priority'});continue;}
    const changed=result.text.replace(pattern(rule.heard),()=>rule.word);
    if(changed===result.text)continue;
    const verdict=validateOutput({rawText,output:changed,strength,termEvidence:[...context.dictionary,...trace.replacements.map(x=>x.heard+'='+x.word),rule.heard+'='+rule.word]});
    if(!verdict.ok){trace.blocked.push({...rule,reason:'validation'});continue;}
    result.text=verdict.text;trace.replacements.push({...rule});
  }
  if(result.text!==original)trace.beforeReplacements=original;
  return {...result,personalization:trace};
}
