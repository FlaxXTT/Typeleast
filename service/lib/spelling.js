// Runs of single letters joined by dashes or spaces can encode explicit spelling.
// Cased letters let adjacent text in uncased scripts delimit an alphabetic spelling.
const letter = String.raw`\p{Cased}\p{M}*`;
const edge = String.raw`[\p{Cased}\p{M}\p{N}\p{Pd}]`;
const spelledWord = new RegExp(String.raw`(?<!${edge})${letter}(?:(?:[ \t]*\p{Pd}[ \t]*${letter}){2,}|(?:[ \t]+${letter}){3,})(?!${edge})`, "gu");
const separators = /[ \t\p{Pd}]+/gu;
const assemble = (spelling) => spelling.replace(separators, "");

export function assembleSpelledWords(text) {
  return text.replace(spelledWord, assemble);
}

export function losesSpelledWords(source, candidate) {
  const spellings = Array.from(source.normalize("NFC").matchAll(spelledWord), ([word]) => assemble(word).toLowerCase());
  if (!spellings.length) return false;
  const words = new Set(assembleSpelledWords(candidate.normalize("NFC")).toLowerCase().match(/[\p{Cased}\p{M}\p{N}]+/gu));
  return spellings.some(word => !words.has(word));
}
