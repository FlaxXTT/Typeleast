import { createHash } from "node:crypto";
import { basename, dirname, extname } from "node:path/posix";

const treeLimit = 8 * 1024 * 1024;
const bundleLimit = 24 * 1024 * 1024;
const sha = /^[a-f0-9]{40}$/u;
const repositoryName = /^[A-Za-z0-9_.-]{1,100}$/u;
const ignoredFolders = new Set([".git", ".github", "node_modules", "__pycache__"]);
const mcpFile = /^(?:\.?mcp(?:[-_.]config)?\.(?:jsonc?|ya?ml|toml)|opencode\.jsonc?|server\.json)$/iu;
const regular = entry => entry.type === "blob" && ["100644", "100755"].includes(entry.mode);
const beneath = (path, folder) => !folder || path.startsWith(folder + "/");
const parent = path => dirname(path) === "." ? "" : dirname(path);
const validPart = part => part.length > 0 && part !== "." && part !== ".." && !/[/\\:\p{Cc}\p{Cf}]/u.test(part);
const encodedPath = path => path.split("/").map(encodeURIComponent).join("/");
const ignoredPath = path => path.split("/").some(part => ignoredFolders.has(part) || part === ".DS_Store");

function sourceLink(input) {
  if (typeof input !== "string" || input.length > 2048) throw new Error("github-link");
  let url, parts;
  try {
    url = new URL(input.trim());
    parts = url.pathname.replace(/^\//u, "").replace(/\/$/u, "").split("/").map(decodeURIComponent);
  } catch { throw new Error("github-link"); }
  if (url.protocol !== "https:" || url.port || url.username || url.password) throw new Error("github-link");
  const raw = url.hostname === "raw.githubusercontent.com";
  if (!raw && !["github.com", "www.github.com"].includes(url.hostname)) throw new Error("github-link");
  const [owner, repoValue] = parts.splice(0, 2);
  const repo = repoValue?.replace(/\.git$/u, "");
  if (!repositoryName.test(owner ?? "") || !repositoryName.test(repo ?? "") ||
      !validPart(owner) || !validPart(repo)) throw new Error("github-link");
  const route = raw ? "blob" : parts.shift();
  if (route !== undefined && (!["tree", "blob"].includes(route) || !parts.length)) throw new Error("github-link");
  const ref = parts.shift();
  if (ref && !ref.split("/").every(validPart) || !parts.every(validPart) || parts.length > 25) {
    throw new Error("github-link");
  }
  return { owner, repo, route, ref, parts };
}

async function bytes(response, maximum) {
  if (Number(response.headers.get("content-length")) > maximum) {
    await response.body?.cancel();
    throw new Error("github-too-large");
  }
  const chunks = [];
  let length = 0;
  for await (const chunk of response.body ?? []) {
    length += chunk.length;
    if (length > maximum) throw new Error("github-too-large");
    chunks.push(chunk);
  }
  return Buffer.concat(chunks, length);
}

export async function githubLibrary(input, selection, revision, fetcher = fetch) {
  const { owner, repo, route, ref, parts } = sourceLink(input);
  const api = "https://api.github.com/repos/" + owner + "/" + repo;
  const site = "https://github.com/" + owner + "/" + repo;
  const signal = AbortSignal.timeout(60_000);
  async function get(url, maximum, json, missing = false) {
    let response;
    try {
      response = await fetcher(url, { signal, redirect: "error", headers: {
        Accept: json ? "application/vnd.github+json" : "application/octet-stream",
        "User-Agent": "TypeLeast",
      } });
    } catch { throw new Error("github-unavailable"); }
    if (!response.ok) {
      await response.body?.cancel();
      if (response.status === 429 || response.headers.get("x-ratelimit-remaining") === "0") {
        throw new Error("github-rate-limit");
      }
      if (missing && [404, 422].includes(response.status)) return null;
      throw new Error("github-unavailable");
    }
    const data = await bytes(response, maximum);
    try { return json ? JSON.parse(data.toString("utf8")) : data; }
    catch { throw new Error("github-unavailable"); }
  }

  let targetRef = ref;
  let scope = parts.join("/");
  let commit;
  if (revision) {
    if (typeof revision.ref !== "string" || !sha.test(revision.commit ?? "")) throw new Error("changed");
    const inputPath = [ref, ...parts].join("/");
    if (ref && inputPath !== revision.ref && !inputPath.startsWith(revision.ref + "/")) throw new Error("changed");
    if (ref) scope = inputPath.slice(revision.ref.length).replace(/^\//u, "");
    targetRef = revision.ref;
    commit = await get(api + "/commits/" + revision.commit, 1024 * 1024, true);
    if (commit.sha !== revision.commit) throw new Error("changed");
  } else if (ref) {
    // A branch name can have slashes. Resolve it before treating the rest as a path.
    const lastRefPart = Math.min(parts.length - (route === "blob" ? 1 : 0), 7);
    for (let count = 0; count <= lastRefPart; count++) {
      targetRef = [ref, ...parts.slice(0, count)].join("/");
      commit = await get(api + "/commits/" + encodeURIComponent(targetRef), 1024 * 1024, true, true);
      if (commit) {
        scope = parts.slice(count).join("/");
        break;
      }
    }
  } else {
    const repoInfo = await get(api, 1024 * 1024, true);
    targetRef = repoInfo.default_branch;
    if (typeof targetRef !== "string" || !targetRef) throw new Error("github-unavailable");
    commit = await get(api + "/commits/" + encodeURIComponent(targetRef), 1024 * 1024, true);
  }
  const commitId = commit?.sha;
  let treeId = commit?.commit?.tree?.sha;
  if (!sha.test(commitId ?? "") || !sha.test(treeId ?? "")) throw new Error("github-unavailable");
  if (route === "blob" && !scope) throw new Error("github-link");

  async function tree(id, recursive = false) {
    const result = await get(api + "/git/trees/" + id + (recursive ? "?recursive=1" : ""), treeLimit, true);
    if (result.truncated) throw new Error("github-too-large");
    if (!Array.isArray(result.tree)) throw new Error("github-unavailable");
    return result.tree;
  }
  const folder = route === "blob" ? parent(scope) : scope;
  for (const part of folder.split("/").filter(Boolean)) {
    const directory = (await tree(treeId)).find(row => row.path === part && row.type === "tree");
    if (!sha.test(directory?.sha ?? "")) throw new Error("github-unavailable");
    treeId = directory.sha;
  }
  const prefix = folder ? folder + "/" : "";
  const entries = (await tree(treeId, route !== "blob" || selection === "skill"))
    .filter(row => typeof row.path === "string" && row.path.length <= 1024 && row.path.split("/").every(validPart))
    .map(row => ({ ...row, path: prefix + row.path }));
  const blob = route === "blob" ? entries.find(row => row.path === scope && regular(row)) : null;
  const manifests = entries.filter(entry => regular(entry) && !ignoredPath(entry.path) && basename(entry.path).toLowerCase() === "skill.md");
  const candidates = route === "blob" ? [blob].filter(Boolean) : selection === "skill" ? manifests :
    entries.filter(entry => regular(entry) && !ignoredPath(entry.path) && mcpFile.test(basename(entry.path)));
  if (candidates.length > (selection === "skill" ? 200 : 20)) throw new Error("github-too-large");

  async function file(entry, maximum) {
    if (!regular(entry) || !sha.test(entry.sha ?? "") || !Number.isSafeInteger(entry.size) ||
        entry.size < 0 || entry.size > maximum) throw new Error("github-too-large");
    const url = "https://raw.githubusercontent.com/" + owner + "/" + repo + "/" + commitId + "/" + encodedPath(entry.path);
    const contents = await get(url, maximum, false);
    const digest = createHash("sha1").update("blob " + contents.length + "\0").update(contents).digest("hex");
    if (contents.length !== entry.size || digest !== entry.sha) throw new Error("github-unavailable");
    return contents;
  }

  function skillFiles(manifest) {
    if (basename(manifest.path).toLowerCase() !== "skill.md") return [manifest];
    const dir = parent(manifest.path);
    const nestedSkills = manifests.map(row => parent(row.path)).filter(child => child !== dir && beneath(child, dir));
    const files = entries.filter(entry => entry.type !== "tree" && beneath(entry.path, dir) &&
      !ignoredPath(entry.path) && !nestedSkills.some(child => beneath(entry.path, child)));
    if (files.length > 512 || files.some(entry => !regular(entry) || !Number.isSafeInteger(entry.size) || entry.size < 0) ||
        files.reduce((sum, entry) => sum + entry.size, 0) > bundleLimit) throw new Error("github-too-large");
    const unique = new Set(files.map(entry => entry.path.normalize("NFC").toLowerCase()));
    if (unique.size !== files.length) throw new Error("github-unavailable");
    return files;
  }

  return {
    candidates,
    repo,
    revision: { ref: targetRef, commit: commitId },
    permalink: entry => site + "/blob/" + commitId + "/" + encodedPath(entry.path),
    identity: entry => site + "/blob/" + encodeURIComponent(targetRef) + "/" + encodedPath(entry.path),
    file,
    skillFiles,
  };
}
