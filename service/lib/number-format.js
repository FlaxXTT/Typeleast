/**
 * Conservative written numbers for one-shot cleanup. No model calls or I/O.
 * Common Chinese usage: small counts in a sentence (三个人, 两天, 说三点) stay in characters;
 * money, measurements, percentages, dates, clock times, codes and numbers of ten or more use digits.
 */
import { approximateNumbers, chineseNumeral } from './validate.js';

const CN = '零〇一二三四五六七八九十百千万亿两兩';
const RUN = new RegExp(`[负負]?[${CN}]+(?:[点點][零〇一二三四五六七八九]+)?`, 'gu');
const UNIT = /^(?:个人|個人|个|個|人|位|名|条|條|项|項|件|台|臺|次|份|张|張|本|只|句|组|組|页|頁|行|段|岁|歲|天|小时|小時|分钟|分鐘|秒|元|块|塊|美元|公里|米|厘米|公斤|千克|克|毫升|升|年|月|日|号|號|周|倍|级|級|层|層|版本|点|點)/u;
/** Units of measurement and money: even a small number takes digits (3公里, 5元). */
const MEASURE = /^(?:元|美元|公里|千米|米|厘米|毫米|公斤|千克|克|毫升|升|吨|平方米|立方米|度|岁|歲|倍)/u;
/** A clock time, not a count: 早上九点, 九点半, 九点十分. */
const CLOCK_BEFORE = /(?:早上|上午|中午|下午|晚上|凌晨|今天|明天|后天|昨天|今晚|明早)\s*$/u;
const CLOCK_AFTER = /^[点點](?:半|[零〇一二三四五六七八九十]+分|整)/u;
const IDIOM = /一心一意|三心二意|一刀切|五一劳动节|十一国庆|三五成群/u;

function decimal(s) {
  const negative = /^[负負]/u.test(s);
  const [whole, fraction] = s.replace(/^[负負]/u, '').replaceAll('兩', '两').split(/[点點]/u);
  // 三万五 is not reliably 30005: leave abbreviated quantities to the model.
  if (/[万亿][一二三四五六七八九两]$/u.test(whole) || /万亿/u.test(whole)) return null;
  const n = chineseNumeral(whole.replaceAll('〇', '零'));
  if (n === null || !Number.isSafeInteger(n)) return null;
  // A bare unit such as 万 is not zero.
  if (n === 0 && !/[零〇]/u.test(whole)) return null;
  const digits = fraction === undefined ? '' : '.' + [...fraction].map(c => '零一二三四五六七八九'.indexOf(c === '〇' ? '零' : c)).join('');
  return (negative ? '-' : '') + n + digits;
}

/** Only number-shaped phrases with units or explicit numeric cues are changed. */
function convert(text, force) {
  let out = text.replace(/百分之([负負]?[零〇一二三四五六七八九十百千万亿两]+(?:点[零〇一二三四五六七八九]+)?)/gu,
    (whole, value) => { const n = decimal(value); return n === null ? whole : n + '%'; });
  const estimates = approximateNumbers(out);
  // Work backwards: offsets still refer to the original string.
  for (const e of estimates.reverse()) {
    const tail = out.slice(e.index + e.text.length);
    if (!UNIT.test(tail) || IDIOM.test(out.slice(Math.max(0, e.index - 2), e.index + e.text.length + 6))) continue;
    // 三四个人 and 五六天 are small counts: they stay in characters.
    if (!force && e.hi < 10 && !MEASURE.test(tail) && !/^[百千万亿]/u.test(tail)) continue;
    out = out.slice(0, e.index) + e.lo + '～' + e.hi + tail;
  }
  return out.replace(RUN, (whole, offset, source) => {
    const before = source.slice(Math.max(0, offset - 16), offset);
    const after = source.slice(offset + whole.length);
    const nearby = source.slice(Math.max(0, offset - 3), offset + whole.length + 8);
    if (IDIOM.test(nearby)) return whole;
    // 万 after a written number is its unit (1.5万, 2 万元), not a number of its own.
    if (/[\d.]\s*$/u.test(before)) return whole;
    const cue = /(?:编号|验证码|代码|号码|版本|版本号|数量|金额)\s*(?:是|为|[:：])?\s*$/u.test(before);
    // Ordinal words and ambiguous unit boundaries are not measured quantities.
    if (/第\s*$/u.test(before) || (whole.endsWith('千') && after.startsWith('克'))) return whole;
    // 一个/一段 often mean an indefinite article, not a measured quantity.
    if (whole === '一' && !cue && !/^(?:年|月|日|号)/u.test(after)) return whole;
    if (!UNIT.test(after) && !cue) return whole;
    // 三四 is an estimate left in characters above, not thirty-four.
    if (!force && /^[一二三四五六七八九]{2}$/u.test(whole) && whole[0] !== whole[1]) return whole;
    const n = decimal(whole);
    if (n === null) return whole;
    // A small count in a sentence stays in characters unless it is money, a measurement, a date or a time.
    if (!force && !cue && Math.abs(Number(n)) < 10 && !n.includes('.') && !MEASURE.test(after) && !smallDate(before, whole, after)
        && !(/^[点點]/u.test(after) && (CLOCK_BEFORE.test(before) || CLOCK_AFTER.test(after)))) return whole;
    // Literal digit sequences such as 〇〇一二 preserve leading zeros.
    if (!/[十百千万亿两点负負]/u.test(whole) && whole.length >= 3) {
      return [...whole].map(c => '零一二三四五六七八九'.indexOf(c === '〇' ? '零' : c)).join('');
    }
    return n;
  });
}

/** 三月五日: a month followed by a day, or a day after a written month. */
function smallDate(before, whole, after) {
  if (/^月\s*[零〇一二三四五六七八九十\d]+\s*[日号號]/u.test(after)) return true;
  return /^[日号號]/u.test(after) && /(?:\d|[零〇一二三四五六七八九十])\s*月\s*$/u.test(before);
}

export function normalizeNumbers(text) {
  const source = String(text ?? '');
  // An explicit request for written Chinese numerals wins over the default.
  const requests = [...source.matchAll(/(?:保留|使用|用|写成|写为)中文数字/gu)];
  if (requests.some(m => !/(?:不|别|不要|不能|不想|禁止)$/u.test(source.slice(0, m.index)))) return source;
  // So does an explicit request for digits: then every number-shaped phrase is converted.
  const force = /(?:用|使用|写成|写为|改成|换成)阿拉伯数字|(?:不|别|不要|不用)(?:使用|用|写成)?中文数字/u.test(source);
  // Do not touch literal quotations, code, identifiers, URLs or paths.
  const literals = /```[\s\S]*?```|`[^`\n]*`|https?:\/\/[^\s<>]+|(?:[A-Za-z]:[\\/]|\/)[^\s，。；！？]+|[“「『"][^”」』"\n]*[”」』"]|[A-Za-z_][A-Za-z0-9_\-\u4e00-\u9fff]*(?:\.[A-Za-z0-9_\-\u4e00-\u9fff]+)+/gu;
  let result = '', from = 0;
  for (const m of source.matchAll(literals)) {
    result += convert(source.slice(from, m.index), force) + m[0];
    from = m.index + m[0].length;
  }
  return result + convert(source.slice(from), force);
}
