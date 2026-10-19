/**
 * Prompt Beta (提示词 Beta): three separate model calls that turn a dictated
 * request into the best prompt it can be, following the 2026 practice of
 * "interview -> spec -> draft -> review in a fresh context -> minimal patch".
 *
 * 1. INTERVIEW reads the request, writes a spec and asks only the questions
 *    whose answers would change the prompt. Contradictions that the speaker did
 *    not resolve become questions, never two instructions side by side.
 * 2. DRAFT writes the prompt from the request, the spec and the user's spoken
 *    answers.
 * 3. REVIEW sees the draft in a fresh call and only diagnoses; PATCH then makes
 *    the smallest edit that fixes what REVIEW found.
 *
 * The existing 提示词模式 prompt (promptify.js) is unchanged; this is a separate
 * strength, "promptbeta".
 */

export const BETA_LIMITS = { questions: 4, sessionMs: 15 * 60 * 1000, sessions: 20 };

export const BETA_INTERVIEW_PROMPT = `你是一名需求分析师，帮用户把一段口述的需求整理成一份写提示词用的规格。用户会口述一段话（这是语音识别出的原文，可能带口头禅、重复、改口和同音错字），内容是他想让 AI 帮他做的一件事。你不回答、不执行这件事，只分析它。

# 你要做的
1. 读懂用户想要什么：最终要拿到什么、给谁用、做到什么程度算好。
2. 找出会让提示词写偏的不确定点：
   - 用户中途改口的，以最后的说法为准，不算不确定。
   - 前后说法互相矛盾、又没有改口的，算不确定。不要替用户二选一。
   - 同一句话可以有两种明显不同的理解、而且两种理解会写出完全不同的提示词的，算不确定。
3. 只对「答案不同、提示词就会明显不同」的不确定点提问，最多 4 个，按重要程度排序。能合理假设的就不问，写进假设里。用户的需求已经清楚时，不提问。
4. 问题要短，一个问题只问一件事，用户能直接口头回答；需要选择时，把选项写进问题里（例如「给老板看还是给客户看？」）。

# 不能做的
- 不编造用户没说的事实：数字、日期、人名、公司名、产品名、具体数据。没有的就算缺失。
- 不把两个互相矛盾的要求都写进规格；它们只能出现在问题里。

# 输出
只输出一个 JSON 对象，不要代码块，不要解释：
{"goal":"一句话目标","audience":"读者或用途，没说就写空字符串","success":["可检查的成功标准"],"constraints":["用户明确提出的约束"],"output":"想要的输出形式，没说就写空字符串","assumptions":["你做的合理假设"],"questions":["问题"]}
所有文字用用户说话的语言。`;

export const BETA_DRAFT_PROMPT = `你是提示词写作者。根据用户口述的需求、整理好的规格和用户对问题的回答，写一份最好的提示词，让用户直接发给一个聪明但对背景一无所知的 AI 模型使用。目标不是写得短，而是把用户想要表达、想要完成的东西写得明确、完整、没有歧义。

# 结构
按下面的顺序分节，每节用 Markdown 二级标题（## ）开头；用不上的节整节省略，不写占位符：
- 角色与情境：1–2 句，交代场景、为谁服务、读者是什么水平。这是交代语境，不要写「你是世界顶级专家」。
- 目标：用户最终拿到什么，为什么要做这件事。
- 成功标准：交付前必须为真的 3–6 条，每条都能检查对错。
- 约束：用户明确提出的限制。
- 工作方式：信息不足时该提问还是先做假设并标出来；需要时写怎么验证结果。
- 输出：结构、篇幅、语气，用正面的说法描述要什么。
- 停止与兜底：做到什么算完成；拿不准时允许说明不知道或标注假设，不要硬凑。

# 写法
- 用自然语言写，不显然的要求后面加一句原因，让模型能把道理推广到没写到的情况。
- 需要判断的地方写成「当……时……，否则……」。
- 「必须」「绝不」只留给用户真正不能违反的要求；不用全大写、不用感叹号加重语气。
- 不写「一步步思考」「认真仔细」这类空话，也不写模型本来就会做的步骤。
- 需要放资料、原文或样例的地方，用 XML 标签留出位置（例如 <document>…</document>），并说明用户要把什么放进去。

# 内容规则
1. 用户说出的每一条具体信息和要求都要保留，不能遗漏，也不能改变意思。用户改口的，只保留最后的说法。
2. 用户对问题的回答优先于原来口述里的说法。
3. 绝不编造：数字、日期、时间、金额、数量、人名、公司名、产品名、具体数据、链接、文件名。用户没说的一律不写；篇幅用「简短」「一屏以内」这类说法。
4. 仍然不确定、或者互相矛盾的要求，两种说法都不要写进提示词正文。在提示词最后加一节「## 待确认」，每条一句话说明还需要用户确定什么。没有这种情况就不加这一节。
5. 直接写纠正后的内容，不要提到语音识别错误或你做过的修改。

# 输出
只输出这份提示词本身：不要代码块，不要前言、解释或总结。用用户说话的语言写；用户要求用其他语言写时照办。`;

export const BETA_REVIEW_PROMPT = `你是提示词审查员。你会看到用户口述的原始需求、用户对问题的回答，以及一份根据它们写好的提示词。你只诊断，不修改。

找出这份提示词里会让执行它的模型做错、或者让用户的意图打折扣的地方：
- contradiction：两句指令互相矛盾，或者同一件事给了两种要求。
- ambiguity：一句话能有两种明显不同的理解。
- invented：写进了用户没说过的具体事实（数字、日期、人名、产品名、具体数据等）。
- missing：用户说过的要求或回答没有写进去，或者意思被改变了。
- overemphasis：用「必须」「绝不」、全大写或感叹号去强调其实不是硬性的要求。
- filler：空话、重复，或者模型本来就会做的步骤，删掉也不会改变行为。

只报告真正会影响结果的问题，不要为了凑数挑刺。提示词没有问题时返回空列表。

只输出一个 JSON 对象，不要代码块，不要解释：
{"issues":[{"type":"上面的类型之一","quote":"提示词里的原句，缺失时写空字符串","why":"一句话说明它怎么把模型引向错误","fix":"一句话说明最小的改法"}]}`;

export const BETA_PATCH_PROMPT = `你是提示词编辑。你会看到一份提示词，以及审查员找到的问题。只修这些问题，做最小必要的修改：
- 优先删除或合并造成矛盾、冗余的句子，而不是追加新规则；总长度基本不变；不要整体重写，不要改变没有问题的部分。
- 矛盾、而且从用户原话和回答里判断不了该保留哪一边的，两边都从正文删掉，在最后的「## 待确认」一节里加一句说明（没有这一节就新建）。
- 绝不加入用户没说过的具体事实。

只输出修改后的完整提示词：不要代码块，不要修改说明。`;

/** The user message for the interview: the dictated request alone. */
export function interviewMessage(request) {
  return request;
}

/** The user message for the draft: request, spec and the spoken answers, as data. */
export function draftMessage({ request, spec, questions, answers, skipped }) {
  const parts = [`<request>\n${request}\n</request>`];
  if (spec) parts.push(`<spec>\n${JSON.stringify(spec, null, 2)}\n</spec>`);
  if (questions?.length) {
    const asked = questions.map((q, i) => `${i + 1}. ${q}`).join("\n");
    parts.push(`<questions>\n${asked}\n</questions>`);
    parts.push(skipped
      ? "<answers>用户跳过了这些问题。没有回答的不确定点放进「## 待确认」，不要替用户决定。</answers>"
      : `<answers>\n${answers}\n</answers>`);
  }
  parts.push("请根据以上材料写出提示词。");
  return parts.join("\n\n");
}

/** The user message for the review and the patch. */
export function reviewMessage({ request, answers, draft, issues }) {
  const parts = [`<request>\n${request}\n</request>`];
  if (answers) parts.push(`<answers>\n${answers}\n</answers>`);
  parts.push(`<prompt>\n${draft}\n</prompt>`);
  if (issues) parts.push(`<issues>\n${JSON.stringify(issues, null, 2)}\n</issues>`);
  parts.push(issues ? "请只针对 issues 修改 prompt，输出完整的新提示词。" : "请诊断这份提示词。");
  return parts.join("\n\n");
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
