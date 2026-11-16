#!/bin/bash
# Use a disposable certificate and Keychain to verify update identity without
# consulting the user's credentials or allowing authentication UI in the probes.
set -euo pipefail
if [ "${CI:-}" != true ]; then
  echo 'This integration check requires an isolated macOS CI runner with passwordless sudo.' >&2
  exit 2
fi
/usr/bin/sudo -n true
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/typeleast-update-identity.XXXXXX")"
cleanup() {
  if [ -n "${signing_work:-}" ]; then
    bash "$ROOT/scripts/cleanup-release-signing.sh" "$signing_work" || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT
umask 077
test_password="$(/usr/bin/openssl rand -hex 24)"
identity="TypeLeast Update Test $(basename "$WORK")"
echo 'Preparing a disposable publisher certificate chain'
cat > "$WORK/root.cfg" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $identity Root
[ext]
basicConstraints = critical,CA:true
keyUsage = critical,keyCertSign,cRLSign
EOF
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 1 -config "$WORK/root.cfg" \
  -keyout "$WORK/root-key.pem" -out "$WORK/root.pem" 2>/dev/null
cat > "$WORK/cert.cfg" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $identity
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF
/usr/bin/openssl req -new -newkey rsa:2048 -nodes -config "$WORK/cert.cfg" \
  -keyout "$WORK/key.pem" -out "$WORK/cert.csr" 2>/dev/null
/usr/bin/openssl x509 -req -days 1 -in "$WORK/cert.csr" -CA "$WORK/root.pem" -CAkey "$WORK/root-key.pem" \
  -CAcreateserial -extfile "$WORK/cert.cfg" -extensions ext -out "$WORK/cert.pem" 2>/dev/null
/usr/bin/openssl pkcs12 -export -name "$identity" -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -certfile "$WORK/root.pem" -out "$WORK/id.p12" -passout "pass:$test_password" 2>/dev/null
echo 'Testing the production release-signing setup with disposable material'
MACOS_SIGNING_CERTIFICATE_BASE64="$(/usr/bin/base64 < "$WORK/id.p12")" \
MACOS_SIGNING_CERTIFICATE_PASSWORD="$test_password" GITHUB_ENV="$WORK/signing-env" \
  bash "$ROOT/scripts/setup-release-signing.sh"
signing_hash="$(sed -n 's/^TYPELEAST_SIGN_IDENTITY=//p' "$WORK/signing-env")"
signing_work="$(sed -n 's/^TYPELEAST_RELEASE_SIGNING_WORK=//p' "$WORK/signing-env")"
KEYCHAIN="$signing_work/signing.keychain-db"
root_hash="$(/usr/bin/openssl x509 -in "$WORK/root.pem" -noout -fingerprint -sha1 | sed 's/^[^=]*=//; s/://g')"
test "${#signing_hash}" = 40

cat > "$WORK/main.swift" <<'SWIFT'
import Foundation
import Security
import LocalAuthentication

#if FIRST_RELEASE
let build = "first"
#else
let build = "updated"
#endif
let args = CommandLine.arguments
guard args.count >= 3 else { exit(2) }
let mode = args[1]
// An attempted dialog must fail this process's operation, never wait for input.
guard SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else { exit(3) }
if mode == "verify" || mode == "verify-denied" {
    guard args.count == 5 else { exit(2) }
    let problem = SelfIntegrity.problem(bundleURL: URL(fileURLWithPath: args[3]), matching: args[4])
    guard (problem == nil) == (mode == "verify") else {
        print("FAIL signature validation: \(problem ?? "unexpectedly accepted")")
        exit(1)
    }
} else {
    var keychain: SecKeychain?
    guard SecKeychainOpen(args[2], &keychain) == errSecSuccess, let keychain else { exit(3) }
    let context = LAContext()
    context.interactionNotAllowed = true
    var query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "TypeLeast.update-identity-test",
        kSecAttrAccount as String: "fixture",
        kSecUseAuthenticationContext as String: context,
    ]
    let fixture = Data("disposable-test-value".utf8)
    if mode == "write" {
        query[kSecUseKeychain as String] = keychain
        query[kSecValueData as String] = fixture
        guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else { exit(1) }
    } else {
        query[kSecMatchSearchList as String] = [keychain]
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var found: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &found)
        if mode == "read" {
            guard status == errSecSuccess, found as? Data == fixture else {
                print("FAIL same-certificate silent read: \(status)")
                exit(1)
            }
        } else if mode == "read-denied" {
            guard [errSecInteractionNotAllowed, errSecAuthFailed].contains(status) else {
                print("FAIL changed identity was not denied as expected: \(status)")
                exit(1)
            }
        } else { exit(2) }
    }
}
print("PASS \(build) \(mode)")
SWIFT

for version in 1 2; do
  echo "Compiling and signing disposable version $version"
  app="$WORK/v$version/IdentityProbe.app"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
  cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.typeleast.update-identity-test</string>
<key>CFBundleExecutable</key><string>IdentityProbe</string>
<key>CFBundleVersion</key><string>$version</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
EOF
  compile_flags=()
  if [ "$version" = 1 ]; then compile_flags=(-D FIRST_RELEASE); fi
  /usr/bin/swiftc -swift-version 5 "${compile_flags[@]}" "$ROOT/Sources/SelfIntegrity.swift" "$WORK/main.swift" \
    -o "$app/Contents/MacOS/IdentityProbe"
  /usr/bin/codesign --force --keychain "$KEYCHAIN" --sign "$signing_hash" --timestamp=none --options runtime "$app"
done
echo 'Removing build-time root trust before running the credential probes'
/usr/bin/sudo -n /usr/bin/security remove-trusted-cert -d "$WORK/root.pem"
/usr/bin/sudo -n /usr/bin/security delete-certificate -Z "$root_hash" /Library/Keychains/System.keychain
FIRST="$WORK/v1/IdentityProbe.app"
UPDATED="$WORK/v2/IdentityProbe.app"
requirement="$(/usr/bin/codesign -d -r- "$FIRST" 2>&1 | sed -n '/^designated =>/p')"
test -n "$requirement"
echo 'Testing stable identity, denied changed identity, and sealed-resource integrity'
"$FIRST/Contents/MacOS/IdentityProbe" write "$KEYCHAIN"
"$UPDATED/Contents/MacOS/IdentityProbe" read "$KEYCHAIN"
"$FIRST/Contents/MacOS/IdentityProbe" verify "$KEYCHAIN" "$UPDATED" "$requirement"

# Changing the signing identity must not inherit the saved item's access.
CHANGED="$WORK/changed/IdentityProbe.app"
mkdir -p "$(dirname "$CHANGED")"
/usr/bin/ditto "$UPDATED" "$CHANGED"
/usr/bin/codesign --force --sign - --timestamp=none --options runtime "$CHANGED"
"$CHANGED/Contents/MacOS/IdentityProbe" read-denied "$KEYCHAIN"
"$FIRST/Contents/MacOS/IdentityProbe" verify-denied "$KEYCHAIN" "$CHANGED" "$requirement"

# A matching requirement string cannot make altered sealed resources valid.
printf 'unsigned resource\n' > "$UPDATED/Contents/Resources/changed.txt"
"$FIRST/Contents/MacOS/IdentityProbe" verify-denied "$KEYCHAIN" "$UPDATED" "$requirement"
echo 'PASS: same-certificate updates preserve silent Keychain access; changed identities and resources are rejected'
