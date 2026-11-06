/**
 * Find a narrow, independently checkable class of meaning changes.
 *
 * This is deliberately not a fact checker: a single mismatch asks the user
 * to review the two texts; it does not decide which text is correct. Multiple
 * instances of the same value are left alone because a later expression may
 * be a correction, comparison, date, or a different measurement altogether.
 */
const unitGroups = [
  ['page', '页', '頁'], ['sheet', '张', '張'],
  ['day', '天', '日'], ['week', '周', '週'], ['month', '个月', '個月', '月'], ['year', '年'],
  ['hour', '小时', '小時'], ['minute', '分钟', '分鐘'], ['second', '秒'],
  ['yuan', '元', '块', '塊'], ['dollar', '美元'],
  ['kilometer', '公里', '千米'], ['meter', '米'], ['centimeter', '厘米', '公分'],
  ['millimeter', '毫米'], ['kilogram', '公斤', '千克'], ['gram', '克'],
  ['liter', '公升', '升'], ['percent', '%', '％'], ['times', '次', '回'],
];
const units = new Map();
for (const [group, ...variants] of unitGroups) for (const unit of variants) units.set(unit, group);
const unitPattern = [...units.keys()].sort((a, b) => b.length - a.length).join('|');
// Exclude suffixes of longer numerals or decimals. Other numerical formats are
// intentionally left to the model, rather than normalised or guessed here.
const matcher = new RegExp(`(?<![0-9０-９零〇一二三四五六七八九十百千万萬两兩点點.])([0-9０-９]+|[零〇一二三四五六七八九十两兩])[ \\t]*(${unitPattern})`, 'gu');
const chineseDigit = new Map(Object.entries({ 零: '0', 〇: '0', 一: '1', 二: '2', 两: '2', 兩: '2', 三: '3', 四: '4', 五: '5', 六: '6', 七: '7', 八: '8', 九: '9', 十: '10' }));
const unrelatedCompound = /^(?:月饼|月餅|月亮|月球|月光|天气|天氣|天空|天然|天生|日历|日曆|日志|日誌|米饭|米飯|米粉|秒杀|秒殺)/u;

function quantities(text) {
  const result = [];
  const source = String(text ?? '').normalize('NFKC');
  for (const match of source.matchAll(matcher)) {
    const unit = match[2];
    const unitOffset = match.index + match[0].lastIndexOf(unit);
    if (unrelatedCompound.test(source.slice(unitOffset))) continue;
    const digits = chineseDigit.get(match[1]) ?? match[1];
    // Do not collapse identifiers with leading zeroes into another value.
    if (/^0\d/u.test(digits)) continue;
    result.push({ value: digits, unit: units.get(unit) });
  }
  return result;
}

/** Return true only when a unique source quantity changes to another unit. */
export function hasQuantityUnitConflict(raw, candidate, language = 'auto') {
  const original = String(raw ?? '');
  const output = String(candidate ?? '');
  if (language && !['auto', 'zh', 'yue'].includes(language)) return false;
  // Avoid applying Chinese unit conventions to mixed Japanese or Korean text.
  if (!/\p{Script=Han}/u.test(original) || /[\p{Script=Hiragana}\p{Script=Katakana}\p{Script=Hangul}]/u.test(original)) return false;
  const before = quantities(original);
  const after = quantities(output);
  return before.some((quantity) => {
    const sourceMatches = before.filter((item) => item.value === quantity.value);
    const outputMatches = after.filter((item) => item.value === quantity.value);
    return sourceMatches.length === 1 && outputMatches.length === 1 && outputMatches[0].unit !== quantity.unit;
  });
}
