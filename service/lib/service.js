import {hasTermExplanation} from './entity-guard.js';
import {taskFor} from './dictation-task.js';
import {generateDictation, TEXT_LIMIT} from './long-dictation.js';
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
import { wordSuggestions } from "./word-suggestions.js";
import { spelledWords } from "./spelling.js";
import { canonicalStrength, LANGUAGES } from "./config.js";
import { createHash, randomUUID } from "node:crypto";
import { redactFieldContext, redactSecrets } from "./context.js";
import { buildUserMessage, harnessAddendum, promptVersionFor, systemPromptFor } from "./prompt.js";
import { completeOpenAI, normalizeRoute, routeLabel } from "./openai-compat.js";
import { parsePolishOutput } from "./parse-output.js";
import { createDeadline, failureDetail, failureReason, ModelCallError } from "./llm.js";
import { restoreApproximateNumbers, validateOutput } from "./validate.js";
import { normalizeNumbers } from './number-format.js';
import { normalizeTermCase, tidy } from "./tidy.js";
import { validateWav } from "./wav.js";
import {
  BETA_DRAFT_PROMPT, BETA_INTERVIEW_PROMPT, BETA_LIMITS,
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
    this.suggestionEngine = options.suggestionEngine ?? wordSuggestions;
    this.extension = options.extension ?? null;
    this.logger = options.logger ?? { info: () => {}, warn: () => {}, debug: () => {} };
    this.pending = 0;
    this.queue = 0;
    this.version = options.version ?? "0.2.0";
    /** The route of the most recent cleanup, for /health: "custom:<host>" and model id. */
    this.lastRoute = { provider: null, model: null };
    this.startedAt = Date.now();
    /** Entries from config.json; each request adds the app's own dictionary (dictionaryFrom). */
    this.dictionary = [...(this.config.dictionary ?? [])];
    // dictations/polished/fallback/lastMs count /dictate; modelCalls and
    // modelFallbacks count every polish() that reached the model, /polish included.
    this.stats = { dictations: 0, polished: 0, fallback: 0, lastError: null, lastMs: null, modelCalls: 0, modelFallbacks: 0, jsonFallback: 0, jsonRecovered: 0 };
    /** Newest first; only attempts that reached the model and fell back. */
    this.recentFailures = [];
    /** Prompt Beta question sessions: id -> { request, spec, questions, created }. */
    this.betaSessions = new Map();
    this.progress = new Map();
  }

  setProgress(id, value) {
    if (typeof id !== 'string' || !/^[A-Za-z0-9-]{1,80}$/.test(id)) return;
    for (const [key, item] of this.progress) if (Date.now() - item.updated > 600000) this.progress.delete(key);
    if (!this.progress.has(id) && this.progress.size >= 20) return;
    this.progress.set(id, {stage:value.stage,completed:value.completed,total:value.total,updated:Date.now()});
  }
  taskProgress(id) {
    const item = this.progress.get(id);
    return item && Date.now() - item.updated < 600000 ? {stage:item.stage,completed:item.completed,total:item.total} : {stage:'waiting',completed:0,total:0};
  }

  get strength() {
    return "prompt";
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
      task: "dictation",
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
    const taskKind = taskFor(request);
    if (taskKind !== 'translation') request.translateTo = null;
    else if (!Object.hasOwn(TRANSLATE_LANGUAGES, request.translateTo ?? '')) throw Object.assign(new Error('translation target required'),{code:'invalid-task'});
    request.task = taskKind;
    request.strength = taskKind === "assistant" ? "promptbeta" : "prompt";
    const started = Date.now();
    const originalText = String(request.rawText ?? "").trim();
    if (Array.from(originalText).length > TEXT_LIMIT) return this.qualityQuestion(request,{
      task:taskKind,raw:originalText,text:originalText,fallback:true,reason:'text-too-long',ms:timing(started,0),
    });
    // The retired prompt-mode tiers (promptbrief, promptify) are read as 精简整理.
    const strength = canonicalStrength(request.strength ?? this.strength);
    const explanation = strength !== "promptbeta" && !request.translateTo
      ? splitExplanation(originalText, request.explanationMarkers) : { text: originalText, notes: [], used: false };
    const rawText = explanation.text;
    const base = {
      task: taskKind,
      raw: originalText,
      text: rawText,
      fallback: false,
      reason: null,
      model: null,
      provider: null,
      ms: { transcribe: 0, polish: Date.now() - started, total: Date.now() - started },
    };
    // An unmatched marker remains ordinary source text; one-shot modes never ask for a continuation.
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

    const task = request._cleanupTask ?? new CleanupTask(request.signal);
    let candidate = null;
    try {
    const context = await this.buildContext(request, rawText);
    const safeNotes = explanation.notes.map(s => redactSecrets(s));
    const nameRules = explanationNameRule(rawText, safeNotes);
    context.dictionary.push(...nameRules);
    const rawExamples = request._translationSource ? [] : request.preferenceExamples ?? requestPreferences(request.dictionary);
    const filteredExamples = (Array.isArray(rawExamples) ? rawExamples : []).filter(x => x && ![x.raw,x.aiText,x.correctedText].some(v => typeof v === "string" && request._personalization.excludedText?.(v)));
    const examples = request._personalization.policy.disabled ? [] : preferenceHints(filteredExamples, rawText);
    request._personalization.trace.references.push(...examples.map(x=>({kind:"example",source:"personal",sourceId:filteredExamples.find(y=>y.raw===x.raw&&y.correctedText===x.correctedText)?.id??"example"})));
    const style = request._translationSource ? null : context.style?.instructions ?? null;
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

    const parameters = cleanupParameters(rawText, strength, this.config);
    const call = async (system, user, options = parameters) => {
      task.assertTime();
      this.stats.modelCalls += 1;
      return completeOpenAI({route: custom, system, user, ...options, signal: task.signal,
        retryBudget: task, ...(this.fetchImpl ? {fetchImpl:this.fetchImpl} : {})});
    };
    const result = await generateDictation({source:user, system, call, parameters,
      progress: value => this.setProgress(request.requestId, value)});
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
      if (parsed.clarification) return this.retainSourceName(request, base, rawText, started);
      if (parsed.mode !== "json") this.stats.jsonRecovered += 1;
      // Deterministic cleanup runs BEFORE validation so the safety checks judge
      // exactly the text that would be inserted.
      const tidied = tidy(normalizeNumbers(restoreApproximateNumbers(rawText, parsed.text)));
      candidate = tidied.text;
      let reviewed = false;
      const reviewCandidate = async () => {
        reviewed = true;
        this.stats.modelCalls += 1;
        const source = redactSecrets(rawText);
        const review = await completeOpenAI({route:custom,system:CLEANUP_REVIEW_PROMPT,
          user:JSON.stringify({source,candidate:redactSecrets(candidate),explanation:safeNotes,mode:strength,fieldContext:context.fieldContext}),
          maxTokens:1200,temperature:0,timeoutMs:Math.min(60000,Math.max(15000,Array.from(rawText).length*10)),signal:task.signal,retryBudget:task,
          ...(this.fetchImpl?{fetchImpl:this.fetchImpl}:{})});
        return parseCleanupReview(review.text,source,redactSecrets(candidate));
      };
      let verdict = validateOutput({ rawText, output: candidate, strength, termEvidence: context.dictionary });
      if (!verdict.ok && verdict.reason === "entity-changed") {
        // A current explanation can resolve a name, but it cannot waive other fact checks.
        if (!hasTermExplanation(originalText) && !explanation.used) return this.retainSourceName(request, base, rawText, started);
        const issues = await reviewCandidate();
        if (issues === null || issues.length) return this.retainSourceName(request, base, rawText, started);
        verdict = validateOutput({rawText,output:candidate,strength,termEvidence:context.dictionary,nameChangesReviewed:true,meaningReviewed:true});
      }
      if (!verdict.ok && ['output-too-short','invented-content'].includes(verdict.reason)) {
        const issues = reviewed ? null : await reviewCandidate();
        if (issues === null || issues.length) return this.recordFallback(request,{...base,text:candidate,fallback:true,reason:issues===null?'review-invalid':'incomplete-output',ms:timing(started,0)});
        verdict = validateOutput({rawText,output:candidate,strength,termEvidence:context.dictionary,meaningReviewed:true});
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
      this.setProgress(request.requestId,{stage:'checking',completed:0,total:1});
      if (!reviewed && needsCleanupReview(rawText, candidate, verdict.metrics)) {
        const issues = await reviewCandidate();
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
    } finally { if (!request._cleanupTask) task.dispose(); }
  }

  /**
   * Clean and validate the source, then translate it in a second call. A source
   * that fails cleanup is translated directly in one call instead, so the user
   * still gets the target language; only when that fails too is the tidied
   * original inserted.
   */
  async polishTranslate({ request, base, route, started, rawText, target }) {
    const task = new CleanupTask(request.signal);
    let cleanedSource = null;
    try {
      const cleaned = await this.polish({...request, task:'dictation', translateTo:null, variants:null, _translationSource:true, _cleanupTask:task});
      if (cleaned.fallback || cleaned.clarification || cleaned.contextOnly) {
        return {...cleaned,task:'translation',translated:target,
          ...(cleaned.clarification ? {clarification:{...cleaned.clarification,target}} : {})};
      }
      cleanedSource = cleaned.text;
      this.setProgress(request.requestId,{stage:'translating',completed:0,total:1});
      this.stats.modelCalls += 1;
      const parameters = cleanupParameters(cleanedSource,'prompt',this.config);
      const result = await completeOpenAI({route,system:translatePrompt(target)
        + (target === 'en' ? variantInstruction(parseVariants(request.variants)) : ''),
        user:this.config.redactSecrets === false ? cleanedSource : redactSecrets(cleanedSource),
        ...parameters,temperature:0.2,signal:task.signal,retryBudget:task,
        ...(this.fetchImpl ? {fetchImpl:this.fetchImpl} : {})});
      const verdict = validateOutput({rawText:cleanedSource,output:String(result.text ?? '').trim(),strength:'translate'});
      task.assertTime();
      if (!verdict.ok) return this.recordFallback(request,{...base,text:String(result.text ?? ''),fallback:true,reason:verdict.reason,ms:timing(started,0)});
      return this.recordAndReturn(request,{...base,text:verdict.text,translated:target,ms:timing(started,0),attempts:result.attempts});
    } catch (error) {
      const reason = request.signal?.aborted ? 'cancelled' : task.deadline.timedOut() ? 'model-timeout' : failureReason(error);
      return this.recordFallback(request,{...base,text:cleanedSource ?? rawText,fallback:true,reason,ms:timing(started,0),translated:target});
    } finally { task.dispose(); }
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
      session = { request: rawText, turns: [], questions: [], confirmed: [], created: Date.now(), ready: false };
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
        const questions = normaliseQuestions(reply.questions);
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
      const draft = cleanPromptReply(await call(BETA_DRAFT_PROMPT, draftMessage(material), cleanupParameters(source,'prompt',this.config).maxTokens));
      if (!draft) throw Object.assign(new Error('empty draft'), { code: 'output-format' });
      const final = draft;
      const verdict = validateOutput({ rawText: source, output: final, strength: 'promptbeta' });
      if (!verdict.ok) throw Object.assign(new Error('fact check failed'), { code: 'beta-validation' });
      if (this.betaSessions.get(id) !== session) throw new DOMException('Cancelled', 'AbortError');
      request.signal?.throwIfAborted();
      const result = await this.recordAndReturn(request, { ...base, raw: source, text: verdict.text,
        ms: timing(started, 0), metrics: verdict.metrics, beta: { reviewed: false, issues: 0, patched: false } });
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
    if(mode!=='promptbeta'&&result.reason!=='cancelled')return this.qualityQuestion(request,result);
    return await this.recordAndReturn(request, result);
  }

  async retainSourceName(request, base, source, started) {
    return this.qualityQuestion(request,{...base,text:tidy(source).text,fallback:true,reason:'name-kept',suggestions:[],ms:timing(started,0)});
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
    if(result.fallback&&canonicalStrength(request.strength??this.strength)!=="promptbeta"&&result.reason!=="cancelled")return this.qualityQuestion(request,result);
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
      this.setProgress(request.requestId,{stage:"recognizing",completed:0,total:0});
      const spoken = await this.transcribe(audio, language, request.signal);
      const polished = await this.polish({
        task: request.task,
        requestId: request.requestId,
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
        task: polished.task,
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
      this.setProgress(request.requestId,{stage:"complete",completed:1,total:1});
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
  async transcribe(audio, language, signal) {
    const started = Date.now();
    const deadline = createDeadline(signal,300000);
    try {
      deadline.signal.throwIfAborted();
      const spoken = await this.recognizer.transcribe(audio, language, deadline.signal);
      deadline.signal.throwIfAborted();
      return { text: String(spoken.text ?? "").trim(), language: language !== "auto" ? language : (spoken.detectedLanguage ?? spoken.language ?? "auto"), ms: Date.now() - started };
    } finally { deadline.dispose(); }
  }

  /**
   * Assemble bounded, redacted context for one call. Of the dictionary, only the entries
   * this dictation (or the field the user let it read) mentions go to the model.
   */
  async buildContext(request, rawText) {
    const redact = this.config.redactSecrets !== false;
    const fieldContext = request.fieldContext ?? null;
    const own = dictionaryFrom(this.dictionary, request.dictionary);
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
export function dictionaryFrom(configured, sent) {
  const entries = [...configured];
  for (const entry of Array.isArray(sent) ? sent.slice(0, DICTIONARY_LIMITS.entries) : []) {
    let value = typeof entry === "string" ? entry : "";
    if (entry && typeof entry === "object" && typeof entry.word === "string") {
      const word = entry.word.trim();
      const heard = typeof entry.heardAs === "string" ? entry.heardAs.trim() : "";
      // Structured automatic entries cannot smuggle a legacy A=B rule in the word field.
      if (!word || /[=\p{Cc}]/u.test(word + heard) || word.length + heard.length > DICTIONARY_LIMITS.entryLength - 1) continue;
      value = (entry.source === "manual" && heard ? heard + "=" : "") + word;
    }
    const trimmed = value.trim().split("=").at(-1).trim().slice(0, DICTIONARY_LIMITS.entryLength);
    if (trimmed.length > 0 && !entries.includes(trimmed)) entries.push(trimmed);
  }
  return entries;
}

/**
 * Entries the user marked 「不发给模型」 arrive as {"local": "heard=word"} (or {"local": "word"})
 * next to the ordinary strings. They never reach a model request; those with a heard-as
 * spelling become replacements made on this computer.
 * @returns {Array<[string, string]>} heard-as and correct spellings.
 */
export function localEntriesFrom(sent) {
  const pairs = [];
  for (const entry of Array.isArray(sent) ? sent.slice(0, DICTIONARY_LIMITS.entries) : []) {
    if (entry?.source === "auto") continue;
    const text = entry && typeof entry === "object" && typeof entry.local === "string" ? entry.local.trim().slice(0, DICTIONARY_LIMITS.entryLength) : "";
    const split = text.indexOf("=");
    if (split <= 0) continue;
    const heard = text.slice(0, split).trim(), word = text.slice(split + 1).trim();
    if (heard && word && heard !== word) pairs.push([heard, word]);
  }
  return pairs;
}

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
export function applyLocalEntries(text, pairs) {
  if (!pairs.length || typeof text !== "string" || !text) return text;
  let out = text;
  for (const [heard, word] of pairs) {
    if (/[\u3400-\u9fff\uf900-\ufaff]/u.test(heard)) out = out.split(heard).join(word);
    else out = out.replace(new RegExp(`(?<![\\p{L}\\p{N}])${heard.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}(?![\\p{L}\\p{N}])`, "giu"), () => word);
  }
  return out;
}

/** Narrow an unknown throwable to a printable message. */
function message(error) {
  return error instanceof Error ? error.message : String(error);
}

