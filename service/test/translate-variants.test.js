import test from "node:test";
import assert from "node:assert/strict";
import { VoicePolishService } from "../lib/service.js";
import { directTranslatePrompt, TRANSLATE_LANGUAGES } from "../lib/prompts/translate.js";
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
    config: { language: "zh", maxOutputTokens: 800, timeoutMs: 12000, strength: "prompt", redactSecrets: true, maxAudioBytes: 4194304, maxDurationSeconds: 120, dictionary: [] },
    logger: { info: () => {}, warn: () => {}, debug: () => {} },
  });
}

test("翻译：一次调用直接整理并译成目标语言，不用听写整理提示词", async () => {
  const { calls, fetchImpl } = provider("The meeting is on Thursday at 3 pm. Please bring your laptops.");
  const service = makeService(fetchImpl);
  const result = await service.polish({ rawText: SPOKEN, strength: "prompt", llm: ROUTE, translateTo: "en" });
  assert.equal(result.fallback, false);
  assert.equal(result.text, "The meeting is on Thursday at 3 pm. Please bring your laptops.");
  assert.equal(result.translated, "en");
  assert.equal(calls.length, 1);
  assert.equal(calls[0].user, SPOKEN);
  assert.match(calls[0].system, /把语音识别文本理解并整理后译成English/);
  assert.doesNotMatch(calls[0].system, /# Profile/);
  assert.equal(service.stats.modelCalls, 1);
});

test("翻译请求失败：插入整理过语气词的原文", async () => {
  const fetchImpl = async () => ({ ok: false, status: 401, body: { cancel: async () => {} } });
  const result = await makeService(fetchImpl).polish({ rawText: SPOKEN, llm: ROUTE, translateTo: "en" });
  assert.equal(result.fallback, true);
  assert.equal(result.reason, "model-error:HTTP_401");
  assert.notEqual(result.text, "");
});

test("不认识的目标语言按普通整理处理", async () => {
  const { calls, fetchImpl } = provider('{"status":"ok","text":"周四下午三点开会，大家记得带电脑。"}');
  const result = await makeService(fetchImpl).polish({ rawText: SPOKEN, strength: "prompt", llm: ROUTE, translateTo: "xx" });
  assert.equal(result.translated, undefined);
  assert.match(calls[0].system, /# Profile/);
});

test("翻译提示词：十种目标语言，中文先写简体再按变体转换", () => {
  assert.equal(Object.keys(TRANSLATE_LANGUAGES).length, 10);
  assert.match(directTranslatePrompt("zh"), /简体中文/);
  assert.match(directTranslatePrompt("unknown"), /English/);
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
  const { fetchImpl } = provider(japanese);
  const translated = await makeService(fetchImpl).polish({ rawText: SPOKEN, llm: ROUTE, translateTo: "ja", variants: "zh=tw" });
  assert.equal(translated.text, japanese);
  const { fetchImpl: toChinese } = provider("这个软件周四更新。");
  const chinese = await makeService(toChinese).polish({ rawText: SPOKEN, llm: ROUTE, translateTo: "zh", variants: "zh=tw" });
  assert.equal(chinese.text, "這個軟體週四更新。");
  // Recognised as Japanese: no kana does not make it Chinese (企画書 must not become 企畫書).
  const kanjiOnly = await makeService(provider('{"status":"ok","text":"企画書。"}').fetchImpl).polish({ rawText: "企画書", language: "ja", variants: "zh=tw" });
  assert.match(kanjiOnly.text, /^企画書/);
});

test("变体对整理结果和无模型回退都生效；英式拼写写进系统提示词", async () => {
  const { calls, fetchImpl } = provider('{"status":"ok","text":"周四下午三点开会，大家记得带电脑。"}');
  const service = makeService(fetchImpl);
  const polished = await service.polish({ rawText: SPOKEN, strength: "prompt", llm: ROUTE, variants: "zh=tw,en=gb" });
  assert.equal(polished.text, "週四下午三點開會，大家記得帶電腦。");
  assert.match(calls[0].system, /British spelling/);
  const withoutRoute = await service.polish({ rawText: "下午三点开会", strength: "prompt", variants: "zh=hk" });
  assert.equal(withoutRoute.text, "下午三點開會");
});

test("繁体按语言启用：中文和粤语启用，其他及未知语言关闭", async () => {
  for (const language of [undefined, "auto", "ja", "ko", "en", "fr"]) {
    for (const text of ["会社", "企画書", "软件开发"]) {
      assert.equal(await applyVariants(text, { zh: "tw" }, language), text, `${language}: ${text}`);
    }
    const result = await makeService().polish({ rawText: "企画書", language: language ?? "auto", variants: "zh=tw" });
    assert.equal(result.text, "企画書");
  }
  for (const language of ["zh", "yue"]) {
    assert.equal(await applyVariants("软件开发", { zh: "tw" }, language), "軟體開發");
  }
  const failed = await makeService().polish({ rawText: "会社", language: "ja", translateTo: "zh", variants: "zh=tw" });
  assert.ok(failed.fallback || failed.uncertain, 'not a clean pass');
  assert.equal(failed.text, "会社", "a failed translation must not treat its Japanese source as Chinese");
});

test("recognizer metadata reaches the output-language gate without another model call", async () => {
  const service = makeService();
  for (const [detectedLanguage, text, expected] of [["ja", "企画書", "企画書"], ["zh", "软件", "軟體"], [null, "企画書", "企画書"]]) {
    service.recognizer.transcribe = async () => ({ text, language: "auto", detectedLanguage });
    const spoken = await service.transcribe(Buffer.alloc(0), "auto");
    const result = await service.polish({ rawText: spoken.text, language: spoken.language, variants: "zh=tw" });
    assert.equal(result.text, expected);
  }
});
