#!/bin/bash
# package.sh - build a self-contained TypeLeast for one kind of Mac, as .dmg and .zip.
#
#   ./package.sh arm64  [out-dir]     Apple silicon (M1 and later)
#   ./package.sh x86_64 [out-dir]     Intel
#
# The app carries everything it runs: the local service, the sherpa-onnx library
# for that architecture, and an official Node.js (checked against the SHA-256
# list nodejs.org publishes). Only the speech model (about 241 MB) is downloaded
# by the app on first use.
#
# NODE_VERSION picks the Node.js release; TYPELEAST_NODE_BINARY=<path> uses a
# local node binary instead of downloading one (for testing this script).
set -euo pipefail

ARCH="${1:?usage: package.sh arm64|x86_64 [out-dir]}"
ROOT="$(cd "$(dirname "$0")" && pwd)"
OUT="${2:-$ROOT/build/release}"
NODE_VERSION="${NODE_VERSION:-24.21.0}"
SHERPA_VERSION="1.13.8"
case "$ARCH" in
  arm64) NODE_ARCH="arm64"; SHERPA_PKG="sherpa-onnx-darwin-arm64"; LABEL="AppleSilicon" ;;
  x86_64) NODE_ARCH="x64"; SHERPA_PKG="sherpa-onnx-darwin-x64"; LABEL="Intel" ;;
  *) echo "unknown arch: $ARCH (use arm64 or x86_64)" >&2; exit 2 ;;
esac
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Info.plist")"
WORK="$ROOT/build/package-$ARCH"
rm -rf "$WORK"
mkdir -p "$WORK" "$OUT"

echo "== TypeLeast $VERSION for $LABEL ($ARCH), Node.js $NODE_VERSION =="
TYPELEAST_ARCH="$ARCH" "$ROOT/build.sh" --no-install
APP_SRC="$ROOT/build/dist.noindex/TypeLeast.app"
APP="$WORK/TypeLeast.app"
ditto "$APP_SRC" "$APP"
RES="$APP/Contents/Resources"

# The sherpa-onnx library for the target architecture (npm installed the host's).
rm -rf "$RES/service/node_modules/"sherpa-onnx-darwin-*
(cd "$WORK" && npm pack --silent "$SHERPA_PKG@$SHERPA_VERSION" >/dev/null)
mkdir -p "$RES/service/node_modules/$SHERPA_PKG"
tar -xzf "$WORK/$SHERPA_PKG-$SHERPA_VERSION.tgz" -C "$RES/service/node_modules/$SHERPA_PKG" --strip-components 1
echo "sherpa : $SHERPA_PKG $SHERPA_VERSION"

# Node.js, verified against nodejs.org's published SHA-256 list.
mkdir -p "$RES/node/bin"
if [ -n "${TYPELEAST_NODE_BINARY:-}" ]; then
  cp "$TYPELEAST_NODE_BINARY" "$RES/node/bin/node"
  echo "node   : local binary (test build)"
else
  TARBALL="node-v$NODE_VERSION-darwin-$NODE_ARCH.tar.gz"
  BASE="https://nodejs.org/dist/v$NODE_VERSION"
  curl -fsSL "$BASE/$TARBALL" -o "$WORK/$TARBALL"
  curl -fsSL "$BASE/SHASUMS256.txt" -o "$WORK/SHASUMS256.txt"
  (cd "$WORK" && grep " $TARBALL\$" SHASUMS256.txt | shasum -a 256 -c -)
  tar -xzf "$WORK/$TARBALL" -C "$WORK"
  cp "$WORK/node-v$NODE_VERSION-darwin-$NODE_ARCH/bin/node" "$RES/node/bin/node"
  cp "$WORK/node-v$NODE_VERSION-darwin-$NODE_ARCH/LICENSE" "$RES/node/LICENSE"
  echo "node   : $TARBALL (sha256 verified)"
fi
cp "$ROOT/../../THIRD-PARTY-NOTICES.md" "$RES/THIRD-PARTY-NOTICES.md"

# Re-seal the bundle. Not --deep: Node.js keeps the signature nodejs.org gave it.
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --strict "$APP"

NAME="TypeLeast-$VERSION-macOS-$LABEL"
STAGE="$WORK/dmg"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/TypeLeast.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$OUT/$NAME.dmg" "$OUT/$NAME.zip"
# hdiutil is occasionally "Resource busy" on build machines: retry a few times.
for attempt in 1 2 3 4 5; do
  if hdiutil create -quiet -volname "TypeLeast" -srcfolder "$STAGE" -ov -format UDZO "$OUT/$NAME.dmg"; then break; fi
  [ "$attempt" = 5 ] && { echo "hdiutil failed" >&2; exit 1; }
  sleep $((attempt * 3))
done
(cd "$WORK" && ditto -c -k --keepParent TypeLeast.app "$OUT/$NAME.zip")
(cd "$OUT" && shasum -a 256 "$NAME.dmg" "$NAME.zip")
echo "package.sh: done -> $OUT"
