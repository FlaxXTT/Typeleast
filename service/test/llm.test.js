import test from "node:test";
import assert from "node:assert/strict";
import { createDeadline, failureDetail, failureReason, ModelCallError } from "../lib/llm.js";

test("each failure kind maps to the reason history reports", () => {
  const cases = [
    [new ModelCallError("timeout", "t"), "model-timeout"],
    [new ModelCallError("cancelled", "c"), "cancelled"],
    [new ModelCallError("max-tokens", "m"), "model-max-tokens"],
    [new ModelCallError("tool-calls", "x"), "model-tool-calls"],
    [new ModelCallError("error", "e", { code: "HTTP_401" }), "model-error:HTTP_401"],
    [new ModelCallError("error", "e", { code: "NETWORK" }), "model-error:NETWORK"],
    [new ModelCallError("error", "e"), "model-error:unknown"],
  ];
  for (const [error, reason] of cases) assert.equal(failureReason(error), reason, error.kind);
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

test("a deadline follows the caller's cancellation", () => {
  const controller = new AbortController();
  const deadline = createDeadline(controller.signal, 60000);
  assert.equal(deadline.signal.aborted, false);
  controller.abort(new Error("caller went away"));
  assert.equal(deadline.signal.aborted, true);
  assert.equal(deadline.timedOut(), false);
  deadline.dispose();
});

test("an already-aborted caller aborts the call immediately", () => {
  const controller = new AbortController();
  controller.abort(new Error("caller went away"));
  const deadline = createDeadline(controller.signal, 60000);
  assert.equal(deadline.signal.aborted, true);
  assert.equal(deadline.timedOut(), false);
  deadline.dispose();
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

test("a detail names the cause chain once", () => {
  const cause = Object.assign(new Error("connect ECONNRESET"), { code: "ECONNRESET" });
  const wrapped = new TypeError("fetch failed", { cause });
  assert.equal(failureDetail(wrapped), "fetch failed: connect ECONNRESET");
  assert.equal(failureReason(wrapped), "model-error:ECONNRESET");
});
