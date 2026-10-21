#!/bin/bash
# render.sh - offscreen PNGs of the main window, onboarding and the pill (design review).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/build/render.noindex}"
BIN="${TYPELEAST_RENDER_BIN:-$ROOT/build/typeleast-render}"
SOURCES=()
while IFS= read -r f; do SOURCES+=("$f"); done < <(find "$ROOT/Sources" -maxdepth 1 -name '*.swift' ! -name 'main.swift' | sort)
/usr/bin/swiftc -swift-version 5 -target "$(uname -m)-apple-macosx13.0" \
  -framework AppKit -framework SwiftUI -framework AVFoundation -framework CoreAudio -framework Carbon -framework ServiceManagement \
  -o "$BIN" "${SOURCES[@]}" "$ROOT/Tools/render/main.swift"
"$BIN" "$OUT"
