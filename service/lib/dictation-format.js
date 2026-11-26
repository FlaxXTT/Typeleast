const markdownRequest = /(?:用|使用|采用|写成|输出为)\s*markdown\b|\b(?:use|format (?:it |this )?as|write (?:it |this )?in|return (?:it |this )?as)\s+markdown\b/iu;
const plainRequest = /纯文本|純文字|纯文字|(?:别|不(?:要|用|许)|禁止)[^。！？，,.!\n]{0,16}markdown\b|\b(?:plain text|no markdown|without markdown|don.t use markdown)\b/iu;
const aiHandoff = /(?:发给|發給|交给|交給|提供给|提供給|贴给|貼給)\s*(?:另一个|另一個|一个|一個|其他|下一个|下一個)\s*(?:AI|大(?:语言|語言)?模型|语言模型|語言模型)|\b(?:send|pass|give|paste|hand (?:it |this )?off)\b[^.!?\n]{0,80}\b(?:to another (?:AI|language model)|to the next (?:AI|language model))\b/iu;

export function dictationUsesMarkdown(source) {
  return !plainRequest.test(source) && (markdownRequest.test(source) || aiHandoff.test(source));
}

const plainInstruction = "\n\nReturn paste-ready plain text in the JSON text field. Keep numbered lists and paragraphs. Omit Markdown formatting. Preserve meaningful symbols, including operators.";
const markdownInstruction = "\n\nThis request explicitly calls for Markdown or an AI handoff. Use Markdown only if it helps the requested structure.";

export function dictationFormatInstruction(markdown) {
  return markdown ? markdownInstruction : plainInstruction;
}

const fenced = /^[ \t]*(?:\x60{3,}|~{3,})[^\r\n]*\r?\n([\s\S]*?)^[ \t]*(?:\x60{3,}|~{3,})[ \t]*(?=\r?$)/gmu;
const inline = /(?<!\\)\x60+([^\x60\n]+?)\x60+|\[([^\]\n]+)\]\(((?:[^()\s]|\([^()\s]*\))+)\)|https?:\/\/[^\s<>]+/gu;
const emphasis = /(?<![\\*])(\*{2,3})(?![\s*])([^\n*]*?\S)\1(?!\*)|(?<![A-Za-z0-9_\\*])\*(?![\s*])([^\n*]*?\S)\*(?![A-Za-z0-9_*])|(?<![A-Za-z0-9_\\])(_{1,2})(?![\s_])([^\n_]*?\S)\4(?![A-Za-z0-9_])|(?<![\\~])~~(?!\s)([^\n~]*?\S)~~(?!~)/gu;
const rule = /^[ \t]*(?:\*{3,}|-{3,}|_{3,})[ \t]*$/u;
const tableDivider = /^[ \t]*\|?[ \t]*:?-{3,}:?(?:[ \t]*\|[ \t]*:?-{3,}:?)+[ \t]*\|?[ \t]*$/u;

function inlinePlain(text, source) {
  const clean = part => part.replace(emphasis, (match, _stars, bold, italic, _underscores, underlined, strike) =>
    source.includes(match) ? match : bold ?? italic ?? underlined ?? strike);
  let output = "";
  let offset = 0;
  for (const token of text.matchAll(inline)) {
    const [match, code, label, url] = token;
    output += clean(text.slice(offset, token.index));
    if (source.includes(match) || (!code && !label)) output += match;
    else if (code) output += code;
    else output += label === url ? url : clean(label) + " (" + url + ")";
    offset = token.index + match.length;
  }
  return output + clean(text.slice(offset));
}

function plainLines(text, source, sourceLines) {
  let inTable = false;
  const lines = text.split("\n");
  return lines.flatMap((line, index) => {
    if (inTable && tableDivider.test(line.trimEnd())) return [];
    inTable = line.includes("|") && (inTable || tableDivider.test(lines[index + 1]?.trimEnd() ?? ""));
    if (inTable) line = line.trim().replace(/^\||\|$/gu, "").split("|").map(cell => cell.trim()).join(" · ");
    if (rule.test(line) && !source.includes(line.trim())) return [""];
    const marked = line.match(/^([ \t]*)(?:#{1,6}[ \t]+|(?:> ?)+|[-+*][ \t]+)(\S.*)$/u);
    if (marked && !sourceLines.has(line)) {
      const [prefix, indent, content] = marked;
      const bullet = /^[-+*][ \t]/u.test(prefix.trimStart());
      const heading = /^#/u.test(prefix.trimStart());
      line = indent + (bullet ? "• " : "") + (heading ? content.replace(/[ \t]+#+[ \t]*$/u, "") : content);
    }
    return [inlinePlain(line, source)];
  }).join("\n");
}

// Flatten only generated presentation. Code, spoken symbols and visible text
// stay usable when the next app displays every character literally.
export function plainDictationText(text, source) {
  const sourceLines = new Set(source.split(/\r?\n/u));
  let output = "";
  let offset = 0;
  for (const block of text.matchAll(fenced)) {
    output += plainLines(text.slice(offset, block.index), source, sourceLines) + block[1].trimEnd();
    offset = block.index + block[0].length;
  }
  return (output + plainLines(text.slice(offset), source, sourceLines)).trim();
}
