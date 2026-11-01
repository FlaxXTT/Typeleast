/**
 * Translation (spoken, or selected text): the maintainer's academic translation prompt, the text
 * in the maintainer's user template, temperature 0, at most 8 paragraphs per request.
 * The dictation cleanup prompt is not used here.
 */

/** Target languages the apps offer, with the name the prompt uses. */
export const TRANSLATE_LANGUAGES = {
  en: "English",
  zh: "中文",
  ja: "日本語",
  ko: "한국어",
  fr: "Français",
  de: "Deutsch",
  es: "Español",
  pt: "Português",
  it: "Italiano",
  ru: "Русский",
};

/** The maintainer's translation prompt, verbatim; {{to}} is the target language. */
export const TRANSLATE_PROMPT = "Translate academic and research content into {{to}} using precise disciplinary terminology and a formal scholarly register. Preserve the scope, uncertainty, complexity, and logical force of claims without simplifying or strengthening them. Treat quantitative expressions and author-year citations as protected source spans: copy formulas, statistical labels, values, brackets, ASCII punctuation, and author strings exactly as written, including forms such as `β = 0.42`, `95% CI [0.10, 0.74]`, `p < 0.05`, and `Smith et al. (2021)`; translate only the surrounding prose. Keep scientific notation, symbols, references, bibliographic data, abbreviations, and named methods accurate, using established target-language terminology where available outside those protected spans.\n{{title_prompt}}{{summary_prompt}}{{terms_prompt}}";

/** Paragraphs translated per request. */
export const TRANSLATE_BATCH = 8;

function languageName(target) {
  const name = TRANSLATE_LANGUAGES[target] ?? TRANSLATE_LANGUAGES.en;
  return target === "zh" ? name + "（简体中文）" : name;
}

/** The system prompt for one translation; the title, summary and terms slots are empty here. */
export function directTranslatePrompt(target) {
  return TRANSLATE_PROMPT.replaceAll("{{to}}", languageName(target))
    .replace("{{title_prompt}}", "").replace("{{summary_prompt}}", "").replace("{{terms_prompt}}", "").trim();
}

/** The user message: the maintainer's template with the text to translate. */
export function translateUserMessage(target, text) {
  return `Translate to ${languageName(target)}:\n\n${text}`;
}

/** The text split into batches of at most TRANSLATE_BATCH non-empty paragraphs (lines). */
export function translateBatches(text) {
  const paragraphs = String(text ?? "").split(/\r?\n/).map(p => p.trim()).filter(Boolean);
  const batches = [];
  for (let i = 0; i < paragraphs.length; i += TRANSLATE_BATCH) batches.push(paragraphs.slice(i, i + TRANSLATE_BATCH).join("\n"));
  return batches;
}
