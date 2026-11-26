import { lstat, readdir, realpath } from "node:fs/promises";
import { basename, dirname, isAbsolute, join, parse, resolve, sep } from "node:path";
import { configObject, readLocal } from "./agent-config.js";
import { isMarkdownFile } from "./skill-import.js";

const directoryBudget = 1024;
const maxDepth = 3;
const folder = (env, name, fallback) => isAbsolute(env[name] ?? "") ? env[name] : fallback;
const entryPoint = name => name.toLowerCase() === "skill.md";

function directories(value, base, home) {
  return (Array.isArray(value) ? value : []).filter(path => typeof path === "string" &&
    path.length > 0 && !/^[a-z][a-z\d+.-]*:|[{}\0]/iu.test(path))
    .map(path => path.startsWith("~/") ? join(home, path.slice(2)) : resolve(base, path))
    .filter(path => path !== home && path !== parse(path).root);
}

async function readConfig(path, format) {
  try {
    const file = await readLocal(path, 1024 * 1024, { follow: true });
    return file ? configObject(format, file.text) : {};
  } catch { return {}; }
}

async function openCodeProjects(dbPath) {
  try {
    if (!(await lstat(dbPath)).isFile()) return [];
    const { DatabaseSync } = await import("node:sqlite");
    const db = new DatabaseSync(dbPath, { readOnly: true });
    try {
      return db.prepare("SELECT DISTINCT worktree FROM project LIMIT 256").all()
        .map(row => row.worktree).filter(path => typeof path === "string" && isAbsolute(path) && path !== parse(path).root);
    } finally { db.close(); }
  } catch { return []; }
}

async function deepSeekProjects(home) {
  const cache = join(home, "storages", "session_projcache", "sessions");
  const entries = await readdir(cache, { withFileTypes: true }).catch(() => []);
  const folders = await Promise.all(entries.filter(item => item.isFile() && item.name.endsWith(".json"))
    .slice(0, 256).map(async item => (await readConfig(join(cache, item.name), "jsonc")).record?.identity?.cwd));
  const roots = new Set();
  for (const folder of new Set(folders)) {
    if (typeof folder !== "string" || !isAbsolute(folder) || folder === parse(folder).root) continue;
    let project = folder;
    while (project !== parse(project).root) {
      if (await lstat(join(project, ".git")).catch(() => null)) break;
      project = dirname(project);
    }
    roots.add(project === parse(project).root ? folder : project);
  }
  return roots;
}

function deepSeekConfiguredRoots(config, output = { custom: [], bundled: [] }, seen = new WeakSet()) {
  if (!config || typeof config !== "object" || seen.has(config)) return output;
  seen.add(config);
  if (Array.isArray(config.customSkillDirs)) output.custom.push(...config.customSkillDirs);
  if (typeof config.bundledSkillDir === "string") output.bundled.push(config.bundledSkillDir);
  for (const child of Object.values(config)) if (child && typeof child === "object") deepSeekConfiguredRoots(child, output, seen);
  return output;
}

async function skillRoots(home, env) {
  const config = folder(env, "XDG_CONFIG_HOME", join(home, ".config"));
  const data = folder(env, "XDG_DATA_HOME", join(home, ".local", "share"));
  const support = join(home, "Library", "Application Support");
  const open = folder(env, "OPENCODE_CONFIG_DIR", join(config, "opencode"));
  const dsh = folder(env, "DSH_HOME", join(home, ".dsh"));
  const claude = folder(env, "CLAUDE_CONFIG_DIR", join(home, ".claude"));
  const hermes = folder(env, "HERMES_HOME", join(home, ".hermes"));
  const roots = [
    ["Codex", folder(env, "CODEX_HOME", join(home, ".codex"))],
    ["Claude Code", claude],
    ["OpenCode", open],
    ["OpenCode", join(home, ".opencode")],
    ["OpenCode", join(support, "ai.opencode.desktop")],
    ["DeepSeek Harness", dsh],
    ["DeepSeek Harness", join(home, ".deepseek", "harness")],
    ["DeepSeek Harness", join(support, "@deepseek-ai", "dsh-desktop")],
    ["ChatGPT", join(support, "ChatGPT")],
    ["ChatGPT", join(support, "com.openai.chat")],
    ["ChatGPT", join(support, "com.openai.codex")],
    ["Hermes", hermes],
    ["Shared", join(home, ".agents")],
  ].map(([provider, base]) => [provider, join(base, "skills")]);

  const projects = await openCodeProjects(join(data, "opencode", "opencode.db"));
  const openConfigs = [env.OPENCODE_CONFIG, join(open, "opencode.json"), join(open, "opencode.jsonc")];
  roots.push(["OpenCode", join(open, "skill")]);
  if (projects.length) {
    if (!["1", "true"].includes(env.OPENCODE_DISABLE_CLAUDE_CODE)) roots.push(["OpenCode", join(home, ".claude", "skills")]);
    roots.push(["OpenCode", join(home, ".agents", "skills")]);
  }
  for (const project of projects) {
    for (const name of [".opencode", ".claude", ".agents"]) roots.push(["OpenCode", join(project, name, "skills")]);
    roots.push(["OpenCode", join(project, ".opencode", "skill")]);
    for (const base of [project, join(project, ".opencode")]) {
      openConfigs.push(join(base, "opencode.json"), join(base, "opencode.jsonc"));
    }
  }
  for (const file of new Set(openConfigs.filter(value => typeof value === "string" && isAbsolute(value)))) {
    const { skills } = await readConfig(file, "jsonc");
    for (const path of directories(Array.isArray(skills) ? skills : skills?.paths, dirname(file), home)) roots.push(["OpenCode", path]);
  }

  const bundled = [];
  for (const base of [dsh, join(dsh, "profiles", "desktop")]) {
    for (const name of ["cordis.yml", "cordis.patch.yml"]) {
      const extras = deepSeekConfiguredRoots(await readConfig(join(base, name), "yaml"));
      for (const path of directories(extras.custom, base, home)) roots.push(["DeepSeek Harness", path]);
      bundled.push(...directories(extras.bundled, base, home));
    }
  }
  for (const project of await deepSeekProjects(dsh)) {
    roots.push(["DeepSeek Harness", join(project, ".dsh", "skills")],
      ["DeepSeek Harness", join(project, ".agents", "skills")]);
  }
  if (isAbsolute(env.DSH_BUNDLED_SKILL_DIR ?? "")) bundled.push(env.DSH_BUNDLED_SKILL_DIR);

  roots.push(["ChatGPT", join(home, "Library", "Containers", "com.openai.chat", "Data", "Library", "Application Support", "ChatGPT", "skills")]);
  return { roots, bundled, hermesSkills: join(hermes, "skills"),
    claudeSyncRoots: [...new Set([claude, join(home, ".claude")])].map(path => join(path, "skills", "synced")) };
}

async function canonicalFile(path) {
  try {
    const target = await realpath(path);
    return (await lstat(target)).isFile() ? target : null;
  } catch {
    return null;
  }
}

async function bundledOrigins({ bundled, hermesSkills, claudeSyncRoots }) {
  const canonicalHermes = await realpath(hermesSkills).catch(() => hermesSkills);
  const vendorRoots = await Promise.all(bundled.map(path => realpath(path).catch(() => path)));
  const manifest = await readLocal(join(hermesSkills, ".bundled_manifest"), 256 * 1024).catch(() => null);
  const hermesNames = new Set((manifest?.text ?? "").split(/\r?\n/u)
    .map(line => line.replace(/^\uFEFF/u, "").split(":", 1)[0].trim()).filter(Boolean));
  const managed = new Set();
  for (const sync of claudeSyncRoots) {
    const workspaces = await readdir(sync, { withFileTypes: true }).catch(() => []);
    for (const workspace of workspaces) {
      if (!workspace.isDirectory()) continue;
      const directory = join(sync, workspace.name);
      const config = await readConfig(join(directory, "manifest.json"), "jsonc");
      if (!Array.isArray(config.skills)) continue;
      for (const row of config.skills) {
        if (!["anthropic", "anthropic-example"].includes(row?.source) ||
            typeof row.name !== "string" || !row.name || row.name === "." || row.name === ".." || /[/\\]/u.test(row.name)) continue;
        const path = await canonicalFile(join(directory, row.name, "SKILL.md"));
        if (path) managed.add(path);
      }
    }
  }
  return path => /\.app\/Contents\/|\/\.(?:curated|system)\//iu.test(path) || managed.has(path) ||
    vendorRoots.some(root => path.startsWith(root + sep)) ||
    path.startsWith(canonicalHermes + sep) && hermesNames.has(basename(dirname(path)));
}

// A symlink may lead to one explicitly linked Skill, but never acts as the
// root of another walk through the user's files.
export async function discoverLocalSkills(home, env, storedPaths) {
  const inventory = await skillRoots(home, env);
  const isBundled = await bundledOrigins(inventory);
  const imported = new Set([...storedPaths, ...await Promise.all(storedPaths.map(canonicalFile))]);
  const discovered = new Map();
  let visited = 0;

  function add(canonical, provider) {
    if (!canonical || imported.has(canonical) || isBundled(canonical)) return;
    if (!discovered.has(canonical)) discovered.set(canonical, new Set());
    discovered.get(canonical).add(provider);
  }

  async function walk(path, provider, depth, leafOnly = false) {
    if (visited >= directoryBudget) return;
    let entries;
    try { entries = await readdir(path, { withFileTypes: true }); } catch { return; }
    visited += 1;
    const skill = entries.find(entry => entryPoint(entry.name) && (entry.isFile() || entry.isSymbolicLink()));
    if (skill) {
      const canonical = await canonicalFile(join(path, skill.name));
      if (canonical && isMarkdownFile(basename(canonical))) add(canonical, provider);
      return;
    }
    if (leafOnly || depth >= (provider === "OpenCode" ? 6 : maxDepth)) return;
    for (const entry of entries.sort((a, b) => a.name.localeCompare(b.name))) {
      if (entry.name.startsWith(".") || entry.name === "node_modules") continue;
      if (depth === 0 && provider === "ChatGPT" && /\.skill$/iu.test(entry.name)) {
        if (entry.isFile()) add(await canonicalFile(join(path, entry.name)), provider);
        continue;
      }
      if (depth === 0 && ["OpenCode", "DeepSeek Harness"].includes(provider) && isMarkdownFile(entry.name)) {
        const canonical = await canonicalFile(join(path, entry.name));
        if (canonical && isMarkdownFile(canonical)) add(canonical, provider);
        continue;
      }
      if (entry.isDirectory() || entry.isSymbolicLink()) {
        await walk(join(path, entry.name), provider, depth + 1, entry.isSymbolicLink());
      }
    }
  }

  for (const [provider, path] of new Map(inventory.roots.map(pair => [JSON.stringify(pair), pair])).values()) await walk(path, provider, 0);
  return new Map([...discovered].map(([path, providers]) => [path, [...providers]]));
}
