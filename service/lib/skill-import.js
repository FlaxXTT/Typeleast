import { readdir } from "node:fs/promises";
import { basename, dirname, extname, isAbsolute } from "node:path";
import { isDeepStrictEqual } from "node:util";
import { isMap, isScalar, parseDocument } from "yaml";
import { configObject, fingerprint, readLocal } from "./agent-config.js";
import { redactSecrets } from "./context.js";

export const maxSkillBytes = 512 * 1024;
const fileExtension = /\.(?:md|mdx|txt|json|jsonc|ya?ml|toml|xml|csv|pdf|py|sh|bash|js|mjs|ts|sql|png|jpe?g|svg|webp)\b/iu;
const supportingFolders = /(?:^|[^\p{L}\p{N}_])(?:scripts|references|assets|templates|resources)[\\/]/iu;
const toolFields = ["allowed-tools", "requires", "dependencies", "scripts", "resources", "references", "assets", "hooks", "mcpServers"];
const frontMatter = /^\uFEFF?---[ \t]*\r?\n([\s\S]*?)(?<=\n)(?:---|\.\.\.)[ \t]*(?:\r?\n|$)/du;
const omittedFields = new Set(["license", "license-file", "license-url", "trigger-call-header"]);
const omittedMetadata = new Set([...omittedFields, "author", "authors", "skill-author", "copyright", "version", "last-reviewed"]);
const label = text => typeof text === "string" ? redactSecrets(text).replace(/[\p{Cc}\p{Cf}]/gu, " ").trim().slice(0, 160) : "";

export const isMarkdownFile = path => /\.(?:md|markdown)$/iu.test(path);

const normalizedKey = key => typeof key === "string" ? key.toLowerCase().replace(/[\s_]+/gu, "-") : "";
const pairKey = pair => isScalar(pair.key) ? normalizedKey(pair.key.value) : "";

export function slimSkillMarkdown(text) {
  const match = text.match(frontMatter);
  if (!match) return text;
  const yaml = match[1];
  try {
    const document = parseDocument(yaml, { uniqueKeys: true });
    if (document.errors.length || !isMap(document.contents) || document.contents.flow) return text;
    const original = document.toJS({ maxAliasCount: 20 });
    const expected = { ...original };
    const cuts = [];
    function removeLine(pair) {
      const keyStart = pair.key.range[0];
      const start = yaml.lastIndexOf("\n", keyStart - 1) + 1;
      if (!/^[ \t]*$/u.test(yaml.slice(start, keyStart))) return false;
      const valueEnd = pair.value?.range?.[1] ?? pair.key.range[1];
      const lineEnd = yaml.indexOf("\n", Math.max(keyStart, valueEnd - 1));
      cuts.push([start, lineEnd === -1 ? yaml.length : lineEnd + 1]);
      return true;
    }
    for (const pair of document.contents.items) {
      const key = pairKey(pair);
      if (omittedFields.has(key)) {
        if (removeLine(pair)) delete expected[pair.key.value];
      } else if (key === "metadata" && isMap(pair.value) && pair.value.items.length) {
        const entries = pair.value.items.filter(entry => omittedMetadata.has(pairKey(entry)));
        if (entries.length === pair.value.items.length && removeLine(pair)) {
          delete expected[pair.key.value];
        } else if (!pair.value.flow && Object.hasOwn(expected, pair.key.value)) {
          const metadata = { ...expected[pair.key.value] };
          for (const entry of entries) {
            if (removeLine(entry)) delete metadata[entry.key.value];
          }
          expected[pair.key.value] = metadata;
        }
      }
    }
    if (!cuts.length) return text;
    let compact = yaml;
    for (const [start, end] of cuts.sort((a, b) => b[0] - a[0])) {
      compact = compact.slice(0, start) + compact.slice(end);
    }
    // Aliases can tie removed fields to retained values. Preserve the original on ambiguity.
    if (!isDeepStrictEqual(configObject("yaml", compact), expected)) return text;
    const [start, end] = match.indices[1];
    return text.slice(0, start) + compact + text.slice(end);
  } catch {
    return text;
  }
}

function hasValue(value) {
  if (Array.isArray(value)) return value.length > 0;
  if (value && typeof value === "object") return Object.keys(value).length > 0;
  return Boolean(value);
}

function hasFileReference(body) {
  if (supportingFolders.test(body) || /\bfile:\/\/|\b(?:SKILL|CLAUDE_SKILL)[_-](?:DIR|ROOT|PATH)\b/iu.test(body)) return true;
  const markdownTargets = /(!?)\[[^\]\n]*\]\(\s*(?:<([^>\n]+)>|([^\s)]+))/gu;
  const referenceTargets = /^\s{0,3}\[[^\]\n]+\]:\s*(?:<([^>\n]+)>|(\S+))/gmu;
  const localTarget = value => !/^(?:#|https?:\/\/|mailto:)/iu.test(value);
  for (const [, image, angled, simple] of body.matchAll(markdownTargets)) {
    if (image || localTarget(angled ?? simple)) return true;
  }
  for (const [, angled, simple] of body.matchAll(referenceTargets)) {
    if (localTarget(angled ?? simple)) return true;
  }
  for (const [, path] of body.matchAll(/`((?:\.\.?[\\/]|~[\\/]|\/)[^`\n]+)`/gu)) {
    if (fileExtension.test(path) || !path.includes(" ")) return true;
  }
  const directReads = /(?:\b(?:read|load|open|run|execute|source|include|follow|see)\s+(?:the\s+)?|(?:读取|打开|载入|加载|运行|执行|参见)\s*)[`"'‘“]?([^\s`"'’”]+[.][a-z0-9]+)/giu;
  for (const [, path] of body.matchAll(directReads)) {
    if (localTarget(path) && fileExtension.test(path)) return true;
  }
  return /<(?:img|script)\b[^>]*\bsrc\s*=/iu.test(body) || /\b(?:href|src)\s*=\s*["'](?:file:\/\/|\.\.?\/)/iu.test(body);
}

function hasMarkdownSource(item) {
  return Array.isArray(item.sources) && item.sources.some(source =>
    source.agent === "manual" && typeof source.path === "string" && isAbsolute(source.path) &&
    isMarkdownFile(source.path));
}

export function isIndependentSpeak(item) {
  const managedGitHubMarkdown = /^[a-f0-9]{64}$/u.test(item.markdownDigest ?? "") &&
    item.sources?.some(source => source.agent === "github" && typeof source.path === "string" &&
      source.path.startsWith("https://github.com/") && isMarkdownFile(source.path));
  return item.kind === "skill" && item.imported === true && item.dependencies === false &&
    (hasMarkdownSource(item) || managedGitHubMarkdown) && typeof item.body === "string" && item.body.trim().length > 0 &&
    !item.body.includes("\0") && !hasFileReference(item.body);
}

export function isSkillReference(item) {
  return item.kind === "skill" && item.imported === true && hasMarkdownSource(item) &&
    (item.importMode === "reference" || (item.importMode === "linked" && item.dependencies === true &&
      typeof item.body === "string" && item.body.trim().length > 0));
}

export function parseSpeak(path, text, neighbors = []) {
  const source = text.replace(/^\uFEFF/u, "");
  const front = source.match(frontMatter);
  if (/^---[ \t]*\r?\n/u.test(source) && !front) return null;
  const meta = front ? configObject("yaml", front[1]) : {};
  const body = source.slice(front?.[0].length ?? 0).trim();
  if (!body || body.includes("\0")) return null;
  const skillFile = basename(path).toLowerCase() === "skill.md";
  const parentName = basename(dirname(path));
  const declaredName = label(meta.name);
  const name = declaredName || label(skillFile ? parentName : basename(path).slice(0, -extname(path).length));
  const namedSkillFolder = declaredName.toLowerCase() === parentName.toLowerCase();
  const relatedFiles = skillFile ? neighbors.filter(name =>
    /^(?:scripts|references|assets|templates|resources)$/iu.test(name) ||
    namedSkillFolder && !name.startsWith(".") && name !== basename(path) &&
    !/^(?:readme|licen[cs]e|copying|notice)(?:\.[a-z0-9]+)?$/iu.test(name))
    .map(label).sort().slice(0, 12) : [];
  const fields = toolFields.filter(field => hasValue(meta[field]));
  const usesFiles = hasFileReference(body);
  return {
    item: { id: "skill:" + fingerprint(body), kind: "skill", name, description: label(meta.description), body,
      imported: true, dependencies: Boolean(fields.length || usesFiles || relatedFiles.length), sources: [{ agent: "manual", path }] },
    fields, usesFiles, relatedFiles, digest: fingerprint(source),
  };
}

export async function readSpeak(path) {
  const file = await readLocal(path, maxSkillBytes, { preserveBOM: true });
  if (!file) return null;
  const neighbors = basename(path).toLowerCase() === "skill.md" ? await readdir(dirname(path)) : [];
  const parsed = parseSpeak(path, file.text, neighbors);
  return parsed ? { ...parsed, markdown: file.text, digest: fingerprint(file.text) } : null;
}
