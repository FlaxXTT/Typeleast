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

/** Translation needs time for target-language output, even for a short source. */
function translationParameters(text, config) {
  return { ...cleanupParameters(text, "prompt", config),
    timeoutMs: Math.min(config.timeoutMs ?? 300000, 300000, Math.max(90000, Array.from(text).length * 80)) };
}

export async function runTranslation(ctx, target) {
  const { request, base, started, rawText, config } = ctx;
  const task = new CleanupTask(request.signal);
  const batches = translateBatches(rawText);
  const parts = [];
  let attempts = 0;
  const incomplete = (reason, offerFailover = false) => ctx.fail({ ...base, text: tidy(rawText).text,
    fallback: true, reason, ...(offerFailover ? { offerFailover: true } : {}), ms: timing(started, 0),
    translated: target, attempts,
    ...(parts.length && parts.length < batches.length && reason !== "cancelled"
      ? { translationProgress: { text: parts.join("\n").trimEnd(), completed: parts.length, total: batches.length } }
      : {}),
  });
  try {
    ctx.progress("translating");
    const system = directTranslatePrompt(target, request.translatePrompt)
      + (target === "en" ? variantInstruction(parseVariants(request.variants)) : "")
      + "\nTranslate all source lines in order. Preserve blank lines between paragraphs.";
    // At most TRANSLATE_BATCH paragraphs per request; the rest follow in later batches.
    for (const batch of batches) {
      const result = await ctx.complete({ system, user: translateUserMessage(target, ctx.redact(batch)),
        ...translationParameters(batch, config), temperature: 0, signal: task.signal, retryBudget: task });
      attempts += result.attempts ?? 1;
      const text = unwrap(String(result.text ?? "")).text.trim();
      if (!text) return incomplete(parts.length ? "partial-output" : "empty-output");
      const trailingBlankLines = batch.match(/(?:\n[^\S\n]*)+$/u)?.[0] ?? "";
      parts.push(text + trailingBlankLines);
    }
    const translated = parts.join("\n");
    task.assertTime();
    if (!translated) return incomplete("empty-output");
    const review = await reviewFacts(ctx, task, rawText, translated);
    if (review.state !== "clear") return ctx.fail({ ...base, raw: "", text: "", fallback: true,
      reason: "fact-review", qualityReview: { kind: "facts", original: rawText, candidate: translated, issues: review.issues ?? [] }, translated: target, ms: timing(started, 0), attempts });
    return ctx.done({ ...base, text: translated, translated: target, ms: timing(started, 0), attempts });
  } catch (error) {
    const reason = request.signal?.aborted ? "cancelled" : task.deadline.timedOut() ? "model-timeout" : failureReason(error);
    return incomplete(reason, error?.offerFailover === true);
  } finally { task.dispose(); }
}
