/**
 * Loader configuration for voice-polish.
 *
 * The schema is a minimal StandardSchemaV1 implementation rather than a
 * Schemastery schema, because this plugin is loaded from a path that cannot
 * resolve DSH's packages. Its validator applies defaults and rejects unknown or
 * ill-typed values at load time.
 *
 * `Config` must NOT expose `toJSON()`. DSH's Settings service treats any Config
 * with `toJSON` as a Schemastery schema and reads `schema.meta.volatile`; on
 * this object that throws a TypeError, `settings.describe` fails, and the
 * desktop window crashes at start with "desktop welcome: Web RPC failed".
 * Without `toJSON` the Settings service skips this plugin: configure it in the
 * profile patch. The JSON Schema view stays available as configJsonSchema().
 *
 * @module dsh-voice-polish/config
 */
import { join } from "node:path";
import { homedir } from "node:os";

/** Default state directory under the DSH home. */
export const DEFAULT_STATE_DIR = join(process.env.DSH_HOME?.trim() || join(homedir(), ".dsh"), "voice-polish");

export const STRENGTHS = ["off", "conservative", "prompt", "maximal"];
export const LANGUAGES = ["auto", "zh", "en", "yue", "ja", "ko"];
/** "default" sends no effort, so the route's own default applies. */
export const REASONING_EFFORTS = ["off", "low", "high", "max", "default"];
/** Which instructions the model receives. */
/** The Article prompt is the only one; the key stays so an existing profile value validates. */
export const PROMPT_SOURCES = ["article"];

/** Field declarations: default, kind and help for the Settings form. */
const FIELDS = {
  provider: { kind: "string", default: "deepseek-account", help: "LLM provider route id, e.g. deepseek-account." },
  model: { kind: "string", default: "deepseek-flash", help: "Model id passed to the provider route." },
  maxOutputTokens: { kind: "integer", default: 800, help: "Upper bound for the polished text." },
  // The shipped DeepSeek adapter defaults to "high" when a call names no effort,
  // and its thinking tokens are billed against maxOutputTokens.
  reasoningEffort: { kind: "enum", default: "off", values: REASONING_EFFORTS, help: "Model reasoning effort for polishing: off | low | high | max, or default to use the route's own default. Thinking tokens count against maxOutputTokens." },
  timeoutMs: { kind: "integer", default: 12000, help: "Polishing budget; on expiry the raw transcript is used. Real dictations need 4-6s, so 12s leaves headroom." },
  strength: { kind: "enum", default: "prompt", values: STRENGTHS, help: "off skips the model. conservative | prompt | maximal all use the Article prompt and only change how strict output validation is." },
  promptSource: { kind: "enum", default: "article", values: PROMPT_SOURCES, help: "article, the vendored Budget-Reference-DIY prompt (the only prompt)." },
  temperature: { kind: "number", default: 0.8, help: "Sampling temperature. The vendored prompt is tuned for 0.8; set 0 for the most literal output." },
  language: { kind: "enum", default: "auto", values: LANGUAGES, help: "Recognition language hint." },
  contextTurns: { kind: "integer", default: 6, help: "Recent conversation turns supplied as context." },
  contextChars: { kind: "integer", default: 4000, help: "Character budget for conversation context." },
  historyDays: { kind: "integer", default: 14, help: "Retention for the dictation history file." },
  stateDir: { kind: "string", default: DEFAULT_STATE_DIR, help: "Directory holding the token and history files." },
  dictionary: { kind: "stringArray", default: [], help: "Words whose spelling must be preserved verbatim." },
  maxAudioBytes: { kind: "integer", default: 4194304, help: "Largest accepted WAV body." },
  maxDurationSeconds: { kind: "integer", default: 120, help: "Longest accepted recording." },
  redactSecrets: { kind: "boolean", default: true, help: "Strip key-shaped strings from model context." },
  logRaw: { kind: "boolean", default: true, help: "Store raw transcripts in history; false keeps only hashes." },
};

/** JSON Schema view of the fields, for documentation and tests (see the module note on toJSON). */
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
 * Validate and default one configuration object.
 *
 * The returned `issues` key is OMITTED when the value is valid: Cordis decides
 * with `if (result.issues) throw new ValidationError(...)`, and an empty array
 * is truthy, so reporting "no problems" as [] would reject every configuration.
 *
 * @param {unknown} value - untrusted loader configuration.
 * @returns {{value: object, issues?: Array<{message: string, path?: string[]}>}}
 */
function validate(value) {
  const issues = [];
  const input = value === null || typeof value !== "object" ? {} : value;
  const output = {};
  for (const key of Object.keys(input)) {
    if (!Object.prototype.hasOwnProperty.call(FIELDS, key)) {
      issues.push({ message: `unknown configuration key "${key}"`, path: [key] });
    }
  }
  for (const [name, field] of Object.entries(FIELDS)) {
    const raw = input[name];
    if (raw === undefined) {
      output[name] = Array.isArray(field.default) ? [...field.default] : field.default;
      continue;
    }
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
        if (!field.values.includes(raw)) issues.push({ message: `${name} must be one of ${field.values.join(", ")}`, path: [name] });
        else output[name] = raw;
        break;
      case "stringArray":
        if (!Array.isArray(raw) || raw.some((entry) => typeof entry !== "string")) issues.push({ message: `${name} must be an array of strings`, path: [name] });
        else output[name] = [...raw];
        break;
      default:
        if (typeof raw !== "string" || raw.length === 0) issues.push({ message: `${name} must be a non-empty string`, path: [name] });
        else output[name] = raw;
    }
  }
  // Cross-field rules worth enforcing before the plugin starts serving.
  if (typeof output.maxOutputTokens === "number" && output.maxOutputTokens < 1) issues.push({ message: "maxOutputTokens must be at least 1", path: ["maxOutputTokens"] });
  if (typeof output.timeoutMs === "number" && output.timeoutMs < 1000) issues.push({ message: "timeoutMs must be at least 1000", path: ["timeoutMs"] });
  if (typeof output.timeoutMs === "number" && output.timeoutMs < 6000) issues.push({ message: "timeoutMs below 6000 will fall back on real dictations", path: ["timeoutMs"] });
  if (typeof output.temperature === "number" && (output.temperature < 0 || output.temperature > 2)) issues.push({ message: "temperature must be between 0 and 2", path: ["temperature"] });
  if (typeof output.maxAudioBytes === "number" && output.maxAudioBytes < 46) issues.push({ message: "maxAudioBytes must be at least the WAV header size (46)", path: ["maxAudioBytes"] });
  return issues.length === 0 ? { value: output } : { value: output, issues };
}

/** The Loader-facing schema: StandardSchemaV1 only. No toJSON (see the module note). */
export const Config = {
  "~standard": { version: 1, vendor: "dsh-voice-polish", validate },
};
