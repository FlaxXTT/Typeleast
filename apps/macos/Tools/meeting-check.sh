#!/bin/bash
# meeting-check.sh <built TypeLeast.app> <models dir> import|record <audio file> <output prefix>
# Runs the app's bundled service and engine on a real file through the Meetings page's controller.
# Uses a temporary state folder, so the installed app's settings, history and service stay untouched.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$1"; MODELS="$2"; MODE="$3"; AUDIO="$4"; OUT="$5"
HOME_DIR="$(mktemp -d)"
trap '[ -n "${SERVICE:-}" ] && kill "$SERVICE" 2>/dev/null; rm -rf "$HOME_DIR"' EXIT
BIN="$ROOT/build/typeleast-meeting-check"
SOURCES=()
while IFS= read -r f; do SOURCES+=("$f"); done < <(find "$ROOT/Sources" -maxdepth 1 -name '*.swift' ! -name 'main.swift' | sort)
/usr/bin/swiftc -swift-version 5 -target "$(uname -m)-apple-macosx13.0" \
  -framework AppKit -framework SwiftUI -framework AVFoundation -framework CoreAudio -framework Carbon -framework ServiceManagement \
  -o "$BIN" "${SOURCES[@]}" "$ROOT/Tools/meeting-check/main.swift"
export TYPELEAST_HOME="$HOME_DIR" TYPELEAST_MODELS="$MODELS"
node --expose-gc "$APP/Contents/Resources/service/bin/typeleast-service.mjs" > "$HOME_DIR/service.log" 2>&1 &
SERVICE=$!
for _ in $(seq 1 100); do [ -s "$HOME_DIR/runtime.json" ] && break; sleep 0.1; done
"$BIN" "$MODE" "$AUDIO" "$OUT"
