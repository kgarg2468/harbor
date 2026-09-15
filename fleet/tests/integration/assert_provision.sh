#!/bin/bash
# Task 20: the installed-entrypoint row, driven through the real harbor provision
# as the real operator. Bootstrap has already run at the real paths. Each crash
# case gets its own runner, so no provision state is reset to manufacture a retry.
#
# Runs as root to read both principals' journals and to use runuser. Harbor itself
# always runs as the operator. The fixed env list below is the sibling of
# assert_auth.sh's: hook variables appear only on the explicit crash invocation.
# No credential exists in this fixture; auth status is synthetic vendor output.
#
# Usage: sudo bash assert_provision.sh [--fail-after STEP]
# One check per line, failures collected by common.sh and reported by it_done.
set -euo pipefail

# shellcheck source=lib/common.sh
. "$(cd "$(dirname "${0}")" && pwd -P)/lib/common.sh"

[ "$(id -u)" = 0 ] || {
  printf 'assert_provision.sh must run as root\n' >&2
  exit 1
}
fail_after=""
case "${1:-}" in
  --fail-after) fail_after="${2:?--fail-after needs a step name}" ;;
  '') ;;
  *)
    printf 'assert_provision.sh: unknown option\n' >&2
    exit 1
    ;;
esac

tag="$(it_release_tag)"
release="${IT_INSTALL_ROOT}/${tag}"
loosened="${release}/versions.lock"
operator_home="$(it_operator_home)"
operator_uid="$(id -u "${IT_OPERATOR}")"
op_root="${operator_home}/.local/state/harbor"
op_journal="${op_root}/journal"
unit="${operator_home}/.config/systemd/user/t3code.service"
expected_unit="${operator_home}/.local/share/harbor-it/t3code.service.expected"
checkout_moved="${IT_FLEET}.moved-by-assert-provision"

section() {
  printf '\n-- %s\n' "${*}"
}

provision_restore() {
  if [ -e "${loosened}" ]; then chmod 0644 "${loosened}"; fi
  if [ -d "${checkout_moved}" ] && [ ! -e "${IT_FLEET}" ]; then
    mv "${checkout_moved}" "${IT_FLEET}"
  fi
}
trap provision_restore EXIT

provision_sha() {
  sha256sum "${1}" | cut -d ' ' -f 1
}

provision_journal() {
  find "${1}" -maxdepth 1 -type f -name '*.json' -exec sha256sum {} + \
    | LC_ALL=C sort | sha256sum | cut -d ' ' -f 1
}

# provision_run [--fail-after STEP]: every variable is one literal array element.
# env -i also removes ambient hook variables and credentials. HOME binds the real
# operator paths; XDG_RUNTIME_DIR and the bus address reach the real linger manager.
# HARBOR_PID is never supplied: bin/harbor sets it to the process the hook must kill.
provision_run() {
  local step=""
  local -a argv
  if [ "${1:-}" = --fail-after ]; then step="${2:?}"; fi
  argv=(runuser -u "${IT_OPERATOR}" -- env -i
    "PATH=${IT_PATH}"
    "HOME=${operator_home}"
    "HARBOR_VERBOSE=1"
    "XDG_RUNTIME_DIR=/run/user/${operator_uid}"
    "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${operator_uid}/bus")
  if [ -n "${step}" ]; then
    argv+=("HARBOR_TEST_HOOKS=1" "HARBOR_FAIL_AFTER=${step}")
  fi
  argv+=("${IT_LINK}" provision)
  printf '\n+ %s\n' "${argv[*]}"
  PROVISION_RC=0
  PROVISION_OUT="$("${argv[@]}" 2>&1)" || PROVISION_RC="$?"
  printf '%s\n+ exit %s\n' "${PROVISION_OUT}" "${PROVISION_RC}"
}

# ---------------------------------------------------------------------------
section 'a bootstrapped node and the provision-only vendor fixture'
# ---------------------------------------------------------------------------
it_symlink 'installed entrypoint' "${release}/bin/harbor" "${IT_LINK}"
it_file 'bootstrap record' 0644 root root "${IT_HARBOR_RECORD}"
it_file_absent 'operator state root before provision' "${op_root}"
it_eq 'real linger is enabled' yes "$(loginctl show-user "${IT_OPERATOR}" -p Linger --value)"
# Bootstrap leaves Tailscale at NeedsLogin. Drive the stub directly so no earlier
# Harbor command creates the state root whose ordering this script must prove.
runuser -u "${IT_OPERATOR}" -- env -i "PATH=${IT_PATH}" "HOME=${operator_home}" \
  tailscale up --hostname=harbor-node >/dev/null
install -m 0644 "${release}/versions.lock" "${IT_FIXTURES}/provision.versions.lock"
ln -s t3 "${IT_BIN}/npm"
base_mut="$(provision_sha "${IT_MUT_LOG}")"
base_record="$(provision_sha "${IT_HARBOR_RECORD}")"
base_journal="$(provision_journal "${IT_HARBOR_JOURNAL}")"

# ---------------------------------------------------------------------------
section 'writable installed release: exit 3 before the lock and any mutation'
# ---------------------------------------------------------------------------
chmod g+w "${loosened}"
provision_run
it_eq 'writable release exits 3 through provision' 3 "${PROVISION_RC}"
it_contains 'refusal names the writable path' "${loosened}" "${PROVISION_OUT}"
it_contains 'entrypoint mode guard refused it' entrypoint.mode "${PROVISION_OUT}"
it_file_absent 'refusal created no operator root or lock' "${op_root}"
it_eq 'refusal mutated no vendor' "${base_mut}" "$(provision_sha "${IT_MUT_LOG}")"
chmod 0644 "${loosened}"

# ---------------------------------------------------------------------------
section 'state root 0700 exists strictly before lock.d'
# ---------------------------------------------------------------------------
# lock-gate is after state-root creation but before mkdir lock.d. SIGKILL freezes
# that position; a final mode check alone would not establish the ordering.
provision_run --fail-after lock-gate
it_eq 'lock-gate really SIGKILLed the provision process' 137 "${PROVISION_RC}"
it_contains 'the requested boundary was emitted' 'harbor: step: lock-gate' "${PROVISION_OUT}"
it_dir 'state root at the boundary' 0700 "${IT_OPERATOR}" "${IT_OPERATOR}" "${op_root}"
it_dir 'gate at the boundary' 0700 "${IT_OPERATOR}" "${IT_OPERATOR}" "${op_root}/reclaim.d"
it_file 'gate holder' 0600 "${IT_OPERATOR}" "${IT_OPERATOR}" "${op_root}/reclaim.d/holder"
it_file_absent 'the lock has not yet been taken' "${op_root}/lock.d"
it_contains 'provision opened the operator log' 'command provision' "$(cat "${op_root}/harbor.log")"
it_eq 'nothing journaled before the lock' 0 \
  "$(find "${op_root}" -maxdepth 2 -type f -name '*.json' | wc -l | tr -d ' ')"
# The documented manual remedy for a dead gate, performed as its owner. No row
# ran; this removes only the gate, leaving provision's state-root creation intact.
runuser -u "${IT_OPERATOR}" -- env -i "PATH=${IT_PATH}" "HOME=${operator_home}" \
  rm -f "${op_root}/reclaim.d/holder"
runuser -u "${IT_OPERATOR}" -- env -i "PATH=${IT_PATH}" "HOME=${operator_home}" \
  rmdir "${op_root}/reclaim.d"

# ---------------------------------------------------------------------------
section 'row boundary crash and an ordinary rerun'
# ---------------------------------------------------------------------------
if [ -n "${fail_after}" ]; then
  provision_run --fail-after "${fail_after}"
  it_eq "SIGKILL at ${fail_after}" 137 "${PROVISION_RC}"
  it_contains 'the requested row boundary was emitted' "harbor: step: ${fail_after}" "${PROVISION_OUT}"
  # These boundaries sit after the real mutation and before the applied write.
  # Save the prepared entries so recovery must resolve those very entries.
  prepared=()
  case "${fail_after}" in
    config-file | agents-claude-installed | agents-codex-installed | t3-installed | \
      t3-service-installed | state-installed-lock | state-provision-json)
      for entry in "${op_journal}"/*.json; do
        [ -f "${entry}" ] || continue
        if [ "$(it_journal_field "${entry}" phase)" = prepared ]; then prepared+=("${entry}"); fi
      done
      it_ne 'mutation left a prepared entry before its applied write' 0 "${#prepared[@]}"
      ;;
  esac
fi
provision_run
it_eq 'ordinary rerun converges' 0 "${PROVISION_RC}"
it_contains 'all provision rows completed' 'provision complete; every row applied' "${PROVISION_OUT}"
it_file_absent 'rerun released the operator lock' "${op_root}/lock.d"
if [ -n "${fail_after}" ]; then
  for entry in "${prepared[@]}"; do
    it_eq 'recovery applied the interrupted mutation' applied "$(it_journal_field "${entry}" phase)"
  done
fi
for entry in "${op_journal}"/*.json; do
  [ -f "${entry}" ] || continue
  case "$(it_journal_field "${entry}" phase)" in
    applied | reverted) it_pass "$(basename "${entry}") resolved" ;;
    *) it_fail "$(basename "${entry}") remains unresolved" ;;
  esac
done
it_file 'real installed.lock' 0600 "${IT_OPERATOR}" "${IT_OPERATOR}" "${op_root}/installed.lock"
it_file 'real provision.json' 0600 "${IT_OPERATOR}" "${IT_OPERATOR}" "${op_root}/provision.json"
it_file 'real config' 0600 "${IT_OPERATOR}" "${IT_OPERATOR}" "${operator_home}/.config/harbor/config"
it_eq 'default access config' access_mode=connect "$(cat "${operator_home}/.config/harbor/config")"
for key in claude_code_version codex_version t3_version; do
  it_contains "installed.lock records ${key}" "${key}=$(it_lock "${key}")" "$(cat "${op_root}/installed.lock")"
done

# ---------------------------------------------------------------------------
section 'real active vendor service, with vendor-owned bytes'
# ---------------------------------------------------------------------------
active_rc=0
active="$(runuser -u "${IT_OPERATOR}" -- env -i "PATH=${IT_PATH}" "HOME=${operator_home}" \
  "XDG_RUNTIME_DIR=/run/user/${operator_uid}" \
  "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${operator_uid}/bus" \
  systemctl --user is-active t3code.service)" || active_rc="$?"
it_eq 'real user-manager query succeeded' 0 "${active_rc}"
it_eq 't3code.service is active' active "${active}"
if cmp -s "${expected_unit}" "${unit}"; then
  it_pass 'unit is byte for byte what the vendor stub wrote'
else
  it_fail 'unit differs from the vendor stub snapshot'
fi

# ---------------------------------------------------------------------------
section 'deleted checkout and a second run that changes nothing'
# ---------------------------------------------------------------------------
before_mut="$(provision_sha "${IT_MUT_LOG}")"
# The entry names present before the rerun, pipe-delimited on both sides so a
# substring test cannot match a prefix of a longer name.
before_names='|'
for entry in "${op_journal}"/*.json; do
  [ -f "${entry}" ] || continue
  before_names="${before_names}$(basename "${entry}")|"
done
before_lock="$(provision_sha "${op_root}/installed.lock")"
before_record="$(provision_sha "${op_root}/provision.json")"
mv "${IT_FLEET}" "${checkout_moved}"
it_file_absent 'checkout is gone' "${IT_FLEET}"
provision_run
it_eq 'installed provision succeeds without the checkout' 0 "${PROVISION_RC}"
it_eq 'second run makes zero mutating stub calls' "${before_mut}" "$(provision_sha "${IT_MUT_LOG}")"
# "Writes no new entries" is what assert_rerun.sh means by it for bootstrap: no new
# created or modified entry. A rerun that changes nothing still journals what it
# inspected, because every unchanged write ends at harbor_journal_create ... observed
# applied, which is a new entry file by construction -- tests/unit/lib/state.bats pins
# the observed entry a second harbor_state_provision_record writes. Comparing the
# journal byte for byte would assert that provision does not record its own
# inspections, which is neither the contract nor the behaviour. The entries that must
# not appear are the ones claiming something was created or modified.
new_written=0
new_observed=0
for entry in "${op_journal}"/*.json; do
  [ -f "${entry}" ] || continue
  case "${before_names}" in
    *"|$(basename "${entry}")|"*) continue ;;
  esac
  ownership="$(it_journal_field "${entry}" ownership)"
  case "${ownership}" in
    observed) new_observed=$((new_observed + 1)) ;;
    *)
      new_written=$((new_written + 1))
      it_fail "the rerun journalled $(basename "${entry}") as ${ownership}"
      ;;
  esac
done
it_eq 'second run journals no created or modified entry' 0 "${new_written}"
printf 'the rerun journalled %s new observed entries, which is what an\n' "${new_observed}"
printf 'inspection-first rerun records: already-correct state, mutating nothing.\n'
it_eq 'installed.lock unchanged' "${before_lock}" "$(provision_sha "${op_root}/installed.lock")"
it_eq 'provision.json unchanged' "${before_record}" "$(provision_sha "${op_root}/provision.json")"
if cmp -s "${expected_unit}" "${unit}"; then
  it_pass 'vendor unit remains byte-identical after rerun'
else
  it_fail 'rerun changed the vendor unit'
fi
it_eq 'root record unchanged' "${base_record}" "$(provision_sha "${IT_HARBOR_RECORD}")"
it_eq 'root journal unchanged' "${base_journal}" "$(provision_journal "${IT_HARBOR_JOURNAL}")"
it_done 'assert_provision'
