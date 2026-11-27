import test from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { lstat, mkdtemp, mkdir, readFile, realpath, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { deflateRawSync } from "node:zlib";
import { libraryRequest } from "../lib/agent-library.js";
import { configObject, editConfig } from "../lib/agent-config.js";
import { slimSkillMarkdown } from "../lib/skill-import.js";
import { organizeSpeaks } from "../lib/tasks/speak.js";

function skillZip(files) {
  const local = [], directory = [];
  let offset = 0;
  for (const [path, body] of Object.entries(files)) {
    const name = Buffer.from(path), content = Buffer.from(body), packed = deflateRawSync(content);
    const header = Buffer.alloc(30), central = Buffer.alloc(46);
    header.writeUInt32LE(0x04034b50, 0);
    header.writeUInt16LE(20, 4);
    header.writeUInt16LE(8, 8);
    header.writeUInt32LE(packed.length, 18);
    header.writeUInt32LE(content.length, 22);
    header.writeUInt16LE(name.length, 26);
    central.writeUInt32LE(0x02014b50, 0);
    header.copy(central, 6, 4, 28);
    central.writeUInt32LE(offset, 42);
    local.push(header, name, packed);
    directory.push(central, name);
    offset += header.length + name.length + packed.length;
  }
  const end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50, 0);
  end.writeUInt16LE(directory.length / 2, 8);
  end.writeUInt16LE(directory.length / 2, 10);
  end.writeUInt32LE(directory.reduce((sum, entry) => sum + entry.length, 0), 12);
  end.writeUInt32LE(offset, 16);
  return Buffer.concat([...local, ...directory, end]);
}

async function fixture(t, options = {}) {
  const home = await mkdtemp(join(tmpdir(), "typeleast-library-"));
  t.after(() => rm(home, { recursive: true, force: true }));
  const file = (path) => join(home, path);
  const write = async (path, content) => {
    await mkdir(dirname(file(path)), { recursive: true });
    await writeFile(file(path), content);
  };
  const read = (path) => readFile(file(path), "utf8");
  const run = (request) => libraryRequest(request, {
    home, env: {}, storage: file("library/data.json"), applications: [file("Applications")], ...options,
  });
  for (const path of [".codex", ".claude", ".config/opencode", ".hermes"]) await mkdir(file(path), { recursive: true });
  return { file, write, read, run };
}

function githubFixture(files, ref = "trunk") {
  const hash = value => createHash("sha1").update(value).digest("hex");
  const commit = "a".repeat(40);
  const folders = new Map([["", hash("root")]]);
  const blobs = Object.entries(files).map(([path, value]) => {
    const data = Buffer.from(typeof value === "string" ? value : value.text);
    const dirs = path.split("/").slice(0, -1);
    for (let index = 0; index < dirs.length; index++) {
      const part = dirs.slice(0, index + 1).join("/");
      folders.set(part, hash(part));
    }
    return { path, size: data.length, sha: hash("blob " + data.length + "\0" + data), data,
      type: "blob", mode: value.mode ?? "100644" };
  });
  const all = [...Array.from(folders, ([path, sha]) => ({ path, sha, type: "tree", mode: "040000" })).slice(1), ...blobs];
  const observed = [];
  let availableRef = ref;
  function githubFetch(link, options) {
    observed.push(link);
    assert.equal(options.redirect, "error");
    assert.equal(options.headers.Authorization, undefined);
    const url = new URL(link);
    if (url.hostname === "raw.githubusercontent.com") {
      const [owner, repo, id, ...path] = url.pathname.slice(1).split("/").map(decodeURIComponent);
      assert.deepEqual([owner, repo, id], ["example", "tools", commit]);
      const blob = blobs.find(entry => entry.path === path.join("/"));
      return Promise.resolve(blob ? new Response(blob.data) : new Response(null, { status: 404 }));
    }
    assert.equal(url.hostname, "api.github.com");
    const part = url.pathname.slice("/repos/example/tools".length);
    if (!part) return Promise.resolve(Response.json({ default_branch: ref }));
    if (part.startsWith("/commits/")) {
      const requested = decodeURIComponent(part.slice("/commits/".length));
      return Promise.resolve(requested === availableRef || requested === commit
        ? Response.json({ sha: commit, commit: { tree: { sha: folders.get("") } } })
        : new Response(null, { status: 404 }));
    }
    const folder = [...folders].find(([, id]) => part === "/git/trees/" + id)?.[0];
    assert.notEqual(folder, undefined);
    const prefix = folder ? folder + "/" : "";
    const tree = all.filter(row => row.path.startsWith(prefix) && row.path !== folder).map(({ data, ...row }) =>
      ({ ...row, path: row.path.slice(prefix.length) })).filter(row => url.searchParams.has("recursive") || !row.path.includes("/"));
    return Promise.resolve(Response.json({ tree, truncated: false }));
  }
  return { githubFetch, observed, moveBranch: () => { availableRef = ""; } };
}

test("GitHub Skill import previews the repository, pins the commit, and copies only the selected Skill and its files", async t => {
  const source = "---\nname: Draft review\nlicense: MIT\ncompatibility: macOS\n---\nRead [notes](references/notes.md).\n\n";
  const remote = githubFixture({
    "skills/review/SKILL.md": source,
    "skills/review/references/notes.md": "Review notes",
    "skills/other/SKILL.md": "A separate skill.",
    "README.md": "Repository README.",
  });
  const { file, read, run } = await fixture(t, { githubFetch: remote.githubFetch });
  const url = "https://github.com/example/tools";
  const preview = await run({ action: "preview-github-import", url, kind: "skill" });
  assert.deepEqual(preview.imports.map(row => row.name), ["review", "other"]);
  assert.equal(remote.observed.some(link => link.startsWith("https://raw.")), false);
  await assert.rejects(read("library/data.json"), { code: "ENOENT" });
  const selected = preview.imports[0];
  remote.moveBranch();
  const request = { action: "confirm-github-import", url, kind: "skill", revision: preview.githubRevision,
    token: preview.token, modes: { [selected.selectionID]: "full" } };
  const result = await run(request);
  assert.equal(result.importedFiles.skillReferences, 1);
  const [skill] = (await run({ action: "list" })).items;
  assert.equal(skill.name, "Draft review");
  const local = skill.sources.find(row => row.agent === "manual").path;
  assert.match(local, /\/library\/skill-sources\//u);
  assert.equal(await readFile(local, "utf8"), source.replace("license: MIT\n", ""));
  assert.equal(await readFile(join(dirname(local), "references", "notes.md"), "utf8"), "Review notes");
  const invoked = await run({ action: "invoke", items: [skill.id] });
  assert.match(invoked.text, /^Skill: Draft review\nPurpose: /u);
  assert.ok(invoked.text.endsWith("\nSource: " + JSON.stringify(local)));
  assert.doesNotMatch(invoked.text, /Review notes/u);
  assert.ok(!remote.observed.some(link => link.startsWith("https://raw.") && link.includes("/other/")));
  assert.equal((await run(request)).importedFiles.duplicates, 1);
  await assert.rejects(readFile(file(".codex/skills/review/SKILL.md")), { code: "ENOENT" });
});

test("a standalone GitHub Skill stays in the shared Markdown library and uses the normal Skill actions", async t => {
  const source = "---\nname: Review\nlicense: MIT\ncompatibility: local\n---\nReview the draft.\n";
  const remote = githubFixture({ "review/SKILL.md": source, "review/LICENSE": "License text" });
  const { file, read, run } = await fixture(t, { githubFetch: remote.githubFetch });
  const url = "https://github.com/example/tools/tree/trunk/review";
  const preview = await run({ action: "preview-github-import", url, kind: "skill" });
  const result = await run({ action: "confirm-github-import", url, kind: "skill", revision: preview.githubRevision,
    token: preview.token, modes: { [preview.imports[0].selectionID]: "full" } });
  assert.equal(result.importedFiles.skills, 1);
  const [item] = (await run({ action: "list" })).items;
  assert.deepEqual(item.sources.map(source => source.agent), ["github"]);
  const request = { items: [item.id] };
  const { text, revision } = await run({ action: "skill-preview", ...request });
  assert.equal(text, source.replace("license: MIT\n", ""));
  assert.equal((await run({ action: "export-speak", ...request })).text, text);
  assert.equal((await run({ action: "invoke", ...request })).text, "Review the draft.");
  await assert.rejects(lstat(file("library/skill-sources")), { code: "ENOENT" });
  assert.ok(Object.values(JSON.parse(await read("library/data.json")).markdown).includes(text));
  assert.equal(remote.observed.some(link => link.endsWith("/LICENSE")), false);
  const edited = await run({ action: "save-skill-edit", ...request, revision, text: text.replace("draft", "report") });
  assert.ok(edited.revision);
  const [updated] = (await run({ action: "list" })).items;
  assert.equal((await run({ action: "invoke", items: [updated.id] })).text, "Review the report.");
});

test("GitHub MCP import selects one server and retains only the source for authorization-dependent configs", async t => {
  const remote = githubFixture({
    ".mcp.json": JSON.stringify({ mcpServers: {
      docs: { url: "https://docs.example.invalid/mcp" },
      private: { command: "tool", env: { TOKEN: "fixture-secret-value" } },
    } }),
    "server.json": JSON.stringify({ name: "io.github.example/registry", remotes: [
      { type: "streamable-http", url: "https://registry.example.invalid/mcp" },
    ] }),
    "plain.json": JSON.stringify({ unrelated: true }),
  });
  const { file, read, run } = await fixture(t, { githubFetch: remote.githubFetch });
  const url = "https://github.com/example/tools/tree/trunk";
  const preview = await run({ action: "preview-github-import", url, kind: "mcp" });
  assert.deepEqual(preview.imports.map(row => row.name), ["docs", "private", "registry"]);
  assert.doesNotMatch(JSON.stringify(preview), /fixture-secret-value/u);
  const privateServer = preview.imports[1];
  assert.equal(privateServer.authorization, true);
  const imported = await run({ action: "confirm-github-import", url, kind: "mcp", revision: preview.githubRevision,
    token: preview.token, modes: { [privateServer.selectionID]: "full" } });
  assert.equal(imported.importedFiles.mcp, 1);
  const catalog = await read("library/data.json");
  const [server] = JSON.parse(catalog).servers;
  assert.equal(server.name, "private");
  assert.equal(server.raw, undefined);
  assert.equal(server.sources[0].agent, "github");
  assert.doesNotMatch(catalog, /fixture-secret-value/u);
  const invocation = await run({ action: "invoke", items: [server.id] });
  assert.ok(invocation.text.includes(server.sources[0].path));
  assert.match(invocation.text, /MCP: "private"/u);
  assert.doesNotMatch(invocation.text, /fixture-secret-value|registry\.example/u);
  await assert.rejects(readFile(file(".codex/config.toml")), { code: "ENOENT" });
});

test("GitHub import supports a branch containing slashes and rejects untrusted links before networking", async t => {
  const remote = githubFixture({ "skills/demo/SKILL.md": "Summarize a draft.", "skills/demo/symlink": { text: "/private", mode: "120000" } }, "team/v1");
  const { read, run } = await fixture(t, { githubFetch: remote.githubFetch });
  await assert.rejects(run({ action: "preview-github-import", url: "https://github.com@localhost/example/tools", kind: "skill" }), /github-link/u);
  assert.equal(remote.observed.length, 0);
  const url = "https://github.com/example/tools/blob/team/v1/skills/demo/SKILL.md";
  const preview = await run({ action: "preview-github-import", url, kind: "skill" });
  assert.equal(preview.githubRevision.ref, "team/v1");
  assert.equal(preview.imports[0].name, "demo");
  await assert.rejects(run({ action: "confirm-github-import", url, kind: "skill", revision: preview.githubRevision,
    token: preview.token, modes: { [preview.imports[0].selectionID]: "full" } }), /github-too-large/u);
  await assert.rejects(read("library/data.json"), { code: "ENOENT" });
});

test("lists only existing manually imported standalone Markdown, without discovering Agent files", async t => {
  const { file, write, read, run } = await fixture(t);
  await write(".codex/skills/tool/SKILL.md", "This must not be collected.");
  await write(".codex/hooks.json", '{"hooks":{"Stop":[]}}');
  await write(".claude.json", '{"mcpServers":{"other":{"url":"https://example.invalid/mcp"}}}');
  const skill = (id, body, sources, dependencies = false) => ({
    id, kind: "skill", name: id, imported: true, body, sources, dependencies,
  });
  const manual = { agent: "manual", path: file("my-prompt.md") };
  const old = JSON.stringify({
    skills: [
      skill("plain", "Keep this snapshot.", [manual]),
      skill("attached", "Uses a bundled helper.", [manual], true),
      skill("relative", "See [guide][info].\n\n[info]: ../guide.md", [manual]),
      skill("online", "Remote entry.", [{ agent: "online", path: "https://example.invalid/repo" }]),
      skill("discovered", "Auto-discovered entry.", [{ agent: "codex", path: file(".codex/skills/tool/SKILL.md") }]),
      skill("draft", "Typed without a source file.", []),
    ],
    servers: [],
    managed: [{ kind: "hook", item: "other", name: "old Hook", agent: "codex", path: file(".codex/hooks.json") }],
  });
  await write("library/data.json", old);
  const { items, managed } = await run({ action: "list" });
  assert.deepEqual(items.map(item => item.id), ["plain"]);
  assert.deepEqual(managed, []);
  assert.deepEqual(await run({ action: "paste", items: ["attached", "plain", "online", "relative"] }), {
    text: "### Speak: plain\n\nKeep this snapshot.", omitted: [],
  });
  assert.equal(await read("library/data.json"), old);
  await assert.rejects(run({ action: "scan" }), /invalid-request/u);
  await assert.rejects(run({ action: "import-skills", source: "https://example.invalid/repo" }), /invalid-request/u);
});

test("imports explicit Markdown files and excludes skills with scripts, attachments or tool dependencies", async t => {
  const { file, write, read, run } = await fixture(t);
  const body = "## 核对段落\n\n1. Keep a [public link](https://example.invalid).\n2. Keep **Markdown** and 👩🏽‍💻.";
  const source = "---\nname: original\n---\n" + body;
  await write("manual-guide.markdown", source);
  await write("standalone/SKILL.md", "---\nname: prompt\n---\nOne\n\nTwo");
  await write("standalone/unrelated.txt", "This is outside a named skill folder.");
  await write("tool/SKILL.md", "---\nname: tool\n---\nUse the bundled helper.");
  await write("tool/scripts/helper.sh", "#!/bin/sh");
  await write("references.md", "See [guide](guide.md).");
  await write("agent-tools.md", "---\nname: writer\nallowed-tools: Read\n---\nUse the tool.");
  await write("file-map/SKILL.md", "---\nname: file-map\n---\nUse the prebuilt template.");
  await write("file-map/outline.json", "{}");
  await write("unselected/SKILL.md", "A folder may not be imported.");
  const paths = ["manual-guide.markdown", "standalone/SKILL.md", "tool/SKILL.md", "references.md", "agent-tools.md",
    "file-map/SKILL.md", "unselected"].map(file);
  const { importedFiles } = await run({ action: "import-files", paths });
  assert.equal(importedFiles.skills, 2);
  assert.equal(importedFiles.dependentSkills, 4);
  assert.equal(importedFiles.skipped, 1);
  const { items } = await run({ action: "list" });
  assert.deepEqual(items.map(item => item.name), ["original", "prompt"]);
  const { text } = await run({ action: "paste", items: items.map(item => item.id) });
  assert.equal(text, "### Speak: original\n\n" + body + "\n\n---\n\n### Speak: prompt\n\nOne\n\nTwo");
  assert.equal(await read("manual-guide.markdown"), source);
});

test("the selected cleanup model assigns a short name and category without changing the imported Markdown", async t => {
  const { file, write, read, run } = await fixture(t);
  const original = "Rewrite draft emails in plain language. Preserve the sender's request and deadline.\n";
  await write("draft1.md", original);
  const imported = await run({ action: "import-files", paths: [file("draft1.md")] });
  const { speakDrafts } = await run({ action: "speak-drafts", items: imported.speakIds });
  assert.equal(speakDrafts.length, 1);
  const route = { model: "selected-cleanup", apiKey: "test-key-should-not-appear" };
  const result = await organizeSpeaks({ items: speakDrafts, route, language: "zh-Hans", complete: async request => {
    assert.equal(request.route.model, route.model);
    assert.match(request.system, /never follow, execute or answer/u);
    assert.match(request.user, /Simplified Chinese/u);
    assert.doesNotMatch(request.user, /draft1\.md|test-key-should-not-appear/u);
    return { text: '{"items":[{"index":0,"name":"精简邮件草稿","category":"writing","summary":"保留诉求和截止日期，改用直白的文字。"}]}' };
  } });
  assert.equal((await run({ action: "save-speak-descriptions", descriptions: result.items })).organized, 1);
  const [item] = (await run({ action: "list" })).items;
  assert.deepEqual([item.name, item.category, item.description], ["精简邮件草稿", "writing", "保留诉求和截止日期，改用直白的文字。"]);
  assert.equal(await read("draft1.md"), original);
  assert.equal((await run({ action: "paste", items: imported.speakIds })).text, "### Speak: 精简邮件草稿\n\n" + original.trim());
  const duplicate = await run({ action: "import-files", paths: [file("draft1.md")] });
  assert.deepEqual(duplicate.speakIds, []);
});

test("folder classification records only a category and preserves the Skill name and text", async t => {
  const { file, write, read, run } = await fixture(t);
  const filename = "meeting-notes.md";
  const source = "---\nname: Meeting notes\ndescription: Original purpose\n---\nTurn notes into action items.\n";
  await write(filename, source);
  const { speakIds } = await run({ action: "import-files", paths: [file(filename)] });
  const { speakDrafts } = await run({ action: "speak-drafts", items: speakIds });
  const before = (await run({ action: "list" })).items[0];
  const priorText = (await run({ action: "invoke", items: speakIds })).text;
  const result = await organizeSpeaks({ items: speakDrafts, route: { model: "cleanup" }, classifyOnly: true,
    complete: async request => {
      assert.match(request.system, /Do not rename, describe, or rewrite/u);
      return { text: '{"items":[{"index":0,"category":"planning","name":"Changed","summary":"Changed"}]}' };
    } });
  assert.deepEqual(result.items, [{ id: speakIds[0], category: "planning" }]);
  assert.equal((await run({ action: "save-speak-categories", categories: result.items })).organized, 1);
  assert.deepEqual((await run({ action: "list" })).items[0], { ...before, folderCategory: "planning" });
  assert.equal((await run({ action: "invoke", items: speakIds })).text, priorText);
  const rejected = await organizeSpeaks({ items: speakDrafts, route: { model: "cleanup" }, classifyOnly: true,
    complete: async () => ({ text: '{"items":[{"index":0,"category":"other"}]}' }) });
  assert.deepEqual(rejected.items, []);
  assert.equal((await run({ action: "save-speak-categories", categories: [{ id: speakIds[0], category: "other" }] })).organized, 0);
  assert.equal(await read(filename), source);
});

test("batch organizing caches a compact icon and purpose while preserving the existing folder and prompt", async t => {
  const { file, write, read, run } = await fixture(t);
  const filename = "meeting-notes.md";
  const source = "---\nname: Meeting notes\ndescription: Summarizes notes for the team\n---\nExtract decisions and action items from meeting notes.\n";
  await write(filename, source);
  const { speakIds: [id] } = await run({ action: "import-files", paths: [file(filename)] });
  await run({ action: "save-speak-categories", categories: [{ id, category: "writing" }] });
  const { speakDrafts } = await run({ action: "speak-drafts", items: [id] });
  const before = (await run({ action: "list" })).items[0];
  const response = await organizeSpeaks({ items: speakDrafts, route: { model: "cleanup" },
    classifyOnly: true, includePreview: true, language: "zh-Hans", complete: async request => {
      assert.match(request.system, /Choose one icon identifier from: checklist/u);
      assert.match(request.system, /action-and-object phrase/u);
      return { text: '{"items":[{"index":0,"category":"planning","preview":{"icon":"checklist","summary":"提炼结论与行动项。"}}]}' };
    } });
  const preview = { icon: "checklist", summary: "提炼结论与行动项" };
  assert.deepEqual(response.items, [{ id, category: "planning", preview }]);
  assert.deepEqual(await run({ action: "save-speak-categories",
    categories: [{ ...response.items[0], keepFolder: true }] }), { organized: 1 });
  assert.deepEqual((await run({ action: "list" })).items[0], { ...before, wheelPreview: preview });
  assert.equal((await run({ action: "invoke", items: [id] })).text, "Extract decisions and action items from meeting notes.");
  assert.equal(await read(filename), source);

  const invalid = await organizeSpeaks({ items: speakDrafts, route: { model: "cleanup" },
    classifyOnly: true, includePreview: true, complete: async () => ({
      text: '{"items":[{"index":0,"category":"planning","preview":{"icon":"arbitrary-image","summary":"A much longer explanation that should never fit the center of a small wheel"}}]}',
    }) });
  assert.deepEqual(invalid.items[0].preview, { icon: null, summary: null });
});

test("manual Skill organization suggests display names and remembers both review decisions", async t => {
  const { file, write, read, run } = await fixture(t);
  const standalone = "messy-title.md";
  const bundle = "research/SKILL.md";
  const source = "---\nname: A very long draft tool name\n---\nRewrite a draft in plain language.\n";
  const linked = "---\nname: Many research task words\n---\nRead references/guide.md to check sources.\n";
  await write(standalone, source);
  await write(bundle, linked);
  await write("research/references/guide.md", "Check the linked sources.");
  const paths = [file(standalone), file(bundle)];
  async function importBoth() {
    const { token } = await run({ action: "preview-import", paths });
    await run({ action: "confirm-import", paths, token, modes: { [file(standalone)]: "full", [file(bundle)]: "reference" } });
  }
  await importBoth();
  const { items: originals } = await run({ action: "list" });
  const ids = originals.map(item => item.id);
  const drafts = suggestNames => run({ action: "speak-drafts", items: ids, suggestNames });
  assert.ok((await drafts(false)).speakDrafts.every(item => !("currentName" in item)));
  const { speakDrafts } = await drafts(true);
  assert.deepEqual(speakDrafts.map(item => item.currentName), originals.map(item => item.name));
  const names = ["Plain-language editing", "Verify sources"];
  const { items: categories } = await organizeSpeaks({
    items: speakDrafts, route: { model: "cleanup" }, classifyOnly: true, includePreview: true,
    complete: async request => {
      assert.match(request.system, /suggestedName/u);
      assert.deepEqual(JSON.parse(request.user).items.map(item => item.currentName), originals.map(item => item.name));
      return { text: JSON.stringify({ items: names.map((suggestedName, index) => ({
        index, category: index === 0 ? "writing" : "research", suggestedName,
      })) }) };
    },
  });
  const apply = updates => run({ action: "save-speak-categories", suggestNames: true, categories: updates });
  await apply(categories);
  const { items: pending } = await run({ action: "list" });
  assert.deepEqual(pending.map(item => item.name), originals.map(item => item.name));
  assert.deepEqual(pending.map(item => item.suggestedName), names);
  assert.ok((await run({ action: "list", surface: "wheel" })).items.every(item => !("suggestedName" in item)));
  const decide = (index, accept, suggestedName = names[index]) =>
    run({ action: "review-skill-name", items: [ids[index]], accept, suggestedName });
  await assert.rejects(decide(0, true, "An old suggestion"), /changed/u);
  await decide(0, true);
  await decide(1, false);

  await importBoth();
  assert.ok((await drafts(true)).speakDrafts.every(item => !("currentName" in item)));
  await apply(categories.map(item => ({ ...item, category: "analysis", suggestedName: "Try a different name" })));
  const { items: reviewed } = await run({ action: "list" });
  assert.deepEqual(reviewed.map(item => item.name), [names[0], originals[1].name]);
  assert.deepEqual(reviewed.map(item => item.renamed), [true, undefined]);
  assert.ok(reviewed.every(item => !item.suggestedName && item.folderCategory === "analysis"));
  assert.equal((await run({ action: "list", surface: "wheel" })).items[0].name, names[0]);
  assert.equal((await run({ action: "invoke", items: [ids[0]] })).text, "Rewrite a draft in plain language.");
  assert.match((await run({ action: "invoke", items: [ids[1]] })).text, /Source: .+research\/SKILL\.md/u);
  assert.equal(await read(standalone), source);
  assert.equal(await read(bundle), linked);
});

test("reference Skills can be classified and invoke their manifest with instructions to find dependencies", async t => {
  const { file, write, read, run } = await fixture(t);
  const bundle = "helper folder/SKILL.md";
  const body = "BODY_SENTINEL. Read [guide](references/guide.md).";
  await write(bundle, "---\nname: helper\ndescription: Check a draft against a guide\nallowed-tools: Read\n---\n" + body);
  await write("helper folder/references/guide.md", "DEPENDENCY_SENTINEL");
  await write("standalone.md", "Write a concise title.");
  await write("skipped.md", "Skip this.");
  const paths = ["helper folder", "standalone.md", "skipped.md"].map(file);
  const snapshot = await run({ action: "preview-import", paths });
  const [linked, plain] = snapshot.imports;
  assert.deepEqual([linked.path, linked.dependencies, linked.fields, linked.relatedFiles, linked.usesFiles],
    [file(bundle), true, ["allowed-tools"], ["references"], true]);
  assert.equal(plain.dependencies, false);
  assert.doesNotMatch(JSON.stringify(snapshot), /BODY_SENTINEL|DEPENDENCY_SENTINEL/u);
  await assert.rejects(read("library/data.json"), { code: "ENOENT" });
  const modes = { [linked.path]: "reference", [plain.path]: "full" };
  const commit = await run({ action: "confirm-import", paths, token: snapshot.token, modes });
  assert.deepEqual([commit.importedFiles.skills, commit.importedFiles.skillReferences], [1, 1]);
  const { items } = await run({ action: "list" });
  assert.equal(items.length, 2);
  const reference = items.find(item => item.importMode === "reference");
  assert.equal((await run({ action: "invoke", items: commit.speakIds })).text, "Write a concise title.");
  const invoked = await run({ action: "invoke", items: [reference.id] });
  assert.equal(invoked.text, "Skill: helper\nPurpose: Check a draft against a guide\n" +
    "Usage: Read the source first and follow its workflow for the current task. " +
    "Open only the dependencies needed, relative to the source file's directory.\n" +
    "Source: " + JSON.stringify(linked.path));
  assert.equal((await run({ action: "paste", items: [reference.id] })).text, invoked.text);
  const preview = await run({ action: "preview-skills", items: [reference.id, ...commit.speakIds] });
  assert.match(preview.text, /BODY_SENTINEL/u);
  assert.match(preview.text, /Write a concise title\./u);
  assert.doesNotMatch(preview.text, /Purpose:|DEPENDENCY_SENTINEL/u);
  assert.deepEqual(preview.omitted, []);
  assert.doesNotMatch(invoked.text, /BODY_SENTINEL|DEPENDENCY_SENTINEL/u);
  assert.doesNotMatch(await read("library/data.json"), /BODY_SENTINEL|Skip this/u);
  const { speakDrafts } = await run({ action: "speak-drafts", kind: "skill", items: [reference.id] });
  assert.equal(speakDrafts[0].id, reference.id);
  assert.match(speakDrafts[0].body, /BODY_SENTINEL/u);
  assert.doesNotMatch(speakDrafts[0].body, /DEPENDENCY_SENTINEL/u);
  const organized = await organizeSpeaks({ items: speakDrafts, route: { model: "cleanup" },
    classifyOnly: true, includePreview: true, complete: async () => ({
      text: '{"items":[{"index":0,"category":"research","preview":{"icon":"search","summary":"Look up guidance"}}]}',
    }) });
  assert.equal((await run({ action: "save-speak-categories", kind: "skill", categories: organized.items })).organized, 1);
  const classified = (await run({ action: "list" })).items.find(item => item.id === reference.id);
  assert.equal(classified.folderCategory, "research");
  assert.equal(classified.importMode, "reference");
  const afterOrganization = await run({ action: "invoke", items: [reference.id] });
  assert.equal(afterOrganization.text, invoked.text.replace("Check a draft against a guide", "Look up guidance"));
  await rm(file(bundle));
  assert.equal((await run({ action: "invoke", items: [reference.id] })).error, "skill-source-unavailable");
  assert.deepEqual(await run({ action: "preview-skills", items: [reference.id] }), { text: "", omitted: [reference.name] });
});

test("MCP classification uses names and descriptions and can reshuffle previously grouped items", async t => {
  const { file, write, read, run } = await fixture(t);
  await write(".mcp.json", JSON.stringify({ mcpServers: {
    "note-search": { url: "https://notes.example.invalid/mcp", description: "Search team notes" },
    records: { command: "records-server", env: { TOKEN: "private-fixture-credential" } },
  } }));
  await run({ action: "import-files", paths: [file(".mcp.json")] });
  const before = (await run({ action: "list" })).items;
  const ids = before.map(item => item.id);
  const { speakDrafts } = await run({ action: "speak-drafts", kind: "mcp", items: ids });
  assert.deepEqual(speakDrafts.map(item => item.body), ["note-search\nSearch team notes", "records"]);
  await run({ action: "save-speak-categories", kind: "mcp", categories: [{ id: ids[0], category: "writing" }] });
  const organized = await organizeSpeaks({ items: speakDrafts, route: { model: "cleanup" }, classifyOnly: true,
    complete: async ({ system, user }) => {
      assert.match(system, /MCP server based on its purpose/u);
      assert.doesNotMatch(user, /private-fixture-credential|https:|records-server/u);
      return { text: '{"items":[{"index":0,"category":"research"},{"index":1,"category":"analysis"}]}' };
    } });
  assert.equal((await run({ action: "save-speak-categories", kind: "mcp", categories: organized.items })).organized, 2);
  assert.deepEqual((await run({ action: "list" })).items,
    [{ ...before[0], folderCategory: "research" }, { ...before[1], folderCategory: "analysis" }]);
  assert.doesNotMatch(await read("library/data.json"), /private-fixture-credential/u);
});

test("stores independent Markdown intact inside the library or a chosen folder before allowing cleanup", async t => {
  const { file, write, read, run } = await fixture(t);
  const source = "\uFEFF---\r\nname: Notes helper\r\n---\r\nWrite a concise title.\r\n";
  const manual = "Summarize a draft in three sentences.\n";
  await write("notes.md", source);
  await write("draft.md", manual);
  await write("exports/draft.md", "Existing notes that must stay.\n");
  await write("bundle/SKILL.md", "Read [guide](references/guide.md).\n");
  const paths = ["notes.md", "draft.md", "bundle/SKILL.md"].map(file);
  const preview = await run({ action: "preview-import", paths });
  assert.deepEqual(preview.imports.map(row => row.canSaveMarkdown), [true, true, false]);
  await assert.rejects(read("library/data.json"), { code: "ENOENT" });
  const commit = await run({ action: "confirm-import", paths, token: preview.token,
    modes: Object.fromEntries(paths.map(path => [path, "full"])),
    markdownSaves: { [paths[0]]: { location: "library" },
      [paths[1]]: { location: "folder", directory: file("exports") },
      [paths[2]]: { location: "library" } } });
  assert.equal(commit.importedFiles.skills, 2);
  assert.deepEqual(commit.failedSaves, [paths[2]]);
  const [stored, external] = commit.savedMarkdown;
  assert.match(stored.destination, /\/library\/skill-sources\//u);
  assert.equal(await readFile(stored.destination, "utf8"), source);
  assert.equal(await readFile(external.destination, "utf8"), manual);
  assert.notEqual(external.destination, file("exports/draft.md"));
  assert.equal(await read("exports/draft.md"), "Existing notes that must stay.\n");
  assert.equal(await read("notes.md"), source);
  assert.equal(await read("bundle/SKILL.md"), "Read [guide](references/guide.md).\n");

  // The user's later removal of the original must not affect either stored copy.
  await rm(paths[0]);
  await rm(paths[1]);
  const { items } = await run({ action: "list" });
  const internalItem = items.find(item => item.savedMarkdownPath === stored.destination);
  assert.ok(internalItem);
  assert.equal((await run({ action: "invoke", items: [internalItem.id] })).text, "Write a concise title.");
  assert.equal((await run({ action: "export-speak", items: [internalItem.id] })).text, source);
});

test("saving into the original folder creates a separate copy and a failed destination leaves the original intact", async t => {
  const { file, write, read, run } = await fixture(t);
  await write("notes/draft.md", "Write an outline.\n");
  const path = file("notes/draft.md");
  const paths = [path];
  const runSave = async directory => {
    const preview = await run({ action: "preview-import", paths });
    return run({ action: "confirm-import", paths, token: preview.token, modes: { [path]: "full" },
      markdownSaves: { [path]: { location: "folder", directory } } });
  };
  const failure = await runSave(file("missing"));
  assert.deepEqual(failure.failedSaves, [path]);
  assert.deepEqual(failure.savedMarkdown, []);
  assert.equal(await read("notes/draft.md"), "Write an outline.\n");
  const saved = await runSave(file("notes"));
  assert.equal(saved.savedMarkdown[0].destination, await realpath(file("notes/draft (2).md")));
  const retry = await runSave(file("notes"));
  assert.equal(retry.savedMarkdown[0].destination, saved.savedMarkdown[0].destination);
});

test("central Markdown saves each original in one library before approving Trash, including distinct headers for identical prompts", async t => {
  const { file, write, read, run } = await fixture(t);
  const originals = ["\uFEFF---\r\nname: One\r\n---\r\nSummarize a draft.\r\n",
                     "---\nname: Two\n---\nSummarize a draft.\n",
                     "Read [guide](references/guide.md).\n"];
  const paths = ["one.md", "two.md", "linked.md"].map(file);
  for (const [index, path] of ["one.md", "two.md", "linked.md"].entries()) await write(path, originals[index]);
  const preview = await run({ action: "preview-import", paths });
  const result = await run({ action: "confirm-import", paths, token: preview.token, centralizeMarkdown: true,
    modes: Object.fromEntries(paths.map(path => [path, "full"])) });
  assert.deepEqual(result.savedMarkdown.map(copy => copy.source), paths.slice(0, 2));
  assert.ok(result.savedMarkdown.every(copy => copy.destination === undefined));
  const db = JSON.parse(await read("library/data.json"));
  assert.deepEqual(Object.values(db.markdown), originals.slice(0,2));
  const copies = [...result.savedMarkdown, { source: paths[2], digest: "0".repeat(64) }];
  assert.deepEqual((await run({ action: "verify-markdown-trash", copies })).savedMarkdown, result.savedMarkdown);
  for (const path of paths.slice(0,2)) await rm(path);
  const exportReply = await run({ action: "export-speak", items: result.speakIds });
  assert.equal(exportReply.text, originals[1]);
  await assert.rejects(read("library/skill-sources"), { code: "ENOENT" });
});

test("hover preview edits central Markdown without touching its original and rejects stale saves", async t => {
  const { file, write, read, run } = await fixture(t);
  const source = "\uFEFF---\nname: Review\n---\nCheck this draft.\n";
  await write("review.md", source);
  const paths = [file("review.md")];
  const importPreview = await run({ action: "preview-import", paths });
  const { speakIds } = await run({ action: "confirm-import", paths, token: importPreview.token, centralizeMarkdown: true,
    modes: { [paths[0]]: "full" } });
  const items = speakIds;
  const preview = await run({ action: "skill-preview", items });
  assert.equal(preview.text, source);
  const save = { action: "save-skill-edit", items, revision: preview.revision };
  assert.equal((await run({ ...save, revision: "stale", text: "New content." })).error, "changed");
  assert.equal((await run({ ...save, text: "Read [guide](references/guide.md)." })).error, "skill-dependencies");
  const next = source.replace("Check this draft.", "Check this draft, including its headings.");
  assert.ok((await run({ ...save, text: next })).revision);
  assert.equal(await read("review.md"), source);
  const [updated] = (await run({ action: "list" })).items;
  assert.equal((await run({ action: "skill-preview", items: [updated.id] })).text, next);
  assert.match((await run({ action: "invoke", items: [updated.id] })).text, /including its headings/u);
});

test("compacts only known frontmatter fields and preserves the rest verbatim", () => {
  const kept = ['name: example', 'compatibility: "macOS only"', 'allowed-tools: [Read, Grep]',
    'metadata:', '  custom-key: "original spacing" # keep'];
  const body = "  Text with deliberate spacing.\r\n\r\nLicense and trigger-call-header in the body.\r\n";
  const source = ["\uFEFF---", ...kept, "  last-reviewed: yesterday", "license: >-", "  Private test notice.",
    "trigger_call_header: ignore me", "---", body].join("\r\n");
  const expected = ["\uFEFF---", ...kept, "---", body].join("\r\n");
  assert.equal(slimSkillMarkdown(source), expected);
  assert.equal(slimSkillMarkdown(expected), expected);
  const alias = "---\nlicense: &shared MIT\ncompatibility: *shared\n---\nText.\n";
  assert.equal(slimSkillMarkdown(alias), alias);
});

test("automatic compacting retains the original digest for safe cleanup", async t => {
  const { file, write, read, run } = await fixture(t);
  const original = "---\nname: Notes\nlicense: MIT\n---\nWrite a title.\n\n";
  const compact = original.replace("license: MIT\n", "");
  const path = file("notes.md");
  await write("notes.md", original);
  const preview = await run({ action: "preview-import", paths: [path] });
  const committed = await run({ action: "confirm-import", paths: [path], token: preview.token,
    modes: { [path]: "full" }, centralizeMarkdown: true });
  const checkTrash = () => run({ action: "verify-markdown-trash", copies: committed.savedMarkdown });
  assert.equal((await run({ action: "export-speak", items: committed.speakIds })).text, compact);
  assert.equal(await read("notes.md"), original);
  assert.equal((await checkTrash()).savedMarkdown.length, 1);
  await write("notes.md", original.replace("MIT", "BSD"));
  assert.deepEqual((await checkTrash()).savedMarkdown, []);
});

test("packaged Skill copies drop unused licensing metadata and keep linked resources", async t => {
  const { file, write, read, run } = await fixture(t);
  const body = "Read [guide](references/guide.md).\n\n";
  const original = "---\nname: example\nlicense: MIT\nallowed-tools: Read\n---\n" + body;
  const originalPackage = skillZip({ "example/SKILL.md": original, "example/LICENSE": "Unreferenced",
    "example/references/guide.md": "Supporting material." });
  const path = file("example.skill");
  await write("example.skill", originalPackage);
  const preview = await run({ action: "preview-import", paths: [path] });
  await run({ action: "confirm-import", paths: [path], token: preview.token, modes: { [path]: "reference" } });
  const [item] = (await run({ action: "list" })).items;
  const stored = item.sources[0].path;
  assert.equal(await readFile(stored, "utf8"), original.replace("license: MIT\n", ""));
  assert.equal(await readFile(join(dirname(stored), "references/guide.md"), "utf8"), "Supporting material.");
  await assert.rejects(readFile(join(dirname(stored), "LICENSE")), { code: "ENOENT" });
  assert.deepEqual(await readFile(path), originalPackage);
  const invoked = await run({ action: "invoke", items: [item.id] });
  assert.match(invoked.text, /^Skill: example\nPurpose: See the source for this Skill's purpose\./u);
  assert.ok(invoked.text.endsWith("\nSource: " + JSON.stringify(stored)));
  assert.doesNotMatch(invoked.text, /Supporting material|Read \[guide\]/u);
});

test("linked Skills keep the invocation short after hover edits to the original", async t => {
  const { file, write, read, run } = await fixture(t);
  const source = "\uFEFF---\nname: My tool\n---\nRead [guide](references/guide.md).\n";
  await write("helper/SKILL.md", source);
  const paths = [file("helper/SKILL.md")];
  const importPreview = await run({ action: "preview-import", paths });
  await run({ action: "confirm-import", paths, token: importPreview.token, modes: { [paths[0]]: "full" } });
  const [item] = (await run({ action: "list" })).items;
  const items = [item.id];
  assert.equal(item.importMode, "linked");
  const initial = await run({ action: "invoke", items });
  assert.match(initial.text, /^Skill: My tool\nPurpose: .*\nUsage: /u);
  assert.ok(initial.text.endsWith("\nSource: " + JSON.stringify(paths[0])));
  assert.doesNotMatch(initial.text, /Read \[guide\]/u);
  const preview = await run({ action: "skill-preview", items });
  assert.equal(preview.text, source);
  const next = source + "Follow the naming rules.\n";
  assert.ok((await run({ action: "save-skill-edit", items, revision: preview.revision, text: next })).revision);
  assert.equal(await read("helper/SKILL.md"), next);
  assert.equal((await run({ action: "skill-preview", items })).text, next);
  assert.deepEqual(await run({ action: "invoke", items }), initial);
  assert.deepEqual(await run({ action: "paste", items }), { text: initial.text, omitted: [] });
});

test("confirming a changed preview writes nothing, and changing to reference drops prior bundled text", async t => {
  const { file, write, read, run } = await fixture(t);
  const path = file("extension.md");
  await write("extension.md", "Read [outline](outline.md).");
  const preview = () => run({ action: "preview-import", paths: [path] });
  const confirm = (token, mode) => run({ action: "confirm-import", paths: [path], token, modes: { [path]: mode } });
  const first = await preview();
  const text = "Use [revised outline](outline.md) as evidence.";
  await write("extension.md", text);
  await assert.rejects(confirm(first.token, "full"), /changed/u);
  await assert.rejects(read("library/data.json"), { code: "ENOENT" });
  const current = await preview();
  await confirm(current.token, "skip");
  await assert.rejects(read("library/data.json"), { code: "ENOENT" });
  await confirm(current.token, "full");
  const [{ id, importMode }] = (await run({ action: "list" })).items;
  assert.equal(importMode, "linked");
  assert.match(await read("library/data.json"), /revised outline/u);
  const linked = await run({ action: "invoke", items: [id] });
  assert.doesNotMatch(linked.text, /revised outline/u);
  await confirm(current.token, "reference");
  assert.doesNotMatch(await read("library/data.json"), /revised outline/u);
  assert.equal((await run({ action: "list" })).items[0].id, id);
  assert.deepEqual(await run({ action: "invoke", items: [id] }), linked);
});

test("manual scan finds and de-duplicates installed Skills, then imports only selected results", async t => {
  const { file, write, read, run } = await fixture(t);
  await write(".codex/skills/shared/SKILL.md", "Write a short briefing.");
  await write(".hermes/skills/writing/outline/SKILL.md", "Use [notes](notes.md).");
  await write(".config/opencode/skills/local/SKILL.md", "Summarize the discussion.");
  await write(".dsh/skills/custom/SKILL.md", "Normalize table headings.");
  await write("Library/Application Support/ChatGPT/skills/saved/SKILL.md", "Explain acronyms.");
  await write("private/nested/SKILL.md", "This must never be discovered through a directory link.");
  await mkdir(file(".claude/skills"), { recursive: true });
  await symlink(file(".codex/skills/shared"), file(".claude/skills/shared"));
  await symlink(file("private"), file(".claude/skills/unrelated"));

  const scan = () => run({ action: "scan-skills" });
  const result = await scan();
  await assert.rejects(read("library/data.json"), { code: "ENOENT" });
  assert.equal(result.imports.length, 5);
  const shared = result.imports.find(row => row.providers.includes("Codex"));
  const outline = result.imports.find(row => row.providers.includes("Hermes"));
  assert.deepEqual(shared.providers, ["Codex", "Claude Code"]);
  assert.equal(shared.dependencies, false);
  assert.equal(outline.dependencies, true);
  assert.ok(result.imports.some(row => row.providers.includes("OpenCode")));
  assert.ok(result.imports.some(row => row.providers.includes("DeepSeek Harness")));
  assert.ok(result.imports.some(row => row.providers.includes("ChatGPT")));
  assert.doesNotMatch(JSON.stringify(result), /private\/nested|Write a short briefing/u);

  const paths = result.imports.map(row => row.path);
  const confirm = await run({ action: "confirm-import", paths, token: result.token, modes: { [outline.path]: "reference" } });
  assert.equal(confirm.importedFiles.skillReferences, 1);
  assert.equal(confirm.importedFiles.skills, 0);
  assert.equal((await run({ action: "list" })).items.length, 1);
  assert.equal((await scan()).imports.length, 4);
});

test("MCP scan previews individual servers and imports only the confirmed choices without credentials", async t => {
  const { file, write, read, run } = await fixture(t);
  const config = [
    "[mcp_servers.notes]",
    'url = "https://notes.example.invalid/mcp"',
    "[mcp_servers.private]",
    'url = "https://private.example.invalid/mcp"',
    '[mcp_servers.private.headers]',
    'Authorization = "Bearer fixture-secret-value"',
  ].join("\n");
  await write(".codex/config.toml", config);
  await write("Library/Application Support/Code/User/mcp.json", JSON.stringify({
    servers: { local: { command: "local-fixture", args: [] } },
  }));
  await write(".hermes/config.yaml", "mcp_servers: [");
  await write("unrelated/private-mcp.json", JSON.stringify({ mcpServers: { other: { command: "other-fixture" } } }));

  const scan = () => run({ action: "scan-mcps" });
  const preview = await scan();
  const [local, notes, privateServer] = preview.imports;
  assert.deepEqual(preview.imports.map(row => row.name), ["local", "notes", "private"]);
  assert.deepEqual(local.providers, ["VS Code"]);
  assert.deepEqual(notes.providers, ["Codex"]);
  assert.equal(notes.path, privateServer.path);
  assert.notEqual(notes.selectionID, privateServer.selectionID);
  assert.equal(privateServer.authorization, true);
  assert.doesNotMatch(JSON.stringify(preview), /fixture-secret-value|private\.example|local-fixture/u);
  await assert.rejects(read("library/data.json"), { code: "ENOENT" });

  const confirm = (token, selectionID) => run({ action: "confirm-mcp-scan", token, modes: { [selectionID]: "full" } });
  await write(".codex/config.toml", config.replace("notes.example", "updated.example"));
  await assert.rejects(confirm(preview.token, notes.selectionID), /changed/u);

  const current = await scan();
  const added = await confirm(current.token, privateServer.selectionID);
  assert.equal(added.importedFiles.mcp, 1);
  const persisted = await read("library/data.json");
  const [stored] = JSON.parse(persisted).servers;
  assert.equal(stored.name, "private");
  assert.equal(stored.raw, undefined);
  assert.doesNotMatch(persisted, /fixture-secret-value|private\.example|local-fixture/u);
  assert.deepEqual((await scan()).imports.map(row => row.name), ["local", "notes"]);
  assert.equal(await read(".codex/config.toml"), config.replace("notes.example", "updated.example"));
});

test("scans authored project Skills and skips installed application resources", async t => {
  const { file, write, read, run } = await fixture(t);
  await write(".config/opencode/opencode.jsonc", '{"skills":["./team","https://example.invalid/skills"]}');
  await write(".config/opencode/team/notes.md", "Write a brief note.");
  await write("deep-project/.git", "gitdir: .git-worktree");
  await write("deep-project/documents/.keep", "");
  await write(".dsh/storages/session_projcache/sessions/known.json",
    JSON.stringify({ record: { identity: { cwd: file("deep-project/documents") } } }));
  await write("deep-project/.dsh/skills/project/SKILL.md", "Summarize the monthly report.");
  await write("Applications/ChatGPT.app/Contents/Resources/plugins/openai-bundled/plugins/demo/skills/draft/SKILL.md",
    "Draft a short email.");
  const archivePath = "Applications/DeepSeek Harness.app/Contents/Resources/app.asar";
  const base = "dsh/node_modules/@deepseek-ai/dsh-agent-preset/skills";
  const assets = {
    [base + "/helper/SKILL.md"]: "Read [setup](references/setup.md).",
    [base + "/helper/references/setup.md"]: "Instructions for the confirmed Skill.",
    [base + "/another/SKILL.md"]: "Skip this other archived Skill.",
  };
  const root = { files: {} };
  let offset = 0;
  const data = [];
  for (const [path, text] of Object.entries(assets)) {
    const parts = path.split("/");
    const filename = parts.pop();
    const folder = parts.reduce((node, part) => node.files[part] ??= { files: {} }, root);
    const bytes = Buffer.from(text);
    folder.files[filename] = { offset: String(offset), size: bytes.length };
    data.push(bytes);
    offset += bytes.length;
  }
  const info = Buffer.from(JSON.stringify(root));
  const header = Buffer.alloc(16);
  header.writeUInt32LE(4, 0);
  header.writeUInt32LE(info.length + 8, 4);
  header.writeUInt32LE(info.length + 4, 8);
  header.writeUInt32LE(info.length, 12);
  await write(archivePath, Buffer.concat([header, info, ...data]));

  const scan = await run({ action: "scan-skills" });
  const found = scan.imports.map(row => [row.providers[0], row.name]);
  assert.deepEqual(found.filter(([provider]) => provider === "OpenCode"), [["OpenCode", "notes"]]);
  assert.deepEqual(found.filter(([provider]) => provider === "ChatGPT"), []);
  assert.deepEqual(found.filter(([provider]) => provider === "DeepSeek Harness"),
    [["DeepSeek Harness", "project"]]);
  await assert.rejects(read("library/data.json"), { code: "ENOENT" });
  const paths = [file(archivePath + "/" + base + "/helper/SKILL.md")];
  const explicit = await run({ action: "preview-import", paths });
  const [helper] = explicit.imports;
  await run({ action: "confirm-import", paths, token: explicit.token, modes: { [helper.path]: "reference" } });
  const [item] = (await run({ action: "list" })).items;
  assert.equal(item.name, "helper");
  const source = item.sources[0];
  assert.equal(source.archivePath, helper.path);
  assert.ok(source.path.startsWith(file("library/skill-sources/")));
  assert.equal(await readFile(join(dirname(source.path), "references", "setup.md"), "utf8"),
    "Instructions for the confirmed Skill.");
  assert.ok((await run({ action: "invoke", items: [item.id] })).text.includes(source.path));
  assert.doesNotMatch(await read("library/data.json"), /Skip this other archived Skill|Read \[setup\]/u);
  assert.equal((await run({ action: "scan-skills" })).imports.length, 2);
});

test("scan ignores manifest-listed defaults from Claude and Hermes while retaining personal entries", async t => {
  const { file, write, run } = await fixture(t);
  const synced = ".claude/skills/synced/workspace";
  await write(synced + "/manifest.json", JSON.stringify({ skills: [
    { name: "default-editor", source: "anthropic-example" },
    { name: "default-xlsx", source: "anthropic" },
    { name: "own-style", source: "custom" },
  ] }));
  for (const name of ["default-editor", "default-xlsx", "own-style"]) {
    await write(synced + "/" + name + "/SKILL.md", "Prepare a short response.");
  }
  await symlink(file(synced + "/default-editor"), file(".claude/skills/linked-default"));
  await write(".hermes/skills/.bundled_manifest", "\uFEFFstarter:abcd\nolder-starter\n");
  for (const name of ["starter", "older-starter", "own-outline"]) {
    await write(".hermes/skills/category/" + name + "/SKILL.md", "Write an outline.");
  }
  await write(".codex/skills/.system/default/SKILL.md", "Packaged skill.");
  const scan = await run({ action: "scan-skills" });
  assert.deepEqual(scan.imports.map(row => row.name).sort(), ["own-outline", "own-style"]);
});

test("unless confirmed, personal ChatGPT exports stay out of the library and on disk only", async t => {
  const { file, write, read, run } = await fixture(t);
  const root = "Library/Application Support/ChatGPT/skills";
  const name = root + "/my-workflow.skill";
  const archive = skillZip({
    "workflow/SKILL.md": "---\nname: my-workflow\n---\nRead [requirements](references/requirements.md).",
    "workflow/references/requirements.md": "Keep the request and deadline.",
  });
  await write(name, archive);
  await write(root + "/unreadable.skill", "Unknown format.");
  await write(root + "/unsafe.skill", skillZip({ "SKILL.md": "Work more quickly.", "../escape": "Not a pack entry." }));
  await write("Downloads/personal-export.skill", archive);
  await write("Downloads/unrelated.zip", skillZip({ "SKILL.md": "Only consider ZIP files that were selected." }));
  const scan = await run({ action: "scan-skills" });
  assert.deepEqual(scan.imports.map(row => [row.name, row.providers, row.dependencies]), [
    ["my-workflow", ["ChatGPT"], true],
  ]);
  await assert.rejects(read("library/data.json"), { code: "ENOENT" });
  const paths = scan.imports.map(row => row.path);
  await run({ action: "confirm-import", paths, token: scan.token, modes: { [paths[0]]: "skip" } });
  await assert.rejects(read("library/data.json"), { code: "ENOENT" });
  await run({ action: "confirm-import", paths, token: scan.token, modes: { [paths[0]]: "reference" } });
  const [item] = (await run({ action: "list" })).items;
  assert.equal(item.sources[0].archivePath, paths[0]);
  assert.equal(await readFile(join(dirname(item.sources[0].path), "references", "requirements.md"), "utf8"),
    "Keep the request and deadline.");
  assert.doesNotMatch(await read("library/data.json"), /Keep the request and deadline|\\[requirements\\]/u);
  assert.equal((await run({ action: "scan-skills" })).imports.length, 0);
  const downloaded = await run({ action: "preview-import", paths: [file("Downloads/personal-export.skill")] });
  assert.deepEqual(downloaded.imports.map(row => row.providers), [["ChatGPT"]]);
  const zip = await run({ action: "preview-import", paths: [file("Downloads/unrelated.zip")] });
  assert.equal(zip.imports[0].dependencies, false);
});

test("classifies a mixed batch, keeps MCP credentials at their source, and preserves existing names", async t => {
  const { file, write, read, run } = await fixture(t);
  const markdown = "---\nname: file-checklist\n---\n\nOne\n\nTwo";
  await write("dropped/file-checklist/SKILL.md", markdown);
  await write("dropped/extra.md", "A standalone checklist.");
  const placeholder = "$" + "{input:secret-token}";
  const vsCode = JSON.stringify({ servers: {
    notes: { type: "http", url: "https://example.invalid/notes", headers: {} },
    private: { type: "http", url: "https://example.invalid/private", headers: { Authorization: "fixture-key" } },
    local: { type: "stdio", command: "/usr/bin/false", args: [placeholder] },
  }, inputs: [{ id: "secret-token" }] });
  await write("dropped/mcp.json", vsCode);
  await write("dropped/config.toml", '[mcp_servers.docs]\nurl = "https://example.invalid/docs"');
  await write("dropped/config.yaml", 'mcp_servers:\n  wiki:\n    url: https://example.invalid/wiki\n');
  await write("dropped/opencode.jsonc", '{// OpenCode\n"mcp":{"tasks":{"type":"local","command":["/usr/bin/false","fixture"]}}}');
  await write("dropped/malformed.json", '{');
  await write("dropped/report.json", '{"title":"report","url":"https://example.invalid/unrelated"}');
  const names = ["file-checklist/SKILL.md", "extra.md", "mcp.json", "config.toml", "config.yaml", "opencode.jsonc", "malformed.json", "report.json"];
  const batch = { action: "import-files", paths: names.map(name => file("dropped/" + name)) };
  const imported = await run(batch);
  assert.deepEqual(imported.importedFiles, { skills: 2, mcp: 6, references: 0, duplicates: 0, conflicts: 0, skipped: 2, dependentSkills: 0 });
  assert.deepEqual((await run(batch)).importedFiles, { skills: 0, mcp: 0, references: 0, duplicates: 8, conflicts: 0, skipped: 2, dependentSkills: 0 });
  const data = await read("library/data.json");
  assert.doesNotMatch(data, /fixture-key|secret-token|example\.invalid\/private/u);
  assert.equal(await read("dropped/mcp.json"), vsCode);
  assert.equal(await read("dropped/file-checklist/SKILL.md"), markdown);
  await assert.rejects(read(".codex/config.toml"), { code: "ENOENT" });
  const { items } = await run({ action: "list" });
  assert.equal(items.filter(item => item.kind === "mcp").length, 6);
  assert.doesNotMatch(data, /https:\/\/example\.invalid|\/usr\/bin\/false/u);
  await write("different-mcp.mcp", '{"name":"notes","type":"http","url":"https://example.invalid/replacement"}');
  const conflict = await run({ action: "import-files", paths: [file("different-mcp.mcp")] });
  assert.equal(conflict.importedFiles.conflicts, 1);
  assert.equal(await read("library/data.json"), data);
});

test("MCP call text works in any host without reading or changing an Agent's config", async t => {
  const { file, write, read, run } = await fixture(t);
  const source = '{"mcpServers":{"notes":{"url":"https://notes.example.invalid/mcp","description":"Find and summarize team notes","headers":{"Authorization":"fixture-secret"}}}}';
  await write("imported-mcp.json", source);
  await write(".codex/config.toml", "keep = true\n");
  await run({ action: "import-files", paths: [file("imported-mcp.json")] });
  const [item] = (await run({ action: "list" })).items;
  const items = [item.id];
  const invocation = await run({ action: "invoke", items });
  assert.equal(item.invocationText, undefined);
  const [wheelItem] = (await run({ action: "list", surface: "wheel" })).items;
  assert.equal(wheelItem.invocationText, invocation.text);
  assert.match(invocation.text, /MCP: "notes"/u);
  assert.match(invocation.text, /Purpose: Find and summarize team notes/u);
  assert.match(invocation.text, /Source: /u);
  assert.ok(invocation.text.includes(JSON.stringify(file("imported-mcp.json"))));
  assert.match(invocation.text, /relevant tool if available[\s\S]*setup or access needed/u);
  assert.doesNotMatch(invocation.text, /fixture-secret|notes\.example\.invalid/u);
  assert.deepEqual(await run({ action: "paste", items }), { text: invocation.text, omitted: [] });
  assert.deepEqual(await run({ action: "paste", items, agent: "unrecognized" }), { text: invocation.text, omitted: [] });
  await assert.rejects(run({ action: "preview", operation: "assign", targets: ["codex"], items }), /invalid-request/u);
  await assert.rejects(run({ action: "wheel-mcp-verify", agent: "codex", items }), /invalid-request/u);
  assert.equal(await read("imported-mcp.json"), source);
  assert.equal(await read(".codex/config.toml"), "keep = true\n");
});

test("ignoring a Skill or MCP hides it only from the wheel and can be undone", async t => {
  const { file, write, run } = await fixture(t);
  await write("notes.md", "Summarize notes.");
  await write("mcp.json", '{"mcpServers":{"notes":{"url":"https://notes.example.invalid/mcp"}}}');
  await run({ action: "import-files", paths: [file("notes.md"), file("mcp.json")] });
  const { items } = await run({ action: "list" });
  const ids = items.map(item => item.id);
  await run({ action: "set-library-ignored", items: ids, ignored: true });
  assert.deepEqual((await run({ action: "list", surface: "wheel" })).items, []);
  assert.deepEqual((await run({ action: "list" })).items.map(item => item.ignored), [true, true]);
  const skill = items.find(item => item.kind === "skill");
  const mcp = items.find(item => item.kind === "mcp");
  assert.equal((await run({ action: "preview-skills", items: [skill.id] })).text, "Summarize notes.");
  assert.match((await run({ action: "paste", items: [mcp.id] })).text, /MCP: "notes"/u);
  for (const id of ids) assert.equal((await run({ action: "invoke", items: [id] })).error, "item-ignored");
  await run({ action: "set-library-ignored", items: ids, ignored: false });
  const restored = (await run({ action: "list", surface: "wheel" })).items;
  assert.deepEqual(restored.map(item => item.id), ids);
  assert.equal(restored.find(item => item.kind === "skill").invocationText, undefined);
  assert.match(restored.find(item => item.kind === "mcp").invocationText, /MCP: "notes"/u);
});

test("deleting Skills removes their local saved content and leaves external sources and shared copies", async t => {
  const { file, write, read, run } = await fixture(t);
  const source = "---\nname: notes\n---\nSummarize notes.\n";
  await write("notes.md", source);
  const packagePath = file("bundle.skill");
  await writeFile(packagePath, skillZip({
    "bundle/SKILL.md": "Read [guide](references/guide.md).",
    "bundle/references/guide.md": "Internal copy.",
  }));
  const paths = [file("notes.md"), packagePath];
  const preview = await run({ action: "preview-import", paths });
  const bundleRow = preview.imports.find(row => row.path === packagePath);
  await run({ action: "confirm-import", paths, token: preview.token, centralizeMarkdown: true,
    modes: { [file("notes.md")]: "full", [bundleRow.path]: "reference" } });
  const { items } = await run({ action: "list" });
  const packageItem = items.find(item => item.importMode === "reference");
  const local = packageItem.sources[0].path;
  const inventory = JSON.parse(await read("library/data.json"));
  inventory.skills.push({ ...inventory.skills.find(item => item.id === packageItem.id), id: "skill-ref:" + "a".repeat(64) });
  await write("library/data.json", JSON.stringify(inventory));
  assert.equal((await run({ action: "delete-library-items", items: [packageItem.id] })).deleted, 1);
  assert.equal(await readFile(local, "utf8"), "Read [guide](references/guide.md).");
  const remaining = (await run({ action: "list" })).items.map(item => item.id);
  assert.deepEqual(await run({ action: "delete-library-items", items: remaining }), { deleted: 2, pendingCleanup: 0 });
  assert.deepEqual((await run({ action: "list" })).items, []);
  await assert.rejects(lstat(dirname(local)), { code: "ENOENT" });
  assert.equal(await read("notes.md"), source);
  assert.ok((await lstat(packagePath)).isFile());
  assert.deepEqual(JSON.parse(await read("library/data.json")).markdown, {});
});

test("deleting an MCP leaves external config untouched and suppresses the old assignment fallback", async t => {
  const { file, write, read, run } = await fixture(t);
  const config = '[mcp_servers.test]\nurl = "https://example.invalid/mcp"\n';
  const id = "library-mcp:" + "b".repeat(64);
  await write(".codex/config.toml", config);
  await write("library/data.json", JSON.stringify({ skills: [], servers: [],
    managed: [{ item: id, kind: "mcp", name: "test", agent: "codex", path: file(".codex/config.toml"),
      entry: { url: "https://example.invalid/mcp" } }],
  }));
  assert.deepEqual((await run({ action: "list" })).items.map(item => item.id), [id]);
  assert.equal((await run({ action: "delete-library-items", items: [id] })).deleted, 1);
  assert.deepEqual((await run({ action: "list" })).items, []);
  assert.deepEqual((await run({ action: "list", surface: "wheel" })).items, []);
  assert.equal(await read(".codex/config.toml"), config);
});

test("legacy config cleanup preserves the call header and can undo only previously managed entries", async t => {
  const { file, write, read, run } = await fixture(t);
  const url = "https://docs.example.invalid/mcp";
  const id = "library-mcp:" + "a".repeat(64);
  const formats = [
    ["codex", "toml", ".codex/config.toml", ["mcp_servers"], { url }, "keep = true\n"],
    ["claude", "json", ".claude.json", ["mcpServers"], { type: "http", url }, '{"keep":true}'],
    ["opencode", "jsonc", "selected/opencode.jsonc", ["mcp", "servers"], { type: "remote", url }, '{// retained\n"keep":true}'],
    ["hermes", "yaml", ".hermes/config.yaml", ["mcp_servers"], { url }, "keep: true # retained\n"],
  ];
  for (const [, format, path, keys, entry, content] of formats) {
    await write(path, editConfig(format, content, [...keys, "docs"], entry));
  }
  await write(".config/opencode/opencode.jsonc", '{"mcp":{"servers":{"docs":{"type":"remote","url":"https://global.invalid/mcp"}}}}');
  const global = await read(".config/opencode/opencode.jsonc");
  const origin = file("imported-mcp.json");
  await write("library/data.json", JSON.stringify({
    skills: [], servers: [{ id, name: "docs", kind: "mcp", imported: true, portable: true,
      raw: { url }, sources: [{ agent: "manual", path: origin }] }],
    managed: formats.map(([agent, , path, , entry]) => ({ item: id, kind: "mcp", name: "docs", agent, path: file(path), entry })),
    mcpChecks: [{ proof: "old-connection-check" }],
  }));
  const header = (await run({ action: "invoke", items: [id] })).text;
  assert.ok(header.includes(origin));
  assert.doesNotMatch(header, /docs\.example\.invalid/u);
  await run({ action: "save-speak-categories", kind: "mcp", categories: [{ id, category: "research" }] });
  const migrated = JSON.parse(await read("library/data.json"));
  assert.equal(migrated.servers[0].raw, undefined);
  assert.equal(migrated.mcpChecks, undefined);
  assert.equal(migrated.managed.length, 4);

  const undo = { operation: "undo", items: [id], targets: ["codex", "claude", "hermes"] };
  const preview = await run({ action: "preview", ...undo });
  const codex = await read(".codex/config.toml");
  await write(".codex/config.toml", codex.replace("keep = true", "keep = false"));
  await assert.rejects(run({ action: "apply", ...undo, token: preview.token }), /changed/u);
  const retry = await run({ action: "preview", ...undo });
  assert.ok((await run({ action: "apply", ...undo, token: retry.token })).rows.every(row => row.state === "applied"));
  const projectUndo = { ...undo, targets: ["opencode"], scope: "project", project: file("selected") };
  const projectPreview = await run({ action: "preview", ...projectUndo });
  assert.equal((await run({ action: "apply", ...projectUndo, token: projectPreview.token })).rows[0].state, "applied");
  assert.equal(await read(".config/opencode/opencode.jsonc"), global);
  for (const [agent, format, path, keys] of formats) {
    const doc = configObject(format, await read(path));
    assert.equal(doc.keep, agent !== "codex");
    assert.equal(keys.reduce((section, key) => section?.[key], doc)?.docs, undefined);
  }
  assert.equal((await run({ action: "invoke", items: [id] })).text, header);
});
