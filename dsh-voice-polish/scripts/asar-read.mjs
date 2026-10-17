#!/usr/bin/env node
/**
 * Read-only access to DSH's shipped implementation inside app.asar.
 *
 * The asar data base is 8 + <pickled header size at offset 4>, NOT
 * 8 + <header JSON length at offset 12>: those differ by the 10-byte pickle
 * prefix, and using the wrong one shifts every member by 10 bytes (which is
 * what makes extracted files appear to start with stray text). Verified by
 * comparing a member's sha256 against the header's own integrity.hash.
 *
 * Usage:
 *   node scripts/asar-read.mjs ls <asar-path>
 *   node scripts/asar-read.mjs head <asar-path> <member> [bytes]
 *   node scripts/asar-read.mjs extract <asar-path> <member-prefix> <out-dir>
 */
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export function openAsar(asarPath) {
  const fd = fs.openSync(asarPath, 'r');
  const head = Buffer.alloc(16);
  fs.readSync(fd, head, 0, 16, 0);
  const PICKLE = head.readUInt32LE(0);
  const jsonLength = head.readUInt32LE(12);
  const pickledLength = head.readUInt32LE(4);
  if (jsonLength <= 0 || pickledLength < jsonLength) {
    fs.closeSync(fd);
    throw new Error(`not an asar archive: ${asarPath}`);
  }
  const headerBuffer = Buffer.alloc(jsonLength);
  fs.readSync(fd, headerBuffer, 0, jsonLength, 16);
  const root = JSON.parse(headerBuffer.toString('utf8').replace(/\0+$/, ''));
  const base = 8 + pickledLength;
  return { fd, root, base, pickleSize: PICKLE, jsonLength, pickledLength, asarPath };
}

export function lookup(archive, member) {
  let node = archive.root;
  for (const segment of member.split('/').filter(Boolean)) {
    if (!node || !node.files || !Object.prototype.hasOwnProperty.call(node.files, segment)) return null;
    node = node.files[segment];
  }
  return node;
}

/** Read one file member. Throws if the member is a directory or absent. */
export function readMember(archive, member) {
  const node = lookup(archive, member);
  if (!node) throw new Error(`asar member not found: ${member}`);
  if (node.files) throw new Error(`asar member is a directory: ${member}`);
  if (typeof node.offset !== 'string') {
    // Unpacked entries carry no offset; surface the real path instead of reading garbage.
    throw new Error(`asar member is unpacked (no offset): ${member}`);
  }
  const bytes = Buffer.alloc(node.size);
  fs.readSync(archive.fd, bytes, 0, node.size, archive.base + Number.parseInt(node.offset, 10));
  return bytes;
}

/** Verify a member against its own recorded integrity hash. Returns { ok, actual, expected }. */
export function verifyMember(archive, member) {
  const node = lookup(archive, member);
  const bytes = readMember(archive, member);
  const actual = createHash('sha256').update(bytes).digest('hex');
  const expected = node?.integrity?.hash;
  return { ok: expected === undefined || actual === expected, actual, expected };
}

export function walk(archive, prefix = '') {
  const node = prefix ? lookup(archive, prefix) : archive.root;
  const out = [];
  const visit = (current, currentPath) => {
    for (const [name, child] of Object.entries(current.files ?? {})) {
      const childPath = currentPath ? `${currentPath}/${name}` : name;
      if (child.files) visit(child, childPath);
      else out.push({ path: childPath, size: child.size, offset: child.offset });
    }
  };
  visit(node, prefix);
  return out;
}

export function extractTree(archive, prefix, outDir) {
  const node = lookup(archive, prefix);
  if (!node) throw new Error(`asar member not found: ${prefix}`);
  let files = 0;
  let bytes = 0;
  const visit = (current, currentPath) => {
    if (!current.files) {
      const data = readMember(archive, currentPath);
      fs.mkdirSync(path.dirname(outDir), { recursive: true });
      const target = path.join(outDir, path.relative(prefix, currentPath));
      fs.mkdirSync(path.dirname(target), { recursive: true });
      fs.writeFileSync(target, data);
      files += 1;
      bytes += data.length;
      return;
    }
    for (const [name, child] of Object.entries(current.files)) {
      visit(child, currentPath ? `${currentPath}/${name}` : name);
    }
  };
  visit(node, prefix);
  return { files, bytes };
}

const isMain = process.argv[1] && path.resolve(process.argv[1]) === path.resolve(fileURLToPath(import.meta.url));
if (isMain) {
  const [command, asarPath, ...rest] = process.argv.slice(2);
  if (!command || !asarPath) {
    console.error('usage: asar-read.mjs <ls|head|verify|extract> <asar> [...]');
    process.exit(2);
  }
  const archive = openAsar(asarPath);
  try {
    if (command === 'ls') {
      const rows = walk(archive, rest[0] ?? '');
      for (const row of rows) console.log(`${String(row.size).padStart(9)}  ${row.path}`);
      console.log(`# ${rows.length} files, base=${archive.base}, pickle=${archive.pickledLength}`);
    } else if (command === 'head') {
      const limit = Number.parseInt(rest[1] ?? '600', 10);
      process.stdout.write(readMember(archive, rest[0]).toString('utf8').slice(0, limit));
      console.log();
    } else if (command === 'verify') {
      console.log(JSON.stringify(verifyMember(archive, rest[0]), null, 2));
    } else if (command === 'extract') {
      const result = extractTree(archive, rest[0], rest[1]);
      console.log(`extracted ${result.files} files (${result.bytes} bytes) -> ${rest[1]}`);
    } else {
      throw new Error(`unknown command: ${command}`);
    }
  } finally {
    fs.closeSync(archive.fd);
  }
}
