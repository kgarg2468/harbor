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
#
# The form is checked by splitting the method rather than by one glob, because a glob
# loose enough to accept a scoped name accepts too much: npm:*@* matches 'npm:@1.2.3',
# which names no package at all, and 'npm:foo@bar@1.2.3', whose trailing field agrees
# with the pin while the package it would install is something else entirely. Both of
# those would have gone through and left the version check satisfied. So the package
# and the version are separated first and each is checked for what it has to be: a
# package is non-empty and carries no interior @ beyond the one a scope starts with,
# and a version is the same bare exact spelling versions.lock uses everywhere else.
harbor_engines_check_install() {
  local version_key="${1}" install_key="${2}" version install method package named
  version="$(harbor_version_require "${version_key}")" || exit "$?"
  install="$(harbor_version_require "${install_key}")" || exit "$?"
  case "${install}" in
    npm:?*@?*) method="${install#npm:}" ;;
    *) harbor_die 3 versions.install_form "${lock}: ${install_key} is '${install}', which is not the npm:<package>@<version> form design section 2 records a method in" ;;
  esac
  package="${method%@*}"
  named="${method##*@}"
  # A scoped name is @scope/name, so exactly one @ and it is the first character.
  case "${package#@}" in
    "" | *@*) harbor_die 3 versions.install_form "${lock}: ${install_key} is '${install}', whose package part '${package}' is not a package name; design section 2 records a method as npm:<package>@<version>, with at most a leading @scope" ;;
  esac
  case "${named}" in
    [0-9]*.[0-9]*.[0-9]*) ;;
    *) harbor_die 3 versions.install_form "${lock}: ${install_key} is '${install}', whose version part '${named}' is not the bare exact version every value in ${lock} is spelled as" ;;
  esac
  case "${named}" in
    *[!0-9.]*) harbor_die 3 versions.install_form "${lock}: ${install_key} is '${install}', whose version part '${named}' carries something other than digits and dots, so it is a range or a tag rather than the exact version design section 2 requires" ;;
  esac
  [ "${named}" = "${version}" ] \
    || harbor_die 3 versions.install_version "${lock}: ${install_key} names version ${named} and ${version_key} pins ${version}; a method installs the version pinned beside it, so one of the two is wrong"
  printf '%s: %s names the %s it pins, %s\n' "${lock}" "${install_key}" "${version_key}" "${version}"
}
harbor_engines_check_install claude_code_version claude_code_install
harbor_engines_check_install codex_version codex_install
harbor_engines_check_install t3_version t3_install
