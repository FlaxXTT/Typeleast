#!/bin/bash
# paste-check.sh - paste and cursor-anchor checks against real apps (TextEdit, browsers).
# Moves the mouse and opens windows: run by hand. Needs Accessibility for the terminal.
#   ./Tools/paste-check.sh                 TextEdit: paste, moved cursor, other window, pill ✓, prompt panel
#   ./Tools/paste-check.sh browser:Safari:com.apple.Safari
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/build/paste-check"
mkdir -p "$ROOT/build"
SOURCES=()
while IFS= read -r source; do SOURCES+=("$source"); done < <(find "$ROOT/Sources" -maxdepth 1 -name '*.swift' ! -name main.swift | sort)
/usr/bin/swiftc -swift-version 5 -target "$(uname -m)-apple-macosx13.0" \
  -framework Foundation -framework Network -framework AVFoundation -framework AppKit -framework Carbon \
  -framework SwiftUI -framework CoreAudio -framework ServiceManagement \
  -o "$BIN" "${SOURCES[@]}" "$ROOT/Tools/PasteCheck/main.swift"
PASTECHECK_WEB="$ROOT/Tools/PasteCheck/web" "$BIN" "${1:-all}"
