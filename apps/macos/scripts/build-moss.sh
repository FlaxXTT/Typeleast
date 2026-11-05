#!/bin/bash
# build-moss.sh <output file> - build the moss-transcribe engine (MIT) from a pinned commit, as one
# file: ggml linked in and the Metal shaders embedded. MOSS-Transcribe-Diarize runs on it.
set -euo pipefail
OUTPUT="$1"
REPO="https://github.com/localai-org/moss-transcribe.cpp"
COMMIT="190a569c13b4b247450f2fb3b2a431244e84833e"
WORK="${TYPELEAST_MOSS_WORK:-$(dirname "$OUTPUT")/moss-transcribe-src}"
STAMP="$OUTPUT.$COMMIT"
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
cmake -S "$WORK" -B "$WORK/build" -DCMAKE_BUILD_TYPE=Release -DMT_GGML_METAL=ON -DBUILD_SHARED_LIBS=OFF \
  -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_NATIVE=OFF -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 -DCMAKE_OSX_ARCHITECTURES=arm64 >/dev/null
cmake --build "$WORK/build" -j "$(sysctl -n hw.ncpu)" --target moss-transcribe-cli >/dev/null
cp "$WORK/build/moss-transcribe" "$OUTPUT"
cp "$WORK/LICENSE" "$OUTPUT.LICENSE"
rm -f "$OUTPUT".[0-9a-f]*
touch "$STAMP"
echo "moss   : built $COMMIT"
