/**
 * Runtime publication.
 *
 * The service binds an OS-assigned port, a new one on every start, so a client
 * cannot hard-code one. This module publishes the facts a client needs — above
 * all the live port — to a file beside the token:
 *
 *   <state dir>/runtime.json
 *   { "port": 51234, "pid": 4321, "version": "0.1.0", "startedAt": 1792... }
 *
 * The file is the contract between the two halves. It is written atomically so a
 * reader never observes a half-written document, and it is advisory: a client must
 * still confirm with GET /health, because the file outlives a crashed service.
 *
 * @module typeleast-service/runtime
 */
import { mkdir, rename, rm, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";

export const RUNTIME_FILE = "runtime.json";

/**
 * Write the runtime descriptor atomically.
 * @param {object} options - state directory and the facts to publish.
 * @returns {Promise<string>} the path written.
 */
export async function publishRuntime(options) {
  const { stateDir, port, pid, version, startedAt, host = "127.0.0.1" } = options;
  const target = join(stateDir, RUNTIME_FILE);
  const temporary = `${target}.${pid}.${Date.now()}.tmp`;
  const payload = {
    schemaVersion: 1,
    host,
    port,
    pid,
    version,
    startedAt,
  };
  await mkdir(dirname(target), { recursive: true });
  await writeFile(temporary, JSON.stringify(payload, null, 2) + "\n", { encoding: "utf8", mode: 0o600 });
  await rename(temporary, target);
  return target;
}

/**
 * Remove the runtime descriptor, but only when it still describes this process.
 * A service that was replaced by a newer one must not delete the newer file.
 * @param {object} options - state directory and this process's pid.
 */
export async function withdrawRuntime(options) {
  const { stateDir, pid } = options;
  const target = join(stateDir, RUNTIME_FILE);
  try {
    const { readFile } = await import("node:fs/promises");
    const parsed = JSON.parse(await readFile(target, "utf8"));
    if (parsed?.pid === pid) await rm(target, { force: true });
  } catch {
    // Absent or unreadable: nothing to withdraw.
  }
}
