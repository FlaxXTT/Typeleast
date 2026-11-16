#!/bin/bash
# Use a disposable certificate and Keychain to verify update identity without
# consulting the user's credentials or allowing authentication UI in the probes.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/typeleast-update-identity.XXXXXX")"
KEYCHAIN="$WORK/update-test.keychain-db"
cleanup() {
  /usr/bin/security delete-keychain "$KEYCHAIN" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT
umask 077
test_password="$(/usr/bin/openssl rand -hex 24)"
identity="TypeLeast Update Test $(basename "$WORK")"
/usr/bin/security create-keychain -p "$test_password" "$KEYCHAIN"
/usr/bin/security unlock-keychain -p "$test_password" "$KEYCHAIN"
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
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 1 -config "$WORK/cert.cfg" \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
/usr/bin/openssl pkcs12 -export -name "$identity" -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -out "$WORK/id.p12" -passout "pass:$test_password" 2>/dev/null
# codesign access is limited to this disposable test key, never a real identity.
/usr/bin/security import "$WORK/id.p12" -k "$KEYCHAIN" -P "$test_password" -T /usr/bin/codesign >/dev/null
/usr/bin/security set-key-partition-list -S apple-tool:,apple: -s -k "$test_password" "$KEYCHAIN" >/dev/null

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
  /usr/bin/codesign --force --keychain "$KEYCHAIN" --sign "$identity" --timestamp=none --options runtime "$app"
done
FIRST="$WORK/v1/IdentityProbe.app"
UPDATED="$WORK/v2/IdentityProbe.app"
requirement="$(/usr/bin/codesign -d -r- "$FIRST" 2>&1 | sed -n '/^designated =>/p')"
test -n "$requirement"
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
