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
#
# The local service (../../service, Node.js) is copied into
# Contents/Resources/service together with its dependencies, so the app needs
# only Node.js 22+ on the Mac. `npm ci` runs once if they are missing.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="${TYPELEAST_BUILD_DIR:-$ROOT/build}"
STAGE_DIR="$BUILD_DIR/dist.noindex"
APP="$STAGE_DIR/TypeLeast.app"
SWIFTC="/usr/bin/swiftc"
# TYPELEAST_ARCH=x86_64 cross-builds for Intel (development only: Intel is no longer released).
ARCH="${TYPELEAST_ARCH:-$(uname -m)}"
TARGET="$ARCH-apple-macosx13.0"
BIN_NAME="TypeLeast"
SERVICE_SRC="$(cd "$ROOT/../../service" && pwd)"
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

# Development builds keep the self-check and demo hooks (environment variables that
# drive the app); a release (package.sh sets TYPELEAST_RELEASE=1) compiles them out.
DEV_FLAG=()
[ "${TYPELEAST_RELEASE:-0}" = 1 ] || DEV_FLAG=(-D TYPELEAST_DEV)
echo "hooks  : $([ ${#DEV_FLAG[@]} -gt 0 ] && echo 'self-check and demo (development build)' || echo 'none (release build)')"

"$SWIFTC" \
  -swift-version 5 \
  -O \
  ${DEV_FLAG[@]+"${DEV_FLAG[@]}"} \
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

# The local service and its dependencies (sherpa-onnx for this Mac's architecture).
if [ ! -d "$SERVICE_SRC/node_modules/sherpa-onnx-node" ]; then
  if ! command -v npm >/dev/null 2>&1; then
    echo "npm not found: install Node.js 22+ (https://nodejs.org) and run this again" >&2
    exit 1
  fi
  echo "service: installing dependencies (npm ci)"
  (cd "$SERVICE_SRC" && npm ci --omit=dev --no-audit --no-fund)
fi
mkdir -p "$APP/Contents/Resources/service"
cp -R "$SERVICE_SRC/bin" "$SERVICE_SRC/lib" "$SERVICE_SRC/package.json" "$SERVICE_SRC/node_modules" \
  "$APP/Contents/Resources/service/"
echo "service: bundled $(du -sh "$APP/Contents/Resources/service" | cut -f1)"

for localization in "$ROOT/Resources/"*.lproj; do
  if [ -d "$localization" ]; then cp -R "$localization" "$APP/Contents/Resources/"; fi
done
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/../../LICENSE" "$APP/Contents/Resources/LICENSE"
printf 'APPL????' > "$APP/Contents/PkgInfo"
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"; fi

# Enable Hardened Runtime to restrict library injection and debugger attachment.
# This process holds microphone, Accessibility and Keychain permissions.
# Sign with a fixed local certificate when there is one (see make-signing-cert.sh):
# the signature then stays the same across rebuilds, so macOS keeps the Keychain
# "Always Allow" and the Accessibility permission. Otherwise ad-hoc (no identity, no network).
SIGN_IDENTITY="${TYPELEAST_SIGN_IDENTITY:-TypeLeast Local Signing}"
if security find-certificate -c "$SIGN_IDENTITY" >/dev/null 2>&1; then
  codesign --force --sign "$SIGN_IDENTITY" --timestamp=none --options runtime --entitlements "$ROOT/TypeLeast.entitlements" "$APP"
  echo "signed : $SIGN_IDENTITY"
else
  codesign --force --sign - --timestamp=none --options runtime --entitlements "$ROOT/TypeLeast.entitlements" "$APP" >/dev/null 2>&1 \
    || codesign --force --sign - --options runtime --entitlements "$ROOT/TypeLeast.entitlements" "$APP"
  echo "signed : $(codesign -dv "$APP" 2>&1 | grep -m1 'Signature' || echo 'adhoc') (run make-signing-cert.sh once to keep permissions across rebuilds)"
fi

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
