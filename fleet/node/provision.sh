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
# Before lib/t3.sh, which is not self-contained: harbor_t3_runtime_port reads the
# runtime state's optional host through harbor_serve_loopback_host, so a provision
# run that sourced t3.sh alone would die on an unbound command the first time a
# caller asked for the port. bin/harbor orders these the same way.
# shellcheck source=../lib/serve.sh
. "${HARBOR_ROOT}/lib/serve.sh"
# shellcheck source=../lib/t3.sh
. "${HARBOR_ROOT}/lib/t3.sh"
# shellcheck source=../lib/config.sh
. "${HARBOR_ROOT}/lib/config.sh"
# shellcheck source=../lib/access.sh
. "${HARBOR_ROOT}/lib/access.sh"
# shellcheck source=../lib/pair.sh
. "${HARBOR_ROOT}/lib/pair.sh"
# shellcheck source=../lib/auth.sh
. "${HARBOR_ROOT}/lib/auth.sh"
# shellcheck source=../lib/apt.sh
. "${HARBOR_ROOT}/lib/apt.sh"
# shellcheck source=../lib/state.sh
. "${HARBOR_ROOT}/lib/state.sh"

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
  # 8. Recovery may finish an interrupted transaction, but an undecidable entry still
  # stops the run before any new row. The readers it calls need the home belonging to
  # this operator rather than a value inherited from an earlier command's environment,
  # and harbor_state_root_for_principal bound HARBOR_AGENTS_HOME at step 5 beside the
  # state root it is derived from -- every operator command runs this scan, so binding
  # it here as well would be a second place to keep in step with the first.
  harbor_journal_recover "${HARBOR_STATE_ROOT}"
  harbor_step recovery-scan
}

# Attended rows do not stop the unattended work. Keep the same notes for the
# final summary so a later successful install cannot bury the operator's command.
harbor_provision_attended() {
  HARBOR_PROVISION_ATTENDED=1
  HARBOR_PROVISION_NOTES="${HARBOR_PROVISION_NOTES}  ${1}: ${2}
"
  harbor_msg "${1}: ${2}"
  harbor_log provision "attended: ${1}: ${2}"
}

# The SSH row probes the launcher's login shell without changing lib/t3.sh's
# already-reviewed install-time engines check. Unreadable and malformed answers
# are attended here, never a pass and never a raw shell/vendor exit status.
harbor_provision_login_shell_node() {
  local out version range
  HARBOR_PROVISION_LOGIN_NODE_WHY=""
  out="$(HOME="${1}" sh -lc 'command -v node >/dev/null && node --version' 2>/dev/null)" || {
    HARBOR_PROVISION_LOGIN_NODE_WHY="the login shell could not resolve node"
    return 1
  }
  case "${out}" in
    v*) version="${out#v}" ;;
    *)
      HARBOR_PROVISION_LOGIN_NODE_WHY="node --version did not report a recognizable version"
      return 1
      ;;
  esac
  range="$(harbor_version_require t3_engines_node)" || {
    HARBOR_PROVISION_LOGIN_NODE_WHY="the locked Node requirement could not be read"
    return 1
  }
  # The semver reader can exit 3 on malformed input. A subshell makes that a
  # failed reading for this reporting row instead of aborting provision.
  if (harbor_semver_satisfies "${version}" "${range}") >/dev/null 2>&1; then
    return 0
  fi
  HARBOR_PROVISION_LOGIN_NODE_WHY="the login shell's Node version is unrecognized or does not satisfy the locked range"
  return 1
}

harbor_provision_broken() {
  HARBOR_PROVISION_BROKEN=1
  HARBOR_PROVISION_NOTES="${HARBOR_PROVISION_NOTES:-}  ${1}: ${2}
"
  harbor_msg "${1}: broken: ${2}"
  harbor_log provision "broken: ${1}: ${2}"
}

harbor_provision_tailnet_mapping() {
  local mapping magicdns
  mapping="$(harbor_serve_mapping)"
  case "${mapping}" in
    absent)
      # Step 2: no mapping is the one pairing need. An existing mapping never is.
      access_state=needs_pairing
      harbor_provision_attended needs_pairing "run harbor pair, which publishes this node's T3 server over Tailscale Serve and mints a one-time pairing token, then rerun harbor provision"
      return 0
      ;;
    unnormalizable)
      access_state=unknown
      harbor_provision_attended tailnet.serve_unknown "this node has a Serve configuration Harbor could not reduce to a comparable HTTPS 443 mapping; inspect it with: tailscale serve status, then rerun harbor provision"
      return 0
      ;;
  esac
  magicdns="$(harbor_tailscale_magicdns)" || {
    access_state=unknown
    harbor_provision_attended tailnet.no_magicdns "this node has no MagicDNS name, so the tailnet route cannot be checked; log in with: harbor auth tailscale and confirm MagicDNS is enabled, then rerun harbor provision"
    return 0
  }
  # Keep the verdict and non-secret diagnostic together across the subshell.
  harbor_pair_environment "${HOME}" "${magicdns}"
  case "${HARBOR_PAIR_VERDICT:-unknown}" in
    pass) return 0 ;;
    broken)
      access_state=broken
      harbor_provision_broken tailnet.environment "${HARBOR_PAIR_ENVIRONMENT_WHY:-}; minting another pairing token would not change the route — inspect it with: tailscale serve status"
      return 0
      ;;
  esac
  access_state=unknown
  harbor_provision_attended tailnet.environment_unknown "${HARBOR_PAIR_ENVIRONMENT_WHY:-}; rerun harbor provision once the tailnet has settled"
}

harbor_provision_rows() {
  local mode=connect config agent status claude_auth codex_auth service_state access_state=healthy stamp snapshot
  harbor_step provision-journal-config
  harbor_journal_init "${HARBOR_STATE_ROOT}" \
    || harbor_die 2 provision.journal "could not initialize the operator journal; no provision mutation was prepared, so check the filesystem and rerun"
  config="$(harbor_config_path "${HOME}")" || exit "$?"
  # Read an existing choice before create: create writes the mode it is given,
  # and passing the default unconditionally would overwrite a refused choice.
  if [ -e "${config}" ] || [ -L "${config}" ]; then
    mode="$(harbor_config_access_mode "${HOME}")" || exit "$?"
  fi
  [ "${mode}" != tailnet ] || harbor_access_require_tailnet_supported
  harbor_config_create "${HARBOR_STATE_ROOT}" "${HOME}" "${mode}"

  harbor_step provision-runtime-install
  harbor_agents_install "${HARBOR_STATE_ROOT}" "${HOME}" claude
  harbor_agents_install "${HARBOR_STATE_ROOT}" "${HOME}" codex

  harbor_step provision-runtime-auth
  for agent in claude codex; do
    status="$(harbor_agents_auth_status "${agent}" "${HOME}")" || exit "$?"
    case "${agent}" in
      claude) claude_auth="${status}" ;;
      codex) codex_auth="${status}" ;;
    esac
    case "${status}" in
      logged-in) ;;
      unsupported)
        harbor_msg "auth_status_unsupported: ${agent}: this pinned tool has no machine-readable auth status; Harbor cannot verify its login"
        ;;
      logged-out)
        harbor_provision_attended "${agent}.needs_login" "run harbor auth ${agent}, then rerun harbor provision"
        ;;
      *)
        harbor_provision_attended "${agent}.unknown" "Harbor could not verify ${agent}'s login; run harbor auth ${agent}, then rerun harbor provision"
        ;;
    esac
  done

  harbor_step provision-t3-install
  harbor_t3_install "${HARBOR_STATE_ROOT}" "${HOME}"
  harbor_t3_require_engines "${HOME}"

  harbor_step provision-vendor-service
  harbor_t3_service_install "${HARBOR_STATE_ROOT}" "${HOME}"
  service_state="$(harbor_t3_service_status "${HOME}")" || exit "$?"

  harbor_step provision-access-mode
  mode="$(harbor_config_access_mode "${HOME}")" || exit "$?"
  case "${mode}" in
    connect)
      harbor_t3_connect_status "${HOME}"
      # Unknown anywhere wins over a partial answer. Relay failure precedes the
      # link check because an unavailable relay can itself prevent the link.
      case "${HARBOR_T3_CONNECT_DESIRED}/${HARBOR_T3_CONNECT_AUTHENTICATED}/${HARBOR_T3_CONNECT_LINKED}/${HARBOR_T3_CONNECT_RELAY}" in
        *unknown*)
          access_state=unknown
          harbor_provision_attended connect.unknown "T3 Connect status is unknown; run harbor service status and t3 connect status --json, resolve the vendor status, then rerun harbor provision"
          ;;
        true/true/true/available) ;;
        true/false/* | false/false/*)
          access_state=needs_connect_login
          harbor_provision_attended needs_connect_login "run harbor auth connect, then rerun harbor provision"
          ;;
        */missing | */unsupported)
          access_state=degraded
          harbor_provision_attended connect.degraded "vendor relayClient.status=${HARBOR_T3_CONNECT_RELAY}; run t3 connect status --json and harbor service status, resolve the vendor relay requirement, then rerun harbor provision"
          ;;
        */true/false/available)
          access_state=needs_connect_link
          harbor_provision_attended needs_connect_link "run harbor auth connect, then rerun harbor provision"
          ;;
        # Exactly one combination reaches here: authorized, linked, relay available,
        # and desired false. It is attended because the row's healthy definition
        # requires all four, and it is reported without naming harbor auth connect
        # because that command cannot change it -- harbor_t3_connect branches on
        # authenticated and linked alone, never reads desired, and answers a true:true
        # pair with "nothing to do" and exit 0. Naming it would hand the operator a
        # command that exits 0 without touching the state it was named for, which is
        # the same defect as reporting unsupported attended: attention demanded that
        # nothing can satisfy. The toggle belongs to the vendor, so the vendor is who
        # this names.
        *)
          access_state=unknown
          harbor_provision_attended connect.unknown "T3 Connect is authorized and linked on this node but its own status reports desired=false, so it is not running; Harbor ships no command that sets it and harbor auth connect does not (it reports this pair as already done); turn Connect back on with t3 itself, then rerun harbor provision"
          ;;
      esac
      ;;
    tailnet)
      harbor_access_require_tailnet_supported
      harbor_t3_connect_status "${HOME}"
      harbor_serve_status
      # Public exposure is broken even when Connect is still active or unreadable.
      case "$(harbor_serve_funnel)" in
        present)
          access_state=broken
          harbor_provision_broken tailnet.funnel "this node has a Funnel exposure, which publishes it beyond the tailnet; Harbor never creates or removes a Funnel; inspect it with: tailscale serve status and remove it with the vendor command it names"
          ;;
        *)
          case "${HARBOR_T3_CONNECT_DESIRED:-unknown}" in
            true)
              access_state=connect_still_active
              # Not "harbor access set tailnet". This row is only reachable while
              # access_mode already IS tailnet, and harbor access set returns
              # early on an unchanged mode without reverting anything, so that
              # advice sends the operator to a command that does nothing. Harbor
              # reverts a mode's own entries only while switching away from it,
              # and the entries that need reverting here belong to connect, so
              # the node has to pass through connect to unwind them.
              harbor_provision_attended tailnet.connect_active "T3 Connect is still active on this node, so two routes would claim it; Harbor reverts a mode's entries only while switching away from that mode, and this node is already on tailnet, so the connect link has to be unwound by passing through connect: run harbor access set connect, then harbor access set tailnet, which reverts the connect link on the way back, then harbor pair and harbor provision"
              ;;
            false)
              case "$(harbor_serve_funnel)" in
                none) harbor_provision_tailnet_mapping ;;
                *)
                  access_state=unknown
                  harbor_provision_attended tailnet.serve_unknown "Harbor could not read this node's Serve configuration; inspect it with: tailscale serve status, then rerun harbor provision"
                  ;;
              esac
              ;;
            *)
              access_state=unknown
              harbor_provision_attended tailnet.connect_unknown "Harbor could not determine whether Connect is still desired; inspect t3 connect status --json, then rerun harbor provision"
              ;;
          esac
          ;;
      esac
      ;;
    ssh)
      if harbor_provision_login_shell_node "${HOME}"; then
        :
      else
        access_state=needs_node
        harbor_provision_attended ssh.node "the T3 SSH launcher runs sh -lc 'command -v node && node --version' on this node and this release's check of that command failed (${HARBOR_PROVISION_LOGIN_NODE_WHY:-}); make node resolvable from the operator's login shell, then rerun harbor provision"
      fi
      ;;
  esac
  # Task 19: the State record is last, including on attended runs.
  harbor_step provision-state-record
  # This moment, unconditionally. Preserving the previous stamp is the record
  # writer's job and only for a record that is otherwise byte for byte unchanged;
  # deciding it here would carry the old stamp onto changed content as well, which
  # is what dates a rewritten record before the journal activity that caused it.
  stamp="$(harbor_utc_now)" \
    || harbor_die 2 state.timestamp "cannot read the UTC timestamp; state records were not written"
  # Observed once and written twice. The two records are two views of this one run,
  # and the command lock holds off other Harbor commands but not the node's own
  # package machinery: unattended-upgrades can move the Tailscale package between two
  # renders, a vendor updater a CLI. Two readings would leave two durable records
  # disagreeing about the same provision with both writes successful.
  snapshot="$(harbor_state_installed_lock_render)" || exit "$?"
  harbor_state_installed_lock_write "${HARBOR_STATE_ROOT}/installed.lock" "${snapshot}"
  harbor_state_provision_record "${HARBOR_STATE_ROOT}/provision.json" "${stamp}" \
    "${mode}" "${access_state}" "${service_state}" "${claude_auth}" "${codex_auth}" "${snapshot}"
}

harbor_provision_main() {
  HARBOR_PID="${HARBOR_PID:-$$}"
  HARBOR_CMDLINE="${HARBOR_CMDLINE:-harbor provision ${*:-}}"
  [ "$#" -eq 0 ] || harbor_die 3 usage "usage: harbor provision"
  harbor_provision_preflight
  HARBOR_PROVISION_BROKEN=0
  HARBOR_PROVISION_ATTENDED=0
  HARBOR_PROVISION_NOTES=""
  harbor_provision_rows
  # What this node is, not that the command finished: bootstrap's line beside the
  # same degraded block says "this node is bootstrapped" for the reason that applies
  # here too. Every row applied either way, so the sentence is true either way, and
  # an attended run must not be told "provision complete" one line above the steps
  # that are why it is about to exit 1.
  harbor_msg "provision complete; every row applied"
  # Read by the EXIT trap, which otherwise treats a zero exit as an incomplete run.
  # shellcheck disable=SC2034
  HARBOR_COMPLETED=1
  if [ "${HARBOR_PROVISION_BROKEN:-0}" = 1 ]; then
    harbor_msg "provision.broken: these rows need attention:"
    printf '%s' "${HARBOR_PROVISION_NOTES:-}" >&2
    exit 2
  fi
  [ "${HARBOR_PROVISION_ATTENDED}" = 1 ] || return 0
  harbor_msg "provision.attended: these steps still need attention:"
  printf '%s' "${HARBOR_PROVISION_NOTES}" >&2
  exit 1
}
harbor_install_traps
harbor_provision_main ${1+"$@"}
