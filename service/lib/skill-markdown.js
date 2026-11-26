import { constants } from "node:fs";
import { copyFile, lstat, mkdtemp, realpath, rm, writeFile } from "node:fs/promises";
import { basename, extname, isAbsolute, join } from "node:path";
import { fingerprint, readLocal } from "./agent-config.js";
import { stageSkillFiles } from "./skill-archive.js";
import { maxSkillBytes, slimSkillMarkdown } from "./skill-import.js";

export async function readSkillMarkdown(path) {
  return (await readLocal(path, maxSkillBytes, { preserveBOM: true }))?.text;
}

async function saveInFolder(source, markdown, digest, directory) {
  if (typeof directory !== "string" || !isAbsolute(directory)) throw new Error("invalid-folder");
  const folder = await realpath(directory);
  const original = await lstat(source);
  const staging = await mkdtemp(join(folder, ".typeleast-markdown-"));
  const temporary = join(staging, "skill.md");
  const extension = extname(source);
  const stem = basename(source, extension);
  try {
    await writeFile(temporary, markdown, { mode: 0o600 });
    for (let index = 1; index <= 99; index += 1) {
      const destination = join(folder, index === 1 ? stem + extension : `${stem} (${index})${extension}`);
      try {
        await copyFile(temporary, destination, constants.COPYFILE_EXCL);
        return destination;
      } catch (error) {
        if (error.code !== "EEXIST") throw error;
      }
      const existing = await lstat(destination).catch(() => null);
      // Never use the original itself as the verified copy, including via an alias.
      if (!existing?.isFile() || existing.dev === original.dev && existing.ino === original.ino) continue;
      const text = await readSkillMarkdown(destination).catch(() => undefined);
      if (text != null && fingerprint(text) === digest) return destination;
    }
    throw new Error("file-name-conflict");
  } finally {
    await rm(staging, { recursive: true, force: true });
  }
}

export async function saveSkillMarkdown(storage, source, markdown, digest, { location, directory }) {
  const destination = location === "library"
    ? await stageSkillFiles(storage, source, digest, [["SKILL.md", markdown]])
    : await saveInFolder(source, markdown, digest, directory);
  const saved = await readSkillMarkdown(destination);
  const expected = location === "library" ? slimSkillMarkdown(markdown) : markdown;
  if (saved !== expected) throw new Error("copy-not-verified");
  return { source, destination, digest };
}
