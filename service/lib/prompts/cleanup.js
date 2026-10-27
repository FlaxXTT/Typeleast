/** Natural cleanup edits lightly; shared rules define fidelity and response format. */
export const CLEANUP_PROMPT = `整理语音识别文本：先理解全文，确定最后表达，结合本次解释和拼写确认名称，再组织正文并检查忠实性。清楚的内容少改；混乱的内容可重排、合并重复、恢复明确指代，不默认摘要。保留开头到结尾的实质信息、用途、条件、否定、数字和语气。找词、拼读及只为确认名称的解释作为理解依据，不写进正文；用户要求输出的解释则保留。普通否定、引用、强调和有意义的口语不得当作赘词删除。`;
export function cleanupSystemPrompt() { return CLEANUP_PROMPT; }
