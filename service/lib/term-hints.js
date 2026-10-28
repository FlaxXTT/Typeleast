/** Conservative boundaries for common English words that can also name products or tools. */
export const AMBIGUOUS_TERMS = new Set([
  'apple', 'azure', 'bash', 'claude', 'cloud', 'cursor', 'docker', 'go', 'java', 'llama',
  'notion', 'prompt', 'python', 'react', 'rust', 'sora', 'swift', 'windows', 'word', 'yarn',
]);
const PHONETIC_COLLISIONS = new Set([...AMBIGUOUS_TERMS, 'json']);

const CLAUSE_BREAK = /[.!?。！？；;\n]/u;
const escape = s => s.replace(/[.*+?^${}()|[\]\\]/gu, '\\$&');

/** A literal whole Latin word or a literal Chinese phrase, never a substring of another word. */
function* occurrences(text, literal) {
  const latin = !/[\u3400-\u9fff\uf900-\ufaff]/u.test(literal);
  const pattern = latin
    ? new RegExp(`(?<![\\p{L}\\p{N}_])${escape(literal)}(?![\\p{L}\\p{N}_])`, 'giu')
    : new RegExp(escape(literal), 'gu');
  for (const match of text.matchAll(pattern)) yield match.index;
}

function cueNear(text, offset, heardLength, cues, blockers = []) {
  let start = Math.max(0, offset - 48);
  let end = Math.min(text.length, offset + heardLength + 48);
  for (let i = offset - 1; i >= start; i--) if (CLAUSE_BREAK.test(text[i])) { start = i + 1; break; }
  for (let i = offset + heardLength; i < end; i++) if (CLAUSE_BREAK.test(text[i])) { end = i; break; }
  const clause = text.slice(start, end);
  if (blockers.some(cue => !occurrences(clause, cue).next().done)) return false;
  return cues.some(cue => !occurrences(clause, cue).next().done);
}

/** Only this utterance may activate a pack alias; cursor context cannot trigger one. */
export function relevantAliases(aliases, rawText, userEntries = []) {
  if (!Array.isArray(aliases) || !aliases.length || !rawText) return [];
  const text = String(rawText).slice(0, 6000);
  const owned = new Set(userEntries.map(entry => String(entry).split('=')[0].trim().toLowerCase()));
  const found = [];
  const seen = new Set();
  for (const alias of aliases) {
    if (owned.has(alias.heard.toLowerCase())) continue;
    const key = `${alias.heard.toLowerCase()}=${alias.term.toLowerCase()}`;
    if (seen.has(key)) continue;
    let supported = false;
    for (const offset of occurrences(text, alias.heard)) {
      if (cueNear(text, offset, alias.heard.length, alias.cues, alias.blockers)) { supported = true; break; }
    }
    if (supported) {
      found.push({ heard: alias.heard, term: alias.term });
      seen.add(key);
    }
  }
  return found;
}

/** Pack terms with an everyday English meaning need an explicit alias and context instead. */
export function safePackTerms(terms) {
  return terms.filter(term => !PHONETIC_COLLISIONS.has(term.toLowerCase()));
}

export function safeCaseTerms(terms) {
  return terms.filter(term => !AMBIGUOUS_TERMS.has(term.toLowerCase()));
}
