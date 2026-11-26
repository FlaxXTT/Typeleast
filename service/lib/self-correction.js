import { mapOutsideLiterals } from "./punctuation.js";

const cues = /(?:(?:啊|呃)[，,、 \t]*)?(?:(?:我(?:刚才|剛才)?[ \t]*)?(?:说错了|說錯了|讲错了|講錯了|口误了|口誤了)[，,、。！!：:\s]*)+(?:应该是|應該是|应当是|應當是|应该说|應該說|正确的是|正確的是|更正为|更正為|改成|我说的是|我說的是)|\b(?:sorry[,.!; \t]+)?I\s+(?:meant|misspoke[, \t]+(?:it\s+)?should\s+be)\b/giu;
const boundary = /[,，、.。；;！？!?\n]/u;
const trailing = /[\s,，、.。；;！？!?]+$/u;
const leading = /^[\s,，、：:]+/u;
const letterList = /^[A-Z](?:[ ,，、]+[A-Z])*$/u;
const latinWord = /^[a-z][a-z0-9_+.-]*$/iu;
const measurement = /(?:[+-]?\d+(?:[.:]\d+)?|[零〇一二三四五六七八九十百千万萬两兩]+)\s*(?:分钟|分鐘|小时|小時|个月|個月|星期|公斤|毫米|厘米|千米|米|岁|歲|件|个|個|点半|點半|点|點|分|秒|日|号|號|月|年|元|%|[kcm]?g|[kcm]?m|hrs?|mins?|secs?)?$/iu;
const sameEnding = (a, b) => a.length === b.length && b.length > 2 && /\p{Script=Han}{2}$/u.test(b) && a.endsWith(b.slice(-2));
const anotherSpeaker = /(?:他们|她们|你们|他們|她們|你們|你|他|她)(?:刚才|剛才|刚|剛|昨天|自己)?$/u;

/** Remove only explicit, directly adjacent corrections with an identifiable withdrawn span. */
export function resolveSelfCorrections(source) {
  let pending = false;
  const text = mapOutsideLiterals(source, part => {
    let output = part;
    let offset = 0;
    const pattern = new RegExp(cues);
    for (;;) {
      pattern.lastIndex = offset;
      const cue = pattern.exec(output);
      if (!cue) break;
      const start = cue.index;
      const end = start + cue[0].length;
      const before = output.slice(0, start);
      if (anotherSpeaker.test(before.trim())) {
        offset = end;
        continue;
      }
      const after = output.slice(end).replace(leading, "");
      const replacement = after.split(boundary, 1)[0].trim();
      const withdrawn = before.replace(trailing, "");
      const separator = Math.max(...Array.from(withdrawn.matchAll(/[,，、.。；;！？!?\n]/gu), match => match.index), -1);
      const previousClause = withdrawn.slice(separator + 1).trim();
      let replaceFrom = -1;
      if (replacement && previousClause) {
        if (letterList.test(replacement) && letterList.test(previousClause)) {
          const list = withdrawn.match(/(?:^|[^A-Za-z0-9])([A-Z](?:[ \t,，、]+[A-Z])*)$/u);
          replaceFrom = list ? withdrawn.length - list[1].length : withdrawn.length - previousClause.length;
        } else {
          const priorMeasure = withdrawn.match(measurement);
          const nextMeasure = replacement.match(measurement);
          if (priorMeasure && nextMeasure?.index === 0 &&
              !/[A-Za-z0-9]/u.test(withdrawn[(priorMeasure.index ?? 0) - 1] ?? "")) {
            replaceFrom = priorMeasure.index;
          } else if (latinWord.test(replacement) && latinWord.test(previousClause) || sameEnding(previousClause, replacement)) {
            replaceFrom = withdrawn.length - previousClause.length;
          }
        }
      }
      if (replaceFrom < 0) {
        pending = true;
        offset = end;
        continue;
      }
      const fixed = /^(?<letter>[A-Z])(?:[ ,，、]+\k<letter>)+$/u.exec(replacement)?.groups.letter ?? replacement;
      output = output.slice(0, replaceFrom) + fixed + after.slice(replacement.length).replace(/^[ \t]+(?=[.。！？!?，,；;])/u, "");
      offset = replaceFrom + fixed.length;
    }
    return output;
  });
  return { text: text.trim(), pending };
}
