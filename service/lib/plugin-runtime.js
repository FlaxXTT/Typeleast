/** Optional extension boundary. The core service only calls the methods on this object. */
import { relevantEntries } from "./dictionary-relevance.js";
import { relevantAliases, safePackTerms } from "./term-hints.js";
import { normalizeTermCase } from "./tidy.js";
import { CATALOG_SOURCE_MODES, fetchCatalog, parsePlugin, pluginDigest, PLUGIN_LIMITS, summarize } from "./plugins.js";

export class PluginRuntime {
  constructor(store, { fetchImpl, version = "0.2.0" } = {}) {
    this.store = store;
    this.fetchImpl = fetchImpl ?? globalThis.fetch;
    this.version = version;
    this.catalog = null;
  }

  style() {
    try { return this.store.activeStyle()?.instructions ?? null; }
    catch { return null; }
  }

  async context(own, texts, rawText) {
    const terms = safePackTerms(this.store.activeTerms() ?? []);
    const known = new Set(own.map(entry => entry.slice(entry.indexOf("=") + 1).trim().toLowerCase()));
    const entries = [...own];
    for (const term of terms) {
      const key = term.toLowerCase();
      if (!known.has(key)) { known.add(key); entries.push(term); }
    }
    return {
      entries: await relevantEntries(entries, texts),
      aliases: relevantAliases(this.store.activeAliases?.() ?? [], rawText, own),
    };
  }

  normalizeText(text, own) {
    try {
      const spellings = new Set(own.map(entry => entry.slice(entry.indexOf("=") + 1).trim().toLowerCase()));
      const terms = (this.store.activeCaseTerms?.() ?? []).filter(term => typeof term === "string" && !spellings.has(term.toLowerCase()));
      return normalizeTermCase(text, terms);
    } catch { return text; }
  }

  state() {
    return { plugins: this.store.list(), style: this.store.state.style ?? null, problems: this.store.problems ?? [] };
  }

  async refreshCatalog(mode = "auto") {
    try {
      this.catalog = await fetchCatalog({ fetchImpl: this.fetchImpl, version: this.version,
        mode: CATALOG_SOURCE_MODES.includes(mode) ? mode : "auto" });
      await this.store.saveCatalog(this.catalog).catch(() => {});
      return this.catalogView(true, null);
    } catch (error) {
      this.catalog ??= (await this.store.loadCatalog()) ?? null;
      return this.catalogView(false, error.code ?? "market-offline");
    }
  }

  catalogView(ok, code) {
    const installed = new Map(this.store.list().map(plugin => [plugin.id, plugin.version]));
    return {
      ok, ...(code ? { code } : {}),
      source: this.catalog?.source ?? null, mirrored: this.catalog?.mirrored === true,
      fetchedAt: this.catalog?.fetchedAt ?? null, rejected: this.catalog?.rejected ?? 0,
      plugins: (this.catalog?.plugins ?? []).map(plugin => ({ ...summarize(plugin), installedVersion: installed.get(plugin.id) ?? null })),
    };
  }

  async installFromCatalog(id, enable, digest) {
    const plugin = this.catalog?.plugins.find(entry => entry.id === id);
    if (!plugin) throw Object.assign(new Error("not in the catalog"), { code: "plugin-not-found" });
    if (typeof digest !== "string" || pluginDigest(plugin) !== digest) {
      throw Object.assign(new Error("the plugin changed after it was shown"), { code: "plugin-changed" });
    }
    await this.store.install(plugin, { enable, source: "catalog" });
    return this.state();
  }

  /** Called only after the core HTTP layer has checked Host and bearer token. */
  async handleHttp({ route, req, res, url, readBody, reply, maxJsonBytes }) {
    const jsonBody = async () => JSON.parse((await readBody(req, maxJsonBytes)).toString("utf8") || "{}") ?? {};
    const pluginFile = async () => parsePlugin((await readBody(req, PLUGIN_LIMITS.fileBytes)).toString("utf8"));
    const id = /^\/plugins\/([a-z0-9.-]{3,80})$/.exec(route)?.[1];
    if (route === "/plugins" && req.method === "GET") { reply(res, 200, this.state()); return true; }
    if ((route === "/plugins/inspect" || route === "/plugins") && req.method === "POST") {
      const parsed = await pluginFile();
      if (!parsed.ok) { reply(res, 400, { error: "not a valid plugin", code: "plugin-invalid", issues: parsed.issues }); return true; }
      if (route === "/plugins/inspect") {
        reply(res, 200, { plugin: summarize(parsed.plugin), installedVersion: this.store.plugins.get(parsed.plugin.id)?.version ?? null });
      } else {
        if (url.searchParams.get("digest") !== pluginDigest(parsed.plugin)) throw Object.assign(new Error("the plugin changed after it was shown"), { code: "plugin-changed" });
        await this.store.install(parsed.plugin, { enable: url.searchParams.get("enable") === "1", source: "file" });
        reply(res, 200, this.state());
      }
      return true;
    }
    if (route === "/plugins/catalog" && req.method === "GET") { reply(res, 200, await this.refreshCatalog(url.searchParams.get("sources") ?? "auto")); return true; }
    if (route === "/plugins/catalog/install" && req.method === "POST") {
      const body = await jsonBody();
      reply(res, 200, await this.installFromCatalog(String(body.id ?? ""), body.enable === true, body.digest));
      return true;
    }
    if (route === "/plugins/style" && req.method === "PUT") {
      const body = await jsonBody();
      await this.store.selectStyle(typeof body.id === "string" ? body.id : null);
      reply(res, 200, this.state());
      return true;
    }
    if (id && req.method === "PUT") {
      const body = await jsonBody();
      await this.store.setEnabled(id, body.enabled === true);
      reply(res, 200, this.state());
      return true;
    }
    if (id && req.method === "DELETE") {
      await this.store.remove(id);
      reply(res, 200, this.state());
      return true;
    }
    return false;
  }
}
