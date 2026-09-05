#!/bin/bash
# Placeholder scan (design sections 3.8 and 7): every tracked regular file
# except those under fleet/tests/fixtures must hold no work-in-progress marker
# and no identifier outside the placeholder list. Submodule gitlinks are not
# regular files and are skipped by the -f test. Usage:
#   fleet/tests/lint/placeholder_scan.sh [REPO_ROOT]
set -euo pipefail
root="${1:-$(cd "$(dirname "${0}")/../../.." && pwd -P)}"
patterns="$(cd "$(dirname "${0}")" && pwd -P)/placeholder-patterns.txt"
cd "${root}"
list="$(mktemp)"
trap 'rm -f "${list}"' EXIT
git ls-files >"${list}"
status=0
while IFS= read -r f; do
  case "${f}" in
    fleet/tests/fixtures/*) continue ;;
  esac
  [ -f "${f}" ] || continue
  if grep -nIEH -f "${patterns}" -- "${f}"; then
    status=1
  fi
  bad="$(grep -oIE '[A-Za-z0-9-]+\.ts\.net' -- "${f}" | grep -vx 'TAILNET\.ts\.net' || true)"
  if [ -n "${bad}" ]; then
    printf '%s: MagicDNS name outside the placeholder list: %s\n' "${f}" "${bad}"
    status=1
  fi
  # @openssh.com is not an address. OpenSSH names its certificate and security-key
  # algorithms with it, ssh-ed25519-cert-v01@openssh.com and sk-ssh-ed25519@openssh.com
  # among them, and those names are protocol constants that have to be written exactly.
  # The rule is here to keep a real person's address out of a public repository, and no
  # spelling of an algorithm name is that, so they are excluded rather than the rule
  # weakened for every domain.
  bad="$(grep -oIE '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' -- "${f}" | grep -v '@example\.com$' | grep -v '@openssh\.com$' || true)"
  if [ -n "${bad}" ]; then
    printf '%s: email outside example.com: %s\n' "${f}" "${bad}"
    status=1
  fi
done <"${list}"
if [ "${status}" -ne 0 ]; then
  printf 'placeholder scan: failures above\n' >&2
fi
exit "${status}"
