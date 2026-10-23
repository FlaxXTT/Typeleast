/** Local, bounded suggestions from ASR corrections. No I/O except a lazy local library import. */
import { redactSecrets } from './context.js';
let phonetics;
const CJK = /[\u3400-\u9fff\uf900-\ufaff]/u;
const LIMIT = 8;

function tokens(text) {
  const out = [];
  let word = '';
  const flush = () => { if (word) out.push(word.replace(/^[._+#-]+|[._+#-]+$/gu, '')); word = ''; };
  for (const c of text) {
    if (/[a-z0-9]/iu.test(c)) word += c;
    else if (word && '._+#-'.includes(c)) word += c;
    else if (CJK.test(c)) { flush(); out.push(c); }
    else flush();
    if (out.length >= 400) break;
  }
  if (out.length < 400) flush();
  return out.filter(Boolean).slice(0, 400);
}
function join(parts) {
  let result = '';
  for (const part of parts) {
    if (/[a-z0-9]$/iu.test(result) && /^[\x00-\x7f]/u.test(part)) result += ' ';
    result += part;
  }
  return result;
}
function ratio(a, b) {
  if (!a.length && !b.length) return 0;
  let previous = Array.from({length: b.length + 1}, (_, i) => i);
  let current = [...previous];
  for (let i = 1; i <= a.length; i++) {
    current[0] = i;
    for (let j = 1; j <= b.length; j++) current[j] = Math.min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] === b[j - 1] ? 0 : 1));
    [previous, current] = [current, previous];
  }
  return 1 - previous[b.length] / Math.max(a.length, b.length);
}
function reading(text, convert) {
  const words = (CJK.test(text) ? convert(text, { type: 'array', toneType: 'none', nonZh: 'consecutive' }) : [text])
    .flatMap(s => s.toLowerCase().normalize('NFD').replace(/\p{M}/gu, '').match(/[a-z0-9]+/gu) ?? []);
  const full = words.join('');
  return { full, initials: CJK.test(text) || words.length > 1 ? words.map(s => s[0]).join('') : full };
}
function soundScore(heard, word, convert) {
  const a = reading(heard, convert), b = reading(word, convert);
  let score = ratio(a.full, b.full);
  const x = a.full.replace(/[aeiou]/gu, ''), y = b.full.replace(/[aeiou]/gu, '');
  if (x.length >= 3 && y.length >= 3 && Math.min(x.length, y.length) / Math.max(x.length, y.length) >= 0.6) score = Math.max(score, ratio(x, y) * 0.9);
  if (CJK.test(heard) && /^[A-Z]{2,6}$/u.test(word) && a.initials === b.full) score = Math.max(score, 0.9);
  return score;
}
function isTerm(parts) {
  return parts.length >= 1 && parts.length <= 2 &&
    parts.every(s => /[a-z]/iu.test(s) && /^[a-z0-9._+#-]+$/iu.test(s)) &&
    (parts.length === 1 || parts.every(s => /[A-Z]/u.test(s)));
}

export async function wordSuggestions(raw, cleaned) {
  // A credential-shaped string must not become a saved dictionary suggestion.
  const safe = text => redactSecrets(String(text ?? '')).replace(/\[redacted(?:-key|-token)?\]/gu, '');
  const a = tokens(safe(raw)), b = tokens(safe(cleaned));
  if (!a.length || !b.length) return [];
  const table = Array.from({length: a.length + 1}, () => new Uint16Array(b.length + 1));
  for (let i = a.length - 1; i >= 0; i--) for (let j = b.length - 1; j >= 0; j--)
    table[i][j] = a[i] === b[j] ? table[i + 1][j + 1] + 1 : Math.max(table[i + 1][j], table[i][j + 1]);
  const spans = [];
  let i = 0, j = 0, from = [], to = [];
  const close = () => { if (from.length && to.length) spans.push([from, to]); from = []; to = []; };
  while (i < a.length || j < b.length) {
    if (i < a.length && j < b.length && a[i] === b[j]) { close(); i++; j++; }
    else if (j < b.length && (i === a.length || table[i][j + 1] >= table[i + 1][j])) to.push(b[j++]);
    else from.push(a[i++]);
  }
  close();
  const result = [], seen = new Set();
  for (const [heardParts, wordParts] of spans) {
    const heard = join(heardParts), word = join(wordParts);
    if (!isTerm(wordParts) || word.length < 2 || word.length > 30 || heard.length > 30) continue;
    if (heardParts.length === wordParts.length && heardParts.join('').toLowerCase() === wordParts.join('').toLowerCase()) continue;
    const cjk = [...heard].filter(c => CJK.test(c)).length;
    if (cjk > 8 || heardParts.filter(s => /^[\x00-\x7f]/u.test(s)).length > 2) continue;
    const convert = cjk ? (await (phonetics ??= import('pinyin-pro'))).pinyin : null;
    if (soundScore(heard, word, convert) < (cjk ? 0.5 : 0.6)) continue;
    const key = word.toLowerCase();
    if (!seen.has(key)) { result.push({ word, heardAs: heard }); seen.add(key); }
    if (result.length === LIMIT) break;
  }
  return result;
}
