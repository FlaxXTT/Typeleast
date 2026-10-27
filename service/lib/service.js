import {betaSetupQuestions} from './prompts/prompt-beta.js';
import {CleanupTask, cleanupParameters, needsCleanupReview} from './cleanup-task.js';
import {CLEANUP_REVIEW_PROMPT, parseCleanupReview} from './prompts/cleanup-review.js';
import { personalizationContext, applyExplicitRules, requestPolicy, readPolicy } from "./personalization-policy.js";
import { splitExplanation, explanationNameRule, explanationInstruction } from "./explanation-context.js";
import { requestPreferences, preferenceHints, preferenceInstruction } from "./preference-hints.js";
import { nameClarification, clarificationSource, clarificationRule } from "./name-clarification.js";
/**
 * VoicePolishService — "transcribe, then make it sayable".
 *
 * Two entry points matter:
 *   polish()              text -> cleaned text (/polish)
 *   transcribeAndPolish() WAV  -> text (/dictate, used by both apps)
 *
 * Both share one rule: the raw transcript is never lost. Any failure, timeout,
 * rejection, missing key or missing model returns the raw text (deterministically
 * tidied) with a reason and a short detail.
 *
 * The service keeps no dictation history and no dictionary of its own: each app
 * keeps both (encrypted history, its Dictionary page) and sends the dictionary
 * with every request, so there is nothing to keep in sync.
 *
 * Recognition is local (asr.js). Cleanup uses the model and API key the app
 * sends with each request (openai-compat.js); the service stores no key.
 *
 * @module typeleast-service/service
 */
import { spelledWords } from "./spelling.js";
import { canonicalStrength, LANGUAGES } from "./config.js";
import { createHash, randomUUID } from "node:crypto";
import { redactFieldContext, redactSecrets } from "./context.js";
import { buildUserMessage, harnessAddendum, promptVersionFor, systemPromptFor } from "./prompt.js";
import { completeOpenAI, normalizeRoute, routeLabel } from "./openai-compat.js";
import { parsePolishOutput } from "./parse-output.js";
import { failureDetail, failureReason, ModelCallError } from "./llm.js";
import { restoreApproximateNumbers, validateOutput } from "./validate.js";
import { normalizeNumbers } from './number-format.js';
import { tidy } from "./tidy.js";
import { validateWav } from "./wav.js";
import {
  BETA_DRAFT_PROMPT, BETA_INTERVIEW_PROMPT, BETA_LIMITS, BETA_PATCH_PROMPT, BETA_REVIEW_PROMPT,
  cleanPromptReply, draftMessage, hasContent, interviewMessage, normaliseQuestions, parseJsonReply, reviewMessage,
} from "./prompts/prompt-beta.js";
import { directTranslatePrompt, TRANSLATE_LANGUAGES, translatePrompt } from "./prompts/translate.js";
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

/** Recognition, cleanup and validation for one user. */
export class VoicePolishService {
  /**
   * @param {object} options - recognizer, configuration and logger.
   */
  constructor(options) {
    this.recognizer = options.recognizer;
    this.config = options.config;
    /** fetch for model calls; injected in tests. */
    this.fetchImpl = options.fetchImpl;
    /** Optional extension port. Core dictation works when it is absent. */
    this.extension = options.extension ?? null;
    this.logger = options.logger ?? { info: () => {}, warn: () => {}, debug: () => {} };
    this.pending = 0;
    this.queue = 0;
    this.version = options.version ?? "0.2.0";
    /** The route of the most recent cleanup, for /health: "custom:<host>" and model id. */
    this.lastRoute = { provider: null, model: null };
    this.startedAt = Date.now();
    /** Legacy wire field remains empty; persistent vocabulary is retired. */
    this.dictionary = [];
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
      promptSource: "typeleast",
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

  /**
   * Clean up one transcript.
   * @param {object} request - raw text, app hint, strength, session and signal.
   * @returns {Promise<object>} the polished (or raw) text plus telemetry.
   */
  async polish(request) {
    request = { ...request };
    const started = Date.now();
    const originalText = String(request.rawText ?? "").trim();
    // The retired prompt-mode tiers (promptbrief, promptify) are read as 精简整理.
    const strength = canonicalStrength(request.strength ?? this.strength);
    const explanation = strength === "concise" && !request.translateTo
      ? splitExplanation(originalText, request.explanationMarkers) : { text: originalText, notes: [], used: false };
    const rawText = explanation.text;
    const base = {
      raw: originalText,
      text: rawText,
      fallback: false,
      reason: null,
      model: null,
      provider: null,
      ms: { transcribe: 0, polish: Date.now() - started, total: Date.now() - started },
    };
    if (explanation.issue) return this.nameQuestion(request, base,
      { question: "请检查补充信息的开始词和结束词。", evidence: explanation.evidence, kind: "explanation" }, started);
    if (explanation.used) base.explanation = { used: true, segments: explanation.notes.length, markerId: request.explanationMarkers };
    if (explanation.used && !/[\p{L}\p{N}]/u.test(rawText)) return { ...base, text: "", contextOnly: true, suggestions: [], reason: "explanation-only" };
    // Skipping Prompt Beta's questions sends no answer at all, which is not an empty dictation.
    const betaSkip = strength === "promptbeta" && request.betaSkip === true && Boolean(request.betaSession);
    if (rawText.length === 0 && !betaSkip && !(strength === "promptbeta" && request.betaSession)) {
      if (strength === "promptbeta") return { ...base, text: "", fallback: true, reason: "empty-transcript" };
      return await this.recordAndReturn(request, { ...base, fallback: true, reason: "empty-transcript" });
    }
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
    // The model and the user's own API key come with the request. Without a
    // usable route there is nothing to call: hold the transcript for explicit user review.
    const custom = request.llm ? normalizeRoute(request.llm) : null;
    if (!custom) {
      const tidyOnly = tidy(rawText);
      return await this.recordAndReturn(request, { ...base, text: tidyOnly.text, fallback: true, reason: "no-api-key", postprocess: tidyOnly.applied });
    }
    base.provider = routeLabel(custom);
    base.model = custom.model;
    this.lastRoute = { provider: base.provider, model: base.model };

    if (strength === "promptbeta") return await this.polishBeta({ request, base, route: custom, started, rawText, skip: betaSkip });

    const task = new CleanupTask(request.signal);
    let candidate = null;
    try {
    const context = await this.buildContext(request, rawText);
    const safeNotes = explanation.notes.map(s => redactSecrets(s));
    const nameRules = explanationNameRule(rawText, safeNotes);
    context.dictionary.push(...nameRules);
    const rawExamples = request.preferenceExamples ?? requestPreferences(request.dictionary);
    const filteredExamples = (Array.isArray(rawExamples) ? rawExamples : []).filter(x => x && ![x.raw,x.aiText,x.correctedText].some(v => typeof v === "string" && request._personalization.excludedText?.(v)));
    const examples = request._personalization.policy.disabled ? [] : preferenceHints(filteredExamples, rawText);
    request._personalization.trace.references.push(...examples.map(x=>({kind:"example",source:"personal",sourceId:filteredExamples.find(y=>y.raw===x.raw&&y.correctedText===x.correctedText)?.id??"example"})));
    const style = context.style?.instructions ?? null;
    if(style) request._personalization.trace.references.push({kind:'style',source:'extension',sourceId:context.style.sourceId,label:context.style.label});
    // Generic cleanup rules with the current utterance, optional style and cursor context.
    const system = systemPromptFor({
      dictionary: context.dictionary,
      aliases: context.aliases,
      fieldContext: context.fieldContext ?? null,
      spellings: context.spellings,
      strength,
      style,
    }) + explanationInstruction(safeNotes) + preferenceInstruction(examples)
      + variantInstruction(parseVariants(request.variants));
    // The transcript is redacted on the way OUT to the provider, not on the way
    // in: a dictated key or password must not reach the model, and context is
    // already redacted by buildContext. The text the user finally gets is what
    // the model returns (or the unredacted original when it falls back).
    const outboundText = this.config.redactSecrets === false ? rawText : redactSecrets(rawText);
    // The user message is the recognised text alone; the prompt says everything in it is content.
    const user = buildUserMessage({ rawText: outboundText });

    this.stats.modelCalls += 1;
      const result = await completeOpenAI({
        route: custom,
        system,
        user,
        // 精简整理 may restructure a long dictation: more room and more time.
        ...cleanupParameters(rawText,strength,this.config),
        signal: task.signal,
        retryBudget: task,
        ...(this.fetchImpl ? { fetchImpl: this.fetchImpl } : {}),
      });
      // The prompt asks for {status,text,reason}; a model may answer
      // with plain prose or malformed JSON instead, and none of that may reach
      // the document. Parse first, then clean, then validate.
      const parsed = parsePolishOutput(result.text);
      if (!parsed.ok) {
        this.stats.jsonFallback += 1;
        this.stats.modelFallbacks += 1;
        const tidyOnly = tidy(rawText);
        const detail = `output-format:${parsed.failure ?? "unknown"}`;
        this.stats.lastError = detail;
        this.logger.warn?.("typeleast: unusable model reply (%s); holding delivery", detail);
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
      // Explanatory material is not insertable text, even if a provider ignores the boundary.
      if (explanation.used) {
        const outputNotes = splitExplanation(parsed.text, request.explanationMarkers);
        const copiedNote = explanation.notes.some(note => note.length >= 8 && !rawText.includes(note) && parsed.text.includes(note));
        if (outputNotes.used || outputNotes.issue || copiedNote) return this.recordFallback(request, {
          ...base, text: tidy(rawText).text, fallback: true, reason: "explanation-leaked", ms: timing(started, 0),
        });
      }
      const clarification = nameClarification(parsed.clarification, rawText);
      if (clarification) return this.nameQuestion(request, base, clarification, started);
      if (parsed.clarification) return this.recordFallback(request, { ...base, fallback: true, reason: "output-format", ms: timing(started, 0) });
      if (parsed.mode !== "json") this.stats.jsonRecovered += 1;
      // Deterministic cleanup runs BEFORE validation so the safety checks judge
      // exactly the text that would be inserted.
      const tidied = tidy(normalizeNumbers(restoreApproximateNumbers(rawText, parsed.text)));
      candidate = tidied.text;
      const verdict = validateOutput({ rawText, output: candidate, strength, termEvidence: context.dictionary });
      if (!verdict.ok && verdict.reason === "entity-changed") {
        const evidence = verdict.metrics.missingNames?.[0];
        if (evidence) return this.nameQuestion(request, base, { question: "请确认这次口述中的名称。", evidence }, started);
      }
      if (!verdict.ok) {
        // Keep the candidate for editing, but never expose it as insertable text.
        const tidyOnly = tidy(rawText);
        return await this.recordFallback(request, {
          ...base,
          text: candidate,
          fallback: true,
          reason: verdict.reason,
          detail: describeVerdict(verdict.metrics),
          ms: timing(started, 0),
          metrics: verdict.metrics,
          attempts: result.attempts,
          postprocess: tidyOnly.applied,
        });
      }
      candidate = verdict.text;
      if (needsCleanupReview(rawText, candidate, verdict.metrics)) {
        this.stats.modelCalls += 1;
        const source = redactSecrets(rawText);
        const review = await completeOpenAI({route:custom,system:CLEANUP_REVIEW_PROMPT,
          user:JSON.stringify({source,candidate:redactSecrets(candidate),explanation:safeNotes,fieldContext:context.fieldContext}),
          maxTokens:800,temperature:0,timeoutMs:10000,signal:task.signal,retryBudget:task,
          ...(this.fetchImpl?{fetchImpl:this.fetchImpl}:{})});
        const issues=parseCleanupReview(review.text,source,redactSecrets(candidate));
        if(issues===null||issues.length) return this.recordFallback(request,{...base,text:candidate,fallback:true,reason:issues===null?'review-invalid':'incomplete-output',ms:timing(started,0)});
      }
      task.assertTime();
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
        : task.deadline.timedOut() ? "model-timeout" : error instanceof ModelCallError ? failureReason(error) : "internal-error";
      const detail = this.redactDetail(failureDetail(error)).split(custom.apiKey || "\u0000").join("[redacted-key]");
      this.stats.lastError = `${reason}: ${detail}`;
      this.logger.warn?.("typeleast: polishing failed (%s: %s); holding delivery", reason, detail);
      // The fallback is still cleaned deterministically: a model timeout is no
      // reason to insert "呃，嗯，那个" into the user's document.
      const tidyOnly = tidy(rawText);
      return await this.recordFallback(request, {
        ...base,
        text: candidate ?? tidyOnly.text,
        fallback: true,
        reason,
        detail,
        ms: timing(started, 0),
        attempts: error instanceof ModelCallError ? error.attempts : undefined,
        postprocess: tidyOnly.applied,
      });
    } finally { task.dispose(); }
  }

  /**
   * Clean and validate the source, then translate it in a second call. A source
   * that fails cleanup is translated directly in one call instead, so the user
   * still gets the target language; only when that fails too is the tidied
   * original inserted.
   */
  async polishTranslate({ request, base, route, started, rawText, target }) {
    const context = await this.buildContext(request, rawText);
    const cleanupSystem = systemPromptFor({
      dictionary: context.dictionary, aliases: context.aliases, spellings: context.spellings,
      fieldContext: context.fieldContext ?? null, strength: "prompt", style: null,
    });
    const variants = target === "en" ? variantInstruction(parseVariants(request.variants)) : "";
    const redact = text => this.config.redactSecrets === false ? text : redactSecrets(text);
    const outboundText = redact(rawText);
    const call = (system, user, temperature) => {
      this.stats.modelCalls += 1;
      return completeOpenAI({
        route, system, user,
        maxTokens: Math.max(this.config.maxOutputTokens, 1200),
        temperature,
        timeoutMs: Math.max(this.config.timeoutMs, 20000),
        signal: request.signal,
        ...(this.fetchImpl ? { fetchImpl: this.fetchImpl } : {}),
      });
    };
    let cleanedSource = null;
    try {
      const cleanup = await call(cleanupSystem, buildUserMessage({ rawText: outboundText }), 0.2);
      const parsed = parsePolishOutput(cleanup.text);
      if (!parsed.ok) this.stats.jsonFallback += 1;
      else if (parsed.mode !== "json") this.stats.jsonRecovered += 1;
      const clarification = nameClarification(parsed.clarification, rawText);
      if (clarification) return this.nameQuestion(request, base, clarification, started);
      if (parsed.clarification) return this.recordFallback(request, { ...base, fallback: true, reason: "output-format", ms: timing(started, 0) });
      const tidied = parsed.ok ? tidy(normalizeNumbers(restoreApproximateNumbers(rawText, parsed.text))) : null;
      const sourceVerdict = tidied ? validateOutput({ rawText, output: tidied.text, strength: "prompt", termEvidence: context.dictionary }) : null;
      if (sourceVerdict?.reason === "entity-changed") {
        return this.nameQuestion(request, base, { question: "请确认这次口述中的名称。", evidence: sourceVerdict.metrics.missingNames[0] }, started);
      }
      if (!sourceVerdict?.ok) {
        const issue = sourceVerdict ? sourceVerdict.reason : `source-output-format:${parsed.failure ?? "unknown"}`;
        this.logger.warn?.("typeleast: source cleanup unusable (%s); translating the transcript directly", issue);
        const direct = await call(directTranslatePrompt(target)
          + harnessAddendum({ dictionary: context.dictionary, aliases: context.aliases, spellings: context.spellings, fieldContext: context.fieldContext ?? null })
          + variants, outboundText, 0.3);
        const attempts = cleanup.attempts + direct.attempts;
        const verdict = validateOutput({ rawText, output: String(direct.text ?? "").trim(), strength: "translate" });
        if (!verdict.ok) {
          const tidyOnly = tidy(rawText);
          return await this.recordFallback(request, {
            ...base, text: tidyOnly.text, fallback: true, reason: verdict.reason,
            detail: `${issue}; direct ${describeVerdict(verdict.metrics) ?? verdict.reason}`, ms: timing(started, 0), metrics: verdict.metrics,
            attempts, postprocess: tidyOnly.applied, translated: target,
          });
        }
        return await this.recordAndReturn(request, {
          ...base, text: verdict.text, ms: timing(started, 0), metrics: verdict.metrics,
          usage: { cleanup: cleanup.usage, translation: direct.usage },
          attempts, translated: target, detail: `direct-after:${issue}`,
        });
      }
      cleanedSource = sourceVerdict.text;
      const translation = await call(translatePrompt(target) + variants, redact(cleanedSource), 0.3);
      const verdict = validateOutput({ rawText: cleanedSource, output: String(translation.text ?? "").trim(), strength: "translate" });
      if (!verdict.ok) {
        return await this.recordFallback(request, {
          ...base, text: cleanedSource, fallback: true, reason: verdict.reason,
          detail: describeVerdict(verdict.metrics), ms: timing(started, 0), metrics: verdict.metrics,
          attempts: cleanup.attempts + translation.attempts, postprocess: tidied.applied, translated: target,
        });
      }
      return await this.recordAndReturn(request, {
        ...base, text: verdict.text, ms: timing(started, 0), metrics: verdict.metrics,
        usage: { cleanup: cleanup.usage, translation: translation.usage },
        attempts: cleanup.attempts + translation.attempts, translated: target,
      });
    } catch (error) {
      const reason = request.signal?.aborted
        ? "cancelled"
        : error instanceof ModelCallError ? failureReason(error) : "internal-error";
      const detail = this.redactDetail(failureDetail(error)).split(route.apiKey || "\u0000").join("[redacted-key]");
      this.stats.lastError = `${reason}: ${detail}`;
      this.logger.warn?.("typeleast: translation failed (%s: %s); using the cleaned source when available", reason, detail);
      const tidyOnly = tidy(rawText);
      return await this.recordFallback(request, {
        ...base, text: cleanedSource ?? tidyOnly.text, fallback: true, reason, detail, ms: timing(started, 0),
        attempts: error instanceof ModelCallError ? error.attempts : undefined,
        postprocess: cleanedSource === null ? tidyOnly.applied : undefined, translated: target,
      });
    }
  }

  /** Keep the whole clarification in memory until the user explicitly generates or cancels. */
  async polishBeta({ request, base, route, started, rawText, skip }) {
    const redact = text => this.config.redactSecrets === false ? text : redactSecrets(text);
    const call = async (system, user, maxTokens = 1800) => {
      this.stats.modelCalls += 1;
      const result = await completeOpenAI({ route, system, user: redact(user), maxTokens, temperature: 0.2,
        timeoutMs: Math.max(this.config.timeoutMs, 60000), signal: AbortSignal.any([request.signal, session.controller.signal].filter(Boolean)),
        ...(this.fetchImpl ? { fetchImpl: this.fetchImpl } : {}) });
      request.signal?.throwIfAborted();
      return result.text;
    };
    this.pruneBetaSessions();
    const id = request.betaSession || randomUUID();
    let session = this.betaSessions.get(id);
    if (request.betaSession && !session) throw Object.assign(new Error('clarification expired'), { code: 'beta-expired' });
    if (session?.busy) throw Object.assign(new Error('clarification in progress'), { code: 'model-busy' });
    if (!session && !hasContent(rawText)) {
      return { ...base, raw: '', text: '', fallback: true, reason: 'empty-transcript' };
    }
    if (!session) {
      if (rawText.length > BETA_LIMITS.inputChars) throw Object.assign(new Error('request too long'), { code: 'invalid-prompt' });
      // Do not evict another user's active operation to admit a new one.
      if (this.betaSessions.size >= BETA_LIMITS.sessions) throw Object.assign(new Error('too many clarifications'), { code: 'busy' });
      session = { request: rawText, turns: [], questions: betaSetupQuestions(rawText,request.language), confirmed: [], created: Date.now(), ready: false };
      this.betaSessions.set(id, session);
    }
    const pending = notice => ({ ...base, text: '', raw: rawText,
      beta: { sessionId: id, questions: session.questions, confirmed: session.confirmed,
        round: session.turns.length + 1, ready: session.ready, ...(notice ? { notice } : {}) }, ms: timing(started, 0) });
    if (request.betaSession && !skip && !hasContent(rawText)) return pending('empty-transcript');
    const turns = [...session.turns];
    if (request.betaSession && !skip) turns.push({ questions: [...session.questions], answer: rawText });
    const source = [session.request, ...turns.map(t => t.answer)].join('\n');
    if (source.length > BETA_LIMITS.inputChars) return pending('beta-input-limit');
    session.busy = true;
    session.created = Date.now();
    session.controller = new AbortController();
    try {
      if (!skip) {
        const reply = parseJsonReply(await call(BETA_INTERVIEW_PROMPT, interviewMessage(session.request, turns)));
        if (!reply || !Array.isArray(reply.questions) || !Array.isArray(reply.confirmed)) {
          throw Object.assign(new Error('invalid clarification'), { code: 'output-format' });
        }
        if (this.betaSessions.get(id) !== session) throw new DOMException('Cancelled', 'AbortError');
        const questions = request.betaSession ? normaliseQuestions(reply.questions) : betaSetupQuestions(rawText,request.language);
        if (reply.questions.length && !questions.length) throw Object.assign(new Error("invalid questions"), { code: "output-format" });
        session.turns = turns;
        session.spec = { goal: typeof reply.goal === 'string' ? reply.goal.slice(0, 500) : '' };
        session.confirmed = reply.confirmed.filter(x => typeof x === 'string').map(x => x.trim().slice(0, 240)).filter(Boolean).slice(0, 6);
        session.questions = questions;
        session.ready = session.questions.length === 0;
        session.created = Date.now();
        return pending();
      }
      const material = { request: session.request, spec: session.spec, turns,
        questions: session.questions, skipped: true };
      const draft = cleanPromptReply(await call(BETA_DRAFT_PROMPT, draftMessage(material), 3200));
      if (!draft) throw Object.assign(new Error('empty draft'), { code: 'output-format' });
      const reviewDraft = async text => {
        const review = parseJsonReply(await call(BETA_REVIEW_PROMPT, reviewMessage({ ...material, draft: text })));
        if (!review || !Array.isArray(review.issues)) throw Object.assign(new Error('invalid review'), { code: 'output-format' });
        if (review.issues.some(issue => !issue || typeof issue !== 'object' || typeof issue.type !== 'string')) {
          throw Object.assign(new Error('invalid review issue'), { code: 'output-format' });
        }
        const issueTypes = new Set(['invented', 'missing', 'contradiction', 'ambiguity', 'overemphasis', 'filler']);
        if (review.issues.some(issue => !issueTypes.has(issue.type) || typeof issue.quote !== 'string'
          || (issue.type === 'missing' ? issue.quote !== '' : !issue.quote.trim() || !text.includes(issue.quote)))) {
          throw Object.assign(new Error('review evidence does not match draft'), { code: 'output-format' });
        }
        return review.issues.slice(0, 8);
      };
      const issues = await reviewDraft(draft);
      let final = draft;
      if (issues.length) {
        final = cleanPromptReply(await call(BETA_PATCH_PROMPT, reviewMessage({ ...material, draft, issues }), 3200));
        if (!final || (await reviewDraft(final)).length) throw Object.assign(new Error('intent review failed'), { code: 'beta-validation' });
      }
      const verdict = validateOutput({ rawText: source, output: final, strength: 'promptbeta' });
      if (!verdict.ok) throw Object.assign(new Error('fact check failed'), { code: 'beta-validation' });
      if (this.betaSessions.get(id) !== session) throw new DOMException('Cancelled', 'AbortError');
      request.signal?.throwIfAborted();
      const result = await this.recordAndReturn(request, { ...base, raw: source, text: verdict.text,
        ms: timing(started, 0), metrics: verdict.metrics, beta: { reviewed: true, issues: issues.length, patched: final !== draft } });
      this.betaSessions.delete(id);
      return result;
    } catch (error) {
      // Never insert a partial draft or lose accepted answers after a failed round.
      if (request.signal?.aborted || this.betaSessions.get(id) !== session) throw error;
      const notice = error.code === 'beta-validation' ? 'beta-validation' : error instanceof ModelCallError ? failureReason(error) : 'output-format';
      return pending(notice);
    } finally {
      session.busy = false;
    }
  }

  /** Drop expired Prompt Beta sessions and keep the map bounded. */
  pruneBetaSessions(now = Date.now()) {
    for (const [id, session] of this.betaSessions) {
      if (!session.busy && now - session.created > BETA_LIMITS.sessionMs) this.betaSessions.delete(id);
    }
    while (this.betaSessions.size > BETA_LIMITS.sessions) {
      const idle = [...this.betaSessions].find(([, session]) => !session.busy);
      if (!idle) break;
      this.betaSessions.delete(idle[0]);
    }
  }

  /** Forget a Prompt Beta session the user cancelled. */
  cancelBeta(sessionId) {
    const id = String(sessionId ?? "");
    this.betaSessions.get(id)?.controller?.abort();
    return this.betaSessions.delete(id);
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
    const mode=canonicalStrength(request.strength??this.strength);
    if(!request.translateTo&&mode!=='promptbeta'&&result.reason!=='cancelled')return this.qualityQuestion(request,result);
    return await this.recordAndReturn(request, result);
  }

  async qualityQuestion(request,result) {
    const seed=request.variants?await applyVariants(result.text,parseVariants(request.variants),request.language??this.config.language??"auto"):result.text;
    const candidate=seed;
    return {...result,text:'',clarification:{kind:'quality',question:'整理尚未完成，请继续整理或编辑本次内容。',evidence:'',reason:result.reason,candidate,
      markerId:request.explanationMarkers??'',personalizationDisabled:readPolicy(requestPolicy(request)).disabled},suggestions:[]};
  }

  /** Failure text can quote provider responses; keep it to the history's privacy rules. */
  redactDetail(detail) {
    return this.config.redactSecrets === false ? detail : redactSecrets(detail);
  }

  /**
   * Finish one polish attempt: every exit path of polish() goes through here.
   * @param {object} request - the original request (for the written variant).
   * @param {object} result - the result about to be returned.
   * @returns {Promise<object>} the same result.
   */
  nameQuestion(request, base, clarification, started) {
    // Old clients cannot hold insertion: keep the safe raw fallback.
    if (!request.supportsClarification) return this.recordFallback(request, {
      ...base, fallback: true, reason: "entity-changed", ms: timing(started, 0),
    });
    return { ...base, text: "", clarification: { ...clarification, markerId: request.explanationMarkers ?? "", personalizationDisabled: readPolicy(requestPolicy(request)).disabled, ...(request.translateTo ? { target: request.translateTo } : {}) }, suggestions: [], ms: timing(started, 0) };
  }

  async recordAndReturn(request, result) {
    if(result.fallback&&!request.translateTo&&canonicalStrength(request.strength??this.strength)!=="promptbeta"&&result.reason!=="cancelled")return this.qualityQuestion(request,result);
    result = applyExplicitRules(result, request._personalization, result.explanation ? splitExplanation(result.raw, request.explanationMarkers).text : result.raw, canonicalStrength(request.strength ?? this.strength));
    // The written variant (繁體) is the last step, so the history and the inserted text agree.
    // It is for Chinese only: a translation into another language is never converted.
    const target = Object.hasOwn(TRANSLATE_LANGUAGES, request.translateTo ?? "") ? request.translateTo : null;
    // A failed translation returns source text. Unknown languages never opt in by their script.
    const outputLanguage = target ? (result.fallback ? "auto" : target) : (request.language ?? this.config.language ?? "auto");
    if (request.variants) result.text = await applyVariants(result.text, parseVariants(request.variants), outputLanguage);
    result.suggestions = [];
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
        rawText: [clarificationSource(request.dictionary), spoken.text].filter(Boolean).join("\n"),
        supportsClarification: request.supportsClarification === true,
        language: spoken.language ?? language,
        appHint: request.appHint,
        strength: request.strength,
        fieldContext: request.fieldContext ?? null,
        llm: request.llm ?? null,
        signal: request.signal,
        betaSession: request.betaSession ?? null,
        translateTo: request.translateTo ?? null,
        variants: request.variants ?? null,
        dictionary: Array.isArray(request.dictionary) ? request.dictionary : [],
        currentTermRules: clarificationRule(request.dictionary, spoken.text).map(rule => rule.heardAs + "=" + rule.word),
        explanationMarkers: request.explanationMarkers ?? null,
        personalization: requestPolicy(request),
      });
      const result = {
        requestId: request.requestId,
        text: polished.text,
        raw: polished.raw ?? spoken.text,
        fallback: polished.fallback,
        fallbackReason: polished.reason ?? undefined,
        suggestions: polished.suggestions ?? [],
        model: polished.model,
        provider: polished.provider,
        strength: request.strength ?? this.strength,
        ms: {
          transcribe: Math.round(spoken.ms),
          polish: polished.ms.polish,
          total: Date.now() - started,
        },
        metrics: polished.metrics,
        personalization: polished.personalization,
        ...(polished.beta ? { beta: polished.beta } : {}),
        ...(polished.clarification ? { clarification: polished.clarification } : {}),
        ...(polished.explanation ? { explanation: polished.explanation } : {}),
        ...(polished.contextOnly ? { contextOnly: true } : {}),
        ...(polished.translated ? { translated: polished.translated } : {}),
      };
      this.stats.dictations += 1;
      if (result.fallback) this.stats.fallback += 1;
      else if (!result.clarification && !result.beta?.sessionId && !result.contextOnly) this.stats.polished += 1;
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
    return { text: String(spoken.text ?? "").trim(), language: language !== "auto" ? language : (spoken.detectedLanguage ?? spoken.language ?? "auto"), ms: Date.now() - started };
  }

  /**
   * Assemble bounded, redacted context for one call. Of the dictionary, only the entries
   * this dictation (or the field the user let it read) mentions go to the model.
   */
  async buildContext(request, rawText) {
    const redact = this.config.redactSecrets !== false;
    const fieldContext = request.fieldContext ?? null;
    const own = [];
    let data;
    try { data = await personalizationContext(request, own, this.extension, rawText); }
    catch {
      // Optional personalization must not become a dependency of dictation.
      data = {dictionary:[],aliases:[],style:null,policy:{disabled:true,rules:[]},trace:{disabled:true,references:[],replacements:[],blocked:[]}};
    }
    request._personalization = data;
    const entries = [...data.dictionary, ...(request.currentTermRules ?? [])], aliases = data.aliases;
    return {
      style: data.style,
      dictionary: entries.map(entry => redact ? redactSecrets(entry) : entry),
      aliases,
      // Found in the outbound text, so a redacted secret cannot return through a hint.
      spellings: spelledWords(redact ? redactSecrets(rawText) : rawText),
      // The text box being dictated into is the most relevant context there is.
      fieldContext: redactFieldContext(fieldContext, redact),
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

/** Longest dictionary a request may carry, and longest entry. */
export const DICTIONARY_LIMITS = { entries: 2000, entryLength: 120 };

/**
 * The dictionary for one call: config.json's entries, then the app's (each a word to
 * spell exactly, or "heard=word"), trimmed, bounded and without duplicates.
 * @param {string[]} configured - entries from config.json.
 * @param {unknown} sent - the app's list from the request.
 * @returns {string[]} entries to use.
 */
export function dictionaryFrom() { return []; }

/**
 * Entries the user marked 「不发给模型」 arrive as {"local": "heard=word"} (or {"local": "word"})
 * next to the ordinary strings. They never reach a model request; those with a heard-as
 * spelling become replacements made on this computer.
 * @returns {Array<[string, string]>} heard-as and correct spellings.
 */
export function localEntriesFrom() { return []; }

/** Marked entries that are only a spelling (no "heard=" part). */
export function localSpellingsFrom(sent) {
  const words = [];
  for (const entry of Array.isArray(sent) ? sent.slice(0, DICTIONARY_LIMITS.entries) : []) {
    const text = entry && typeof entry === "object" && typeof entry.local === "string" ? entry.local.trim().slice(0, DICTIONARY_LIMITS.entryLength) : "";
    if (text && !text.includes("=")) words.push(text);
  }
  return words;
}

/** Replace heard-as spellings: anywhere for Chinese, as whole words (any case) for latin. */
export function applyLocalEntries(text) { return text; }

/** Narrow an unknown throwable to a printable message. */
function message(error) {
  return error instanceof Error ? error.message : String(error);
}

