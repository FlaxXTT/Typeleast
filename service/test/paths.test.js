import test from "node:test";
import assert from "node:assert/strict";
import { defaultModelsDir, defaultStateDir } from "../lib/paths.js";

test("state and models follow each platform's convention", () => {
  assert.equal(defaultStateDir({}, "darwin", "/Users/me"), "/Users/me/Library/Application Support/TypeLeast");
  assert.equal(defaultModelsDir({}, "darwin", "/Users/me"), "/Users/me/Library/Application Support/TypeLeast/models");
  const win = { APPDATA: "C:\\Users\\me\\AppData\\Roaming", LOCALAPPDATA: "C:\\Users\\me\\AppData\\Local" };
  assert.equal(defaultStateDir(win, "win32", "C:\\Users\\me"), "C:\\Users\\me\\AppData\\Roaming\\TypeLeast");
  // Models are large, so on Windows they never go into the roaming profile.
  assert.equal(defaultModelsDir(win, "win32", "C:\\Users\\me"), "C:\\Users\\me\\AppData\\Local\\TypeLeast\\models");
  assert.equal(defaultStateDir({}, "win32", "C:\\Users\\me"), "C:\\Users\\me\\AppData\\Roaming\\TypeLeast", "APPDATA unset falls back under the profile");
  assert.equal(defaultStateDir({}, "linux", "/home/me"), "/home/me/.config/typeleast");
  assert.equal(defaultModelsDir({}, "linux", "/home/me"), "/home/me/.local/share/typeleast/models");
});

test("TYPELEAST_HOME and TYPELEAST_MODELS override the defaults", () => {
  assert.equal(defaultStateDir({ TYPELEAST_HOME: "/data/tl" }, "darwin", "/Users/me"), "/data/tl");
  assert.equal(defaultModelsDir({ TYPELEAST_HOME: "/data/tl" }, "darwin", "/Users/me"), "/data/tl/models");
  assert.equal(defaultModelsDir({ TYPELEAST_HOME: "/data/tl", TYPELEAST_MODELS: "/big/models" }, "darwin", "/Users/me"), "/big/models");
  assert.equal(defaultStateDir({ TYPELEAST_HOME: "  " }, "linux", "/home/me"), "/home/me/.config/typeleast", "blank means unset");
});
