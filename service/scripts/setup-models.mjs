#!/usr/bin/env node
/**
 * Install the local speech models (about 241 MB, once).
 *
 *   npm run setup-models                       download from huggingface.co
 *   npm run setup-models -- --from <folder>    copy from a folder that has them
 *   npm run setup-models -- --models-dir <dir> install somewhere else
 *
 * Mirror: set HF_ENDPOINT, e.g. HF_ENDPOINT=https://hf-mirror.com (macOS shell)
 * or $env:HF_ENDPOINT="https://hf-mirror.com" (Windows PowerShell).
 *
 * Every file is checked by size and SHA-256 before it is kept.
 */
import { parseArgs } from "node:util";
import { defaultModelsDir } from "../lib/paths.js";
import { downloadModels, importModels, MODEL_FILES, modelStatus, MODELS_TOTAL_BYTES } from "../lib/models.js";

const { values } = parseArgs({
  options: {
    "models-dir": { type: "string" },
    from: { type: "string" },
  },
});
const modelsDir = values["models-dir"] ?? defaultModelsDir();
const mb = (bytes) => (bytes / 1024 / 1024).toFixed(1) + " MB";

console.log(`Models folder: ${modelsDir}`);
if (values.from) {
  const result = await importModels({ from: values.from, modelsDir });
  console.log(`Copied: ${result.copied.join(", ") || "nothing"}`);
  if (result.missing.length > 0) console.log(`Not found (or checksum differs): ${result.missing.join(", ")}`);
}

const before = await modelStatus(modelsDir);
if (before.ready) {
  console.log("All model files are present.");
  process.exit(0);
}
const todo = MODEL_FILES.filter((file) => before.missing.includes(file.id));
console.log(`Downloading ${todo.map((file) => file.file).join(", ")} (${mb(todo.reduce((sum, file) => sum + file.size, 0))} of ${mb(MODELS_TOTAL_BYTES)} in all)…`);
let lastShown = 0;
try {
  await downloadModels({
    modelsDir,
    onProgress: ({ received, total }) => {
      const now = Date.now();
      if (now - lastShown < 1000 && received < total) return;
      lastShown = now;
      process.stdout.write(`\r  ${mb(received)} / ${mb(total)}   `);
    },
  });
  process.stdout.write("\n");
} catch (error) {
  process.stdout.write("\n");
  console.error(`Failed: ${error instanceof Error ? error.message : String(error)}`);
  console.error("If huggingface.co is unreachable, set HF_ENDPOINT to a mirror and run this again.");
  process.exit(1);
}
const after = await modelStatus(modelsDir);
console.log(after.ready ? "Done. All model files are installed and verified." : `Still missing: ${after.missing.join(", ")}`);
process.exit(after.ready ? 0 : 1);
