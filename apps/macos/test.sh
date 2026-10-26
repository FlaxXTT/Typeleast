#!/bin/bash
# test.sh - compile and run the ServiceClient / Wav proof harness (needs no running service).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT/build"
BIN="$BUILD_DIR/typeleast-tests"
SWIFTC="/usr/bin/swiftc"

mkdir -p "$BUILD_DIR"

# Compile the production controllers too: a handwritten subset can silently miss a refactor.
SOURCES=()
while IFS= read -r source; do SOURCES+=("$source"); done < <(find "$ROOT/Sources" -maxdepth 1 -name '*.swift' ! -name main.swift | sort)

CMD=("$SWIFTC" -swift-version 5 -O
  -target "$(uname -m)-apple-macosx13.0"
  -framework Foundation -framework Network -framework AVFoundation -framework AppKit -framework Carbon -framework SwiftUI -framework CoreAudio -framework ServiceManagement
  -o "$BIN"
  "${SOURCES[@]}"
  "$ROOT/Tests/StubServer.swift"
  "$ROOT/Tests/ContextPreferencesTests.swift"
  "$ROOT/Tests/main.swift")

echo "compile: ${CMD[*]}"
"${CMD[@]}"
echo "run: $BIN"
TYPELEAST_SUGGESTION_RESPONSES="$ROOT/../../service/test/fixtures/suggestion-responses.json" \
TYPELEAST_DICTIONARY_CONTRACT="$ROOT/../../tests/conformance/automatic-dictionary-v1.json" \
TYPELEAST_CLIENT_CONTRACT="$ROOT/../../tests/conformance/client-v2.json" "$BIN"
