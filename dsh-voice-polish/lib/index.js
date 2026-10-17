/**
 * Voice-polish host plugin.
 *
 * Mounts one service and one loopback route:
 *   ctx.voicePolish                       in-process API (used by any plugin)
 *   /api/voice-polish/*                   HTTP API (used by the native app)
 *
 * Everything it needs already exists in the running DSH process: the local
 * SenseVoice recogniser (`ctx.speechToText`) and the signed-in model route
 * (`ctx.llm`). It therefore adds no dependency, no download and no second port.
 *
 * @module dsh-voice-polish
 */
import { Config, DEFAULT_STATE_DIR } from "./config.js";
import { History } from "./history.js";
import { VoicePolishService } from "./service.js";
import { createHandler, ROUTE_PREFIX } from "./http.js";
import { ensureToken } from "./token.js";
import { publishRuntime, withdrawRuntime } from "./runtime.js";
import { join } from "node:path";

const VERSION = "0.1.0";
const NAME = "voice-polish";

/** Services required before this plugin can do anything useful. */
export const inject = ["llm", "speechToText"];

export { Config };

/**
 * Register the dictation service, its storage and its HTTP route.
 * @param {object} ctx - Cordis context.
 * @param {object} config - validated configuration from {@link Config}.
 */
export function apply(ctx, config) {
  const logger = (typeof ctx.logger === "function" ? ctx.logger(NAME) : ctx.logger) ?? console;
  const stateDir = config.stateDir || DEFAULT_STATE_DIR;
  const tokenPath = join(stateDir, "api-token");
  const historyPath = join(stateDir, "history.jsonl");
  const dictionaryPath = join(stateDir, "dictionary.json");

  const history = new History({ filePath: historyPath, retentionDays: config.historyDays ?? 14 });
  const service = new VoicePolishService({
    ctx,
    config,
    history,
    dictionaryPath,
    logger,
    version: VERSION,
  });

  let tokenCache = null;
  const currentToken = async () => {
    if (tokenCache === null) tokenCache = await ensureToken(tokenPath);
    return tokenCache;
  };

  // Expose the service for other plugins; the client-side button and any future
  // caller use the same contract as the HTTP route.
  ctx.provide("voicePolish", service);

  // The route lives on DSH's existing server, so wait for it rather than
  // requiring the caller to order the composition by hand.
  ctx.inject(["webServer"], (scope) => {
    const handler = createHandler({ service, logger, currentToken });
    scope.effect(
      () => scope.webServer.register({ kind: "prefix", path: ROUTE_PREFIX, handler }),
      "voice-polish: loopback route",
    );

    // Publish the live port so the native app can find this server.
    //
    // DSH binds an OS-assigned port, and it changes on every launch, so a client
    // that hard-codes one reports "service not started" while the service is
    // running perfectly. `webServer.port` is undefined until the listener is
    // bound, hence the bounded retry; the port never changes after that.
    let cancelled = false;
    let attempts = 0;
    const publish = () => {
      if (cancelled) return;
      const port = scope.webServer?.port;
      if (typeof port === "number" && port > 0) {
        publishRuntime({
          stateDir,
          port,
          pid: process.pid,
          version: VERSION,
          startedAt: service.startedAt,
        })
          .then((target) => logger.info?.("voice-polish: published %s (port %d)", target, port))
          .catch((error) => logger.warn?.("voice-polish: could not publish runtime: %s", error instanceof Error ? error.message : String(error)));
        return;
      }
      attempts += 1;
      if (attempts <= 100) setTimeout(publish, 100); // up to 10 s
    };
    publish();

    scope.effect(() => () => {
      cancelled = true;
      void withdrawRuntime({ stateDir, pid: process.pid });
    }, "voice-polish: withdraw runtime");
  });

  const ready = (async () => {
    await history.load();
    await service.loadDictionary();
    await currentToken();
    logger.info?.(
      "voice-polish %s ready: provider=%s model=%s strength=%s state=%s",
      VERSION,
      config.provider,
      config.model,
      config.strength,
      stateDir,
    );
  })();

  ctx.effect(() => () => {
    logger.info?.("voice-polish disposed");
  });

  // A failure here must not take the host down; the route reports its own state.
  ready.catch((error) => {
    logger.warn?.("voice-polish: startup tasks failed: %s", error instanceof Error ? error.message : String(error));
  });
}

export const name = NAME;
