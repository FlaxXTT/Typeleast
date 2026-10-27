import {createDeadline, ModelCallError} from './llm.js';

/** One operation owns its clock and its single retry, including transport retries. */
export class CleanupTask {
  constructor(signal, {now=Date.now, totalMs=60000}={}) {
    this.now=now; this.end=now()+totalMs; this.retries=1;
    this.deadline=createDeadline(signal,totalMs); this.signal=this.deadline.signal;
  }
  remainingMs() { return Math.max(0,this.end-this.now()); }
  retry() { if(this.retries===0||this.signal.aborted||this.remainingMs()===0)return false;this.retries--;return true; }
  assertTime() { if(this.remainingMs()===0||this.deadline.timedOut())throw new ModelCallError('timeout','cleanup budget exhausted');this.signal.throwIfAborted(); }
  dispose() { this.deadline.dispose(); }
}
export function cleanupParameters(text,strength,config={}) {
  const chars=Array.from(text),cjk=chars.filter(c=>/[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}\p{Script=Hangul}]/u.test(c)).length;
  const estimated=Math.ceil(cjk*1.5+(chars.length-cjk)/3);
  return strength==='concise'?{maxTokens:1600,temperature:1,timeoutMs:25000}:{maxTokens:Math.min(4096,Math.max(1800,Math.ceil(estimated*1.5+256))),temperature:0.8,timeoutMs:Math.min(18000,config.timeoutMs??18000)};
}
export function needsCleanupReview(raw,output,metrics={}) {
  const source=Array.from(raw).length;
  const meaningful=s=>(String(s).match(/[\p{L}\p{N}]/gu)??[]).length;
  const constraints=/(?:不要|不能|不得|除非|只有|不超过|\b(?:must not|unless|only if|do not)\b)/iu;
  return source>=600||(meaningful(raw)>=80&&constraints.test(raw)&&!constraints.test(output))||(meaningful(raw)>=80&&meaningful(output)/meaningful(raw)<0.35)||metrics.suspectedOmission===true;
}
