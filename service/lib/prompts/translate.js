/**
 * Translation mode has its own hotkey: one call cleans up and translates the recognised
 * transcript. The dictation cleanup prompt is not used here.
 */

import { UTTERANCE_RULES } from "../utterance-rules.js";

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

/** Translation mode: clean up and translate the spoken transcript in one call. */
export function directTranslatePrompt(target) {
  const name = TRANSLATE_LANGUAGES[target] ?? TRANSLATE_LANGUAGES.en;
  const script = target === "zh" ? "（简体中文）" : "";
  return `把语音识别文本理解并整理后译成${name}${script}，译文地道自然；原话已是${name}时只整理。` + UTTERANCE_RULES + "只输出译文。";
}
