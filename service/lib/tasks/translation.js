/**
 * Translation: one call cleans up and translates the transcript. On failure the tidied
 * original is inserted. The context is the one described in tasks/dictation.js.
 *
 * @module typeleast-service/tasks/translation
 */
import { CleanupTask, cleanupParameters } from "../cleanup-task.js";
import { failureReason } from "../llm.js";
import { directTranslatePrompt } from "../prompts/translate.js";
import { tidy } from "../tidy.js";
import { unwrap } from "../validate.js";
import { parseVariants, variantInstruction } from "../variants.js";
import { timing } from "./timing.js";

export async function runTranslation(ctx, target) {
  const { request, base, started, rawText, config } = ctx;
  const task = new CleanupTask(request.signal);
  try {
    ctx.progress("translating");
    const result = await ctx.complete({ system: directTranslatePrompt(target)
      + (target === "en" ? variantInstruction(parseVariants(request.variants)) : ""),
      user: ctx.redact(rawText),
      ...cleanupParameters(rawText, "prompt", config), temperature: 0.2, signal: task.signal, retryBudget: task });
    const translated = unwrap(String(result.text ?? "")).text.trim();
    task.assertTime();
    if (!translated) return ctx.fail({ ...base, text: tidy(rawText).text, fallback: true, reason: "empty-output", ms: timing(started, 0), translated: target });
    return ctx.done({ ...base, text: translated, translated: target, ms: timing(started, 0), attempts: result.attempts });
  } catch (error) {
    const reason = request.signal?.aborted ? "cancelled" : task.deadline.timedOut() ? "model-timeout" : failureReason(error);
    return ctx.fail({ ...base, text: tidy(rawText).text, fallback: true, reason, ms: timing(started, 0), translated: target });
  } finally { task.dispose(); }
}
