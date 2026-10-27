/** Protect explicit Latin names without treating sentence capitalisation as names. */
import { spelledWords } from './spelling.js';
const ORDINARY = new Set(['OK', 'UM', 'UH', 'NO', 'YES', 'THE', 'AND', 'OR', 'NOT']);
const TOKEN = /(?<![A-Za-z0-9_])[A-Za-z][A-Za-z0-9]*(?![A-Za-z0-9_])/gu;
const escaped = s => s.replace(/[.*+?^${}()|[\]\\]/gu, '\\$&');
const contains = (text, name) => new RegExp(`(?<![A-Za-z0-9_])${escaped(name)}(?![A-Za-z0-9_])`, 'iu').test(text);

/** A local explicit correction can retract a name; a plain negation cannot. */
function retracted(raw, name) {
  const clauses = raw.split(/[。！？;；\n]/u).filter(clause => contains(clause, name));
  return clauses.length > 0 && clauses.every(clause => {
    const correction = /不对|说错了|改成|改为|no,?\s+(?:wait|I mean)/iu.exec(clause);
    if (!correction || /[“「『"][^”」』"]*$/u.test(clause.slice(0, correction.index))) return false;
    const before = clause.slice(0, correction.index), after = clause.slice(correction.index + correction[0].length);
    return contains(before, name) && !contains(after, name) && explicitNames(after).length > 0;
  });
}
export function explicitNames(text) {
  return [...String(text).matchAll(TOKEN)].map(m => m[0]).filter(word =>
    !ORDINARY.has(word) && (/^[A-Z][A-Z0-9]{1,15}$/u.test(word) || /[a-z][A-Z]/u.test(word)));
}

export function missingNames(raw, output, evidence = []) {
  return [...new Set(explicitNames(raw))].filter(name => {
    if (contains(output, name) || retracted(raw, name)) return false;
    const clauses = String(raw).split(/[。！？;；\n]/u).filter(clause => contains(clause, name));
    if (clauses.length && clauses.every(clause => spelledWords(clause).some(s => {
      const before = clause.slice(0, clause.indexOf(s.spelled));
      return /拼法|拼写|拼一下|英文是|spell|letters/iu.test(before)
        && explicitNames(before).at(-1)?.toLowerCase() === name.toLowerCase() && contains(output, s.word);
    }))) return false;
    // Only an exact, explicit heard-as rule can authorise a replacement here.
    return !evidence.some(entry => {
      if (typeof entry !== 'string') return false;
      const at = entry.indexOf('=');
      const target = entry.slice(at + 1).trim();
      return at > 0 && target.length > 0 && entry.slice(0, at).trim().toLowerCase() === name.toLowerCase()
        && contains(output, target);
    });
  });
}

/** Newly introduced acronyms need current text or a literal spelling, not a category guess. */
export function unsupportedNames(raw, output, evidence = []) {
  const spellings = spelledWords(raw);
  return [...new Set(explicitNames(output))].filter(name => !contains(raw,name)
    && !spellings.some(item => item.word.toLowerCase() === name.toLowerCase())
    && !evidence.some(entry => {
      if (typeof entry !== 'string') return false;
      const at = entry.indexOf('=');
      return at > 0 && contains(raw,entry.slice(0,at).trim()) && entry.slice(at+1).trim().toLowerCase() === name.toLowerCase();
    }));
}

/** Evidence that the speaker is explaining a term, not merely naming a product category. */
export function hasTermExplanation(raw) {
  return /(?:我(?:这个|的)?(?:单词|专有名词)|我(?:说|指)的|(?:这个|那个|该)(?:词|单词|名词|名称|名字|缩写|专有名词)|它的?(?:拼法|拼写|全称|意思))[^。！？!?\n]{0,64}(?:指的是|是指|意思|全称|拼|叫|是)|我是指|(?:this|that) (?:word|term|name|acronym)[^.?!\n]{0,64}(?:mean|refer|spell|stand)/iu.test(String(raw));
}
