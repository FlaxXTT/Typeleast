#!/bin/bash
# make-signing-cert.sh - create a self-signed code-signing certificate in the login
# keychain, once per Mac. build.sh signs with it, so every rebuild has the same
# signature and macOS keeps the Keychain and Accessibility permissions.
# The private key never leaves this Mac's keychain; nothing is written to the repo.
set -euo pipefail

NAME="${TYPELEAST_SIGN_IDENTITY:-TypeLeast Local Signing}"
if security find-certificate -c "$NAME" >/dev/null 2>&1; then
  echo "already there: $NAME"
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
umask 077
cat > "$WORK/cfg" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$WORK/cfg" \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
PASS="$(/usr/bin/openssl rand -hex 16)"
/usr/bin/openssl pkcs12 -export -name "$NAME" -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -out "$WORK/id.p12" -passout "pass:$PASS" 2>/dev/null
security import "$WORK/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P "$PASS" -T /usr/bin/codesign
echo "created: $NAME"
echo "The first build asks once for the login password so codesign can use the key: choose Always Allow."
