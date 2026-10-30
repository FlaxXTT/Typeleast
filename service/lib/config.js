/**
 * Service configuration.
 *
 * Defaults suit almost everyone; a user who wants to change one reads
 * `config.json` in the state directory (see paths.js), for example
 *
 *   { "timeoutMs": 15000 }
 *
 * Unknown or ill-typed keys are reported and ignored, never fatal: a typo in a
 * hand-edited file must not stop dictation.
 *
 * Which model cleans the text, and its API key, are NOT configured here: the app
 * sends that route with each request (see openai-compat.js), so a key never sits
 * in a file the service reads.
 *
 * @module typeleast-service/config
 */
import { readFile } from "node:fs/promises";
import { join } from "node:path";

export const STRENGTHS = ["conservative", "prompt", "maximal", "concise", "promptbeta"];
/** Tiers that no longer exist, and the one each now means. */
export const RETIRED_STRENGTHS = { off: "prompt", promptbrief: "concise", promptify: "concise" };

/** The tier a request asks for, with a retired id read as its replacement. */
export function canonicalStrength(value) {
  return Object.hasOwn(RETIRED_STRENGTHS, value ?? "") ? RETIRED_STRENGTHS[value] : value;
}
export const LANGUAGES = ["auto", "zh", "en", "yue", "ja", "ko"];
export const CONFIG_FILE = "config.json";

/** Field declarations: default, kind and help. */
const FIELDS = {
  maxOutputTokens: { kind: "integer", default: 800, help: "Upper bound for the polished text." },
  timeoutMs: { kind: "integer", default: 300000, help: "Maximum per-call cleanup time; actual time scales with input within the shared 300-second budget." },
  strength: { kind: "enum", default: "prompt", values: STRENGTHS, help: "prompt (自然整理) uses the general cleanup prompt. conservative and maximal are legacy validation levels. concise (AI 整理) keeps the intent and constraints in fewer words. Retired off reads as prompt; retired promptbrief and promptify read as concise. promptbeta (提示词 Beta) clarifies information over multiple rounds." },
  temperature: { kind: "number", default: 0.8, help: "Sampling temperature. Keeps the existing default; set 0 for the most literal output." },
  language: { kind: "enum", default: "auto", values: LANGUAGES, help: "Recognition language (SenseVoice). auto detects it per dictation." },
  numThreads: { kind: "integer", default: 2, help: "CPU threads for local recognition." },
  maxAudioBytes: { kind: "integer", default: 24 * 1024 * 1024, help: "Largest accepted WAV body." },
  maxDurationSeconds: { kind: "integer", default: 600, help: "Longest accepted recording." },
  dictionary: { kind: "stringArray", default: [], help: "Unused since the dictionary was removed; kept so an older config.json still loads." },
  redactSecrets: { kind: "boolean", default: true, help: "Strip key-shaped strings from model context." },
};

/** JSON Schema view of the fields, for documentation and tests. */
export function configJsonSchema() {
  const properties = {};
  for (const [name, field] of Object.entries(FIELDS)) {
    properties[name] = {
      type: field.kind === "integer" ? "integer" : field.kind === "number" ? "number" : field.kind === "boolean" ? "boolean" : field.kind === "stringArray" ? "array" : "string",
      default: field.default,
      description: field.help,
      ...(field.values === undefined ? {} : { enum: [...field.values] }),
      ...(field.kind === "stringArray" ? { items: { type: "string" } } : {}),
    };
  }
  return { type: "object", additionalProperties: false, properties };
}

/**
 * Validate and default one configuration object. Invalid values keep their
 * default and are listed in `issues`.
 * @param {unknown} value - untrusted configuration.
 * @returns {{value: object, issues: Array<{message: string, path: string[]}>}}
 */
export function validateConfig(value) {
  const issues = [];
  const input = value === null || typeof value !== "object" || Array.isArray(value) ? {} : value;
  const output = {};
  for (const key of Object.keys(input)) {
    if (!Object.prototype.hasOwnProperty.call(FIELDS, key)) {
      issues.push({ message: `unknown configuration key "${key}"`, path: [key] });
    }
  }
  for (const [name, field] of Object.entries(FIELDS)) {
    const fallback = Array.isArray(field.default) ? [...field.default] : field.default;
    const raw = input[name];
    output[name] = fallback;
    if (raw === undefined) continue;
    switch (field.kind) {
      case "boolean":
        if (typeof raw !== "boolean") issues.push({ message: `${name} must be a boolean`, path: [name] });
        else output[name] = raw;
        break;
      case "number":
        if (typeof raw !== "number" || !Number.isFinite(raw)) issues.push({ message: `${name} must be a number`, path: [name] });
        else output[name] = raw;
        break;
      case "integer":
        if (!Number.isSafeInteger(raw) || raw < 0) issues.push({ message: `${name} must be a non-negative integer`, path: [name] });
        else output[name] = raw;
        break;
      case "enum":
        if (!field.values.includes(name === "strength" ? canonicalStrength(raw) : raw)) issues.push({ message: `${name} must be one of ${field.values.join(", ")}`, path: [name] });
        else output[name] = name === "strength" ? canonicalStrength(raw) : raw;
        break;
      case "stringArray":
        if (!Array.isArray(raw) || raw.some((entry) => typeof entry !== "string")) issues.push({ message: `${name} must be an array of strings`, path: [name] });
        else output[name] = [...raw];
        break;
      default:
        issues.push({ message: `${name} has an unsupported kind`, path: [name] });
    }
  }
  // Cross-field rules: an out-of-range value goes back to its default.
  const guard = (name, ok, message) => {
    if (!ok(output[name])) {
      issues.push({ message, path: [name] });
      output[name] = FIELDS[name].default;
    }
  };
  guard("maxOutputTokens", (v) => v >= 1, "maxOutputTokens must be at least 1");
  guard("timeoutMs", (v) => v >= 1000, "timeoutMs must be at least 1000");
  guard("temperature", (v) => v >= 0 && v <= 2, "temperature must be between 0 and 2");
  guard("maxAudioBytes", (v) => v >= 46, "maxAudioBytes must be at least the WAV header size (46)");
  guard("numThreads", (v) => v >= 1 && v <= 16, "numThreads must be between 1 and 16");
  if (output.timeoutMs < 6000) issues.push({ message: "timeoutMs below 6000 can interrupt real dictations", path: ["timeoutMs"] });
  return { value: output, issues };
}

/**
 * Read `config.json` from the state directory. A missing file means defaults;
 * a malformed one is reported and also means defaults.
 * @param {string} stateDir - the state directory.
 * @returns {Promise<{value: object, issues: Array<{message: string, path: string[]}>}>}
 */
export async function loadConfig(stateDir) {
  let parsed = {};
  try {
    parsed = JSON.parse(await readFile(join(stateDir, CONFIG_FILE), "utf8"));
  } catch (error) {
    if (error?.code !== "ENOENT") {
      const result = validateConfig({});
      result.issues.push({ message: `${CONFIG_FILE} could not be read (${error instanceof Error ? error.message : String(error)}); using defaults`, path: [] });
      return result;
    }
  }
  return validateConfig(parsed);
}
