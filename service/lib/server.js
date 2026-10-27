/**
 * The TypeLeast local service: one loopback HTTP server that recognises speech
 * on this computer and cleans the text with the user's own model.
 *
 * Both apps start it (bin/typeleast-service.mjs) and talk to it at
 * http://127.0.0.1:<port>/api/voice-polish. The port is chosen by the OS on
 * every start and published to <state dir>/runtime.json; the first line the
 * process prints on stdout carries it too.
 *
 * @module typeleast-service/server
 */
import { createServer } from "node:http";
import { mkdir, rm, stat } from "node:fs/promises";
import { join } from "node:path";
import { format } from "node:util";
import { SpeechModels } from "./speech-models.js";
import { loadConfig } from "./config.js";
import { createHandler } from "./http.js";
import { defaultModelsDir, defaultStateDir } from "./paths.js";
import { publishRuntime, withdrawRuntime } from "./runtime.js";
import { VoicePolishService } from "./service.js";
import { ensureToken } from "./token.js";

export const VERSION = "0.2.0";

/** Log lines go to stderr (stdout is reserved for the ready line). */
export const stderrLogger = {
  info: (...args) => process.stderr.write(`[typeleast] ${format(...args)}\n`),
  warn: (...args) => process.stderr.write(`[typeleast] warning: ${format(...args)}\n`),
  debug: () => {},
};

/**
 * Start the service.
 * @param {object} [options] - stateDir, modelsDir, port (0 = any), logger, and recognizer for tests.
 * @returns {Promise<{port: number, service: VoicePolishService, recognizer: object, stateDir: string, modelsDir: string, close: () => Promise<void>}>}
 */
export async function startService(options = {}) {
  const stateDir = options.stateDir ?? defaultStateDir();
  const modelsDir = options.modelsDir ?? defaultModelsDir();
  const logger = options.logger ?? stderrLogger;
  const host = "127.0.0.1";

  const existingInstallation = await stat(join(stateDir, "api-token")).then(info => info.isFile()).catch(() => false);
  await mkdir(stateDir, { recursive: true });
  const { value: config, issues } = await loadConfig(stateDir);
  for (const issue of issues) logger.warn?.("config.json: %s", issue.message);

  // Versions up to 1.17.8 kept a history of digests and a copy of the dictionary here;
  // the apps own both now, so the leftovers are removed.
  for (const leftover of ["history.jsonl", "dictionary.json"]) await rm(join(stateDir, leftover), { force: true }).catch(() => {});
  const recognizer = options.recognizer ?? new SpeechModels({ modelsDir, selectionPath: join(stateDir, "speech-model.json"), numThreads: config.numThreads, language: config.language, logger });
  // This is the one composition point for the optional extension module.
  // A stripped or disabled build can omit it without changing dictation.
  let extension = null;
  if (options.extensions !== false) {
    try {
      const [{ PluginStore }, { PluginRuntime }] = await Promise.all([
        import("./plugins.js"), import("./plugin-runtime.js"),
      ]);
      const plugins = new PluginStore(join(stateDir, "plugins"));
      await plugins.load();
      await plugins.migrateTechnicalPack(existingInstallation).catch(() => logger.warn?.("retired vocabulary cleanup incomplete; original retained"));
      extension = new PluginRuntime(plugins, { version: VERSION });
    } catch (error) {
      logger.warn?.("plugins could not be read (%s)", error?.code ?? "error");
    }
  }
  const service = new VoicePolishService({
    recognizer,
    config,
    extension,
    logger,
    version: VERSION,
  });
  if (recognizer instanceof SpeechModels) recognizer.beforeActivate = async signal => {
    while (service.pending > 0 || service.queue > 0) { signal?.throwIfAborted(); await new Promise(resolve => setTimeout(resolve, 50)); }
  };
  const token = await ensureToken(join(stateDir, "api-token"));

  const handler = createHandler({ service, logger, currentToken: async () => token, proofKey: options.proofKey ?? null });
  const server = createServer((req, res) => {
    void handler(req, res);
  });
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(options.port ?? 0, host, () => {
      server.off("error", reject);
      resolve();
    });
  });
  const port = server.address().port;
  await publishRuntime({ stateDir, port, pid: process.pid, version: VERSION, startedAt: service.startedAt, host });
  logger.info?.("listening on %s:%d", host, port);

  // Loading the model takes about half a second; requests that arrive first
  // get speech-not-ready and the apps show "loading".
  void recognizer.prepare();

  let closed = false;
  return {
    port,
    service,
    recognizer,
    stateDir,
    modelsDir,
    async close() {
      if (closed) return;
      closed = true;
      await withdrawRuntime({ stateDir, pid: process.pid });
      server.closeAllConnections?.();
      await new Promise((resolve) => server.close(() => resolve()));
    },
  };
}
