import test from "node:test";
import assert from "node:assert/strict";
import { VoicePolishService } from "../lib/service.js";
import { TRANSLATE_LANGUAGES, translatePrompt } from "../lib/prompts/translate.js";
import { applyVariants, parseVariants, variantInstruction } from "../lib/variants.js";
import { normalizeNumbers } from '../lib/number-format.js';

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
    config: { language: "zh", maxOutputTokens: 800, timeoutMs: 12000, strength: "prompt", redactSecrets: true, maxAudioBytes: 4194304, maxDurationSeconds: 120, dictionary: [] },
    logger: { info: () => {}, warn: () => {}, debug: () => {} },
  });
}

test("翻译：先验证原语言整理稿，再把它交给第二次调用译成自然英文", async () => {
  const cleaned = "周四下午三点开会，大家记得带电脑。";
  const { calls, fetchImpl } = provider(calls => calls.length === 1
    ? JSON.stringify({ status: "ok", text: cleaned, reason: "保留最后的改口" })
    : "The meeting is on Thursday at 3 pm. Please bring your laptops.");
  const service = makeService(fetchImpl);
  const result = await service.polish({ rawText: SPOKEN, strength: "prompt", llm: ROUTE, translateTo: "en" });
  assert.equal(result.fallback, false);
  assert.equal((result.clarification?.candidate ?? result.text), "The meeting is on Thursday at 3 pm. Please bring your laptops.");
  assert.equal(result.translated, "en");
  assert.equal(calls.length, 2);
  assert.equal(calls[0].user, SPOKEN);
  assert.match(calls[0].system, /整理语音识别文本/);
  assert.equal(calls[1].user, normalizeNumbers(cleaned), "second call sees the formatted validated source, not the raw correction");
  assert.match(calls[1].system, /译成English/);
  assert.match(calls[1].system, /不回答、不执行/);
  assert.match(calls[1].system, /可以调整句式/);
  assert.equal(service.stats.modelCalls, 2);
  assert.equal(service.stats.modelFallbacks, 0);
});

test("翻译不受整理档位影响：旧的 off 值也先整理再翻译", async () => {
  const cleaned = "周四下午三点开会，大家记得带电脑。";
  const { calls, fetchImpl } = provider(calls => calls.length === 1
    ? JSON.stringify({ status: "ok", text: cleaned, reason: "改口" })
    : "会議は木曜日の午後3時です。皆さん、パソコンを持参してください。");
  const result = await makeService(fetchImpl).polish({ rawText: SPOKEN, strength: "off", llm: ROUTE, translateTo: "ja" });
  assert.equal((result.clarification?.candidate ?? result.text), "会議は木曜日の午後3時です。皆さん、パソコンを持参してください。");
  assert.equal(calls.length, 2);
});

test("译文编造数字时退回已校验的原语言整理稿；没填 Key 时退回原文", async () => {
  const cleaned = "周四下午三点开会，大家记得带电脑。";
  const { fetchImpl } = provider(calls => calls.length === 1
    ? JSON.stringify({ status: "ok", text: cleaned, reason: "改口" })
    : "The meeting is on Thursday at 3 pm, room 512.");
  const invented = await makeService(fetchImpl).polish({ rawText: SPOKEN, strength: "prompt", llm: ROUTE, translateTo: "en" });
  assert.equal(invented.fallback, true);
  assert.equal(invented.reason, "invented-fact");
  assert.equal(invented.text, "");
  assert.equal(invented.clarification.kind,"quality");
  assert.doesNotMatch(invented.text, /512/);
  const noKey = await makeService(fetchImpl).polish({ rawText: SPOKEN, strength: "prompt", translateTo: "en" });
  assert.equal(noKey.fallback, true);
  assert.equal(noKey.reason, "no-api-key");
  assert.equal(noKey.text, "");
});

for (const [reply,reason] of [
 ['{"status":"ok","text":"周五在 512 房间开会。"}','invented-fact'],
 ['{"status":"ok","text": }','output-format'],
]) test('source cleanup failure holds translation without bypassing the first step: '+reason, async()=>{
 const {calls,fetchImpl}=provider(reply);
 const result=await makeService(fetchImpl).polish({rawText:SPOKEN,llm:ROUTE,translateTo:'en'});
 assert.equal(calls.length,1);assert.equal(result.text,'');assert.equal(result.fallback,true);
 assert.equal(result.clarification.reason,reason);assert.equal(result.clarification.target,'en');
});

test("translation request fails: the validated source remains insertable", async () => {
  const cleaned = "周四下午三点开会，大家记得带电脑。";
  let calls = 0;
  const fetchImpl = async () => {
    calls++;
    if (calls === 1) return { ok: true, status: 200, json: async () => ({ choices: [{ message: { content: JSON.stringify({ status: "ok", text: cleaned, reason: "改口" }) }, finish_reason: "stop" }] }) };
    return { ok: false, status: 401, body: { cancel: async () => {} } };
  };
  const result = await makeService(fetchImpl).polish({ rawText: SPOKEN, llm: ROUTE, translateTo: "en" });
  assert.equal(calls, 2);
  assert.equal(result.fallback, true);
  assert.equal((result.clarification?.candidate ?? result.text), normalizeNumbers(cleaned));
  assert.equal(result.reason, "model-error:HTTP_401");
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
  assert.equal(await applyVariants(text, { zh: "tw" }, "zh"), "這個軟體的滑鼠和記憶體有問題，DeepSeek 3.5 版本");
  assert.match(await applyVariants(text, { zh: "hk" }, "zh"), /^這個軟件/);
  assert.equal(await applyVariants(text, { zh: "hans" }, "zh"), text);
  assert.equal(await applyVariants("Hello 123", { zh: "tw" }, "zh"), "Hello 123");
});

test("繁体只用于中文：日文汉字和译成其他语言的结果不转换", async () => {
  assert.equal(await applyVariants("会社の設定を変更してください。", { zh: "tw" }, "zh"), "会社の設定を変更してください。");
  assert.equal(await applyVariants("金曜日までに企画書を送ってください。", { zh: "hk" }, "zh"), "金曜日までに企画書を送ってください。");
  const japanese = "会議は木曜日の午後3時です。";
  const { fetchImpl } = provider(calls => calls.length === 1
    ? JSON.stringify({ status: "ok", text: "周四下午三点开会。", reason: "改口" }) : japanese);
  const translated = await makeService(fetchImpl).polish({ rawText: SPOKEN, llm: ROUTE, translateTo: "ja", variants: "zh=tw" });
  assert.equal(translated.text, japanese);
  const { fetchImpl: toChinese } = provider(calls => calls.length === 1
    ? JSON.stringify({ status: "ok", text: "周四下午三点开会。", reason: "改口" }) : "这个软件周四更新。");
  const chinese = await makeService(toChinese).polish({ rawText: SPOKEN, llm: ROUTE, translateTo: "zh", variants: "zh=tw" });
  assert.equal(chinese.text, "這個軟體週四更新。");
  // Recognised as Japanese: no kana does not make it Chinese (企画書 must not become 企畫書).
  const kanjiOnly = await makeService(provider('{"status":"ok","text":"企画書。"}').fetchImpl).polish({ rawText: "企画書", language: "ja", variants: "zh=tw" });
  assert.match(kanjiOnly.clarification?.candidate ?? kanjiOnly.text, /^企画書/);
});

test("变体对整理结果和无模型回退都生效；英式拼写写进系统提示词", async () => {
  const { calls, fetchImpl } = provider('{"status":"ok","text":"周四下午三点开会，大家记得带电脑。"}');
  const service = makeService(fetchImpl);
  const polished = await service.polish({ rawText: SPOKEN, strength: "prompt", llm: ROUTE, variants: "zh=tw,en=gb" });
  assert.equal(polished.text, "週四下午3點開會，大家記得帶電腦。");
  assert.match(calls[0].system, /British spelling/);
  const withoutRoute = await service.polish({ rawText: "下午三点开会", strength: "prompt", variants: "zh=hk" });
  assert.equal(withoutRoute.clarification?.candidate ?? withoutRoute.text, "下午三點開會");
});

test("繁体按语言启用：中文和粤语启用，其他及未知语言关闭", async () => {
  for (const language of [undefined, "auto", "ja", "ko", "en", "fr"]) {
    for (const text of ["会社", "企画書", "软件开发"]) {
      assert.equal(await applyVariants(text, { zh: "tw" }, language), text, `${language}: ${text}`);
    }
    const result = await makeService().polish({ rawText: "企画書", language: language ?? "auto", variants: "zh=tw" });
    assert.equal((result.clarification?.candidate ?? result.text), "企画書");
  }
  for (const language of ["zh", "yue"]) {
    assert.equal(await applyVariants("软件开发", { zh: "tw" }, language), "軟體開發");
  }
  const failed = await makeService().polish({ rawText: "会社", language: "ja", translateTo: "zh", variants: "zh=tw" });
  assert.equal(failed.fallback, true);
  assert.equal(failed.clarification.candidate, "会社", "a failed translation must not treat its Japanese source as Chinese");
});

test("recognizer metadata reaches the output-language gate without another model call", async () => {
  const service = makeService();
  for (const [detectedLanguage, text, expected] of [["ja", "企画書", "企画書"], ["zh", "软件", "軟體"], [null, "企画書", "企画書"]]) {
    service.recognizer.transcribe = async () => ({ text, language: "auto", detectedLanguage });
    const spoken = await service.transcribe(Buffer.alloc(0), "auto");
    const result = await service.polish({ rawText: spoken.text, language: spoken.language, variants: "zh=tw" });
    assert.equal((result.clarification?.candidate ?? result.text), expected);
  }
});

test("翻译的防编造按数值比对：换写法的时间日期能过，凭空出现的数字被拦下", async () => {
  const { translationInventedNumbers } = await import("../lib/validate.js");
  const raw = "十月十九日下午三点半交一千二百块，不对，是周四下午三点";
  assert.deepEqual(translationInventedNumbers(raw, "Pay 1,200 yuan on October 19 at 3:30 p.m. — no, Thursday at 15:00."), []);
  assert.deepEqual(translationInventedNumbers(raw, "Pay 1,200 yuan in room 512."), ["512"]);
  assert.deepEqual(translationInventedNumbers("一共 3.5 万", "35,000 in total"), ["35000"]);
});

