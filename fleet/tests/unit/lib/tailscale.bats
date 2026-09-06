#!/usr/bin/env bats
load '../test_helper'

# lib/tailscale.sh: the Tailscale install and Tailscale operator rows of design
# section 5.2. Every vendor command is a shim under this test's own bin, every
# fixture is written inline under BATS_TEST_TMPDIR, the apt configuration root is a
# fixture directory, and the state root is the fixture state root. Nothing here
# reads or writes a real system path.
TAB="$(printf '\t')"

setup() {
  # shellcheck source=lib/log.sh
  . "${HARBOR_ROOT}/lib/log.sh"
  # shellcheck source=lib/lock.sh
  . "${HARBOR_ROOT}/lib/lock.sh"
  # shellcheck source=lib/versions.sh
  . "${HARBOR_ROOT}/lib/versions.sh"
  # shellcheck source=lib/journal.sh
  . "${HARBOR_ROOT}/lib/journal.sh"
  # shellcheck source=lib/apt.sh
  . "${HARBOR_ROOT}/lib/apt.sh"
  # shellcheck source=lib/tailscale.sh
  . "${HARBOR_ROOT}/lib/tailscale.sh"
  fixture_state_root
  HARBOR_PID="$$"
  # The vendor commands this library runs, each a symlink to the generic shim, in
  # a bin of this test's own so no repository fixture set is consulted by accident.
  BIN="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "${BIN}"
  local tool
  for tool in tailscale apt-get dpkg-query curl runuser; do
    ln -s "${HARBOR_ROOT}/tests/shims/bin/harbor-shim" "${BIN}/${tool}"
  done
  PATH="${BIN}:${PATH}"
  export PATH
  HARBOR_SHIM_LOG="${BATS_TEST_TMPDIR}/shim.log"
  export HARBOR_SHIM_LOG
  FX="${BATS_TEST_TMPDIR}/fx"
  HARBOR_SHIM_FIXTURES="${FX}"
  export HARBOR_SHIM_FIXTURES
  ETC="${BATS_TEST_TMPDIR}/etc"
  KEYRING="${ETC}/apt/keyrings/tailscale-archive-keyring.gpg"
  SOURCE="${ETC}/apt/sources.list.d/tailscale.list"
  # The locked values come from the real lock file, never from this test.
  harbor_versions_load "$(harbor_versions_lock_path)"
  LOCKED="$(harbor_version_require tailscale_version)"
  CHANNEL="$(harbor_version_require tailscale_apt_channel)"
  KEYRING_URL="https://pkgs.tailscale.com/${CHANNEL}.noarmor.gpg"
  OP="harbor"
  AFTER=""
  SET_EFFECT="full"
  GET_MODE="unavailable"
  harbor_lock_acquire "${FIX_ROOT}" operator
}

teardown() {
  harbor_lock_release "${FIX_ROOT}"
}

# ---- fixture writers ------------------------------------------------------------

key() {
  # key ARG...: the shim's fixture key for an argv (see tests/shims/bin/harbor-shim)
  printf '%s' "$*" | tr ' /' '_%'
}

fx() {
  # fx NAME KEY [EXIT]: the healthy reply of shim NAME to KEY, body from stdin
  mkdir -p "${FX}/${1}/healthy"
  cat >"${FX}/${1}/healthy/${2}.out"
  printf '%s\n' "${3:-0}" >"${FX}/${1}/healthy/${2}.exit"
}

dpkg_installed() {
  # dpkg_installed VERSION: dpkg reports tailscale installed at VERSION
  fx dpkg-query "$(key -s tailscale)" <<EOF
Package: tailscale
Status: install ok installed
Priority: optional
Section: net
Architecture: amd64
Version: ${1}
EOF
}

dpkg_absent() {
  fx dpkg-query "$(key -s tailscale)" 1 <<EOF
dpkg-query: package 'tailscale' is not installed and no information is available
EOF
}

apt_ok() {
  # apt_ok VERSION [OLD]: apt-get update succeeds, and the simulated and real
  # installs of tailscale=VERSION succeed with and without --allow-downgrades,
  # the simulation printing the upgrade form "Inst tailscale [OLD] (VERSION" when
  # OLD is given and the fresh form otherwise.
  local sim
  if [ -n "${2:-}" ]; then
    sim="Inst tailscale [${2}] (${1} Tailscale:noble [amd64])"
  else
    sim="Inst tailscale (${1} Tailscale:noble [amd64])"
  fi
  fx apt-get update <<EOF
Hit:1 https://pkgs.tailscale.com/stable/ubuntu noble InRelease
Reading package lists...
EOF
  local pin="tailscale=${1}" variant
  for variant in "$(key -s install "${pin}")" "$(key -s install --allow-downgrades "${pin}")"; do
    fx apt-get "${variant}" <<EOF
Reading package lists...
Building dependency tree...
${sim}
Conf tailscale (${1} Tailscale:noble [amd64])
EOF
  done
  for variant in "$(key install -y "${pin}")" "$(key install -y --allow-downgrades "${pin}")"; do
    fx apt-get "${variant}" <<EOF
Reading package lists...
Setting up tailscale (${1}) ...
EOF
  done
}

apt_sim_fails() {
  # apt_sim_fails VERSION: the pinned version is not in any reachable source
  local pin="tailscale=${1}" variant
  for variant in "$(key -s install "${pin}")" "$(key -s install --allow-downgrades "${pin}")"; do
    fx apt-get "${variant}" 100 <<EOF
Reading package lists...
E: Version '${1}' for 'tailscale' was not found
EOF
  done
}

curl_ok() {
  fx curl "$(key -fsSL --proto =https --tlsv1.2 "${KEYRING_URL}")" <<EOF
fixture keyring bytes
EOF
}

curl_fails() {
  fx curl "$(key -fsSL --proto =https --tlsv1.2 "${KEYRING_URL}")" 22 </dev/null
}

backend() {
  # backend STATE: root's tailscale status --json carries BackendState STATE
  fx tailscale "$(key status --json)" <<EOF
{
  "Version": "${LOCKED}-fixture",
  "BackendState": "${1}",
  "Self": {"HostName": "harbor-node"}
}
EOF
}

status_fails() {
  fx tailscale "$(key status --json)" 1 <<EOF
failed to connect to local tailscaled; it doesn't appear to be running
EOF
}

probe() {
  # probe granted|denied: what ${OP}'s unprivileged tailscale status --json does
  if [ "${1}" = granted ]; then
    fx runuser "$(key -u "${OP}" -- tailscale status --json)" <<EOF
{"BackendState": "Running"}
EOF
  else
    fx runuser "$(key -u "${OP}" -- tailscale status --json)" 1 <<EOF
Access denied: watch IPN bus access denied, must set --operator or be root
EOF
  fi
}

get_operator() {
  # get_operator unavailable | absent | exact NAME | odd: tailscale get operator
  GET_MODE="${1}"
  case "${1}" in
    unavailable)
      fx tailscale "$(key get operator)" 1 <<EOF
tailscale: unknown subcommand: get
EOF
      ;;
    absent) fx tailscale "$(key get operator)" </dev/null ;;
    exact) printf '%s\n' "${2}" | fx tailscale "$(key get operator)" ;;
    odd) printf 'operator: %s (set by admin)\n' "${2}" | fx tailscale "$(key get operator)" ;;
  esac
}

set_ok() {
  fx tailscale "$(key set "--operator=${OP}")" </dev/null
}

set_fails() {
  fx tailscale "$(key set "--operator=${OP}")" 1 <<EOF
failed to connect to local tailscaled
EOF
}

harbor_installed_journal() {
  # The record an earlier run's Tailscale install row leaves: entry 0001
  fixture_entry "${FIX_ROOT}" 0001 tailscale-install tailscale created applied '"absent"' "$(harbor_apt_state "${LOCKED}")"
}

adopted_journal() {
  fixture_entry "${FIX_ROOT}" 0001 tailscale-install tailscale modified applied "$(harbor_apt_state 1.99.0)" "$(harbor_apt_state "${LOCKED}")"
}

# ---- stateful vendor models ------------------------------------------------------

apt-get() {
  # The shim is stateless; the effect a real install has on dpkg is modeled here.
  # After a successful mutating call, dpkg reports the AFTER version.
  command apt-get ${1+"$@"} || return "$?"
  if [ "${1}" = install ] && [ -n "${AFTER}" ]; then
    dpkg_installed "${AFTER}"
  fi
}

tailscale() {
  # After a successful tailscale set --operator=NAME the daemon grants NAME the
  # unprivileged read and, where tailscale get operator exists, prints NAME. With
  # SET_EFFECT=none the set exits 0 and changes nothing, the shape of a daemon
  # that accepted the command and did not honour it.
  command tailscale ${1+"$@"} || return "$?"
  if [ "${1}" = set ] && [ "${SET_EFFECT}" = full ]; then
    probe granted
    [ "${GET_MODE}" = unavailable ] || get_operator exact "${2#--operator=}"
  fi
}

# ---- assertions -------------------------------------------------------------------

calls_of() {
  # calls_of NAME [ARG]: how many times shim NAME ran, optionally with first ARG
  [ -e "${HARBOR_SHIM_LOG}" ] || {
    printf '0\n'
    return 0
  }
  if [ -n "${2:-}" ]; then
    grep -c "^${1}${TAB}${2}" "${HARBOR_SHIM_LOG}" || true
  else
    grep -c "^${1}${TAB}" "${HARBOR_SHIM_LOG}" || true
  fi
}

mutating_calls() {
  # Every call that changes the node: apt-get install and tailscale set
  local n
  n="$(calls_of apt-get "install${TAB}")"
  n=$((n + $(calls_of tailscale "set${TAB}")))
  printf '%s\n' "${n}"
}

assert_never_up() {
  # The library never runs tailscale up, or any tailscale login or logout
  if [ -e "${HARBOR_SHIM_LOG}" ]; then
    run grep -c "^tailscale${TAB}\(up\|login\|logout\)" "${HARBOR_SHIM_LOG}"
    assert_output 0
  fi
}

assert_entry_field() {
  # assert_entry_field ENTRY FIELD EXPECTED ACTUAL: one field of one journal entry,
  # reported the way bats-assert reports assert_equal. Every field is checked on its
  # own and names itself, because the whole point of these assertions is the shape of
  # the entry the row wrote, and a single bare test over all six fields reports only
  # that the entry is wrong -- never which of ownership, phase, pre_state, or
  # post_state disagreed, nor what the row actually wrote there. The states are JSON
  # fragments that differ from each other by a few characters, so the actual value has
  # to be printed beside the expected one for the failure to be readable at all.
  if [ "${4}" != "${3}" ]; then
    batslib_print_kv_single_or_multi 8 \
      'entry' "${1}" \
      'field' "${2}" \
      'expected' "${3}" \
      'actual' "${4}" \
      | batslib_decorate 'journal entry field differs' \
      | fail
  fi
}

assert_entry() {
  # assert_entry SEQ OP TARGET OWNERSHIP PHASE PRE POST: the whole of journal entry
  # SEQ, field by field, in the argument order tests/unit/lib/ssh.bats uses. The
  # target is asserted like every other field: a tailscale-operator entry's target is
  # the operator account the grant names, and a tailscale-install entry's is the
  # package, and an entry that recorded the right states against the wrong target
  # would still be the wrong entry.
  local entry="${1}-${2}.json"
  if [ ! -f "${FIX_ROOT}/journal/${entry}" ]; then
    batslib_print_kv_single_or_multi 8 \
      'expected' "${entry}" \
      'journal' "$(ls -1 "${FIX_ROOT}/journal" 2>/dev/null || printf '(no journal directory)')" \
      | batslib_decorate 'journal entry missing' \
      | fail
    return 1
  fi
  assert_entry_field "${entry}" target "\"${3}\"" "$(entry_raw "${FIX_ROOT}" "${1}" target)"
  assert_entry_field "${entry}" ownership "\"${4}\"" "$(entry_raw "${FIX_ROOT}" "${1}" ownership)"
  assert_entry_field "${entry}" phase "${5}" "$(entry_phase "${FIX_ROOT}" "${1}")"
  assert_entry_field "${entry}" pre_state "${6}" "$(entry_raw "${FIX_ROOT}" "${1}" pre_state)"
  assert_entry_field "${entry}" post_state "${7}" "$(entry_raw "${FIX_ROOT}" "${1}" post_state)"
}

entry_count() {
  find "${FIX_ROOT}/journal" -name '[0-9][0-9][0-9][0-9]-*.json' | wc -l | tr -d ' '
}

clear_log() {
  rm -f "${HARBOR_SHIM_LOG}"
}

# ---- install row: absent ---------------------------------------------------------

@test "tailscale install: absent installs the locked version from the vendor channel and journals created" {
  dpkg_absent
  curl_ok
  apt_ok "${LOCKED}"
  AFTER="${LOCKED}"
  run harbor_tailscale_install "${FIX_ROOT}" "${ETC}"
  assert_success
  assert_output --partial "installed tailscale ${LOCKED} from the ${CHANNEL} channel"
  # The vendor keyring and source went under the fixture configuration root, each
  # its own file entry, and the source line names the keyring beside it.
  assert_entry 0001 file "${KEYRING}" created applied '"absent"' "$(harbor_observe_file "${KEYRING}")"
  assert_entry 0002 file "${SOURCE}" created applied '"absent"' "$(harbor_observe_file "${SOURCE}")"
  [ "$(cat "${KEYRING}")" = "fixture keyring bytes" ]
  [ "$(cat "${SOURCE}")" = "deb [signed-by=${KEYRING}] https://pkgs.tailscale.com/stable/ubuntu noble main" ]
  assert_entry 0003 tailscale-install tailscale created applied '"absent"' "$(harbor_apt_state "${LOCKED}")"
  [ "$(entry_count)" = 3 ]
  # Fetch, refresh, simulate, then the one mutating call, in that order, and a
  # fresh install never asks for a downgrade.
  run sed -n 's/\t/ /gp' "${HARBOR_SHIM_LOG}"
  assert_line --index 0 "dpkg-query -s tailscale"
  assert_line --index 1 "curl -fsSL --proto =https --tlsv1.2 ${KEYRING_URL}"
  assert_line --index 2 "apt-get update"
  assert_line --index 3 "apt-get -s install tailscale=${LOCKED}"
  assert_line --index 4 "apt-get install -y tailscale=${LOCKED}"
  assert_line --index 5 "dpkg-query -s tailscale"
  [ "$(mutating_calls)" = 1 ]
  # The keyring's temporary copy under the state root is gone.
  run ls -A "${FIX_ROOT}"
  refute_output --partial ".tmp.tailscale"
}

@test "tailscale install: sets ownership and version for the state record" {
  dpkg_absent
  curl_ok
  apt_ok "${LOCKED}"
  AFTER="${LOCKED}"
  harbor_tailscale_install "${FIX_ROOT}" "${ETC}" 2>/dev/null
  [ "${HARBOR_TAILSCALE_OWNERSHIP}" = harbor-installed ]
  [ "${HARBOR_TAILSCALE_VERSION}" = "${LOCKED}" ]
  [ "$(harbor_tailscale_ownership "${FIX_ROOT}")" = harbor-installed ]
}

@test "tailscale install: a second run journals observed and makes no mutating call" {
  dpkg_absent
  curl_ok
  apt_ok "${LOCKED}"
  AFTER="${LOCKED}"
  run harbor_tailscale_install "${FIX_ROOT}" "${ETC}"
  assert_success
  clear_log
  run harbor_tailscale_install "${FIX_ROOT}" "${ETC}"
  assert_success
  assert_entry 0004 tailscale-install tailscale observed applied "$(harbor_apt_state "${LOCKED}")" "$(harbor_apt_state "${LOCKED}")"
  [ "$(entry_count)" = 4 ]
  [ "$(mutating_calls)" = 0 ]
  [ "$(calls_of curl)" = 0 ]
  [ "$(calls_of apt-get)" = 0 ]
  [ "$(harbor_tailscale_ownership "${FIX_ROOT}")" = harbor-installed ]
}

# ---- install row: pre-existing --------------------------------------------------

@test "tailscale install: pre-existing at the locked version is journaled observed and left alone" {
  dpkg_installed "${LOCKED}"
  run harbor_tailscale_install "${FIX_ROOT}" "${ETC}"
  assert_success
  assert_entry 0001 tailscale-install tailscale observed applied "$(harbor_apt_state "${LOCKED}")" "$(harbor_apt_state "${LOCKED}")"
  [ "$(entry_count)" = 1 ]
  [ "$(mutating_calls)" = 0 ]
  [ "$(calls_of curl)" = 0 ]
  [ ! -e "${ETC}" ]
  [ "$(harbor_tailscale_ownership "${FIX_ROOT}")" = pre-existing ]
}

@test "tailscale install: pre-existing drift without --adopt-tailscale is observed, degraded, and unchanged" {
  dpkg_installed 1.90.1
  run harbor_tailscale_install "${FIX_ROOT}" "${ETC}"
  assert_failure 1
  assert_output --partial "tailscale.drift: degraded:"
  assert_output --partial "tailscale 1.90.1 is installed and Harbor did not install it"
  assert_output --partial "pins ${LOCKED}"
  assert_output --partial "--adopt-tailscale"
  assert_entry 0001 tailscale-install tailscale observed applied "$(harbor_apt_state 1.90.1)" "$(harbor_apt_state 1.90.1)"
  [ "$(entry_count)" = 1 ]
  [ "$(mutating_calls)" = 0 ]
  [ "$(calls_of curl)" = 0 ]
  [ "$(calls_of apt-get)" = 0 ]
  [ ! -e "${ETC}" ]
}

@test "tailscale install: --adopt-tailscale installs the locked version over drift and journals modified with the prior version" {
  dpkg_installed 1.90.1
  curl_ok
  apt_ok "${LOCKED}" 1.90.1
  AFTER="${LOCKED}"
  run harbor_tailscale_install "${FIX_ROOT}" "${ETC}" --adopt-tailscale
  assert_success
  assert_output --partial "installed tailscale ${LOCKED} over 1.90.1 (adopted)"
  assert_entry 0001 file "${KEYRING}" created applied '"absent"' "$(harbor_observe_file "${KEYRING}")"
  assert_entry 0002 file "${SOURCE}" created applied '"absent"' "$(harbor_observe_file "${SOURCE}")"
  assert_entry 0003 tailscale-install tailscale modified applied "$(harbor_apt_state 1.90.1)" "$(harbor_apt_state "${LOCKED}")"
  [ "$(entry_count)" = 3 ]
  # A pre-existing installation may be newer than the pin, so the adoption allows
  # a downgrade, in the simulation and in the install alike.
  run sed -n 's/\t/ /gp' "${HARBOR_SHIM_LOG}"
  assert_line "apt-get -s install --allow-downgrades tailscale=${LOCKED}"
  assert_line "apt-get install -y --allow-downgrades tailscale=${LOCKED}"
  [ "$(mutating_calls)" = 1 ]
  [ "$(harbor_tailscale_ownership "${FIX_ROOT}")" = adopted ]
}

@test "tailscale install: an adopted installation converges to a moved lock without the flag" {
  adopted_journal
  dpkg_installed 1.99.0
  curl_ok
  apt_ok "${LOCKED}" 1.99.0
  AFTER="${LOCKED}"
  run harbor_tailscale_install "${FIX_ROOT}" "${ETC}"
  assert_success
  assert_entry 0004 tailscale-install tailscale modified applied "$(harbor_apt_state 1.99.0)" "$(harbor_apt_state "${LOCKED}")"
  [ "$(mutating_calls)" = 1 ]
  [ "$(harbor_tailscale_ownership "${FIX_ROOT}")" = adopted ]
}

@test "tailscale install: a Harbor-installed tailscale behind a moved lock is reinstalled as modified and stays harbor-installed" {
  fixture_entry "${FIX_ROOT}" 0001 tailscale-install tailscale created applied '"absent"' "$(harbor_apt_state 1.99.0)"
  dpkg_installed 1.99.0
  curl_ok
  apt_ok "${LOCKED}" 1.99.0
  AFTER="${LOCKED}"
  run harbor_tailscale_install "${FIX_ROOT}" "${ETC}"
  assert_success
  assert_output --partial "installed tailscale ${LOCKED} over 1.99.0 (harbor-installed)"
  assert_entry 0004 tailscale-install tailscale modified applied "$(harbor_apt_state 1.99.0)" "$(harbor_apt_state "${LOCKED}")"
  [ "$(harbor_tailscale_ownership "${FIX_ROOT}")" = harbor-installed ]
  # A lock that moved its pin backwards asks Harbor to step its own installation
  # down, which apt refuses without the flag, so the flag is not the adoption's
  # alone: every install over a version already present carries it.
  run sed -n 's/\t/ /gp' "${HARBOR_SHIM_LOG}"
  assert_line "apt-get -s install --allow-downgrades tailscale=${LOCKED}"
  assert_line "apt-get install -y --allow-downgrades tailscale=${LOCKED}"
}

# ---- install row: failures -------------------------------------------------------

@test "tailscale install: an unavailable pinned version fails 3 naming versions.lock before any entry or mutation" {
  dpkg_absent
  curl_ok
  fx apt-get update </dev/null
  apt_sim_fails "${LOCKED}"
  run harbor_tailscale_install "${FIX_ROOT}" "${ETC}"
  assert_failure 3
  assert_output --partial "tailscale.version_unavailable:"
  assert_output --partial "tailscale_version ${LOCKED} in ${HARBOR_ROOT}/versions.lock is not installable"
  assert_output --partial "Version '${LOCKED}' for 'tailscale' was not found"
  # The vendor source was written (it is what the simulation needed); the
  # tailscale-install entry was never prepared.
  [ "$(entry_count)" = 2 ]
  [ ! -e "${FIX_ROOT}/journal/0003-tailscale-install.json" ]
  [ "$(mutating_calls)" = 0 ]
}

@test "tailscale install: a simulation that names another version fails 3 naming versions.lock" {
  dpkg_absent
  curl_ok
  apt_ok 1.90.1
  # The simulation fixture for the locked pin answers with the wrong candidate.
  cp "${FX}/apt-get/healthy/$(key -s install tailscale=1.90.1).out" "${FX}/apt-get/healthy/$(key -s install "tailscale=${LOCKED}").out"
  run harbor_tailscale_install "${FIX_ROOT}" "${ETC}"
  assert_failure 3
  assert_output --partial "would install '1.90.1', not tailscale_version ${LOCKED} of ${HARBOR_ROOT}/versions.lock"
  [ "$(mutating_calls)" = 0 ]
  [ ! -e "${FIX_ROOT}/journal/0003-tailscale-install.json" ]
}

@test "tailscale install: a lock without tailscale_version fails 3 naming the lock file and touches nothing" {
  local lock="${BATS_TEST_TMPDIR}/versions.lock"
  sed 's/^tailscale_version=.*/tailscale_version=/' "${HARBOR_ROOT}/versions.lock" >"${lock}"
  harbor_versions_load "${lock}"
  dpkg_absent
  run harbor_tailscale_install "${FIX_ROOT}" "${ETC}"
  assert_failure 3
  assert_output --partial "versions.unset: ${lock}: tailscale_version is not pinned yet"
  [ "$(entry_count)" = 0 ]
  [ ! -e "${HARBOR_SHIM_LOG}" ]
  [ ! -e "${ETC}" ]
}

@test "tailscale install: a malformed tailscale_apt_channel fails 3 naming the lock file and touches nothing" {
  local lock="${BATS_TEST_TMPDIR}/versions.lock"
  sed 's|^tailscale_apt_channel=.*|tailscale_apt_channel=stable-noble|' "${HARBOR_ROOT}/versions.lock" >"${lock}"
  harbor_versions_load "${lock}"
  dpkg_absent
  run harbor_tailscale_install "${FIX_ROOT}" "${ETC}"
  assert_failure 3
  assert_output --partial "tailscale.channel: ${lock}: tailscale_apt_channel 'stable-noble' is not <track>/<os>/<codename>"
  [ "$(entry_count)" = 0 ]
  [ ! -e "${HARBOR_SHIM_LOG}" ]
  [ ! -e "${ETC}" ]
}

@test "tailscale install: a failed keyring download fails 2 with nothing written or journaled" {
  dpkg_absent
  curl_fails
  run harbor_tailscale_install "${FIX_ROOT}" "${ETC}"
  assert_failure 2
  assert_output --partial "tailscale.keyring: fetching the vendor keyring ${KEYRING_URL} failed (curl exit 22)"
  [ "$(entry_count)" = 0 ]
  [ ! -e "${KEYRING}" ]
  [ ! -e "${SOURCE}" ]
  [ "$(calls_of apt-get)" = 0 ]
  run ls -A "${FIX_ROOT}"
  refute_output --partial ".tmp.tailscale"
}

@test "tailscale install: a failed apt-get update fails 2 before the pin is simulated" {
  dpkg_absent
  curl_ok
  apt_ok "${LOCKED}"
  fx apt-get update 100 <<EOF
Err:1 https://pkgs.tailscale.com/stable/ubuntu noble InRelease
E: Some index files failed to download.
EOF
  run harbor_tailscale_install "${FIX_ROOT}" "${ETC}"
  assert_failure 2
  assert_output --partial "tailscale.apt_update: apt-get update failed (exit 100)"
  [ "$(calls_of apt-get "-s")" = 0 ]
  [ "$(mutating_calls)" = 0 ]
  [ ! -e "${FIX_ROOT}/journal/0003-tailscale-install.json" ]
}

@test "tailscale install: a failed install leaves the entry prepared and recovery decides it by dpkg" {
  dpkg_absent
  curl_ok
  apt_ok "${LOCKED}"
  fx apt-get "$(key install -y "tailscale=${LOCKED}")" 100 <<EOF
E: Unable to fetch some archives
EOF
  run harbor_tailscale_install "${FIX_ROOT}" "${ETC}"
  assert_failure 2
  assert_output --partial "tailscale.install: apt-get install -y tailscale=${LOCKED} failed (exit 100)"
  assert_output --partial "0003-tailscale-install.json stays prepared"
  assert_entry 0003 tailscale-install tailscale created prepared '"absent"' "$(harbor_apt_state "${LOCKED}")"
  # Package still absent: reverted.
  run harbor_journal_recover "${FIX_ROOT}"
  assert_success
  [ "$(entry_phase "${FIX_ROOT}" 0003)" = reverted ]
  # Package at the locked version after the crash: applied.
  harbor_journal_set_phase "${FIX_ROOT}/journal/0003-tailscale-install.json" prepared
  dpkg_installed "${LOCKED}"
  run harbor_journal_recover "${FIX_ROOT}"
  assert_success
  [ "$(entry_phase "${FIX_ROOT}" 0003)" = applied ]
  # Package at some other version: neither state, undecidable, blocks the rerun.
  harbor_journal_set_phase "${FIX_ROOT}/journal/0003-tailscale-install.json" prepared
  dpkg_installed 1.90.1
  run harbor_journal_recover "${FIX_ROOT}"
  assert_failure 2
  assert_output --partial "journal.undecidable: prepared entries 0003"
  [ "$(entry_phase "${FIX_ROOT}" 0003)" = prepared ]
}

@test "tailscale install: an install that exits 0 without dpkg reporting the lock fails 2 with the entry prepared" {
  dpkg_absent
  curl_ok
  apt_ok "${LOCKED}"
  AFTER=1.90.1
  run harbor_tailscale_install "${FIX_ROOT}" "${ETC}"
  assert_failure 2
  assert_output --partial "tailscale.verify: apt-get install -y reported success but dpkg does not report tailscale at ${LOCKED}"
  [ "$(entry_phase "${FIX_ROOT}" 0003)" = prepared ]
}

@test "tailscale install: an unknown flag is a usage error" {
  dpkg_absent
  run harbor_tailscale_install "${FIX_ROOT}" "${ETC}" --adopt-firewall
  assert_failure 3
  assert_output --partial "usage: harbor_tailscale_install"
  [ ! -e "${HARBOR_SHIM_LOG}" ]
}

# ---- operator row: Harbor-installed ---------------------------------------------

@test "tailscale operator: Harbor-installed grants the operator once, journaled created from absent, and touches nothing else" {
  harbor_installed_journal
  backend Running
  probe denied
  get_operator absent
  set_ok
  run harbor_tailscale_operator "${FIX_ROOT}" "${OP}"
  assert_success
  assert_output --partial "granted ${OP} the Tailscale operator role (tailscale set --operator=${OP})"
  assert_entry 0002 tailscale-operator "${OP}" created applied '"absent"' "\"${OP}\""
  [ "$(entry_count)" = 2 ]
  # Root's read gates the probe, the probe precedes the get, and the one set is
  # the only mutation; then the section 6.1 check reads the node again.
  run sed -n 's/\t/ /gp' "${HARBOR_SHIM_LOG}"
  assert_line --index 0 "tailscale status --json"
  assert_line --index 1 "runuser -u ${OP} -- tailscale status --json"
  assert_line --index 2 "tailscale get operator"
  assert_line --index 3 "tailscale set --operator=${OP}"
  assert_line --index 4 "tailscale status --json"
  assert_line --index 5 "runuser -u ${OP} -- tailscale status --json"
  assert_line --index 6 "tailscale get operator"
  [ "$(mutating_calls)" = 1 ]
  [ "$(calls_of tailscale "set${TAB}--operator=${OP}")" = 1 ]
  assert_never_up
  # Running is silent.
  refute_output --partial "needs_tailscale_login"
  refute_output --partial "bring it up"
}

@test "tailscale operator: a second run finds the grant and journals observed with no set" {
  harbor_installed_journal
  backend Running
  probe denied
  get_operator absent
  set_ok
  run harbor_tailscale_operator "${FIX_ROOT}" "${OP}"
  assert_success
  clear_log
  run harbor_tailscale_operator "${FIX_ROOT}" "${OP}"
  assert_success
  assert_entry 0003 tailscale-operator "${OP}" observed applied "\"${OP}\"" "\"${OP}\""
  [ "$(entry_count)" = 3 ]
  [ "$(mutating_calls)" = 0 ]
  assert_never_up
}

@test "tailscale operator: Harbor-installed with another exact operator journals modified with the prior value" {
  harbor_installed_journal
  backend Running
  probe denied
  get_operator exact admin
  set_ok
  run harbor_tailscale_operator "${FIX_ROOT}" "${OP}"
  assert_success
  assert_entry 0002 tailscale-operator "${OP}" modified applied '"admin"' "\"${OP}\""
  [ "$(mutating_calls)" = 1 ]
}

@test "tailscale operator: without tailscale get operator the grant records the probe and the rerun trusts the record" {
  harbor_installed_journal
  backend Running
  probe denied
  get_operator unavailable
  set_ok
  run harbor_tailscale_operator "${FIX_ROOT}" "${OP}"
  assert_success
  assert_entry 0002 tailscale-operator "${OP}" created applied '"absent"' '{"probe":"granted"}'
  [ "$(mutating_calls)" = 1 ]
  clear_log
  # The rerun changes nothing, so what it has to say is a harbor_log line and not a
  # harbor_msg one: an idempotent rerun stays quiet on stderr, exactly as the "nothing
  # to do" of lib/user.sh does. HARBOR_VERBOSE=1 is how a test reads such a line.
  HARBOR_VERBOSE=1 run harbor_tailscale_operator "${FIX_ROOT}" "${OP}"
  assert_success
  assert_output --partial "nothing to do"
  assert_entry 0003 tailscale-operator "${OP}" observed applied '{"probe":"granted"}' '{"probe":"granted"}'
  [ "$(mutating_calls)" = 0 ]
  assert_never_up
}

@test "tailscale operator: without tailscale get operator and no record, a passing probe alone does not prove the grant" {
  # A daemon that lets any local user read status does not distinguish the
  # operator; with no earlier grant recorded, Harbor makes it.
  harbor_installed_journal
  backend Running
  probe granted
  get_operator unavailable
  set_ok
  run harbor_tailscale_operator "${FIX_ROOT}" "${OP}"
  assert_success
  assert_entry 0002 tailscale-operator "${OP}" created applied '"absent"' '{"probe":"granted"}'
  [ "$(mutating_calls)" = 1 ]
}

@test "tailscale operator: an exact value naming the operator with a failing probe is a contradiction, exit 2" {
  harbor_installed_journal
  backend Running
  probe denied
  get_operator exact "${OP}"
  run harbor_tailscale_operator "${FIX_ROOT}" "${OP}"
  assert_failure 2
  assert_output --partial "tailscale.operator_contradiction:"
  [ "$(entry_count)" = 1 ]
  [ "$(mutating_calls)" = 0 ]
}

# ---- operator row: pre-existing and adopted ------------------------------------

@test "tailscale operator: pre-existing with a passing probe is journaled observed with the probe state" {
  backend Running
  probe granted
  get_operator unavailable
  # Nothing is mutated here either, so the row records the reading through harbor_log
  # and prints nothing to the operator; HARBOR_VERBOSE=1 makes that line readable.
  HARBOR_VERBOSE=1 run harbor_tailscale_operator "${FIX_ROOT}" "${OP}"
  assert_success
  assert_output --partial "reads tailscaled's status without sudo on a pre-existing installation"
  assert_entry 0001 tailscale-operator "${OP}" observed applied '{"probe":"granted"}' '{"probe":"granted"}'
  [ "$(entry_count)" = 1 ]
  [ "$(mutating_calls)" = 0 ]
  assert_never_up
}

@test "tailscale operator: pre-existing naming the operator exactly is journaled observed with the value" {
  backend Running
  probe granted
  get_operator exact "${OP}"
  run harbor_tailscale_operator "${FIX_ROOT}" "${OP}"
  assert_success
  assert_entry 0001 tailscale-operator "${OP}" observed applied "\"${OP}\"" "\"${OP}\""
  [ "$(mutating_calls)" = 0 ]
}

@test "tailscale operator: pre-existing, failing probe, exact prior value, --adopt-tailscale: modified with the prior value" {
  backend Running
  probe denied
  get_operator exact admin
  set_ok
  run harbor_tailscale_operator "${FIX_ROOT}" "${OP}" --adopt-tailscale
  assert_success
  assert_entry 0001 tailscale-operator "${OP}" modified applied '"admin"' "\"${OP}\""
  [ "$(mutating_calls)" = 1 ]
  assert_never_up
}

@test "tailscale operator: pre-existing, failing probe, exact prior value, no flag: precondition, return 3, nothing changed" {
  backend Running
  probe denied
  get_operator exact admin
  run harbor_tailscale_operator "${FIX_ROOT}" "${OP}"
  assert_failure 3
  assert_output --partial "tailscale.operator: precondition:"
  assert_output --partial "whose operator is admin"
  assert_output --partial "sudo tailscale set --operator=${OP}"
  assert_output --partial "--adopt-tailscale"
  [ "$(entry_count)" = 0 ]
  [ "$(mutating_calls)" = 0 ]
  assert_never_up
}

@test "tailscale operator: pre-existing, failing probe, no exact value: precondition even with --adopt-tailscale" {
  backend Running
  probe denied
  get_operator absent
  run harbor_tailscale_operator "${FIX_ROOT}" "${OP}" --adopt-tailscale
  assert_failure 3
  assert_output --partial "prints no exact prior operator value"
  assert_output --partial "sudo tailscale set --operator=${OP}"
  [ "$(entry_count)" = 0 ]
  [ "$(mutating_calls)" = 0 ]
  # The same without the command at all, and with output that is not one name.
  get_operator unavailable
  run harbor_tailscale_operator "${FIX_ROOT}" "${OP}" --adopt-tailscale
  assert_failure 3
  assert_output --partial "sudo tailscale set --operator=${OP}"
  get_operator odd admin
  run harbor_tailscale_operator "${FIX_ROOT}" "${OP}" --adopt-tailscale
  assert_failure 3
  assert_output --partial "sudo tailscale set --operator=${OP}"
  [ "$(entry_count)" = 0 ]
  [ "$(mutating_calls)" = 0 ]
}

@test "tailscale operator: after the owner runs the precondition command the rerun journals observed" {
  backend Running
  probe denied
  get_operator absent
  run harbor_tailscale_operator "${FIX_ROOT}" "${OP}"
  assert_failure 3
  # The owner ran sudo tailscale set --operator=harbor outside Harbor.
  probe granted
  get_operator exact "${OP}"
  run harbor_tailscale_operator "${FIX_ROOT}" "${OP}"
  assert_success
  assert_entry 0001 tailscale-operator "${OP}" observed applied "\"${OP}\"" "\"${OP}\""
  [ "$(mutating_calls)" = 0 ]
}

@test "tailscale operator: an adopted installation is treated as the owner's, not Harbor's" {
  adopted_journal
  backend Running
  probe denied
  get_operator absent
  run harbor_tailscale_operator "${FIX_ROOT}" "${OP}" --adopt-tailscale
  assert_failure 3
  assert_output --partial "on this adopted Tailscale installation"
  [ "$(entry_count)" = 1 ]
  probe granted
  run harbor_tailscale_operator "${FIX_ROOT}" "${OP}"
  assert_success
  assert_entry 0002 tailscale-operator "${OP}" observed applied '"absent"' '"absent"'
  [ "$(mutating_calls)" = 0 ]
}

# ---- operator row: closing report ------------------------------------------------

@test "tailscale operator: BackendState Running closes silently" {
  harbor_installed_journal
  backend Running
  probe granted
  get_operator exact "${OP}"
  harbor_tailscale_operator "${FIX_ROOT}" "${OP}" 2>"${BATS_TEST_TMPDIR}/err"
  [ "${HARBOR_TAILSCALE_REPORT}" = "" ]
  [ "${HARBOR_TAILSCALE_BACKEND_STATE}" = Running ]
  run cat "${BATS_TEST_TMPDIR}/err"
  refute_output --partial "needs_tailscale_login"
  refute_output --partial "not_running"
}

@test "tailscale operator: not running and Harbor-installed reports needs_tailscale_login naming harbor auth tailscale" {
  harbor_installed_journal
  backend NeedsLogin
  probe denied
  get_operator absent
  set_ok
  harbor_tailscale_operator "${FIX_ROOT}" "${OP}" 2>"${BATS_TEST_TMPDIR}/err"
  [ "${HARBOR_TAILSCALE_REPORT}" = needs_tailscale_login ]
  run cat "${BATS_TEST_TMPDIR}/err"
  assert_output --partial "tailscale.needs_tailscale_login: BackendState is NeedsLogin"
  assert_output --partial "harbor auth tailscale"
  assert_never_up
}

@test "tailscale operator: not running and pre-existing prints that the owner brings it up, whichever way the row went" {
  backend Stopped
  probe granted
  get_operator unavailable
  run harbor_tailscale_operator "${FIX_ROOT}" "${OP}"
  assert_success
  assert_output --partial "tailscale.not_running: BackendState is Stopped on a Tailscale installation Harbor did not create (pre-existing)"
  assert_output --partial "bring it up yourself with your existing preferences"
  refute_output --partial "needs_tailscale_login"
  # The report closes the precondition path too.
  probe denied
  run harbor_tailscale_operator "${FIX_ROOT}" "${OP}"
  assert_failure 3
  assert_output --partial "sudo tailscale set --operator=${OP}"
  assert_output --partial "bring it up yourself"
  assert_never_up
}

# ---- operator row: failures and recovery ----------------------------------------

@test "tailscale operator: a daemon that cannot answer root fails 2 before the probe" {
  harbor_installed_journal
  status_fails
  run harbor_tailscale_operator "${FIX_ROOT}" "${OP}"
  assert_failure 2
  assert_output --partial "tailscale.status: tailscale status --json failed (exit 1)"
  [ "$(calls_of runuser)" = 0 ]
  [ "$(entry_count)" = 1 ]
  # Status without a BackendState is not a status this row can read either.
  fx tailscale "$(key status --json)" <<EOF
{"Version": "${LOCKED}-fixture"}
EOF
  run harbor_tailscale_operator "${FIX_ROOT}" "${OP}"
  assert_failure 2
  assert_output --partial "printed no BackendState"
  [ "$(calls_of runuser)" = 0 ]
}

@test "tailscale operator: a failed set leaves the entry prepared" {
  harbor_installed_journal
  backend Running
  probe denied
  get_operator absent
  set_fails
  run harbor_tailscale_operator "${FIX_ROOT}" "${OP}"
  assert_failure 2
  assert_output --partial "tailscale.operator_set: tailscale set --operator=${OP} failed (exit 1)"
  assert_output --partial "0002-tailscale-operator.json stays prepared"
  assert_entry 0002 tailscale-operator "${OP}" created prepared '"absent"' "\"${OP}\""
}

@test "tailscale operator: a set that exits 0 without granting the read fails 2 with the entry prepared" {
  harbor_installed_journal
  backend Running
  probe denied
  get_operator absent
  set_ok
  SET_EFFECT=none
  run harbor_tailscale_operator "${FIX_ROOT}" "${OP}"
  assert_failure 2
  assert_output --partial "tailscale.operator_verify:"
  assert_output --partial "the node now observes \"absent\", not \"${OP}\""
  [ "$(entry_phase "${FIX_ROOT}" 0002)" = prepared ]
}

@test "tailscale operator: recovery decides a prepared tailscale-operator entry by the same reading" {
  fixture_entry "${FIX_ROOT}" 0001 tailscale-operator "${OP}" created prepared '"absent"' "\"${OP}\""
  backend Running
  probe granted
  get_operator exact "${OP}"
  run harbor_journal_recover "${FIX_ROOT}"
  assert_success
  [ "$(entry_phase "${FIX_ROOT}" 0001)" = applied ]
  harbor_journal_set_phase "${FIX_ROOT}/journal/0001-tailscale-operator.json" prepared
  probe denied
  get_operator absent
  run harbor_journal_recover "${FIX_ROOT}"
  assert_success
  [ "$(entry_phase "${FIX_ROOT}" 0001)" = reverted ]
  # Without tailscale get operator and with the probe failing, the reading is
  # {"probe":"denied"}, neither state: undecidable, for harbor journal resolve.
  harbor_journal_set_phase "${FIX_ROOT}/journal/0001-tailscale-operator.json" prepared
  get_operator unavailable
  run harbor_journal_recover "${FIX_ROOT}"
  assert_failure 2
  assert_output --partial "journal.undecidable: prepared entries 0001"
  assert_output --partial 'observed:   {"probe":"denied"}'
  # And with the probe passing on such a release, the recorded probe state applies.
  fixture_entry "${FIX_ROOT}" 0002 tailscale-operator "${OP}" created prepared '"absent"' '{"probe":"granted"}'
  harbor_journal_set_phase "${FIX_ROOT}/journal/0001-tailscale-operator.json" reverted
  probe granted
  run harbor_journal_recover "${FIX_ROOT}"
  assert_success
  [ "$(entry_phase "${FIX_ROOT}" 0002)" = applied ]
  assert_never_up
}

@test "tailscale operator: an operator name that is not one word is refused before any vendor call" {
  harbor_installed_journal
  run harbor_tailscale_operator "${FIX_ROOT}" "harbor --operator=root"
  assert_failure 3
  assert_output --partial "tailscale.operator_name:"
  [ ! -e "${HARBOR_SHIM_LOG}" ]
  run harbor_tailscale_operator "${FIX_ROOT}" "-harbor"
  assert_failure 3
  [ ! -e "${HARBOR_SHIM_LOG}" ]
  [ "$(entry_count)" = 1 ]
}

@test "tailscale operator: an unknown flag is a usage error" {
  run harbor_tailscale_operator "${FIX_ROOT}" "${OP}" --adopt-firewall
  assert_failure 3
  assert_output --partial "usage: harbor_tailscale_operator"
  [ ! -e "${HARBOR_SHIM_LOG}" ]
}
