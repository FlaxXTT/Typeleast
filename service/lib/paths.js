/**
 * Where TypeLeast keeps its files, by platform convention.
 *
 *   state (token, runtime.json, history, dictionary, config.json)
 *     macOS    ~/Library/Application Support/TypeLeast
 *     Windows  %APPDATA%\TypeLeast
 *     Linux    $XDG_CONFIG_HOME/typeleast (~/.config/typeleast)
 *   models (about 240 MB, so never in a roaming profile)
 *     macOS    ~/Library/Application Support/TypeLeast/models
 *     Windows  %LOCALAPPDATA%\TypeLeast\models
 *     Linux    $XDG_DATA_HOME/typeleast/models (~/.local/share/typeleast/models)
 *
 * TYPELEAST_HOME and TYPELEAST_MODELS override both. Every path is built with
 * node:path, so the same code is correct on macOS and Windows.
 *
 * @module typeleast-service/paths
 */
import { homedir } from "node:os";
import { posix, win32 } from "node:path";

/** The join for the target platform, so a path built for Windows uses backslashes even in a test on macOS. */
const joinFor = (platform) => (platform === "win32" ? win32.join : posix.join);

/**
 * The state directory.
 * @param {object} [env] - environment (process.env by default).
 * @param {string} [platform] - process.platform by default.
 * @param {string} [home] - the user's home directory.
 * @returns {string} an absolute path.
 */
export function defaultStateDir(env = process.env, platform = process.platform, home = homedir()) {
  const join = joinFor(platform);
  const override = env.TYPELEAST_HOME?.trim();
  if (override) return override;
  if (platform === "darwin") return join(home, "Library", "Application Support", "TypeLeast");
  if (platform === "win32") return join(env.APPDATA?.trim() || join(home, "AppData", "Roaming"), "TypeLeast");
  return join(env.XDG_CONFIG_HOME?.trim() || join(home, ".config"), "typeleast");
}

/**
 * The models directory.
 * @param {object} [env] - environment (process.env by default).
 * @param {string} [platform] - process.platform by default.
 * @param {string} [home] - the user's home directory.
 * @returns {string} an absolute path.
 */
export function defaultModelsDir(env = process.env, platform = process.platform, home = homedir()) {
  const join = joinFor(platform);
  const override = env.TYPELEAST_MODELS?.trim();
  if (override) return override;
  if (env.TYPELEAST_HOME?.trim()) return join(env.TYPELEAST_HOME.trim(), "models");
  if (platform === "darwin") return join(home, "Library", "Application Support", "TypeLeast", "models");
  if (platform === "win32") return join(env.LOCALAPPDATA?.trim() || join(home, "AppData", "Local"), "TypeLeast", "models");
  return join(env.XDG_DATA_HOME?.trim() || join(home, ".local", "share"), "typeleast", "models");
}
