import { readFileSync } from "node:fs";
import { readSavedPrompt } from "../prompt.js";

const PROMPT_FILES = {
  interview: "prompt-mode-clarify.md",
  breakdown: "prompt-mode-breakdown.md",
  draft: "prompt-mode-draft.md",
};

function bundledPrompt(filename) {
  return readFileSync(new URL(filename, import.meta.url), "utf8").trim();
}

/** Multi-turn clarification. The user's words are the only source of requirements. */
/** A session stays open for two hours: people read and answer in between other work. */
export const BETA_LIMITS = { questions: 3, sessionMs: 2 * 60 * 60 * 1000, sessions: 20, inputChars: 24000 };

export const BETA_INTERVIEW_PROMPT = bundledPrompt(PROMPT_FILES.interview);

/**
 * Text the user selected before starting (often a prompt another AI wrote) is the draft: break it down so it
 * can be read in seconds, with what the user said about changing it.
 */
export const BETA_BREAKDOWN_PROMPT = bundledPrompt(PROMPT_FILES.breakdown);

export const BETA_DRAFT_PROMPT = bundledPrompt(PROMPT_FILES.draft);

const BUILTIN_PROMPTS = {
  interview: BETA_INTERVIEW_PROMPT,
  breakdown: BETA_BREAKDOWN_PROMPT,
  draft: BETA_DRAFT_PROMPT,
};

const OUTPUT_FORMAT = {
  interview: '只回复 JSON 对象。goal 是一句话目标，confirmed 和 questions 是字符串数组。信息足够时 questions 为空数组。',
  breakdown: '只回复 JSON 对象。goal 是一句话目标，goals、confirmed 和 questions 是字符串数组。信息足够时 questions 为空数组。',
  draft: '只输出最终的提示词正文。',
};

export function defaultAssistantPrompt(stage) {
  return BUILTIN_PROMPTS[stage];
}

export async function savedAssistantPrompt(stage, stateDir, { logger, redact }) {
  const custom = await readSavedPrompt(stateDir, PROMPT_FILES[stage], logger);
  const builtin = defaultAssistantPrompt(stage);
  return custom && custom !== builtin ? redact(custom) + "\n\n" + OUTPUT_FORMAT[stage] : builtin;
}

export function interviewMessage(request, turns = [], baseline = '') {
  return JSON.stringify(baseline ? { baseline, request, turns } : { request, turns });
}

export function draftMessage({ baseline = '', request, spec, turns = [], questions = [], answers = '', skipped }) {
  return JSON.stringify({ ...(baseline ? { baseline } : {}), request, turns, spec, questions, answers,
    instruction: skipped ? '用户主动结束补充。未确认内容列在待确认，不替用户决定。' : '仅根据用户原话整理。' });
}

export function reviewMessage({ request, answers, turns = [], draft, issues }) {
  return JSON.stringify({ request, turns, answers, draft, ...(issues ? { issues } : {}) });
}

/**
 * True when a transcript says something: recogniser tokens such as <sil>,
 * punctuation and bare fillers (嗯、啊、um) do not count. Without this a silent
 * recording would still produce a prompt written about nothing.
 */
export function hasContent(text) {
  const rest = String(text ?? "")
    .replace(/<[^<>]{0,20}>/g, "")
    .replace(/\b(?:um+|uh+|er+|hmm+|ah+)\b/gi, "")
    .replace(/[嗯啊呃哦唔额噢诶哎呀吧呢]/g, "")
    .replace(/[\s\p{P}\p{S}]/gu, "");
  return rest.length >= 2;
}

/** Pull the first JSON object out of a model reply; null when there is none. */
export function parseJsonReply(text) {
  const raw = String(text ?? "").trim().replace(/^```[a-z]*\s*/i, "").replace(/```\s*$/, "");
  const start = raw.indexOf("{");
  const end = raw.lastIndexOf("}");
  if (start < 0 || end <= start) return null;
  try {
    return JSON.parse(raw.slice(start, end + 1));
  } catch {
    return null;
  }
}

/** Strip a code fence a model may wrap around the finished prompt. */
export function cleanPromptReply(text) {
  return String(text ?? "").trim().replace(/^```[a-z]*\s*\n/i, "").replace(/\n```\s*$/, "").trim();
}

/** Keep at most BETA_LIMITS.questions short, distinct, non-empty questions. */
export function normaliseQuestions(list) {
  if (!Array.isArray(list)) return [];
  const seen = new Set();
  const out = [];
  for (const item of list) {
    const q = String(item ?? "").trim();
    if (!q || q.length > 200 || seen.has(q)) continue;
    seen.add(q);
    out.push(q);
    if (out.length === BETA_LIMITS.questions) break;
  }
  return out;
}
