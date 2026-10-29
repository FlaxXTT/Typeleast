import {createDeadline, ModelCallError} from './llm.js';

/** One operation owns its clock and its retries, including transport retries. Long dictations may take five minutes. */
export class CleanupTask {
  constructor(signal, {now=Date.now, totalMs=300000}={}) {
    this.now=now; this.end=now()+totalMs; this.retries=3;
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
  return {maxTokens:Math.min(8192,Math.max(1800,Math.ceil(estimated*1.5+256))),temperature:0.3,timeoutMs:Math.min(config.timeoutMs??300000,300000,Math.max(30000,chars.length*40))};
}
