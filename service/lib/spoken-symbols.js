import { mapOutsideLiterals } from "./punctuation.js";

const symbols = new Map([
  ["井号", "#"], ["井號", "#"], ["hash sign", "#"], ["number sign", "#"],
  ["艾特", "@"], ["at 符号", "@"], ["at 符號", "@"], ["at sign", "@"],
  ["感叹号", "!"], ["感嘆號", "!"], ["惊叹号", "!"], ["驚嘆號", "!"], ["exclamation mark", "!"],
  ["问号", "?"], ["問號", "?"], ["question mark", "?"],
  ["逗号", "，"], ["逗號", "，"], ["句号", "。"], ["句號", "。"],
  ["冒号", "："], ["冒號", "："], ["分号", "；"], ["分號", "；"],
  ["百分号", "%"], ["百分號", "%"], ["下划线", "_"], ["底線", "_"],
  ["星号", "*"], ["星號", "*"], ["斜杠", "/"], ["斜線", "/"],
  ["竖线", "|"], ["豎線", "|"], ["双竖线", "||"], ["雙豎線", "||"],
  ["逻辑或", "∨"], ["邏輯或", "∨"], ["逻辑或符号", "∨"], ["邏輯或符號", "∨"],
  ["脱字符", "^"], ["脫字符", "^"], ["插入符", "^"], ["caret", "^"],
]);

const spokenMark = /^(?:请|請)?(?:打出|输入|輸入|插入|写下|寫下|打|写|寫|加上?)\s*(?:[一1][个個]\s*)?/u;
const mentionOfSymbol = /(?:标点|標點|符号|符號|名称|名稱|叫作|读作|讀作|看成|例如|比如|包括)[^\n。！？!?]{0,14}$|是[ \t]*$/u;
const sentenceMarks = [...symbols].filter(([, value]) => /[!?，。；：]/u.test(value));
const spokenEnding = new RegExp(
  `(?:[，,、][ \t]*|[ \t]+|[，,]?[ \t]*(?:最后|最後|结尾|結尾|末尾)[ \t]*(?:加上?|打出?|输入|輸入)[ \t]*)` +
  `(${sentenceMarks.map(([key]) => key).join("|")})[。.!?！？]?(?=[ \t]*$)`, "gimu");
const standaloneExponent = /^上[标標][ \t]*([+-]?\d{1,8}|[零〇一二三四五六七八九])$/u;
const attachedExponent = /(?<![A-Za-z0-9_])([A-Za-z][A-Za-z0-9_]*|\d+)\s*(?:的[ \t]*)?上[标標][ \t]*([+-]?\d{1,8}|[零〇一二三四五六七八九])(?=[\s，。；！？,.!?;:=]|$)/gu;
const digits = "零一二三四五六七八九";
const superscript = value => [...value].map(character => {
  if (character === "+") return "⁺";
  if (character === "-") return "⁻";
  const digit = character === "〇" ? 0 : digits.indexOf(character);
  return "⁰¹²³⁴⁵⁶⁷⁸⁹"[digit < 0 ? Number(character) : digit];
}).join("");

function standaloneSymbol(name) {
  const known = symbols.get(name.toLowerCase());
  const exponent = known ? null : name.match(standaloneExponent);
  return exponent ? superscript(exponent[1]) : known;
}

export function renderSpokenSymbols(source) {
  const required = [];
  const use = symbol => { required.push(symbol); return symbol; };
  const text = mapOutsideLiterals(source, (part, followingLiteral) => {
    const lines = part.split("\n").map(line => {
      const bare = line.trim().replace(/[。.!?！？]$/u, "").replace(spokenMark, "");
      const requested = bare.split(/[、，,；;][ \t]*/u).map(name => standaloneSymbol(name.trim()));
      if (requested.every(Boolean)) return requested.map(use).join(" ");
      return line;
    }).join("\n");
    let result = lines.replace(attachedExponent, (_, base, exponent) => base + use(superscript(exponent)))
      .replace(/(?<=[A-Za-z0-9_\])])[ \t]*(?:逻辑或|邏輯或)[ \t]*(?=[A-Za-z0-9_(\[])/gu, () => " " + use("∨") + " ")
      .replace(/^[ \t]*井[号號][ \t]*(\d+)(?=[ \t，。！？,.!?]|$)/gmu, (_, number) => use("#") + number)
      .replace(/^[ \t]*井[号號][ \t]*空格[ \t]*(?=\S)/gmu, () => use("#") + " ")
      .replace(/^[ \t]*艾特[ \t]*(?!一下|别人|別人|对方|對方|功能)([A-Za-z0-9_][A-Za-z0-9_-]*|\p{Script=Han}{2,4})(?=[ \t，。！？：,.!?:]|$)/gmu,
        (_, handle) => use("@") + handle);
    // Bare domain names are protected literals. Join a dictated address up to
    // that boundary without editing the actual domain token.
    if (/^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$/u.test(followingLiteral ?? "")) {
      result = result.replace(/([A-Za-z0-9._%+-]+)[ \t]*(?:艾特|at 符[号號])[ \t]*$/iu, (_, mailbox) => mailbox + use("@"));
    }
    return result.replace(spokenEnding, (match, name, offset, line) => {
      const earlier = line.slice(0, offset).split("\n").at(-1);
      return !earlier.trim() || mentionOfSymbol.test(earlier) ? match : use(symbols.get(name.toLowerCase()));
    });
  });
  return { text, required };
}

export function keepsSpokenSymbols(text, required) {
  const remaining = new Map();
  for (const symbol of required) remaining.set(symbol, (remaining.get(symbol) ?? 0) + 1);
  if (!remaining.size) return true;
  const alternatives = [...remaining.keys()].sort((a, b) => b.length - a.length)
    .map(symbol => symbol.replace(/[.*+?^${}()|[\]\\]/gu, "\\$&"));
  for (const [symbol] of text.matchAll(new RegExp(alternatives.join("|"), "gu"))) {
    const count = remaining.get(symbol);
    if (count === 1) remaining.delete(symbol);
    else if (count > 1) remaining.set(symbol, count - 1);
  }
  return remaining.size === 0;
}
