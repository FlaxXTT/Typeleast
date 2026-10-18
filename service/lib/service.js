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
import { createHash } from "node:crypto";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname } from "node:path";
import { redactFieldContext, redactSecrets } from "./context.js";
import { buildUserMessage, promptVersionFor, systemPromptFor } from "./prompt.js";
import { completeOpenAI, normalizeRoute, routeLabel } from "./openai-compat.js";
import { parsePolishOutput } from "./parse-output.js";
import { failureDetail, failureReason, ModelCallError } from "./llm.js";
import { validateOutput } from "./validate.js";
import { tidy } from "./tidy.js";
import { validateWav } from "./wav.js";

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
    this.dictionary = [...(this.config.dictionary ?? [])];
    // dictations/polished/fallback/lastMs count /dictate; modelCalls and
    // modelFallbacks count every polish() that reached the model, /polish included.
    this.stats = { dictations: 0, polished: 0, fallback: 0, lastError: null, lastMs: null, modelCalls: 0, modelFallbacks: 0, jsonFallback: 0, jsonRecovered: 0 };
    /** Newest first; only attempts that reached the model and fell back. */
    this.recentFailures = [];
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
    if (rawText.length === 0) return await this.recordAndReturn(request, { ...base, fallback: true, reason: "empty-transcript" });
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

    const context = await this.buildContext(request);
    // Article's prompt and demonstrations, plus an addendum with only the dictionary
    // and the text around the cursor (already redacted by buildContext).
    const system = systemPromptFor({
      dictionary: this.dictionary,
      fieldContext: context.fieldContext ?? null,
      strength,
    });
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
      const detail = this.redactDetail(failureDetail(error));
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
      const spoken = await this.transcribe(audio);
      const polished = await this.polish({
        rawText: spoken.text,
        appHint: request.appHint,
        strength: request.strength,
        fieldContext: request.fieldContext ?? null,
        llm: request.llm ?? null,
        signal: request.signal,
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
  async transcribe(audio) {
    const started = Date.now();
    const spoken = await this.recognizer.transcribe(audio);
    return { text: String(spoken.text ?? "").trim(), ms: Date.now() - started };
  }

  /** Assemble bounded, redacted context for one call. */
  async buildContext(request) {
    const redact = this.config.redactSecrets !== false;
    return {
      dictionary: [...this.dictionary],
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
