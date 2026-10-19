/**
 * Output validation for polished transcripts.
 *
 * The single most damaging failure of this feature class is a model that
 * "improves" an utterance into something the speaker never said. Every check
 * here exists to catch that, and any failure means the caller falls back to the
 * raw transcript. All functions are pure so they can be tested without a model.
 *
 * @module typeleast-service/validate
 */

const CJK = /[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff\u3040-\u30ff\uac00-\ud7af]/gu;
const LATIN = /[A-Za-z]/g;
const WORD = /[A-Za-z0-9][A-Za-z0-9'\u2019_-]*/g;

/** Words that carry no meaning on their own; excluded from drift measurement. */
const STOP_WORDS = new Set([
  "the", "a", "an", "and", "or", "but", "if", "then", "so", "to", "of", "in", "on", "at",
  "for", "with", "is", "are", "was", "were", "be", "been", "it", "this", "that", "i", "you",
  "we", "they", "he", "she", "my", "your", "our", "their", "as", "by", "from", "not", "no",
]);

/**
 * Remove wrappers a chatty model may add around an otherwise fine answer.
 *
 * A single fenced block is unwrapped rather than rejected: the content is what
 * matters, and rejecting it would silently discard a usable answer. Anything
 * left wrapped is still reported so it can be measured.
 * @param {string} text - raw model output.
 * @returns {{text: string, unwrappedFence: boolean, unwrappedQuotes: boolean}}
 */
export function unwrap(text) {
  let out = String(text ?? "").trim();
  let unwrappedFence = false;
  let unwrappedQuotes = false;
  const fence = out.match(/^```[A-Za-z0-9_-]*\n([\s\S]*?)\n?```$/);
  if (fence) {
    out = fence[1].trim();
    unwrappedFence = true;
  }
  if (out.length >= 2) {
    const first = out[0];
    const last = out[out.length - 1];
    const pairs = [['"', '"'], ["'", "'"], ["\u201c", "\u201d"], ["\u2018", "\u2019"], ["\u300c", "\u300d"]];
    for (const [open, close] of pairs) {
      if (first === open && last === close) {
        const inner = out.slice(1, -1);
        // Only unwrap when the quotes are not part of the content itself.
        if (!inner.includes(close) && !inner.includes(open)) {
          out = inner.trim();
          unwrappedQuotes = true;
          break;
        }
      }
    }
  }
  return { text: out, unwrappedFence, unwrappedQuotes };
}

/**
 * Count meaningful characters after dropping punctuation, whitespace and symbols.
 * @param {string} text - input text.
 * @returns {number} number of letters, digits and CJK characters.
 */
export function contentLength(text) {
  return (String(text ?? "").match(/[\p{L}\p{N}]/gu) ?? []).length;
}

/**
 * Extract comparison units: CJK bigrams plus non-stopword latin words.
 * @param {string} text - input text.
 * @returns {Set<string>} the unit set.
 */
export function units(text) {
  const source = String(text ?? "");
  const set = new Set();
  const cjkOnly = source.replace(/[^\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff\u3040-\u30ff\uac00-\ud7af]/gu, " ");
  for (const run of cjkOnly.split(/\s+/)) {
    if (run.length === 1) set.add(run);
    for (let i = 0; i + 1 < run.length; i += 1) set.add(run.slice(i, i + 2));
  }
  for (const word of source.toLowerCase().match(WORD) ?? []) {
    if (!STOP_WORDS.has(word) && word.length > 1) set.add(word);
  }
  return set;
}

/**
 * Fraction of the source's units that survive in the output.
 * Directional on purpose: a rewrite may compress, but it may not invent.
 * @param {string} source - raw transcript.
 * @param {string} output - polished candidate.
 * @returns {number} coverage in [0, 1]; 1 when the source has no units.
 */
export function coverage(source, output) {
  const from = units(source);
  if (from.size === 0) return 1;
  const to = units(output);
  let hits = 0;
  for (const unit of from) if (to.has(unit)) hits += 1;
  return hits / from.size;
}

/**
 * Fraction of the OUTPUT's units that do not appear in the source.
 *
 * This is the check that catches additive hallucination, which coverage alone
 * misses: a model can keep every original idea and still append a promise the
 * speaker never made, and coverage stays high. Measured on this codebase,
 * legitimate rewrites — self-correction, filler removal, list and prompt
 * restructuring — score 0.00, while an invented clause scores 0.54 and a
 * wholesale fabrication 0.94.
 *
 * @param {string} source - raw transcript.
 * @param {string} output - polished candidate.
 * @returns {number} novelty in [0, 1]; 0 when the output has no units.
 */
export function novelty(source, output) {
  const to = units(output);
  if (to.size === 0) return 0;
  const from = units(source);
  let fresh = 0;
  for (const unit of to) if (!from.has(unit)) fresh += 1;
  return fresh / to.size;
}

/**
 * CJK bigrams only, plus latin words. Chinese has no word boundaries, so whole
 * runs collapse into one token and a fabricated clause can hide inside an
 * otherwise-matching token; bigrams expose it.
 * @param {string} text - input text.
 * @returns {Set<string>} the finer-grained unit set.
 */
export function preciseUnits(text) {
  const source = String(text ?? "");
  const set = new Set();
  const cjkOnly = source.replace(/[^\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff\u3040-\u30ff\uac00-\ud7af]/gu, " ");
  for (const run of cjkOnly.split(/\s+/)) {
    if (run.length === 1) set.add(run);
    for (let i = 0; i + 1 < run.length; i += 1) set.add(run.slice(i, i + 2));
  }
  for (const word of source.toLowerCase().match(WORD) ?? []) if (word.length > 1) set.add(word);
  return set;
}

/**
 * Fraction of the output's fine-grained units absent from the source.
 * @param {string} source - raw transcript.
 * @param {string} output - polished candidate.
 * @returns {number} novelty in [0, 1].
 */
export function preciseNovelty(source, output) {
  const to = preciseUnits(output);
  if (to.size === 0) return 0;
  const from = preciseUnits(source);
  let fresh = 0;
  for (const unit of to) if (!from.has(unit)) fresh += 1;
  return fresh / to.size;
}

/**
 * Concrete facts a rewrite must never invent: numbers, quantities, clock and
 * calendar words, and latin identifiers.
 *
 * Measured on this project's real cases, novelty ratios overlap between a bold
 * legitimate rewrite (0.63) and an added requirement (0.67), so ratios cannot
 * separate them. This class does separate cleanly: restructuring never
 * introduces a new number, date or named identifier, so any new one is
 * fabrication with no false positives.
 *
 * @param {string} text - input text.
 * @returns {Set<string>} normalised fact tokens.
 */
/** Calendar words that name the same day or period ("这周" and "本周"). */
const CALENDAR_SYNONYMS = {
  本周: "这周",
  星期一: "周一", 星期二: "周二", 星期三: "周三", 星期四: "周四", 星期五: "周五", 星期六: "周六",
  星期日: "周日", 周天: "周日",
};

export function factTokens(text) {
  // List labels are layout, not facts: "1. 更新解析器" adds structure, not the
  // number one. Without this every numbered list the user asked for was
  // rejected as an invented fact.
  const source = stripListMarkers(text);
  const set = new Set();
  // Arabic digits and Chinese numerals both count, and both normalise to the
  // same value: "两个平台" and "2 个平台" state the same fact, so rewriting one
  // into the other is not fabrication.
  for (const token of source.match(/\d+(?:[.:/-]\d+)*/g) ?? []) set.add("N:" + token);
  // An ordinal ("第二点", "第三个") is sequence, not quantity: never a fact.
  for (const token of source.match(/(?<!第)[零一二三四五六七八九十百千万亿两]{1,4}(?=[个条元块岁天分秒人年次件点步项位名号周])/g) ?? []) {
    // A bare 一 before a measure word is usually the indefinite article
    // ("一个问题"); a rewrite adds it freely, so it is not evidence of invention.
    if (token === "一") continue;
    const value = chineseNumeral(token);
    set.add("N:" + (value === null ? token : String(value)));
  }
  const calendar = source.match(/(?:周一|周二|周三|周四|周五|周六|周日|周天|星期一|星期二|星期三|星期四|星期五|星期六|星期日|今天|明天|后天|昨天|上周|本周|下周|这周|下个月|上个月|今年|明年|去年|上午|下午|晚上|早上|中午)/g) ?? [];
  for (const token of calendar) set.add("D:" + (CALENDAR_SYNONYMS[token] ?? token));
  // Latin facts are limited to what is unambiguous: symbol-bearing identifiers.
  // Capitalised words are deliberately NOT facts. English capitalises the first
  // word of every sentence, and bullet lists capitalise each item, so treating
  // them as facts rejects correct rewrites such as "Restart the service" or
  // "- Update the parser". A single-day name in a latin sentence is a known gap
  // in this guard; the system prompt and the fallback path are what cover it.
  for (const token of source.match(/@[A-Za-z0-9_.-]+|[A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)+/g) ?? []) {
    set.add("W:" + token);
  }
  return set;
}

/**
 * A list label: "1. ", "2) ", "3）", "4、", "一、", "- ", "• " at the start of a line,
 * or inline after a colon or separator ("：1. 要快 2. 要准").
 */
const LIST_MARKER = /(^|[\s：:；;，,。])[ \t]*(?:\d{1,2}[.)．）](?!\d)|\d{1,2}、|[一二三四五六七八九十]、|[-•*·](?=[ \t]))[ \t]*/gmu;

/**
 * Number of list items: lines that start with a list label.
 * @param {string} text - candidate output.
 * @returns {number} the item count.
 */
export function listItemCount(text) {
  return (String(text ?? "").match(/^[ \t]*(?:\d{1,2}[.)．）](?!\d)|\d{1,2}、|[一二三四五六七八九十]、|[-•*·][ \t])/gmu) ?? []).length;
}

/**
 * Remove list labels so numbering does not read as numbers.
 * @param {string} text - input text.
 * @returns {string} the text without leading list labels.
 */
export function stripListMarkers(text) {
  return String(text ?? "").replace(LIST_MARKER, "$1");
}

const CN_DIGITS = { 零: 0, 〇: 0, 一: 1, 二: 2, 两: 2, 三: 3, 四: 4, 五: 5, 六: 6, 七: 7, 八: 8, 九: 9 };
const CN_UNITS = { 十: 10, 百: 100, 千: 1000 };
const CN_BIG = { 万: 1e4, 亿: 1e8 };

/**
 * Value of a Chinese numeral: "两" -> 2, "十二" -> 12, "二十三" -> 23,
 * "一百零五" -> 105, "二零二六" -> 2026 (digit-by-digit reading).
 * @param {string} token - a run of Chinese numeral characters.
 * @returns {number|null} the value, or null when the run is not a numeral.
 */
export function chineseNumeral(token) {
  const text = String(token ?? "");
  if (text.length === 0) return null;
  const chars = Array.from(text);
  if (!chars.some((c) => c in CN_UNITS || c in CN_BIG)) {
    let digits = "";
    for (const c of chars) {
      if (!(c in CN_DIGITS)) return null;
      digits += String(CN_DIGITS[c]);
    }
    return Number(digits);
  }
  let total = 0;
  let section = 0;
  let digit = null;
  for (const c of chars) {
    if (c in CN_DIGITS) digit = CN_DIGITS[c];
    else if (c in CN_UNITS) {
      section += (digit ?? 1) * CN_UNITS[c];
      digit = null;
    } else if (c in CN_BIG) {
      total += (section + (digit ?? 0)) * CN_BIG[c];
      section = 0;
      digit = null;
    } else return null;
  }
  return total + section + (digit ?? 0);
}

/** Markers by which a speaker visibly revises what they just said. */
const CORRECTION = /(no wait|i mean|rather|sorry|actually|instead|不对|不不|不是|应该是|改成|改为|错了|重新说|我的意思是|应该是说)/i;

/**
 * Whether the transcript contains a spoken self-correction.
 *
 * A correction authorises exactly one new fact ("send it Tuesday - no wait,
 * Wednesday"), which would otherwise look like fabrication.
 * @param {string} source - raw transcript.
 * @returns {boolean} whether a revision marker is present.
 */
export function hasCorrection(source) {
  return CORRECTION.test(String(source ?? ""));
}

/**
 * The window a spoken correction authorises.
 *
 * "send it tuesday, no wait, wednesday" authorises one replacement, and it must
 * be the thing the speaker revised — not a licence to append a deadline
 * elsewhere in the sentence. Everything after the last revision marker is the
 * revised material; anything outside it is fabrication as usual.
 *
 * @param {string} source - raw transcript.
 * @returns {string} the authorised tail, or an empty string when there is no correction.
 */
export function correctionWindow(source) {
  const text = String(source ?? "");
  const matches = [...text.matchAll(new RegExp(CORRECTION.source, "gi"))];
  if (matches.length === 0) return "";
  const last = matches[matches.length - 1];
  return text.slice((last.index ?? 0) + last[0].length);
}

/**
 * Fact tokens present in the output but absent from the source.
 * @param {string} source - raw transcript.
 * @param {string} output - polished candidate.
 * @returns {Array<string>} the newly introduced tokens.
 */
export function inventedFacts(source, output) {
  const from = factTokens(source);
  const invented = [];
  for (const token of factTokens(output)) if (!from.has(token)) invented.push(token);
  return invented;
}

/** Language balance of a text: CJK characters, latin letters and latin words. */
export function languageBalance(text) {
  const source = String(text ?? "");
  return {
    cjk: (source.match(CJK) ?? []).length,
    latin: (source.match(LATIN) ?? []).length,
    latinWords: (source.match(/[A-Za-z]+(?:['’][A-Za-z]+)?/g) ?? []).length,
  };
}

/**
 * Share of Chinese in a text, counting a latin WORD as one unit like one CJK
 * character. Counting letters instead made a mixed sentence look English as soon
 * as its English words were spelled out: "我在iphone上用n记的笔记" ->
 * "我在 iPhone 上用 Notion 记的笔记" has 8 CJK characters and 12 letters, and was
 * rejected as a translation.
 * @param {{cjk: number, latinWords: number}} balance - from languageBalance().
 * @returns {number|null} the share in [0, 1], or null when there is no text.
 */
export function cjkShare(balance) {
  const units = balance.cjk + balance.latinWords;
  return units === 0 ? null : balance.cjk / units;
}

/**
 * Whether the output is a translation rather than a cleanup: the text moved from
 * mostly Chinese to mostly English or the other way round.
 * @param {string} source - raw transcript.
 * @param {string} output - candidate.
 * @returns {boolean} whether the language changed.
 */
export function languageChanged(source, output) {
  const from = cjkShare(languageBalance(source));
  const to = cjkShare(languageBalance(output));
  if (from === null || to === null) return false;
  if (from >= 0.5 && to < THRESHOLDS.languageFlipLow) return true;
  if (from < 0.5 && to > THRESHOLDS.languageFlipHigh) return true;
  return false;
}

/** Thresholds for one validation run. */
export const THRESHOLDS = {
  /** Chinese share below which a Chinese transcript counts as translated to English. */
  languageFlipLow: 0.25,
  /** Chinese share above which an English transcript counts as translated to Chinese. */
  languageFlipHigh: 0.75,
  /** Below this content length most checks are skipped: too little signal. */
  shortText: 8,
  /** Relative change allowed for short utterances. */
  shortRatio: [0.3, 3],
  /** Relative change allowed for longer utterances. */
  longRatio: [0.4, 2],
  /** Minimum source-unit coverage for deliberately restructured output. */
  structuredCoverage: 0.45,
  /** Minimum source-unit coverage for conservative output. */
  conservativeCoverage: 0.7,
  /** Maximum fraction of the output that may be new material. */
  structuredNovelty: 0.4,
  /** Conservative output may introduce almost nothing. */
  conservativeNovelty: 0.25,
  /** Novelty only carries enough signal in output of at least this size. */
  noveltyMinUnits: 6,
  /**
   * Below this output/source unit ratio the answer is deliberately compressive,
   * so coverage stops being a useful gate. Measured on this project's cases:
   * a self-correction answered correctly lands at 0.15-0.31, while a partial
   * rewrite that kept most of the content sits at 0.46 and is still judged.
   */
  compressionRatio: 0.25,
  /** A length ratio at or below this is truncation rather than compression. */
  truncationRatio: 0.15,
  /**
   * Fine-grained novelty ceiling per strength level.
   *
   * prompt/maximal sit deliberately above the "added requirement" range because
   * those modes are supposed to restructure boldly; the fact-token guard is what
   * catches concrete fabrication. conservative stays strict.
   */
  preciseNoveltyByStrength: { conservative: 0.45, prompt: 0.7, maximal: 0.8 },
  /** Novelty only carries signal above this many output units. */
  noveltySignalUnits: 6,
  /** Source coverage floor per strength level. */
  coverageByStrength: { conservative: 0.7, prompt: 0.35, maximal: 0.25 },
};

/**
 * Numbers a translation wrote in digits that the speaker never said, by value.
 * A translation changes how a number is written ("三点" -> "3:00 PM", "十九日" ->
 * "October 19"), so the rewrite guard's token comparison does not fit: here every
 * digit group must be a value the speaker said (in digits or Chinese numerals),
 * zero, or the 24-hour form of a spoken hour. Words such as "p.m." are not facts.
 * @param {string} raw - the transcript.
 * @param {string} output - the translation.
 * @returns {string[]} the unexplained numbers.
 */
export function translationInventedNumbers(raw, output) {
  const said = new Set([0]);
  const source = stripListMarkers(String(raw ?? ""));
  for (const token of source.match(/\d+(?:[.:/-]\d+)*/g) ?? []) {
    said.add(Number(token));
    for (const part of token.split(/[.:/-]/)) said.add(Number(part));
  }
  for (const token of source.match(/[零一二三四五六七八九十百千万亿两]+/g) ?? []) {
    const value = chineseNumeral(token);
    if (value !== null) said.add(value);
  }
  if (/半/.test(source)) { said.add(30); said.add(0.5); }
  for (const value of [...said]) if (Number.isInteger(value) && value >= 1 && value <= 12) said.add(value + 12);
  const written = stripListMarkers(String(output ?? "")).replace(/(\d),(?=\d{3}\b)/g, "$1");
  const extra = [];
  for (const token of written.match(/\d+(?:[.:/-]\d+)*/g) ?? []) {
    if (said.has(Number(token))) continue;
    for (const part of token.split(/[.:/-]/)) if (!said.has(Number(part))) extra.push(token);
  }
  return [...new Set(extra)];
}

/**
 * Validate a polished candidate against its raw transcript.
 * @param {object} input - raw text, candidate, and the applied strength.
 * @returns {{ok: boolean, reason?: string, text: string, metrics: object}}
 */
export function validateOutput(input) {
  const { rawText, strength } = input;
  const raw = String(rawText ?? "");
  const metrics = { rawLength: contentLength(raw) };
  const unwrapped = unwrap(input.output ?? "");
  const text = unwrapped.text;
  metrics.outputLength = contentLength(text);
  metrics.coverage = coverage(raw, text);
  metrics.unwrappedFence = unwrapped.unwrappedFence;
  metrics.unwrappedQuotes = unwrapped.unwrappedQuotes;

  if (text.length === 0) return { ok: false, reason: "empty-output", text, metrics };

  const rawContent = contentLength(raw);
  // A very short utterance ("ok", "嗯") has no structure to validate.
  if (rawContent < THRESHOLDS.shortText) return { ok: true, text, metrics };

  // Language is checked before length: a translated answer also breaks the
  // length ratio, and the reason reported must name the real fault.
  // Prompt mode may legitimately be asked (in the user's own additions) to write
  // the prompt in another language, so only its fact check applies.
  // 翻译模式 changes the language and every word on purpose: only invented numbers count.
  if (strength === "translate") {
    metrics.inventedFacts = translationInventedNumbers(raw, text);
    return metrics.inventedFacts.length > 0 ? { ok: false, reason: "invented-fact", text, metrics } : { ok: true, text, metrics };
  }

  if (strength !== "promptify" && languageChanged(raw, text)) return { ok: false, reason: "language-changed", text, metrics };

  const ratio = metrics.outputLength / Math.max(1, rawContent);
  metrics.ratio = ratio;
  const unitCount = units(text).size;
  metrics.outputUnits = unitCount;
  metrics.novelty = novelty(raw, text);

  // The output is judged by what it ADDS, not by how much of the transcript it
  // restates. A speaker who says "send it Tuesday — no, Wednesday" and gets back
  // "Send it Wednesday." has been served correctly, yet only half the source
  // units survive; the same ratio can also mean the answer was truncated. The
  // conservative rule is therefore: treat a large length loss as truncation, and
  // otherwise require that almost nothing new was introduced.
  const sourceUnits = units(raw).size;
  const outputRatio = sourceUnits === 0 ? 1 : unitCount / sourceUnits;
  metrics.outputUnitRatio = outputRatio;

  // Concrete fabrication is checked first because it is decisive and has no
  // legitimate counterpart: a rewrite must not conjure a number, date or name.
  const invented = inventedFacts(raw, text);
  metrics.inventedFacts = invented;
  // A spoken correction authorises ONE replacement, and only inside the material
  // the speaker revised. A new fact anywhere else is fabrication.
  const window = correctionWindow(raw);
  const authorised = window.length === 0
    ? 0
    : invented.filter((token) => factTokens(window).has(token)).length;
  // "以下三点：1. … 2. … 3. …": a count that equals the number of list items is
  // read off the structure the rewrite created, not invented.
  const items = listItemCount(text);
  const structural = items >= 2 ? invented.filter((token) => token === "N:" + items).length : 0;
  // Prompt mode (提示词模式) adds a role, tone and output format on purpose, so
  // it is always much longer and mostly new wording; only the decisive checks
  // (language, invented facts) apply to it. Counting the user's own items in
  // words ("这两项工作") is summary, not invention, so there a number counts as
  // invented only when it is written in digits ("300 字", "5 点").
  if (strength === "promptify") {
    const digits = factTokens(text.replace(/[零一二三四五六七八九十百千万亿两]/g, ""));
    const decisive = invented.filter((token) => !token.startsWith("N:") || digits.has(token));
    if (decisive.length > authorised) return { ok: false, reason: "invented-fact", text, metrics };
    return { ok: true, text, metrics };
  }

  if (invented.length > authorised + structural) return { ok: false, reason: "invented-fact", text, metrics };

  const maxNovelty = THRESHOLDS.preciseNoveltyByStrength[strength] ?? THRESHOLDS.preciseNoveltyByStrength.prompt;
  metrics.preciseNovelty = preciseNovelty(raw, text);
  if (unitCount >= THRESHOLDS.noveltySignalUnits && metrics.preciseNovelty > maxNovelty) {
    return { ok: false, reason: "invented-content", text, metrics };
  }

  // Compression inverts the meaning of low coverage, so the two cases are
  // separated explicitly: resolved self-corrections collapse the transcript and
  // are judged only by what they added, while ordinary rephrasing must still
  // restate most of what was said.
  // Truncation is judged on the length ratio alone.
  if (ratio <= THRESHOLDS.truncationRatio) return { ok: false, reason: "output-too-short", text, metrics };

  // Coverage is only a gate for the conservative strength.
  //
  // For prompt/maximal the product decision is explicit: the user wants bold
  // restructuring, and every measurement in this project showed the ratio cannot
  // separate "ruthlessly compressed" from "truncated" from "resolved a
  // self-correction" — the same 0.31 belongs to a correct compression and to a
  // real truncation. Concrete fabrication is caught by the fact guard above, and
  // the remaining risk is the price of the requested aggressiveness. The metric
  // is still reported for logs.
  if (strength === "conservative" && outputRatio >= THRESHOLDS.compressionRatio && metrics.coverage < THRESHOLDS.conservativeCoverage) {
    return { ok: false, reason: "semantic-drift", text, metrics };
  }

  const [, highRatio] = rawContent < 40 ? THRESHOLDS.shortRatio : THRESHOLDS.longRatio;
  if (ratio > highRatio) return { ok: false, reason: "output-too-long", text, metrics };

  return { ok: true, text, metrics };
}
