/**
 * Letter-by-letter spellings in an utterance ("拼法是 R-O-G", "我拼一下 r o g").
 *
 * Small models often miss that separated letters spell one word. Finding them
 * here lets the prompt name the word only when the utterance contains one,
 * instead of carrying a long instruction on every request.
 *
 * @module typeleast-service/spelling
 */

/** Single letters joined throughout by hyphens, dots or commas, or throughout by spaces. */
const LETTER_RUN = /(?<![\p{L}\p{N}_])\p{Script=Latin}(?:(?:[ \t]*[-‐–.,，、·][ \t]*\p{Script=Latin})+|(?:[ \t]+\p{Script=Latin})+)(?![\p{L}\p{N}_])/gu;
const HYPHENS_ONLY = /^\p{L}(?:[ \t]*[-‐–][ \t]*\p{L})+$/u;
/** Words that announce a spelling. */
const CUE = /拼法|拼写|拼一下|拼成|拼作|字母|英文是|英文叫|写作|spell|letters?\b/iu;
const CLAUSE_BREAK = /[。！？；;!?\n]/u;
const MAX_LETTERS = 20;
const MAX_SPELLINGS = 5;

/** The clause around a match, so a cue in another sentence does not count. */
function clauseAround(text, start, end) {
  let from = Math.max(0, start - 24);
  let to = Math.min(text.length, end + 24);
  for (let i = start - 1; i >= from; i--) if (CLAUSE_BREAK.test(text[i])) { from = i + 1; break; }
  for (let i = end; i < to; i++) if (CLAUSE_BREAK.test(text[i])) { to = i; break; }
  return text.slice(from, to);
}

/**
 * Spellings found in the text, each with the word its letters make.
 * Three or more hyphenated letters ("A-B-C") count on their own; any other run
 * needs a spelling cue in the same clause, so "A-B 测试" or "x y 轴" stay ordinary.
 * @param {string} text - the recognised utterance.
 * @returns {Array<{spelled: string, word: string}>} at most five, in order.
 */
export function spelledWords(text) {
  const source = String(text ?? "").slice(0, 6000);
  const found = [];
  const seen = new Set();
  for (const match of source.matchAll(LETTER_RUN)) {
    const spelled = match[0];
    const letters = spelled.replace(/[^\p{L}]/gu, "");
    if (letters.length < 2 || letters.length > MAX_LETTERS) continue;
    const standalone = letters.length >= 3 && HYPHENS_ONLY.test(spelled);
    if (!standalone && !CUE.test(clauseAround(source, match.index, match.index + spelled.length))) continue;
    if (seen.has(spelled)) continue;
    seen.add(spelled);
    found.push({ spelled, word: letters });
    if (found.length === MAX_SPELLINGS) break;
  }
  return found;
}
