#!/bin/bash
# Access mode support, reversion, and operator commands.
# harbor_access_probe_path: the recorded Revalidation A result. Under the release
# root, so an installed release carries the value it was tested at rather than
# reading whatever a checkout on the node happens to say.
harbor_access_probe_path() {
  printf '%s/vendor-smoke/tailnet-environment.probe' "${HARBOR_ROOT:-}"
}
# harbor_access_tailnet_supported: 0 only when the recorded probe says supported.
# Fails closed on a missing, unreadable, or unrecognized file: section 5.5 makes
# an unverified tailnet an explicit exit 3 gate, never a silently accepted mode.
harbor_access_tailnet_supported() {
  local file result
  file="$(harbor_access_probe_path)"
  [ -f "${file}" ] && [ -r "${file}" ] || return 1
  result="$(sed -n 's/^result=//p' "${file}" | sed -n 1p)"
  [ "${result}" = supported ] || return 1
  return 0
}
harbor_access_require_tailnet_supported() {
  harbor_access_tailnet_supported \
    || harbor_die 3 access.tailnet_unverified "tailnet mode is implemented but not enabled on this release: whether a node can fetch its own Serve descriptor through its MagicDNS name has not been verified on the pinned tailscale and t3 versions, and design section 5.5 makes an unverified tailnet an explicit refusal rather than a mode Harbor accepts and cannot check; the recorded result is in vendor-smoke/tailnet-environment.probe and the procedure that fills it in is in the PR 5 body; use: harbor access set connect, or harbor access set ssh; nothing was changed"
}

# harbor_access_mode_ops MODE: the journal ops a mode's setup creates. ssh journals
# nothing on the node -- section 5.5: "nothing on the node beyond bootstrap and the
# vendor service" -- and an empty answer is the honest one, not an omission.
harbor_access_mode_ops() {
  case "${1}" in
    connect) printf 't3-connect-link' ;;
    tailnet) printf 'tailscale-serve' ;;
    ssh) ;;
  esac
}

# harbor_access_revert STATE_ROOT MODE: run each of MODE's applied entries' own
# inverse and mark it reverted. Returns 1 when any entry was reported rather than
# reverted, so the caller can report attended work rather than claim a clean switch.
#
# Three rules, and they are the whole of section 6.1 in this context. An observed
# entry is never reverted: Harbor did not create that state and does not remove it.
# A created entry is reverted only when the world still equals its post_state:
# anything else has been touched since, and unwinding it would unwind someone
# else's change. Newest first, so dependent mutations unwind in the order made.
harbor_access_revert() {
  local root="${1}" mode="${2}" ops entry base seq op ownership phase post observed entries attended=0
  ops="$(harbor_access_mode_ops "${mode}")"
  [ -n "${ops}" ] || return 0
  entries="$(harbor_access_entries_newest_first "${root}")" \
    || harbor_die 2 access.entries "could not read the journal; the new mode was not configured"
  [ -n "${entries}" ] || return 0
  while IFS= read -r entry; do
    op="$(harbor_journal_string "${entry}" op)"
    case " ${ops} " in
      *" ${op} "*) ;;
      *) continue ;;
    esac
    phase="$(harbor_journal_string "${entry}" phase)"
    [ "${phase}" = applied ] || continue
    base="$(basename "${entry}")"
    seq="${base%%-*}"
    ownership="$(harbor_journal_string "${entry}" ownership)"
    if [ "${ownership}" != created ]; then
      harbor_msg "access: ${base} records a ${op} Harbor did not create, so it is left exactly as it is; remove it yourself if it is yours"
      continue
    fi
    post="$(harbor_journal_raw "${entry}" post_state)"
    observed="$(harbor_journal_observe "${op}" "$(harbor_journal_string "${entry}" target)")" || harbor_die 2 access.observe_failed "could not inspect ${base}; the entry was not reverted and the new mode was not configured"
    if [ "${observed}" != "${post}" ]; then
      harbor_msg "access: ${base} records a ${op} whose state has changed since Harbor created it, so Harbor will not undo it; inspect it and, when you have decided, resolve the entry with: harbor journal resolve ${seq} --reverted"
      attended=1
      continue
    fi
    harbor_access_inverse "${op}" || harbor_die 2 access.revert_failed "the inverse of ${op} recorded in ${base} failed, so the previous mode is only partly undone and the new mode was not configured; the vendor's output above says why; rerun the intended harbor access set command to retry the switch"
    harbor_journal_set_phase "${entry}" reverted \
      || harbor_die 2 access.revert_record "the inverse succeeded but ${base} could not be marked reverted; inspect the journal before retrying"
    harbor_log access "${base} reverted (${op})"
  done <<EOF
${entries}
EOF
  [ "${attended}" = 0 ]
}

# harbor_access_inverse OP: the vendor's own documented inverse. Both measured:
# disableTailscaleServe in the pinned t3 runs `tailscale serve --https=443 off`,
# and section 3.3's table names `t3 connect unlink`. Harbor never invents one.
harbor_access_inverse() {
  case "${1}" in
    tailscale-serve) tailscale serve --https=443 off ;;
    t3-connect-link) harbor_t3_run "${HARBOR_AGENTS_HOME:-}" connect unlink ;;
    *) return 1 ;;
  esac
}

# harbor_access_entries_newest_first STATE_ROOT: the journal's entry paths, highest
# sequence first. A separate function because a case statement inside $( ) is a
# bash 3.2 parse error (Correction 26) and the loop above needs the list in one.
harbor_access_entries_newest_first() {
  find "${1}/journal" -maxdepth 1 -type f -name '[0-9][0-9][0-9][0-9]-*.json' \
    | LC_ALL=C sort -r
}

# harbor_access_cmd get|set MODE: the access mode as a command (section 3.3).
harbor_access_cmd() {
  local verb="${1:-}" mode="${2:-}" home root current
  harbor_auth_refuse_root
  home="${HOME}"
  case "${verb}" in
    get)
      [ "$#" -eq 1 ] || harbor_die 3 usage "usage: harbor access get"
      harbor_config_access_mode "${home}" || exit "$?"
      printf '\n'
      return 0
      ;;
    set)
      [ "$#" -eq 2 ] || harbor_die 3 usage "usage: harbor access set <connect|tailnet|ssh>"
      ;;
    *) harbor_die 3 usage "usage: harbor access <get|set <connect|tailnet|ssh>>" ;;
  esac
  # Validated before anything is locked or read, so a typo costs nothing.
  harbor_config_validate_mode "$(harbor_config_path "${home}")" "${mode}"
  [ "${mode}" != tailnet ] || harbor_access_require_tailnet_supported
  harbor_state_root_for_principal
  root="${HARBOR_STATE_ROOT}"
  harbor_state_root_create "${root}" operator \
    || harbor_die 2 access.state_root "could not create the operator state root; configuration was not changed"
  harbor_log_open "${root}/harbor.log" 0600 \
    || harbor_die 2 access.log "could not open the operator log; configuration was not changed"
  harbor_log command "access set ${mode}"
  harbor_lock_acquire "${root}" operator
  harbor_journal_init "${root}" \
    || harbor_die 2 access.journal "could not initialize the operator journal; configuration was not changed"
  # shellcheck disable=SC2034
  HARBOR_AGENTS_HOME="${home}"
  harbor_versions_load "$(harbor_versions_lock_path)"
  harbor_journal_recover "${root}" \
    || harbor_die 2 access.recovery "journal recovery failed; configuration was not changed"
  harbor_step recovery-scan
  current="$(harbor_config_access_mode "${home}")" || exit "$?"
  if [ "${current}" = "${mode}" ]; then
    harbor_msg "access: this node's access_mode is already ${mode}; nothing was reverted, rewritten, or journaled"
    return 0
  fi
  # Revert first, and write the config only if it succeeded. The other order would
  # leave a node whose config names a mode whose setup never happened, on top of a
  # previous mode whose entries still claim to be applied -- two wrong answers
  # where failing here leaves exactly one state, the one the node was already in.
  harbor_access_revert "${root}" "${current}" || harbor_msg "access: the previous mode left attended work, listed above; it does not block the switch"
  harbor_config_create "${root}" "${home}" "${mode}"
  harbor_access_report_next "${mode}" "${home}"
}

# harbor_access_report_next MODE HOME: the attended step the new mode still needs,
# named as the command that performs it (section 3.6's list).
harbor_access_report_next() {
  case "${1}" in
    connect)
      harbor_msg "access: access_mode is now connect; the attended step is: harbor auth connect, then: harbor provision"
      ;;
    tailnet)
      harbor_msg "access: access_mode is now tailnet; the attended step is: harbor pair, then: harbor provision"
      ;;
    ssh)
      harbor_msg "access: access_mode is now ssh; there is no further step on this node — the desktop starts and manages its own remote server over SSH, and Harbor neither manages nor observes it; run: harbor provision to confirm the node's Node.js satisfies the launcher's requirement"
      ;;
  esac
}
