import { createHash, randomUUID } from "node:crypto";
import { open, lstat, mkdir, rename, rm } from "node:fs/promises";
import { dirname, join } from "node:path";
import { isDeepStrictEqual } from "node:util";
import { applyEdits, modify, parse as parseJSON, visit } from "jsonc-parser";
import { parse as parseTOML, stringify as stringifyTOML } from "smol-toml";
import { parseDocument } from "yaml";

export const fingerprint = (text) => createHash("sha256").update(text).digest("hex");

const maxConfigBytes = 8 * 1024 * 1024;

export async function readLocal(path, maxBytes = maxConfigBytes, { follow = false, preserveBOM = false } = {}) {
  try {
    const info = await lstat(path);
    if (!(info.isFile() || (follow && info.isSymbolicLink()))) throw new Error("not-file");
    const file = await open(path, "r");
    try {
      const stat = await file.stat();
      if (!stat.isFile() || stat.size > maxBytes) throw new Error("unsupported-file");
      const buffer = Buffer.alloc(stat.size + 1);
      const { bytesRead } = await file.read(buffer, 0, buffer.length, 0);
      if (bytesRead > maxBytes) throw new Error("unsupported-file");
      const text = new TextDecoder("utf-8", { fatal: true, ignoreBOM: preserveBOM }).decode(buffer.subarray(0, bytesRead));
      return { text, mode: stat.mode & 0o777 };
    } finally {
      await file.close();
    }
  } catch (error) {
    if (error.code === "ENOENT") return null;
    throw error;
  }
}

export async function replaceLocal(path, previous, text, { maxBytes, preserveBOM = false } = {}) {
  await mkdir(dirname(path), { recursive: true, mode: 0o700 });
  const temporary = join(dirname(path), ".typeleast-" + randomUUID());
  try {
    const handle = await open(temporary, "wx", previous?.mode ?? 0o600);
    try {
      await handle.writeFile(text, "utf8");
      await handle.sync();
    } finally {
      await handle.close();
    }
    const latest = await readLocal(path, maxBytes, { preserveBOM });
    if (latest?.text !== previous?.text) throw new Error("changed");
    await rename(temporary, path);
  } finally {
    await rm(temporary, { force: true });
  }
}

export function configObject(format, text) {
  if (!text.trim()) return {};
  let object;
  switch (format) {
    case "toml": object = parseTOML(text); break;
    case "yaml": {
      const document = parseDocument(text, { uniqueKeys: true });
      if (document.errors.length) throw new Error("invalid-config");
      object = document.toJS({ maxAliasCount: 20 });
      break;
    }
    default: {
      const errors = [];
      const options = { allowTrailingComma: format === "jsonc", disallowComments: format === "json" };
      object = parseJSON(text, errors, options);
      if (errors.length) throw new Error("invalid-config");
      const keys = [];
      visit(text, {
        onObjectBegin: () => keys.push(new Set()),
        onObjectEnd: () => keys.pop(),
        onObjectProperty: (key) => {
          const current = keys.at(-1);
          if (current?.has(key)) throw new Error("invalid-config");
          current?.add(key);
        },
      }, options);
    }
  }
  if (object == null || Array.isArray(object) || typeof object !== "object") throw new Error("invalid-config");
  return object;
}

function tablePath(line) {
  if (!/^\s*\[[^[]/u.test(line)) return null;
  try {
    let tree = parseTOML(line + "\n__typeleast_probe = true");
    const path = [];
    while (!Object.hasOwn(tree, "__typeleast_probe")) {
      const keys = Object.keys(tree);
      if (keys.length !== 1) return null;
      tree = tree[keys[0]];
      path.push(keys[0]);
    }
    return path;
  } catch {
    return null;
  }
}

function removeTomlTable(text, path) {
  const lines = text.split(/(?<=\n)/u);
  const prefix = (candidate) => path.every((part, index) => part === candidate?.[index]);
  let dropping = false;
  return lines.filter((line) => {
    const header = tablePath(line.trimEnd());
    if (header || /^\s*\[\[/u.test(line)) dropping = prefix(header);
    return !dropping || /^\s*(?:#|$)/u.test(line);
  }).join("");
}

export function editConfig(format, text, path, value) {
  const expected = configObject(format, text);
  let parent = expected;
  for (const key of path.slice(0, -1)) {
    if (!Object.hasOwn(parent, key)) Object.defineProperty(parent, key, { value: {}, enumerable: true, configurable: true, writable: true });
    parent = parent[key];
    if (!parent || typeof parent !== "object" || Array.isArray(parent)) throw new Error("invalid-config");
  }
  if (value === undefined) delete parent[path.at(-1)];
  else Object.defineProperty(parent, path.at(-1), { value, enumerable: true, configurable: true, writable: true });
  let output;
  switch (format) {
    case "toml": {
      if (value === undefined) {
        output = removeTomlTable(text, path);
        // Removing the only child also removes the implicitly declared parent.
        if (!Object.keys(parent).length && !configObject(format, output)[path[0]]) delete expected[path[0]];
      } else {
        output = text.trim() ? text.replace(/\s*$/u, "\n\n") : "";
        output += "[" + path.map(key => JSON.stringify(key)).join(".") + "]\n" + stringifyTOML(value);
      }
      break;
    }
    case "yaml": {
      const doc = parseDocument(text.trim() ? text : "{}\n", { uniqueKeys: true });
      if (value === undefined) doc.deleteIn(path);
      else doc.setIn(path, value);
      output = doc.toString();
      break;
    }
    default: {
      const body = text.trim() || "{}";
      output = applyEdits(body, modify(body, path, value, { formattingOptions: { insertSpaces: true, tabSize: 2 } }));
    }
  }
  // An adapter must never discard settings it did not intend to edit.
  const actual = configObject(format, output);
  const sortKeys = (object) => {
    if (Array.isArray(object)) return object.map(sortKeys);
    if (!object || Object.prototype.toString.call(object) !== "[object Object]") return object;
    return Object.fromEntries(Object.entries(object).map(([key, item]) => [key, sortKeys(item)]));
  };
  if (!isDeepStrictEqual(sortKeys(expected), sortKeys(actual))) throw new Error("unsupported-layout");
  return output.trimEnd() + "\n";
}
