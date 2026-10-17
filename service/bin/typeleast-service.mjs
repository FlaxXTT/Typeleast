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
  },
  allowPositionals: false,
});

const port = values.port === undefined ? 0 : Number(values.port);
if (!Number.isInteger(port) || port < 0 || port > 65535) {
  process.stderr.write("--port must be an integer between 0 and 65535\n");
  process.exit(2);
}

let handle;
try {
  handle = await startService({
    stateDir: values["state-dir"],
    modelsDir: values["models-dir"],
    port,
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
