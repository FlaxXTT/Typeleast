#!/usr/bin/env bash
# build.sh - assemble the one-page site into site/dist from site/ and docs/media/,
# so the images are not stored twice. Cloudflare Pages: build command "bash site/build.sh",
# output directory "site/dist".
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
out="$root/site/dist"
media="$root/docs/media"
rm -rf "$out"
mkdir -p "$out/assets"
cp "$root/site/index.html" "$root/site/_headers" "$out/"
cp "$media/icon-256.png" "$out/assets/icon.png"
cp "$media/promo.mp4" "$media/promo-poster.jpg" "$out/assets/"
cp "$media/windows/recording-bar.mp4" "$media/windows/recording-bar-poster.png" "$out/assets/"
for page in home-light home-dark settings-light history-light; do cp "$media/windows/$page.png" "$out/assets/win-$page.png"; done
for page in home history settings dictionary-dark; do cp "$media/$page.png" "$out/assets/mac-$page.png"; done
echo "site: $out"
