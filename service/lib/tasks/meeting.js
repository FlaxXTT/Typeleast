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
export const MAX_MEETING_BYTES = WAV_HEADER_BYTES + MAX_MEETING_SECONDS * BYTES_PER_SECOND;

/** Generated tokens allowed per second of audio; the engine reserves its cache for all of them. */
const TOKENS_PER_SECOND = 15;

export const meetingTokenBudget = (seconds) => Math.max(2048, Math.ceil(seconds * TOKENS_PER_SECOND));

const failure = (code, message) => Object.assign(new Error(message), { code });

export class MeetingJobs {
  /** @param {object} options - recognizer: async () => a ready MossRecognizer; logger. */
  constructor(options) {
    this.recognizer = options.recognizer;
    this.logger = options.logger ?? { warn: () => {} };
    /** The current or last job. Its transcript stays in memory only, until the app forgets it. */
    this.job = null;
  }

  /** Accept one recording and start in the background. @returns {string} the job's id. */
  start({ audio, language = "auto" }) {
    if (this.job && ["preparing", "transcribing"].includes(this.job.phase)) throw failure("busy", "a meeting is already being transcribed");
    const { durationSeconds } = validateWav(audio, MAX_MEETING_SECONDS);
    const job = { id: randomUUID(), phase: "preparing", seconds: durationSeconds, startedAt: Date.now(), elapsedMs: null, code: null, result: null, controller: new AbortController() };
    this.job = job;
    void this.run(job, audio, language);
    return job.id;
  }

  async run(job, audio, language) {
    const { signal } = job.controller;
    try {
      const engine = await this.recognizer();
      signal.throwIfAborted();
      job.phase = "transcribing";
      const spoken = await engine.transcribe(audio, language, signal, { maxNew: meetingTokenBudget(job.seconds) });
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
      if (signal.aborted) job.phase = "cancelled";
      else {
        job.phase = "failed";
        job.code = error?.code ?? "meeting-failed";
        this.logger.warn?.("typeleast: meeting transcription failed (%s)", job.code);
      }
    } finally {
      job.elapsedMs = Date.now() - job.startedAt;
    }
  }

  status(id) {
    const job = this.job;
    if (!job || job.id !== id) throw failure("meeting-not-found", "no such meeting job");
    return {
      id: job.id, phase: job.phase, seconds: job.seconds,
      elapsedMs: job.elapsedMs ?? Date.now() - job.startedAt,
      ...(job.code ? { code: job.code } : {}),
      ...(job.result ? { result: job.result } : {}),
    };
  }

  /** Stop the engine if it is running, and drop the job with its transcript. */
  cancel(id) {
    const job = this.job;
    if (!job || (id !== undefined && job.id !== id)) return false;
    job.controller.abort(failure("cancelled", "cancelled"));
    this.job = null;
    return true;
  }
}
