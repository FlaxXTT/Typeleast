#!/bin/bash
# One-command owner-side setup; private material stays on the owner's Mac.
set -euo pipefail
set +x
[ "$(uname -s)" = Darwin ] || { echo 'Run this script in Terminal on your own Mac.' >&2; exit 2; }
for executable in curl shasum unzip openssl git; do
  command -v "$executable" >/dev/null || { echo "$executable is required." >&2; exit 2; }
done
umask 077
work="$(mktemp -d "${TMPDIR:-/tmp}/typeleast-publisher-setup.XXXXXX")"
trap 'rm -rf "$work"' EXIT

if ! command -v gh >/dev/null || ! gh --version >/dev/null 2>&1; then
  cli_version=2.104.0
  case "$(uname -m)" in
    arm64)
      cli_arch=arm64
      cli_sha=23b12706219b9892e44236f988444a24adcf29284e16b35e03ba5b863fb6eb8e ;;
    x86_64)
      cli_arch=amd64
      cli_sha=a8c2a708dbae89dc7c05ba7b0beafc95bd8d09ab4a3505467b77d32ebf364dc6 ;;
    *) echo 'Unsupported Mac architecture.' >&2; exit 2 ;;
  esac
  tools="${TYPELEAST_SIGNING_TOOLS_DIR:-$HOME/.local/share/typeleast-signing-tools}"
  installation="$tools/gh-$cli_version-$cli_arch"
  if [ ! -x "$installation/bin/gh" ]; then
    [ ! -e "$installation" ] || { echo 'An incomplete CLI installation exists; preserve it and repair the setup before retrying.' >&2; exit 1; }
    archive="gh_${cli_version}_macOS_${cli_arch}.zip"
    echo 'Downloading GitHub CLI from its official release; no Homebrew or administrator access is needed.'
    curl -fsSL --retry 2 --connect-timeout 20 --max-time 180 \
      "https://github.com/cli/cli/releases/download/v$cli_version/$archive" -o "$work/$archive"
    (cd "$work" && printf '%s  %s\n' "$cli_sha" "$archive" | shasum -a 256 -c -)
    unzip -q "$work/$archive" -d "$work/extracted"
    test -x "$work/extracted/gh_${cli_version}_macOS_${cli_arch}/bin/gh"
    mkdir -p "$tools"
    chmod 700 "$tools"
    mv "$work/extracted/gh_${cli_version}_macOS_${cli_arch}" "$installation"
  fi
  export PATH="$installation/bin:$PATH"
fi

if ! gh auth status --hostname github.com >/dev/null 2>&1; then
  echo 'Sign in to your repository-owner account in your own browser. Keep sign-in codes and credentials out of chat.'
  gh auth login --hostname github.com --web --git-protocol https
fi

helper_commit=d283d868aa92824e8d1ae2ffdd3d1c68bcb3b642
helper_sha=d701aa613a5d95039b72ab51f325f99a39fc27f34256e94b9ad803fe168121cb
curl -fsSL --retry 2 --connect-timeout 20 --max-time 60 \
  "https://raw.githubusercontent.com/FlaxXTT/Typeleast/$helper_commit/apps/macos/scripts/configure-publisher-signing.sh" \
  -o "$work/configure.sh"
(cd "$work" && printf '%s  configure.sh\n' "$helper_sha" | shasum -a 256 -c -)
bash "$work/configure.sh" FlaxXTT/Typeleast \
  "${TYPELEAST_SIGNING_BACKUP_DIR:-$HOME/.local/share/typeleast-publisher-signing}"
echo 'Signing configuration is complete. Tell Codex: 配置完成. Release validation and publishing can continue.'
