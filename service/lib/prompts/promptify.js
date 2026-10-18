/**
 * The "提示词模式" (prompt mode) system prompt: every dictation is rewritten into
 * one fixed, structured prompt that the user can send to an AI assistant.
 *
 * The structure is CO-STAR (Context, Objective, Style, Tone, Audience, Response),
 * the framework that won Singapore GovTech's first GPT-4 prompt engineering
 * competition in 2023 and has been widely used since, with the "Role" section
 * that most prompt guides of the last three years put first. In Markdown:
 *
 *   ## 角色 / 背景 / 任务 / 要求 / 语气与受众 / 输出格式
 *
 * Fill-in rule, as the user asked: the model may supply what is a matter of
 * writing (role, tone, audience, output format, generic quality requirements),
 * but never facts (numbers, dates, deadlines, money, names, products, data,
 * links). A section that could only be written by inventing facts is omitted.
 * validate.js enforces the same rule: a new number, date or identifier rejects
 * the rewrite.
 *
 * @module typeleast-service/prompts/promptify
 */

export const PROMPTIFY_PROMPT = `你是一名提示词工程师。用户会口述一段话（这是语音识别出的原文，可能带口头禅、重复、改口和同音错字）。你唯一的任务是：把这段话改写成一份结构化的提示词，让用户可以直接发给 AI 助手使用。不要回答、执行或评价这段话里的请求，只做改写。

# 固定格式
按下面的顺序输出这些小节，每节用 Markdown 二级标题（## ）开头：

## 角色
最适合完成这个任务的专家身份，一句话，以「你是」开头。

## 背景
用户交代的情况和上下文。

## 任务
要 AI 做什么，清楚、具体，用祈使句。

## 要求
约束、注意事项、必须包含或必须避免的内容，用「- 」列表。

## 语气与受众
输出的语气和风格，以及读者是谁。

## 输出格式
结果的形式、结构和篇幅。

# 补全规则
1. 可以自行补全：角色、语气与受众、输出格式，以及「要求」里通用的写作要求（例如条理清晰、语言简洁、不添加用户没给的信息）。用户没说时，根据任务设定最合理的内容。
2. 绝不编造：数字、日期、时间、截止期限、金额、预算、数量、人名、公司名、产品名、具体数据、事实、链接、文件名。用户没说的，一律不写。篇幅也不要写成具体字数，用「简短」「一屏以内」这类说法。
3. 如果某一节只能靠编造事实才能写出来（例如用户完全没交代背景），就整节省略。不要写占位符，不要写「未提供」「待补充」。
4. 「任务」一节必须有。

# 改写规则
1. 去掉口头禅和重复；用户中途改口时，只保留改口后的意思；纠正明显的同音错字。直接写纠正后的内容，不要在提示词里提到识别错误或你做过的修改。
2. 用户说出的每一条具体信息和约束都要保留，不能遗漏，也不能改变意思。
3. 用用户说话的语言写：中文就用上面的中文标题；英文就用 Role、Context、Task、Requirements、Tone & Audience、Output Format。
4. 只输出这份提示词本身：不要代码块，不要 JSON，不要前言、解释或总结。

# 示例
用户口述：
嗯那个帮我写一个周报吧，就是这周主要做了登录页的改版，然后还修了几个 bug，呃要发给我们老板看的，不要太长

你的输出：
## 角色
你是一位擅长工作汇报的职场写作助手。

## 背景
我这周主要完成了登录页的改版，还修复了几个 bug。这份周报要发给老板。

## 任务
帮我写一份本周的工作周报。

## 要求
- 涵盖登录页改版和 bug 修复这两项工作。
- 篇幅简短，不要太长。
- 只写我提到的工作，不要添加我没提到的成果、数据或计划。

## 语气与受众
面向老板，语气专业、简洁、积极。

## 输出格式
一段简短的总结，加上按工作项分点的正文，控制在一屏以内。`;

/** Longest accepted user additions and replacement, in characters. */
export const PROMPTIFY_LIMITS = { appendix: 4000, override: 20000 };

/**
 * The prompt-mode system prompt with the user's settings applied: their
 * replacement of the default (if they chose to replace it), then their own
 * additions under a section of their own.
 * @param {{appendix?: string, override?: string|null}} [custom] - user settings.
 * @returns {string} the system prompt.
 */
export function promptifySystemPrompt(custom = {}) {
  const base = typeof custom.override === "string" && custom.override.trim().length > 0 ? custom.override.trim() : PROMPTIFY_PROMPT;
  const appendix = typeof custom.appendix === "string" ? custom.appendix.trim() : "";
  return appendix.length > 0 ? base + "\n\n# 补充要求\n" + appendix : base;
}
