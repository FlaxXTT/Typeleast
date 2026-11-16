#!/bin/bash
# Remove only the temporary CI identity and trust created by the setup script.
set -euo pipefail
work="${1:-${TYPELEAST_RELEASE_SIGNING_WORK:-}}"
[ -n "$work" ] || exit 0
if [ "${CI:-}" != true ]; then echo 'Signing cleanup is restricted to CI.' >&2; exit 2; fi
[ -d "$work" ] || exit 0
work="$(cd "$work" && pwd -P)"
runner_temp="$(cd "${RUNNER_TEMP:?}" && pwd -P)"
[ "$(dirname "$work")" = "$runner_temp" ] || { echo 'Refusing to clean outside the CI temporary directory.' >&2; exit 2; }
case "$(basename "$work")" in
  typeleast-release-signing.*) ;;
  *) echo 'Refusing to clean an unrelated signing directory.' >&2; exit 2 ;;
esac
if [ -f "$work/trust-added" ] && [ -f "$work/root.pem" ]; then
  root_hash="$(/usr/bin/openssl x509 -in "$work/root.pem" -noout -fingerprint -sha1 | sed 's/^[^=]*=//; s/://g')"
  /usr/bin/sudo -n /usr/bin/security remove-trusted-cert -d "$work/root.pem" >/dev/null 2>&1 || true
  /usr/bin/sudo -n /usr/bin/security delete-certificate -Z "$root_hash" /Library/Keychains/System.keychain >/dev/null 2>&1 || true
fi
if [ -f "$work/search-list" ]; then
  previous=()
  while IFS= read -r path; do previous+=("$path"); done < "$work/search-list"
  if [ "${#previous[@]}" -gt 0 ]; then /usr/bin/security list-keychains -d user -s "${previous[@]}"; fi
fi
/usr/bin/security delete-keychain "$work/signing.keychain-db" >/dev/null 2>&1 || true
rm -rf "$work"
