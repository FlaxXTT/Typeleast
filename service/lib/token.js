/**
 * Bearer token for the loopback dictation endpoint.
 *
 * Listening on 127.0.0.1 keeps other computers out, but not other programs on
 * this one, so every request also carries a private token. It lives in the
 * state directory (0600 on macOS; on Windows the user profile's own ACL applies),
 * where the app reads it without a keychain round trip.
 *
 * @module typeleast-service/token
 */
import { randomBytes, timingSafeEqual } from "node:crypto";
import { chmod, mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname } from "node:path";

/** Load the token, creating it on first use. */
export async function ensureToken(filePath) {
  try {
    const existing = (await readFile(filePath, "utf8")).trim();
    if (/^[a-f0-9]{64}$/.test(existing)) return existing;
  } catch {
    // Missing or unreadable: mint a fresh one below.
  }
  const token = randomBytes(32).toString("hex");
  await mkdir(dirname(filePath), { recursive: true });
  await writeFile(filePath, token + "\n", { encoding: "utf8", mode: 0o600 });
  await chmod(filePath, 0o600).catch(() => {});
  return token;
}

/**
 * Constant-time comparison of a presented bearer token.
 * @param {string} expected - the stored token.
 * @param {string|undefined} presented - the Authorization header value.
 * @returns {boolean} whether the request is authorised.
 */
export function authorize(expected, presented) {
  if (typeof presented !== "string" || !presented.startsWith("Bearer ")) return false;
  const actual = Buffer.from(presented.slice("Bearer ".length));
  const wanted = Buffer.from(expected);
  if (actual.length !== wanted.length) return false;
  return timingSafeEqual(actual, wanted);
}
