/**
 * Which dictionary entries one dictation needs. The app sends its whole dictionary to this
 * local service; only the entries that this utterance (or the field the user allowed it to
 * read) plausibly mentions go on to the model, so a name or internal term in the dictionary
 * is not sent along with dictations that have nothing to do with it.
 *
 * An entry ("word" or "heard=word") is related when
 *   - the word or its heard-as spelling appears in the text, ignoring case and spacing;
 *   - a Chinese word sounds exactly like part of the text (章伟 / 张伟);
 *   - a latin word sounds like part of the text (DeepSeek / 迪普西克), compared by
 *     consonant skeleton, the way speech recognisers tend to mishear terms.
 * Missing a related entry only loses a spelling hint; sending an unrelated one is the
 * leak this guards against, so the sound checks are deliberately not loose.
 *
 * @module typeleast-service/dictionary-relevance
 */
import { CJK, pinyinConverter, ratio } from './word-suggestions.js';

/** Longest span of syllables or words compared with one entry. */
const MAX_SPAN = 8;
/** Text looked at per dictation: the transcript plus the field context, both already bounded. */
const MAX_TEXT = 6000;

const compact = (s) => s.toLowerCase().replace(/[\s\p{P}\p{S}]/gu, '');
// Consonants only, with "c" read as "k" (Claude / 克劳德).
const skeleton = (s) => s.replace(/c/gu, 'k').replace(/[aeiou]/gu, '');

/** Lowercase latin units: one pinyin syllable per Chinese character, one token per latin word. */
function units(text, convert) {
  const parts = CJK.test(text) ? convert(text, { type: 'array', toneType: 'none', nonZh: 'consecutive' }) : [text];
  return parts.flatMap((s) => s.toLowerCase().normalize('NFD').replace(/\p{M}/gu, '').match(/[a-z0-9]+/gu) ?? []);
}

/** Every span of up to MAX_SPAN units, as joined readings and by skeleton length. */
function spans(list) {
  const readings = new Set();
  const skeletons = new Map();
  for (let i = 0; i < list.length; i++) {
    let joined = '';
    for (let n = 0; n < MAX_SPAN && i + n < list.length; n++) {
      joined += list[i + n];
      readings.add(joined);
      const key = skeleton(joined);
      if (!skeletons.has(key.length)) skeletons.set(key.length, new Set());
      skeletons.get(key.length).add(key);
    }
  }
  return { readings, skeletons };
}

/** A latin word sounds like some span: close consonant skeletons, exact ones for short words. */
function soundsLatin(word, skeletons) {
  const target = skeleton(word);
  if (target.length < 2) return false;
  const short = target.length < 4;
  for (let length = target.length - (short ? 0 : 1); length <= target.length + (short ? 0 : 1); length++) {
    for (const candidate of skeletons.get(length) ?? []) {
      if (short ? candidate === target : ratio(target, candidate) >= 0.75) return true;
    }
  }
  return false;
}

/**
 * The entries one dictation needs, in their original order.
 * @param {string[]} entries - the dictionary for this call ("word" or "heard=word").
 * @param {Array<string|null|undefined>} texts - the transcript and any field context.
 * @returns {Promise<string[]>}
 */
export async function relevantEntries(entries, texts) {
  if (!entries.length) return [];
  const text = texts.filter((t) => typeof t === 'string' && t.length > 0).join('\n').slice(0, MAX_TEXT);
  if (!text) return [];
  const flat = compact(text);
  const needsPinyin = CJK.test(text) || entries.some((entry) => CJK.test(entry));
  const convert = needsPinyin ? await pinyinConverter() : null;
  const { readings, skeletons } = spans(units(text, convert));
  return entries.filter((entry) => {
    const split = entry.indexOf('=');
    const heard = split > 0 ? entry.slice(0, split) : '';
    const word = split > 0 ? entry.slice(split + 1) : entry;
    for (const spelling of [word, heard]) {
      const key = compact(spelling);
      if (key.length > 0 && flat.includes(key)) return true;
    }
    if (CJK.test(word)) {
      const reading = units(word, convert).join('');
      return reading.length > 0 && readings.has(reading);
    }
    const letters = units(word, convert).join('');
    return soundsLatin(letters, skeletons);
  });
}
