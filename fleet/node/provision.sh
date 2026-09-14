#!/bin/bash
# Operator provision (design section 5.4): the preflight in the table's order.
# The cheap refusals precede state creation, and state creation immediately precedes
# the lock, just as harbor auth tailscale does. A root invocation therefore cannot
# leave an operator state root behind before discovering it is the wrong principal.
# No vendor login or system mutation belongs to a preflight: the refusal names the
# attended command or the root command the owner must run outside this process.
#
# The dispatcher sources this file with its arguments, because installed releases
# carry node/ files at 0644. Sourcing its own dependencies also lets the unit lane
# run it directly under /bin/bash; the script keeps the bash 3.2 subset even though
# the deployed node runs Ubuntu. The runtime observer precedes its reader owners so
# recovery can inspect installs interrupted in an earlier provision process.
set -euo pipefail
LC_ALL=C
export LC_ALL
HARBOR_ROOT="${HARBOR_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)}"
export HARBOR_ROOT
# shellcheck source=../lib/log.sh
. "${HARBOR_ROOT}/lib/log.sh"
# shellcheck source=../lib/versions.sh
. "${HARBOR_ROOT}/lib/versions.sh"
# shellcheck source=../lib/lock.sh
. "${HARBOR_ROOT}/lib/lock.sh"
# shellcheck source=../lib/journal.sh
. "${HARBOR_ROOT}/lib/journal.sh"
# shellcheck source=../lib/entrypoint.sh
. "${HARBOR_ROOT}/lib/entrypoint.sh"
# shellcheck source=../lib/runtime.sh
. "${HARBOR_ROOT}/lib/runtime.sh"
# shellcheck source=../lib/agents.sh
. "${HARBOR_ROOT}/lib/agents.sh"
# shellcheck source=../lib/t3.sh
. "${HARBOR_ROOT}/lib/t3.sh"
# shellcheck source=../lib/auth.sh
. "${HARBOR_ROOT}/lib/auth.sh"

harbor_provision_preflight() {
  local record ownership operator linger range node rc=0
  # 1. Nothing has been created, including the log. The state root is the operator's
  # own, so root is refused before even binding HOME to any recovery reader.
  [ "$(id -u)" != 0 ] \
    || harbor_die 3 provision.root "harbor provision runs unprivileged as the operator: rerun it as the operator without sudo; nothing was changed"
  harbor_step provision-principal
  # 2. Like auth, the record stand-in is only a development input after root has
  # been refused. An installed command must read bootstrap's record rather than an
  # authorization answer supplied by the account whose installation it is judging.
  record="${HARBOR_AUTH_RECORD}"
  if [ "${HARBOR_DEV:-0}" = 1 ]; then
    # HARBOR_AUTH_FIXTURE_RECORD, not a second name of provision's own: the record is
    # one file with one meaning, provision already takes its real path from the same
    # pair's HARBOR_AUTH_RECORD above, and two spellings of one override is how a test
    # that sets only one of them ends up reading /var/lib/harbor/bootstrap.json in
    # whichever command it forgot.
    record="${HARBOR_AUTH_FIXTURE_RECORD:-${record}}"
  fi
  harbor_entrypoint_check "${0}" "${record}"
  harbor_step provision-entrypoint
  # 3. A node awaiting login is attended, not broken. Unlike the later provision
  # rows, this is a gate: collecting a degraded note and continuing would allow
  # installation on a node whose required tailnet connection is not established.
  harbor_auth_backend_state || rc="$?"
  if [ "${rc}" != 0 ] || [ "${HARBOR_AUTH_BACKEND_STATE}" != Running ]; then
    ownership="$(harbor_auth_record_value "${record}" tailscale_ownership)"
    if [ "${ownership}" = harbor-installed ]; then
      harbor_die 1 needs_tailscale_login "BackendState is ${HARBOR_AUTH_BACKEND_STATE:-unknown} (status exit ${rc}); as the operator run harbor auth tailscale, then rerun harbor provision; nothing was changed"
    fi
    harbor_die 1 needs_tailscale_login "BackendState is ${HARBOR_AUTH_BACKEND_STATE:-unknown} (status exit ${rc}); ${record} records tailscale_ownership=${ownership:-unknown}, so the owner must run their own tailscale up outside Harbor, then rerun harbor provision; nothing was changed"
  fi
  harbor_step provision-backend
  # 4. The user manager has to survive the SSH session. Provision cannot grant
  # linger itself, and a missing or unreadable answer cannot prove it is enabled,
  # so both leave the same explicit root command for the owner rather than guessing.
  operator="$(id -un)" \
    || harbor_die 3 provision.operator "id -un failed, so Harbor cannot name the operator whose user manager it must inspect; nothing was changed"
  rc=0
  linger="$(loginctl show-user "${operator}" -p Linger --value 2>/dev/null)" || rc="$?"
  [ "${rc}" = 0 ] && [ "${linger}" = yes ] \
    || harbor_die 3 provision.linger "Linger is ${linger:-unknown} for ${operator} (loginctl exit ${rc}); the user manager must persist before provisioning: ask the owner to run sudo loginctl enable-linger ${operator}, then rerun harbor provision; nothing was changed"
  harbor_step provision-linger
  # 5. This is the first filesystem mutation, immediately before the command lock
  # whose directory lives here. The log opens only now so even a refused linger
  # check cannot accidentally create state through its diagnostic path.
  harbor_state_root_for_principal
  harbor_state_root_create "${HARBOR_STATE_ROOT}" operator \
    || harbor_die 2 provision.state_root "could not create ${HARBOR_STATE_ROOT} at 0700; the operator lock was not taken and no journal was written, so check the filesystem and rerun"
  [ -d "${HARBOR_STATE_ROOT}" ] \
    || harbor_die 2 provision.state_root "${HARBOR_STATE_ROOT} is still not a directory after creation; the operator lock has nowhere to live, so check the filesystem and rerun"
  harbor_log_open "${HARBOR_STATE_ROOT}/harbor.log" 0600 \
    || harbor_die 2 provision.log "could not open ${HARBOR_STATE_ROOT}/harbor.log at 0600; the state root exists but no lock was taken or journal written"
  harbor_log command provision
  harbor_step provision-state-root
  # 6. The version lock must parse before its engines value can be used. The
  # command lock then proves exclusive ownership; its library owns refusals for
  # malformed records, live holders, and gates a crashed process left behind.
  harbor_versions_load "$(harbor_versions_lock_path)"
  harbor_lock_acquire "${HARBOR_STATE_ROOT}" operator
  harbor_step provision-lock
  # 7. The login shell is the service launcher's view of Node, which can differ
  # from this process's inherited PATH. Judge that version against the locked
  # engines range, not against a hard-coded Node pin or a package not installed yet.
  range="$(harbor_version_require t3_engines_node)" || exit "$?"
  node="$(sh -lc 'node --version' 2>/dev/null)" \
    || harbor_die 3 provision.node "sh -lc 'node --version' failed; the operator's login shell must resolve Node satisfying t3_engines_node '${range}' before provisioning; no provision row ran"
  case "${node}" in
    v*) node="${node#v}" ;;
    *) harbor_die 3 provision.node "the login shell reported '${node}', not a Node version; fix its Node resolution to satisfy t3_engines_node '${range}' and rerun; no provision row ran" ;;
  esac
  harbor_semver_satisfies "${node}" "${range}" \
    || harbor_die 3 provision.node "the login shell's Node ${node} does not satisfy t3_engines_node '${range}'; fix its Node resolution and rerun; no provision row ran"
  harbor_step provision-node
  # 8. The readers need the home belonging to this operator, not a value inherited
  # from an earlier command's environment. Recovery may finish an interrupted
  # transaction, but an undecidable entry still stops the run before any new row.
  HARBOR_AGENTS_HOME="${HOME}"
  harbor_journal_recover "${HARBOR_STATE_ROOT}"
  harbor_step recovery-scan
}

harbor_provision_main() {
  HARBOR_PID="${HARBOR_PID:-$$}"
  HARBOR_CMDLINE="${HARBOR_CMDLINE:-harbor provision ${*:-}}"
  [ "$#" -eq 0 ] || harbor_die 3 usage "usage: harbor provision"
  harbor_provision_preflight
  # Task 18 begins here: Journal and config, then the remaining provision rows.
  # In particular, journal initialization belongs to that first row, not to this
  # preflight; recovery already treats an absent journal as having nothing to recover.
  harbor_msg "provision preflight complete; provision rows begin at Task 18"
  # Read by the EXIT trap, which otherwise treats a zero exit as an incomplete run.
  # shellcheck disable=SC2034
  HARBOR_COMPLETED=1
}
harbor_install_traps
harbor_provision_main ${1+"$@"}
