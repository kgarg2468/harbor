#!/bin/bash
# Task 21: the installed access command at the real operator's config path.
# Runs as root for runuser and journal reads; Harbor always runs as the operator.
# There is no tailnet here, so pairing is not proven end to end.
# Usage: sudo bash assert_access.sh
# One check per line, failures collected by common.sh and reported by it_done.
set -euo pipefail

# shellcheck source=lib/common.sh
. "$(cd "$(dirname "${0}")" && pwd -P)/lib/common.sh"

[ "$(id -u)" = 0 ] || {
  printf 'assert_access.sh must run as root\n' >&2
  exit 1
}

tag="$(it_release_tag)"
release="${IT_INSTALL_ROOT}/${tag}"
operator_home="$(it_operator_home)"
operator_uid="$(id -u "${IT_OPERATOR}")"
op_root="${operator_home}/.local/state/harbor"
op_journal="${op_root}/journal"
config="${operator_home}/.config/harbor/config"

section() {
  printf '\n-- %s\n' "${*}"
}

access_sha() {
  sha256sum "${1}" | cut -d ' ' -f 1
}

access_names() {
  local entry
  printf '|'
  for entry in "${op_journal}"/*.json; do
    [ -f "${entry}" ] || continue
    printf '%s|' "$(basename "${entry}")"
  done
}

access_journal() {
  find "${op_journal}" -maxdepth 1 -type f -name '*.json' -exec sha256sum {} + \
    | LC_ALL=C sort | sha256sum | cut -d ' ' -f 1
}

# Every "the journal is unchanged" assertion below is a hash compared to a hash,
# and over an empty journal both sides are the hash of nothing -- so the check
# would pass however badly the run behaved. Provision populates it and the
# entry-count assertions above depend on that, but depending on it is not the
# same as stating it, and this is what stops those comparisons from going quietly
# vacuous if a later change stops the journal from being written at all.
access_journal_nonempty() {
  local entry
  for entry in "${op_journal}"/*.json; do
    if [ -f "${entry}" ]; then
      printf 'yes'
      return 0
    fi
  done
  printf 'no'
}

# The same fixed environment as assert_provision.sh, with no test hooks.
access_run() {
  local -a argv
  argv=(runuser -u "${IT_OPERATOR}" -- env -i
    "PATH=${IT_PATH}"
    "HOME=${operator_home}"
    "HARBOR_VERBOSE=1"
    "XDG_RUNTIME_DIR=/run/user/${operator_uid}"
    "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${operator_uid}/bus"
    "${IT_LINK}" "$@")
  printf '\n+ %s\n' "${argv[*]}"
  ACCESS_RC=0
  ACCESS_OUT="$("${argv[@]}" 2>&1)" || ACCESS_RC="$?"
  printf '%s\n+ exit %s\n' "${ACCESS_OUT}" "${ACCESS_RC}"
}

section 'fresh provision with the synthetic vendor fixture'
it_symlink 'installed entrypoint' "${release}/bin/harbor" "${IT_LINK}"
it_file_absent 'operator state before provision' "${op_root}"
if ! it_wait_user_manager "${operator_uid}"; then
  it_fail "the operator's user manager never came up: ${IT_USER_MANAGER_STATE}"
  it_done 'assert_access'
  exit 1
fi
runuser -u "${IT_OPERATOR}" -- env -i "PATH=${IT_PATH}" "HOME=${operator_home}" \
  tailscale up --hostname=harbor-node >/dev/null
install -m 0644 "${release}/versions.lock" "${IT_FIXTURES}/provision.versions.lock"
ln -s t3 "${IT_BIN}/npm"
access_run provision
it_eq 'fresh provision succeeds' 0 "${ACCESS_RC}"
it_file_absent 'provision released the operator lock' "${op_root}/lock.d"

# access get's whole contract is one word on stdout. Comparing it against the
# merged capture above would compare it against HARBOR_VERBOSE's trace on stderr
# as well, and this is also the only spelling that asserts what a caller piping
# harbor access get actually receives -- with no HARBOR_VERBOSE, because such a
# caller would not set one.
access_stdout() {
  runuser -u "${IT_OPERATOR}" -- env -i \
    "PATH=${IT_PATH}" \
    "HOME=${operator_home}" \
    "XDG_RUNTIME_DIR=/run/user/${operator_uid}" \
    "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${operator_uid}/bus" \
    "${IT_LINK}" "$@" 2>/dev/null
}

section 'access get on the freshly provisioned node'
access_run access get
it_eq 'access get succeeds' 0 "${ACCESS_RC}"
it_eq 'default access mode on stdout alone' connect "$(access_stdout access get)"
it_file_absent 'get leaves no operator lock' "${op_root}/lock.d"

section 'switch to ssh at the real config path'
before_names="$(access_names)"
access_run access set ssh
it_eq 'ssh switch succeeds' 0 "${ACCESS_RC}"
it_eq 'ssh config contents' access_mode=ssh "$(cat "${config}")"
it_file 'ssh config' 0600 "${IT_OPERATOR}" "${IT_OPERATOR}" "${config}"
it_contains 'ssh needs no node setup' 'no further step on this node' "${ACCESS_OUT}"
it_file_absent 'ssh switch released the operator lock' "${op_root}/lock.d"
config_entries=0
other_entries=0
for entry in "${op_journal}"/*.json; do
  [ -f "${entry}" ] || continue
  case "${before_names}" in *"|$(basename "${entry}")|"*) continue ;; esac
  if [ "$(it_journal_field "${entry}" op)" = file ] && [ "$(it_journal_field "${entry}" target)" = "${config}" ]; then
    config_entries=$((config_entries + 1))
    it_eq 'config-file entry is modified' modified "$(it_journal_field "${entry}" ownership)"
    it_eq 'config-file entry is applied' applied "$(it_journal_field "${entry}" phase)"
  else
    other_entries=$((other_entries + 1))
  fi
done
it_eq 'ssh switch journals the config file' 1 "${config_entries}"
it_eq 'ssh journals no setup ops' 0 "${other_entries}"
# Provision in ssh mode reaches the real sh -lc launcher probe, through a real
# login shell rather than the unit lane's stub. Asserting 0 here is not an
# assumption about the runner: provision's own preflight runs
# sh -lc 'node --version' and exits 3 if it fails, and the first provision above
# already succeeded, so this machine's login shell demonstrably resolves a
# satisfying node. The launcher command is run here anyway, because a
# disagreement between it and Harbor's report is exactly what this row exists to
# catch and nothing else in the lane would notice one.
launcher_rc=0
runuser -u "${IT_OPERATOR}" -- env -i "PATH=${IT_PATH}" "HOME=${operator_home}" \
  sh -lc 'command -v node >/dev/null && node --version' >/dev/null 2>&1 || launcher_rc="$?"
it_eq 'the launcher command resolves node on this runner' 0 "${launcher_rc}"
access_run provision
it_eq 'ssh provision agrees with the launcher command' 0 "${ACCESS_RC}"
it_file_absent 'ssh provision released the operator lock' "${op_root}/lock.d"

section 'tailnet is gated on this release'
before_config="$(access_sha "${config}")"
before_journal="$(access_journal)"
it_eq 'there are journal entries for the refusal to leave alone' yes "$(access_journal_nonempty)"
access_run access set tailnet
it_eq 'unsupported tailnet exits 3' 3 "${ACCESS_RC}"
it_eq 'tailnet refusal leaves ssh configured' access_mode=ssh "$(cat "${config}")"
it_eq 'tailnet refusal leaves config unchanged' "${before_config}" "$(access_sha "${config}")"
it_eq 'tailnet refusal leaves journal unchanged' "${before_journal}" "$(access_journal)"
it_file_absent 'tailnet refusal leaves no operator lock' "${op_root}/lock.d"

section 'switch back to connect without reverting ssh operations'
before_mut="$(access_sha "${IT_MUT_LOG}")"
# Existing entries must retain their bytes: no ssh entry is reverted.
declare -A before_sha=()
for entry in "${op_journal}"/*.json; do
  [ -f "${entry}" ] || continue
  before_sha["${entry}"]="$(access_sha "${entry}")"
done
# Same reason: a loop over an empty array emits no checks and reports nothing.
it_eq 'there are existing entries to prove the switch left alone' yes "$(access_journal_nonempty)"
access_run access set connect
it_eq 'connect switch succeeds' 0 "${ACCESS_RC}"
it_eq 'connect config contents' access_mode=connect "$(cat "${config}")"
it_contains 'connect names the attended command' 'harbor auth connect' "${ACCESS_OUT}"
it_eq 'switch from ssh makes no mutating stub call' "${before_mut}" "$(access_sha "${IT_MUT_LOG}")"
for entry in "${!before_sha[@]}"; do
  it_eq 'switch from ssh leaves existing journal entry unchanged' "${before_sha[${entry}]}" "$(access_sha "${entry}")"
done
it_file_absent 'connect switch released the operator lock' "${op_root}/lock.d"

section 'second connect switch is a no-op'
before_mut="$(access_sha "${IT_MUT_LOG}")"
before_names="$(access_names)"
access_run access set connect
it_eq 'second connect switch succeeds' 0 "${ACCESS_RC}"
it_eq 'second connect switch makes zero mutating stub calls' "${before_mut}" "$(access_sha "${IT_MUT_LOG}")"
new_written=0
for entry in "${op_journal}"/*.json; do
  [ -f "${entry}" ] || continue
  case "${before_names}" in *"|$(basename "${entry}")|"*) continue ;; esac
  case "$(it_journal_field "${entry}" ownership)" in
    created | modified) new_written=$((new_written + 1)) ;;
  esac
done
it_eq 'second connect switch journals no new created or modified entry' 0 "${new_written}"
it_file_absent 'second connect switch released the operator lock' "${op_root}/lock.d"
it_done 'assert_access'
