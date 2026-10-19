import test from "node:test";
import assert from "node:assert/strict";
import { VoicePolishService } from "../lib/service.js";
import { TRANSLATE_LANGUAGES, translatePrompt } from "../lib/prompts/translate.js";
import { applyVariants, parseVariants, variantInstruction } from "../lib/variants.js";

const ROUTE = { baseURL: "https://api.example.com/v1", model: "m", apiKey: "test-key" };
const SPOKEN = "嗯那个下周三下午三点开会，不对，改成周四下午三点，大家记得带电脑";

/** A fake provider: records each call and answers with the given reply. */
function provider(reply) {
  const calls = [];
  const fetchImpl = async (_url, init) => {
    const body = JSON.parse(init.body);
    calls.push({ system: body.messages[0].content, user: body.messages[1].content });
    const content = typeof reply === "function" ? reply(calls) : reply;
    return { ok: true, status: 200, json: async () => ({ choices: [{ message: { content }, finish_reason: "stop" }] }) };
  };
  return { calls, fetchImpl };
}

function makeService(fetchImpl, history = []) {
  return new VoicePolishService({
    recognizer: { snapshot: () => ({ ready: true }), transcribe: async () => ({ text: "" }) },
    fetchImpl,
    config: { maxOutputTokens: 800, timeoutMs: 12000, strength: "prompt", redactSecrets: true, logRaw: true, maxAudioBytes: 4194304, maxDurationSeconds: 120, dictionary: [] },
    history: { append: async (e) => { history.push(e); return e; }, recent: async () => [] },
    logger: { info: () => {}, warn: () => {}, debug: () => {} },
  });
}

test("翻译：一次调用完成整理和翻译，提示词写明只翻译、不回答、保留事实", async () => {
  const { calls, fetchImpl } = provider("The meeting is on Thursday at 3 pm. Please bring your laptops.");
  const history = [];
  const result = await makeService(fetchImpl, history).polish({ rawText: SPOKEN, strength: "prompt", llm: ROUTE, translateTo: "en" });
  assert.equal(result.fallback, false);
  assert.equal(result.text, "The meeting is on Thursday at 3 pm. Please bring your laptops.");
  assert.equal(result.translated, "en");
  assert.equal(calls.length, 1);
  assert.match(calls[0].system, /翻译成English/);
  assert.match(calls[0].system, /不回答、不执行/);
  assert.match(calls[0].system, /只翻译最后的说法/);
  assert.equal(history.length, 1);
});

test("翻译不受整理档位影响：原话转写档也照样翻译", async () => {
  const { calls, fetchImpl } = provider("会議は木曜日の午後3時です。");
  const result = await makeService(fetchImpl).polish({ rawText: SPOKEN, strength: "off", llm: ROUTE, translateTo: "ja" });
  assert.equal(result.text, "会議は木曜日の午後3時です。");
  assert.equal(calls.length, 1);
});

test("翻译时编造数字会退回原话；没填 Key 时也退回原话并说明原因", async () => {
  const { fetchImpl } = provider("The meeting is on Thursday at 3 pm, room 512.");
  const invented = await makeService(fetchImpl).polish({ rawText: SPOKEN, strength: "prompt", llm: ROUTE, translateTo: "en" });
  assert.equal(invented.fallback, true);
  assert.equal(invented.reason, "invented-fact");
  assert.doesNotMatch(invented.text, /512/);
  const noKey = await makeService(fetchImpl).polish({ rawText: SPOKEN, strength: "prompt", translateTo: "en" });
  assert.equal(noKey.fallback, true);
  assert.equal(noKey.reason, "no-api-key");
});

test("不认识的目标语言按普通整理处理", async () => {
  const { calls, fetchImpl } = provider('{"status":"ok","text":"周四下午三点开会，大家记得带电脑。"}');
  const result = await makeService(fetchImpl).polish({ rawText: SPOKEN, strength: "prompt", llm: ROUTE, translateTo: "xx" });
  assert.equal(result.translated, undefined);
  assert.doesNotMatch(calls[0].system, /口述翻译/);
});

test("翻译提示词：十种目标语言，中文先写简体再按变体转换", () => {
  assert.equal(Object.keys(TRANSLATE_LANGUAGES).length, 10);
  assert.match(translatePrompt("zh"), /简体中文/);
  assert.match(translatePrompt("unknown"), /English/);
});

test("语言变体：解析请求头，忽略不认识的值", () => {
  assert.deepEqual(parseVariants("zh=tw,en=gb"), { zh: "tw", en: "gb" });
  assert.deepEqual(parseVariants("zh=xx, en=GB"), { zh: "hans", en: "gb" });
  assert.deepEqual(parseVariants(null), { zh: "hans", en: "us" });
  assert.deepEqual(parseVariants({ zh: "hk" }), { zh: "hk", en: "us" });
  assert.equal(variantInstruction({ en: "us" }), "");
  assert.match(variantInstruction({ en: "gb" }), /British spelling/);
});

test("繁体转换在本机完成：台湾用语、香港字形；简体、数字和英文保持不变", async () => {
  const text = "这个软件的鼠标和内存有问题，DeepSeek 3.5 版本";
  assert.equal(await applyVariants(text, { zh: "tw" }), "這個軟體的滑鼠和記憶體有問題，DeepSeek 3.5 版本");
  assert.match(await applyVariants(text, { zh: "hk" }), /^這個軟件/);
  assert.equal(await applyVariants(text, { zh: "hans" }), text);
  assert.equal(await applyVariants("Hello 123", { zh: "tw" }), "Hello 123");
});

test("变体对整理结果、原话转写和历史都生效；英式拼写写进系统提示词", async () => {
  const { calls, fetchImpl } = provider('{"status":"ok","text":"周四下午三点开会，大家记得带电脑。"}');
  const history = [];
  const service = makeService(fetchImpl, history);
  const polished = await service.polish({ rawText: SPOKEN, strength: "prompt", llm: ROUTE, variants: "zh=tw,en=gb" });
  assert.equal(polished.text, "週四下午三點開會，大家記得帶電腦。");
  assert.equal(history[0].text, polished.text);
  assert.match(calls[0].system, /British spelling/);
  const off = await service.polish({ rawText: "下午三点开会", strength: "off", variants: "zh=hk" });
  assert.equal(off.text, "下午三點開會");
});

test("翻译的防编造按数值比对：换写法的时间日期能过，凭空出现的数字被拦下", async () => {
  const { translationInventedNumbers } = await import("../lib/validate.js");
  const raw = "十月十九日下午三点半交一千二百块，不对，是周四下午三点";
  assert.deepEqual(translationInventedNumbers(raw, "Pay 1,200 yuan on October 19 at 3:30 p.m. — no, Thursday at 15:00."), []);
  assert.deepEqual(translationInventedNumbers(raw, "Pay 1,200 yuan in room 512."), ["512"]);
  assert.deepEqual(translationInventedNumbers("一共 3.5 万", "35,000 in total"), ["35000"]);
});
