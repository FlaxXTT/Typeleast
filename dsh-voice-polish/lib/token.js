/**
 * Bearer token for the loopback dictation endpoint.
 *
 * The endpoint shares DSH's existing web server, which already requires its own
 * browser authentication for the index; a plugin route bypasses that fence, so
 * the route authenticates every request with a private token instead. The token
 * lives in a 0600 file under the DSH home: readable only by this user, and
 * usable by the native menu-bar app without a keychain round trip.
 *
 * @module dsh-voice-polish/token
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
