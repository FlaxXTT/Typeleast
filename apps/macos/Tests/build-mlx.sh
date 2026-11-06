#!/bin/bash
# Verify the worker build accepts only the Metal library made by that Xcode build.
# No model, network, signing identity, or file checksum is used.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/typeleast-mlx-build-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

cat > "$TMP/bin/xcodebuild" <<'STUB'
#!/bin/bash
set -euo pipefail
derived=''
work=''
mode=''
locked=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    -resolvePackageDependencies) mode=resolve; shift ;;
    build) mode=build; shift ;;
    -derivedDataPath) derived="$2"; shift 2 ;;
    -clonedSourcePackagesDirPath) work="$2"; shift 2 ;;
    -onlyUsePackageVersionsFromResolvedFile) locked=1; shift ;;
    *) shift ;;
  esac
done
test -n "$work" && test "$locked" = 1
if [ "$mode" = resolve ]; then
  [ "${TEST_CASE:-}" != resolve-fails ] || exit 7
  mkdir -p "$work/checkouts/mlx-audio-swift" "$work/checkouts/mlx-swift"
  printf 'resolved fixture\n' > "$work/.resolved-by-test"
  printf 'public license fixture\n' > "$work/checkouts/mlx-audio-swift/LICENSE"
  printf 'public license fixture\n' > "$work/checkouts/mlx-swift/LICENSE"
  exit 0
fi
test "$mode" = build && test -n "$derived" && test -f "$work/.resolved-by-test"
case "${TEST_CASE:-}" in
  xcode-fails) exit 7 ;;
esac
product="$derived/Build/Products/Release"
mkdir -p "$product/mlx-swift_Cmlx.bundle/Contents/Resources" \
  "$product/swift-crypto_Crypto.bundle/Contents/Resources" \
  "$work/checkouts/mlx-audio-swift" "$work/checkouts/mlx-swift"
if [ "${TEST_CASE:-}" != missing-worker ]; then
  printf '#!/bin/sh\nexit 0\n' > "$product/mlx-asr"
  chmod +x "$product/mlx-asr"
fi
printf 'resource fixture\n' > "$product/swift-crypto_Crypto.bundle/Contents/Resources/fixture.txt"
case "${TEST_CASE:-}" in
  missing-metal) ;;
  empty-metal) : > "$product/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib" ;;
  *) printf 'fresh metal fixture\n' > "$product/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib" ;;
esac
STUB
cat > "$TMP/bin/codesign" <<'STUB'
#!/bin/sh
exit 0
STUB
chmod +x "$TMP/bin/xcodebuild" "$TMP/bin/codesign"
export PATH="$TMP/bin:$PATH"

WORK="$TMP/good"
TYPELEAST_MLX_BUILD_DIR="$WORK" TEST_CASE=good bash "$ROOT/scripts/build-mlx.sh" "$TMP/out/mlx-asr"
test -x "$TMP/out/mlx-asr"
test "$(cat "$TMP/out/mlx.metallib")" = 'fresh metal fixture'
test -s "$TMP/out/mlx-bundles/swift-crypto_Crypto.bundle/Contents/Resources/fixture.txt"
test -f "$TMP/out/mlx-licenses/mlx-audio-swift-LICENSE"

for test_case in missing-metal empty-metal missing-worker xcode-fails resolve-fails; do
  WORK="$TMP/$test_case"
  # The exact previously used derived-product location may contain stale files.
  mkdir -p "$WORK/xcode-derived/Build/Products/Release/mlx-swift_Cmlx.bundle/Contents/Resources"
  printf 'stale metal fixture\n' > "$WORK/xcode-derived/Build/Products/Release/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib"
  printf '#!/bin/sh\nexit 0\n' > "$WORK/xcode-derived/Build/Products/Release/mlx-asr"
  chmod +x "$WORK/xcode-derived/Build/Products/Release/mlx-asr"
  if TYPELEAST_MLX_BUILD_DIR="$WORK" TEST_CASE="$test_case" \
      bash "$ROOT/scripts/build-mlx.sh" "$TMP/$test_case-out/mlx-asr" > "$TMP/$test_case.log" 2>&1; then
    echo "FAIL: $test_case unexpectedly passed" >&2
    exit 1
  fi
  case "$test_case" in
    missing-worker) grep -q 'MLX worker is missing' "$TMP/$test_case.log" ;;
    missing-metal|empty-metal) grep -q 'MLX Metal library is missing or empty' "$TMP/$test_case.log" ;;
  esac
  test ! -e "$TMP/$test_case-out/mlx-asr"
  test -z "$(find "$WORK" -maxdepth 1 -name '.xcode-derived.*' -print -quit)"
done
echo 'PASS: Xcode products are used and stale or absent Metal libraries fail closed'
