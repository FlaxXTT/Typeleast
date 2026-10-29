/** Explicit, user-selected spoken delimiters. No custom regex or executable configuration. */
import { explicitNames } from './entity-guard.js';

export const EXPLANATION_MARKERS = Object.freeze({
  note: { zh: ['备注', '说完了'], hant: ['備註', '說完了'], en: ['side note', 'back to text'], old1: ['补充背景开始','补充背景结束'], old2: ['解释内容开始','解释内容结束'], old3: ['旁注开始','旁注结束'], old4: ['context note begins','context note ends'], old5: ['explanation begins','explanation ends'], old6: ['aside begins','aside ends'], old7: ['補充背景開始','補充背景結束'], old8: ['解釋內容開始','解釋內容結束'], old9: ['旁註開始','旁註結束'] },
  background: { zh: ['补充背景开始', '补充背景结束'], hant: ['補充背景開始', '補充背景結束'], en: ['context note begins', 'context note ends'] },
  explanation: { zh: ['解释内容开始', '解释内容结束'], hant: ['解釋內容開始', '解釋內容結束'], en: ['explanation begins', 'explanation ends'] },
  aside: { zh: ['旁注开始', '旁注结束'], hant: ['旁註開始', '旁註結束'], en: ['aside begins', 'aside ends'] },
});
const escape = s => s.replace(/[.*+?^${}()|[\]\\]/gu, '\\$&');

export function splitExplanation(raw, selection) {
  const preset = typeof selection === "string" && Object.hasOwn(EXPLANATION_MARKERS, selection) ? EXPLANATION_MARKERS[selection] : null;
  if (!preset) return { text: raw, notes: [], used: false };
  const markers = Object.values(preset).flatMap(([start, end]) => [{ word: start, start: true }, { word: end, start: false }]).sort((a,b)=>b.word.length-a.word.length);
  const pattern = word => /[\u3400-\u9fff]/u.test(word) ? [...word].map(escape).join('[ \t:：，,、]*') : escape(word).replace(/ /gu, '\\s+');
  const normalize = word => /[\u3400-\u9fff]/u.test(word) ? word.replace(/[\s:：，,、]/gu, '') : word.toLowerCase().replace(/\s+/gu, ' ');
  const re = new RegExp(markers.map(m => pattern(m.word)).join('|'), 'giu');
  const parts = [], notes = [];
  let cursor = 0, opened = null, openingWord = null;
  for (const match of raw.matchAll(re)) {
    const marker = markers.find(m => normalize(m.word) === normalize(match[0]));
    if (/^[a-z]/u.test(marker.word) && (/[a-z0-9_]/iu.test(raw[match.index - 1] ?? '') || /[a-z0-9_]/iu.test(raw[match.index + match[0].length] ?? ''))) continue;
    if(selection==='note' && /["“”「」『』]/u.test((raw[match.index-1]??'')+(raw[match.index+match[0].length]??'')))continue;
    if (selection === 'note' && ['备注','備註','说完了','說完了'].includes(normalize(match[0]))) {
      const before=raw[match.index-1], after=raw[match.index+match[0].length];
      if ((before && !/[\s，,。.!！?？:：;；]/u.test(before)) || (after && !/[\s，,。.!！?？:：;；]/u.test(after))) continue;
    }
    if (marker.start) {
      if (opened !== null) return { text: raw, notes: [], used: false, issue: 'nested', evidence: match[0] };
      parts.push(raw.slice(cursor, match.index));
      opened = match.index + match[0].length; openingWord = match[0];
    } else {
      if (opened === null && selection==='note' && ['说完了','說完了','back to text'].includes(normalize(match[0]))) continue;
      if (opened === null) return { text: raw, notes: [], used: false, issue: 'unmatched-end', evidence: match[0] };
      const note = raw.slice(opened, match.index).trim();
      if (!/[\p{L}\p{N}]/u.test(note) || notes.length >= 4 || note.length > 4000) return { text: raw, notes: [], used: false, issue: 'invalid-note', evidence: match[0] };
      notes.push(note); opened = null; cursor = match.index + match[0].length;
    }
  }
  if (opened !== null) return { text: raw, notes: [], used: false, issue: 'unmatched-start', evidence: openingWord };
  if (!notes.length) return { text: raw, notes: [], used: false };
  parts.push(raw.slice(cursor));
  return { text: parts.join(' ').trim(), notes, used: true };
}

/** Only one explicitly explained name may replace one ambiguous source name this time. */
export function explanationNameRule(text, notes) {
  const before = [...new Set(explicitNames(text))];
  const joined = notes.join(' ');
  const after = [...new Set(explicitNames(joined))];
  if (before.length !== 1 || after.length !== 1 || before[0] === after[0]
      || text.toLowerCase().split(before[0].toLowerCase()).length !== 2
      || !/(?:指的是|指代|我说的是|拼法|拼写|全称|英文是|means|refers to|stands for|spelled)/iu.test(joined)) return [];
  return [before[0] + '=' + after[0]];
}

export function explanationInstruction(notes) {
  if (!notes.length) return '';
  return '\n\n=== EXPLANATION DATA FOR THIS UTTERANCE ===\n' + JSON.stringify(notes)
    + '\n以上是用户为本次口述给出的解释资料，用来确定指代、名称和含义；正文只写口述本身的内容。';
}
