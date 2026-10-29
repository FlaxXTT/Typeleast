import {ModelCallError} from './llm.js';
import {parsePolishOutput} from './parse-output.js';

export const TEXT_LIMIT = 32000;
/**
 * Above this a dictation is cleaned in parts: one long call tends to stop structuring halfway.
 * Each part is about CHUNK_SIZE characters and sees OVERLAP characters of its neighbours on both
 * sides (read-only context, as in RAG chunking), so meaning carries across the cut. Up to PARALLEL
 * parts are cleaned at once.
 */
export const CHUNK_THRESHOLD = 1500;
export const CHUNK_SIZE = 1000;
export const OVERLAP = 200;
export const PARALLEL = 4;

/** Unicode-safe, lossless partitions, preferring the last sentence boundary. */
export function partitionText(text, limit = CHUNK_SIZE) {
  const chars = Array.from(text), parts = [];
  for (let start = 0; start < chars.length;) {
    let end = Math.min(start + limit, chars.length);
    if (end < chars.length) {
      for (let i = end - 1; i >= start + Math.floor(limit / 2); i--) {
        if (/[。！？.!?\n]/u.test(chars[i])) { end = i + 1; break; }
      }
    }
    parts.push(chars.slice(start, end).join('')); start = end;
  }
  return parts;
}

const EVIDENCE_PROMPT = `从整段口述中提取名称依据、改口关系和需要跨段保留的条件，供分段整理参考。只记录原文明确说出的依据。只返回 JSON：{"evidence":[{"quote":"原文中连续且逐字存在的依据","meaning":"依据的简短含义"}]}。最多 40 项，每项 quote 不超过 300 字、meaning 不超过 180 字。没有依据时 evidence 为空数组。`;

/** Every accepted hint must have a bounded quotation in this request. */
export function parseEvidence(text, source) {
  let value;
  try { value = JSON.parse(text); } catch { return null; }
  if (!Array.isArray(value?.evidence) || value.evidence.length > 40) return null;
  if (value.evidence.some(x => !x || typeof x.quote !== 'string' || !x.quote.trim() || Array.from(x.quote).length > 300
    || !source.includes(x.quote) || typeof x.meaning !== 'string' || Array.from(x.meaning).length > 180)) return null;
  return value.evidence;
}

/**
 * Join cleaned parts in order. A numbered list cut between two parts keeps counting: when a part
 * ends inside a list and the next one opens with "1.", the next one's leading list continues.
 */
export function joinParts(drafts) {
  const out = [];
  for (const draft of drafts) {
    let text = draft.trim();
    const previous = out.at(-1);
    const lastLine = previous?.split('\n').filter(l => l.trim()).at(-1) ?? '';
    const last = /^\s*(\d+)[.、]\s/u.exec(lastLine);
    if (last && /^\s*1[.、]\s/u.test(text)) {
      const shift = Number(last[1]);
      const lines = text.split('\n');
      for (let i = 0; i < lines.length; i++) {
        const m = /^(\s*)(\d+)([.、]\s)/u.exec(lines[i]);
        if (!m) { if (lines[i].trim()) break; continue; }
        lines[i] = m[1] + (Number(m[2]) + shift) + m[3] + lines[i].slice(m[0].length);
      }
      text = lines.join('\n');
      out[out.length - 1] = previous + '\n' + text;
    } else out.push(text);
  }
  return out.join('\n\n');
}

/** Run `work` over `items` with at most `limit` running at once; results keep their order. */
async function pool(items, limit, work) {
  const results = new Array(items.length);
  let next = 0;
  const worker = async () => { while (next < items.length) { const i = next++; results[i] = await work(items[i], i); } };
  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, worker));
  return results;
}

/** call() owns transport, the shared budget and retry count. No partial delivery. `force` skips the single call. */
export async function generateDictation({source, system, call, parameters, progress = () => {}, force = false}) {
  if (!force && Array.from(source).length <= CHUNK_THRESHOLD) {
    progress({stage:'generating',completed:0,total:1});
    try { return await call(system, source, parameters); }
    catch (error) {
      // 413 is an explicit size rejection. Other 400 errors can be invalid credentials or parameters.
      if (!['HTTP_413','CONTEXT_LIMIT'].includes(error?.code)) throw error;
    }
  }
  progress({stage:'preparing',completed:0,total:0});
  const context = await call(EVIDENCE_PROMPT, source, {...parameters,maxTokens:4096,temperature:0});
  const evidence = parseEvidence(context.text, source);
  if (evidence === null) throw new ModelCallError('error','invalid cross-segment evidence',{code:'invalid-evidence'});
  const parts = partitionText(source);
  let attempts = context.attempts ?? 1, done = 0;
  const segmentSystem = system + '\n这是长口述的一部分。evidence 是全文依据，帮助理解；before 和 after 是相邻原文，只用来衔接，由相邻部分负责整理。正文是 text 从头到尾的整理结果。全文依据里明确的后续改口可以撤回本段的旧说法。';
  progress({stage:'generating',completed:0,total:parts.length});
  const drafts = await pool(parts, PARALLEL, async (text, i) => {
    const before = i > 0 ? Array.from(parts[i - 1]).slice(-OVERLAP).join('') : '';
    const after = i + 1 < parts.length ? Array.from(parts[i + 1]).slice(0, OVERLAP).join('') : '';
    const message = JSON.stringify({part:i+1,total:parts.length,evidence,before,text,after});
    // A malformed part is asked again once before the whole request gives up.
    for (let attempt = 0; ; attempt++) {
      const result = await call(segmentSystem, message, parameters);
      attempts += result.attempts ?? 1;
      const parsed = parsePolishOutput(result.text);
      if (parsed.ok && !parsed.clarification && parsed.text.trim()) {
        progress({stage:'generating',completed:++done,total:parts.length});
        return parsed.text;
      }
      if (attempt >= 1) throw new ModelCallError('error','invalid segment output',{code:'output-format'});
    }
  });
  // The caller applies the fixed formatting to the merged text and inserts it.
  return {text:JSON.stringify({status:'ok',text:joinParts(drafts)}),attempts,segmented:true};
}
