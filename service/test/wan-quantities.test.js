import test from "node:test";
import assert from "node:assert/strict";
import { inventedFacts, validateOutput } from "../lib/validate.js";

test("一万五, 两万 and their written forms state the same value", () => {
  assert.deepEqual(inventedFacts("预算一万五左右", "预算 15000 元左右"), []);
  assert.deepEqual(inventedFacts("预算一万五左右", "预算 1.5 万元左右"), []);
  assert.deepEqual(inventedFacts("一万五千块", "15000 块"), []);
  assert.deepEqual(inventedFacts("预算不超过两万", "预算不超过 2 万"), []);
  assert.deepEqual(inventedFacts("预算不超过两万", "预算不超过 20000 元"), []);
  assert.deepEqual(inventedFacts("三万五的预算", "3.5 万的预算"), []);
});

test("a changed 万 amount is still caught", () => {
  const raw = "这个工具要能导出PDF，必须支持离线使用，这是硬性要求，预算不超过两万，除非能多支持Windows";
  const ok = "这个工具要能导出 PDF，必须支持离线使用，这是硬性要求。预算不超过 2 万元，除非能多支持 Windows。";
  assert.equal(validateOutput({ rawText: raw, output: ok, strength: "prompt" }).ok, true);
  for (const wrong of ["30000 元", "2.5 万"]) {
    const verdict = validateOutput({ rawText: raw, output: ok.replace("2 万元", wrong), strength: "prompt" });
    assert.equal(verdict.reason, "invented-fact", wrong);
  }
});
