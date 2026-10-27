/**
 * Style plugins are bounded JSON data. They provide wording instructions for natural
 * and AI cleanup; they cannot execute code or access local files. The official catalog
 * is read only when requested by a client. Managed legacy vocabulary packs are retired.
 */
import { mkdir, readFile, readdir, rename, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { createHash } from "node:crypto";
import { redactSecrets } from "./context.js";

export const PLUGIN_FORMAT = "typeleast-plugin";
export const CATALOG_FORMAT = "typeleast-catalog";

export const PLUGIN_LIMITS = {
  fileBytes: 256 * 1024,
  instructionsBytes: 8 * 1024,
  nameChars: 40,
  descriptionChars: 200,
  authorChars: 60,
  urlChars: 200,
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
  if (value.formatVersion !== 1) fail("formatVersion", "unsupported-version");
  if (value.type !== "style") return { ok: false, issues: [...issues, { path: "type", code: "unknown-type" }] };
  const allowed = FIELDS.style;
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

  const instructions = typeof value.instructions === "string" ? value.instructions.trim() : "";
    if (!instructions || Buffer.byteLength(instructions, "utf8") > PLUGIN_LIMITS.instructionsBytes || CONTROL.test(instructions)) fail("instructions", "invalid-instructions");
    else if (secretShaped(instructions)) fail("instructions", "secret-shaped");
  if (issues.length) return { ok: false, issues: issues.slice(0, 20) };
  return {
    ok: true,
    plugin: {
      format: PLUGIN_FORMAT, formatVersion: value.formatVersion, id: value.id, version: value.version, type: value.type,
      name: { "zh-Hans": value.name["zh-Hans"].trim(), en: value.name.en.trim() },
      description: { "zh-Hans": value.description["zh-Hans"].trim(), en: value.description.en.trim() },
      author: value.author.trim(), license: value.license,
      ...(value.homepage ? { homepage: value.homepage } : {}),
      instructions,
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
    instructions: plugin.instructions,
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
          vocabularyRemoved: parsed.vocabularyRemoved === true, technicalMigration: parsed.technicalMigration === true };
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
  async migrateTechnicalPack() {
    // A previous pack must never be reinstalled. Cleanup is retried after a failed write.
    if(this.state.vocabularyRemoved)return;
    await this.change(async()=>{
      const names=await readdir(this.dir);
      let incomplete=false;
      for(const name of names) {
        if(!name.endsWith('.typeleast-plugin'))continue;
        let value;try{value=JSON.parse(await readFile(join(this.dir,name),'utf8'));}catch{incomplete=true;continue;}
        if(value?.type==='dictionary') {await rm(join(this.dir,name));this.plugins.delete(value.id);delete this.state.plugins[value.id];this.problems=this.problems.filter(id=>id!==value.id);}
      }
      await rm(join(this.dir,'catalog-cache.json'),{force:true});
      this.state.vocabularyRemoved=!incomplete;this.state.technicalMigration=true;
    });
  }

  list() {
    return [...this.plugins.values()].sort((a, b) => a.id.localeCompare(b.id)).map((plugin) => ({
      ...summarize(plugin),
      source: this.state.plugins[plugin.id]?.source ?? "file",
      enabled: this.state.style === plugin.id,
    }));
  }

  /** Install or update; `enable` turns a pack on or selects a style. */
  install(plugin, { enable = false, source = "file" } = {}) {
    return this.change(async () => {
      if(plugin.type!=="style")throw Object.assign(new Error("unsupported plugin type"),{code:"plugin-invalid"});
      await this.writeAtomic(`${plugin.id}.typeleast-plugin`, JSON.stringify(plugin, null, 2) + "\n");
      this.plugins.set(plugin.id, plugin);
      this.state.plugins[plugin.id] = {source};
      if (plugin.type === "style" && enable) this.state.style = plugin.id;
    });
  }

  setEnabled() { throw Object.assign(new Error('dictionary packs removed'),{code:'plugin-not-found',status:404}); }

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
