import { lstat, mkdir, mkdtemp, open, rename, rm, writeFile } from "node:fs/promises";
import { basename, dirname, join } from "node:path";
import { fingerprint } from "./agent-config.js";
import { slimSkillMarkdown } from "./skill-import.js";

const archiveName = "DeepSeek Harness.app/Contents/Resources/app.asar";
const packageRoots = [
  "dsh/node_modules/@deepseek-ai/dsh-agent-preset/skills",
  "dsh/node_modules/@deepseek-ai/dsh-skill-office/assets",
];
const safeComponent = name => name.length > 0 && name !== "." && name !== ".." && !/[\\/\0]/u.test(name);

function asarPaths(applications) {
  return applications.map(directory => join(directory, archiveName));
}

function entry(root, path) {
  return path.split("/").reduce((node, name) => node?.files && Object.hasOwn(node.files, name) ? node.files[name] : null, root);
}

async function withArchive(archive, callback) {
  if (!(await lstat(archive)).isFile()) throw new Error("invalid-archive");
  const file = await open(archive, "r");
  try {
    const stat = await file.stat();
    const header = Buffer.alloc(16);
    const { bytesRead } = await file.read(header, 0, 16, 0);
    const headerSize = header.readUInt32LE(4);
    const jsonSize = header.readUInt32LE(12);
    const start = headerSize + 8;
    if (bytesRead !== 16 || header.readUInt32LE(0) !== 4 || jsonSize > 16 * 1024 * 1024 ||
        jsonSize > start - 16 || start > stat.size) throw new Error("invalid-archive");
    const json = Buffer.alloc(jsonSize);
    if ((await file.read(json, 0, json.length, 16)).bytesRead !== json.length) throw new Error("invalid-archive");
    const root = JSON.parse(json);
    return await callback(root, async (node, maxBytes) => {
      const offset = start + Number(node.offset);
      if (node.link || node.unpacked || !Number.isSafeInteger(offset) || offset < start ||
          !Number.isSafeInteger(node.size) || node.size < 0 || node.size > maxBytes || offset + node.size > stat.size) {
        throw new Error("unsupported-archive-entry");
      }
      const data = Buffer.alloc(node.size);
      if ((await file.read(data, 0, data.length, offset)).bytesRead !== data.length) throw new Error("invalid-archive");
      return data;
    });
  } finally { await file.close(); }
}

export async function readArchivedSkill(applications, path, includeFiles = false) {
  const archive = asarPaths(applications).find(file => path.startsWith(file + "/"));
  if (!archive) return null;
  const resource = path.slice(archive.length + 1);
  const parent = dirname(resource);
  if (!packageRoots.includes(dirname(parent)) || !safeComponent(basename(parent)) || basename(resource) !== "SKILL.md") return null;
  return await withArchive(archive, async (root, read) => {
    const directory = entry(root, parent);
    const skill = directory?.files?.["SKILL.md"];
    if (!skill) return null;
    const content = await read(skill, 512 * 1024);
    const text = new TextDecoder("utf-8", { fatal: true }).decode(content);
    // The manifest is part of the preview proof. Replacing the app or its packaged
    // resources after preview must bring the user back to confirmation.
    const digest = fingerprint(JSON.stringify([directory, fingerprint(content)]));
    const children = Object.keys(directory.files);
    if (!includeFiles) return { text, children, digest };

    const files = [["SKILL.md", content]];
    let remaining = 6 * 1024 * 1024 - content.length;
    async function collect(node, prefix = "", depth = 0) {
      for (const [name, child] of Object.entries(node.files)) {
        if (!safeComponent(name)) throw new Error("invalid-archive-entry");
        const file = prefix + name;
        if (file === "SKILL.md") continue;
        if (depth >= 8 || files.length >= 64) throw new Error("skill-archive-too-large");
        if (child.files) await collect(child, file + "/", depth + 1);
        else {
          const resource = await read(child, remaining);
          remaining -= resource.length;
          files.push([file, resource]);
        }
      }
    }
    await collect(directory);
    return { text, children, digest, files };
  });
}

export async function stageArchivedSkill(applications, storage, path, digest) {
  const skill = await readArchivedSkill(applications, path, true);
  if (skill?.digest !== digest) throw new Error("changed");
  return await stageSkillFiles(storage, path, digest, skill.files);
}

export async function stageSkillFiles(storage, path, digest, sourceFiles) {
  const files = sourceFiles.map(entry => {
    const [name, contents] = entry;
    if (name !== "SKILL.md") return entry;
    const original = contents.toString();
    const compact = slimSkillMarkdown(original);
    return compact === original ? entry : [name, compact];
  });
  const retained = files.filter(([name]) => {
    const filename = name.toLowerCase();
    if (!/^(?:licen[cs]e|copying)(?:\.(?:md|txt|rst))?$/u.test(filename)) return true;
    return files.some(([other, content]) => other !== name && content.toString().toLowerCase().includes(filename));
  });
  const compacted = retained.length !== sourceFiles.length || files.some((entry, index) => entry !== sourceFiles[index]);
  const root = join(dirname(storage), "skill-sources");
  // Preserve any older copy that still uses its original materialization key.
  const destination = join(root, fingerprint(path + (compacted ? digest + ":compact-skill-v1" : digest)));
  await mkdir(root, { recursive: true, mode: 0o700 });
  const staged = await mkdtemp(join(root, ".import-"));
  try {
    for (const [name, contents] of retained) {
      if (!name.split("/").every(safeComponent)) throw new Error("invalid-archive-entry");
      const file = join(staged, name);
      await mkdir(dirname(file), { recursive: true, mode: 0o700 });
      await writeFile(file, contents, { mode: 0o600 });
    }
    try { await rename(staged, destination); }
    catch (error) {
      // An earlier import can already have materialized this version.
      if (!["EEXIST", "ENOTEMPTY"].includes(error.code)) throw error;
    }
    return join(destination, "SKILL.md");
  } finally { await rm(staged, { recursive: true, force: true }); }
}
