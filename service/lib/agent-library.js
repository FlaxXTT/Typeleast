import { constants } from "node:fs";
import { access, lstat, readdir, realpath, rm } from "node:fs/promises";
import { homedir } from "node:os";
import { basename, dirname, extname, isAbsolute, join } from "node:path";
import { isDeepStrictEqual } from "node:util";
import { redactSecrets } from "./context.js";
import { configObject, editConfig, fingerprint, readLocal, replaceLocal } from "./agent-config.js";
import { githubLibrary } from "./github-library.js";
import { isIndependentSpeak, isMarkdownFile, isSkillReference, maxSkillBytes, parseSpeak, readSpeak, slimSkillMarkdown } from "./skill-import.js";
import { readSkillMarkdown, saveSkillMarkdown } from "./skill-markdown.js";
import { discoverLocalSkills } from "./skill-discovery.js";
import { readArchivedSkill, stageArchivedSkill, stageSkillFiles } from "./skill-archive.js";
import { isSkillPackage, readSkillPackage, stageSkillPackage } from "./skill-package.js";
import { speakDescription, speakExcerpt, speakNameSuggestion, speakWheelPreview, SPEAK_BATCH_SIZE, SPEAK_CATEGORIES } from "./tasks/speak.js";

const object = (value) => value && typeof value === "object" && !Array.isArray(value) ? value : {};
const list = (value) => Array.isArray(value) ? value : [];
const safeName = (value) => typeof value === "string" && /^[a-zA-Z0-9][a-zA-Z0-9_. -]{0,79}$/u.test(value)
  && !["__proto__", "prototype", "constructor"].includes(value);
const names = { codex: "Codex", claude: "Claude Code", opencode: "OpenCode", hermes: "Hermes" };
const maxLibraryBytes = 24 * 1024 * 1024;
const present = path => access(path).then(() => true, () => false);
const map = (value) => Object.entries(object(value));
const label = (text) => typeof text === "string" ? redactSecrets(text).replace(/[\p{Cc}\p{Cf}]/gu, " ").trim().slice(0, 160) : "";

function root(env, key, fallback) {
  return isAbsolute(env[key] ?? "") ? env[key] : fallback;
}

// Assignment looks up a configuration only for an explicitly chosen target.
function agentDefinition(id, home, env, project) {
  switch (id) {
    case "codex": {
      const codex = root(env, "CODEX_HOME", join(home, ".codex"));
      return { id, format: "toml", mcp: "mcp_servers", path: join(codex, "config.toml"),
        project: project && { path: join(project, ".codex", "config.toml") } };
    }
    case "claude":
      return { id, format: "json", mcp: "mcpServers", path: join(home, ".claude.json"),
        project: project && { path: join(project, ".mcp.json") } };
    case "opencode": {
      const open = root(env, "OPENCODE_CONFIG_DIR", join(root(env, "XDG_CONFIG_HOME", join(home, ".config")), "opencode"));
      return { id, format: "jsonc", mcp: "mcp", path: env.OPENCODE_CONFIG && isAbsolute(env.OPENCODE_CONFIG) ? env.OPENCODE_CONFIG : undefined,
        paths: [join(open, "opencode.jsonc"), join(open, "opencode.json")], defaultPath: join(open, "opencode.json"),
        project: project && { paths: [join(project, "opencode.jsonc"), join(project, "opencode.json"),
          join(project, ".opencode", "opencode.jsonc"), join(project, ".opencode", "opencode.json")] } };
    }
    case "hermes":
      return { id, format: "yaml", mcp: "mcp_servers", path: join(root(env, "HERMES_HOME", join(home, ".hermes")), "config.yaml") };
    default:
      return null;
  }
}

async function configPath(location) {
  if (location?.path) return location.path;
  for (const path of location?.paths ?? []) if (await present(path)) return path;
  return location?.defaultPath ?? location?.paths?.[0];
}

function mcpTransport(raw) {
  if (typeof raw.url === "string") {
    let url;
    try { url = new URL(raw.url); } catch { return null; }
    if (!["http:", "https:"].includes(url.protocol) || url.username || url.password || url.search || url.hash
        || (url.protocol === "http:" && !["localhost", "127.0.0.1", "[::1]"].includes(url.hostname))) return null;
    return { url: url.href };
  }
  const [command, ...args] = Array.isArray(raw.command) ? raw.command : [raw.command, ...list(raw.args)];
  if (typeof command !== "string" || !command.length || command.length > 512 || /[\p{Cc}\p{Cf}]/u.test(command) ||
      args.length > 48 || args.some(arg => typeof arg !== "string" || arg.length > 1024 || /[\p{Cc}]/u.test(arg))) return null;
  return { command, args };
}

function requiresAuthorization(raw) {
  return ["env", "environment", "headers", "http_headers", "env_http_headers", "bearer_token_env_var",
    "oauth", "oauthClientId", "apiKey", "api_key", "token"].some(key =>
    raw[key] !== undefined && raw[key] !== false && (typeof raw[key] !== "object" || Object.keys(raw[key] ?? {}).length > 0));
}

function portableMcp(raw) {
  const supportedFields = new Set(["command", "args", "url", "description", "type", "enabled", "disabled"]);
  if (Object.keys(raw).some(key => !supportedFields.has(key)) || requiresAuthorization(raw)) return null;
  if (raw.type && !["stdio", "http", "local", "remote", "streamable-http"].includes(raw.type)) return null;
  const transport = mcpTransport(raw);
  // Arguments sometimes contain passwords even when the configuration has no env block.
  if (transport?.args?.some(arg => /(?:key|token|password|secret|credential|authorization|bearer|:\/\/[^/ ]*@)/iu.test(arg))) return null;
  return transport;
}

function mcpEntries(agent, doc) {
  const settings = object(doc[agent.mcp]);
  if (agent.id !== "opencode") return { path: [agent.mcp], settings };
  if (Object.hasOwn(settings, "servers") || !Object.keys(settings).some(key => object(settings[key]).type)) {
    return { path: [agent.mcp, "servers"], settings: object(settings.servers) };
  }
  return { path: [agent.mcp], settings };
}

const emptyLibrary = () => ({ skills: [], servers: [], managed: [] });

async function readLibrary(path) {
  const previous = await readLocal(path, maxLibraryBytes);
  const library = previous ? JSON.parse(previous.text) : emptyLibrary();
  if (!["skills", "servers", "managed"].every(key => Array.isArray(library[key]))) throw new Error("invalid-library");
  library.servers = library.servers.map(({ raw, portable, ...item }) => {
    if (raw && !item.configurationID && portable === true) item.configurationID = fingerprint(JSON.stringify(raw));
    return item;
  });
  delete library.mcpChecks;
  return { previous, library };
}

async function writeLibrary(path, previous, library) {
  const text = JSON.stringify(library);
  if (Buffer.byteLength(text) > maxLibraryBytes) throw new Error("library-full");
  await replaceLocal(path, previous, text, { maxBytes: maxLibraryBytes });
}

function mergeSkills(library, selected) {
  const known = new Map(library.skills.map(item => [item.id, item]));
  let added = 0;
  let changed = false;
  for (const item of selected) {
    const earlier = known.get(item.id);
    if (!earlier) {
      known.set(item.id, { ...item, imported: true });
      added += 1;
      changed = true;
      continue;
    }
    const origins = list(earlier.sources);
    const extra = item.sources.filter(source => !origins.some(s => s.agent === source.agent && s.path === source.path));
    const visible = isIndependentSpeak(earlier) || isSkillReference(earlier);
    if (!visible || extra.length || item.savedMarkdownPath && item.savedMarkdownPath !== earlier.savedMarkdownPath
        || item.markdownDigest && item.markdownDigest !== earlier.markdownDigest
        || isSkillReference(item) && !isDeepStrictEqual(item, earlier)) {
      // A validated file may re-enable a previously hidden snapshot with the same text.
      known.set(item.id, { ...(isSkillReference(item) ? {} : earlier), ...item,
        ...(earlier.nameReview ? { nameReview: earlier.nameReview } : {}),
        ...(earlier.ignored === true ? { ignored: true } : {}), sources: [...origins, ...extra] });
      changed = true;
      if (!visible) added += 1;
    }
  }
  if (changed) library.skills = [...known.values()];
  return { added, changed };
}

const importFormats = new Map([
  [".json", "jsonc"], [".jsonc", "jsonc"], [".mcp", "jsonc"], [".yaml", "yaml"], [".yml", "yaml"], [".toml", "toml"],
]);
const hasMcpConnection = raw => typeof raw?.url === "string" || typeof raw?.command === "string" || Array.isArray(raw?.command);
const utf8 = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true });

function fileMcpEntries(doc, path) {
  const name = basename(path, extname(path));
  const namedMcp = /(?:^|[._-])mcp(?:$|[._-])/iu.test(basename(path));
  const wrapped = [doc.mcpServers, doc.mcp_servers, doc.mcp?.servers ?? doc.mcp];
  if (doc.servers && (namedMcp || Object.keys(doc).every(key => ["servers", "inputs"].includes(key)))) wrapped.push(doc.servers);
  if (wrapped.some(value => value !== undefined)) {
    return wrapped.flatMap(value => map(value).filter(([, raw]) => hasMcpConnection(raw)));
  }
  const { name: title, ...raw } = doc;
  if (hasMcpConnection(raw) && (namedMcp || typeof title === "string" && typeof raw.type === "string")) {
    return [[title ?? name, raw]];
  }
  return namedMcp ? map(doc).filter(([, entry]) => hasMcpConnection(entry)) : [];
}

function importedFileServer(name, raw, path) {
  if (!safeName(name)) return null;
  // VS Code's inputs and standard interpolation are resolved by its own host.
  const needsInput = [raw.url, raw.command, ...list(raw.command), ...list(raw.args)]
    .some(value => typeof value === "string" && /\$\{(?:input|env|command):[^}]+\}/u.test(value));
  const configuration = { ...raw };
  // Some exporters include empty env and headers maps for servers that need no credentials.
  for (const field of ["env", "headers"]) {
    const value = object(raw[field]);
    if (value === raw[field] && !Object.keys(value).length) delete configuration[field];
  }
  const transport = needsInput ? null : portableMcp(configuration);
  const catalogDescription = label(raw.description);
  return { id: "library-mcp:" + fingerprint(name), kind: "mcp", name, imported: true,
    ...(catalogDescription ? { catalogDescription } : {}),
    ...(transport ? { configurationID: fingerprint(JSON.stringify(transport)) } : {}),
    sources: [{ agent: "manual", path }], enabled: raw.enabled !== false && raw.disabled !== true,
    authorization: needsInput || requiresAuthorization(raw) };
}

async function scanLocalMcps(library, home, env) {
  const agents = Object.entries(names).map(([id, name]) => ({ ...agentDefinition(id, home, env), name }));
  const support = join(home, "Library", "Application Support");
  agents.push(
    { id: "claude-desktop", name: "Claude Desktop", format: "jsonc", mcp: "mcpServers",
      path: join(support, "Claude", "claude_desktop_config.json") },
    { id: "vscode", name: "VS Code", format: "jsonc", mcp: "servers", path: join(support, "Code", "User", "mcp.json") },
    { id: "cursor", name: "Cursor", format: "jsonc", mcp: "mcpServers", path: join(home, ".cursor", "mcp.json") },
  );
  const existing = new Map(library.servers.map(item => [item.id, item]));
  const sources = await Promise.all(agents.map(async agent => {
    const paths = new Set([await configPath(agent), ...(agent.paths ?? [])].filter(Boolean));
    return (await Promise.all([...paths].map(async path => {
      try {
        const file = await readLocal(path, undefined, { follow: true });
        if (!file) return [];
        const { settings } = mcpEntries(agent, configObject(agent.format, file.text));
        return map(settings).flatMap(([name, value]) => {
          const raw = object(value);
          if (!hasMcpConnection(raw)) return [];
          const item = importedFileServer(name, raw, path);
          if (!item || existing.get(item.id)?.sources.some(source => source.path === path)) return [];
          item.sources = [{ agent: agent.id, path }];
          const selectionID = fingerprint(JSON.stringify([agent.id, path, name]));
          return [{ row: { selectionID, path, name, kind: "mcp", dependencies: false,
            authorization: item.authorization, enabled: item.enabled, providers: [agent.name] },
          items: [item], digest: fingerprint(JSON.stringify(raw)) }];
        });
      } catch { return []; }
    }))).flat();
  }));
  return sources.flat().sort((a, b) => a.row.name.localeCompare(b.row.name) ||
    a.row.providers[0].localeCompare(b.row.providers[0]) || a.row.path.localeCompare(b.row.path));
}

async function importCandidates(paths, { allowDirectories, applications }) {
  const candidates = new Map();
  for (const chosen of new Set(list(paths).filter(value => typeof value === "string" && isAbsolute(value)))) {
    let path = chosen;
    try {
      const archived = chosen.includes(".asar/") ? await readArchivedSkill(applications, chosen) : null;
      if (!archived && allowDirectories && (await lstat(path)).isDirectory()) path = join(path, "SKILL.md");
      if (candidates.has(path)) continue;
      const packaged = !archived && isSkillPackage(path) ? await readSkillPackage(path) : null;
      const skill = archived ? parseSpeak(path, archived.text, archived.children) :
        packaged ? parseSpeak(packaged.manifestPath, packaged.text, packaged.children) :
          isMarkdownFile(path) ? await readSpeak(path) : null;
      if (skill) {
        const { item, fields, usesFiles, relatedFiles, digest, markdown } = skill;
        if (packaged) {
          const resources = packaged.children.filter(name => !/^(?:SKILL\.md|readme|licen[cs]e|copying|notice)(?:\.[a-z0-9]+)?$/iu.test(name));
          item.dependencies ||= resources.length > 0;
          for (const resource of resources) if (!relatedFiles.includes(resource) && relatedFiles.length < 12) relatedFiles.push(resource);
        }
        candidates.set(path, { row: { path, name: item.name, kind: "skill",
          dependencies: item.dependencies, fields, usesFiles, relatedFiles, canSaveMarkdown: !item.dependencies && markdown != null,
          ...(packaged && extname(path).toLowerCase() === ".skill" ? { providers: ["ChatGPT"] } : {}) },
          items: [item], digest: archived?.digest ?? packaged?.digest ?? digest, markdown,
          archiveKind: archived ? "asar" : packaged ? "package" : null });
        continue;
      }
      const format = importFormats.get(extname(path).toLowerCase()) ??
        (["mcp", ".mcp"].includes(basename(path).toLowerCase()) ? "jsonc" : undefined);
      const file = format ? await readLocal(path) : null;
      const items = file ? fileMcpEntries(configObject(format, file.text), path)
        .map(([name, raw]) => importedFileServer(name, raw, path)).filter(Boolean) : [];
      if (items.length) {
        candidates.set(path, { row: { path, name: basename(path), kind: "mcp",
          dependencies: false }, items, digest: fingerprint(file.text) });
        continue;
      }
    } catch { /* Show unreadable or unsupported selections without importing them. */ }
    candidates.set(path, { row: { path, name: basename(path), kind: "unknown", dependencies: false }, items: [] });
  }
  return [...candidates.values()];
}

function importProof(options) {
  return fingerprint(JSON.stringify(options.map(({ row, digest }) => [row, digest])));
}

function registryMcpEntries(doc) {
  const name = typeof doc.name === "string" ? doc.name.split("/").at(-1) : "";
  const remotes = list(doc.remotes);
  const remote = remotes.find(item => item?.type === "streamable-http" && typeof item.url === "string")
    ?? remotes.find(item => item?.type === "sse" && typeof item.url === "string");
  if (remote && safeName(name)) return [[name, { ...remote, description: doc.description }]];
  if (list(doc.packages).length && safeName(name)) return [[name, { packages: doc.packages, description: doc.description }]];
  return [];
}

async function githubImportOptions(repo, kind) {
  if (kind === "skill") {
    return repo.candidates.filter(entry => isMarkdownFile(entry.path)).map(entry => {
      const path = repo.identity(entry);
      const folder = dirname(entry.path);
      const name = basename(entry.path).toLowerCase() === "skill.md" ? folder === "." ? repo.repo : basename(folder)
        : basename(entry.path, extname(entry.path));
      return { row: { path, name, kind: "skill", dependencies: false, selectionID: fingerprint(path), providers: ["GitHub"] },
        digest: entry.sha, entry };
    });
  }
  const options = await Promise.all(repo.candidates.map(async entry => {
    const format = importFormats.get(extname(entry.path).toLowerCase());
    if (!format) return [];
    const contents = await repo.file(entry, 512 * 1024);
    let doc;
    try { doc = configObject(format, utf8.decode(contents)); }
    catch { return []; }
    const servers = basename(entry.path).toLowerCase() === "server.json" ? registryMcpEntries(doc) : [];
    return (servers.length ? servers : fileMcpEntries(doc, entry.path)).slice(0, 80).flatMap(([name, raw]) => {
      const path = repo.permalink(entry);
      const item = importedFileServer(name, raw, path);
      if (!item) return [];
      item.sources = [{ agent: "github", path }];
      return [{ row: { path, name, kind: "mcp", dependencies: false, authorization: item.authorization,
        enabled: item.enabled, selectionID: fingerprint(JSON.stringify([repo.identity(entry), name])), providers: ["GitHub"] },
      items: [item], digest: entry.sha }];
    });
  }));
  const rows = [...new Map(options.flat().map(option => [option.row.selectionID, option])).values()];
  if (rows.length > 200) throw new Error("github-too-large");
  return rows;
}

async function githubSkillItems(repo, selected, storage) {
  const bundles = selected.map(option => ({ option, files: repo.skillFiles(option.entry) }));
  const totalBytes = bundles.reduce((total, { files }) => total + files.reduce((sum, file) => sum + file.size, 0), 0);
  if (totalBytes > 32 * 1024 * 1024 || bundles.length > 30) throw new Error("github-too-large");
  const downloaded = [];
  for (const { option, files } of bundles) {
    const manifest = await repo.file(option.entry, maxSkillBytes);
    const folder = dirname(option.entry.path);
    const relativePath = path => folder === "." ? path : path.slice(folder.length + 1);
    const children = files.filter(file => file.path !== option.entry.path).map(file => relativePath(file.path).split("/")[0]);
    let markdown, parsed;
    try {
      markdown = utf8.decode(manifest);
      parsed = parseSpeak(join(repo.repo, option.entry.path), markdown, children);
    }
    catch { /* The remote file is not a readable Skill. */ }
    if (!parsed) throw new Error("github-no-skill");
    const { item } = parsed;
    item.dependencies ||= children.some(child => !/^(?:readme|licen[cs]e|copying|notice)(?:\.[a-z0-9]+)?$/iu.test(child));
    item.sources = [{ agent: "github", path: repo.permalink(option.entry) }];
    if (!item.dependencies) {
      downloaded.push({ option, item, markdown: slimSkillMarkdown(markdown) });
      continue;
    }
    const resources = files.filter(file => file.path !== option.entry.path);
    const packaged = [["SKILL.md", manifest]];
    for (let index = 0; index < resources.length; index += 6) {
      packaged.push(...await Promise.all(resources.slice(index, index + 6).map(async file =>
        [relativePath(file.path), await repo.file(file, 24 * 1024 * 1024)])));
    }
    const digest = fingerprint(JSON.stringify(files.map(file => [file.path, file.sha])));
    downloaded.push({ option, item, digest, packaged });
  }
  const imported = [];
  for (const { option, item, markdown, digest, packaged } of downloaded) {
    if (packaged) {
      const path = await stageSkillFiles(storage, option.row.path, digest, packaged);
      item.sources.unshift({ agent: "manual", path });
    }
    imported.push({ row: { ...option.row, dependencies: item.dependencies }, items: [item], markdown });
  }
  return imported;
}

function importFiles(library, options, modes) {
  const summary = { skills: 0, skillReferences: 0, mcp: 0, references: 0, duplicates: 0, conflicts: 0, skipped: 0, dependentSkills: 0 };
  const skills = [];
  const servers = new Map(library.servers.map(item => [item.id, item]));
  let changed = false;
  for (const { row, items } of options) {
    const { path, dependencies } = row;
    const mode = modes?.[row.selectionID ?? path] ?? (modes ? "skip" : "full");
    if (row.kind === "unknown") { summary.skipped += 1; continue; }
    if (row.kind === "skill") {
      if (mode === "reference" || (mode === "full" && modes && dependencies)) {
        const { body, ...entry } = items[0];
        const reference = { ...entry, id: "skill-ref:" + fingerprint(path), importMode: mode === "reference" ? "reference" : "linked" };
        if (mode === "full") reference.body = body;
        skills.push(reference);
      } else if (mode === "full" && !dependencies) skills.push(items[0]);
      else if (mode === "full" && dependencies) summary.dependentSkills += 1;
    } else if (mode === "full") {
      for (const item of items) {
        const earlier = servers.get(item.id);
        if (!earlier) {
          servers.set(item.id, item);
          summary.mcp += 1;
          changed = true;
        } else if (earlier.configurationID === item.configurationID && earlier.authorization === item.authorization
                   && earlier.enabled === item.enabled
                   && (item.configurationID || earlier.sources.some(source => source.path === path))) {
          summary.duplicates += 1;
          if (!earlier.sources.some(source => source.path === path)) {
            servers.set(item.id, { ...earlier, sources: [...earlier.sources, ...item.sources] });
            changed = true;
          }
        } else {
          summary.conflicts += 1;
        }
      }
    }
  }
  const previousIds = new Set(library.skills.filter(isSkillReference).map(item => item.id));
  const merged = mergeSkills(library, skills);
  summary.skillReferences = new Set(skills.filter(item => isSkillReference(item) && !previousIds.has(item.id)).map(item => item.id)).size;
  summary.skills = merged.added - summary.skillReferences;
  summary.duplicates += skills.length - merged.added;
  if (changed) library.servers = [...servers.values()];
  const speakIds = [...new Set(skills.filter(isIndependentSpeak).map(item => item.id))]
    .filter(id => !library.skills.find(item => item.id === id)?.catalog);
  if (!modes) delete summary.skillReferences;
  return { summary, speakIds, changed: changed || merged.changed };
}

function storedItems(library) {
  const items = [...library.skills.filter(item => isIndependentSpeak(item) || isSkillReference(item)),
    ...library.servers.filter(item => item.kind === "mcp")];
  const seen = new Set(items.map(item => item.id));
  // Keep previously assigned MCPs available for undo even if their source was discovered by an older version.
  for (const record of library.managed) {
    if (record.kind !== "mcp" || record.removed === true || seen.has(record.item)) continue;
    items.push({ id: record.item, kind: "mcp", name: record.name, ignored: record.ignored,
      sources: [{ agent: record.agent, path: record.path }] });
    seen.add(record.item);
  }
  return items;
}

function canOrganizeItem(item) {
  return isIndependentSpeak(item) || isSkillReference(item) || (item.kind === "mcp" && item.imported === true);
}

function skillDisplayName(item) {
  return (item.nameReview?.status === "accepted" ? item.nameReview.value : null) ?? item.catalog?.name ?? item.name;
}

function publicItem(item, showSuggestions = false) {
  const { body, configurationID, catalog, markdownDigest, catalogDescription, nameReview, ...visible } = item;
  if (item.kind === "mcp") return { ...visible, description: catalogDescription ?? item.wheelPreview?.summary ?? item.description };
  return {
    ...visible, name: skillDisplayName(item),
    ...(catalog ? { description: catalog.summary, category: catalog.category } : {}),
    ...(showSuggestions && nameReview?.status === "pending" ? { suggestedName: nameReview.value } : {}),
    ...(showSuggestions && nameReview?.status === "accepted" ? { renamed: true } : {}),
  };
}

const skillFolderID = /^[a-f0-9]{64}$/u;

async function ownedSkillFolders(root, skills) {
  const paths = skills.flatMap(item => [item.savedMarkdownPath,
    ...list(item.sources).filter(source => source.agent === "manual").map(source => source.path)]);
  const dirs = await Promise.all([...new Set(paths)].filter(path => typeof path === "string" &&
    isAbsolute(path) && basename(path) === "SKILL.md").map(async path => {
    const canonical = await realpath(path).catch(() => null);
    if (!canonical || basename(canonical) !== "SKILL.md") return null;
    const folder = dirname(canonical);
    const id = basename(folder);
    return dirname(folder) === root && skillFolderID.test(id) ? id : null;
  }));
  return new Set(dirs.filter(Boolean));
}

async function cleanRetiredSkillFolders(storage, previous, library) {
  const queued = list(library.retiredSkillFolders).filter(id => typeof id === "string" && skillFolderID.test(id));
  if (!queued.length) return 0;
  const root = join(await realpath(dirname(storage)), "skill-sources");
  try {
    if (!(await lstat(root)).isDirectory()) return queued.length;
  } catch (error) {
    if (error.code !== "ENOENT") return queued.length;
  }
  const inUse = await ownedSkillFolders(root, library.skills);
  const pending = [];
  for (const id of queued) {
    if (inUse.has(id)) continue;
    try {
      // Only a generated directory directly inside TypeLeast's own store is eligible.
      await rm(join(root, id), { recursive: true, force: true });
    } catch { pending.push(id); }
  }
  if (pending.length) library.retiredSkillFolders = pending;
  else delete library.retiredSkillFolders;
  await writeLibrary(storage, previous, library);
  return pending.length;
}

async function deleteLibraryItems(storage, previous, library, items) {
  const removed = new Set(items.map(item => item.id));
  if (removed.size) {
    const root = join(await realpath(dirname(storage)), "skill-sources");
    const copies = await ownedSkillFolders(root, items.filter(item => item.kind === "skill"));
    library.skills = library.skills.filter(item => !removed.has(item.id));
    library.servers = library.servers.filter(item => !removed.has(item.id));
    library.managed = library.managed.map(record => removed.has(record.item) && record.kind === "mcp"
      ? { ...record, removed: true } : record);
    const used = new Set(library.skills.map(item => item.markdownDigest));
    for (const { markdownDigest } of items) {
      if (markdownDigest && !used.has(markdownDigest)) delete library.markdown?.[markdownDigest];
    }
    if (copies.size) library.retiredSkillFolders = [...new Set([...list(library.retiredSkillFolders), ...copies])];
    await writeLibrary(storage, previous, library);
    ({ previous, library } = await readLibrary(storage));
  }
  const pendingCleanup = await cleanRetiredSkillFolders(storage, previous, library);
  return { deleted: removed.size, pendingCleanup };
}

function storeMarkdown(library, item, markdown) {
  const digest = fingerprint(markdown);
  const records = library.markdown ??= {};
  const changed = records[digest] !== markdown;
  records[digest] = markdown;
  item.markdownDigest = digest;
  return changed;
}

function verifiedMarkdown(library, digest) {
  if (typeof digest !== "string" || !/^[a-f0-9]{64}$/u.test(digest)) return undefined;
  const text = library.markdown?.[digest];
  return typeof text === "string" && fingerprint(text) === digest ? text : undefined;
}

async function skillMarkdownSnapshot(library, item) {
  if (!item) return null;
  const path = item.sources.find(source => source.agent === "manual")?.path;
  if (isIndependentSpeak(item)) {
    const saved = item.savedMarkdownPath ? await readSkillMarkdown(item.savedMarkdownPath).catch(() => undefined) : undefined;
    return { path: path ?? item.sources.find(source => source.agent === "github")?.path,
      text: verifiedMarkdown(library, item.markdownDigest) ?? saved ?? item.body };
  }
  if (!isSkillReference(item)) return null;
  const original = await readLocal(path, maxSkillBytes, { preserveBOM: true }).catch(() => null);
  return original ? { path, text: original.text, original } : null;
}

async function saveSkillEdit(request, item, library, storage, previous) {
  const source = await skillMarkdownSnapshot(library, item);
  if (!source) return { error: "skill-source-unavailable" };
  if (request.revision !== fingerprint(source.text)) return { error: "changed" };
  const text = request.text;
  if (typeof text !== "string" || Buffer.byteLength(text) > maxSkillBytes) return { error: "invalid-skill" };
  if (source.text === text) return { revision: request.revision };
  let parsed;
  try { parsed = parseSpeak(source.path, text); } catch { return { error: "invalid-skill" }; }
  if (!parsed) return { error: "invalid-skill" };

  if (source.original) {
    const options = { maxBytes: maxSkillBytes, preserveBOM: true };
    await replaceLocal(source.path, source.original, text, options);
    if (item.importMode === "linked") {
      item.body = parsed.item.body;
      try { await writeLibrary(storage, previous, library); }
      catch (error) {
        await replaceLocal(source.path, { text, mode: source.original.mode }, source.text, options);
        throw error;
      }
    }
  } else {
    if (parsed.item.dependencies) return { error: "skill-dependencies" };
    if (library.skills.some(other => other !== item && other.id === parsed.item.id)) return { error: "duplicate-skill" };
    item.id = parsed.item.id;
    item.body = parsed.item.body;
    storeMarkdown(library, item, text);
    await writeLibrary(storage, previous, library);
  }
  return { revision: fingerprint(text) };
}

async function centralizeSavedMarkdown(storage, previous, library) {
  const migrated = [];
  const root = join(await realpath(dirname(storage)), "skill-sources");
  for (const item of library.skills.filter(isIndependentSpeak)) {
    if (verifiedMarkdown(library, item.markdownDigest) !== undefined) continue;
    const source = item.savedMarkdownPath;
    const existing = source ? await readSkillMarkdown(source).catch(() => undefined) : undefined;
    if (existing === undefined) continue;
    storeMarkdown(library, item, existing);
    const canonical = await realpath(source).catch(() => null);
    const shared = library.skills.some(other => other !== item &&
      (other.savedMarkdownPath === source || other.sources?.some(origin => origin.path === source)));
    const cleanup = canonical && dirname(dirname(canonical)) === root && basename(canonical) === "SKILL.md"
      && !shared && (await readdir(dirname(canonical))).length === 1;
    if (cleanup) delete item.savedMarkdownPath;
    migrated.push({ digest: item.markdownDigest, ...(cleanup ? { source: canonical } : {}) });
  }
  if (migrated.length) await writeLibrary(storage, previous, library);
  const durable = (await readLibrary(storage)).library;
  return { migratedMarkdown: migrated.filter(copy => verifiedMarkdown(durable, copy.digest) !== undefined) };
}

function pasteSelection(items) {
  return items.flatMap(item => {
    if (isSkillReference(item)) return [skillInvocation(item)];
    if (item.kind === "skill") return ["### Speak: " + skillDisplayName(item) + "\n\n" + item.body];
    return [mcpInvocation(item)];
  }).join("\n\n---\n\n");
}

function mcpInvocation(item) {
  const source = item.sources.find(({ path }) => typeof path === "string" && isAbsolute(path)) ??
    item.sources.find(({ agent, path }) => agent === "github" && /^https:\/\/github\.com\//u.test(path));
  const purpose = label(item.catalogDescription ?? item.wheelPreview?.summary ?? item.description) ||
    "Read the source entry to determine the server's purpose and expected output.";
  return [
    "MCP: " + JSON.stringify(item.name),
    "Purpose: " + purpose,
    ...(source ? ["Source: " + JSON.stringify(source.path)] : []),
    "Use this server's relevant tool if available. Check its inputs and return the result for the current task. " +
      "If unavailable, inspect only the named entry in the source when accessible and explain the setup or access needed.",
  ].join("\n");
}

function skillInvocation(item) {
  if (isIndependentSpeak(item)) return item.body;
  const path = item.sources.find(source => source.agent === "manual").path;
  const purpose = label(item.wheelPreview?.summary) || label(item.description) || "See the source for this Skill's purpose.";
  return [
    "Skill: " + label(skillDisplayName(item)),
    "Purpose: " + purpose,
    "Usage: Read the source first and follow its workflow for the current task. " +
      "Open only the dependencies needed, relative to the source file's directory.",
    "Source: " + JSON.stringify(path),
  ].join("\n");
}

async function canInvoke(item) {
  if (isIndependentSpeak(item)) return true;
  if (!isSkillReference(item)) return false;
  const path = item.sources.find(source => source.agent === "manual").path;
  try {
    if (!(await lstat(path)).isFile()) return false;
    await access(path, constants.R_OK);
    return true;
  } catch {
    return false;
  }
}

async function mutations(request, items, home, env, project, ledger) {
  const changes = [];
  const rows = [];
  for (const id of new Set(list(request.targets))) {
    const agent = agentDefinition(id, home, env, project);
    if (!agent) continue;
    const files = new Map();
    const status = (item, state, path) => rows.push({ resource: item.id, agent: id, item: item.name, state, path });
    const location = request.scope === "project" ? agent.project : agent;
    const file = await configPath(location);
    for (const item of items) {
      if (item.kind !== "mcp") continue;
      const recorded = ledger.find(record => record.item === item.id && record.agent === id && record.path === file);
      if (!file) { status(item, "unsupported"); continue; }
      if (!recorded) { status(item, "not-managed"); continue; }
      const format = agent.format;
      try {
        if (!files.has(file)) {
          const previous = await readLocal(file);
          files.set(file, { path: file, previous, text: previous?.text ?? "", ledger: [] });
        }
        const target = files.get(file);
        const doc = configObject(format, target.text);
        const mcp = mcpEntries(agent, doc);
        const existing = Object.hasOwn(mcp.settings, item.name) ? mcp.settings[item.name] : undefined;
        if (!isDeepStrictEqual({ ...object(existing) }, recorded.entry)) { status(item, "changed", file); continue; }
        target.text = editConfig(format, target.text, [...mcp.path, item.name], undefined);
        target.ledger.push(recorded);
        status(item, "ready", file);
      } catch (error) {
        status(item, error.message === "unsupported-layout" ? "unsupported-layout" : "unreadable-config", file);
      }
    }
    changes.push(...Array.from(files.values()).filter(file => file.ledger.length > 0));
  }
  const token = fingerprint(JSON.stringify([rows, changes.map(c => [c.path, c.previous?.text, c.text])]));
  return { rows, changes, token };
}

export async function libraryRequest(request, {
  home = homedir(), env = process.env, storage, applications = ["/Applications", join(home, "Applications")],
  githubFetch = fetch,
}) {
  if (request.action === "preview-github-import" || request.action === "confirm-github-import") {
    const kind = request.kind;
    if (kind !== "skill" && kind !== "mcp") throw new Error("invalid-request");
    const confirming = request.action === "confirm-github-import";
    if (confirming && !request.revision) throw new Error("changed");
    const repo = await githubLibrary(request.url, kind, confirming ? request.revision : null, githubFetch);
    const options = await githubImportOptions(repo, kind);
    const token = fingerprint(JSON.stringify([repo.revision, kind, importProof(options)]));
    if (!confirming) return { imports: options.map(({ row }) => row), token, githubRevision: repo.revision };
    if (token !== request.token) throw new Error("changed");
    const selected = options.filter(({ row }) => request.modes?.[row.selectionID] === "full");
    if (!selected.length) throw new Error("invalid-request");
    const imports = kind === "skill" ? await githubSkillItems(repo, selected, storage) : selected;
    const modes = Object.fromEntries(imports.map(({ row }) => [row.selectionID, row.kind === "skill" && row.dependencies ? "reference" : "full"]));
    const { previous, library } = await readLibrary(storage);
    let markdownChanged = false;
    for (const { items, markdown } of imports) {
      if (markdown !== undefined) markdownChanged = storeMarkdown(library, items[0], markdown) || markdownChanged;
    }
    const { summary, speakIds, changed } = importFiles(library, imports, modes);
    if (changed || markdownChanged) await writeLibrary(storage, previous, library);
    return { importedFiles: summary, speakIds };
  }
  const { previous, library } = await readLibrary(storage);
  if (request.action === "centralize-saved-markdown") return centralizeSavedMarkdown(storage, previous, library);
  if (request.action === "verify-markdown-trash") {
    const copies = list(request.copies).filter(copy => copy && typeof copy.source === "string"
      && isAbsolute(copy.source) && isMarkdownFile(copy.source));
    const verified = await Promise.all(copies.map(async ({ source, digest }) => {
      const original = await readSkillMarkdown(source).catch(() => undefined);
      if (original == null || fingerprint(original) !== digest) return null;
      const stored = fingerprint(slimSkillMarkdown(original));
      return verifiedMarkdown(library, stored) !== undefined || verifiedMarkdown(library, digest) !== undefined
        ? { source, digest } : null;
    }));
    return { savedMarkdown: verified.filter(Boolean) };
  }
  if (request.action === "scan-skills") {
    const storedPaths = library.skills.filter(item => isIndependentSpeak(item) || isSkillReference(item))
      .flatMap(item => item.sources.filter(source => source.agent === "manual").map(source => source.archivePath ?? source.path));
    const discovered = await discoverLocalSkills(home, env, storedPaths);
    const candidates = await importCandidates([...discovered.keys()], { allowDirectories: false, applications });
    const options = candidates.filter(({ row }) => row.kind === "skill");
    return { imports: options.map(({ row }) => ({ ...row, providers: discovered.get(row.path) })), token: importProof(options) };
  }
  if (request.action === "scan-mcps" || request.action === "confirm-mcp-scan") {
    const options = await scanLocalMcps(library, home, env);
    const token = importProof(options);
    if (request.action === "scan-mcps") return { imports: options.map(({ row }) => row), token };
    if (token !== request.token) throw new Error("changed");
    const { summary, changed } = importFiles(library, options, object(request.modes));
    if (changed) await writeLibrary(storage, previous, library);
    return { importedFiles: summary };
  }
  if (["import-files", "preview-import", "confirm-import"].includes(request.action)) {
    const options = await importCandidates(request.paths, { allowDirectories: request.action !== "import-files", applications });
    const token = importProof(options);
    if (request.action === "preview-import") return { imports: options.map(option => option.row), token };
    const modes = request.action === "confirm-import" ? object(request.modes) : null;
    if (modes && token !== request.token) throw new Error("changed");
    const savedMarkdown = [], failedSaves = [];
    const storedDigests = new Map();
    let markdownChanged = false;
    const markdownSaves = modes ? object(request.markdownSaves) : {};
    for (const { row, items, digest, markdown } of options) {
      if (modes?.[row.path] !== "full") continue;
      if (request.centralizeMarkdown === true && row.canSaveMarkdown) {
        markdownChanged = storeMarkdown(library, items[0], slimSkillMarkdown(markdown)) || markdownChanged;
        storedDigests.set(row.path, items[0].markdownDigest);
        savedMarkdown.push({ source: row.path, digest });
        continue;
      }
      if (!Object.hasOwn(markdownSaves, row.path)) continue;
      const save = object(markdownSaves[row.path]);
      try {
        if (!row.canSaveMarkdown || !["library", "folder"].includes(save.location)) throw new Error("unsupported-save");
        const copy = await saveSkillMarkdown(storage, row.path, markdown, digest, save);
        items[0].savedMarkdownPath = copy.destination;
        savedMarkdown.push(copy);
      } catch {
        modes[row.path] = "skip";
        failedSaves.push(row.path);
      }
    }
    for (const { row, items, archiveKind, digest } of options) {
      if (!archiveKind || !["full", "reference"].includes(modes?.[row.path])) continue;
      const path = archiveKind === "asar" ? await stageArchivedSkill(applications, storage, row.path, digest) :
        await stageSkillPackage(storage, row.path, digest);
      items[0].sources = [{ agent: "manual", path, archivePath: row.path }];
    }
    if (!modes) {
      // The older immediate-import protocol cannot select packaged resources.
      for (const option of options) if (option.archiveKind) option.row.kind = "unknown";
    }
    const { summary, speakIds, changed } = importFiles(library, options, modes);
    if (changed || markdownChanged) await writeLibrary(storage, previous, library);
    const central = request.centralizeMarkdown === true ? (await readLibrary(storage)).library : undefined;
    const verified = central ? savedMarkdown.filter(copy => copy.destination ||
      verifiedMarkdown(central, storedDigests.get(copy.source)) !== undefined)
      : savedMarkdown;
    return { importedFiles: summary, speakIds, savedMarkdown: verified, failedSaves };
  }
  const project = typeof request.project === "string" && isAbsolute(request.project) ? request.project : undefined;
  const inventory = storedItems(library);
  const requested = new Set(list(request.items));
  const items = inventory.filter(item => requested.has(item.id));
  switch (request.action) {
    case "set-library-ignored": {
      if (typeof request.ignored !== "boolean") throw new Error("invalid-request");
      const matched = new Set(items.map(item => item.id));
      const update = (item, id) => matched.has(id) ? { ...item, ignored: request.ignored } : item;
      if (matched.size) {
        library.skills = library.skills.map(item => update(item, item.id));
        library.servers = library.servers.map(item => update(item, item.id));
        library.managed = library.managed.map(record => record.kind === "mcp" ? update(record, record.item) : record);
        await writeLibrary(storage, previous, library);
      }
      return { changedItems: matched.size };
    }
    case "delete-library-items": return deleteLibraryItems(storage, previous, library, items);
    case "export-speak": {
      const [item] = items.filter(isIndependentSpeak);
      if (!item) return { error: "skill-source-unavailable" };
      return { text: (await skillMarkdownSnapshot(library, item)).text };
    }
    case "skill-preview": {
      const [item] = items.filter(item => item.kind === "skill");
      const source = await skillMarkdownSnapshot(library, item);
      return source ? { text: source.text, revision: fingerprint(source.text) } : { error: "skill-source-unavailable" };
    }
    case "preview-skills": {
      const skills = items.filter(item => item.kind === "skill");
      const sources = await Promise.all(skills.map(item => skillMarkdownSnapshot(library, item)));
      return {
        text: sources.filter(Boolean).map(source => source.text).join("\n\n---\n\n"),
        omitted: skills.filter((_, index) => !sources[index]).map(item => item.name),
      };
    }
    case "save-skill-edit":
      return saveSkillEdit(request, items.find(item => item.kind === "skill"), library, storage, previous);
    case "speak-drafts": {
      const selected = items.filter(item => canOrganizeItem(item) && item.kind === (request.kind ?? "skill"));
      const drafts = await Promise.all(selected.slice(0, SPEAK_BATCH_SIZE).map(async item => {
        if (item.kind === "mcp") {
          const description = label(item.catalogDescription ?? item.description);
          return { id: item.id, body: [item.name, description].filter(Boolean).join("\n") };
        }
        const body = isIndependentSpeak(item) ? item.body : (await skillMarkdownSnapshot(library, item))?.text;
        return body?.trim() ? { id: item.id, body: speakExcerpt(body),
          ...(request.suggestNames === true && !item.nameReview ? { currentName: skillDisplayName(item) } : {}) } : null;
      }));
      return { speakDrafts: drafts.filter(Boolean) };
    }
    case "save-speak-descriptions": {
      const updates = new Map(list(request.descriptions).slice(0, SPEAK_BATCH_SIZE)
        .map(speakDescription).filter(Boolean).map(({ id, ...catalog }) => [id, catalog]));
      let organized = 0;
      library.skills = library.skills.map(item => {
        const catalog = updates.get(item.id);
        if (!catalog || !isIndependentSpeak(item)) return item;
        organized += 1;
        return { ...item, catalog };
      });
      if (organized) await writeLibrary(storage, previous, library);
      return { organized };
    }
    case "save-speak-categories": {
      const updates = new Map(list(request.categories).slice(0, SPEAK_BATCH_SIZE)
        .filter(row => SPEAK_CATEGORIES.includes(row?.category)).map(row => [row.id, row]));
      let organized = 0;
      let changed = false;
      const updateFolder = item => {
        const update = updates.get(item.id);
        if (!update || !canOrganizeItem(item) || item.kind !== (request.kind ?? "skill")) return item;
        organized += 1;
        const next = { ...item };
        const existingFolder = item.folderCategory ?? item.catalog?.category;
        if (update.keepFolder !== true || !SPEAK_CATEGORIES.includes(existingFolder)) next.folderCategory = update.category;
        const preview = speakWheelPreview(update.preview);
        if (preview) next.wheelPreview = preview;
        if (item.kind === "skill" && request.suggestNames === true && !item.nameReview) {
          const value = speakNameSuggestion(update.suggestedName, skillDisplayName(item));
          if (value) next.nameReview = { status: "pending", value };
        }
        if (isDeepStrictEqual(item, next)) return item;
        changed = true;
        return next;
      };
      if (request.kind === "mcp") library.servers = library.servers.map(updateFolder);
      else library.skills = library.skills.map(updateFolder);
      if (changed) await writeLibrary(storage, previous, library);
      return { organized };
    }
    case "review-skill-name": {
      const [item] = items;
      if (items.length !== 1 || item.kind !== "skill" || typeof request.accept !== "boolean") throw new Error("invalid-request");
      const review = item.nameReview;
      if (review?.status !== "pending" || review.value !== request.suggestedName) throw new Error("changed");
      item.nameReview = request.accept ? { status: "accepted", value: review.value } : { status: "declined" };
      await writeLibrary(storage, previous, library);
      return { reviewed: true };
    }
    case "list": {
      if (request.surface === "wheel") {
        return { items: inventory.filter(item => item.ignored !== true).map(item =>
          item.kind === "mcp" ? { ...publicItem(item), invocationText: mcpInvocation(item) } : publicItem(item)) };
      }
      return { agents: Object.entries(names).map(([id, name]) => ({ id, name })), items: inventory.map(item => publicItem(item, true)),
        managed: library.managed.filter(item => item.kind === "mcp")
          .map(({ item, agent, path }) => ({ item, agent, path })), pendingCleanup: list(library.retiredSkillFolders).length };
    }
    case "paste": {
      const withSources = await Promise.all(items.map(async item => !isSkillReference(item) || await canInvoke(item)));
      return { text: pasteSelection(items.filter((_, index) => withSources[index])),
        omitted: items.filter((_, index) => !withSources[index]).map(item => item.name) };
    }
    case "invoke": {
      const [item] = items;
      if (item?.ignored === true) return { error: "item-ignored" };
      if (item?.kind === "mcp") return { text: mcpInvocation(item) };
      return item && await canInvoke(item) ? { text: skillInvocation(item) } : { error: "skill-source-unavailable" };
    }
    case "preview":
    case "apply": {
      if (request.operation !== "undo") throw new Error("invalid-request");
      const { rows, changes, token } = await mutations(request, items, home, env, project, library.managed);
      if (request.action === "preview") return { rows, token };
      if (request.token !== token) throw new Error("changed");
      let record = previous;
      for (const change of changes) {
        try {
          await replaceLocal(change.path, change.previous, change.text);
          const managedBefore = library.managed;
          for (const entry of change.ledger) {
            library.managed = library.managed.filter(x => x.item !== entry.item || x.agent !== entry.agent || x.path !== entry.path);
          }
          try {
            await writeLibrary(storage, record, library);
            record = await readLocal(storage, 24 * 1024 * 1024);
          } catch (error) {
            library.managed = managedBefore;
            await replaceLocal(change.path, { text: change.text, mode: change.previous?.mode }, change.previous?.text ?? "");
            throw error;
          }
          for (const row of rows) if (row.path === change.path && row.state === "ready") row.state = "applied";
        } catch (error) {
          for (const row of rows) if (row.path === change.path && row.state === "ready") {
            row.state = error.message === "changed" ? "changed" : "write-failed";
          }
        }
      }
      return { rows };
    }
    default: throw new Error("invalid-request");
  }
}
