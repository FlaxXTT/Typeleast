#!/bin/bash
# test.sh - compile and run the DshClient / Wav proof harness (needs no host service).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT/build"
BIN="$BUILD_DIR/dsh-voice-tests"
SWIFTC="/usr/bin/swiftc"

mkdir -p "$BUILD_DIR"

CMD=("$SWIFTC" -swift-version 5 -O
  -target "$(uname -m)-apple-macosx13.0"
  -framework Foundation -framework Network -framework AVFoundation -framework AppKit -framework Carbon
  -o "$BIN"
  "$ROOT/Sources/DshClient.swift"
  "$ROOT/Sources/Wav.swift"
  "$ROOT/Sources/AudioConvert.swift"
  "$ROOT/Sources/Recorder.swift"
  "$ROOT/Sources/RecordingBar.swift"
  "$ROOT/Sources/FnKey.swift"
  "$ROOT/Sources/FieldContext.swift"
  "$ROOT/Sources/EditLearner.swift"
  "$ROOT/Sources/Inserter.swift"
  "$ROOT/Sources/Settings.swift"
  "$ROOT/Sources/LLMSettings.swift"
  "$ROOT/Tests/StubServer.swift"
  "$ROOT/Tests/main.swift")

echo "compile: ${CMD[*]}"
"${CMD[@]}"
echo "run: $BIN"
"$BIN"
