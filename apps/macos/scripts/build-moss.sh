#!/bin/bash
# build-moss.sh <output file> - build the moss-transcribe engine (MIT) from a pinned commit, as one
# file: ggml linked in and the Metal shaders embedded. MOSS-Transcribe-Diarize runs on it.
set -euo pipefail
OUTPUT="$1"
REPO="https://github.com/localai-org/moss-transcribe.cpp"
COMMIT="190a569c13b4b247450f2fb3b2a431244e84833e"
WORK="${TYPELEAST_MOSS_WORK:-$(dirname "$OUTPUT")/moss-transcribe-src}"
# Older cached builds used host-specific ARM instructions and are not portable.
STAMP="$OUTPUT.$COMMIT.portable-v1"
if [ -x "$OUTPUT" ] && [ -f "$STAMP" ]; then
  echo "moss   : cached $COMMIT"
  exit 0
fi
rm -rf "$WORK"
mkdir -p "$WORK" "$(dirname "$OUTPUT")"
git -C "$WORK" init -q
git -C "$WORK" fetch -q --depth 1 "$REPO" "$COMMIT"
git -C "$WORK" checkout -q FETCH_HEAD
git -C "$WORK" submodule update -q --init --depth 1
# The pinned upstream revision forces native CPU optimization, even when
# GGML_NATIVE=OFF is supplied on the command line. Patch only this checkout;
# fail closed if the expected upstream line changes.
CMAKE_FILE="$WORK/CMakeLists.txt"
NATIVE_LINE='set(GGML_NATIVE ON CACHE BOOL "" FORCE)'
if [ "$(grep -Fxc "$NATIVE_LINE" "$CMAKE_FILE")" != 1 ]; then
  echo "Unexpected upstream GGML_NATIVE setting; refusing a host-specific build." >&2
  exit 1
fi
awk '{ if ($0 == "set(GGML_NATIVE ON CACHE BOOL \"\" FORCE)") print "set(GGML_NATIVE OFF CACHE BOOL \"\" FORCE)"; else print }' \
  "$CMAKE_FILE" > "$CMAKE_FILE.tmp"
mv "$CMAKE_FILE.tmp" "$CMAKE_FILE"
cmake -S "$WORK" -B "$WORK/build" -DCMAKE_BUILD_TYPE=Release -DMT_GGML_METAL=ON -DBUILD_SHARED_LIBS=OFF \
  -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_NATIVE=OFF -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 -DCMAKE_OSX_ARCHITECTURES=arm64 >/dev/null
if ! grep -q '^GGML_NATIVE:BOOL=OFF$' "$WORK/build/CMakeCache.txt" || \
   [ ! -s "$WORK/build/compile_commands.json" ] || \
   grep -Eq -- '-mcpu=|-march=|\+sme|\+i8mm' "$WORK/build/compile_commands.json"; then
  echo "MOSS compiler settings are not portable; refusing the build." >&2
  exit 1
fi
cmake --build "$WORK/build" -j "$(sysctl -n hw.ncpu)" --target moss-transcribe-cli >/dev/null
cp "$WORK/build/moss-transcribe" "$OUTPUT"
cp "$WORK/LICENSE" "$OUTPUT.LICENSE"
rm -f "$OUTPUT".[0-9a-f]*
touch "$STAMP"
echo "moss   : built $COMMIT"
