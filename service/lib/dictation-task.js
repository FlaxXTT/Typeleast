import {TRANSLATE_LANGUAGES} from './prompts/translate.js';
/** Task identity is independent of retired cleanup-strength settings. */
export const TASKS = ['dictation', 'translation', 'assistant'];
export function taskFor(request = {}) {
  if (request.task !== undefined) {
    if (!TASKS.includes(request.task)) throw Object.assign(new Error('unsupported task'), {code:'invalid-task'});
    return request.task;
  }
  if (Object.hasOwn(TRANSLATE_LANGUAGES,request.translateTo ?? '')) return 'translation';
  return request.strength === 'promptbeta' ? 'assistant' : 'dictation';
}
