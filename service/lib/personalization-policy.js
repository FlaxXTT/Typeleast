/** Only wording examples and optional styles remain; legacy vocabulary cannot regain effect. */
import {redactSecrets} from './context.js';
export function requestPolicy(request) {
  if(request.personalization!==undefined)return request.personalization;
  const blocks=(Array.isArray(request.dictionary)?request.dictionary:[]).filter(x=>x&&typeof x==='object'&&Object.hasOwn(x,'personalization'));
  return blocks.length===1?blocks[0].personalization:blocks.length>1?{version:1,disabled:true}:null;
}
export function readPolicy(input) {
 return {disabled:input!=null&&(typeof input!=='object'||input.version!==1||input.disabled===true),rules:[],excluded:new Set()};
}
export async function personalizationContext(request,_configured,extension) {
 const policy=readPolicy(requestPolicy(request));
 const trace={disabled:policy.disabled,references:[],replacements:[],blocked:[]};
 let style=null;
 if(!policy.disabled)try {const candidate=extension?.referenceData?.()?.style;if(candidate&&typeof candidate.instructions==='string'&&redactSecrets(candidate.instructions)===candidate.instructions)style=candidate;}catch{}
 return {dictionary:[],aliases:[],style,policy,trace};
}
export function applyExplicitRules(result,context) {
 return {...result,personalization:context?.trace??{disabled:false,references:[],replacements:[],blocked:[]}};
}
