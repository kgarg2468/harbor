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
