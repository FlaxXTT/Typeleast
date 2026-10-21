#!/usr/bin/env bash
# package-wine.sh - build the Windows x64 release of TypeLeast on Linux, without
# GitHub Actions. Same output as package.ps1:
#   TypeLeast-<version>-Windows-x64-Setup.exe     installer (Inno Setup under wine)
#   TypeLeast-<version>-Windows-x64-Portable.zip  unzip and run TypeLeast.exe
#   SHA256SUMS.txt
#
# Needs: .NET 8 SDK from Microsoft (the Ubuntu source-built SDK has no WPF
# targets), Node.js 22+ with npm, zip, wine, and ISCC.exe of Inno Setup 6
# installed in a wine prefix.
#
#   ISCC_EXE='C:\inno\ISCC.exe' WINEPREFIX=~/.wine apps/windows/package-wine.sh [out-dir]
#
# Differences from package.ps1, check them on Windows before publishing:
# - The Visual C++ runtime DLLs are copied only when VCRUNTIME_DIR names a folder
#   with vcruntime140.dll, vcruntime140_1.dll and msvcp140.dll from Windows.
# - The bundled service is not started (no Windows node.exe smoke test here).
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
out="${1:-$here/dist}"
node_version="${NODE_VERSION:-24.21.0}"
iscc="${ISCC_EXE:?set ISCC_EXE to the wine path of ISCC.exe, e.g. C:\\inno\\ISCC.exe}"
version="$(sed -n 's:.*<Version>\(.*\)</Version>.*:\1:p' "$here/Directory.Build.props")"
stage="$out/stage"
work="$out/work"
rm -rf "$stage" "$work"
mkdir -p "$stage" "$work" "$out"
echo "== TypeLeast $version for Windows x64, Node.js $node_version (Linux + wine) =="

# 1. The app: one self-contained TypeLeast.exe.
dotnet publish "$here/TypeLeast/TypeLeast.csproj" -c Release -r win-x64 --self-contained true \
    -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:DebugType=none -o "$stage"

# 2. The local service with its Windows dependencies (sherpa-onnx-win-x64),
#    installed in a separate folder so the repository's own node_modules stay as they are.
mkdir -p "$work/service"
cp "$root/service/package.json" "$root/service/package-lock.json" "$work/service/"
(cd "$work/service" && npm ci --omit=dev --no-audit --no-fund --os=win32 --cpu=x64)
test -f "$work/service/node_modules/sherpa-onnx-win-x64/sherpa-onnx.node"
mkdir -p "$stage/service"
cp -R "$root/service/bin" "$root/service/lib" "$work/service/node_modules" "$stage/service/"
cp "$root/service/package.json" "$stage/service/"
sherpa="$stage/service/node_modules/sherpa-onnx-win-x64"
if [ -n "${VCRUNTIME_DIR:-}" ]; then
    for dll in vcruntime140.dll vcruntime140_1.dll msvcp140.dll; do cp "$VCRUNTIME_DIR/$dll" "$sherpa/"; done
    echo "vcrt   : copied from $VCRUNTIME_DIR"
else
    echo "vcrt   : NOT bundled (set VCRUNTIME_DIR); the Visual C++ Redistributable must be installed"
fi

# 3. Node.js, checked against nodejs.org's SHA-256 list.
zip_name="node-v$node_version-win-x64.zip"
base="https://nodejs.org/dist/v$node_version"
curl -fsSL -o "$work/$zip_name" "$base/$zip_name"
curl -fsSL -o "$work/SHASUMS256.txt" "$base/SHASUMS256.txt"
(cd "$work" && grep " $zip_name\$" SHASUMS256.txt | sha256sum -c -)
(cd "$work" && unzip -q "$zip_name")
mkdir -p "$stage/node"
cp "$work/node-v$node_version-win-x64/node.exe" "$work/node-v$node_version-win-x64/LICENSE" "$stage/node/"
cp "$root/LICENSE" "$root/THIRD-PARTY-NOTICES.md" "$stage/"

# 4. Portable zip and installer.
name="TypeLeast-$version-Windows-x64"
rm -f "$out/$name-Portable.zip" "$out/$name-Setup.exe" "$out/SHA256SUMS.txt"
(cd "$stage" && zip -qr -X "$out/$name-Portable.zip" .)
WINEDEBUG=-all wine "$iscc" /Q "/DAppVersion=$version" "/DSourceDir=$(winepath -w "$stage")" \
    "/DOutputDir=$(winepath -w "$out")" "$(winepath -w "$here/installer/TypeLeast.iss")"
test -f "$out/$name-Setup.exe"
rm -rf "$stage" "$work"
(cd "$out" && sha256sum "$name-Setup.exe" "$name-Portable.zip" > SHA256SUMS.txt && cat SHA256SUMS.txt)
echo "package-wine.sh: done -> $out"
