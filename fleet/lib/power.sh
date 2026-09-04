#!/bin/bash
# Power policy (design section 5.2, the Power row): the logind lid drop-in and the
# masked sleep targets that keep a headless laptop node awake with its lid closed.
# Every mutation here is one journaled transaction of design section 3.7 and every
# step is decided by inspection first (section 6.1), so a second run makes no
# mutating call. The destination root of the drop-in is a parameter defaulting to
# the production /etc, so tests write inside their own fixture root. Harbor masks
# and never unmasks: a target somebody else already masked is recorded and left
# alone, and only the entries this library writes as created are ever inverted by
# teardown (section 5.7).
HARBOR_POWER_SLEEP_TARGETS="sleep.target suspend.target hibernate.target hybrid-sleep.target"
HARBOR_POWER_LOGIND_UNIT="systemd-logind.service"
# harbor_power_dropin_path [DEST_ROOT]: the logind drop-in under the configuration
# root DEST_ROOT, which defaults to the production /etc.
harbor_power_dropin_path() {
  printf '%s/systemd/logind.conf.d/harbor.conf' "${1:-/etc}"
}
# The drop-in content: the three lid settings of the design section 5.2 Power row,
# each ignore, so closing the lid on external power, on battery, and docked all
# leave the node running. Byte-stable, so a rerun observes the same sha256 and
# rewrites nothing.
harbor_power_dropin_render() {
  printf '# Managed by Harbor: keep this node awake with the lid closed.\n'
  printf '# Remove this file and restart %s to restore the system default.\n' "${HARBOR_POWER_LOGIND_UNIT}"
  printf '[Login]\n'
  printf 'HandleLidSwitch=ignore\n'
  printf 'HandleLidSwitchExternalPower=ignore\n'
  printf 'HandleLidSwitchDocked=ignore\n'
}
# harbor_power_lid STATE_ROOT [DEST_ROOT]: write the drop-in as one journaled file
# transaction, a temporary file and a rename, with both states rendered by
# harbor_observe_file, which is what recovery observes a file entry with, so an
# entry left prepared by a crash between the rename and the applied write is
# decidable. A drop-in that is already byte for byte what would be written is
# journaled observed and left alone; anything at the path that is not a regular
# file is foreign and exits 3 untouched. Sets HARBOR_POWER_LID_CHANGED to 1 when
# the file was written, which is what makes the logind restart conditional.
harbor_power_lid() {
  local root="${1}" path dir pre post ownership tmp entry
  HARBOR_POWER_LID_CHANGED=0
  path="$(harbor_power_dropin_path "${2:-}")"
  dir="$(dirname "${path}")"
  if [ ! -d "${dir}" ]; then
    mkdir -p "${dir}"
    chmod 0755 "${dir}"
  fi
  pre="$(harbor_observe_file "${path}")"
  case "${pre}" in
    '"unobservable:'*)
      harbor_die 3 power.foreign "${path} exists and is not a regular file; inspect it and remove it by hand, then rerun"
      ;;
  esac
  tmp="${dir}/.tmp.$(basename "${path}").${HARBOR_LOCK_ID_PID}"
  rm -f "${tmp}"
  harbor_power_dropin_render >"${tmp}"
  chmod 0644 "${tmp}"
  post="$(harbor_observe_file "${tmp}")"
  if [ "${post}" = "${pre}" ]; then
    rm -f "${tmp}"
    harbor_journal_create "${root}" file "${path}" observed applied "${pre}" "${post}"
    return 0
  fi
  ownership=modified
  [ "${pre}" != '"absent"' ] || ownership=created
  harbor_journal_create "${root}" file "${path}" "${ownership}" prepared "${pre}" "${post}"
  entry="${HARBOR_JOURNAL_ENTRY}"
  harbor_journal_sync_path "${tmp}"
  if ! mv -f "${tmp}" "${path}"; then
    rm -f "${tmp}"
    harbor_die 2 power.lid_rename "renaming ${tmp} onto ${path} failed; ${path} holds what it held before and $(basename "${entry}") stays prepared, rerun after fixing the cause"
  fi
  harbor_journal_sync_path "${dir}"
  harbor_step power-lid
  harbor_journal_set_phase "${entry}" applied
  HARBOR_POWER_LID_CHANGED=1
}
# harbor_power_unit_file_state UNIT: the unit file state systemctl reports for UNIT,
# one word. Whether a unit is masked is a property of systemd's unit file lookup,
# not of any one path: a mask is a symlink to /dev/null that may sit in
# /etc/systemd/system or, for a runtime mask, in /run/systemd/system, and the unit
# itself may be shipped, generated, or transient. So the honest question is the one
# systemctl answers, and this asks it rather than reading a file. The decision is
# made on the word printed, never on the exit status, because systemctl exits
# non-zero for several states that are perfectly readable, masked among them. A word
# outside the vocabulary, which is what an unknown unit or an unreachable manager
# produces, is fail-closed: exit 2, nothing journaled, nothing masked.
harbor_power_unit_file_state() {
  local unit="${1}" out rc=0
  out="$(systemctl is-enabled "${unit}" 2>&1)" || rc="$?"
  out="$(printf '%s\n' "${out}" | sed -n 1p)"
  case "${out}" in
    masked | masked-runtime | enabled | enabled-runtime | linked | linked-runtime | alias | static | indirect | disabled | generated | transient)
      printf '%s' "${out}"
      ;;
    *)
      harbor_die 2 power.unit_state "systemctl is-enabled ${unit} printed '${out}' (exit ${rc}), which is not a unit file state; nothing was masked"
      ;;
  esac
}
# harbor_observe_op_systemd_mask UNIT: the observer harbor_journal_observe dispatches
# to for a systemd-mask entry, so a prepared entry left by a crash between the mask
# and the applied write is decidable by recovery (design section 3.7). It answers
# with the unit file state systemctl reports, in the shape both recorded states
# carry, so recovery compares the same rendering it recorded: equal to pre_state the
# mask never happened, equal to post_state it did. Inspection only; an unreadable
# state stays the exit 2 of harbor_power_unit_file_state. Called only through
# harbor_journal_observe.
harbor_observe_op_systemd_mask() {
  local state
  state="$(harbor_power_unit_file_state "${1}")" || exit "$?"
  printf '{"unit_file_state":"%s"}' "$(harbor_json_escape "${state}")"
}
# harbor_power_masked_state: the state a masked unit is recorded in, the post_state
# of every systemd-mask entry.
harbor_power_masked_state() {
  printf '{"unit_file_state":"masked"}'
}
# harbor_power_mask STATE_ROOT UNIT: mask UNIT as one journaled systemd-mask
# transaction whose pre_state is the state inspection found. A unit already masked
# is journaled observed, created directly as applied, and no systemctl mask runs for
# it. Only a persistent mask counts as already masked: a runtime mask lives in /run
# and is gone after the next boot, so it would not keep this node awake. The mask is
# verified by asking systemctl again before the entry is marked applied, so a mask
# that reported success without taking effect leaves the entry prepared.
harbor_power_mask() {
  local root="${1}" unit="${2}" pre post observed out rc=0 entry
  pre="$(harbor_observe_op_systemd_mask "${unit}")" || exit "$?"
  post="$(harbor_power_masked_state)"
  if [ "${pre}" = "${post}" ]; then
    harbor_journal_create "${root}" systemd-mask "${unit}" observed applied "${pre}" "${post}"
    return 0
  fi
  harbor_journal_create "${root}" systemd-mask "${unit}" created prepared "${pre}" "${post}"
  entry="${HARBOR_JOURNAL_ENTRY}"
  harbor_log_vendor systemctl mask "${unit}"
  out="$(systemctl mask "${unit}" 2>&1)" || rc="$?"
  [ "${rc}" = 0 ] \
    || harbor_die 2 power.mask "systemctl mask ${unit} failed (exit ${rc}): ${out}; $(basename "${entry}") stays prepared, rerun after fixing the cause"
  harbor_step "power-mask-${unit}"
  observed="$(harbor_observe_op_systemd_mask "${unit}")" || exit "$?"
  [ "${observed}" = "${post}" ] \
    || harbor_die 2 power.mask_verify "systemctl mask ${unit} exited 0 but systemctl still reports ${observed}; $(basename "${entry}") stays prepared"
  harbor_journal_set_phase "${entry}" applied
}
# harbor_power_mask_sleep STATE_ROOT: mask the four sleep targets, in order, each its
# own journaled transaction with its own pre-state.
harbor_power_mask_sleep() {
  local root="${1}" unit
  for unit in ${HARBOR_POWER_SLEEP_TARGETS}; do
    harbor_power_mask "${root}" "${unit}"
  done
}
# harbor_power_restart_logind: restart logind so the drop-in takes effect. Nothing
# is journaled: a restart leaves no artifact to own or invert.
harbor_power_restart_logind() {
  local out rc=0
  harbor_log_vendor systemctl restart "${HARBOR_POWER_LOGIND_UNIT}"
  out="$(systemctl restart "${HARBOR_POWER_LOGIND_UNIT}" 2>&1)" || rc="$?"
  [ "${rc}" = 0 ] \
    || harbor_die 2 power.logind_restart "systemctl restart ${HARBOR_POWER_LOGIND_UNIT} failed (exit ${rc}): ${out}; the drop-in is in place but logind is still running with the previous lid policy, so fix the cause and rerun"
  harbor_step power-logind-restarted
}
# harbor_power_configure STATE_ROOT [DEST_ROOT]: the whole Power step, in the order
# of the design section 5.2 table: the lid drop-in, the four masked sleep targets,
# then the logind restart, which runs only when the drop-in was written, so a second
# run makes no mutating call at all.
harbor_power_configure() {
  local root="${1}"
  harbor_power_lid "${root}" "${2:-}"
  harbor_power_mask_sleep "${root}"
  [ "${HARBOR_POWER_LID_CHANGED}" = 1 ] || return 0
  harbor_power_restart_logind
}
