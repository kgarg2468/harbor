#!/bin/bash
set -euo pipefail
# Engines proof (design section 2, "Node.js"): the locked nodejs_version must
# satisfy the locked t3_engines_node, which is T3's own engines.node range copied
# verbatim, so Harbor never hard-codes that range in code. The check itself is
# harbor_versions_require_node_range, so the static lane proves the same
# implementation the unit lane drives. A failure exits 3 naming both values.
# Usage: fleet/tests/lint/engines_check.sh [LOCK_FILE]
# With no argument the lock is the one beside the libraries this script sources.
root="$(cd "$(dirname "${0}")/../.." && pwd -P)"
lock="${1:-${root}/versions.lock}"
# shellcheck source=lib/log.sh
. "${root}/lib/log.sh"
# shellcheck source=lib/versions.sh
. "${root}/lib/versions.sh"
harbor_versions_require_node_range "${lock}"
printf '%s: nodejs_version %s satisfies t3_engines_node %s\n' \
  "${lock}" "$(harbor_version_get nodejs_version)" "$(harbor_version_get t3_engines_node)"
# Install-method agreement (design section 2): the three home-prefix runtimes record
# their method as npm:<package>@<version>, and the version a method names has to be the
# version pinned beside it. A lock edit that moved one and not the other would install
# a version every record then calls something else, and the drift would not surface
# until a provision run on a real node. This lane has no network, so it proves the
# agreement of the file with itself; the vendor-smoke lane proves the file against the
# registry.
harbor_engines_check_install() {
  local version_key="${1}" install_key="${2}" version install
  version="$(harbor_version_require "${version_key}")" || exit "$?"
  install="$(harbor_version_require "${install_key}")" || exit "$?"
  case "${install}" in
    npm:*@*) ;;
    *) harbor_die 3 versions.install_form "${lock}: ${install_key} is '${install}', which is not the npm:<package>@<version> form design section 2 records a method in" ;;
  esac
  [ "${install##*@}" = "${version}" ] \
    || harbor_die 3 versions.install_version "${lock}: ${install_key} names version ${install##*@} and ${version_key} pins ${version}; a method installs the version pinned beside it, so one of the two is wrong"
  printf '%s: %s names the %s it pins, %s\n' "${lock}" "${install_key}" "${version_key}" "${version}"
}
harbor_engines_check_install claude_code_version claude_code_install
harbor_engines_check_install codex_version codex_install
harbor_engines_check_install t3_version t3_install
