// record-film.mjs - record the product film (site/film.js) for the README:
//   docs/media/promo.mp4, promo.gif and promo-poster.jpg (Chinese), promo-en.mp4 (English).
// Needs Playwright with Chromium and ffmpeg.
//
//   node site/record-film.mjs
import { execFileSync } from "node:child_process";
import { mkdtempSync, rmSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { createRequire } from "node:module";

// A global Playwright install is found through NODE_PATH, which only require() reads.
const { chromium } = await import("playwright").catch(() => createRequire(import.meta.url)("playwright"));

const here = dirname(fileURLToPath(import.meta.url));
const media = join(here, "..", "docs", "media");
const film = readFileSync(join(here, "film.js"), "utf8");
const FPS = 30, W = 1280, H = 720;

async function frames(browser, lang, dir) {
  const page = await browser.newPage({ viewport: { width: W, height: H } });
  await page.setContent(`<!doctype html><meta charset="utf-8"><style>html,body{margin:0;background:#000}</style>
<div id="f" style="width:${W}px"></div><script>${film}</script>
<script>window.f = TypeLeastFilm.mount(document.getElementById("f"), "${lang}");</script>`);
  await page.evaluate(() => document.fonts.ready);
  const length = await page.evaluate(() => window.f.length);
  for (let i = 0; i < length * FPS; i++) {
    await page.evaluate((s) => window.f.seek(s), i / FPS);
    await page.screenshot({ path: join(dir, `f${String(i).padStart(4, "0")}.png`) });
  }
  await page.close();
}

const ffmpeg = (...args) => execFileSync("ffmpeg", ["-hide_banner", "-loglevel", "error", "-y", ...args], { stdio: "inherit" });

const browser = await chromium.launch();
for (const lang of ["zh", "en"]) {
  const dir = mkdtempSync(join(tmpdir(), "typeleast-film-"));
  try {
    await frames(browser, lang, dir);
    const input = ["-framerate", String(FPS), "-i", join(dir, "f%04d.png")];
    const mp4 = join(media, lang === "zh" ? "promo.mp4" : "promo-en.mp4");
    ffmpeg(...input, "-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "20", "-preset", "slow", "-movflags", "+faststart", mp4);
    if (lang === "zh") {
      ffmpeg("-i", join(dir, "f0200.png"), "-q:v", "3", join(media, "promo-poster.jpg"));
      const vf = "fps=12,scale=880:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=96:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle";
      ffmpeg(...input, "-vf", vf, join(media, "promo.gif"));
    }
    console.log("film:", lang, "done");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}
await browser.close();
