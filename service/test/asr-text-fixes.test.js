import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { joinSpacedCapitals } from "../lib/tidy.js";
import { relevantAliases } from "../lib/term-hints.js";
import { cleanupSystemPrompt } from "../lib/prompts/cleanup.js";
import { UTTERANCE_RULES } from "../lib/utterance-rules.js";

test("capitals a recogniser spaced out are joined; words are not", () => {
  assert.equal(joinSpacedCapitals("帮我查一下L G那款显示器"), "帮我查一下LG那款显示器");
  assert.equal(joinSpacedCapitals("可用的H T T P或MIXED代理"), "可用的HTTP或MIXED代理");
  assert.equal(joinSpacedCapitals("I am fine, use OAuth"), "I am fine, use OAuth");
});

test("new pack hints apply only in their context", () => {
  const pack = JSON.parse(readFileSync(new URL("../lib/bundled/typeleast.tech-terms.typeleast-plugin", import.meta.url), "utf8"));
  const terms = (text) => relevantAliases(pack.aliases, text).map((a) => a.term);
  assert.deepEqual(terms("link the Figma file and the jar board"), ["Jira"]);
  assert.deepEqual(terms("把 jar 包打包上传到 maven"), []);
  assert.deepEqual(terms("修复 codecs 官方 Chrome 插件的问题"), ["Codex"]);
  assert.deepEqual(terms("视频的 codecs 不支持"), []);
});

test("the prompt keeps explained names, lists parallel items, writes spoken symbols and keeps English", () => {
  const prompt = cleanupSystemPrompt() + UTTERANCE_RULES;
  for (const rule of ["被解释的名称本身保留", "编号列表", "点写 .", "代码块", "结果也用英文"]) assert.ok(prompt.includes(rule), rule);
});
