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
import { taskFor } from "./dictation-task.js";
import { redactSecrets } from "./context.js";
import { promptVersionFor } from "./prompt.js";
import { completeOpenAI, normalizeRoute, routeLabel } from "./openai-compat.js";
import { createDeadline } from "./llm.js";
import { tidy } from "./tidy.js";
import { validateWav } from "./wav.js";
import { TRANSLATE_LANGUAGES } from "./prompts/translate.js";
import { applyVariants, parseVariants } from "./variants.js";
import { runDictation } from "./tasks/dictation.js";
import { runTranslation } from "./tasks/translation.js";
import { AssistantSessions } from "./tasks/assistant.js";
import { buildProfile } from "./tasks/profile.js";
import { timing } from "./tasks/timing.js";

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
    /** Prompt mode's open clarifications. */
    this.assistant = new AssistantSessions();
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
    if (rawText.length === 0 && !betaSkip && !(strength === "promptbeta" && (request.betaSession || request.baseline))) {
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

    const ctx = this.taskContext({ request, base, route: custom, started, rawText });
    // 翻译模式 has its own hotkey and prompt: one call cleans up and translates.
    const translateTo = Object.hasOwn(TRANSLATE_LANGUAGES, request.translateTo ?? "") ? request.translateTo : null;
    if (translateTo) return await runTranslation(ctx, translateTo);
    if (strength === "promptbeta") return await this.assistant.run(ctx, betaSkip);
    return await runDictation(ctx);
  }

  /**
   * What a task module receives: the request, the route, and the service's hooks for model
   * calls, redaction, progress and finishing (see tasks/dictation.js).
   */
  taskContext({ request, base, route, started, rawText }) {
    return {
      request, base, route, started, rawText,
      config: this.config,
      logger: this.logger,
      stats: this.stats,
      complete: (options) => this.complete({ route, ...options }),
      redact: (text) => this.redactDetail(text),
      progress: (stage) => this.setProgress(request.requestId, { stage, completed: 0, total: 1 }),
      done: (result) => this.recordAndReturn(request, result),
      fail: (result) => this.recordFallback(request, result),
    };
  }

  /** One model call; every call is counted for /health. */
  complete(options) {
    this.stats.modelCalls += 1;
    return completeOpenAI({ ...options, ...(this.fetchImpl ? { fetchImpl: this.fetchImpl } : {}) });
  }

  /** Prompt mode's sessions, for the tests and diagnostics. */
  get betaSessions() {
    return this.assistant.map;
  }

  /** Drop expired prompt-mode sessions. */
  pruneBetaSessions(now = Date.now()) {
    this.assistant.prune(now);
  }

  /** Forget a prompt-mode session the user cancelled. */
  cancelBeta(sessionId) {
    return this.assistant.cancel(sessionId);
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
        baseline: request.baseline ?? null,
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
  async buildProfile(request) {
    return buildProfile(request, (options) => this.complete(options), (text) => this.redactDetail(text));
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



/** Narrow an unknown throwable to a printable message. */
function message(error) {
  return error instanceof Error ? error.message : String(error);
}

