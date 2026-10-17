import test from "node:test";
import assert from "node:assert/strict";
import {
  collectStreamText,
  completeText,
  createDeadline,
  createUserTextMessage,
  failureDetail,
  failureReason,
  finishError,
  isRetryable,
  ModelCallError,
  resolveRoute,
} from "../lib/llm.js";

async function* streamOf(chunks) {
  for (const chunk of chunks) yield chunk;
}

test("the request message matches the shape the shipped adapter reads", () => {
  assert.deepEqual(createUserTextMessage("hi"), { role: "user", content: [{ type: "text", text: "hi" }] });
});

test("chunks fold into text and terminal facts", async () => {
  const result = await collectStreamText(
    streamOf([
      { type: "block-start", index: 0, blockType: "text" },
      { type: "text-delta", index: 0, text: "Send the " },
      { type: "reasoning-delta", index: 1, text: "ignored" },
      { type: "text-delta", index: 0, text: "report." },
      { type: "usage", usage: { inputTokens: 10, outputTokens: 4 } },
      { type: "finish", reason: { kind: "stop" } },
    ]),
    undefined,
  );
  assert.equal(result.text, "Send the report.");
  assert.equal(result.usage.outputTokens, 4);
  assert.equal(result.finish.kind, "stop");
});

test("a provider that emits only a completed block still yields text", async () => {
  const result = await collectStreamText(streamOf([{ type: "block-end", index: 0, block: { type: "text", text: "done" } }]), undefined);
  assert.equal(result.text, "done");
});

test("finish reasons map to actionable failures", () => {
  assert.equal(finishError({ kind: "stop" }), null);
  assert.match(finishError({ kind: "error", failure: { message: "boom", code: "X" } }).message, /boom/);
  assert.match(finishError({ kind: "max-tokens" }).message, /token limit/);
  assert.match(finishError({ kind: "tool-calls" }).message, /requested a tool/);
  assert.match(finishError({ kind: "weird" }).message, /unsupported finish reason/);
});

test("finish failures carry a kind and code that name the reason", () => {
  const cases = [
    [{ kind: "max-tokens" }, "max-tokens", "model-max-tokens"],
    [{ kind: "tool-calls" }, "tool-calls", "model-tool-calls"],
    [{ kind: "error", failure: { message: "boom", code: "RATE_LIMITED" } }, "error", "model-error:RATE_LIMITED"],
    [{ kind: "error", failure: { message: "boom" } }, "error", "model-error:unknown"],
    [{ kind: "aborted" }, "error", "model-error:aborted"],
    [{ kind: "weird" }, "error", "model-error:finish-weird"],
  ];
  for (const [finish, kind, reason] of cases) {
    const error = finishError(finish);
    assert.ok(error instanceof ModelCallError, JSON.stringify(finish));
    assert.equal(error.kind, kind, JSON.stringify(finish));
    assert.equal(failureReason(error), reason);
  }
  // The provider's own code is what the retry policy reads, so it must survive.
  assert.equal(isRetryable(finishError({ kind: "error", failure: { message: "slow down", code: "RATE_LIMITED" } })), true);
});

test("a deadline aborts on its own and releases its timer", async () => {
  const deadline = createDeadline(undefined, 30);
  await new Promise((resolve) => setTimeout(resolve, 60));
  assert.equal(deadline.signal.aborted, true);
  assert.equal(deadline.timedOut(), true);
  assert.ok(deadline.signal.reason instanceof ModelCallError);
  assert.equal(deadline.signal.reason.kind, "timeout");
  assert.match(deadline.signal.reason.message, /deadline of 30 ms exceeded/);
  deadline.dispose();
});

/** A route whose stream behaves as `body` says, counting calls. */
function scriptedLlm(body) {
  const llm = { calls: 0, stream: (request) => {
    llm.calls += 1;
    return body(request);
  } };
  return llm;
}

const CALL = { provider: "deepseek-account", model: "deepseek-flash", system: "s", user: "u", maxTokens: 10 };

test("completeText forwards reasoningEffort only when the caller names one", async () => {
  const requests = [];
  const llm = scriptedLlm((request) => {
    requests.push(request);
    return streamOf([{ type: "text-delta", index: 0, text: "ok" }, { type: "finish", reason: { kind: "stop" } }]);
  });
  await completeText({ ...CALL, llm, timeoutMs: 60000, reasoningEffort: "off" });
  await completeText({ ...CALL, llm, timeoutMs: 60000 });
  assert.equal(requests[0].reasoningEffort, "off");
  assert.equal("reasoningEffort" in requests[1], false);
});

test("completeText reports its own deadline as a timeout, whatever the adapter threw", async () => {
  const llm = scriptedLlm((request) => (async function* generate() {
    await new Promise((resolve) => request.signal.addEventListener("abort", resolve, { once: true }));
    throw new DOMException("This operation was aborted", "AbortError");
  })());
  const error = await completeText({ ...CALL, llm, timeoutMs: 30 }).catch((caught) => caught);
  assert.ok(error instanceof ModelCallError);
  assert.equal(error.kind, "timeout");
  assert.equal(error.attempts, 1);
  assert.equal(llm.calls, 1, "a timeout is not retried");
  assert.ok(error.elapsedMs >= 25, String(error.elapsedMs));
  assert.equal(failureReason(error), "model-timeout");
  assert.match(failureDetail(error), /^deadline of 30 ms exceeded: This operation was aborted \(\d+ ms\)$/);
});

test("completeText reports a caller abort as cancelled", async () => {
  const controller = new AbortController();
  controller.abort(new Error("client went away"));
  const llm = scriptedLlm(() => streamOf([{ type: "text-delta", index: 0, text: "x" }]));
  const error = await completeText({ ...CALL, llm, timeoutMs: 60000, signal: controller.signal }).catch((caught) => caught);
  assert.equal(error.kind, "cancelled");
  assert.equal(failureReason(error), "cancelled");
});

test("completeText retries a transport failure once and keeps its code", async () => {
  const llm = scriptedLlm(() => {
    throw Object.assign(new Error("read ECONNRESET"), { code: "ECONNRESET" });
  });
  const error = await completeText({ ...CALL, llm, timeoutMs: 60000 }).catch((caught) => caught);
  assert.equal(llm.calls, 2);
  assert.equal(error.kind, "error");
  assert.equal(error.attempts, 2);
  assert.equal(failureReason(error), "model-error:ECONNRESET");
  assert.match(failureDetail(error), /^read ECONNRESET \(2 attempts, \d+ ms\)$/);
});

test("a wrapped transport failure is named by its cause's code", async () => {
  // fetch() reports "fetch failed" and puts the socket error in `cause`. The
  // retry policy reads only the outer error, so this is not retried today.
  const llm = scriptedLlm(() => {
    throw Object.assign(new TypeError("fetch failed"), { cause: Object.assign(new Error("read ECONNRESET"), { code: "ECONNRESET" }) });
  });
  const error = await completeText({ ...CALL, llm, timeoutMs: 60000 }).catch((caught) => caught);
  assert.equal(llm.calls, 1);
  assert.equal(failureReason(error), "model-error:ECONNRESET");
  assert.match(failureDetail(error), /^fetch failed: read ECONNRESET \(\d+ ms\)$/);
});

test("completeText does not retry a protocol failure", async () => {
  const llm = scriptedLlm(() => streamOf([{ type: "finish", reason: { kind: "max-tokens" } }]));
  const error = await completeText({ ...CALL, llm, timeoutMs: 60000 }).catch((caught) => caught);
  assert.equal(llm.calls, 1);
  assert.equal(failureReason(error), "model-max-tokens");
});

test("failure codes are sanitised and details are bounded", () => {
  assert.equal(failureReason(new ModelCallError("error", "x", { code: "bad code/with spaces" })), "model-error:bad-code-with-spaces");
  assert.equal(failureReason(Object.assign(new Error("x"), { status: 429 })), "model-error:http-429");
  assert.equal(failureReason(new Error("plain")), "model-error:unknown");
  const long = new ModelCallError("error", "y".repeat(500), { attempts: 2, elapsedMs: 4712 });
  const detail = failureDetail(long);
  assert.equal(detail.length, 200);
  assert.match(detail, /^y+… \(2 attempts, 4712 ms\)$/, "the attempt facts survive truncation");
});

test("an already-aborted caller aborts the call immediately", () => {
  const controller = new AbortController();
  controller.abort(new Error("caller went away"));
  const deadline = createDeadline(controller.signal, 60000);
  assert.equal(deadline.signal.aborted, true);
  assert.equal(deadline.timedOut(), false);
  deadline.dispose();
});

test("the configured route is preferred, otherwise the first live route wins", () => {
  const llm = { listProviders: () => [{ id: "deepseek-account" }, { id: "openrouter" }] };
  assert.deepEqual(resolveRoute(llm, { provider: "deepseek-account", model: "m" }), { provider: "deepseek-account", model: "m", fallbackRoute: false });
  assert.deepEqual(resolveRoute(llm, { provider: "gone", model: "m" }), { provider: "deepseek-account", model: "m", fallbackRoute: true });
  assert.deepEqual(resolveRoute({ listProviders: () => [] }, { provider: "gone", model: "m" }), { provider: "gone", model: "m", fallbackRoute: true });
});

test("only transport-shaped failures are retried", () => {
  assert.equal(isRetryable(Object.assign(new Error("x"), { code: "RATE_LIMITED" })), true);
  assert.equal(isRetryable(new Error("socket hang up")), true);
  assert.equal(isRetryable(new Error("HTTP 503 from provider")), true);
  assert.equal(isRetryable(new Error("model output hit its token limit")), false);
  assert.equal(isRetryable(new Error("unexpected token")), false);
});
