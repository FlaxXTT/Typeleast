#!/bin/bash
# Remove only the temporary CI identity and trust created by the setup script.
set -euo pipefail
work="${1:-${TYPELEAST_RELEASE_SIGNING_WORK:-}}"
[ -n "$work" ] || exit 0
if [ "${CI:-}" != true ] || [ "${RUNNER_ENVIRONMENT:-}" != github-hosted ]; then echo 'Signing cleanup is restricted to isolated GitHub-hosted CI.' >&2; exit 2; fi
[ -d "$work" ] || exit 0
work="$(cd "$work" && pwd -P)"
runner_temp="$(cd "${RUNNER_TEMP:?}" && pwd -P)"
[ "$(dirname "$work")" = "$runner_temp" ] || { echo 'Refusing to clean outside the CI temporary directory.' >&2; exit 2; }
case "$(basename "$work")" in
  typeleast-release-signing.*) ;;
  *) echo 'Refusing to clean an unrelated signing directory.' >&2; exit 2 ;;
esac
trust_status=0
if [ -f "$work/trust-added" ] && [ -f "$work/root.pem" ]; then
  echo 'Removing the temporary CI signing root trust'
  ROOT="$(cd "$(dirname "$0")/.." && pwd)"
  bash "$ROOT/scripts/remove-ci-trust.sh" "$work/root.pem" || trust_status=$?
  # The public certificate may remain in this disposable CI VM until teardown.
  # It contains no private key. Any teardown failure stops release publishing.
fi
if [ -f "$work/search-list" ]; then
  previous=()
  while IFS= read -r path; do previous+=("$path"); done < "$work/search-list"
  if [ "${previous[0]+present}" = present ]; then /usr/bin/security list-keychains -d user -s "${previous[@]}"; fi
fi
echo 'Removing the temporary CI signing Keychain'
/usr/bin/security delete-keychain "$work/signing.keychain-db" >/dev/null 2>&1 || true
rm -rf "$work"
exit "$trust_status"
