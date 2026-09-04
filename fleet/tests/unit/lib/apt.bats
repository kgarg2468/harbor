#!/usr/bin/env bats
load '../test_helper'

# The six bootstrap packages of design section 5.2. The list belongs to the
# caller; lib/apt.sh names no package of its own.
PACKAGES="git curl ufw jq openssh-server ca-certificates"
TAB="$(printf '\t')"

setup() {
  # lib/apt.sh depends on lib/log.sh, lib/lock.sh, and lib/journal.sh.
  # shellcheck source=lib/log.sh
  . "${HARBOR_ROOT}/lib/log.sh"
  # shellcheck source=lib/lock.sh
  . "${HARBOR_ROOT}/lib/lock.sh"
  # shellcheck source=lib/journal.sh
  . "${HARBOR_ROOT}/lib/journal.sh"
  # shellcheck source=lib/apt.sh
  . "${HARBOR_ROOT}/lib/apt.sh"
  fixture_state_root
  HARBOR_PID="$$"
  REPO_FX="${HARBOR_ROOT}/tests/fixtures/shims"
  FX="${BATS_TEST_TMPDIR}/fx"
  PATH="${HARBOR_ROOT}/tests/shims/bin:${PATH}"
  export PATH
  HARBOR_SHIM_LOG="${BATS_TEST_TMPDIR}/shim.log"
  export HARBOR_SHIM_LOG
  FRONTEND_LOG="${BATS_TEST_TMPDIR}/frontend.log"
  AFTER=""
  # The vendor source lands under a fixture configuration root, never the real
  # system one: the destination root is a parameter of the function under test.
  ETC="${BATS_TEST_TMPDIR}/etc"
  KEYRING="${ETC}/apt/keyrings/tailscale-archive-keyring.gpg"
  SOURCE="${ETC}/apt/sources.list.d/tailscale.list"
  KEYRING_SRC="${BATS_TEST_TMPDIR}/noble.noarmor.gpg"
  printf 'fixture keyring bytes\n' >"${KEYRING_SRC}"
  SOURCE_LINE="deb [signed-by=${KEYRING}] https://pkgs.tailscale.com/stable/ubuntu noble main"
  harbor_lock_acquire "${FIX_ROOT}" operator
}

teardown() {
  harbor_lock_release "${FIX_ROOT}"
}

fixtures() {
  # fixtures DPKG APT [AFTER]: compose a fixture root whose healthy scenario
  # answers dpkg-query from tests/fixtures/shims/dpkg-query/DPKG and apt-get from
  # apt-get/APT. AFTER names the dpkg-query set that answers once the mutating
  # apt-get call has succeeded (see the apt-get function below).
  rm -rf "${FX}"
  mkdir -p "${FX}/dpkg-query" "${FX}/apt-get"
  ln -s "${REPO_FX}/dpkg-query/${1}" "${FX}/dpkg-query/healthy"
  ln -s "${REPO_FX}/apt-get/${2}" "${FX}/apt-get/healthy"
  AFTER="${3:-}"
  HARBOR_SHIM_FIXTURES="${FX}"
  export HARBOR_SHIM_FIXTURES
}

apt-get() {
  # The shim is stateless, so the effect a real install has on dpkg is modeled
  # here: the shim is still what runs and logs, and after a successful mutating
  # call the dpkg-query answers switch to the AFTER set. The frontend log records
  # the DEBIAN_FRONTEND each call saw.
  printf '%s\n' "${DEBIAN_FRONTEND:-unset}" >>"${FRONTEND_LOG}"
  command apt-get ${1+"$@"} || return "$?"
  if [ "${1}" = install ] && [ -n "${AFTER}" ]; then
    rm "${FX}/dpkg-query/healthy"
    ln -s "${REPO_FX}/dpkg-query/${AFTER}" "${FX}/dpkg-query/healthy"
  fi
}

mutating_calls() {
  grep -c "^apt-get${TAB}install${TAB}" "${HARBOR_SHIM_LOG}" || true
}

apt_get_calls() {
  # A shim log that was never created is zero calls of every kind.
  [ -e "${HARBOR_SHIM_LOG}" ] || {
    printf '0\n'
    return 0
  }
  grep -c "^apt-get${TAB}" "${HARBOR_SHIM_LOG}" || true
}

entries_owned() {
  # entries_owned OWNERSHIP: how many journal entries carry that ownership
  grep -l "^  \"ownership\": \"${1}\",\$" "${FIX_ROOT}"/journal/*.json 2>/dev/null | wc -l | tr -d ' '
}

assert_entry() {
  # assert_entry SEQ OP TARGET OWNERSHIP PHASE PRE POST
  assert [ -f "${FIX_ROOT}/journal/${1}-${2}.json" ]
  assert_equal "$(entry_raw "${FIX_ROOT}" "${1}" target)" "\"${3}\""
  assert_equal "$(entry_raw "${FIX_ROOT}" "${1}" ownership)" "\"${4}\""
  assert_equal "$(entry_phase "${FIX_ROOT}" "${1}")" "${5}"
  assert_equal "$(entry_raw "${FIX_ROOT}" "${1}" pre_state)" "${6}"
  assert_equal "$(entry_raw "${FIX_ROOT}" "${1}" post_state)" "${7}"
}

pkg_state() {
  printf '{"version":"%s","method":"apt"}' "${1}"
}

other_version() {
  # other_version PKG VERSION: a dpkg-query fixture set reporting PKG installed at
  # VERSION, the state a crash can leave that matches neither recorded state
  rm -rf "${FX}"
  mkdir -p "${FX}/dpkg-query/healthy"
  printf 'Package: %s\nStatus: install ok installed\nVersion: %s\n' "${1}" "${2}" \
    >"${FX}/dpkg-query/healthy/-s_${1}.out"
  HARBOR_SHIM_FIXTURES="${FX}"
  export HARBOR_SHIM_FIXTURES
}

prepared_package_entry() {
  # prepared_package_entry SEQ PKG VERSION: the entry a crash between apt-get and
  # the applied write leaves behind (design section 3.7)
  fixture_entry "${FIX_ROOT}" "${1}" package "${2}" created prepared '"absent"' "$(pkg_state "${3}")"
}

@test "harbor_apt_installed inspects with dpkg-query only and never appears as a mutating call" {
  fixtures mixed none
  run harbor_apt_installed git
  assert_success
  assert_output ''
  run harbor_apt_installed ufw
  assert_equal "${status}" 1
  assert_output ''
  fixtures none none
  # Removed but not purged: dpkg answers, exit 0, and the package is still absent.
  run harbor_apt_installed ufw
  assert_equal "${status}" 1
  run grep -v "^dpkg-query${TAB}-s${TAB}[a-z-]*\$" "${HARBOR_SHIM_LOG}"
  assert_output ''
  assert_equal "$(apt_get_calls)" 0
  run ls -A "${FIX_ROOT}/journal"
  assert_output ''
}

@test "a dpkg-query failure other than not-installed exits 2 apt.inspect and prepares nothing" {
  fixtures broken none
  run harbor_apt_installed git
  assert_equal "${status}" 2
  assert_output --partial 'apt.inspect'
  run harbor_apt_install "${FIX_ROOT}" git
  assert_equal "${status}" 2
  assert_output --partial 'apt.inspect'
  assert_equal "$(apt_get_calls)" 0
  run ls -A "${FIX_ROOT}/journal"
  assert_output ''
}

@test "all six missing: one noninteractive apt-get install -y, six created entries from absent to the installed version" {
  fixtures none none installed
  run harbor_apt_install "${FIX_ROOT}" ${PACKAGES}
  assert_success
  assert_equal "$(mutating_calls)" 1
  run grep "^apt-get${TAB}" "${HARBOR_SHIM_LOG}"
  assert_line --index 0 "apt-get${TAB}-s${TAB}install${TAB}git${TAB}curl${TAB}ufw${TAB}jq${TAB}openssh-server${TAB}ca-certificates"
  assert_line --index 1 "apt-get${TAB}install${TAB}-y${TAB}git${TAB}curl${TAB}ufw${TAB}jq${TAB}openssh-server${TAB}ca-certificates"
  assert_equal "${#lines[@]}" 2
  run cat "${FRONTEND_LOG}"
  assert_line --index 0 noninteractive
  assert_line --index 1 noninteractive
  assert_equal "${#lines[@]}" 2
  assert_entry 0001 package git created applied '"absent"' "$(pkg_state 1:2.43.0-1ubuntu7.1)"
  assert_entry 0002 package curl created applied '"absent"' "$(pkg_state 8.5.0-2ubuntu10.4)"
  assert_entry 0003 package ufw created applied '"absent"' "$(pkg_state 0.36.2-6)"
  assert_entry 0004 package jq created applied '"absent"' "$(pkg_state 1.7.1-3build1)"
  assert_entry 0005 package openssh-server created applied '"absent"' "$(pkg_state 1:9.6p1-3ubuntu13.5)"
  assert_entry 0006 package ca-certificates created applied '"absent"' "$(pkg_state 20240203)"
  run ls -A "${FIX_ROOT}/journal"
  assert_equal "${#lines[@]}" 6
}

@test "all six present: zero apt-get calls and six observed entries created directly as applied" {
  fixtures installed none
  run harbor_apt_install "${FIX_ROOT}" ${PACKAGES}
  assert_success
  assert_equal "$(apt_get_calls)" 0
  assert [ ! -e "${FRONTEND_LOG}" ]
  assert_entry 0001 package git observed applied "$(pkg_state 1:2.43.0-1ubuntu7.1)" "$(pkg_state 1:2.43.0-1ubuntu7.1)"
  assert_entry 0006 package ca-certificates observed applied "$(pkg_state 20240203)" "$(pkg_state 20240203)"
  assert_equal "$(entries_owned observed)" 6
  assert_equal "$(entries_owned created)" 0
  run ls -A "${FIX_ROOT}/journal"
  assert_equal "${#lines[@]}" 6
}

@test "a mix installs only the missing packages in one call and observes the rest" {
  fixtures mixed mixed installed
  run harbor_apt_install "${FIX_ROOT}" ${PACKAGES}
  assert_success
  run grep "^apt-get${TAB}" "${HARBOR_SHIM_LOG}"
  assert_line --index 0 "apt-get${TAB}-s${TAB}install${TAB}ufw${TAB}jq${TAB}openssh-server"
  assert_line --index 1 "apt-get${TAB}install${TAB}-y${TAB}ufw${TAB}jq${TAB}openssh-server"
  assert_equal "${#lines[@]}" 2
  assert_entry 0001 package git observed applied "$(pkg_state 1:2.43.0-1ubuntu7.1)" "$(pkg_state 1:2.43.0-1ubuntu7.1)"
  assert_entry 0002 package curl observed applied "$(pkg_state 8.5.0-2ubuntu10.4)" "$(pkg_state 8.5.0-2ubuntu10.4)"
  assert_entry 0003 package ca-certificates observed applied "$(pkg_state 20240203)" "$(pkg_state 20240203)"
  assert_entry 0004 package ufw created applied '"absent"' "$(pkg_state 0.36.2-6)"
  assert_entry 0005 package jq created applied '"absent"' "$(pkg_state 1.7.1-3build1)"
  assert_entry 0006 package openssh-server created applied '"absent"' "$(pkg_state 1:9.6p1-3ubuntu13.5)"
  assert_equal "$(entries_owned created)" 3
  assert_equal "$(entries_owned observed)" 3
}

@test "a second run after a successful install makes zero mutating shim calls and writes no created or modified entry" {
  fixtures none none installed
  run harbor_apt_install "${FIX_ROOT}" ${PACKAGES}
  assert_success
  assert_equal "$(entries_owned created)" 6
  : >"${HARBOR_SHIM_LOG}"
  run harbor_apt_install "${FIX_ROOT}" ${PACKAGES}
  assert_success
  assert_equal "$(apt_get_calls)" 0
  run grep -v "^dpkg-query${TAB}-s${TAB}" "${HARBOR_SHIM_LOG}"
  assert_output ''
  assert_equal "$(entries_owned created)" 6
  assert_equal "$(entries_owned modified)" 0
  assert_equal "$(entries_owned observed)" 6
  assert_entry 0007 package git observed applied "$(pkg_state 1:2.43.0-1ubuntu7.1)" "$(pkg_state 1:2.43.0-1ubuntu7.1)"
}

@test "a failing apt-get leaves every entry prepared for recovery and exits 2" {
  fixtures none failing installed
  run harbor_apt_install "${FIX_ROOT}" ${PACKAGES}
  assert_equal "${status}" 2
  assert_output --partial 'apt.install'
  assert_equal "$(mutating_calls)" 1
  assert_entry 0001 package git created prepared '"absent"' "$(pkg_state 1:2.43.0-1ubuntu7.1)"
  assert_entry 0006 package ca-certificates created prepared '"absent"' "$(pkg_state 20240203)"
  run ls -A "${FIX_ROOT}/journal"
  assert_equal "${#lines[@]}" 6
  run grep -l '"phase": "applied"' "${FIX_ROOT}"/journal/*.json
  assert_failure
  assert_output ''
}

@test "recovery decides a prepared package entry: absent is reverted, the recorded version is applied, another version is undecidable" {
  # The crash window of design section 3.7: apt-get ran or did not, and the applied
  # write never happened. Recovery observes the package and decides without asking.
  fixtures none none
  prepared_package_entry 0001 git 1:2.43.0-1ubuntu7.1
  run harbor_journal_recover "${FIX_ROOT}"
  assert_success
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" reverted
  fixtures installed none
  prepared_package_entry 0002 git 1:2.43.0-1ubuntu7.1
  run harbor_journal_recover "${FIX_ROOT}"
  assert_success
  assert_equal "$(entry_phase "${FIX_ROOT}" 0002)" applied
  other_version git 1:2.43.0-1ubuntu7.2
  prepared_package_entry 0003 git 1:2.43.0-1ubuntu7.1
  run --separate-stderr harbor_journal_recover "${FIX_ROOT}"
  assert_equal "${status}" 2
  assert_regex "${stderr}" 'journal entry 0003-package.json is undecidable:'
  assert_regex "${stderr}" 'observed:   \{"version":"1:2\.43\.0-1ubuntu7\.2","method":"apt"\}'
  assert_regex "${stderr}" 'journal.undecidable: prepared entries 0003 cannot be decided'
  assert_equal "$(entry_phase "${FIX_ROOT}" 0003)" prepared
  # Deciding an entry inspects only: no apt-get call and no new entry.
  assert_equal "$(apt_get_calls)" 0
  run ls -A "${FIX_ROOT}/journal"
  assert_equal "${#lines[@]}" 3
}

@test "recovery of a prepared package entry is fail-closed when dpkg-query fails for another reason" {
  fixtures broken none
  prepared_package_entry 0001 git 1:2.43.0-1ubuntu7.1
  run harbor_journal_recover "${FIX_ROOT}"
  assert_equal "${status}" 2
  assert_output --partial 'apt.inspect'
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" prepared
  assert_equal "$(apt_get_calls)" 0
}

@test "a failed candidate lookup exits 2 before any entry is prepared and before any mutating call" {
  fixtures none unknown installed
  run harbor_apt_install "${FIX_ROOT}" ${PACKAGES}
  assert_equal "${status}" 2
  assert_output --partial 'apt.simulate'
  assert_equal "$(mutating_calls)" 0
  run ls -A "${FIX_ROOT}/journal"
  assert_output ''
  run harbor_apt_install "${FIX_ROOT}"
  assert_equal "${status}" 3
  assert_output --partial 'usage'
}

@test "the vendor source writes the keyring and the list 0644 under the destination root it is given, journaled as two created file entries, and a rerun observes them" {
  fixtures installed none
  run harbor_apt_add_vendor_source "${FIX_ROOT}" tailscale "${KEYRING_SRC}" "${SOURCE_LINE}" "${ETC}"
  assert_success
  assert_equal "$(cat "${KEYRING}")" 'fixture keyring bytes'
  assert_equal "$(harbor_stat_mode "${KEYRING}")" 0644
  assert_equal "$(cat "${SOURCE}")" "${SOURCE_LINE}"
  assert_equal "$(harbor_stat_mode "${SOURCE}")" 0644
  assert_equal "$(harbor_stat_mode "$(dirname "${KEYRING}")")" 0755
  assert_equal "$(harbor_stat_mode "$(dirname "${SOURCE}")")" 0755
  # In production the caller passes the system configuration root and root owns
  # both files; here the running user is what ownership records.
  assert_equal "$(harbor_stat_owner "${KEYRING}")" "$(id -un)"
  assert_entry 0001 file "${KEYRING}" created applied '"absent"' "$(harbor_observe_file "${KEYRING}")"
  assert_entry 0002 file "${SOURCE}" created applied '"absent"' "$(harbor_observe_file "${SOURCE}")"
  run ls -A "$(dirname "${KEYRING}")" "$(dirname "${SOURCE}")"
  refute_output --partial '.tmp'
  run harbor_apt_add_vendor_source "${FIX_ROOT}" tailscale "${KEYRING_SRC}" "${SOURCE_LINE}" "${ETC}"
  assert_success
  assert_entry 0003 file "${KEYRING}" observed applied "$(harbor_observe_file "${KEYRING}")" "$(harbor_observe_file "${KEYRING}")"
  assert_entry 0004 file "${SOURCE}" observed applied "$(harbor_observe_file "${SOURCE}")" "$(harbor_observe_file "${SOURCE}")"
  assert_equal "$(entries_owned created)" 2
  assert_equal "$(entries_owned modified)" 0
  assert_equal "$(apt_get_calls)" 0
}

@test "lib/apt.sh hard-codes no system configuration path" {
  run grep -n '/etc' "${HARBOR_ROOT}/lib/apt.sh"
  assert_failure
  assert_output ''
}

@test "a keyring with different content is replaced and journaled modified; a foreign non-regular file at a target exits 3 untouched" {
  fixtures installed none
  mkdir -p "$(dirname "${KEYRING}")"
  printf 'stale key\n' >"${KEYRING}"
  chmod 0600 "${KEYRING}"
  pre="$(harbor_observe_file "${KEYRING}")"
  run harbor_apt_add_vendor_source "${FIX_ROOT}" tailscale "${KEYRING_SRC}" "${SOURCE_LINE}" "${ETC}"
  assert_success
  assert_equal "$(cat "${KEYRING}")" 'fixture keyring bytes'
  assert_equal "$(harbor_stat_mode "${KEYRING}")" 0644
  assert_entry 0001 file "${KEYRING}" modified applied "${pre}" "$(harbor_observe_file "${KEYRING}")"
  assert_entry 0002 file "${SOURCE}" created applied '"absent"' "$(harbor_observe_file "${SOURCE}")"
  rm "${SOURCE}"
  mkdir "${SOURCE}"
  run harbor_apt_add_vendor_source "${FIX_ROOT}" tailscale "${KEYRING_SRC}" "${SOURCE_LINE}" "${ETC}"
  assert_equal "${status}" 3
  assert_output --partial 'apt.foreign'
  assert_output --partial "${SOURCE}"
  assert [ -d "${SOURCE}" ]
  assert_equal "$(cat "${KEYRING}")" 'fixture keyring bytes'
  run ls -A "${FIX_ROOT}/journal"
  assert_equal "${#lines[@]}" 3
  assert_entry 0003 file "${KEYRING}" observed applied "$(harbor_observe_file "${KEYRING}")" "$(harbor_observe_file "${KEYRING}")"
  run ls -A "$(dirname "${SOURCE}")"
  assert_output tailscale.list
}

@test "an unreadable keyring source exits 3, writes nothing under the destination root, and journals nothing" {
  fixtures installed none
  run harbor_apt_add_vendor_source "${FIX_ROOT}" tailscale "${BATS_TEST_TMPDIR}/no-such-key.gpg" "${SOURCE_LINE}" "${ETC}"
  assert_equal "${status}" 3
  assert_output --partial 'apt.keyring_source'
  assert [ ! -e "${ETC}" ]
  run ls -A "${FIX_ROOT}/journal"
  assert_output ''
  run harbor_apt_add_vendor_source "${FIX_ROOT}" tailscale "${KEYRING_SRC}" "${SOURCE_LINE}"
  assert_equal "${status}" 3
  assert_output --partial 'usage'
  assert [ ! -e "${ETC}" ]
}
