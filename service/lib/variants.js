/**
 * Language variants (语言变体): how Chinese and English are written in the output.
 *
 * Chinese is converted deterministically, on this computer, after everything else
 * (OpenCC dictionaries via opencc-js), so it also applies when no model is used and
 * never disturbs the checks that compare the output with the transcript. English
 * spelling has no reliable rule table, so British spelling is asked of the model.
 *
 * Header form: "zh=tw,en=gb". Unknown or missing parts mean the default
 * (Simplified Chinese, American English).
 */

export const ZH_VARIANTS = ["hans", "tw", "hk"];
export const EN_VARIANTS = ["us", "gb"];

/** Parse "zh=tw,en=gb" (or an object) into { zh, en }, dropping anything unknown. */
export function parseVariants(value) {
  const out = { zh: "hans", en: "us" };
  if (!value) return out;
  const pairs = typeof value === "object"
    ? Object.entries(value)
    : String(value).split(",").map((part) => part.split("=").map((s) => s.trim().toLowerCase()));
  for (const [key, choice] of pairs) {
    if (key === "zh" && ZH_VARIANTS.includes(choice)) out.zh = choice;
    if (key === "en" && EN_VARIANTS.includes(choice)) out.en = choice;
  }
  return out;
}

/** A line for the system prompt, or "" when the default spelling is wanted. */
export function variantInstruction(variants) {
  return variants?.en === "gb"
    ? "\n\nWhen the output contains English, use British spelling and vocabulary (colour, organise, centre, flat)."
    : "";
}

// Loaded on first use: the dictionaries are about 2 MB and most people never need them.
const converters = new Map();
async function converter(target) {
  if (!converters.has(target)) {
    converters.set(target, import("opencc-js/cn2t").then((m) => m.Converter({ from: "cn", to: target })));
  }
  return converters.get(target);
}

/** Convert Chinese text to the chosen variant; Simplified (the default) is returned unchanged. */
export async function applyVariants(text, variants) {
  const value = String(text ?? "");
  if (!value || !variants || variants.zh === "hans" || !/[一-鿿]/.test(value)) return value;
  // Taiwan gets Taiwanese phrasing too (软件 → 軟體), Hong Kong its own characters.
  const convert = await converter(variants.zh === "tw" ? "twp" : "hk");
  return convert(value);
}
