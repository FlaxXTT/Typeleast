#!/bin/bash
# Import a persistent publisher identity into an ephemeral CI-only Keychain.
# Never generate a fresh publisher identity during a release.
set -euo pipefail
if [ "${CI:-}" != true ] || [ -z "${RUNNER_TEMP:-}" ] || [ -z "${GITHUB_ENV:-}" ]; then
  echo 'Release signing setup requires an isolated GitHub Actions macOS runner.' >&2
  exit 2
fi
if [ -z "${MACOS_SIGNING_CERTIFICATE_BASE64:-}" ] || [ -z "${MACOS_SIGNING_CERTIFICATE_PASSWORD:-}" ]; then
  echo 'Configure MACOS_SIGNING_CERTIFICATE_BASE64 and MACOS_SIGNING_CERTIFICATE_PASSWORD before publishing. Ad-hoc release fallback is disabled.' >&2
  exit 1
fi
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
umask 077
signing_work="$(mktemp -d "$RUNNER_TEMP/typeleast-release-signing.XXXXXXXX")"
signing_keychain="$signing_work/signing.keychain-db"
cleanup_on_failure() {
  local result=$?
  rm -f "$signing_work/identity.p12"
  if [ "$result" != 0 ]; then bash "$ROOT/scripts/cleanup-release-signing.sh" "$signing_work" || true; fi
  exit "$result"
}
trap cleanup_on_failure EXIT
printf '%s' "$MACOS_SIGNING_CERTIFICATE_BASE64" | /usr/bin/base64 --decode > "$signing_work/identity.p12"
/usr/bin/openssl pkcs12 -in "$signing_work/identity.p12" -clcerts -nokeys \
  -passin env:MACOS_SIGNING_CERTIFICATE_PASSWORD -out "$signing_work/leaf.pem" 2>/dev/null
/usr/bin/openssl x509 -in "$signing_work/leaf.pem" -checkend 0 -noout >/dev/null
identity_hash="$(/usr/bin/openssl x509 -in "$signing_work/leaf.pem" -noout -fingerprint -sha1 | sed 's/^[^=]*=//; s/://g')"
[[ "$identity_hash" =~ ^[0-9A-Fa-f]{40}$ ]] || { echo 'The signing certificate fingerprint is invalid.' >&2; exit 1; }

signing_keychain_password="$(/usr/bin/openssl rand -hex 24)"
/usr/bin/security list-keychains -d user | /usr/bin/python3 -c 'import shlex,sys; print("\n".join(shlex.split(sys.stdin.read())))' > "$signing_work/search-list"
/usr/bin/security create-keychain -p "$signing_keychain_password" "$signing_keychain"
/usr/bin/security unlock-keychain -p "$signing_keychain_password" "$signing_keychain"
/usr/bin/security set-keychain-settings -lut 21600 "$signing_keychain"
/usr/bin/security import "$signing_work/identity.p12" -k "$signing_keychain" -P "$MACOS_SIGNING_CERTIFICATE_PASSWORD" -T /usr/bin/codesign >/dev/null
/usr/bin/security set-key-partition-list -S apple-tool:,apple: -s -k "$signing_keychain_password" "$signing_keychain" >/dev/null
previous=()
while IFS= read -r path; do previous+=("$path"); done < "$signing_work/search-list"
/usr/bin/security list-keychains -d user -s "$signing_keychain" "${previous[@]}"

if ! /usr/bin/security find-identity -v -p codesigning "$signing_keychain" | grep -Fiq "$identity_hash"; then
  # A fixed private publisher CA is usable without Developer ID. Trust its root
  # only on this disposable build machine; never install trust on user Macs.
  /usr/bin/openssl pkcs12 -in "$signing_work/identity.p12" -cacerts -nokeys \
    -passin env:MACOS_SIGNING_CERTIFICATE_PASSWORD -out "$signing_work/root.pem" 2>/dev/null
  if ! /usr/bin/openssl x509 -in "$signing_work/root.pem" -noout >/dev/null 2>&1; then
    cp "$signing_work/leaf.pem" "$signing_work/root.pem"
  fi
  subject="$(/usr/bin/openssl x509 -in "$signing_work/root.pem" -noout -subject | sed 's/^[^=]*=//')"
  issuer="$(/usr/bin/openssl x509 -in "$signing_work/root.pem" -noout -issuer | sed 's/^[^=]*=//')"
  [ "$subject" = "$issuer" ] || { echo 'The publisher certificate chain is not trusted and has no self-signed root.' >&2; exit 1; }
  /usr/bin/openssl verify -CAfile "$signing_work/root.pem" "$signing_work/leaf.pem" >/dev/null
  /usr/bin/sudo -n /usr/bin/security add-trusted-cert -d -r trustRoot -p codeSign \
    -k /Library/Keychains/System.keychain "$signing_work/root.pem"
  touch "$signing_work/trust-added"
fi
/usr/bin/security find-identity -v -p codesigning "$signing_keychain" | grep -Fiq "$identity_hash" \
  || { echo 'No valid signing identity is available; publishing is stopped.' >&2; exit 1; }
printf 'TYPELEAST_SIGN_IDENTITY=%s\nTYPELEAST_RELEASE_SIGNING_WORK=%s\n' "$identity_hash" "$signing_work" >> "$GITHUB_ENV"
echo 'Persistent publisher identity imported; release packaging will preserve it.'
