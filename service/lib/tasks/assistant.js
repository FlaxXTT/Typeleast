/**
 * Prompt mode (assistant): a multi-round clarification kept in memory until the user generates
 * the prompt or cancels. The context is the one described in tasks/dictation.js.
 *
 * @module typeleast-service/tasks/assistant
 */
import { randomUUID } from "node:crypto";
import { cleanupParameters } from "../cleanup-task.js";
import { failureReason, ModelCallError } from "../llm.js";
import {
  BETA_BREAKDOWN_PROMPT, BETA_DRAFT_PROMPT, BETA_INTERVIEW_PROMPT, BETA_LIMITS,
  boundaryQuestions, cleanPromptReply, draftMessage, hasContent, interviewMessage, normaliseQuestions, parseJsonReply,
} from "../prompts/prompt-beta.js";
import { unwrap } from "../validate.js";
import { timing } from "./timing.js";

/** The open clarifications: id -> { request, baseline, turns, questions, confirmed, goals, spec, created, busy }. */
export class AssistantSessions {
  constructor() {
    this.map = new Map();
  }

  /** Drop expired sessions and keep the map bounded. */
  prune(now = Date.now()) {
    for (const [id, session] of this.map) {
      if (!session.busy && now - session.created > BETA_LIMITS.sessionMs) this.map.delete(id);
    }
    while (this.map.size > BETA_LIMITS.sessions) {
      const idle = [...this.map].find(([, session]) => !session.busy);
      if (!idle) break;
      this.map.delete(idle[0]);
    }
  }

  /** Forget a session the user cancelled, stopping its model call. */
  cancel(sessionId) {
    const id = String(sessionId ?? "");
    this.map.get(id)?.controller?.abort();
    return this.map.delete(id);
  }

  /** One round: ask (or re-ask) questions, or with `skip` write the final prompt. */
  async run(ctx, skip) {
    const { request, base, started, config } = ctx;
    let rawText = ctx.rawText;
    const call = async (system, user, maxTokens = 1800) => {
      const result = await ctx.complete({ system, user: ctx.redact(user), maxTokens, temperature: 0.2,
        timeoutMs: Math.max(config.timeoutMs, 60000), signal: AbortSignal.any([request.signal, session.controller.signal].filter(Boolean)) });
      request.signal?.throwIfAborted();
      return result.text;
    };
    this.prune();
    // The draft: text selected when 提示词模式 started. The older form sends it as the text itself.
    let baseline = typeof request.baseline === "string" ? request.baseline.trim() : "";
    if (!baseline && request.source === "selection") { baseline = rawText; rawText = ""; }
    const id = request.betaSession || randomUUID();
    let session = this.map.get(id);
    if (request.betaSession && !session) throw Object.assign(new Error("clarification expired"), { code: "beta-expired" });
    if (session?.busy) throw Object.assign(new Error("clarification in progress"), { code: "model-busy" });
    if (!session && !hasContent(rawText) && !hasContent(baseline)) {
      return { ...base, raw: "", text: "", fallback: true, reason: "empty-transcript" };
    }
    if (!session) {
      if (rawText.length + baseline.length > BETA_LIMITS.inputChars) throw Object.assign(new Error("request too long"), { code: "invalid-prompt" });
      // Do not evict another user's active operation to admit a new one.
      if (this.map.size >= BETA_LIMITS.sessions) throw Object.assign(new Error("too many clarifications"), { code: "busy" });
      session = { request: hasContent(rawText) ? rawText : "", baseline, turns: [], questions: [], confirmed: [], goals: [], selection: Boolean(baseline), created: Date.now(), ready: false };
      this.map.set(id, session);
    }
    const pending = notice => ({ ...base, text: "", raw: rawText,
      beta: { sessionId: id, questions: session.questions, confirmed: session.confirmed, goals: session.goals ?? [],
        round: session.turns.length + 1, ready: session.ready, ...(notice ? { notice } : {}) }, ms: timing(started, 0) });
    if (request.betaSession && !skip && !hasContent(rawText)) return pending("empty-transcript");
    const turns = [...session.turns];
    // 生成 may carry answers chosen in the panel but not sent yet.
    if (request.betaSession && (!skip || hasContent(rawText))) turns.push({ questions: [...session.questions], answer: rawText });
    const source = [session.baseline ?? "", session.request, ...turns.map(t => t.answer)].join("\n");
    if (source.length > BETA_LIMITS.inputChars) return pending("beta-input-limit");
    session.busy = true;
    session.created = Date.now();
    session.controller = new AbortController();
    try {
      if (!skip) {
        const reply = parseJsonReply(await call(session.selection ? BETA_BREAKDOWN_PROMPT : BETA_INTERVIEW_PROMPT, interviewMessage(session.request, turns, session.baseline)));
        if (!reply || !Array.isArray(reply.questions) || !Array.isArray(reply.confirmed)) {
          throw Object.assign(new Error("invalid clarification"), { code: "output-format" });
        }
        if (this.map.get(id) !== session) throw new DOMException("Cancelled", "AbortError");
        const modelQuestions = normaliseQuestions(reply.questions);
        if (reply.questions.length && !modelQuestions.length) throw Object.assign(new Error("invalid questions"), { code: "output-format" });
        // The task's boundaries come first: what may be read or searched, and creative or routine work.
        const questions = normaliseQuestions([...boundaryQuestions(session.request, turns, session.baseline), ...modelQuestions]);
        session.turns = turns;
        session.spec = { goal: typeof reply.goal === "string" ? reply.goal.slice(0, 500) : "" };
        session.confirmed = reply.confirmed.filter(x => typeof x === "string").map(x => x.trim().slice(0, 240)).filter(Boolean).slice(0, session.selection ? 8 : 6);
        if (Array.isArray(reply.goals)) session.goals = reply.goals.filter(x => typeof x === "string").map(x => x.trim().slice(0, 200)).filter(Boolean).slice(0, 5);
        session.questions = questions;
        session.ready = session.questions.length === 0;
        session.created = Date.now();
        return pending();
      }
      const material = { baseline: session.baseline, request: session.request, spec: session.spec, turns,
        questions: session.questions, skipped: true };
      const draft = cleanPromptReply(await call(BETA_DRAFT_PROMPT, draftMessage(material), cleanupParameters(source, "prompt", config).maxTokens));
      if (!draft) throw Object.assign(new Error("empty draft"), { code: "output-format" });
      if (this.map.get(id) !== session) throw new DOMException("Cancelled", "AbortError");
      request.signal?.throwIfAborted();
      const result = await ctx.done({ ...base, raw: source, text: unwrap(draft).text.trim(),
        ms: timing(started, 0), beta: { reviewed: false, issues: 0, patched: false } });
      this.map.delete(id);
      return result;
    } catch (error) {
      // Never insert a partial draft or lose accepted answers after a failed round.
      if (request.signal?.aborted || this.map.get(id) !== session) throw error;
      const notice = error.code === "beta-validation" ? "beta-validation" : error instanceof ModelCallError ? failureReason(error) : "output-format";
      return pending(notice);
    } finally {
      session.busy = false;
    }
  }
}
