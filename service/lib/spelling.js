import { mapOutsideLiterals } from "./punctuation.js";

// Runs of single letters joined by dashes or spaces can encode explicit spelling.
// Cased letters let adjacent text in uncased scripts delimit an alphabetic spelling.
const letter = String.raw`\p{Cased}\p{M}*`;
const edge = String.raw`[\p{Cased}\p{M}\p{N}\p{Pd}/／]`;
const spelling = String.raw`${letter}(?:(?:[ \t]*[\p{Pd}/／][ \t]*${letter}){2,}|(?:[ \t]+${letter}){3,})`;
const spelledWord = new RegExp(String.raw`(?<!${edge})${spelling}(?!${edge})`, "gu");
const echo = new RegExp(String.raw`(?<!${edge})((?:${letter}){2,})(?:[ \t]*[,，:：][ \t]*|[ \t]+)(${spelling})(?!${edge})`, "gu");
const separators = /[ \t\p{Pd}/／]+/gu;
const assemble = (spelling) => spelling.replace(separators, "");
const wordsIn = (text) => text.normalize("NFC").toLowerCase().match(/[\p{Cased}\p{M}\p{N}]+/gu) ?? [];

export function removeSpellingEchoes(text, resolved = text) {
  const resolvedWords = new Set(wordsIn(resolved));
  return mapOutsideLiterals(text, part => part.replace(echo, (match, named, letters) => {
    const token = named.normalize("NFC").toLowerCase();
    const spelled = assemble(letters).normalize("NFC").toLowerCase();
    if (token === spelled) return named;
    // A few spelled letters can also be misheard. Only accept a nearby name the
    // cleaned text actually retains, and keep shorter or unrelated spellings binding.
    if (!/^[A-Z][a-z]+$/.test(named) || !/^[a-z]+$/.test(spelled) || token.length < 7
        || token.length !== spelled.length || !resolvedWords.has(token) || resolvedWords.has(spelled)) return match;
    const mismatches = Array.from(token).filter((character, index) => character !== spelled[index]).length;
    return mismatches <= 2 ? named : match;
  }));
}

export function assembleSpelledWords(text) {
  return text.replace(spelledWord, assemble);
}

export function losesSpelledWords(source, candidate) {
  const supportedSource = removeSpellingEchoes(source, candidate);
  const spellings = Array.from(supportedSource.normalize("NFC").matchAll(spelledWord), ([word]) => assemble(word).toLowerCase());
  if (!spellings.length) return false;
  const words = new Set(assembleSpelledWords(candidate.normalize("NFC")).toLowerCase().match(/[\p{Cased}\p{M}\p{N}]+/gu));
  return spellings.some(word => !words.has(word));
}
