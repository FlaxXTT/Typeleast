#!/bin/bash
# package.sh - build a self-contained TypeLeast for one kind of Mac, as .dmg and .zip.
#
#   ./package.sh arm64  [out-dir]     Apple silicon (M1 and later)
#   (Intel Macs are no longer built; the last Intel release is 1.17.1.)
#
# The app carries the local service, the MLX worker and an official Node.js
# binary. Speech model weights are downloaded separately after user selection.
#
# NODE_VERSION picks the Node.js release; TYPELEAST_NODE_BINARY=<path> uses a
# local node binary instead of downloading one (for testing this script).
set -euo pipefail

ARCH="${1:?usage: package.sh arm64 [out-dir]}"
ROOT="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=apps/macos/scripts/package-names.sh
source "$ROOT/scripts/package-names.sh"
OUT="${2:-$ROOT/build/release}"
NODE_VERSION="${NODE_VERSION:-24.21.0}"
case "$ARCH" in
  arm64) NODE_ARCH="arm64"; LABEL="AppleSilicon" ;;
  x86_64) echo "Intel Macs are no longer built (the last Intel release is 1.17.1)" >&2; exit 2 ;;
  *) echo "unknown arch: $ARCH (use arm64)" >&2; exit 2 ;;
esac
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Info.plist")"
BUILD_DIR="${TYPELEAST_BUILD_DIR:-$ROOT/build}"
mkdir -p "$BUILD_DIR" "$OUT"
BUILD_DIR="$(cd "$BUILD_DIR" && pwd -P)"
OUT="$(cd "$OUT" && pwd -P)"
export TYPELEAST_BUILD_DIR="$BUILD_DIR"
WORK="$BUILD_DIR/package-$ARCH"
case "$OUT/" in
  "$WORK/"*) echo "Release output cannot be inside the temporary packaging directory." >&2; exit 1 ;;
esac
DMG_NAME="$(typeleast_macos_dmg_name "$VERSION" "$LABEL")"
ZIP_NAME="$(typeleast_macos_zip_name "$VERSION" "$LABEL")"
LEGACY_ZIP_NAME="$(typeleast_macos_legacy_zip_name "$VERSION" "$LABEL")"
if [ -e "$OUT/$LEGACY_ZIP_NAME" ] || [ -e "$OUT/$DMG_NAME" ] || [ -e "$OUT/$ZIP_NAME" ]; then
  echo "Release output already contains an asset for $VERSION; choose an empty output directory." >&2
  exit 1
fi
CACHE="${TYPELEAST_PACKAGE_CACHE:-$WORK}"
rm -rf "$WORK"
mkdir -p "$WORK" "$OUT" "$CACHE"

echo "== TypeLeast $VERSION for $LABEL ($ARCH), Node.js $NODE_VERSION =="
TYPELEAST_RELEASE=1 TYPELEAST_ARCH="$ARCH" "$ROOT/build.sh" --no-install
APP_SRC="$BUILD_DIR/dist.noindex/TypeLeast.app"
APP="$WORK/TypeLeast.app"
ditto "$APP_SRC" "$APP"
RES="$APP/Contents/Resources"

# The shared service retains the Windows adapter in source, but Mac packages do
# not ship its ONNX runtime. The Mac catalog must expose only MLX models.
rm -rf "$RES/service/node_modules/sherpa-onnx-node" "$RES/service/node_modules/"sherpa-onnx-darwin-*

# Node.js, verified against nodejs.org's published SHA-256 list.
mkdir -p "$RES/node/bin"
if [ -n "${TYPELEAST_NODE_BINARY:-}" ]; then
  cp "$TYPELEAST_NODE_BINARY" "$RES/node/bin/node"
  echo "node   : local binary (test build)"
else
  TARBALL="node-v$NODE_VERSION-darwin-$NODE_ARCH.tar.gz"
  BASE="https://nodejs.org/dist/v$NODE_VERSION"
  SUMS="node-v$NODE_VERSION-SHASUMS256.txt"
  if [ ! -f "$CACHE/$TARBALL" ]; then curl -fsSL "$BASE/$TARBALL" -o "$CACHE/$TARBALL"; fi
  if [ ! -f "$CACHE/$SUMS" ]; then curl -fsSL "$BASE/SHASUMS256.txt" -o "$CACHE/$SUMS"; fi
  (cd "$CACHE" && grep " $TARBALL\$" "$SUMS" | shasum -a 256 -c -)
  tar -xzf "$CACHE/$TARBALL" -C "$WORK"
  cp "$WORK/node-v$NODE_VERSION-darwin-$NODE_ARCH/bin/node" "$RES/node/bin/node"
  cp "$WORK/node-v$NODE_VERSION-darwin-$NODE_ARCH/LICENSE" "$RES/node/LICENSE"
  echo "node   : $TARBALL (sha256 verified)"
fi
cp "$ROOT/../../THIRD-PARTY-NOTICES.md" "$RES/THIRD-PARTY-NOTICES.md"

# Re-seal the bundle. Not --deep: Node.js keeps the signature nodejs.org gave it.
codesign --force --sign - --timestamp=none --options runtime --entitlements "$ROOT/TypeLeast.entitlements" "$APP"
codesign --verify --strict "$APP"

STAGE="$WORK/dmg"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/TypeLeast.app"
ln -s /Applications "$STAGE/Applications"
# hdiutil is occasionally "Resource busy" on build machines: retry a few times.
for attempt in 1 2 3 4 5; do
  if hdiutil create -quiet -volname "TypeLeast" -srcfolder "$STAGE" -ov -format UDZO "$OUT/$DMG_NAME"; then break; fi
  [ "$attempt" = 5 ] && { echo "hdiutil failed" >&2; exit 1; }
  sleep $((attempt * 3))
done
(cd "$WORK" && ditto -c -k --keepParent TypeLeast.app "$OUT/$ZIP_NAME")
(cd "$OUT" && shasum -a 256 "$DMG_NAME" "$ZIP_NAME")
echo "package.sh: done -> $OUT"
