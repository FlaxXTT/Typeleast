/**
 * Translation: one call cleans up and translates the transcript. On failure the tidied
 * original is inserted. The context is the one described in tasks/dictation.js.
 *
 * @module typeleast-service/tasks/translation
 */
import { CleanupTask, cleanupParameters } from "../cleanup-task.js";
import { failureReason } from "../llm.js";
import { directTranslatePrompt, translateBatches, translateUserMessage } from "../prompts/translate.js";
import { tidy } from "../tidy.js";
import { unwrap } from "../validate.js";
import { parseVariants, variantInstruction } from "../variants.js";
import { timing } from "./timing.js";
import { reviewFacts } from "../fact-review.js";

export async function runTranslation(ctx, target) {
  const { request, base, started, rawText, config } = ctx;
  const task = new CleanupTask(request.signal);
  try {
    ctx.progress("translating");
    const system = directTranslatePrompt(target, request.translatePrompt) + (target === "en" ? variantInstruction(parseVariants(request.variants)) : "");
    // At most TRANSLATE_BATCH paragraphs per request; the rest follow in later batches.
    const parts = [];
    let attempts = 0;
    for (const batch of translateBatches(rawText)) {
      const result = await ctx.complete({ system, user: translateUserMessage(target, ctx.redact(batch)),
        ...cleanupParameters(batch, "prompt", config), temperature: 0, signal: task.signal, retryBudget: task });
      attempts += result.attempts ?? 1;
      parts.push(unwrap(String(result.text ?? "")).text.trim());
    }
    const translated = parts.filter(Boolean).join("\n");
    task.assertTime();
    if (!translated) return ctx.fail({ ...base, text: tidy(rawText).text, fallback: true, reason: "empty-output", ms: timing(started, 0), translated: target });
    if (!await reviewFacts(ctx, task, rawText, translated)) return ctx.fail({ ...base, raw: "", text: "", fallback: true,
      reason: "fact-review", qualityReview: { kind: "facts", original: rawText, candidate: translated, issues: ctx.reviewEvidence ?? [] }, translated: target, ms: timing(started, 0), attempts });
    return ctx.done({ ...base, text: translated, translated: target, ms: timing(started, 0), attempts });
  } catch (error) {
    const reason = request.signal?.aborted ? "cancelled" : task.deadline.timedOut() ? "model-timeout" : failureReason(error);
    return ctx.fail({ ...base, text: tidy(rawText).text, fallback: true, reason,
      ...(error?.offerFailover === true ? { offerFailover: true } : {}), ms: timing(started, 0), translated: target });
  } finally { task.dispose(); }
}
