/**
 * The word to learn when the user fixes a dictation right after it was pasted. Both apps read
 * the field again and ask here, so the rule exists once. Conservatively:
 *   - only one contiguous correction, short on both sides, and at least two characters
 *     (one changed Chinese character does not say which word it belongs to);
 *   - the replacement must SOUND like what was recognised (pinyin or letters), so a content
 *     edit ("明天" -> "后天") is never mistaken for a spelling fix;
 *   - what is learned is the corrected word as vocabulary, never a hard "always replace A
 *     with B" rule, so a real word like 公式 is never rewritten.
 * Nothing is stored or logged. No I/O except the lazy pinyin import.
 *
 * @module typeleast-service/edit-correction
 */
import { redactSecrets } from './context.js';
import { CJK, pinyinConverter, ratio, reading } from './word-suggestions.js';

/** Longest span, in characters, that can count as one corrected word. */
export const MAX_SPAN = 16;
/** Longest inserted text or edited region looked at; the apps send far less. */
export const MAX_EDIT_CHARS = 20000;
/** Phonetic similarity a correction needs to count as a spelling fix. */
export const MIN_SIMILARITY = 0.5;
export const MIN_LATIN_SIMILARITY = 0.6;

const isWordChar = (c) => typeof c === 'string' && /^[A-Za-z0-9_.-]$/u.test(c);
// Spaces, and the punctuation a latin word may contain but not end with ("DeepSeek." at the
// end of a sentence is DeepSeek).
const trimEdges = (s) => s.replace(/^[\p{Zs}\t]+|[\p{Zs}\t]+$/gu, '').replace(/^[._-]+|[._-]+$/gu, '');
const length = (s) => Array.from(s).length;

/** The single corrected span, or null when the edit is not one short substitution. */
export function correction(inserted, edited) {
  const a = Array.from(inserted), b = Array.from(edited);
  if (inserted === edited || !a.length || !b.length) return null;
  let prefix = 0;
  while (prefix < a.length && prefix < b.length && a[prefix] === b[prefix]) prefix++;
  let suffix = 0;
  while (suffix < a.length - prefix && suffix < b.length - prefix && a[a.length - 1 - suffix] === b[b.length - 1 - suffix]) suffix++;
  let lo = prefix, hiA = a.length - suffix, hiB = b.length - suffix;
  // Pure insertions and deletions are edits, not spelling fixes.
  if (hiA <= lo || hiB <= lo) return null;
  // What actually changed, before growing to a word: the sound check compares this, so a
  // shared neighbour ("天" in 明天/后天) cannot make a content edit look like a spelling fix.
  const coreFrom = a.slice(lo, hiA).join(''), coreTo = b.slice(lo, hiB).join('');
  // Grow to whole latin words. Chinese has no spaces, so a one-character fix (张伟 -> 章伟)
  // cannot tell which word it belongs to; it stays one character and is not learned.
  while (lo > 0 && isWordChar(a[lo - 1]) && (isWordChar(a[lo]) || isWordChar(b[lo]))) lo--;
  while (hiA < a.length && hiB < b.length && isWordChar(a[hiA]) && (isWordChar(a[hiA - 1]) || isWordChar(b[hiB - 1]))) { hiA++; hiB++; }
  const from = trimEdges(a.slice(lo, hiA).join('')), to = trimEdges(b.slice(lo, hiB).join(''));
  if (!from || !to || length(from) > MAX_SPAN || length(to) > MAX_SPAN || to.includes('\n') || !/[\p{L}\p{M}]/u.test(to)) return null;
  return { from, to, coreFrom, coreTo };
}

/**
 * How alike two spellings sound: pinyin for Chinese, letters for everything else, with
 * syllable initials as a second chance ("第四批" ~ "DSH").
 * @param {Function|null} convert - pinyin-pro's converter; needed only for Chinese.
 */
export function similarity(heard, corrected, convert) {
  const a = reading(heard, convert), b = reading(corrected, convert);
  if (!a.full || !b.full) return 0;
  const consonants = (s) => s.replace(/[aeiou]/gu, '');
  return Math.max(
    ratio(a.full, b.full),
    ratio(a.initials, b.initials) * 0.9,
    Math.max(ratio(a.initials, b.full), ratio(a.full, b.initials)) * 0.9,
    // Consonant skeletons: "depuxike" ~ "deepseek" as "dpxk" ~ "dpsk".
    ratio(consonants(a.full), consonants(b.full)) * 0.9,
  );
}

/**
 * The word to add to the dictionary for this edit, or null.
 * @param {unknown} inserted - the text that was pasted.
 * @param {unknown} edited - what became of it in the field.
 * @returns {Promise<string|null>}
 */
export async function learnedWord(inserted, edited) {
  if (typeof inserted !== 'string' || typeof edited !== 'string') return null;
  if (inserted.length > MAX_EDIT_CHARS || edited.length > MAX_EDIT_CHARS) return null;
  const pair = correction(inserted, edited);
  if (!pair || length(pair.to) < 2) return null;
  // A credential-shaped string must not become a dictionary word.
  if (redactSecrets(pair.to) !== pair.to) return null;
  const convert = CJK.test(pair.from + pair.to) ? await pinyinConverter() : null;
  // Chinese is judged on the changed characters; latin on the whole word, since a typo fix
  // changes a single letter of it.
  const chinese = CJK.test(pair.coreFrom + pair.coreTo);
  const score = chinese ? similarity(pair.coreFrom, pair.coreTo, convert) : similarity(pair.from, pair.to, convert);
  // A latin typo fix keeps most of the word; two different words (Monday/Friday) share half.
  return score >= (chinese ? MIN_SIMILARITY : MIN_LATIN_SIMILARITY) ? pair.to : null;
}
