import test from "node:test";
import assert from "node:assert/strict";
import { conversationContext, dictationContext, redactSecrets, resolveSession } from "../lib/context.js";

test("key-shaped strings are redacted before anything is sent to a provider", () => {
  const out = redactSecrets('key sk-abcdefghijklmnop and token ghp_abcdefghijklmnop and api_key = "hunter2"');
  assert.ok(!out.includes("sk-abcdefghijklmnop"));
  assert.ok(!out.includes("ghp_abcdefghijklmnop"));
  assert.ok(!out.includes("hunter2"));
  assert.match(out, /\[redacted-key\]/);
});

test("bearer headers are redacted", () => {
  assert.match(redactSecrets("Authorization: Bearer abcdefghijklmnop.qrstuv"), /Bearer \[redacted\]/);
});

test("credentials are redacted in the forms people actually dictate", () => {
  // A password is normally spoken as prose, not as key=value, and this is the
  // text that would otherwise be forwarded verbatim to a model provider.
  const spoken = [
    "my password is hunter2",
    "the password for the wifi is swordfish",
    "the api key is sk-live-abcdefghijklmnopqrst",
    "set the token to ghp_abcdefghijklmnopqrstuv",
    "password: hunter2",
    'the secret is "opensesame"',
    "the passcode is 556677",
  ];
  for (const text of spoken) {
    const out = redactSecrets(text);
    assert.ok(out.includes("[redacted"), text + " -> " + out);
    assert.ok(!/hunter2|swordfish|opensesame|556677|sk-live-abcdefghijklmnopqrst|ghp_abcdefghijklmnopqrstuv/.test(out), text + " -> " + out);
  }
});

test("ordinary speech about passwords and keys is left alone", () => {
  // Over-redacting would silently corrupt what the user said, so a keyword with
  // no value after it must survive untouched.
  const innocent = [
    "the password field is on the left",
    "i forgot my password again",
    "we should rotate the api key before the release",
    "the token bucket refills every minute",
  ];
  for (const text of innocent) {
    const out = redactSecrets(text);
    assert.ok(!out.includes("[redacted"), text + " -> " + out);
    assert.equal(out, text);
  }
});

test("conversation context keeps only text turns, newest last, inside the budget", () => {
  const session = {
    deriveMessages: () => [
      { role: "user", content: [{ type: "text", text: "first turn" }] },
      { role: "assistant", content: [{ type: "text", text: "first answer" }] },
      { role: "user", content: [{ type: "tool-call", id: "1", name: "bash", arguments: "{}" }] },
      { role: "user", content: [{ type: "text", text: "second turn" }] },
    ],
  };
  const ctx = { sessions: { get: () => session } };
  const turns = conversationContext({ ctx, sessionId: "s1", turns: 2, charBudget: 1000, redact: true });
  assert.deepEqual(turns.map((t) => t.text), ["first answer", "second turn"]);
});

test("a missing session yields no context instead of throwing", () => {
  assert.deepEqual(conversationContext({ ctx: {}, sessionId: "nope", turns: 3, charBudget: 100, redact: true }), []);
  assert.equal(resolveSession({}, undefined), null);
});

test("a session that cannot enumerate messages is treated as empty", () => {
  const ctx = { sessions: { get: () => ({ deriveMessages: () => { throw new Error("gone"); } }) } };
  assert.deepEqual(conversationContext({ ctx, sessionId: "s", turns: 2, charBudget: 100, redact: false }), []);
});

test("dictation context pairs each transcript with what was inserted, preserving caller order", () => {
  // History.recent() supplies newest-first and the prompt presents it that way,
  // so the function must not silently reorder anything.
  const entries = [
    { raw: "sounds good", text: "Sounds good." },
    { raw: "send it tuesday no wednesday", text: "Send it Wednesday." },
  ];
  assert.deepEqual(dictationContext(entries, { redact: false, maxEntries: 5 }), [
    { raw: "sounds good", cleaned: "Sounds good." },
    { raw: "send it tuesday no wednesday", cleaned: "Send it Wednesday." },
  ]);
  assert.deepEqual(dictationContext([entries[1]], { redact: false }), [
    { raw: "send it tuesday no wednesday", cleaned: "Send it Wednesday." },
  ]);
});

test("dictation context keeps the most recent pairs when the budget is tight", () => {
  const entries = [
    { raw: "newest", text: "N" },
    { raw: "middle", text: "M" },
    { raw: "oldest", text: "O" },
  ];
  assert.equal(dictationContext(entries, { redact: false, maxEntries: 1 }).length, 1);
  assert.deepEqual(dictationContext(entries, { redact: false, maxEntries: 1 }).map((pair) => pair.raw), ["newest"]);
  // A budget too small for everything drops the tail (oldest) rather than
  // throwing. Each pair costs raw+cleaned = 6+1 characters, so three pairs cost
  // 21 and a budget of 20 leaves exactly two.
  const trimmed = dictationContext(entries, { redact: false, maxChars: 20 });
  assert.deepEqual(trimmed.map((pair) => pair.raw), ["newest", "middle"]);
  // One pair is always kept, however tight the budget.
  assert.equal(dictationContext(entries, { redact: false, maxChars: 1 }).length, 1);
});

test("dictation context drops entries with no transcript and honours the budget", () => {
  const entries = [{ raw: "", text: "ignored" }, { raw: "x".repeat(50), text: "y".repeat(50) }, { raw: "older", text: "ancient" }];
  const pairs = dictationContext(entries, { redact: false, maxEntries: 10, maxChars: 120 });
  assert.ok(pairs.length >= 1);
  assert.ok(pairs.every((pair) => pair.raw.length > 0));
});
test("field context header is base64 JSON, bounded, and dropped when malformed", async () => {
  const { parseFieldContext, normalizeFieldContext, redactFieldContext, wantsConversation, FIELD_CONTEXT_LIMITS } = await import("../lib/context.js");
  const header = Buffer.from(JSON.stringify({ before: "x".repeat(2000) + "END", selected: "sel", after: "after", windowTitle: "Title" })).toString("base64");
  const parsed = parseFieldContext(header);
  assert.equal(parsed.before.length, FIELD_CONTEXT_LIMITS.before);
  assert.ok(parsed.before.endsWith("END"), "the text nearest the cursor survives");
  assert.equal(parsed.windowTitle, "Title");
  assert.equal(parseFieldContext("%%%not-base64"), null);
  assert.equal(parseFieldContext(Buffer.from("[1,2]").toString("base64")), null);
  assert.equal(parseFieldContext(undefined), null);
  assert.equal(normalizeFieldContext({ before: "  ", after: 7 }), null, "no text means no context");
  assert.equal(redactFieldContext({ before: "password is hunter2", selected: "", after: "", windowTitle: "" }, true).before, "password is [redacted]");
  assert.equal(wantsConversation("com.deepseek.dsh"), true);
  assert.equal(wantsConversation(null), true);
  assert.equal(wantsConversation("com.apple.mail"), false);
});
