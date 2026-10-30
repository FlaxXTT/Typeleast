/**
 * Dictation: one model call cleans up the transcript (cleanup.md + the learned description +
 * the cursor context), and the JSON reply becomes the text to insert.
 *
 * Every task module takes the same context from the service (see service.js, taskContext):
 *   request, base, route, started, rawText, config, logger, stats,
 *   complete(options)  one model call with the user's route,
 *   redact(text)       credential-shaped strings removed when redaction is on,
 *   progress(stage)    the stage the app shows while it waits,
 *   done(result)       finish with a result,
 *   fail(result)       finish with a fallback from an attempt that reached the model.
 *
 * @module typeleast-service/tasks/dictation
 */
import { CleanupTask, cleanupParameters } from "../cleanup-task.js";
import { redactFieldContext } from "../context.js";
import { failureDetail, failureReason, ModelCallError } from "../llm.js";
import { parsePolishOutput } from "../parse-output.js";
import { buildUserMessage, systemPromptFor } from "../prompt.js";
import { tidy } from "../tidy.js";
import { unwrap } from "../validate.js";
import { parseVariants, variantInstruction } from "../variants.js";
import { timing } from "./timing.js";

/** Clean up one transcript; on any failure the tidied transcript is inserted instead. */
export async function runDictation(ctx) {
  const { request, base, route, started, rawText, config, logger, stats } = ctx;
  const task = new CleanupTask(request.signal);
  const redactOn = config.redactSecrets !== false;
  try {
    const system = systemPromptFor({
      fieldContext: redactFieldContext(request.fieldContext ?? null, redactOn),
      profile: ctx.redact(String(request.profile ?? "")),
    }) + variantInstruction(parseVariants(request.variants));
    // The transcript is redacted on the way OUT to the provider: a dictated key or
    // password must not reach the model. The user gets the model's text (or the original).
    const user = buildUserMessage({ rawText: ctx.redact(rawText) });
    ctx.progress("generating");
    const result = await ctx.complete({ system, user, ...cleanupParameters(rawText, request.strength, config),
      signal: task.signal, retryBudget: task });
    task.assertTime();
    // A reply that is not the expected JSON must not reach the document.
    const parsed = parsePolishOutput(result.text);
    if (!parsed.ok) {
      stats.jsonFallback += 1;
      const tidyOnly = tidy(rawText);
      const detail = `output-format:${parsed.failure ?? "unknown"}`;
      stats.lastError = detail;
      logger.warn?.("typeleast: unusable model reply (%s)", detail);
      return await ctx.fail({ ...base, text: tidyOnly.text, fallback: true, reason: "output-format", detail,
        ms: timing(started, 0), attempts: result.attempts, postprocess: tidyOnly.applied });
    }
    if (parsed.mode !== "json") stats.jsonRecovered += 1;
    // The cleaned text is inserted as the model wrote it, minus a wrapper a chatty model may add.
    const candidate = unwrap(parsed.text).text.trim();
    if (!candidate) {
      const tidyOnly = tidy(rawText);
      return await ctx.fail({ ...base, text: tidyOnly.text, fallback: true, reason: "empty-output",
        ms: timing(started, 0), attempts: result.attempts, postprocess: tidyOnly.applied });
    }
    return await ctx.done({
      ...base,
      text: candidate,
      ms: timing(started, 0),
      usage: result.usage,
      attempts: result.attempts,
      modelNote: parsed.reason ?? undefined,
      outputMode: parsed.mode,
      ...(parsed.corrections ? { corrections: parsed.corrections } : {}),
      ...(parsed.intention ? { intention: parsed.intention } : {}),
    });
  } catch (error) {
    if (!(error instanceof ModelCallError) && !request.signal?.aborted && !task.deadline.timedOut()) logger.warn?.("typeleast: internal cleanup error (%s)", error?.name ?? "error");
    const reason = request.signal?.aborted
      ? "cancelled"
      : task.deadline.timedOut() ? "model-timeout" : error instanceof ModelCallError ? failureReason(error) : "internal-error";
    const detail = ctx.redact(failureDetail(error)).split(route.apiKey || "\u0000").join("[redacted-key]");
    stats.lastError = `${reason}: ${detail}`;
    logger.warn?.("typeleast: polishing failed (%s: %s)", reason, detail);
    // The fallback is still cleaned deterministically: a model timeout is no
    // reason to insert "呃，嗯，那个" into the user's document.
    const tidyOnly = tidy(rawText);
    return await ctx.fail({
      ...base,
      text: tidyOnly.text,
      fallback: true,
      reason,
      detail,
      ms: timing(started, 0),
      attempts: error instanceof ModelCallError ? error.attempts : undefined,
      postprocess: tidyOnly.applied,
    });
  } finally { task.dispose(); }
}
