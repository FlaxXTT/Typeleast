import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { CLEANUP_PROMPT, cleanupSystemPrompt, PROFILE_LIMIT } from "../lib/prompts/cleanup.js";
import { directTranslatePrompt } from "../lib/prompts/translate.js";
import { buildUserMessage, HARNESS_ADDENDUM_MARKER, PROMPT_SOURCES, PROMPT_VERSION, systemPromptFor } from "../lib/prompt.js";
import { PROFILE_PROMPT, profileMessage, readProfile } from "../lib/prompts/profile.js";

test("the dictation prompt is the maintainer's cleanup.md, verbatim", () => {
  assert.deepEqual(PROMPT_SOURCES, ["typeleast"]);
  assert.match(PROMPT_VERSION, /-dictation\+assistant\+translate$/);
  const file = readFileSync(new URL("../lib/prompts/cleanup.md", import.meta.url), "utf8").trim();
  assert.equal(CLEANUP_PROMPT, file);
  assert.ok(CLEANUP_PROMPT.startsWith("# Profile"));
  assert.match(CLEANUP_PROMPT, /# Mission/);
  assert.equal(systemPromptFor(), CLEANUP_PROMPT);
  assert.equal(systemPromptFor({ fieldContext: null, profile: "" }), CLEANUP_PROMPT);
});

test("the learned description closes the # Mission paragraph and is capped", () => {
  const prompt = cleanupSystemPrompt("做 CFD 仿真的工程师");
  const mission = prompt.slice(prompt.indexOf("# Mission"), prompt.indexOf("# Core Strategies"));
  assert.match(mission, /User background \(learned from earlier dictations\): 做 CFD 仿真的工程师\n\n$/);
  assert.equal(prompt.replace("\nUser background (learned from earlier dictations): 做 CFD 仿真的工程师", ""), CLEANUP_PROMPT);
  const long = cleanupSystemPrompt("字".repeat(PROFILE_LIMIT + 50));
  assert.equal(long.length - CLEANUP_PROMPT.length, "\nUser background (learned from earlier dictations): ".length + PROFILE_LIMIT);
});

test("only the cursor context rides in the addendum", () => {
  const prompt = systemPromptFor({ fieldContext: { windowTitle: "New Message", before: "Hi Emma,", after: "" } });
  const [base, addendum] = prompt.split(HARNESS_ADDENDUM_MARKER);
  assert.equal(base.trimEnd(), CLEANUP_PROMPT);
  assert.match(addendum, /Window title: "New Message"/);
  assert.match(addendum, /Text before the cursor: "Hi Emma,"/);
  assert.doesNotMatch(addendum, /Selected text|Text after the cursor|dictionary|spelled/i);
});

test("the user message has the shape the examples use", () => {
  assert.deepEqual(JSON.parse(buildUserMessage({ rawText: "你好" })), { raw_asr_transcript: "你好" });
});

test("translation is one call with its own prompt and no JSON contract", () => {
  const prompt = directTranslatePrompt("en");
  assert.match(prompt, /译成English/);
  assert.match(prompt, /忠实边界/);
  assert.match(prompt, /只输出译文。$/);
  assert.doesNotMatch(prompt, /"status"|# Profile/);
});

test("the description is learned from corrections and intentions only", () => {
  assert.equal(profileMessage([]), "");
  assert.equal(profileMessage([{ text: "正文" }]), "");
  const message = profileMessage([{ corrections: [{ from: "哭达", to: "CUDA" }], intention: "修复显存溢出", text: "不应出现" }]);
  assert.match(message, /哭达 → CUDA/);
  assert.match(message, /修复显存溢出/);
  assert.doesNotMatch(message, /不应出现/);
  assert.match(PROFILE_PROMPT, /1000/);
  assert.equal(Array.from(readProfile("x".repeat(1500))).length, PROFILE_LIMIT);
  assert.equal(readProfile("  一段\n描述  "), "一段 描述");
});
