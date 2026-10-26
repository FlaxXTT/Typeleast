import { spelledWords } from "./spelling.js";
/** Only current-utterance evidence can open a name question. No sessions or credentials are retained. */
export function nameClarification(value, raw) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return null;
  const question = typeof value.question === 'string' ? value.question.trim() : '';
  const evidence = typeof value.evidence === 'string' ? value.evidence.trim() : '';
  if (!question || question.length > 240 || !evidence || evidence.length > 240 || !raw.includes(evidence)
      || /[\u0000-\u0008\u000b\u000c\u000e-\u001f]/u.test(question + evidence)) return null;
  return { question, evidence };
}

/** Continuations are explicit user input, bounded by the existing JSON prefix limit. */
export function clarificationSource(entries) {
  const sources = Array.isArray(entries) ? entries.filter(e => e && typeof e === 'object' && Object.hasOwn(e, 'clarificationSource')) : [];
  if (!sources.length) return '';
  if (sources.length !== 1 || typeof sources[0].clarificationSource !== 'string' || sources[0].clarificationSource.length > 32000)
    throw Object.assign(new Error('invalid clarification source'), { code: 'invalid-prompt' });
  return sources[0].clarificationSource.trim();
}

/** A short, explicit answer may resolve ONLY the quoted name for this request. */
export function clarificationRule(entries, answer) {
  const source = clarificationSource(entries);
  const item = entries?.find(e => e && typeof e === 'object' && Object.hasOwn(e, 'clarificationSource'));
  const heard = item?.clarificationEvidence;
  if (!source || typeof heard !== 'string' || !heard.trim() || heard.length > 240 || !source.includes(heard)
      || source.toLowerCase().split(heard.toLowerCase()).length !== 2
      || heard.includes('=') || /[\r\n]/u.test(heard)) return [];
  const spellings = spelledWords(String(answer));
  const normalized = spellings.length === 1 ? String(answer).replace(spellings[0].spelled, spellings[0].word) : String(answer);
  const match = normalized.trim().match(/^(?:不对[，,\s]*)?(?:(?:是|我说的是|名字是|名称是|叫|改成|改为|(?:它的|这个名称的)?(?:拼法是|拼写是|英文是)|I mean|it is|the name is)\s*)?([A-Za-z][A-Za-z0-9.+#-]{1,31})[。.!！]?$/iu);
  if (!match || heard.length + match[1].length + 1 > 120) return [];
  return [{ word: match[1], heardAs: heard, source: 'manual' }];
}
