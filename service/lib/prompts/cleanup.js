/** Dictation cleanup: the task. The shared boundary and reply format follow it. */
export const CLEANUP_PROMPT = `把语音识别文本整理成可以直接使用的书面文字。先通读全文，理解说话人最终想表达什么，再自行判断如何整理：纠正识别错误，去掉口误、重复和改口过程，按需要调整措辞、顺序、标点和格式。沿用口述的语言。`;
export function cleanupSystemPrompt() { return CLEANUP_PROMPT; }
