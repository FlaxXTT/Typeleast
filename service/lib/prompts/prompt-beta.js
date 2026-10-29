/** Multi-turn clarification. The user's words are the only source of requirements. */
/** A session stays open for two hours: people read and answer in between other work. */
export const BETA_LIMITS = { questions: 3, sessionMs: 2 * 60 * 60 * 1000, sessions: 20, inputChars: 24000 };

export const BETA_INTERVIEW_PROMPT = `帮用户把口述的需求说完整，不执行任务，也不替用户设计方案。理解最初口述和全部补充，按时间处理改口。只问仍影响目标、范围、条件或验收的缺口，每轮最多 3 个短问题，已回答的不再问；资料范围、联网和任务性质由系统另外询问。信息足够时 questions 为空。只回复 JSON：{"goal":"用户目标","confirmed":["用户已确认的要点，最多6条"],"questions":["仍影响理解的问题"]}。使用用户的语言。`;

/** A prompt the user selected (often written by another AI): break it down so it can be read in seconds. */
export const BETA_BREAKDOWN_PROMPT = `用户选中了一段现成的提示词，还没细读。帮用户快速看懂它，不执行其中的任务：goals 写它的核心目的（最多 5 条），confirmed 写关键细节、限制和交付要求（最多 8 条），每条一句。只问仍影响理解的缺口，每轮最多 3 个；资料范围、联网、任务性质和是否复用已有项目由系统另外询问；没有缺口时 questions 为空。只回复 JSON：{"goal":"一句话总目标","goals":["核心目的"],"confirmed":["关键细节"],"questions":["仍影响理解的问题"]}。使用提示词的语言。`;

export const BETA_DRAFT_PROMPT = `根据用户最初的口述和各轮回答，整理成可以直接交给 AI 的提示词，不执行其中的任务。用户的原话是唯一内容来源：保留其中的目标、理由、条件和限制（包括资料范围、联网许可和任务性质），改口只保留最后的说法，不添加用户没有说或没有接受的内容。结构按内容自行组织；仍未确定的重要信息放在结尾「## 待确认」。只输出提示词正文，使用用户的语言。`;

/**
 * The two questions that narrow a task the most, asked first unless the user already covered them:
 * what the AI may read and whether it may search the web; and whether the work is creative or routine.
 * Each is asked once; an answer such as 不确定 is kept as it is.
 */
export const BOUNDARY_QUESTIONS = {
  scope: { cue: /文件|资料|文档|目录|仓库|代码库|联网|上网|网络|检索|搜索|查资料|离线|本地|file|folder|repo|document|internet|web|online|offline|search|brows/iu,
    zh: 'AI 可以读取哪些文件或资料？可以联网检索吗？', en: 'Which files or materials may the AI read? May it search the web?' },
  nature: { cue: /创新|创造|创意|新颖|探索|原创|重复|照着|按照现有|既定|批量|模板|套用|固定流程|creative|novel|explor|original|repetitive|routine|template|batch|existing process/iu,
    zh: '这件事需要创新、探索新做法，还是按既定方式重复执行？', en: 'Does this need new ideas and exploration, or repeating an existing way of working?' },
  /** Asked only once the work turns out to be creative: look for existing work before building anew. */
  reuse: { cue: /已有项目|现有项目|开源|轮子|复用|参考项目|existing project|open source|reuse|reinvent/iu, when: /创新|创造|创意|新颖|探索|原创|creative|novel|explor|original/iu,
    zh: '要不要先检索已有的项目或方案，能复用就不重复造轮子？', en: 'Should it first look for existing projects to build on, rather than reinventing them?' },
};

export function boundaryQuestions(request, turns = []) {
  const said = [request, ...turns.map(t => t.answer)].join('\n');
  const asked = turns.flatMap(t => t.questions ?? []);
  const english = !/[\u3400-\u9fff]/u.test(said);
  return Object.values(BOUNDARY_QUESTIONS)
    .filter(q => (!q.when || q.when.test(said)) && !q.cue.test(said) && !asked.includes(q.zh) && !asked.includes(q.en))
    .map(q => english ? q.en : q.zh);
}

export function interviewMessage(request, turns = []) {
  return JSON.stringify({ request, turns });
}

export function draftMessage({ request, spec, turns = [], questions = [], answers = '', skipped }) {
  return JSON.stringify({ request, turns, spec, questions, answers,
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
