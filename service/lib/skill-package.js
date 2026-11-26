import { constants } from "node:fs";
import { open } from "node:fs/promises";
import { basename, dirname, extname, join } from "node:path";
import { inflateRawSync } from "node:zlib";
import { fingerprint } from "./agent-config.js";
import { stageSkillFiles } from "./skill-archive.js";

const maxArchiveBytes = 24 * 1024 * 1024;
const maxManifestBytes = 512 * 1024;
const utf8 = new TextDecoder("utf-8", { fatal: true });
const version = /^\.(?:skill|zip)$/iu;
const validPart = name => name.length > 0 && name !== "." && name !== ".." && !/[:\\\p{Cc}]/u.test(name);

export const isSkillPackage = path => version.test(extname(path));

async function archiveBytes(path) {
  const file = await open(path, constants.O_RDONLY | constants.O_NONBLOCK | constants.O_NOFOLLOW);
  try {
    const stat = await file.stat();
    if (!stat.isFile() || stat.size < 22 || stat.size > maxArchiveBytes) throw new Error("invalid-skill-package");
    const bytes = Buffer.alloc(stat.size + 1);
    if ((await file.read(bytes, 0, bytes.length, 0)).bytesRead !== stat.size) throw new Error("changed");
    return bytes.subarray(0, stat.size);
  } finally { await file.close(); }
}

function zipEntries(bytes) {
  let end = bytes.length - 22;
  const min = Math.max(0, end - 65535);
  while (end >= min && (bytes.readUInt32LE(end) !== 0x06054b50 || end + 22 + bytes.readUInt16LE(end + 20) !== bytes.length)) end -= 1;
  if (end < min || bytes.readUInt32LE(end + 4) !== 0) throw new Error("invalid-skill-package");

  const count = bytes.readUInt16LE(end + 10);
  const start = bytes.readUInt32LE(end + 16);
  const stop = start + bytes.readUInt32LE(end + 12);
  if (count > 512 || count !== bytes.readUInt16LE(end + 8) || stop !== end) throw new Error("invalid-skill-package");
  const entries = new Map();
  let position = start;
  for (let index = 0; index < count; index++) {
    if (position + 46 > stop || bytes.readUInt32LE(position) !== 0x02014b50) throw new Error("invalid-skill-package");
    const flags = bytes.readUInt16LE(position + 8);
    const method = bytes.readUInt16LE(position + 10);
    const compressed = bytes.readUInt32LE(position + 20);
    const size = bytes.readUInt32LE(position + 24);
    const nameSize = bytes.readUInt16LE(position + 28);
    const nameStart = position + 46;
    const nameEnd = nameStart + nameSize;
    const next = nameEnd + bytes.readUInt16LE(position + 30) + bytes.readUInt16LE(position + 32);
    const disk = bytes.readUInt16LE(position + 34);
    const kind = (bytes.readUInt32LE(position + 38) >>> 16) & 0xf000;
    const local = bytes.readUInt32LE(position + 42);
    if (next > stop || disk !== 0 || local + 30 > start || nameSize === 0 || size > maxArchiveBytes) throw new Error("invalid-skill-package");
    const name = utf8.decode(bytes.subarray(nameStart, nameEnd));
    position = next;
    if (!name.replace(/\/$/u, "").split("/").every(validPart)) throw new Error("invalid-skill-package");
    if (name.endsWith("/") || name.startsWith("__MACOSX/") || basename(name) === ".DS_Store") continue;
    if (![0, 0x8000].includes(kind) || (flags & 0x41) || ![0, 8].includes(method)) throw new Error("invalid-skill-package");
    const localNameSize = bytes.readUInt16LE(local + 26);
    const payload = local + 30 + localNameSize + bytes.readUInt16LE(local + 28);
    if (bytes.readUInt32LE(local) !== 0x04034b50 || bytes.readUInt16LE(local + 8) !== method ||
        payload + compressed > start || localNameSize !== nameSize ||
        !bytes.subarray(local + 30, local + 30 + localNameSize).equals(bytes.subarray(nameStart, nameEnd))) {
      throw new Error("invalid-skill-package");
    }
    const key = name.normalize("NFC").toLowerCase();
    if (entries.has(key)) throw new Error("invalid-skill-package");
    entries.set(key, { name, method, payload, compressed, size });
  }
  if (position !== stop) throw new Error("invalid-skill-package");
  return [...entries.values()];
}

function decompress(bytes, entry) {
  const packed = bytes.subarray(entry.payload, entry.payload + entry.compressed);
  const content = entry.method === 0 ? packed : inflateRawSync(packed, { maxOutputLength: Math.max(entry.size, 1) });
  if (content.length !== entry.size) throw new Error("invalid-skill-package");
  return content;
}

export async function readSkillPackage(path, includeFiles = false) {
  const bytes = await archiveBytes(path);
  const entries = zipEntries(bytes);
  const manifests = entries.filter(entry => basename(entry.name).toLowerCase() === "skill.md");
  if (manifests.length !== 1 || manifests[0].size > maxManifestBytes) return null;
  const manifest = manifests[0];
  const name = dirname(manifest.name);
  const prefix = name === "." ? "" : name + "/";
  const packageEntries = entries.filter(entry => entry.name.startsWith(prefix));
  if (packageEntries.reduce((total, entry) => total + entry.size, 0) > maxArchiveBytes) return null;
  const files = packageEntries.map(entry => [entry === manifest ? "SKILL.md" : entry.name.slice(prefix.length), entry]);
  const children = [...new Set(files.map(([relative]) => relative.split("/")[0]))];
  return {
    text: utf8.decode(decompress(bytes, manifest)),
    manifestPath: join(dirname(path), name === "." ? basename(path, extname(path)) : basename(name), "SKILL.md"),
    children,
    digest: fingerprint(bytes),
    files: includeFiles ? files.map(([relative, entry]) => [relative, decompress(bytes, entry)]) : undefined,
  };
}

export async function stageSkillPackage(storage, path, digest) {
  const contents = await readSkillPackage(path, true);
  if (contents?.digest !== digest) throw new Error("changed");
  return await stageSkillFiles(storage, path, digest, contents.files);
}
