/**
 * Text helpers for model replies. The service no longer checks what the model wrote.
 *
 * @module typeleast-service/validate
 */

/**
 * Remove wrappers a chatty model may add around an otherwise fine answer.
 *
 * A single fenced block is unwrapped rather than rejected: the content is what
 * matters, and rejecting it would silently discard a usable answer. Anything
 * left wrapped is still reported so it can be measured.
 * @param {string} text - raw model output.
 * @returns {{text: string, unwrappedFence: boolean, unwrappedQuotes: boolean}}
 */
export function unwrap(text) {
  let out = String(text ?? "").trim();
  let unwrappedFence = false;
  let unwrappedQuotes = false;
  const fence = out.match(/^```[A-Za-z0-9_-]*\n([\s\S]*?)\n?```$/);
  if (fence) {
    out = fence[1].trim();
    unwrappedFence = true;
  }
  if (out.length >= 2) {
    const first = out[0];
    const last = out[out.length - 1];
    const pairs = [['"', '"'], ["'", "'"], ["\u201c", "\u201d"], ["\u2018", "\u2019"], ["\u300c", "\u300d"]];
    for (const [open, close] of pairs) {
      if (first === open && last === close) {
        const inner = out.slice(1, -1);
        // Only unwrap when the quotes are not part of the content itself.
        if (!inner.includes(close) && !inner.includes(open)) {
          out = inner.trim();
          unwrappedQuotes = true;
          break;
        }
      }
    }
  }
  return { text: out, unwrappedFence, unwrappedQuotes };
}
