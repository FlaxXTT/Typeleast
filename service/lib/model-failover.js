import { ModelCallError } from "./llm.js";
import { normalizeRoute } from "./openai-compat.js";

/** Unavailable accounts/models, transport failures and rate limits qualify for failover. */
function unavailable(error) {
  if (!(error instanceof ModelCallError)) return false;
  if (error.kind === "timeout") return true;
  if (error.kind !== "error") return false;
  const code = String(error.code ?? "");
  const status = /^HTTP_(\d{3})$/.exec(code);
  return code === "NETWORK" || (status !== null && ([401, 402, 403, 404, 429].includes(Number(status[1])) || Number(status[1]) >= 500));
}

/** Routes exist only for this request and are never persisted by the service. */
export function modelRoutes(primary, backups) {
  const routes = [primary];
  const seen = new Set([`${primary.baseURL}\u0000${primary.model}`]);
  if (!Array.isArray(backups)) return routes;
  for (const value of backups.slice(0, 8)) {
    const route = normalizeRoute(value);
    if (!route) continue;
    const identity = `${route.baseURL}\u0000${route.model}`;
    if (seen.has(identity)) continue;
    seen.add(identity);
    routes.push(route);
  }
  return routes;
}

/** A model call may be retried on the next user-configured provider, without duplicating output. */
export function modelCompletion({ routes, hasDeferredBackups, rawText, complete, onSuccess }) {
  let activeIndex = 0;
  const originalChars = Array.from(rawText).length;
  return async (options) => {
    const alternatives = routes.length > 1 || hasDeferredBackups;
    // Assistant turns can contain earlier answers even when the current answer is empty.
    const userChars = Array.from(String(options.user ?? "")).length;
    const shortTimeout = Math.max(10_000, 8_000 + Math.max(originalChars, userChars) * 40);
    for (let i = activeIndex; i < routes.length; i += 1) {
      options.signal?.throwIfAborted();
      options.retryBudget?.assertTime();
      const canContinue = i < routes.length - 1 || hasDeferredBackups;
      try {
        const result = await complete({ ...options, route: routes[i],
          ...(alternatives ? { maxTransportAttempts: 1 } : {}),
          ...(canContinue ? { timeoutMs: Math.min(options.timeoutMs, shortTimeout) } : {}),
        });
        activeIndex = i;
        onSuccess(routes[i], i > 0);
        return result;
      } catch (error) {
        if (options.signal?.aborted || !unavailable(error)) throw error;
        if (i + 1 < routes.length) continue;
        if (hasDeferredBackups && error instanceof ModelCallError) error.offerFailover = true;
        throw error;
      }
    }
    throw new ModelCallError("error", "no model route available");
  };
}
