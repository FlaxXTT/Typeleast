import test from "node:test";
import assert from "node:assert/strict";
import { redactSecrets } from "../lib/context.js";

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

test("field context header is base64 JSON, bounded, and dropped when malformed", async () => {
  const { parseFieldContext, normalizeFieldContext, redactFieldContext, FIELD_CONTEXT_LIMITS } = await import("../lib/context.js");
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
});
