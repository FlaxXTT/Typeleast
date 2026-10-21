#!/usr/bin/env bash
# make-media.sh - render the Windows images for README and site into docs/media/windows/.
# Needs the Microsoft .NET 8 SDK, wine with a prefix to spare (its %APPDATA% gets sample data),
# xvfb-run, Python 3 with Pillow, and ffmpeg.
#   WINEPREFIX=/tmp/media-prefix apps/windows/Tools/MediaRenderer/make-media.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../../../.." && pwd)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
dotnet publish "$here/TypeLeast.MediaRenderer.csproj" -c Release -r win-x64 --self-contained true -o "$out/bin"
WINEDEBUG=-all xvfb-run -a wine "$out/bin/TypeLeast.MediaRenderer.exe" "$(winepath -w "$out")"
python3 "$here/compose.py" "$out" "$root/docs/media/windows"
ffmpeg -loglevel error -y -framerate 25 -i "$out/bar-%03d.png" -vf "tpad=stop_mode=clone:stop_duration=1.2,format=yuv420p" \
    -c:v libx264 -crf 22 -movflags +faststart "$root/docs/media/windows/recording-bar.mp4"
