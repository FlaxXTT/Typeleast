/**
 * VoicePolishService — "transcribe, then make it sayable".
 *
 * Two entry points matter:
 *   polish()              text -> cleaned text (/polish)
 *   transcribeAndPolish() WAV  -> text (/dictate, used by both apps)
 *
 * Both share one rule: the raw transcript is never lost. Any failure, timeout,
 * rejection, missing key or missing model returns the raw text (deterministically
 * tidied) with a reason and a short detail, and the attempt is recorded in
 * history first.
 *
 * Recognition is local (asr.js). Cleanup uses the model and API key the app
 * sends with each request (openai-compat.js); the service stores no key.
 *
 * @module typeleast-service/service
 */
import { LANGUAGES } from "./config.js";
import { createHash, randomUUID } from "node:crypto";
import { mkdir, readFile, stat, writeFile } from "node:fs/promises";
import { dirname } from "node:path";
import { redactFieldContext, redactSecrets } from "./context.js";
import { buildUserMessage, harnessAddendum, promptVersionFor, systemPromptFor } from "./prompt.js";
import { completeOpenAI, normalizeRoute, routeLabel } from "./openai-compat.js";
import { parsePolishOutput } from "./parse-output.js";
import { failureDetail, failureReason, ModelCallError } from "./llm.js";
import { validateOutput } from "./validate.js";
import { tidy } from "./tidy.js";
import { validateWav } from "./wav.js";
import { PROMPTIFY_LIMITS, PROMPTIFY_PROMPT, promptifySystemPrompt } from "./prompts/promptify.js";
import {
  BETA_DRAFT_PROMPT, BETA_INTERVIEW_PROMPT, BETA_LIMITS, BETA_PATCH_PROMPT, BETA_REVIEW_PROMPT,
  cleanPromptReply, draftMessage, hasContent, normaliseQuestions, parseJsonReply, reviewMessage,
} from "./prompts/prompt-beta.js";
import { TRANSLATE_LANGUAGES, translatePrompt } from "./prompts/translate.js";
import { applyVariants, parseVariants, variantInstruction } from "./variants.js";

/** Hard ceiling on concurrent recognition+polish work. */
const MAX_PENDING = 2;
/** How many further requests may wait before the endpoint reports backpressure. */
const MAX_QUEUE = 4;
/** How many recent fallbacks /health reports. */
const MAX_RECENT_FAILURES = 5;

class BackpressureError extends Error {
  constructor() {
    super("too many dictations in flight");
    this.name = "BackpressureError";
    this.code = "busy";
  }
}

/** Recognition, cleanup, validation and history for one user. */
export class VoicePolishService {
  /**
   * @param {object} options - recognizer, history, configuration and logger.
   */
  constructor(options) {
    this.recognizer = options.recognizer;
    this.config = options.config;
    /** fetch for model calls; injected in tests. */
    this.fetchImpl = options.fetchImpl;
    this.history = options.history;
    this.logger = options.logger ?? { info: () => {}, warn: () => {}, debug: () => {} };
    this.pending = 0;
    this.queue = 0;
    this.version = options.version ?? "0.2.0";
    /** The route of the most recent cleanup, for /health: "custom:<host>" and model id. */
    this.lastRoute = { provider: null, model: null };
    this.startedAt = Date.now();
    this.dictionaryPath = options.dictionaryPath ?? null;
    /** Prompt mode (提示词模式): the user's additions and, if they replaced it, their default. */
    this.promptifyPath = options.promptifyPath ?? null;
    this.promptify = { appendix: "", override: null };
    this.promptifyMtime = null;
    this.dictionary = [...(this.config.dictionary ?? [])];
    // dictations/polished/fallback/lastMs count /dictate; modelCalls and
    // modelFallbacks count every polish() that reached the model, /polish included.
    this.stats = { dictations: 0, polished: 0, fallback: 0, lastError: null, lastMs: null, modelCalls: 0, modelFallbacks: 0, jsonFallback: 0, jsonRecovered: 0 };
    /** Newest first; only attempts that reached the model and fell back. */
    this.recentFailures = [];
    /** Prompt Beta question sessions: id -> { request, spec, questions, created }. */
    this.betaSessions = new Map();
  }

  get strength() {
    return this.config.strength ?? "prompt";
  }

  /**
   * Availability of the pieces this service needs, without doing any work.
   * @returns {object} a detached readiness report.
   */
  snapshot() {
    const speech = this.speechSnapshot();
    return {
      version: this.version,
      promptVersion: promptVersionFor(),
      startedAt: this.startedAt,
      provider: this.lastRoute.provider,
      model: this.lastRoute.model,
      promptSource: "article",
      temperature: this.config.temperature ?? 0.8,
      strength: this.strength,
      dictionarySize: this.dictionary.length,
      speech,
      stats: { ...this.stats },
      recentFailures: this.recentFailures.map((entry) => ({ ...entry })),
      pending: this.pending,
      queue: this.queue,
    };
  }

  /** The local recogniser's state. */
  speechSnapshot() {
    try {
      return this.recognizer.snapshot();
    } catch (error) {
      return { providerId: null, phase: "unavailable", ready: false, error: message(error) };
    }
  }

  /** Recent dictation history, newest first. */
  async readHistory({ limit = 20 } = {}) {
    return this.history.recent({ limit: Math.max(1, Math.min(200, limit)) });
  }

  /**
   * Add a spelling correction learned from a user edit.
   * @param {{from: string, to: string}} pair - the wrong and preferred spellings.
   * @returns {Promise<{ok: boolean, dictionary: string[]}>} the updated dictionary.
   */
  async learn(pair) {
    const from = String(pair.from ?? "").trim();
    const to = String(pair.to ?? "").trim();
    if (from.length === 0 || to.length === 0) throw new Error("learn requires non-empty from and to");
    const existing = this.dictionary.findIndex((item) => item.startsWith(`${from}=`));
    const entry = `${from}=${to}`;
    if (existing >= 0) this.dictionary[existing] = entry;
    else this.dictionary.push(entry);
    await this.persistDictionary();
    return { ok: true, dictionary: [...this.dictionary] };
  }

  /**
   * Replace the learned dictionary with the app's list (the native Dictionary page
   * owns it: add, edit, delete, CSV import, auto-added words). Entries are either a
   * plain word ("DeepSeek", a spelling to prefer) or "heard=word" (a hard rule).
   * Entries from config.json are always kept.
   * @param {unknown} entries - candidate list.
   * @returns {Promise<{ok: boolean, dictionary: string[]}>} the dictionary now in use.
   */
  async setDictionary(entries) {
    if (!Array.isArray(entries)) throw new Error("dictionary must be an array of strings");
    const cleaned = [];
    for (const entry of entries.slice(0, 2000)) {
      if (typeof entry !== "string") continue;
      const trimmed = entry.trim().slice(0, 120);
      if (trimmed.length > 0 && !cleaned.includes(trimmed)) cleaned.push(trimmed);
    }
    const configured = (this.config.dictionary ?? []).filter((entry) => typeof entry === "string");
    this.dictionary = [...configured, ...cleaned.filter((entry) => !configured.includes(entry))];
    await this.persistDictionary();
    return { ok: true, dictionary: [...this.dictionary] };
  }

  /**
   * Merge the user's learned dictionary into memory.
   *
   * Learned entries live in dictionary.json, apart from config.json, so the
   * service never rewrites a file the user edits by hand.
   */
  async loadDictionary() {
    if (this.dictionaryPath === null) return;
    try {
      const parsed = JSON.parse(await readFile(this.dictionaryPath, "utf8"));
      if (Array.isArray(parsed)) {
        for (const entry of parsed) {
          if (typeof entry === "string" && entry.trim().length > 0 && !this.dictionary.includes(entry)) {
            this.dictionary.push(entry);
          }
        }
      }
    } catch {
      // Absent or malformed: the configured dictionary is still valid.
    }
  }

  /** The prompt-mode prompt: the fixed default, the user's settings, and what is in effect. */
  promptifySettings() {
    return {
      default: PROMPTIFY_PROMPT,
      appendix: this.promptify.appendix,
      override: this.promptify.override,
      modified: this.promptify.override !== null,
      effective: promptifySystemPrompt(this.promptify),
    };
  }

  /**
   * Change the prompt-mode settings. `appendix` replaces the additions;
   * `override` replaces the default (a string) or restores it (null). Keys that
   * are absent are left as they are.
   * @param {{appendix?: string, override?: string|null}} input - the change.
   * @returns {Promise<object>} the settings now in effect.
   */
  async setPromptify(input) {
    const next = { ...this.promptify };
    if (input && Object.prototype.hasOwnProperty.call(input, "appendix")) {
      if (typeof input.appendix !== "string") throw Object.assign(new Error("appendix must be a string"), { code: "invalid-prompt" });
      next.appendix = input.appendix.trim().slice(0, PROMPTIFY_LIMITS.appendix);
    }
    if (input && Object.prototype.hasOwnProperty.call(input, "override")) {
      if (input.override === null) next.override = null;
      else if (typeof input.override === "string" && input.override.trim().length > 0) next.override = input.override.trim().slice(0, PROMPTIFY_LIMITS.override);
      else throw Object.assign(new Error("override must be a non-empty string, or null to restore the default"), { code: "invalid-prompt" });
      // Saving the default unchanged is not a modification.
      if (next.override === PROMPTIFY_PROMPT) next.override = null;
    }
    this.promptify = next;
    if (this.promptifyPath !== null) {
      await mkdir(dirname(this.promptifyPath), { recursive: true });
      await writeFile(this.promptifyPath, JSON.stringify(this.promptify, null, 2) + "\n", "utf8");
      this.promptifyMtime = await mtimeOf(this.promptifyPath);
    }
    return this.promptifySettings();
  }

  /** Load the prompt-mode settings; absent or malformed means the default. */
  async loadPromptify() {
    if (this.promptifyPath === null) return;
    this.promptifyMtime = await mtimeOf(this.promptifyPath);
    try {
      const parsed = JSON.parse(await readFile(this.promptifyPath, "utf8"));
      this.promptify = {
        appendix: typeof parsed?.appendix === "string" ? parsed.appendix.slice(0, PROMPTIFY_LIMITS.appendix) : "",
        override: typeof parsed?.override === "string" && parsed.override.trim().length > 0 ? parsed.override.slice(0, PROMPTIFY_LIMITS.override) : null,
      };
    } catch {
      this.promptify = { appendix: "", override: null };
    }
  }

  /**
   * Pick up edits made to promptify.json by hand (in a text editor) since it was
   * last read, so the next request sends what the file says without a restart.
   */
  async refreshPromptify() {
    if (this.promptifyPath === null) return;
    if ((await mtimeOf(this.promptifyPath)) !== this.promptifyMtime) await this.loadPromptify();
  }

  /** Persist learned entries. */
  async persistDictionary() {
    if (this.dictionaryPath === null) return;
    try {
      await mkdir(dirname(this.dictionaryPath), { recursive: true });
      await writeFile(this.dictionaryPath, JSON.stringify(this.dictionary, null, 2) + "\n", "utf8");
    } catch (error) {
      this.logger.warn?.("typeleast: could not persist the dictionary: %s", message(error));
    }
  }

  /**
   * Clean up one transcript.
   * @param {object} request - raw text, app hint, strength, session and signal.
   * @returns {Promise<object>} the polished (or raw) text plus telemetry.
   */
  async polish(request) {
    const started = Date.now();
    const rawText = String(request.rawText ?? "").trim();
    const strength = request.strength ?? this.strength;
    const base = {
      raw: rawText,
      text: rawText,
      fallback: false,
      reason: null,
      model: null,
      provider: null,
      ms: { transcribe: 0, polish: Date.now() - started, total: Date.now() - started },
    };
    // Skipping Prompt Beta's questions sends no answer at all, which is not an empty dictation.
    const betaSkip = strength === "promptbeta" && request.betaSkip === true && Boolean(request.betaSession);
    if (rawText.length === 0 && !betaSkip) return await this.recordAndReturn(request, { ...base, fallback: true, reason: "empty-transcript" });
    // 翻译模式 has its own hotkey and always needs the model, whatever the strength.
    const translateTo = Object.hasOwn(TRANSLATE_LANGUAGES, request.translateTo ?? "") ? request.translateTo : null;
    if (translateTo) {
      const route = request.llm ? normalizeRoute(request.llm) : null;
      if (!route) {
        const tidyOnly = tidy(rawText);
        return await this.recordAndReturn(request, { ...base, text: tidyOnly.text, fallback: true, reason: "no-api-key", postprocess: tidyOnly.applied });
      }
      base.provider = routeLabel(route);
      base.model = route.model;
      this.lastRoute = { provider: base.provider, model: base.model };
      return await this.polishTranslate({ request, base, route, started, rawText, target: translateTo });
    }
    if (strength === "off") {
      // "off" means no model, not "leave the disfluency in". The deterministic
      // pass is free, so an unpolished dictation is still a tidy one.
      const tidyOnly = tidy(rawText);
      return await this.recordAndReturn(request, { ...base, text: tidyOnly.text, reason: "strength-off", postprocess: tidyOnly.applied });
    }

    // The model and the user's own API key come with the request. Without a
    // usable route there is nothing to call: the tidied transcript is inserted
    // and the app tells the user to add a key.
    const custom = request.llm ? normalizeRoute(request.llm) : null;
    if (!custom) {
      const tidyOnly = tidy(rawText);
      return await this.recordAndReturn(request, { ...base, text: tidyOnly.text, fallback: true, reason: "no-api-key", postprocess: tidyOnly.applied });
    }
    base.provider = routeLabel(custom);
    base.model = custom.model;
    this.lastRoute = { provider: base.provider, model: base.model };

    if (strength === "promptbeta") return await this.polishBeta({ request, base, route: custom, started, rawText, skip: betaSkip });

    const context = await this.buildContext(request);
    if (strength === "promptify") await this.refreshPromptify();
    // Article's prompt and demonstrations, plus an addendum with only the dictionary
    // and the text around the cursor (already redacted by buildContext).
    const system = systemPromptFor({
      dictionary: context.dictionary,
      fieldContext: context.fieldContext ?? null,
      strength,
      promptify: this.promptify,
    }) + variantInstruction(parseVariants(request.variants));
    // The transcript is redacted on the way OUT to the provider, not on the way
    // in: a dictated key or password must not reach the model, and context is
    // already redacted by buildContext. The text the user finally gets is what
    // the model returns (or the unredacted original when it falls back).
    const outboundText = this.config.redactSecrets === false ? rawText : redactSecrets(rawText);
    // The user message is the recognised text alone, as the Article article intends.
    const user = buildUserMessage({ rawText: outboundText });

    this.stats.modelCalls += 1;
    try {
      const result = await completeOpenAI({
        route: custom,
        system,
        user,
        // Prompt mode writes a whole structured prompt: more room and more time.
        maxTokens: strength === "promptify" ? Math.max(this.config.maxOutputTokens, 1600) : this.config.maxOutputTokens,
        temperature: this.config.temperature ?? 0.8,
        timeoutMs: strength === "promptify" ? Math.max(this.config.timeoutMs, 25000) : this.config.timeoutMs,
        signal: request.signal,
        ...(this.fetchImpl ? { fetchImpl: this.fetchImpl } : {}),
      });
      // The vendored prompt asks for {status,text,reason}; a model may answer
      // with plain prose or malformed JSON instead, and none of that may reach
      // the document. Parse first, then clean, then validate.
      const parsed = parsePolishOutput(result.text);
      if (!parsed.ok) {
        this.stats.jsonFallback += 1;
        this.stats.modelFallbacks += 1;
        const tidyOnly = tidy(rawText);
        const detail = `output-format:${parsed.failure ?? "unknown"}`;
        this.stats.lastError = detail;
        this.logger.warn?.("typeleast: unusable model reply (%s); using the raw transcript", detail);
        return await this.recordFallback(request, {
          ...base,
          text: tidyOnly.text,
          fallback: true,
          reason: "output-format",
          detail,
          ms: timing(started, 0),
          attempts: result.attempts,
          postprocess: tidyOnly.applied,
        });
      }
      if (parsed.mode !== "json") this.stats.jsonRecovered += 1;
      // Deterministic cleanup runs BEFORE validation so the safety checks judge
      // exactly the text that would be inserted.
      const tidied = tidy(parsed.text);
      const verdict = validateOutput({ rawText, output: tidied.text, strength });
      if (!verdict.ok) {
        // Same fallback text as the exception path below: the rejected rewrite
        // is discarded, but the filler in the raw transcript still is not wanted.
        const tidyOnly = tidy(rawText);
        return await this.recordFallback(request, {
          ...base,
          text: tidyOnly.text,
          fallback: true,
          reason: verdict.reason,
          detail: describeVerdict(verdict.metrics),
          ms: timing(started, 0),
          metrics: verdict.metrics,
          attempts: result.attempts,
          postprocess: tidyOnly.applied,
        });
      }
      return await this.recordAndReturn(request, {
        ...base,
        text: verdict.text,
        ms: timing(started, 0),
        metrics: verdict.metrics,
        usage: result.usage,
        attempts: result.attempts,
        postprocess: tidied.applied,
        modelNote: parsed.reason ?? undefined,
        outputMode: parsed.mode,
      });
    } catch (error) {
      // completeOpenAI() only throws ModelCallError; anything else came from the
      // deterministic steps after it and must not be blamed on the model.
      const reason = request.signal?.aborted
        ? "cancelled"
        : error instanceof ModelCallError ? failureReason(error) : "internal-error";
      const detail = this.redactDetail(failureDetail(error)).split(custom.apiKey || "\u0000").join("[redacted-key]");
      this.stats.lastError = `${reason}: ${detail}`;
      this.logger.warn?.("typeleast: polishing failed (%s: %s); using the raw transcript", reason, detail);
      // The fallback is still cleaned deterministically: a model timeout is no
      // reason to insert "呃，嗯，那个" into the user's document.
      const tidyOnly = tidy(rawText);
      return await this.recordFallback(request, {
        ...base,
        text: tidyOnly.text,
        fallback: true,
        reason,
        detail,
        ms: timing(started, 0),
        attempts: error instanceof ModelCallError ? error.attempts : undefined,
        postprocess: tidyOnly.applied,
      });
    }
  }

  /**
   * 翻译模式: clean up the spoken transcript and write it in the target language, in
   * one call. Only the decisive fact check applies; a failure inserts the tidied
   * original rather than nothing.
   */
  async polishTranslate({ request, base, route, started, rawText, target }) {
    const context = await this.buildContext(request);
    const system = translatePrompt(target)
      + harnessAddendum({ dictionary: context.dictionary, fieldContext: context.fieldContext ?? null })
      + (target === "en" ? variantInstruction(parseVariants(request.variants)) : "");
    const outboundText = this.config.redactSecrets === false ? rawText : redactSecrets(rawText);
    this.stats.modelCalls += 1;
    try {
      const result = await completeOpenAI({
        route, system, user: outboundText,
        maxTokens: Math.max(this.config.maxOutputTokens, 1200),
        temperature: 0.3,
        timeoutMs: Math.max(this.config.timeoutMs, 20000),
        signal: request.signal,
        ...(this.fetchImpl ? { fetchImpl: this.fetchImpl } : {}),
      });
      const verdict = validateOutput({ rawText, output: String(result.text ?? "").trim(), strength: "translate" });
      if (!verdict.ok) {
        const tidyOnly = tidy(rawText);
        return await this.recordFallback(request, {
          ...base, text: tidyOnly.text, fallback: true, reason: verdict.reason,
          detail: describeVerdict(verdict.metrics), ms: timing(started, 0), metrics: verdict.metrics,
          attempts: result.attempts, postprocess: tidyOnly.applied, translated: target,
        });
      }
      return await this.recordAndReturn(request, {
        ...base, text: verdict.text, ms: timing(started, 0), metrics: verdict.metrics,
        usage: result.usage, attempts: result.attempts, translated: target,
      });
    } catch (error) {
      const reason = request.signal?.aborted
        ? "cancelled"
        : error instanceof ModelCallError ? failureReason(error) : "internal-error";
      const detail = this.redactDetail(failureDetail(error)).split(route.apiKey || "\u0000").join("[redacted-key]");
      this.stats.lastError = `${reason}: ${detail}`;
      this.logger.warn?.("typeleast: translation failed (%s: %s); using the raw transcript", reason, detail);
      const tidyOnly = tidy(rawText);
      return await this.recordFallback(request, {
        ...base, text: tidyOnly.text, fallback: true, reason, detail, ms: timing(started, 0),
        attempts: error instanceof ModelCallError ? error.attempts : undefined,
        postprocess: tidyOnly.applied, translated: target,
      });
    }
  }

  /**
   * Prompt Beta (提示词 Beta): interview -> (questions) -> draft -> fresh review -> minimal patch.
   *
   * A new request runs the interview only. When it has questions they are returned with a
   * session id and nothing is inserted; the next dictation carries that id and is taken as
   * the spoken answers. A request that needs no questions goes straight to the draft.
   * @returns {Promise<object>} a result whose `beta.questions` is set when answers are needed.
   */
  async polishBeta({ request, base, route, started, rawText, skip }) {
    const redact = (text) => (this.config.redactSecrets === false ? text : redactSecrets(text));
    const call = async (system, user, { maxTokens, temperature }) => {
      this.stats.modelCalls += 1;
      const result = await completeOpenAI({
        route, system, user, maxTokens, temperature,
        // Three calls of a whole prompt each: generous room and time, quality over speed.
        timeoutMs: Math.max(this.config.timeoutMs, 60000),
        signal: request.signal,
        ...(this.fetchImpl ? { fetchImpl: this.fetchImpl } : {}),
      });
      return result.text;
    };
    this.pruneBetaSessions();
    let session = null;
    if (request.betaSession) {
      session = this.betaSessions.get(request.betaSession) ?? null;
      if (!session) throw Object.assign(new Error("the questions have expired; dictate the request again"), { code: "beta-expired" });
      this.betaSessions.delete(request.betaSession);
    }
    // A silent or filler-only request has nothing to write a prompt about.
    if (!session && !hasContent(rawText)) {
      return await this.recordAndReturn(request, { ...base, text: "", fallback: true, reason: "empty-transcript" });
    }
    const original = session ? session.request : rawText;
    // An answer that says nothing counts as skipping the questions.
    const skipped = Boolean(session) && (skip || !hasContent(rawText));
    const answers = session && !skipped ? rawText : "";
    const source = answers ? `${original}\n${answers}` : original;
    try {
      let spec = session?.spec ?? null;
      let questions = session?.questions ?? [];
      if (!session) {
        const reply = parseJsonReply(await call(BETA_INTERVIEW_PROMPT, redact(rawText), { maxTokens: 1600, temperature: 0.3 }));
        if (reply) {
          spec = {
            goal: reply.goal ?? "", audience: reply.audience ?? "", success: reply.success ?? [],
            constraints: reply.constraints ?? [], output: reply.output ?? "", assumptions: reply.assumptions ?? [],
          };
        }
        questions = normaliseQuestions(reply?.questions);
        if (questions.length > 0) {
          const sessionId = randomUUID();
          this.betaSessions.set(sessionId, { request: rawText, spec, questions, created: Date.now() });
          // Not recorded: nothing was written for the user yet.
          return { ...base, text: "", beta: { sessionId, questions }, ms: timing(started, 0) };
        }
      }
      const draft = cleanPromptReply(await call(BETA_DRAFT_PROMPT,
        draftMessage({ request: redact(original), spec, questions, answers: redact(answers), skipped }),
        { maxTokens: 3200, temperature: 0.5 }));
      if (!draft) throw Object.assign(new Error("empty draft"), { code: "output-format" });
      // Review in a fresh call that only diagnoses, then a separate minimal patch.
      const review = parseJsonReply(await call(BETA_REVIEW_PROMPT,
        reviewMessage({ request: redact(original), answers: redact(answers), draft }),
        { maxTokens: 1600, temperature: 0.2 }));
      const issues = (Array.isArray(review?.issues) ? review.issues : [])
        .filter((issue) => issue && typeof issue === "object" && issue.type).slice(0, 8);
      let final = draft;
      if (issues.length > 0) {
        const patched = cleanPromptReply(await call(BETA_PATCH_PROMPT,
          reviewMessage({ request: redact(original), answers: redact(answers), draft, issues }),
          { maxTokens: 3200, temperature: 0.2 }));
        if (patched) final = patched;
      }
      let verdict = validateOutput({ rawText: source, output: final, strength: "promptify" });
      if (!verdict.ok && final !== draft) {
        // The patch may have introduced the problem; the reviewed draft is still usable.
        const before = validateOutput({ rawText: source, output: draft, strength: "promptify" });
        if (before.ok) { final = draft; verdict = before; }
      }
      if (!verdict.ok) {
        const tidyOnly = tidy(source);
        return await this.recordFallback(request, {
          ...base, raw: source, text: tidyOnly.text, fallback: true, reason: verdict.reason,
          detail: describeVerdict(verdict.metrics), ms: timing(started, 0), metrics: verdict.metrics,
        });
      }
      return await this.recordAndReturn(request, {
        ...base, raw: source, text: verdict.text, ms: timing(started, 0), metrics: verdict.metrics,
        beta: { reviewed: true, issues: issues.length, patched: final !== draft },
      });
    } catch (error) {
      const reason = request.signal?.aborted
        ? "cancelled"
        : error instanceof ModelCallError ? failureReason(error) : (error.code === "output-format" ? "output-format" : "internal-error");
      const detail = this.redactDetail(failureDetail(error)).split(route.apiKey || "\u0000").join("[redacted-key]");
      this.stats.lastError = `${reason}: ${detail}`;
      this.logger.warn?.("typeleast: prompt beta failed (%s: %s); using the raw transcript", reason, detail);
      const tidyOnly = tidy(source);
      return await this.recordFallback(request, {
        ...base, raw: source, text: tidyOnly.text, fallback: true, reason, detail, ms: timing(started, 0),
      });
    }
  }

  /** Drop expired Prompt Beta sessions and keep the map bounded. */
  pruneBetaSessions(now = Date.now()) {
    for (const [id, session] of this.betaSessions) {
      if (now - session.created > BETA_LIMITS.sessionMs) this.betaSessions.delete(id);
    }
    while (this.betaSessions.size > BETA_LIMITS.sessions) {
      this.betaSessions.delete(this.betaSessions.keys().next().value);
    }
  }

  /** Forget a Prompt Beta session the user cancelled. */
  cancelBeta(sessionId) {
    return this.betaSessions.delete(String(sessionId ?? ""));
  }

  /**
   * Remember a fallback from an attempt that reached the model, then record and
   * return it like any other result.
   * @param {object} request - the original request.
   * @param {object} result - the fallback result about to be returned.
   * @returns {Promise<object>} the same result.
   */
  async recordFallback(request, result) {
    this.stats.modelFallbacks += 1;
    this.recentFailures.unshift({
      ts: Date.now(),
      reason: result.reason,
      detail: result.detail ?? null,
      app: request.appHint ?? null,
      strength: request.strength ?? this.strength,
      ms: result.ms.polish,
    });
    this.recentFailures.length = Math.min(this.recentFailures.length, MAX_RECENT_FAILURES);
    return await this.recordAndReturn(request, result);
  }

  /** Failure text can quote provider responses; keep it to the history's privacy rules. */
  redactDetail(detail) {
    return this.config.redactSecrets === false ? detail : redactSecrets(detail);
  }

  /**
   * Record one polish attempt, then return it.
   *
   * Every exit path of polish() goes through here, so history never misses an
   * attempt — including the short-circuits that never reach the model. Callers
   * therefore must NOT record a polish result a second time.
   *
   * @param {object} request - the original request (for app, language, strength).
   * @param {object} result - the result about to be returned.
   * @returns {Promise<object>} the same result.
   */
  async recordAndReturn(request, result) {
    // The written variant (繁體) is the last step, so history and the inserted text agree.
    if (request.variants) result.text = await applyVariants(result.text, parseVariants(request.variants));
    await this.record(request, {
      raw: result.raw,
      text: result.text,
      fallback: result.fallback,
      fallbackReason: result.reason,
      detail: result.detail,
      model: result.model,
      provider: result.provider,
      ms: result.ms,
    });
    return result;
  }

  /**
   * Transcribe recorded audio and clean up the transcript.
   * @param {object} request - WAV bytes plus per-request options.
   * @returns {Promise<object>} the result, including the raw transcript.
   */
  async transcribeAndPolish(request) {
    if (this.pending >= MAX_PENDING) {
      if (this.queue >= MAX_QUEUE) throw new BackpressureError();
      this.queue += 1;
      try {
        await this.waitForSlot(request.signal);
      } finally {
        this.queue -= 1;
      }
    }
    this.pending += 1;
    const started = Date.now();
    try {
      const audio = request.audio;
      if (Buffer.isBuffer(audio) && audio.length > this.config.maxAudioBytes) {
        const error = new Error(`audio is ${audio.length} bytes, over the ${this.config.maxAudioBytes} limit`);
        error.code = "audio-too-large";
        throw error;
      }
      validateWav(audio, this.config.maxDurationSeconds);
      const language = request.language ?? this.config.language ?? "auto";
      if (!LANGUAGES.includes(language)) {
        const error = new Error("unsupported recognition language");
        error.code = "invalid-language";
        throw error;
      }
      const spoken = await this.transcribe(audio, language);
      const polished = await this.polish({
        rawText: spoken.text,
        language: spoken.language ?? language,
        appHint: request.appHint,
        strength: request.strength,
        fieldContext: request.fieldContext ?? null,
        llm: request.llm ?? null,
        signal: request.signal,
        betaSession: request.betaSession ?? null,
        translateTo: request.translateTo ?? null,
        variants: request.variants ?? null,
      });
      const result = {
        requestId: request.requestId,
        text: polished.text,
        raw: spoken.text,
        fallback: polished.fallback,
        fallbackReason: polished.reason ?? undefined,
        model: polished.model,
        provider: polished.provider,
        strength: request.strength ?? this.strength,
        ms: {
          transcribe: Math.round(spoken.ms),
          polish: polished.ms.polish,
          total: Date.now() - started,
        },
        metrics: polished.metrics,
        ...(polished.beta ? { beta: polished.beta } : {}),
        ...(polished.translated ? { translated: polished.translated } : {}),
      };
      this.stats.dictations += 1;
      if (result.fallback) this.stats.fallback += 1;
      else this.stats.polished += 1;
      this.stats.lastMs = result.ms.total;
      return result;
    } finally {
      this.pending -= 1;
    }
  }

  /**
   * Recognise the audio locally. When the model is not loaded yet this throws
   * speech-not-ready (and loading starts), so the app can say so honestly.
   */
  async transcribe(audio, language) {
    const started = Date.now();
    const spoken = await this.recognizer.transcribe(audio, language);
    return { text: String(spoken.text ?? "").trim(), language: spoken.language ?? language, ms: Date.now() - started };
  }

  /** Assemble bounded, redacted context for one call. */
  async buildContext(request) {
    const redact = this.config.redactSecrets !== false;
    return {
      dictionary: this.dictionary.map(entry => redact ? redactSecrets(entry) : entry),
      // The text box being dictated into is the most relevant context there is.
      fieldContext: redactFieldContext(request.fieldContext ?? null, redact),
    };
  }

  /** Wait for a free slot without polling. */
  async waitForSlot(signal) {
    const deadlineAt = Date.now() + 15000;
    while (this.pending >= MAX_PENDING) {
      if (signal?.aborted) throw signal.reason ?? new Error("aborted");
      if (Date.now() > deadlineAt) throw new BackpressureError();
      await new Promise((resolve) => setTimeout(resolve, 50));
    }
  }

  /** Store one attempt, before the caller ever sees the result. */
  async record(request, result) {
    try {
      const redact = this.config.redactSecrets !== false;
      const logRaw = this.config.logRaw !== false;
      // Redaction happens before hashing: a digest of an unredacted secret is
      // still derived from the secret, and this file is meant to be safe to read.
      const rawText = redact ? redactSecrets(result.raw ?? "") : (result.raw ?? "");
      const cleanText = redact ? redactSecrets(result.text ?? "") : (result.text ?? "");
      await this.history.append({
        app: request.appHint ?? null,
        language: request.language ?? this.config.language ?? "auto",
        strength: request.strength ?? this.strength,
        raw: logRaw ? rawText : hash(rawText),
        text: logRaw ? cleanText : hash(cleanText),
        fallback: result.fallback,
        reason: result.fallbackReason ?? null,
        detail: result.detail ?? null,
        model: result.model ?? null,
        provider: result.provider ?? null,
        ms: result.ms ?? null,
      });
    } catch (error) {
      this.logger.warn?.("typeleast: could not record history: %s", message(error));
    }
  }
}

/** Milliseconds shape shared by every result. */
function timing(started, transcribeMs) {
  const polish = Date.now() - started;
  return { transcribe: Math.round(transcribeMs), polish, total: Math.round(transcribeMs) + polish };
}

/**
 * Summarise why the validator rejected an answer, using only measurements:
 * the invented tokens themselves are dictated content and stay out of it.
 * @param {object} metrics - validateOutput() metrics.
 * @returns {string|null} e.g. "ratio=1.42 coverage=0.61 novelty=0.52 inventedFacts=2".
 */
function describeVerdict(metrics) {
  const parts = [];
  for (const [label, value] of [["ratio", metrics?.ratio], ["coverage", metrics?.coverage], ["novelty", metrics?.preciseNovelty]]) {
    if (typeof value === "number" && Number.isFinite(value)) parts.push(`${label}=${value.toFixed(2)}`);
  }
  if (Array.isArray(metrics?.inventedFacts) && metrics.inventedFacts.length > 0) parts.push(`inventedFacts=${metrics.inventedFacts.length}`);
  return parts.length > 0 ? parts.join(" ") : null;
}

/** Short stable digest for privacy-preserving history. */
function hash(text) {
  return `sha256:${createHash("sha256").update(String(text)).digest("hex").slice(0, 16)}`;
}

/** Narrow an unknown throwable to a printable message. */
function message(error) {
  return error instanceof Error ? error.message : String(error);
}

/** Modification time of a file in ms, or null when it does not exist. */
async function mtimeOf(path) {
  try {
    return (await stat(path)).mtimeMs;
  } catch {
    return null;
  }
}
