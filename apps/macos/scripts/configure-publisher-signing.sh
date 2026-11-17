#!/bin/bash
# One-time owner-side setup. Keep the private directory outside every checkout.
# This uses files and GitHub Secrets, not the Mac login Keychain or sudo.
set -euo pipefail
set +x
repository="${1:?usage: configure-publisher-signing.sh owner/repo private-directory}"
private_directory="${2:?a durable private directory outside the repository is required}"
[[ "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo 'Invalid repository name.' >&2; exit 2; }
for executable in gh openssl git; do command -v "$executable" >/dev/null || { echo "$executable is required." >&2; exit 2; }; done

# Check access before creating material. Never overwrite an existing publisher.
existing="$(gh secret list --repo "$repository" --json name --jq '[.[] | select(.name == "MACOS_SIGNING_CERTIFICATE_BASE64" or .name == "MACOS_SIGNING_CERTIFICATE_PASSWORD") | .name] | length')"
[ "$existing" = 0 ] || { echo 'Signing secrets already exist. Refusing to rotate or overwrite the publishing identity.' >&2; exit 1; }
umask 077
mkdir -p "$private_directory"
private_directory="$(cd "$private_directory" && pwd -P)"
if git -C "$private_directory" rev-parse --show-toplevel >/dev/null 2>&1; then
  echo 'The private signing directory must be outside Git repositories.' >&2
  exit 2
fi
if [ -e "$private_directory/identity.p12" ] || [ -e "$private_directory/password" ]; then
  for file in identity.p12 password root-key.enc.pem root.pem certificate.pem repository; do
    [ -f "$private_directory/$file" ] || { echo 'A partial identity exists. Preserve it and repair the setup before retrying.' >&2; exit 1; }
  done
  [ "$(cat "$private_directory/repository")" = "$repository" ] || { echo 'This identity belongs to a different repository.' >&2; exit 1; }
  chmod 700 "$private_directory"
else
  if [ -n "$(find "$private_directory" -mindepth 1 -maxdepth 1 -print -quit)" ]; then
    echo 'Use an empty private directory; existing files will not be overwritten.' >&2
    exit 1
  fi
  chmod 700 "$private_directory"
  printf '%s' "$repository" > "$private_directory/repository"
  signing_password="$(openssl rand -hex 32)"
  printf '%s' "$signing_password" > "$private_directory/password"
  cat > "$private_directory/root.cfg" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = TypeLeast Publisher Root ($repository)
[ext]
basicConstraints = critical,CA:true
keyUsage = critical,keyCertSign,cRLSign
EOF
  cat > "$private_directory/leaf.cfg" <<EOF
[req]
distinguished_name = dn
prompt = no
[dn]
CN = TypeLeast Publisher Signing ($repository)
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF
  openssl req -x509 -newkey rsa:3072 -sha256 -days 7300 -config "$private_directory/root.cfg" \
    -passout "file:$private_directory/password" -keyout "$private_directory/root-key.enc.pem" \
    -out "$private_directory/root.pem" 2>/dev/null
  openssl req -new -newkey rsa:3072 -sha256 -nodes -config "$private_directory/leaf.cfg" \
    -keyout "$private_directory/leaf-key.pem" -out "$private_directory/leaf.csr" 2>/dev/null
  openssl x509 -req -sha256 -days 3650 -in "$private_directory/leaf.csr" \
    -CA "$private_directory/root.pem" -CAkey "$private_directory/root-key.enc.pem" \
    -passin "file:$private_directory/password" -CAcreateserial -extfile "$private_directory/leaf.cfg" \
    -extensions ext -out "$private_directory/certificate.pem" 2>/dev/null
  # The legacy PKCS#12 wrapping is supported by macOS Security; GitHub Secrets
  # additionally encrypts the payload in transit and at rest.
  openssl pkcs12 -export -name 'TypeLeast Publisher Signing' -inkey "$private_directory/leaf-key.pem" \
    -in "$private_directory/certificate.pem" -certfile "$private_directory/root.pem" \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
    -passout "file:$private_directory/password" -out "$private_directory/identity.p12" 2>/dev/null
  rm -f "$private_directory/leaf-key.pem" "$private_directory/leaf.csr"
fi
openssl base64 -A -in "$private_directory/identity.p12" -out "$private_directory/identity.p12.base64"
gh secret set MACOS_SIGNING_CERTIFICATE_BASE64 --repo "$repository" < "$private_directory/identity.p12.base64"
gh secret set MACOS_SIGNING_CERTIFICATE_PASSWORD --repo "$repository" < "$private_directory/password"
echo 'Persistent publisher signing secrets configured. No release was published.'
echo 'Keep the protected private directory and an offline backup; do not upload it to Git or chat.'
openssl x509 -in "$private_directory/certificate.pem" -noout -subject -issuer -dates
