#!/bin/bash
# These names are an update safety boundary for older macOS clients.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/package-names.sh"
for version in 1.25.0 2.0.0 9.99.123; do
  zip="$(typeleast_macos_zip_name "$version" AppleSilicon)"
  legacy="$(typeleast_macos_legacy_zip_name "$version" AppleSilicon)"
  dmg="$(typeleast_macos_dmg_name "$version" AppleSilicon)"
  [ "$zip" = "TypeLeast-$version-macOS14-AppleSilicon.zip" ]
  [ "$legacy" = "TypeLeast-$version-macOS-AppleSilicon.zip" ]
  [ "$zip" != "$legacy" ]
  [ "$dmg" = "TypeLeast-$version-macOS-AppleSilicon.dmg" ]
done

# A pre-existing output must never be overwritten or uploaded accidentally.
# The guard runs before the build, so this test does not package or hash files.
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Info.plist")"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/typeleast-package-names.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
for name in "$(typeleast_macos_legacy_zip_name "$version" AppleSilicon)" \
            "$(typeleast_macos_zip_name "$version" AppleSilicon)" \
            "$(typeleast_macos_dmg_name "$version" AppleSilicon)"; do
  printf 'pre-existing file\n' > "$tmp/$name"
  if "$ROOT/package.sh" arm64 "$tmp" > /dev/null 2>&1; then
    echo "FAIL: packaging accepted an existing output: $name" >&2
    exit 1
  fi
  [ "$(cat "$tmp/$name")" = 'pre-existing file' ] || { echo "FAIL: pre-existing output changed" >&2; exit 1; }
  rm "$tmp/$name"
done
mkdir -p "$tmp/build/package-arm64/output"
printf 'pre-existing file\n' > "$tmp/build/package-arm64/output/keep.txt"
if TYPELEAST_BUILD_DIR="$tmp/build" "$ROOT/package.sh" arm64 "$tmp/build/package-arm64/output" > /dev/null 2>&1; then
  echo 'FAIL: packaging accepted an output inside its temporary directory' >&2
  exit 1
fi
[ "$(cat "$tmp/build/package-arm64/output/keep.txt")" = 'pre-existing file' ] || { echo 'FAIL: nested output was changed' >&2; exit 1; }
echo "PASS: new and legacy ZIP names differ; DMG names stay unchanged"
