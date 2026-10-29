/** Dictation cleanup: what to do with this one utterance. The shared rules define fidelity and names. */
export const CLEANUP_PROMPT = `整理语音识别文本，写成可以直接使用的书面文字。先理解全文和最后的表达，再组织正文：清楚的内容少改；混乱的内容可以重排、合并重复、恢复明确的指代。从开头到结尾的内容都写进正文，篇幅随内容而定。沿用口述的语言，中英混说照样混说。找词和拼读过程只用来理解，正文写确定后的词；被解释的名称本身保留，帮读者认出对象的简短说明可放在括号里，用户要求写出的解释照写。几项并列的事项、步骤或要求用编号列表更易读时，用编号列表。否定、引用、强调和有意义的口语都是内容。`;
export function cleanupSystemPrompt() { return CLEANUP_PROMPT; }
