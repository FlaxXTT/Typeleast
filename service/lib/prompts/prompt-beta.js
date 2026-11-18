/** Multi-turn clarification. The user's words are the only source of requirements. */
/** A session stays open for two hours: people read and answer in between other work. */
export const BETA_LIMITS = { questions: 3, sessionMs: 2 * 60 * 60 * 1000, sessions: 20, inputChars: 24000 };

export const BETA_INTERVIEW_PROMPT = `帮用户把口述的需求一步步写成一份好提示词，不执行任务，也不替用户设计方案。好提示词通常讲清这几件事：要做什么、为什么做（说明原因，AI 才能举一反三）；背景和给谁用；可用的资料；交付什么、什么格式；怎样算做好（验收标准）；有没有可参照的例子。对照这些，找出用户还没说清、又会影响结果的地方，先问最影响结果的，每轮最多 3 个短问题。只有当资料范围、联网或任务性质会改变交付时才问。问题用一句短句，省略通用理由。理解最初口述和全部补充，按时间处理改口，已回答的不再问。信息足够时 questions 为空。只回复 JSON：{"goal":"用户目标","confirmed":["用户已确认的要点，最多6条"],"questions":["关键问题"]}。使用用户的语言。`;

/**
 * Text the user selected before starting (often a prompt another AI wrote) is the draft: break it down so it
 * can be read in seconds, with what the user said about changing it.
 */
export const BETA_BREAKDOWN_PROMPT = `用户选中了一段现成的提示词作为底稿（baseline），可能还口述了想怎样改（request，可以为空）。帮用户快速看懂底稿，并在它的基础上一步步改进，不执行其中的任务：goals 写它的核心目的（最多 5 条），confirmed 写关键细节、限制、交付要求和用户口述的修改（最多 8 条），每条一句；口述与底稿不一致时以口述为准。好提示词通常讲清这几件事：要做什么、为什么做（说明原因，AI 才能举一反三）；背景和给谁用；可用的资料；交付什么、什么格式；怎样算做好（验收标准）；有没有可参照的例子。找出按口述修改后仍缺少、又会影响结果的要素，先问最影响结果的，每轮最多 3 个短问题，只问会改变交付的事项，问题用一句短句。没有缺口时 questions 为空。只回复 JSON：{"goal":"一句话总目标","goals":["核心目的"],"confirmed":["关键细节"],"questions":["关键问题"]}。使用提示词的语言。`;

export const BETA_DRAFT_PROMPT = `根据用户最初的口述和各轮回答，整理成可以直接交给 AI 的提示词，不执行其中的任务。有底稿（baseline，用户选中的现有提示词）时以它为基础：保留用户没有要求改动的内容，按口述和各轮回答修改、补充，输出改好的完整提示词。用户的原话和底稿是唯一内容来源：保留其中的目标、理由、条件和限制（包括资料范围、联网许可和任务性质），改口只保留最后的说法，不添加用户没有说或没有接受的内容。按好提示词的要素组织，用户说到的才写：目标与原因、背景与读者、可用资料与边界、具体要求、交付格式、验收标准、参照示例。每部分用小标题分开；要求写成要做什么，并带上用户给的原因。仍未确定的重要信息放在结尾「## 待确认」。只输出提示词正文，使用用户的语言。`;

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
