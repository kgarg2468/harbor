#!/usr/bin/env bats
load '../test_helper'

# node/bootstrap.sh at fixture paths (design section 7). Nothing here touches
# /etc, /var/lib, /usr/local, /opt, the real operator state root, or sudo: the
# script reads every production path, the machine architecture, whether the caller
# is root, and the exec itself from HARBOR_BOOTSTRAP_FIXTURE_* variables it consults
# only when id -u is not 0, exactly as lib/checkout.sh, lib/entrypoint.sh, and
# lib/ssh.sh consult their own stand-ins, so no root code path can ever see one.

setup() {
  # The tree hash of a fixture release is needed to seed a harbor-install entry, and
  # that hash must be the one the journal observer computes, so this file sources the
  # libraries lib/release.sh needs rather than harbor_load_libs.
  # shellcheck source=../../../lib/log.sh
  . "${HARBOR_ROOT}/lib/log.sh"
  # shellcheck source=../../../lib/lock.sh
  . "${HARBOR_ROOT}/lib/lock.sh"
  # shellcheck source=../../../lib/journal.sh
  . "${HARBOR_ROOT}/lib/journal.sh"
  # shellcheck source=../../../lib/release.sh
  . "${HARBOR_ROOT}/lib/release.sh"
  TEST_USER="$(id -un)"
  # The checkout trust rules judge every component from / to the checkout root, so the
  # checkout fixture cannot live under BATS_TEST_TMPDIR: on Linux that sits under
  # /tmp, whose 1777 mode the rules reject, correctly. Every component of ${HOME} is
  # owned by root or by the test user and none is group- or world-writable on either
  # platform, so a disposable directory there is the one fixture base whose ancestors
  # pass, as tests/unit/lib/checkout.bats already found. The whole fixture node lives
  # under it so that one teardown removes all of it.
  FIX_BASE="$(cd "$(mktemp -d "${HOME}/.harbor-bootstrap-test.XXXXXX")" && pwd -P)"
  chmod 0755 "${FIX_BASE}"
  TAG=v0.3.0
  OTHER_TAG=v0.2.0
  OPERATOR=harbor
  ADMIN=ubuntu
  STATE="${FIX_BASE}/var/lib/harbor"
  INSTALL="${FIX_BASE}/usr/local/lib/harbor"
  LINK="${FIX_BASE}/usr/local/bin/harbor"
  CHECKOUT="${FIX_BASE}/checkout"
  OSREL="${FIX_BASE}/os-release"
  EXECLOG="${FIX_BASE}/exec.argv"
  HOMES="${FIX_BASE}/home"
  ARCH=amd64
  ASSUME_ROOT=1
  mkdir -p "${FIX_BASE}/var/lib" "${INSTALL}" "${FIX_BASE}/usr/local/bin" \
    "${HOMES}/${ADMIN}/.ssh"
  KEYSRC="${HOMES}/${ADMIN}/.ssh/authorized_keys"
  printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5 fixture\n' >"${KEYSRC}"
  os_release ubuntu 24.04
  # getent resolves to the PR 2 shim through a link in the fixture base, so the
  # operator clash refusal consults no real account or group on either platform.
  BIN="${FIX_BASE}/bin"
  FX="${FIX_BASE}/fx"
  mkdir -p "${BIN}" "${FX}/getent/healthy"
  ln -s "${HARBOR_ROOT}/tests/shims/bin/harbor-shim" "${BIN}/getent"
  absent_account "${OPERATOR}"
  group_entry sudo 27 "${ADMIN}"
  no_group_entry admin
  build_checkout
  ARGV0="${CHECKOUT}/bin/harbor"
}

teardown() {
  case "${FIX_BASE:-}" in
    /*/.harbor-bootstrap-test.??????) rm -rf "${FIX_BASE}" ;;
  esac
}

os_release() {
  # os_release ID VERSION_ID: /etc/os-release as Ubuntu writes it, quoted values
  # included, at the fixture path the script reads instead.
  printf 'PRETTY_NAME="Ubuntu %s LTS"\nNAME="Ubuntu"\nID=%s\nVERSION_ID="%s"\n' \
    "${2}" "${1}" "${2}" >"${OSREL}"
}

gitc() {
  git -C "${CHECKOUT}" -c user.name=Harbor -c user.email=harbor@example.com \
    -c commit.gpgsign=false -c init.defaultBranch=main -c core.hooksPath=/dev/null "$@"
}

build_checkout() {
  # A checkout as a clone at a release tag leaves one: trusted ownership, no
  # group- or other-writable path, a clean work tree, and HEAD exactly at a tag.
  mkdir -p "${CHECKOUT}/bin" "${CHECKOUT}/lib" "${CHECKOUT}/node"
  printf '#!/bin/bash\nexit 0\n' >"${CHECKOUT}/bin/harbor"
  printf '# lib\n' >"${CHECKOUT}/lib/log.sh"
  printf '# node\n' >"${CHECKOUT}/node/bootstrap.sh"
  # The modes are set before the commit, because Git tracks the executable bit and a
  # chmod afterwards would leave the work tree dirty rather than clean.
  chmod 0755 "${CHECKOUT}/bin/harbor"
  chmod 0644 "${CHECKOUT}/lib/log.sh" "${CHECKOUT}/node/bootstrap.sh"
  gitc init -q
  gitc add -A
  gitc commit -q -m 'fixture release'
  gitc tag "${TAG}"
  chmod -R go-w "${CHECKOUT}"
  chmod 0755 "${CHECKOUT}" "${CHECKOUT}/bin" "${CHECKOUT}/lib" "${CHECKOUT}/node"
}

build_release() {
  # build_release TAG: an installed release directory with the installed modes of
  # design section 5.2, as harbor_release_stage leaves one, and its argv0.
  local rel="${INSTALL}/${1}"
  mkdir -p "${rel}/bin" "${rel}/lib" "${rel}/node"
  printf '#!/bin/bash\nexit 0\n' >"${rel}/bin/harbor"
  printf '# lib\n' >"${rel}/lib/log.sh"
  printf '# node\n' >"${rel}/node/bootstrap.sh"
  printf 'tag=%s\ncommit=%s\n' "${1}" 0123456789abcdef0123456789abcdef01234567 >"${rel}/RELEASE"
  chmod 0755 "${rel}" "${rel}/bin" "${rel}/lib" "${rel}/node" "${rel}/bin/harbor"
  chmod 0644 "${rel}/RELEASE" "${rel}/lib/log.sh" "${rel}/node/bootstrap.sh"
  RELEASE_DIR="${rel}"
  ARGV0="${rel}/bin/harbor"
}

write_record() {
  # write_record TAG: bootstrap.json as the last step of bootstrap writes it.
  mkdir -p "${STATE}"
  printf '{\n  "release_tag": "%s",\n  "entrypoint": "%s"\n}\n' "${1}" "${LINK}" \
    >"${STATE}/bootstrap.json"
  chmod 0644 "${STATE}/bootstrap.json"
}

passwd_entry() {
  # passwd_entry USER SHELL UID GID: what getent passwd USER answers
  printf '%s:x:%s:%s:Harbor:/home/%s:%s\n' "${1}" "${3}" "${4}" "${1}" "${2}" \
    >"${FX}/getent/healthy/passwd_${1}.out"
  rm -f "${FX}/getent/healthy/passwd_${1}.exit"
}

absent_account() {
  # getent exits 2 for a key it cannot find.
  : >"${FX}/getent/healthy/passwd_${1}.out"
  printf '2\n' >"${FX}/getent/healthy/passwd_${1}.exit"
}

group_entry() {
  # group_entry GROUP GID MEMBERS
  printf '%s:x:%s:%s\n' "${1}" "${2}" "${3}" >"${FX}/getent/healthy/group_${1}.out"
  rm -f "${FX}/getent/healthy/group_${1}.exit"
}

no_group_entry() {
  : >"${FX}/getent/healthy/group_${1}.out"
  printf '2\n' >"${FX}/getent/healthy/group_${1}.exit"
}

expected_flags() {
  # expected_flags [KEY_SOURCE]: the normalized flag set of a default run, in the
  # one canonical field order lib/entrypoint.sh prints.
  printf 'operator=%s authorized-key-source=%s adopt-firewall=no adopt-tailscale=no allow-lan-ssh=no harden-sshd=no tailscale-ssh=no' \
    "${OPERATOR}" "${1:-${KEYSRC}}"
}

bootstrap() {
  # The script under test, run as a subprocess exactly as the dispatcher sources it,
  # against fixture paths only.
  run env -u HARBOR_DEV -u HARBOR_TEST_HOOKS -u HARBOR_FAIL_AFTER \
    HARBOR_ROOT="${HARBOR_ROOT}" \
    PATH="${BIN}:${PATH}" \
    SUDO_USER="${ADMIN}" \
    HARBOR_SHIM_FIXTURES="${FX}" \
    HARBOR_BOOTSTRAP_FIXTURE_ROOT="${ASSUME_ROOT}" \
    HARBOR_BOOTSTRAP_FIXTURE_OS_RELEASE="${OSREL}" \
    HARBOR_BOOTSTRAP_FIXTURE_ARCH="${ARCH}" \
    HARBOR_BOOTSTRAP_FIXTURE_STATE_ROOT="${STATE}" \
    HARBOR_BOOTSTRAP_FIXTURE_INSTALL_ROOT="${INSTALL}" \
    HARBOR_BOOTSTRAP_FIXTURE_LINK="${LINK}" \
    HARBOR_BOOTSTRAP_FIXTURE_ARGV0="${ARGV0}" \
    HARBOR_BOOTSTRAP_FIXTURE_EXEC="${EXECLOG}" \
    HARBOR_CHECKOUT_TRUSTED_USERS="root ${TEST_USER}" \
    HARBOR_ENTRYPOINT_INSTALL_ROOT="${INSTALL}" \
    HARBOR_ENTRYPOINT_TRUSTED_OWNER="${TEST_USER}" \
    HARBOR_SSH_HOME_ROOT="${HOMES}" \
    ${HOOKS:+HARBOR_TEST_HOOKS=1} ${HOOKS:+HARBOR_FAIL_AFTER="${HOOKS}"} \
    bash "${HARBOR_ROOT}/node/bootstrap.sh" ${1+"$@"}
}

# 1. /etc/os-release reports the locked release and amd64

@test "the os-release check runs first, before the root check" {
  os_release ubuntu 22.04
  ASSUME_ROOT=0
  bootstrap
  assert_equal "${status}" 3
  assert_output --partial 'bootstrap.os_release'
  assert_output --partial '22.04'
  assert_output --partial '24.04'
  assert [ ! -e "${STATE}" ]
}

@test "an os-release naming another distribution exits 3 naming it" {
  os_release debian 24.04
  bootstrap
  assert_equal "${status}" 3
  assert_output --partial 'bootstrap.os_release'
  assert_output --partial 'debian'
  assert [ ! -e "${STATE}" ]
}

@test "a missing os-release exits 3 naming the file" {
  rm "${OSREL}"
  bootstrap
  assert_equal "${status}" 3
  assert_output --partial 'bootstrap.os_release'
  assert_output --partial "${OSREL}"
}

@test "an architecture other than amd64 exits 3 naming it" {
  ARCH=arm64
  bootstrap
  assert_equal "${status}" 3
  assert_output --partial 'bootstrap.architecture'
  assert_output --partial 'arm64'
  assert [ ! -e "${STATE}" ]
}

# 2. root with a valid SUDO_USER or --authorized-key-file

@test "a caller that is not root exits 3 and creates no state root" {
  ASSUME_ROOT=0
  bootstrap
  assert_equal "${status}" 3
  assert_output --partial 'bootstrap.not_root'
  assert [ ! -e "${STATE}" ]
  assert [ ! -e "${EXECLOG}" ]
}

@test "root with neither SUDO_USER nor --authorized-key-file exits 3 naming both ways out" {
  ADMIN=""
  bootstrap
  assert_equal "${status}" 3
  assert_output --partial 'bootstrap.no_sudo_user'
  assert_output --partial '--authorized-key-file'
  assert [ ! -e "${STATE}" ]
}

@test "SUDO_USER root without --authorized-key-file exits 3" {
  ADMIN=root
  bootstrap
  assert_equal "${status}" 3
  assert_output --partial 'bootstrap.sudo_user_root'
  assert [ ! -e "${STATE}" ]
}

@test "--authorized-key-file stands in for SUDO_USER and is what the flag set records" {
  ADMIN=""
  bootstrap --authorized-key-file "${KEYSRC}"
  assert_success
  assert_equal "$(entry_raw "${STATE}" 0001 target)" "\"$(expected_flags)\""
}

# 3. the operator-name clash refusal

@test "--operator root exits 3 naming the clash" {
  bootstrap --operator root
  assert_equal "${status}" 3
  assert_output --partial 'user.operator_root'
  assert [ ! -e "${STATE}" ]
}

@test "--operator naming the invoking administrator exits 3" {
  bootstrap --operator "${ADMIN}"
  assert_equal "${status}" 3
  assert_output --partial 'user.operator_administrator'
  assert [ ! -e "${STATE}" ]
}

@test "--operator naming a sudo group member exits 3 naming the group" {
  passwd_entry sudoer /bin/bash 1005 1005
  group_entry sudo 27 "${ADMIN},sudoer"
  bootstrap --operator sudoer
  assert_equal "${status}" 3
  assert_output --partial 'user.operator_sudo_capable'
  assert_output --partial 'sudo'
  assert [ ! -e "${STATE}" ]
}

@test "the operator clash is refused before any checkout rule, so a dirty checkout is not what is named" {
  printf 'dirty\n' >>"${CHECKOUT}/lib/log.sh"
  bootstrap --operator root
  assert_equal "${status}" 3
  assert_output --partial 'user.operator_root'
  refute_output --partial 'checkout.dirty'
}

# 4. the checkout or entrypoint rules of slice 3b

@test "a checkout with uncommitted changes exits 3 and creates no state root" {
  printf 'dirty\n' >>"${CHECKOUT}/lib/log.sh"
  bootstrap
  assert_equal "${status}" 3
  assert_output --partial 'checkout.dirty'
  assert [ ! -e "${STATE}" ]
  assert [ ! -e "${INSTALL}/${TAG}" ]
}

@test "an untracked file in the checkout exits 3 naming it" {
  printf 'stray\n' >"${CHECKOUT}/lib/stray.sh"
  bootstrap
  assert_equal "${status}" 3
  assert_output --partial 'checkout.untracked'
  assert_output --partial 'stray.sh'
}

@test "a checkout that is not at a tag exits 3" {
  gitc tag -d "${TAG}"
  bootstrap
  assert_equal "${status}" 3
  assert_output --partial 'checkout.no_tag'
  assert [ ! -e "${STATE}" ]
}

@test "a group-writable path in the checkout exits 3 naming it" {
  chmod 0775 "${CHECKOUT}/lib"
  bootstrap
  assert_equal "${status}" 3
  assert_output --partial 'checkout.mode'
  assert_output --partial "${CHECKOUT}/lib"
  assert [ ! -e "${STATE}" ]
}

@test "the installed-entrypoint form applies the release rules to the executing path" {
  build_release "${TAG}"
  chmod 0775 "${RELEASE_DIR}/lib"
  bootstrap
  assert_equal "${status}" 3
  assert_output --partial 'entrypoint.mode'
  assert_output --partial "${RELEASE_DIR}/lib"
  assert [ ! -e "${STATE}" ]
}

@test "the record-less form defers only the record equality check and then owes the harbor-install proof" {
  build_release "${TAG}"
  bootstrap
  assert_equal "${status}" 3
  assert_output --partial 'entrypoint.install_proof'
  assert_output --partial "${RELEASE_DIR}"
  assert [ ! -e "${EXECLOG}" ]
}

@test "the installed-entrypoint form with the proof continues without staging or exec'ing" {
  build_release "${TAG}"
  write_record "${OTHER_TAG}"
  mkdir -p "${STATE}/journal"
  chmod 0700 "${STATE}/journal"
  fixture_entry "${STATE}" 0001 harbor-install "${RELEASE_DIR}" created applied '"absent"' \
    "{\"tree_sha256\":\"$(harbor_release_tree_hash "${RELEASE_DIR}")\"}"
  bootstrap
  assert_success
  assert [ ! -e "${EXECLOG}" ]
  assert_equal "$(readlink "${LINK}")" "${RELEASE_DIR}/bin/harbor"
  assert_equal "$(entry_phase "${STATE}" 0002)" applied
}

# 5 and 6. the state root, then the lock

@test "the state root is created 0755 when absent and the lock is released before the exec" {
  bootstrap
  assert_success
  run ls -ld "${STATE}"
  assert_output --regexp '^drwxr-xr-x'
  assert [ ! -e "${STATE}/lock.d" ]
  assert [ ! -e "${STATE}/reclaim.d" ]
  assert [ -f "${EXECLOG}" ]
}

@test "a lock.d whose holder record does not parse exits 3 and installs nothing" {
  mkdir -p "${STATE}/lock.d"
  printf 'not a holder record\n' >"${STATE}/lock.d/holder"
  bootstrap
  assert_equal "${status}" 3
  assert_output --partial 'lock.unreadable'
  assert [ ! -e "${INSTALL}/${TAG}" ]
  assert [ ! -e "${STATE}/journal" ]
}

# 7. journal/ exists or bootstrap.json is absent too

@test "a state root holding bootstrap.json but no journal exits 3 naming the lost journal" {
  write_record "${TAG}"
  bootstrap
  assert_equal "${status}" 3
  assert_output --partial 'bootstrap.lost_journal'
  assert_output --partial "${STATE}/journal"
  assert [ ! -e "${INSTALL}/${TAG}" ]
}

# 8. recovery clean

@test "an undecidable prepared entry exits 2 before anything is installed" {
  mkdir -p "${STATE}/journal"
  chmod 0700 "${STATE}/journal"
  fixture_undecidable_file_entry "${STATE}" 0001
  bootstrap
  assert_equal "${status}" 2
  assert_output --partial 'journal.undecidable'
  assert [ ! -e "${INSTALL}/${TAG}" ]
  assert [ ! -e "${EXECLOG}" ]
}

# 9. the flag binding

@test "the first run records the flag set as an applied bootstrap-flags entry before any mutation" {
  bootstrap
  assert_success
  assert_equal "$(entry_phase "${STATE}" 0001)" applied
  assert_equal "$(entry_raw "${STATE}" 0001 target)" "\"$(expected_flags)\""
  assert_equal "$(entry_raw "${STATE}" 0001 ownership)" '"observed"'
  assert [ -f "${STATE}/journal/0001-bootstrap-flags.json" ]
}

@test "a later run with another flag set exits 3 printing the recorded value beside this run's" {
  bootstrap
  assert_success
  rm -f "${EXECLOG}"
  bootstrap --harden-sshd
  assert_equal "${status}" 3
  assert_output --partial 'flags.mismatch'
  assert_output --partial '--harden-sshd: this run yes, recorded no'
  assert [ ! -e "${EXECLOG}" ]
}

@test "a later run with the equal flag set writes no second bootstrap-flags entry and restages nothing" {
  bootstrap
  assert_success
  local hash
  hash="$(harbor_release_tree_hash "${INSTALL}/${TAG}")"
  bootstrap
  assert_success
  assert [ ! -e "${STATE}/journal/0004-bootstrap-flags.json" ]
  assert_equal "$(harbor_release_tree_hash "${INSTALL}/${TAG}")" "${hash}"
  assert_equal "$(entry_raw "${STATE}" 0002 target)" "\"${INSTALL}/${TAG}\""
}

# 10. the entrypoint symlink

@test "a foreign file at the entrypoint link exits 3 naming it for manual removal" {
  printf 'not harbor\n' >"${LINK}"
  bootstrap
  assert_equal "${status}" 3
  assert_output --partial 'bootstrap.link_foreign'
  assert_output --partial "${LINK}"
  assert [ ! -e "${INSTALL}/${TAG}" ]
}

@test "a symlink at the entrypoint link pointing outside the install root exits 3 naming it" {
  ln -s "${CHECKOUT}/bin/harbor" "${LINK}"
  bootstrap
  assert_equal "${status}" 3
  assert_output --partial 'bootstrap.link_foreign'
  assert_output --partial "${CHECKOUT}/bin/harbor"
  assert [ ! -e "${INSTALL}/${TAG}" ]
}

# The install step, the release of the lock, and the exec

@test "the install step stages the tag, journals it applied, and points the link at it" {
  bootstrap
  assert_success
  assert [ -f "${INSTALL}/${TAG}/bin/harbor" ]
  assert [ -f "${INSTALL}/${TAG}/RELEASE" ]
  assert_equal "$(sed -n 's/^tag=//p' "${INSTALL}/${TAG}/RELEASE")" "${TAG}"
  assert_equal "$(entry_phase "${STATE}" 0002)" applied
  assert_equal "$(entry_raw "${STATE}" 0002 target)" "\"${INSTALL}/${TAG}\""
  assert_equal "$(entry_phase "${STATE}" 0003)" applied
  assert_equal "$(readlink "${LINK}")" "${INSTALL}/${TAG}/bin/harbor"
}

@test "the exec passes the original arguments through unchanged after the lock is released" {
  bootstrap --operator "${OPERATOR}" --tailscale-ssh --authorized-key-file "${KEYSRC}"
  assert_success
  run cat "${EXECLOG}"
  assert_line --index 0 "${LINK}"
  assert_line --index 1 'bootstrap'
  assert_line --index 2 '--operator'
  assert_line --index 3 "${OPERATOR}"
  assert_line --index 4 '--tailscale-ssh'
  assert_line --index 5 '--authorized-key-file'
  assert_line --index 6 "${KEYSRC}"
  assert [ ! -e "${STATE}/lock.d" ]
}

@test "an authorized-key path carrying a space is refused rather than recorded ambiguously" {
  mkdir -p "${HOMES}/${ADMIN}/keys dir"
  cp "${KEYSRC}" "${HOMES}/${ADMIN}/keys dir/authorized_keys"
  bootstrap --authorized-key-file "${HOMES}/${ADMIN}/keys dir/authorized_keys"
  assert_equal "${status}" 3
  assert_output --partial 'flags.whitespace'
}

# Step boundaries

@test "HARBOR_FAIL_AFTER cuts between the intent entry and the install step" {
  HOOKS=bootstrap-flags
  bootstrap
  assert [ "${status}" -ne 0 ]
  assert_equal "$(entry_phase "${STATE}" 0001)" applied
  assert [ ! -e "${INSTALL}/${TAG}" ]
  assert [ ! -e "${EXECLOG}" ]
}

# Usage

@test "an unknown flag exits 3 with the usage line" {
  bootstrap --nope
  assert_equal "${status}" 3
  assert_output --partial 'bootstrap.usage'
  assert_output --partial '--nope'
  assert [ ! -e "${STATE}" ]
}

@test "a flag whose value is missing exits 3 naming it" {
  bootstrap --operator
  assert_equal "${status}" 3
  assert_output --partial 'bootstrap.usage'
  assert_output --partial '--operator'
  assert [ ! -e "${STATE}" ]
}
