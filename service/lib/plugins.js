/**
 * Plugins, version 1: data only. A plugin is one JSON file (".typeleast-plugin") that is
 * either a dictionary pack (terms) or a style (extra wording/format instructions for
 * 标准/精简整理). Nothing in a plugin runs: the service checks the file, stores it, and at
 * dictation time adds the enabled packs' terms to the dictionary (still filtered to the
 * terms a dictation mentions) and the selected style's instructions to the one model call.
 *
 * The official catalog is a static file published from the repository (market/) and read
 * only from official addresses, only when the user opens the market.
 *
 * @module typeleast-service/plugins
 */
import { mkdir, readFile, readdir, rename, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { createHash } from "node:crypto";
import { redactSecrets } from "./context.js";
import { safeCaseTerms } from "./term-hints.js";

export const PLUGIN_FORMAT = "typeleast-plugin";
export const CATALOG_FORMAT = "typeleast-catalog";

export const PLUGIN_LIMITS = {
  fileBytes: 256 * 1024,
  terms: 2000,
  termChars: 120,
  aliases: 200,
  aliasChars: 80,
  aliasCues: 8,
  cueChars: 40,
  instructionsBytes: 8 * 1024,
  nameChars: 40,
  descriptionChars: 200,
  authorChars: 60,
  urlChars: 200,
  /** All enabled packs together. */
  enabledTerms: 10000,
  enabledAliases: 1000,
  catalogBytes: 2 * 1024 * 1024,
  catalogPlugins: 500,
};

/** The official addresses of the catalog, tried first. */
export const CATALOG_URLS = [
  "https://typeleast.promptking.workers.dev/market/catalog.json",
  "https://raw.githubusercontent.com/FlaxXTT/Typeleast/main/market/catalog.json",
];

/**
 * Public copies of the same file, for networks that block both official addresses (mainland
 * China): jsDelivr serves the GitHub file as it is, and the GitHub proxies are the ones the apps'
 * updater already uses. A mirror could change what it serves, so a catalog read through one is
 * marked `mirrored` and the apps say so before installing.
 */
export const CATALOG_MIRRORS = [
  "https://fastly.jsdelivr.net/gh/FlaxXTT/Typeleast@main/market/catalog.json",
  "https://cdn.jsdelivr.net/gh/FlaxXTT/Typeleast@main/market/catalog.json",
  ...["https://ghfast.top/", "https://gh-proxy.com/", "https://gh-proxy.org/", "https://gh.llkk.cc/"].map((proxy) => proxy + CATALOG_URLS[1]),
];

/** The apps' 更新来源 setting: auto (official, then mirrors), github (official only), mirror (mirrors first). */
export const CATALOG_SOURCE_MODES = ["auto", "github", "mirror"];

/** The addresses to try for one source mode, in order. */
export function catalogSources(mode = "auto") {
  const official = CATALOG_URLS.map((url) => ({ url, mirrored: false }));
  const mirrors = CATALOG_MIRRORS.map((url) => ({ url, mirrored: true }));
  if (mode === "github") return official;
  return mode === "mirror" ? [...mirrors, ...official] : [...official, ...mirrors];
}

const ID = /^[a-z0-9](?:[a-z0-9-]{0,30}[a-z0-9])?\.[a-z0-9](?:[a-z0-9-]{0,30}[a-z0-9])?$/;
const VERSION = /^(0|[1-9]\d{0,5})\.(0|[1-9]\d{0,5})\.(0|[1-9]\d{0,5})$/;
const LICENSE = /^(?:[A-Za-z0-9.+-]{1,40}|LicenseRef-[A-Za-z0-9.-]{1,40})$/;
const CONTROL = /[\u0000-\u0008\u000b-\u001f\u007f-\u009f]/u;
const FIELDS = {
  dictionary: ["format", "formatVersion", "id", "version", "type", "name", "description", "author", "license", "homepage", "terms"],
  style: ["format", "formatVersion", "id", "version", "type", "name", "description", "author", "license", "homepage", "instructions"],
};

const length = (s) => Array.from(s).length;
const secretShaped = (s) => redactSecrets(s) !== s;

/** "1.10.0" > "1.9.3", compared as numbers. */
export function compareVersions(a, b) {
  const x = a.split(".").map(Number), y = b.split(".").map(Number);
  for (let i = 0; i < 3; i++) if (x[i] !== y[i]) return x[i] - y[i];
  return 0;
}

/**
 * Check a parsed plugin file. Unknown fields, unknown types and anything over the limits
 * are refused, never trimmed to fit.
 * @returns {{ok: true, plugin: object} | {ok: false, issues: Array<{path: string, code: string}>}}
 */
export function validatePlugin(value) {
  const issues = [];
  const fail = (path, code) => { issues.push({ path, code }); };
  if (!value || typeof value !== "object" || Array.isArray(value)) return { ok: false, issues: [{ path: "", code: "not-an-object" }] };
  if (value.format !== PLUGIN_FORMAT) fail("format", "unknown-format");
  if (value.formatVersion !== 1 && !(value.formatVersion === 2 && value.type === "dictionary")) fail("formatVersion", "unsupported-version");
  if (!Object.hasOwn(FIELDS, value.type)) return { ok: false, issues: [...issues, { path: "type", code: "unknown-type" }] };
  const allowed = value.formatVersion === 2 && value.type === "dictionary" ? [...FIELDS.dictionary, "aliases"] : FIELDS[value.type];
  for (const key of Object.keys(value)) if (!allowed.includes(key)) fail(key, "unknown-field");
  if (typeof value.id !== "string" || !ID.test(value.id)) fail("id", "invalid-id");
  if (typeof value.version !== "string" || !VERSION.test(value.version)) fail("version", "invalid-version");
  for (const field of ["name", "description"]) {
    const text = value[field];
    const max = field === "name" ? PLUGIN_LIMITS.nameChars : PLUGIN_LIMITS.descriptionChars;
    if (!text || typeof text !== "object" || Array.isArray(text)) { fail(field, "missing-text"); continue; }
    for (const key of Object.keys(text)) if (key !== "zh-Hans" && key !== "en") fail(`${field}.${key}`, "unknown-field");
    for (const language of ["zh-Hans", "en"]) {
      const s = text[language];
      if (typeof s !== "string" || !s.trim() || length(s) > max || CONTROL.test(s) || /[\r\n]/.test(s)) fail(`${field}.${language}`, "invalid-text");
    }
  }
  if (typeof value.author !== "string" || !value.author.trim() || length(value.author) > PLUGIN_LIMITS.authorChars || CONTROL.test(value.author)) fail("author", "invalid-text");
  if (typeof value.license !== "string" || !LICENSE.test(value.license)) fail("license", "invalid-license");
  if (value.homepage !== undefined && (typeof value.homepage !== "string" || !/^https:\/\/[^\s]+$/.test(value.homepage) || value.homepage.length > PLUGIN_LIMITS.urlChars)) fail("homepage", "invalid-url");

  let terms;
  let instructions;
  let aliases;
  if (value.type === "dictionary") {
    if (!Array.isArray(value.terms) || value.terms.length === 0 || value.terms.length > PLUGIN_LIMITS.terms) fail("terms", "invalid-count");
    else {
      const seen = new Set();
      terms = [];
      value.terms.forEach((term, i) => {
        if (typeof term !== "string") return fail(`terms[${i}]`, "invalid-term");
        const t = term.trim();
        // Packs offer spellings only; "heard=word" rules stay the user's own.
        if (!t || length(t) > PLUGIN_LIMITS.termChars || t.length > PLUGIN_LIMITS.termChars || t.includes("=") || /[\r\n\t]/.test(t) || CONTROL.test(t)) return fail(`terms[${i}]`, "invalid-term");
        if (secretShaped(t)) return fail(`terms[${i}]`, "secret-shaped");
        const key = t.toLowerCase();
        if (seen.has(key)) return fail(`terms[${i}]`, "duplicate-term");
        seen.add(key);
        terms.push(t);
      });
    }
    if (value.formatVersion === 2) {
      aliases = [];
      if (value.aliases !== undefined && (!Array.isArray(value.aliases) || value.aliases.length > PLUGIN_LIMITS.aliases)) fail("aliases", "invalid-count");
      else if (Array.isArray(value.aliases)) {
        const heardKeys = new Set();
        value.aliases.forEach((alias, i) => {
          const path = `aliases[${i}]`;
          if (!alias || typeof alias !== "object" || Array.isArray(alias)) return fail(path, "invalid-alias");
          for (const key of Object.keys(alias)) if (!["heard", "term", "cues", "blockers"].includes(key)) fail(`${path}.${key}`, "unknown-field");
          const validText = (s, max) => typeof s === "string" && s.trim() === s && length(s) >= 2 && length(s) <= max &&
            /^[\p{L}\p{N}\p{M} ._+#/-]+$/u.test(s) && !secretShaped(s);
          if (!validText(alias.heard, PLUGIN_LIMITS.aliasChars)) fail(`${path}.heard`, "invalid-text");
          if (!validText(alias.term, PLUGIN_LIMITS.termChars) || !terms?.some(t => t === alias.term)) fail(`${path}.term`, "unknown-term");
          if (!Array.isArray(alias.cues) || alias.cues.length < 1 || alias.cues.length > PLUGIN_LIMITS.aliasCues ||
            alias.cues.some(cue => !validText(cue, PLUGIN_LIMITS.cueChars))) fail(`${path}.cues`, "invalid-cues");
          if (alias.blockers !== undefined && (!Array.isArray(alias.blockers) || alias.blockers.length > PLUGIN_LIMITS.aliasCues ||
            alias.blockers.some(cue => !validText(cue, PLUGIN_LIMITS.cueChars)))) fail(`${path}.blockers`, "invalid-blockers");
          if (typeof alias.heard === "string" && typeof alias.term === "string") {
            const key = `${alias.heard.toLowerCase()}=${alias.term.toLowerCase()}`;
            if (heardKeys.has(key)) fail(path, "duplicate-alias");
            heardKeys.add(key);
          }
          if (validText(alias.heard, PLUGIN_LIMITS.aliasChars) && validText(alias.term, PLUGIN_LIMITS.termChars) && Array.isArray(alias.cues) && alias.cues.every(cue => validText(cue, PLUGIN_LIMITS.cueChars)) &&
            (alias.blockers === undefined || (Array.isArray(alias.blockers) && alias.blockers.every(cue => validText(cue, PLUGIN_LIMITS.cueChars))))) {
            aliases.push({ heard: alias.heard, term: alias.term, cues: alias.cues, ...(alias.blockers ? { blockers: alias.blockers } : {}) });
          }
        });
      }
    }
  } else {
    instructions = typeof value.instructions === "string" ? value.instructions.trim() : "";
    if (!instructions || Buffer.byteLength(instructions, "utf8") > PLUGIN_LIMITS.instructionsBytes || CONTROL.test(instructions)) fail("instructions", "invalid-instructions");
    else if (secretShaped(instructions)) fail("instructions", "secret-shaped");
  }
  if (issues.length) return { ok: false, issues: issues.slice(0, 20) };
  return {
    ok: true,
    plugin: {
      format: PLUGIN_FORMAT, formatVersion: value.formatVersion, id: value.id, version: value.version, type: value.type,
      name: { "zh-Hans": value.name["zh-Hans"].trim(), en: value.name.en.trim() },
      description: { "zh-Hans": value.description["zh-Hans"].trim(), en: value.description.en.trim() },
      author: value.author.trim(), license: value.license,
      ...(value.homepage ? { homepage: value.homepage } : {}),
      ...(terms ? { terms, ...(value.formatVersion === 2 ? { aliases } : {}) } : { instructions }),
    },
  };
}

/** Parse and check a plugin file's text. */
export function parsePlugin(text) {
  if (typeof text !== "string" || Buffer.byteLength(text, "utf8") > PLUGIN_LIMITS.fileBytes) return { ok: false, issues: [{ path: "", code: "too-large" }] };
  let value;
  try { value = JSON.parse(text); } catch { return { ok: false, issues: [{ path: "", code: "invalid-json" }] }; }
  return validatePlugin(value);
}

/**
 * A fingerprint of a plugin's whole checked content. The app sends back the fingerprint of
 * what it showed, so a confirmation installs exactly that content and nothing newer.
 */
export function pluginDigest(plugin) {
  return createHash("sha256").update(JSON.stringify(plugin)).digest("hex");
}

/** What the app shows for a plugin: everything a user should see before turning it on. */
export function summarize(plugin) {
  return {
    id: plugin.id, digest: pluginDigest(plugin), version: plugin.version, type: plugin.type, name: plugin.name, description: plugin.description,
    author: plugin.author, license: plugin.license, homepage: plugin.homepage ?? null,
    ...(plugin.type === "dictionary"
      ? { termCount: plugin.terms.length, termsPreview: plugin.terms.slice(0, 30), ...(plugin.formatVersion === 2 ? { aliasCount: plugin.aliases.length, aliasesPreview: plugin.aliases.slice(0, 12) } : {}) }
      : { instructions: plugin.instructions }),
  };
}

/**
 * The installed plugins and their switches, in <state dir>/plugins: one file per plugin
 * plus state.json. Writes are whole-file replacements (temporary file, then rename) and
 * run one at a time, so a crash never leaves half a file behind.
 */
export class PluginStore {
  constructor(dir) {
    this.dir = dir;
    this.plugins = new Map();
    this.state = { formatVersion: 1, plugins: {}, style: null, technicalMigration: false };
    this.problems = [];
    this.queue = Promise.resolve();
  }

  async load() {
    this.plugins.clear();
    this.problems = [];
    try {
      const parsed = JSON.parse(await readFile(join(this.dir, "state.json"), "utf8"));
      if (parsed && typeof parsed === "object" && parsed.plugins && typeof parsed.plugins === "object") {
        this.state = { formatVersion: 1, plugins: parsed.plugins, style: typeof parsed.style === "string" ? parsed.style : null,
          technicalMigration: parsed.technicalMigration === true };
      }
    } catch { /* no state yet, or unreadable: start with every plugin off */ }
    let names = [];
    try { names = await readdir(this.dir); } catch { names = []; }
    for (const name of names) {
      if (!name.endsWith(".typeleast-plugin")) continue;
      const id = name.slice(0, -".typeleast-plugin".length);
      const result = parsePlugin(await readFile(join(this.dir, name), "utf8").catch(() => ""));
      if (result.ok && result.plugin.id === id) this.plugins.set(id, result.plugin);
      else this.problems.push(id);
    }
    if (this.state.style && this.plugins.get(this.state.style)?.type !== "style") this.state.style = null;
  }

  /** One change at a time; each change ends with the state on disk. */
  change(work) {
    const run = this.queue.then(async () => {
      await mkdir(this.dir, { recursive: true, mode: 0o700 });
      const result = await work();
      await this.writeAtomic("state.json", JSON.stringify(this.state, null, 2) + "\n");
      return result;
    });
    this.queue = run.catch(() => {});
    return run;
  }

  async writeAtomic(name, text) {
    const target = join(this.dir, name);
    const temporary = `${target}.${process.pid}.tmp`;
    await writeFile(temporary, text, { encoding: "utf8", mode: 0o600 });
    await rename(temporary, target);
  }

  /** One-time local upgrade. Never fetch the catalog or re-enable a user's disabled pack. */
  async migrateTechnicalPack(existingInstallation) {
    if (this.state.technicalMigration) return;
    let bundled = null;
    if (existingInstallation) {
      const text = await readFile(new URL('./bundled/typeleast.tech-terms.typeleast-plugin', import.meta.url), 'utf8');
      const parsed = parsePlugin(text);
      if (!parsed.ok || parsed.plugin.id !== 'typeleast.tech-terms') throw new Error('bundled terminology is invalid');
      bundled = parsed.plugin;
    }
    await this.change(async () => {
      if (bundled && !this.state.plugins[bundled.id]) {
        if (!this.plugins.has(bundled.id)) {
          this.checkTermBudget(bundled);
          await this.writeAtomic(`${bundled.id}.typeleast-plugin`, JSON.stringify(bundled, null, 2) + '\n');
          this.plugins.set(bundled.id, bundled);
        }
        this.state.plugins[bundled.id] = { source: 'bundled', enabled: true };
      }
      this.state.technicalMigration = true;
    });
  }

  list() {
    return [...this.plugins.values()].sort((a, b) => a.id.localeCompare(b.id)).map((plugin) => ({
      ...summarize(plugin),
      source: this.state.plugins[plugin.id]?.source ?? "file",
      enabled: plugin.type === "dictionary" ? this.state.plugins[plugin.id]?.enabled === true : this.state.style === plugin.id,
    }));
  }

  enabledTermCount(except) {
    let total = 0;
    for (const plugin of this.plugins.values()) {
      if (plugin.type === "dictionary" && plugin.id !== except && this.state.plugins[plugin.id]?.enabled) total += plugin.terms.length;
    }
    return total;
  }

  enabledAliasCount(except) {
    let total = 0;
    for (const plugin of this.plugins.values()) {
      if (plugin.type === "dictionary" && plugin.id !== except && this.state.plugins[plugin.id]?.enabled) total += plugin.aliases?.length ?? 0;
    }
    return total;
  }

  checkTermBudget(plugin) {
    if (plugin.terms.length + this.enabledTermCount(plugin.id) > PLUGIN_LIMITS.enabledTerms) {
      throw Object.assign(new Error("too many enabled terms"), { code: "plugin-terms-limit", status: 409 });
    }
    if ((plugin.aliases?.length ?? 0) + this.enabledAliasCount(plugin.id) > PLUGIN_LIMITS.enabledAliases) {
      throw Object.assign(new Error("too many enabled pronunciation aliases"), { code: "plugin-aliases-limit", status: 409 });
    }
  }

  /** Install or update; `enable` turns a pack on or selects a style. */
  install(plugin, { enable = false, source = "file" } = {}) {
    return this.change(async () => {
      const wasEnabled = plugin.type === "dictionary" ? this.state.plugins[plugin.id]?.enabled === true : this.state.style === plugin.id;
      const on = enable || wasEnabled;
      if (plugin.type === "dictionary" && on) this.checkTermBudget(plugin);
      await this.writeAtomic(`${plugin.id}.typeleast-plugin`, JSON.stringify(plugin, null, 2) + "\n");
      this.plugins.set(plugin.id, plugin);
      this.state.plugins[plugin.id] = { source, ...(plugin.type === "dictionary" ? { enabled: on } : {}) };
      if (plugin.type === "style" && enable) this.state.style = plugin.id;
    });
  }

  setEnabled(id, enabled) {
    return this.change(async () => {
      const plugin = this.plugins.get(id);
      if (!plugin || plugin.type !== "dictionary") throw Object.assign(new Error("no such pack"), { code: "plugin-not-found", status: 404 });
      if (enabled) this.checkTermBudget(plugin);
      this.state.plugins[id] = { ...this.state.plugins[id], enabled: Boolean(enabled) };
    });
  }

  selectStyle(id) {
    return this.change(async () => {
      if (id !== null && this.plugins.get(id)?.type !== "style") throw Object.assign(new Error("no such style"), { code: "plugin-not-found", status: 404 });
      this.state.style = id;
    });
  }

  remove(id) {
    return this.change(async () => {
      if (!this.plugins.has(id)) throw Object.assign(new Error("not installed"), { code: "plugin-not-found", status: 404 });
      await rm(join(this.dir, `${id}.typeleast-plugin`), { force: true });
      this.plugins.delete(id);
      delete this.state.plugins[id];
      if (this.state.style === id) this.state.style = null;
    });
  }

  /** Keep the last catalog read from an official address, to show it offline. */
  async saveCatalog(catalog) {
    await mkdir(this.dir, { recursive: true, mode: 0o700 });
    await this.writeAtomic("catalog-cache.json", JSON.stringify(catalog) + "\n");
  }

  /** The last catalog read, checked again (null when there is none). */
  async loadCatalog() {
    try {
      const cached = JSON.parse(await readFile(join(this.dir, "catalog-cache.json"), "utf8"));
      return { ...validateCatalog({ format: CATALOG_FORMAT, formatVersion: 1, generatedAt: cached.generatedAt, plugins: cached.plugins }),
        source: typeof cached.source === "string" ? cached.source : null, fetchedAt: typeof cached.fetchedAt === "string" ? cached.fetchedAt : null };
    } catch {
      return null;
    }
  }

  /** Terms of the enabled packs, for the dictionary of one call. */
  activeTerms() {
    const out = [];
    for (const plugin of this.plugins.values()) {
      if (plugin.type === "dictionary" && this.state.plugins[plugin.id]?.enabled) out.push(...plugin.terms);
    }
    return out;
  }

  /** Bounded, literal pronunciation hints from enabled version-2 packs. */
  activeAliases() {
    const out = [];
    for (const plugin of this.plugins.values()) {
      if (plugin.type === "dictionary" && plugin.formatVersion === 2 && this.state.plugins[plugin.id]?.enabled) out.push(...plugin.aliases);
    }
    return out;
  }

  /** Version-2 terms are curated for safe exact-token capitalisation in raw mode. */
  activeCaseTerms() {
    const out = new Map();
    for (const plugin of this.plugins.values()) {
      if (plugin.type === "dictionary" && plugin.formatVersion === 2 && this.state.plugins[plugin.id]?.enabled) {
        for (const term of safeCaseTerms(plugin.terms)) if (!out.has(term.toLowerCase())) out.set(term.toLowerCase(), term);
      }
    }
    return [...out.values()];
  }

  /** The selected style, if any. */
  activeStyle() {
    const plugin = this.state.style ? this.plugins.get(this.state.style) : null;
    return plugin?.type === "style" ? plugin : null;
  }
}

/** Read a response body, refusing more than `limit` bytes. */
async function readLimited(response, limit) {
  const declared = Number(response.headers?.get?.("content-length"));
  if (Number.isFinite(declared) && declared > limit) throw Object.assign(new Error("catalog too large"), { code: "market-too-large" });
  if (!response.body?.getReader) {
    const text = await response.text();
    if (Buffer.byteLength(text, "utf8") > limit) throw Object.assign(new Error("catalog too large"), { code: "market-too-large" });
    return text;
  }
  const reader = response.body.getReader();
  const chunks = [];
  let size = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > limit) { await reader.cancel().catch(() => {}); throw Object.assign(new Error("catalog too large"), { code: "market-too-large" }); }
    chunks.push(value);
  }
  return Buffer.concat(chunks.map((c) => Buffer.from(c))).toString("utf8");
}

/** Check a parsed catalog; plugins that fail the checks are left out and counted. */
export function validateCatalog(value) {
  if (!value || typeof value !== "object" || value.format !== CATALOG_FORMAT || value.formatVersion !== 1 || !Array.isArray(value.plugins)) {
    throw Object.assign(new Error("not a catalog"), { code: "market-protocol-unsupported" });
  }
  if (value.plugins.length > PLUGIN_LIMITS.catalogPlugins) throw Object.assign(new Error("catalog too large"), { code: "market-too-large" });
  const plugins = [];
  const seen = new Set();
  let rejected = 0;
  for (const entry of value.plugins) {
    const result = validatePlugin(entry);
    if (!result.ok || seen.has(result.plugin.id)) { rejected++; continue; }
    seen.add(result.plugin.id);
    plugins.push(result.plugin);
  }
  return { generatedAt: typeof value.generatedAt === "string" ? value.generatedAt.slice(0, 40) : null, plugins, rejected };
}

/**
 * Read the catalog from the first address that answers with a valid one. The next address is
 * tried only when the previous ones failed or stayed silent for `staggerMs`, so a working official
 * address is the only one contacted and a blocked one costs seconds, not a full timeout. No
 * redirects; nothing is sent but a user agent.
 */
export async function fetchCatalog({ fetchImpl = globalThis.fetch, version = "0", mode = "auto", urls, timeoutMs = 20000, staggerMs = 2000 } = {}) {
  const sources = urls ? urls.map((url) => ({ url, mirrored: false })) : catalogSources(mode);
  const read = async ({ url, mirrored }, signal) => {
    const response = await fetchImpl(url, {
      method: "GET", redirect: "error", signal,
      headers: { accept: "application/json", "user-agent": `TypeLeast/${version}` },
    });
    if (!response.ok) throw Object.assign(new Error(`HTTP ${response.status}`), { code: "market-offline" });
    const catalog = validateCatalog(JSON.parse(await readLimited(response, PLUGIN_LIMITS.catalogBytes)));
    return { ...catalog, source: new URL(url).host, mirrored, fetchedAt: new Date().toISOString() };
  };
  return await new Promise((resolve, reject) => {
    const controllers = [];
    let next = 0, running = 0, done = false, lastError = null, stagger = null;
    const finish = (catalog) => {
      if (done) return;
      done = true;
      clearTimeout(deadline); clearTimeout(stagger);
      for (const controller of controllers) controller.abort();
      if (catalog) resolve(catalog);
      else {
        const code = lastError?.code && String(lastError.code).startsWith("market-") ? lastError.code : "market-offline";
        reject(Object.assign(new Error("catalog unavailable"), { code }));
      }
    };
    const deadline = setTimeout(() => finish(null), timeoutMs);
    const start = () => {
      if (done || next >= sources.length) return;
      clearTimeout(stagger);
      const controller = new AbortController();
      controllers.push(controller);
      running++;
      read(sources[next++], controller.signal).then(finish, (error) => {
        running--;
        if (done) return;
        lastError = error;
        if (next < sources.length) start();
        else if (running === 0) finish(null);
      });
      if (next < sources.length) stagger = setTimeout(start, staggerMs);
    };
    start();
  });
}
