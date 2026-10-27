import test from "node:test";
import assert from "node:assert/strict";
import { spelledWords } from "../lib/spelling.js";

test("拼写确认：连字符拼读和带提示词的空格拼读都能合成单词", () => {
  assert.deepEqual(spelledWords("这个型号叫 ROG，它的拼法是 R-O-G。"), [{ spelled: "R-O-G", word: "ROG" }]);
  assert.deepEqual(spelledWords("我拼一下 r o g"), [{ spelled: "r o g", word: "rog" }]);
  assert.deepEqual(spelledWords("我的名字拼写是 L, I, N"), [{ spelled: "L, I, N", word: "LIN" }]);
  assert.deepEqual(spelledWords("就是 A-B-C 这个牌子"), [{ spelled: "A-B-C", word: "ABC" }]);
  assert.deepEqual(spelledWords("You spell it c a t"), [{ spelled: "c a t", word: "cat" }]);
});

test("拼写确认：改口后的两次拼写都交给模型，由规则取最后一次", () => {
  assert.deepEqual(spelledWords("先拼 R-O-G，不对，应该是 R-O-C-K").map(item => item.word), ["ROG", "ROCK"]);
});

test("拼写确认：没有拼写提示时，短字母组合和普通英文保持原样", () => {
  for (const text of ["做一个 A-B 测试", "把 x y 轴对调", "I want a big one", "e.g. this one", "Python 3.12 版本", "下午 3 点开会"]) {
    assert.deepEqual(spelledWords(text), [], text);
  }
  assert.deepEqual(spelledWords("拼法在下一句。我们做 A B 测试"), [], "a cue in another sentence does not count");
});

test("拼写确认：数量有上限，重复的拼写只算一次", () => {
  assert.equal(spelledWords("A-B-C A-B-C").length, 1);
  assert.equal(spelledWords(Array.from({ length: 8 }, (_, i) => `X-Y-${String.fromCharCode(65 + i)}`).join(" ")).length, 5);
});

test("拼写确认：整理请求带上拼写提示，普通话语不带", async () => {
  const { VoicePolishService } = await import("../lib/service.js");
  const systems = [];
  const fetchImpl = async (_url, init) => {
    systems.push(JSON.parse(init.body).messages[0].content);
    return { ok: true, status: 200, json: async () => ({ choices: [{ message: { content: '{"status":"ok","text":"这个型号叫 ROG。"}' }, finish_reason: "stop" }] }) };
  };
  const service = new VoicePolishService({
    recognizer: { snapshot: () => ({ ready: true }), transcribe: async () => ({ text: "" }) },
    fetchImpl,
    config: { maxOutputTokens: 800, timeoutMs: 12000, strength: "prompt", redactSecrets: true, maxAudioBytes: 4194304, maxDurationSeconds: 120, dictionary: [] },
    logger: { info: () => {}, warn: () => {}, debug: () => {} },
  });
  const llm = { baseURL: "https://api.example.com/v1", model: "m", apiKey: "test-key" };
  await service.polish({ rawText: "这个型号叫 ROG，它的拼法是 R-O-G。", llm });
  await service.polish({ rawText: "我们明天下午开会。", llm });
  assert.match(systems[0], /"R-O-G" spells "ROG"\./);
  assert.doesNotMatch(systems[1], /Letter-by-letter spellings in this utterance/);
});

test('a matching parenthetical spelling is evidence without an extra cue',()=>{
 assert.deepEqual(spelledWords('我想知道 stream（s t r e a m）是什么意思。'),[{spelled:'s t r e a m',word:'stream'}]);
 assert.deepEqual(spelledWords('这个单词是 C U D A，用于计算。'),[{spelled:'C U D A',word:'CUDA'}]);
 assert.deepEqual(spelledWords('compare alpha (x y z)'),[]);
});
test('spelling late in a long utterance is not discarded at an early text boundary',()=>{
 assert.deepEqual(spelledWords('这是说明。'.repeat(1600)+'它的拼法是 S-T-R-E-A-M。'),[{spelled:'S-T-R-E-A-M',word:'STREAM'}]);
});
