import {taskFor} from './dictation-task.js';
import {CleanupTask, cleanupParameters} from './cleanup-task.js';
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
 * The service keeps no dictation history: each app keeps it (encrypted) and sends,
 * with every request, the short description of the user's work it learned from it.
 *
 * Recognition is local (asr.js). Cleanup uses the model and API key the app
 * sends with each request (openai-compat.js); the service stores no key.
 *
 * @module typeleast-service/service
 */
import { canonicalStrength, LANGUAGES } from "./config.js";
import { createHash, randomUUID } from "node:crypto";
import { redactFieldContext, redactSecrets } from "./context.js";
import { buildUserMessage, promptVersionFor, systemPromptFor } from "./prompt.js";
import { completeOpenAI, normalizeRoute, routeLabel } from "./openai-compat.js";
import { parsePolishOutput } from "./parse-output.js";
import { createDeadline, failureDetail, failureReason, ModelCallError } from "./llm.js";
import { PROFILE_PROMPT, profileMessage, readProfile } from "./prompts/profile.js";
import { unwrap } from "./validate.js";
import { tidy } from "./tidy.js";
import { validateWav } from "./wav.js";
import {
  BETA_BREAKDOWN_PROMPT, BETA_DRAFT_PROMPT, BETA_INTERVIEW_PROMPT, BETA_LIMITS,
  boundaryQuestions, cleanPromptReply, draftMessage, hasContent, interviewMessage, normaliseQuestions, parseJsonReply, reviewMessage,
} from "./prompts/prompt-beta.js";
import { directTranslatePrompt, TRANSLATE_LANGUAGES } from "./prompts/translate.js";
import { applyVariants, parseVariants, variantInstruction } from "./variants.js";

/** Longest transcript cleaned by the model, in characters. */
export const TEXT_LIMIT = 32000;
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
    this.logger = options.logger ?? { info: () => {}, warn: () => {}, debug: () => {} };
    this.pending = 0;
    this.queue = 0;
    this.version = options.version ?? "0.2.0";
    /** The route of the most recent cleanup, for /health: "custom:<host>" and model id. */
    this.lastRoute = { provider: null, model: null };
    this.startedAt = Date.now();
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
    if (Array.from(originalText).length > TEXT_LIMIT) return this.recordAndReturn(request,{
      task:taskKind,raw:originalText,text:tidy(originalText).text,fallback:true,reason:'text-too-long',ms:timing(started,0),
    });
    const strength = canonicalStrength(request.strength ?? this.strength);
    const rawText = originalText;
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
    // Skipping Prompt Beta's questions sends no answer at all, which is not an empty dictation.
    const betaSkip = strength === "promptbeta" && request.betaSkip === true && Boolean(request.betaSession);
    if (rawText.length === 0 && !betaSkip && !(strength === "promptbeta" && request.betaSession)) {
      if (strength === "promptbeta") return { ...base, text: "", fallback: true, reason: "empty-transcript" };
      return await this.recordAndReturn(request, { ...base, fallback: true, reason: "empty-transcript" });
    }
    // The model and the user's own API key come with the request. Without a
    // usable route there is nothing to call: the tidied transcript is inserted.
    const custom = request.llm ? normalizeRoute(request.llm) : null;
    if (!custom) {
      const tidyOnly = tidy(rawText);
      return await this.recordAndReturn(request, { ...base, text: tidyOnly.text, fallback: true, reason: "no-api-key", postprocess: tidyOnly.applied });
    }
    base.provider = routeLabel(custom);
    base.model = custom.model;
    this.lastRoute = { provider: base.provider, model: base.model };

    // 翻译模式 has its own hotkey and prompt: one call cleans up and translates.
    const translateTo = Object.hasOwn(TRANSLATE_LANGUAGES, request.translateTo ?? "") ? request.translateTo : null;
    if (translateTo) return await this.polishTranslate({ request, base, route: custom, started, rawText, target: translateTo });
    if (strength === "promptbeta") return await this.polishBeta({ request, base, route: custom, started, rawText, skip: betaSkip });

    const task = new CleanupTask(request.signal);
    const redact = this.config.redactSecrets !== false;
    try {
      const system = systemPromptFor({
        fieldContext: redactFieldContext(request.fieldContext ?? null, redact),
        profile: redact ? redactSecrets(String(request.profile ?? "")) : request.profile,
      }) + variantInstruction(parseVariants(request.variants));
      // The transcript is redacted on the way OUT to the provider: a dictated key or
      // password must not reach the model. The user gets the model's text (or the original).
      const user = buildUserMessage({ rawText: redact ? redactSecrets(rawText) : rawText });
      this.setProgress(request.requestId, { stage: "generating", completed: 0, total: 1 });
      this.stats.modelCalls += 1;
      const result = await completeOpenAI({ route: custom, system, user, ...cleanupParameters(rawText, strength, this.config),
        signal: task.signal, retryBudget: task, ...(this.fetchImpl ? { fetchImpl: this.fetchImpl } : {}) });
      task.assertTime();
      // A reply that is not the expected JSON must not reach the document.
      const parsed = parsePolishOutput(result.text);
      if (!parsed.ok) {
        this.stats.jsonFallback += 1;
        const tidyOnly = tidy(rawText);
        const detail = `output-format:${parsed.failure ?? "unknown"}`;
        this.stats.lastError = detail;
        this.logger.warn?.("typeleast: unusable model reply (%s)", detail);
        return await this.recordFallback(request, { ...base, text: tidyOnly.text, fallback: true, reason: "output-format", detail,
          ms: timing(started, 0), attempts: result.attempts, postprocess: tidyOnly.applied });
      }
      if (parsed.mode !== "json") this.stats.jsonRecovered += 1;
      // The cleaned text is inserted as the model wrote it, minus a wrapper a chatty model may add.
      const candidate = unwrap(parsed.text).text.trim();
      if (!candidate) {
        const tidyOnly = tidy(rawText);
        return await this.recordFallback(request, { ...base, text: tidyOnly.text, fallback: true, reason: "empty-output",
          ms: timing(started, 0), attempts: result.attempts, postprocess: tidyOnly.applied });
      }
      return await this.recordAndReturn(request, {
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
      if (!(error instanceof ModelCallError) && !request.signal?.aborted && !task.deadline.timedOut()) this.logger.warn?.("typeleast: internal cleanup error (%s)", error?.name ?? "error");
      const reason = request.signal?.aborted
        ? "cancelled"
        : task.deadline.timedOut() ? "model-timeout" : error instanceof ModelCallError ? failureReason(error) : "internal-error";
      const detail = this.redactDetail(failureDetail(error)).split(custom.apiKey || "\u0000").join("[redacted-key]");
      this.stats.lastError = `${reason}: ${detail}`;
      this.logger.warn?.("typeleast: polishing failed (%s: %s)", reason, detail);
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
    } finally { task.dispose(); }
  }

  /** Clean up and translate the recognised transcript in one call; on failure the tidied original is inserted. */
  async polishTranslate({ request, base, route, started, rawText, target }) {
    const task = new CleanupTask(request.signal);
    const redact = this.config.redactSecrets !== false;
    try {
      this.setProgress(request.requestId,{stage:'translating',completed:0,total:1});
      this.stats.modelCalls += 1;
      const result = await completeOpenAI({route,system:directTranslatePrompt(target)
        + (target === 'en' ? variantInstruction(parseVariants(request.variants)) : ''),
        user:redact ? redactSecrets(rawText) : rawText,
        ...cleanupParameters(rawText,'prompt',this.config),temperature:0.2,signal:task.signal,retryBudget:task,
        ...(this.fetchImpl ? {fetchImpl:this.fetchImpl} : {})});
      const translated = unwrap(String(result.text ?? '')).text.trim();
      task.assertTime();
      if (!translated) return this.recordFallback(request,{...base,text:tidy(rawText).text,fallback:true,reason:'empty-output',ms:timing(started,0),translated:target});
      return this.recordAndReturn(request,{...base,text:translated,translated:target,ms:timing(started,0),attempts:result.attempts});
    } catch (error) {
      const reason = request.signal?.aborted ? 'cancelled' : task.deadline.timedOut() ? 'model-timeout' : failureReason(error);
      return this.recordFallback(request,{...base,text:tidy(rawText).text,fallback:true,reason,ms:timing(started,0),translated:target});
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
      session = { request: rawText, turns: [], questions: [], confirmed: [], goals: [], selection: request.source === 'selection', created: Date.now(), ready: false };
      this.betaSessions.set(id, session);
    }
    const pending = notice => ({ ...base, text: '', raw: rawText,
      beta: { sessionId: id, questions: session.questions, confirmed: session.confirmed, goals: session.goals ?? [],
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
        const reply = parseJsonReply(await call(session.selection ? BETA_BREAKDOWN_PROMPT : BETA_INTERVIEW_PROMPT, interviewMessage(session.request, turns)));
        if (!reply || !Array.isArray(reply.questions) || !Array.isArray(reply.confirmed)) {
          throw Object.assign(new Error('invalid clarification'), { code: 'output-format' });
        }
        if (this.betaSessions.get(id) !== session) throw new DOMException('Cancelled', 'AbortError');
        const modelQuestions = normaliseQuestions(reply.questions);
        if (reply.questions.length && !modelQuestions.length) throw Object.assign(new Error("invalid questions"), { code: "output-format" });
        // The task's boundaries come first: what may be read or searched, and creative or routine work.
        const questions = normaliseQuestions([...boundaryQuestions(session.request, turns), ...modelQuestions]);
        session.turns = turns;
        session.spec = { goal: typeof reply.goal === 'string' ? reply.goal.slice(0, 500) : '' };
        session.confirmed = reply.confirmed.filter(x => typeof x === 'string').map(x => x.trim().slice(0, 240)).filter(Boolean).slice(0, session.selection ? 8 : 6);
        if (Array.isArray(reply.goals)) session.goals = reply.goals.filter(x => typeof x === 'string').map(x => x.trim().slice(0, 200)).filter(Boolean).slice(0, 5);
        session.questions = questions;
        session.ready = session.questions.length === 0;
        session.created = Date.now();
        return pending();
      }
      const material = { request: session.request, spec: session.spec, turns,
        questions: session.questions, skipped: true };
      const draft = cleanPromptReply(await call(BETA_DRAFT_PROMPT, draftMessage(material), cleanupParameters(source,'prompt',this.config).maxTokens));
      if (!draft) throw Object.assign(new Error('empty draft'), { code: 'output-format' });
      if (this.betaSessions.get(id) !== session) throw new DOMException('Cancelled', 'AbortError');
      request.signal?.throwIfAborted();
      const result = await this.recordAndReturn(request, { ...base, raw: source, text: unwrap(draft).text.trim(),
        ms: timing(started, 0), beta: { reviewed: false, issues: 0, patched: false } });
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
    return await this.recordAndReturn(request, result);
  }

  /** Failure text can quote provider responses; keep it to the history's privacy rules. */
  redactDetail(detail) {
    return this.config.redactSecrets === false ? detail : redactSecrets(detail);
  }

  /** Finish one polish attempt: every exit path of polish() goes through here. */
  async recordAndReturn(request, result) {
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
        profile: request.profile ?? "",
      });
      const result = {
        requestId: request.requestId,
        task: polished.task,
        text: polished.text,
        raw: polished.raw ?? spoken.text,
        fallback: polished.fallback,
        fallbackReason: polished.reason ?? undefined,
        suggestions: [],
        model: polished.model,
        provider: polished.provider,
        strength: request.strength ?? this.strength,
        ms: {
          transcribe: Math.round(spoken.ms),
          polish: polished.ms.polish,
          total: Date.now() - started,
        },
        ...(polished.corrections ? { corrections: polished.corrections } : {}),
        ...(polished.intention ? { intention: polished.intention } : {}),
        ...(polished.beta ? { beta: polished.beta } : {}),
        ...(polished.translated ? { translated: polished.translated } : {}),
      };
      this.setProgress(request.requestId,{stage:"complete",completed:1,total:1});
      this.stats.dictations += 1;
      if (result.fallback) this.stats.fallback += 1;
      else if (!result.beta?.sessionId) this.stats.polished += 1;
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
   * Describe the user's work from what their history learned: the terms the model corrected and
   * what they asked for. The app calls this once when it starts and keeps the answer.
   * @param {object} request - the route and the history items.
   * @returns {Promise<{profile: string}>} at most PROFILE_LIMIT characters, possibly empty.
   */
  async buildProfile({ llm, items, signal }) {
    const route = llm ? normalizeRoute(llm) : null;
    if (!route) throw Object.assign(new Error("model route required"), { code: "no-api-key" });
    const message = profileMessage(items);
    if (!message) return { profile: "" };
    const redact = this.config.redactSecrets !== false;
    this.stats.modelCalls += 1;
    const result = await completeOpenAI({ route, system: PROFILE_PROMPT, user: redact ? redactSecrets(message) : message,
      maxTokens: 1200, temperature: 0.2, timeoutMs: 60000, signal, ...(this.fetchImpl ? { fetchImpl: this.fetchImpl } : {}) });
    return { profile: readProfile(result.text) };
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


/** Narrow an unknown throwable to a printable message. */
function message(error) {
  return error instanceof Error ? error.message : String(error);
}

