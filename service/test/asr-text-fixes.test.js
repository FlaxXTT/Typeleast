import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { relevantAliases } from "../lib/term-hints.js";
import { cleanupSystemPrompt } from "../lib/prompts/cleanup.js";
import { JSON_OUTPUT, UTTERANCE_RULES } from "../lib/utterance-rules.js";

test("new pack hints apply only in their context", () => {
  const pack = JSON.parse(readFileSync(new URL("../lib/bundled/typeleast.tech-terms.typeleast-plugin", import.meta.url), "utf8"));
  const terms = (text) => relevantAliases(pack.aliases, text).map((a) => a.term);
  assert.deepEqual(terms("link the Figma file and the jar board"), ["Jira"]);
  assert.deepEqual(terms("把 jar 包打包上传到 maven"), []);
  assert.deepEqual(terms("修复 codecs 官方 Chrome 插件的问题"), ["Codex"]);
  assert.deepEqual(terms("视频的 codecs 不支持"), []);
});

test("the prompt states the task, the fidelity boundary and the language", () => {
  const prompt = cleanupSystemPrompt() + UTTERANCE_RULES + JSON_OUTPUT;
  for (const rule of ["纠正识别错误", "改口", "沿用口述的语言", "专有名称", "照写"]) assert.ok(prompt.includes(rule), rule);
});
