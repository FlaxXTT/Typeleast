/**
 * Deterministic cleanup applied after the model, for the things a model
 * reliably under-does on Chinese dictation: filler particles survive
 * surprisingly often, and dictated sentences repeat themselves.
 *
 * Implemented as an explicit scan rather than a regular expression. The rules
 * here interact (removing a particle can orphan the punctuation around it, and
 * whether the mark survives depends on how much sentence preceded it), and a
 * scan states that logic once, in a form a reader can check.
 *
 * Deliberate limits:
 *   - 然后 / 就是 / 其实 / 那个 are NOT touched. In real output they carry
 *     sequence and definition ("把它封装一下，然后压成一个文件"); deleting them
 *     silently corrupts the sentence. The system prompt discourages them as
 *     filler; this module does not gamble on them.
 *   - 哪 is deliberately absent: it belongs to 哪吒. 呢 and 吧 are present,
 *     because a question already carries "?" and a command "!", so a bare 呢/吧
 *     in cleaned text is residue from speech.
 *   - A particle inside a real word is never removed: a run is only treated as
 *     filler when it touches a non-word character on at least one side, and the
 *     words in PROTECTED_WORDS are masked out first.
 *
 * @module dsh-voice-polish/tidy
 */

const PARTICLES = new Set("呃嗯唔哦噢唉诶呀呐嘛呢吧".split(""));

/** Whole words containing a particle character; they must survive untouched. */
const PROTECTED_WORDS = ["哪吒", "嘛呢", "嗯哼", "噢姆"];

const MARKS = new Set(["，", ",", "。", "！", "？", "；", "：", "、"]);

/**
 * Neighbours that mark a particle as MENTIONED rather than used: quoted ("“呃”")
 * or enumerated ("呃、嗯、啊"). Someone dictating about filler words wants
 * those words kept; stripping them leaves debris like "，、啊、这些".
 */
const MENTION = new Set(["、", "“", "”", "\"", "「", "」", "『", "』", "‘", "’", "'", "《", "》"]);

/** Anything outside these ranges is a word boundary as far as particles go. */
function isCjk(character) {
  const code = character.codePointAt(0) ?? 0;
  return (
    (code >= 0x3400 && code <= 0x4dbf) ||
    (code >= 0x4e00 && code <= 0x9fff) ||
    (code >= 0xf900 && code <= 0xfaff) ||
    (code >= 0x3040 && code <= 0x30ff) ||
    (code >= 0xac00 && code <= 0xd7af)
  );
}

/** Characters that carry meaning, used to tell a real clause from a fragment. */
function countContent(text) {
  return (String(text ?? "").match(/[\p{L}\p{N}]/gu) ?? []).length;
}

/**
 * Remove filler runs, keeping or dropping the punctuation they leave behind.
 *
 * A run followed by a mark is removed together with it when the clause before it
 * is too short to be a sentence ("比如呃嗯。" becomes "比如，"); otherwise the mark
 * stays ("此外呢，" becomes "此外，").
 *
 * @param {string} text - model output.
 * @returns {string} text with disfluency removed.
 */
export function stripParticles(text) {
  const source = String(text ?? "");
  const before = countContent(source);

  // Mask protected words so no scan can reach inside them.
  let masked = source;
  const restored = [];
  for (const word of PROTECTED_WORDS) {
    if (!masked.includes(word)) continue;
    const token = "\u0000" + restored.length + "\u0000";
    restored.push(word);
    masked = masked.split(word).join(token);
  }

  const chars = Array.from(masked);
  let out = "";
  for (let index = 0; index < chars.length; index += 1) {
    const character = chars[index];
    if (!PARTICLES.has(character)) {
      out += character;
      continue;
    }
    const previous = index > 0 ? chars[index - 1] : "";
    // The run extends over consecutive particles and the mark directly after it.
    let end = index;
    while (end + 1 < chars.length && PARTICLES.has(chars[end + 1])) end += 1;
    const mark = end + 1 < chars.length && MARKS.has(chars[end + 1]) ? chars[end + 1] : "";
    const next = end + 1 + (mark.length > 0 ? 1 : 0);
    // The particle's own right-hand neighbour: the mark when it has one, the next
    // character otherwise. Using the character AFTER the mark would misread
    // "先这样吧，明天" as glued to content and keep a filler.
    const nextCharacter = end + 1 < chars.length ? chars[end + 1] : "";

    // Filler when it touches a boundary on at least one side. With no boundary
    // at all, a run of two or more particles is still filler — that shape is
    // what "比如啊呢这些" is — while a single character wedged inside content is
    // left alone, which is what protects real words.
    if (MENTION.has(previous) || MENTION.has(nextCharacter)) {
      out += chars.slice(index, end + 1).join("");
      index = end;
      continue;
    }
    const boundaryBefore = previous === "" || !isCjk(previous);
    const boundaryAfter = nextCharacter === "" || !isCjk(nextCharacter);
    const runLength = end - index + 1;
    const isFiller = boundaryBefore || boundaryAfter || runLength >= 2;
    if (!isFiller) {
      out += character;
      index = end;
      continue;
    }

    if (mark.length === 0) {
      index = end;
      continue;
    }
    // Decide the mark: a full stop after a clause shorter than three content
    // characters is an artefact of the removal, so a comma is what the sentence
    // now needs. An empty clause takes no mark at all.
    const fragment = (out.split(/[，,。！？；：、\s]/u).pop() ?? "").trim();
    if (/[。！？]/u.test(mark) && countContent(fragment) < 3) {
      if (countContent(out) > 0) out += "，";
    } else {
      out += mark;
    }
    index = next - 1;
  }

  out = out
    .replace(/([，,。！？；：、])(?=\1)/gu, "")
    .replace(/([，,、])\s*(?=[。！？])/gu, "")
    .replace(/([。！？])[，,、\s]*\1+/gu, "$1")
    .replace(/^[\s，,、。；;：:]+/u, "")
    .replace(/([，,、])\s*([。！？])/gu, "$2");

  for (let index = 0; index < restored.length; index += 1) {
    out = out.split("\u0000" + index + "\u0000").join(restored[index]);
  }
  if (countContent(out) === 0 && before > 0) return source.trim();
  return out.trim();
}

/** Strip punctuation and spacing so two sentences can be compared. */
function normalize(text) {
  return String(text ?? "").replace(/[\s，,。！？!?；;：:]/gu, "");
}

/**
 * Collapse a sentence repeated back-to-back.
 * "我想把会议挪到周四。我想把会议挪到周四。" -> one sentence.
 * @param {string} text - input text.
 * @returns {string} text with adjacent duplicate sentences collapsed.
 */
export function collapseRepeats(text) {
  const source = String(text ?? "");
  // Each part keeps the whitespace that followed it. Splitting on the whitespace
  // and joining with "" (as before) deleted the line breaks of a numbered list
  // whose items end in "。", squashing "1. 要快。\n2. 要准。" onto one line.
  const parts = source.match(/[^。！？!?]*[。！？!?]+\s*|[^。！？!?]+$/gu) ?? [];
  const kept = [];
  for (const part of parts) {
    const key = normalize(part);
    const previousKey = kept.length > 0 ? normalize(kept[kept.length - 1]) : "";
    if (key.length > 0 && key === previousKey) continue;
    // A clause the previous sentence already ends with is a stutter.
    if (key.length >= 4 && previousKey.endsWith(key)) continue;
    // A false start: the previous sentence is just the opening of this one
    // ("这个功能要改成。" then "这个功能要改成先整理再插入。"). The earlier
    // fragment is the abandoned attempt, so it goes.
    if (previousKey.length >= 5 && key.startsWith(previousKey)) {
      kept.pop();
    }
    kept.push(part);
  }
  return kept.join("");
}

/**
 * Apply every deterministic cleanup.
 * @param {string} text - model output.
 * @returns {{text: string, applied: string[]}} cleaned text and the steps that fired.
 */
export function tidy(text) {
  const applied = [];
  let out = String(text ?? "");
  const collapsed = collapseRepeats(out);
  if (collapsed !== out) applied.push("collapse-repeats");
  out = collapsed;
  const stripped = stripParticles(out);
  if (stripped !== out) applied.push("strip-particles");
  out = stripped;
  const cased = normalizeTermCase(out);
  if (cased !== out) applied.push("term-case");
  out = cased;
  return { text: out, applied };
}

/**
 * Names and acronyms with exactly one correct spelling and no ordinary English
 * meaning, so fixing their case can never change what was said ("iphone" ->
 * "iPhone", "api" -> "API"). Words that are also plain English (React, Notion,
 * Word, Go) are deliberately absent: those are left to the model.
 */
const CANONICAL_TERMS = [
  "iPhone", "iPad", "iOS", "macOS", "GitHub", "GitLab", "ChatGPT", "OpenAI", "DeepSeek", "JavaScript", "TypeScript",
  "PowerPoint", "YouTube", "WeChat", "LinkedIn", "PyTorch", "TensorFlow", "Kubernetes", "PostgreSQL", "MySQL",
  "MongoDB", "Docker", "Python", "Figma", "API", "PPT", "SDK", "URL", "PDF", "JSON", "HTTP", "HTTPS", "HTML", "CSS",
  "CPU", "GPU", "KPI", "OKR", "LLM", "CI", "PR",
];
const TERM_PATTERNS = CANONICAL_TERMS.map((term) => [
  term,
  // Not part of a longer word or a code token ("json.loads", "my_api", "/api/").
  new RegExp(`(?<![A-Za-z0-9_./-])${term}(?![A-Za-z0-9_./(-])`, "gi"),
]);

/**
 * Give well-known names and acronyms their standard capitalisation.
 * @param {string} text - input text.
 * @returns {string} the text with those terms re-cased.
 */
export function normalizeTermCase(text) {
  let out = String(text ?? "");
  for (const [term, pattern] of TERM_PATTERNS) out = out.replace(pattern, term);
  return out;
}
