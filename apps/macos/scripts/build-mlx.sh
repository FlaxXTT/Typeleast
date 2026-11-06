#!/bin/bash
# Build the Apple Silicon ASR worker and the matching MLX Metal library.
# The resolved Swift dependencies are pinned in MLXWorker/Package.resolved.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="$1"
WORK="${TYPELEAST_MLX_BUILD_DIR:-$(dirname "$OUTPUT")/mlx-build}"
PACKAGE="$ROOT/MLXWorker"
if [ "$(uname -m)" != arm64 ]; then
  echo "MLX speech recognition requires Apple Silicon." >&2
  exit 1
fi
if [ ! -f "$PACKAGE/Package.resolved" ]; then
  echo "Missing pinned MLXWorker/Package.resolved." >&2
  exit 1
fi
swift build --package-path "$PACKAGE" --scratch-path "$WORK" \
  --configuration release --product mlx-asr --disable-automatic-resolution
BIN_DIR="$(swift build --package-path "$PACKAGE" --scratch-path "$WORK" \
  --configuration release --show-bin-path --disable-automatic-resolution)"
BIN="$BIN_DIR/mlx-asr"
# SwiftPM places the shaders in Cmlx's resource bundle. MLX also accepts a
# colocated mlx.metallib, which is stable inside the signed application bundle.
METAL="$(find "$WORK" -path '*/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib' -print -quit)"
if [ ! -x "$BIN" ] || [ -z "$METAL" ] || [ ! -s "$METAL" ]; then
  echo "MLX worker or its Metal library is missing; install the Xcode Metal toolchain." >&2
  exit 1
fi
mkdir -p "$(dirname "$OUTPUT")"
cp "$BIN" "$OUTPUT"
cp "$METAL" "$(dirname "$OUTPUT")/mlx.metallib"
# Tokenizer and crypto dependencies can load SwiftPM resources via Bundle.module.
BUNDLES="$(dirname "$OUTPUT")/mlx-bundles"
mkdir -p "$BUNDLES"
# These are generated build outputs. Previous SwiftPM resource bundles can
# contain read-only files or directories, so replace them from fresh staging
# directories rather than overwriting individual files in place.
chmod u+w "$BUNDLES"
BUNDLE_STAGE=""
cleanup_bundle_stage() {
  if [ -n "$BUNDLE_STAGE" ] && [ -d "$BUNDLE_STAGE" ]; then
    chmod -R u+w "$BUNDLE_STAGE" 2>/dev/null || true
    rm -rf "$BUNDLE_STAGE"
  fi
}
trap cleanup_bundle_stage EXIT
for bundle in "$BIN_DIR"/*.bundle; do
  [ -d "$bundle" ] || continue
  name="$(basename "$bundle")"
  [ "$name" = "mlx-swift_Cmlx.bundle" ] && continue
  BUNDLE_STAGE="$(mktemp -d "$BUNDLES/.bundle.XXXXXXXX")"
  cp -R "$bundle" "$BUNDLE_STAGE/new"
  target="$BUNDLES/$name"
  if [ -L "$target" ]; then
    rm "$target"
  elif [ -e "$target" ]; then
    chmod -R u+w "$target"
    rm -rf "$target"
  fi
  mv "$BUNDLE_STAGE/new" "$target"
  rmdir "$BUNDLE_STAGE"
  BUNDLE_STAGE=""
done
LICENSES="$(dirname "$OUTPUT")/mlx-licenses"
mkdir -p "$LICENSES"
chmod u+w "$LICENSES"
for checkout in "$WORK"/checkouts/*; do
  [ -d "$checkout" ] || continue
  name="$(basename "$checkout")"
  for file in LICENSE LICENSE.txt LICENSE.md NOTICE NOTICE.txt; do
    # SwiftPM checkouts are read-only. install replaces a previous read-only
    # output and gives our generated copy a writable, predictable mode.
    [ ! -f "$checkout/$file" ] || install -m 644 "$checkout/$file" "$LICENSES/$name-$file"
  done
done
for component in mlx mlx-c fmt json metal-cpp; do
  for file in "$WORK/checkouts/mlx-swift/Source/Cmlx/$component"/LICENSE*; do
    [ ! -f "$file" ] || install -m 644 "$file" "$LICENSES/mlx-$component-$(basename "$file")"
  done
done
test -f "$LICENSES/mlx-audio-swift-LICENSE"
test -f "$LICENSES/mlx-swift-LICENSE"
codesign --force --sign - --timestamp=none --options runtime "$OUTPUT"
