#!/bin/bash
set -euo pipefail
if [ "${CI:-}" != true ] || [ "${RUNNER_ENVIRONMENT:-}" != github-hosted ]; then
  echo 'Trust cleanup requires an isolated GitHub-hosted CI runner.' >&2
  exit 2
fi
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
certificate="${1:?a temporary CI certificate is required}"
work="$(cd "$(dirname "$certificate")" && pwd -P)"
runner_temp="$(cd "${RUNNER_TEMP:?}" && pwd -P)"
case "$work" in
  "$runner_temp"/*) ;;
  *) echo 'Refusing to change trust for a certificate outside CI temporary storage.' >&2; exit 2 ;;
esac
/usr/bin/openssl x509 -in "$certificate" -outform der -out "$work/remove-ci-trust.der"
/usr/bin/swiftc -swift-version 5 "$ROOT/scripts/RemoveCITrust.swift" -o "$work/remove-ci-trust"
/usr/bin/sudo -n /usr/bin/env TYPELEAST_CI_TRUST_CLEANUP=1 "$work/remove-ci-trust" "$work/remove-ci-trust.der"
