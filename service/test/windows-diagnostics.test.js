import test from "node:test";
import assert from "node:assert/strict";
import { VoicePolishService } from "../lib/service.js";
import { completeOpenAI, normalizeRoute } from "../lib/openai-compat.js";

const route = normalizeRoute({ baseURL: "https://provider.example/v1", model: "synthetic", apiKey: "fake-key-not-a-secret" });
const raw = "Send the report on Wednesday with the three documents.";
const reply = (content, finish = "stop") => ({ ok: true, status: 200,
  json: async () => ({ choices: [{ message: { content }, finish_reason: finish }] }) });

for (const scenario of ["timeout", "length", "format", "validation", "auth", "network"]) {
  test(`successful ping does not prove dictation success: ${scenario}`, async () => {
    const budgets = [];
    const fetchImpl = async (_url, init) => {
      const body = JSON.parse(init.body);
      budgets.push(body.max_tokens);
      if (body.messages.at(-1).content === "ping") return reply("OK");
      if (scenario === "timeout") {
        await new Promise(resolve => init.signal.addEventListener("abort", resolve, { once: true }));
        throw new DOMException("aborted", "AbortError");
      }
      if (scenario === "auth") return { ok: false, status: 401, body: { cancel: async () => {} } };
      if (scenario === "network") throw new Error("synthetic offline");
      if (scenario === "length") return reply("Send", "length");
      if (scenario === "format") return reply('{"status":"ok","text":"');
      return reply("Send the report on Wednesday with 999 documents.");
    };
    const ping = await completeOpenAI({ route, system: "Reply with exactly: OK", user: "ping", maxTokens: 64, timeoutMs: 20000, fetchImpl });
    assert.equal(ping.text, "OK");
    const service = new VoicePolishService({ config: { timeoutMs: 20, maxOutputTokens: 800, strength: "prompt", redactSecrets: true, dictionary: [] },
      recognizer: { snapshot: () => ({ ready: true }) }, fetchImpl });
    const result = await service.polish({ rawText: raw, strength: "prompt", llm: route });
    assert.equal(result.fallback, true);
    assert.equal(result.text, "");assert.ok(result.raw.includes("Wednesday"));assert.equal(result.clarification.kind,"quality");
    const expected = { timeout: "model-timeout", length: "model-max-tokens", format: "output-format", auth: "model-error:HTTP_401", network: "model-error:NETWORK" };
    if (expected[scenario]) assert.equal(result.reason, expected[scenario]);
    else assert.ok(result.reason && !result.text.includes("999"));
    assert.equal(budgets[0], 64);
    assert.equal(budgets[1], 1800);
    assert.ok(Number.isFinite(result.ms.total));
  });
}
