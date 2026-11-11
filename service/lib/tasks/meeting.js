/**
 * Meeting transcription: one recording goes through MOSS-Transcribe-Diarize in one pass, and the
 * speaker labels and times are kept. It runs as a background job because a long recording takes
 * minutes: the app uploads the audio, polls the status and reads the result.
 *
 * Meetings use their own engine process whichever model dictation is set to, outside the
 * dictation queue, so dictation keeps working while a meeting is transcribed.
 *
 * Labels (S01, S02…) are relative to one recording, in order of appearance.
 *
 * @module typeleast-service/tasks/meeting
 */
import { randomUUID } from "node:crypto";
import { BYTES_PER_SECOND, validateWav, WAV_HEADER_BYTES } from "../wav.js";

/**
 * Longest recording accepted: the longest measured to finish. One pass slows down faster than the
 * recording grows, because every generated token attends to all the audio and text before it.
 * On an M5 Pro: 5 min took 47 s, 10 min took 271 s, and 20 min had not finished after 45 min.
 */
export const MAX_MEETING_SECONDS = 10 * 60;
// Includes model preparation and transcription; a stuck engine must release the job.
export const MAX_MEETING_PROCESSING_MS = 20 * 60_000;
export const MAX_MEETING_BYTES = WAV_HEADER_BYTES + MAX_MEETING_SECONDS * BYTES_PER_SECOND;
// A cancellation may arrive while the matching request is still uploading audio. Retain its ID
// longer than the client's maximum upload time, without retaining audio or an unbounded list.
export const MEETING_CANCEL_TTL_MS = 180_000;
export const MAX_CANCEL_TOMBSTONES = 256;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

/** Generated tokens allowed per second of audio; the engine reserves its cache for all of them. */
const TOKENS_PER_SECOND = 15;

export const meetingTokenBudget = (seconds) => Math.max(2048, Math.ceil(seconds * TOKENS_PER_SECOND));

const failure = (code, message) => Object.assign(new Error(message), { code });

export class MeetingJobs {
  /** @param {object} options - recognizer: async () => a ready MossRecognizer; logger. */
  constructor(options) {
    this.recognizer = options.recognizer;
    this.logger = options.logger ?? { warn: () => {} };
    this.now = options.now ?? Date.now;
    this.processingTimeoutMs = options.processingTimeoutMs ?? MAX_MEETING_PROCESSING_MS;
    this.cancelledIds = new Map();
    /** The current or last job. Its transcript stays in memory only, until the app forgets it. */
    this.job = null;
  }

  /** Accept one recording and start in the background. @returns {string} the job's id. */
  start({ audio, language = "auto", requestId }) {
    if (requestId !== undefined && (typeof requestId !== "string" || !UUID.test(requestId))) throw failure("invalid-meeting-id", "the meeting request ID must be a UUID");
    const id = requestId === undefined ? randomUUID() : requestId.toLowerCase();
    this.pruneCancellations();
    if (this.cancelledIds.has(id)) throw failure("meeting-cancelled", "this meeting request was cancelled");
    // Retrying the same request after losing the HTTP response must not start a second engine.
    // A caller must use a fresh ID for different audio.
    if (this.job?.id === id) return id;
    if (this.job && ["preparing", "transcribing"].includes(this.job.phase)) throw failure("busy", "a meeting is already being transcribed");
    const { durationSeconds } = validateWav(audio, MAX_MEETING_SECONDS);
    const job = { id, phase: "preparing", seconds: durationSeconds, startedAt: Date.now(), elapsedMs: null, code: null, result: null, controller: new AbortController() };
    this.job = job;
    void this.run(job, audio, language);
    return job.id;
  }

  async run(job, audio, language) {
    const { signal } = job.controller;
    let timedOut = false;
    const timer = setTimeout(() => {
      timedOut = true;
      job.controller.abort(failure("meeting-timeout", "meeting processing timed out"));
    }, this.processingTimeoutMs);
    let abort;
    const cancelled = new Promise((_, reject) => {
      abort = () => reject(signal.reason);
      signal.addEventListener("abort", abort, { once: true });
      if (signal.aborted) abort();
    });
    try {
      const engine = await Promise.race([this.recognizer(), cancelled]);
      signal.throwIfAborted();
      job.phase = "transcribing";
      const spoken = await Promise.race([engine.transcribe(audio, language, signal, { maxNew: meetingTokenBudget(job.seconds) }), cancelled]);
      signal.throwIfAborted();
      const segments = spoken.segments ?? [];
      job.result = {
        segments,
        speakers: spoken.speakers ?? [],
        text: spoken.text ?? "",
        detectedLanguage: spoken.detectedLanguage ?? null,
        // The engine ran out of its token budget in the middle of a turn: the end is missing.
        truncated: segments.length > 0 && segments[segments.length - 1].end === null,
      };
      job.phase = "done";
    } catch (error) {
      if (timedOut) { job.phase = "failed"; job.code = "meeting-timeout"; }
      else if (signal.aborted) job.phase = "cancelled";
      else {
        job.phase = "failed";
        job.code = error?.code ?? "meeting-failed";
        this.logger.warn?.("typeleast: meeting transcription failed (%s)", job.code);
      }
    } finally {
      clearTimeout(timer);
      signal.removeEventListener("abort", abort);
      job.elapsedMs = Date.now() - job.startedAt;
    }
  }

  status(id) {
    if (typeof id === "string" && UUID.test(id)) id = id.toLowerCase();
    const job = this.job;
    if (!job || job.id !== id) throw failure("meeting-not-found", "no such meeting job");
    return {
      id: job.id, phase: job.phase, seconds: job.seconds,
      elapsedMs: job.elapsedMs ?? Date.now() - job.startedAt,
      ...(job.code ? { code: job.code } : {}),
      ...(job.result ? { result: job.result } : {}),
    };
  }

  pruneCancellations() {
    const now = this.now();
    for (const [id, expires] of this.cancelledIds) {
      if (expires <= now) this.cancelledIds.delete(id);
    }
  }

  /** Stop the engine if it is running, and drop the job with its transcript. */
  cancel(id) {
    if (id !== undefined && typeof id === "string" && UUID.test(id)) {
      id = id.toLowerCase();
      this.pruneCancellations();
      // Re-insertion keeps the oldest cancellation at the front for bounded eviction.
      this.cancelledIds.delete(id);
      this.cancelledIds.set(id, this.now() + MEETING_CANCEL_TTL_MS);
      while (this.cancelledIds.size > MAX_CANCEL_TOMBSTONES) this.cancelledIds.delete(this.cancelledIds.keys().next().value);
    }
    const job = this.job;
    if (!job || (id !== undefined && job.id !== id)) return false;
    job.controller.abort(failure("cancelled", "cancelled"));
    this.job = null;
    return true;
  }
}
