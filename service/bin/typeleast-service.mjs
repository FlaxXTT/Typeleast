#!/usr/bin/env node
/**
 * Start the TypeLeast local service.
 *
 *   node bin/typeleast-service.mjs [--state-dir DIR] [--models-dir DIR]
 *                                  [--port N] [--parent-pid PID]
 *
 * On success the first stdout line is one JSON object:
 *   {"event":"ready","port":51234,"pid":4321,"version":"0.2.0"}
 * Log lines go to stderr.
 *
 * --auth-stdin reads one line from stdin first: a hex secret shared only with the
 * app that started this process. /health then answers a challenge with an HMAC,
 * so the app can tell its own service from anything else listening on loopback
 * before it sends an API key.
 *
 * --parent-pid makes the service exit when that process does, so an app that
 * starts it never leaves it behind (checked every 2 s; works on macOS and
 * Windows). Ctrl+C, SIGTERM and SIGINT stop it cleanly.
 */
import { parseArgs } from "node:util";
import { startService, stderrLogger } from "../lib/server.js";

const { values } = parseArgs({
  options: {
    "state-dir": { type: "string" },
    "models-dir": { type: "string" },
    port: { type: "string" },
    "parent-pid": { type: "string" },
    "auth-stdin": { type: "boolean" },
  },
  allowPositionals: false,
});

const port = values.port === undefined ? 0 : Number(values.port);
if (!Number.isInteger(port) || port < 0 || port > 65535) {
  process.stderr.write("--port must be an integer between 0 and 65535\n");
  process.exit(2);
}

/** The first stdin line, as a 64-hex-digit secret; anything else is refused. */
async function readProofKey() {
  let data = "";
  for await (const chunk of process.stdin) {
    data += chunk;
    if (data.includes("\n") || data.length > 256) break;
  }
  const key = data.split("\n")[0].trim();
  if (!/^[0-9a-f]{64}$/.test(key)) {
    process.stderr.write("--auth-stdin expects a 64-digit hex secret on the first line of stdin\n");
    process.exit(2);
  }
  return key;
}
const proofKey = values["auth-stdin"] ? await readProofKey() : null;

let handle;
try {
  handle = await startService({
    stateDir: values["state-dir"],
    modelsDir: values["models-dir"],
    port,
    proofKey,
    logger: stderrLogger,
  });
} catch (error) {
  process.stderr.write(`[typeleast] could not start: ${error instanceof Error ? error.message : String(error)}\n`);
  process.exit(1);
}

process.stdout.write(JSON.stringify({ event: "ready", port: handle.port, pid: process.pid, version: handle.service.version }) + "\n");

let stopping = false;
async function stop(code = 0) {
  if (stopping) return;
  stopping = true;
  await handle.close().catch(() => {});
  process.exit(code);
}
process.on("SIGINT", () => void stop(0));
process.on("SIGTERM", () => void stop(0));

const parent = values["parent-pid"] === undefined ? null : Number(values["parent-pid"]);
if (parent !== null && Number.isInteger(parent) && parent > 0) {
  setInterval(() => {
    try {
      process.kill(parent, 0);
    } catch (error) {
      // EPERM means it exists but belongs to someone else: still alive.
      if (error?.code === "ESRCH") void stop(0);
    }
  }, 2000);
}
