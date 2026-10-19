/**
 * Dictation history: an append-only JSONL file in the state directory.
 *
 * The service records outcomes for diagnosis. By default, transcript fields
 * contain digests; the apps keep their own encrypted, recoverable history.
 *
 * @module typeleast-service/history
 */
import { appendFile, chmod, mkdir, readFile, stat, writeFile, rename } from "node:fs/promises";
import { createHash, randomUUID } from "node:crypto";
import { dirname } from "node:path";

/** Soft size ceiling; older lines are dropped once the file exceeds it. */
const MAX_BYTES = 5 * 1024 * 1024;

/** Short stable digest that stands in for a dictation's words. */
export function textDigest(text) {
  return `sha256:${createHash("sha256").update(String(text)).digest("hex").slice(0, 16)}`;
}

export class History {
  /**
   * @param {object} options - storage policy.
   * @param {string} options.filePath - JSONL destination.
   * @param {number} options.retentionDays - entries older than this are pruned.
   */
  constructor(options) {
    this.filePath = options.filePath;
    this.retentionDays = options.retentionDays;
    this.lines = null;
  }

  /** Load once, tolerating a partially written trailing line. */
  async load() {
    if (this.lines !== null) return this.lines;
    try {
      const text = await readFile(this.filePath, "utf8");
      const lines = [];
      for (const line of text.split("\n")) {
        const trimmed = line.trim();
        if (trimmed.length === 0) continue;
        try {
          lines.push(JSON.parse(trimmed));
        } catch {
          // A truncated tail means a crash mid-append; drop that one line only.
        }
      }
      this.lines = lines;
    } catch (error) {
      if (error.code !== "ENOENT") throw error;
      this.lines = [];
    }
    return this.lines;
  }

  /**
   * Append one entry, pruning whatever the retention policy no longer wants.
   * @param {object} entry - the dictation record.
   * @returns {Promise<object>} the stored entry (with generated id and ts).
   */
  async append(entry) {
    const lines = await this.load();
    const record = {
      id: entry.id ?? randomUUID(),
      ts: entry.ts ?? Date.now(),
      app: entry.app ?? null,
      language: entry.language ?? "auto",
      raw: entry.raw ?? "",
      text: entry.text ?? "",
      fallback: entry.fallback === true,
      reason: entry.reason ?? null,
      // One short line on why a fallback happened (error message, attempts,
      // elapsed ms, or validator measurements); null when nothing fell back.
      detail: entry.detail ?? null,
      model: entry.model ?? null,
      provider: entry.provider ?? null,
      ms: entry.ms ?? null,
      strength: entry.strength ?? null,
    };
    lines.push(record);
    await mkdir(dirname(this.filePath), { recursive: true });
    // The common path is append-only: a full rewrite happens only when the
    // retention policy actually drops something, so a dictation never pays for
    // rewriting the whole file.
    const pruned = this.prune(lines);
    if (pruned.length === lines.length) {
      await appendFile(this.filePath, JSON.stringify(record) + "\n", "utf8");
    } else {
      await writeFile(this.filePath, pruned.map((line) => JSON.stringify(line)).join("\n") + "\n", "utf8");
    }
    // History holds everything the user dictated, which can be far more
    // sensitive than a transcript file suggests. Keep it owner-only, the same
    // mode as the token.
    await chmod(this.filePath, 0o600).catch(() => {});
    this.lines = pruned;
    return record;
  }

  /**
   * Drop entries outside the retention window and trim the oldest until the
   * file fits the byte ceiling.
   * @param {Array<object>} lines - current entries.
   * @returns {Array<object>} the retained entries.
   */
  prune(lines) {
    const cutoff = Date.now() - this.retentionDays * 24 * 60 * 60 * 1000;
    let kept = lines.filter((line) => typeof line.ts !== "number" || line.ts >= cutoff);
    let bytes = kept.reduce((total, line) => total + JSON.stringify(line).length + 1, 0);
    let from = 0;
    while (bytes > MAX_BYTES && from < kept.length) {
      bytes -= JSON.stringify(kept[from]).length + 1;
      from += 1;
    }
    if (from > 0) kept = kept.slice(from);
    return kept;
  }

  /**
   * Read the newest entries first.
   * @param {object} options - query options.
   * @returns {Promise<Array<object>>} up to `limit` entries, newest first.
   */
  async recent({ limit = 20 } = {}) {
    const lines = await this.load();
    return lines.slice(-limit).reverse();
  }

  /**
   * Replace words kept by older versions with digests, once: the apps keep their own
   * (encrypted) history, so this file only needs to show that something happened.
   * @returns {Promise<number>} how many entries were rewritten.
   */
  async scrubText() {
    const lines = (await this.load()).map(line => ({ ...line }));
    let changed = 0;
    for (const line of lines) {
      for (const key of ["raw", "text"]) {
        const value = line[key];
        if (typeof value === "string" && value.length > 0 && !/^sha256:[0-9a-f]{16}$/.test(value)) {
          line[key] = textDigest(value);
          changed += 1;
        }
      }
    }
    if (changed > 0) {
      const temporary = this.filePath + ".scrub.tmp";
      await writeFile(temporary, lines.map((line) => JSON.stringify(line)).join("\n") + "\n", { encoding: "utf8", mode: 0o600 });
      await rename(temporary, this.filePath);
      this.lines = lines;
      await chmod(this.filePath, 0o600).catch(() => {});
    }
    return changed;
  }

  /** Test seam: replace the in-memory view without touching disk. */
  seed(lines) {
    this.lines = lines;
  }
}
