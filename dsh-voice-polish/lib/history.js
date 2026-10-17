/**
 * Dictation history: an append-only JSONL file under the DSH home.
 *
 * History is the safety net for this feature: every attempt is recorded before
 * the caller inserts anything, so a failed paste, an offline service or a
 * rejected rewrite is always recoverable.
 *
 * @module dsh-voice-polish/history
 */
import { appendFile, chmod, mkdir, readFile, stat, writeFile } from "node:fs/promises";
import { randomUUID } from "node:crypto";
import { dirname } from "node:path";

/** Soft size ceiling; older lines are dropped once the file exceeds it. */
const MAX_BYTES = 5 * 1024 * 1024;

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
    } catch {
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

  /** Test seam: replace the in-memory view without touching disk. */
  seed(lines) {
    this.lines = lines;
  }
}
