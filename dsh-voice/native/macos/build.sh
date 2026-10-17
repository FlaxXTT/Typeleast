#!/bin/bash
# build.sh - compile, bundle, ad-hoc sign and install TypeLeast.app
# Usage: ./build.sh [--no-install] [--test]
#
# The bundle is assembled under build/dist.noindex/: Spotlight skips *.noindex
# folders, so the build copy never shows up as a second "TypeLeast" in Spotlight,
# Launchpad or the Apps view. After installing, the staging copy is removed and
# unregistered, the old instance is quit and the installed app is relaunched, so
# exactly one TypeLeast exists and runs. The app was called dsh-voice before;
# that copy is quit, removed and unregistered on install. The bundle id stays
# com.dsh.voice so settings, history and the dictionary carry over.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT/build"
STAGE_DIR="$BUILD_DIR/dist.noindex"
APP="$STAGE_DIR/TypeLeast.app"
SWIFTC="/usr/bin/swiftc"
ARCH="$(uname -m)"
TARGET="$ARCH-apple-macosx13.0"
BIN_NAME="TypeLeast"
LEGACY_DEST="$HOME/Applications/dsh-voice.app"
DEST="$HOME/Applications/$BIN_NAME.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

if [ "${1:-}" = "--test" ]; then
  exec "$ROOT/test.sh"
fi

echo "== TypeLeast build =="
echo "swiftc : $($SWIFTC --version 2>&1 | head -1)"
echo "target : $TARGET"

# A copy left by older versions of this script directly under build/ is what made
# two dsh-voice entries appear in the Apps view.
if [ -d "$BUILD_DIR/dsh-voice.app" ]; then
  "$LSREGISTER" -u "$BUILD_DIR/dsh-voice.app" >/dev/null 2>&1 || true
  rm -rf "$BUILD_DIR/dsh-voice.app"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

SOURCES=()
while IFS= read -r f; do SOURCES+=("$f"); done < <(find "$ROOT/Sources" -maxdepth 1 -name '*.swift' | sort)
if [ ${#SOURCES[@]} -eq 0 ]; then echo "no sources found in $ROOT/Sources" >&2; exit 1; fi
echo "sources: ${#SOURCES[@]} files"

"$SWIFTC" \
  -swift-version 5 \
  -O \
  -target "$TARGET" \
  -framework AppKit \
  -framework SwiftUI \
  -framework AVFoundation \
  -framework CoreAudio \
  -framework Carbon \
  -framework ServiceManagement \
  -framework Foundation \
  -o "$APP/Contents/MacOS/$BIN_NAME" \
  "${SOURCES[@]}"

cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"; fi

# Ad-hoc signature (no identity required, no network).
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 || codesign --force --sign - "$APP"
echo "signed : $(codesign -dv "$APP" 2>&1 | grep -m1 'Signature' || echo 'adhoc')"

if [ "${1:-}" != "--no-install" ]; then
  # Quit the running copy (new or old name) so the new binary is the only one alive.
  if pgrep -x "$BIN_NAME" >/dev/null 2>&1 || pgrep -x dsh-voice >/dev/null 2>&1; then
    osascript -e 'tell application id "com.dsh.voice" to quit' >/dev/null 2>&1 || true
    sleep 1
    pkill -x "$BIN_NAME" >/dev/null 2>&1 || true
    pkill -x dsh-voice >/dev/null 2>&1 || true
  fi
  # The pre-rename copy: remove it so Spotlight / the Apps view list one app.
  if [ -d "$LEGACY_DEST" ]; then
    "$LSREGISTER" -u "$LEGACY_DEST" >/dev/null 2>&1 || true
    rm -rf "$LEGACY_DEST"
    echo "removed old: $LEGACY_DEST"
  fi
  rm -rf "$STAGE_DIR/dsh-voice.app"
  mkdir -p "$HOME/Applications"
  rm -rf "$DEST"
  cp -R "$APP" "$DEST"
  "$LSREGISTER" -u "$APP" >/dev/null 2>&1 || true
  rm -rf "$APP"
  "$LSREGISTER" -f "$DEST" >/dev/null 2>&1 || true
  echo ""
  echo "INSTALLED_APP=$DEST"
  codesign --verify --deep --strict "$DEST" && echo "codesign --verify: OK"
  plutil -p "$DEST/Contents/Info.plist" | grep -E 'LSUIElement|CFBundleIdentifier'
  open "$DEST"
  echo "launched: $DEST"
fi
echo ""
echo "build.sh: exit 0"
