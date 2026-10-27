import test from "node:test";
import assert from "node:assert/strict";
import { collapseRepeats, stripParticles, tidy } from "../lib/tidy.js";

test("leading filler runs are removed", () => {
  assert.equal(stripParticles("呃，嗯，此外，我们要发货"), "此外，我们要发货");
  assert.equal(stripParticles("嗯嗯。这个功能要改"), "这个功能要改");
  assert.equal(stripParticles("呃嗯，我想说的是这个"), "我想说的是这个");
});

test("a filler run that replaced a clause takes a comma, not a full stop", () => {
  // The real shape from this project: "。比如呃嗯。啊呢这些" — leaving "比如。" would
  // read as an empty sentence.
  const out = stripParticles("比如呃嗯。啊呢这些口水话");
  assert.ok(!/比如[。]/u.test(out), "no empty clause was left behind: " + out);
  assert.ok(out.includes("比如，"), out);
});

test("a trailing question particle goes with the question", () => {
  assert.equal(stripParticles("这个功能是不是要改呢？"), "这个功能是不是要改？");
  assert.equal(stripParticles("先这样吧，明天再说"), "先这样，明天再说");
});

test("real words that merely contain a particle character are protected", () => {
  // 哪吒 contains 哪 and 吒; removing either would corrupt the word. 嘛呢 likewise.
  for (const text of ["哪吒的故事很好看", "嘛呢这个词是藏语", "他说嗯哼了一声"]) {
    assert.equal(stripParticles(text), text, text + " must be untouched");
  }
});

test("ordinary prose with no filler is returned unchanged", () => {
  const prose = "我们周三发给他，记得带上第四批的文件，另外把预算表也一起发过去。";
  const result = tidy(prose);
  assert.equal(result.text, prose);
  assert.deepEqual(result.applied, []);
});

test("a single particle wedged inside content is left alone", () => {
  // Deliberate: protecting real words matters more than catching this one, and
  // the model's rewrite is what removes it.
  assert.equal(stripParticles("表格的呃这些列"), "表格的呃这些列");
});

test("adjacent duplicate sentences collapse into one", () => {
  assert.equal(collapseRepeats("我想把会议挪到周四。我想把会议挪到周四。"), "我想把会议挪到周四。");
  assert.equal(collapseRepeats("这个要改。这个要改，先整理再插入。"), "这个要改。这个要改，先整理再插入。");
});

test("a repeated clause is dropped even when its sentence differs", () => {
  // The first sentence is a truncated prefix of the second, which is the shape
  // dictation produces when someone restarts a sentence.
  const out = collapseRepeats("这个功能要改成。这个功能要改成先整理再插入。");
  assert.equal(out, "这个功能要改成先整理再插入。");
});

test("cleanup never deletes the whole answer", () => {
  assert.equal(stripParticles("呃。").length > 0, true);
  assert.equal(stripParticles("嗯嗯嗯"), "嗯嗯嗯", "an all-filler answer is kept rather than emptied");
});

test("tidy reports which steps changed the text", () => {
  const result = tidy("嗯，这个功能要改成。这个功能要改成先整理再插入。");
  assert.ok(result.applied.includes("strip-particles"));
  assert.ok(result.text.length > 0);
  assert.ok(!result.text.startsWith("嗯"));
});
test("fillers that are quoted or listed are mentioned, not used, and survive", () => {
  assert.equal(stripParticles("口水话处理得也不够，“呃”“嗯”“啊”“呢”这些还在。"), "口水话处理得也不够，“呃”“嗯”“啊”“呢”这些还在。");
  assert.equal(stripParticles("比如呃、嗯、啊这些词"), "比如呃、嗯、啊这些词");
  assert.equal(stripParticles("呃，我想说的是这个"), "我想说的是这个", "a used filler still goes");
});

test("line breaks between list items survive sentence de-duplication", () => {
  const list = "我想说三点：\n1. 要快。\n2. 要准。\n3. 要便宜。";
  assert.equal(tidy(list).text, list);
  assert.equal(collapseRepeats("第一段。\n\n第二段。"), "第一段。\n\n第二段。");
  assert.equal(collapseRepeats("我想把会议挪到周四。\n我想把会议挪到周四。"), "我想把会议挪到周四。\n", "a repeated line still collapses");
});


test("generic raw cleanup does not add brand spelling", () => {
  assert.equal(tidy("嗯，我在iphone上用github").text, "我在iphone上用github");
});
