#!/usr/bin/env bats
load '../test_helper'

setup() {
  # lib/ssh.sh depends on lib/log.sh, lib/lock.sh, and lib/journal.sh, so this file
  # sources those four rather than harbor_load_libs.
  # shellcheck source=lib/log.sh
  . "${HARBOR_ROOT}/lib/log.sh"
  # shellcheck source=lib/lock.sh
  . "${HARBOR_ROOT}/lib/lock.sh"
  # shellcheck source=lib/journal.sh
  . "${HARBOR_ROOT}/lib/journal.sh"
  # shellcheck source=lib/ssh.sh
  . "${HARBOR_ROOT}/lib/ssh.sh"
  fixture_state_root
  HARBOR_PID="$$"
  # The production /home becomes a fixture home root, read only because these tests
  # are not root; the operator identity is a parameter, and the only account an
  # unprivileged test may chown to is the one it already runs as.
  HOMES="${BATS_TEST_TMPDIR}/homes"
  mkdir -p "${HOMES}"
  HARBOR_SSH_HOME_ROOT="${HOMES}"
  export HARBOR_SSH_HOME_ROOT
  OPERATOR="$(id -un)"
  OP_HOME="${BATS_TEST_TMPDIR}/operator"
  mkdir -p "${OP_HOME}"
  SSH_DIR="${OP_HOME}/.ssh"
  TARGET="${SSH_DIR}/authorized_keys"
  # Fixture keys are literal test strings, never anything shaped like a real key,
  # and the only email in them is the placeholder of design section 3.8.
  ALICE_KEY='ssh-ed25519 FIXTURE-KEY-ALICE operator@example.com'
  BOB_KEY='ssh-ed25519 FIXTURE-KEY-BOB operator@example.com'
  GIVEN_KEY='ssh-ed25519 FIXTURE-KEY-GIVEN operator@example.com'
  seed_key alice "${ALICE_KEY}"
  seed_key bob "${BOB_KEY}"
  GIVEN="${BATS_TEST_TMPDIR}/given/keys"
  mkdir -p "${BATS_TEST_TMPDIR}/given"
  printf '%s\n' "${GIVEN_KEY}" >"${GIVEN}"
  chmod 0644 "${GIVEN}"
  SUDO_USER=alice
  export SUDO_USER
}

seed_key() {
  # seed_key USER TEXT: an account under the fixture home root with a key
  mkdir -p "${HOMES}/${1}/.ssh"
  chmod 0700 "${HOMES}/${1}/.ssh"
  printf '%s\n' "${2}" >"${HOMES}/${1}/.ssh/authorized_keys"
  chmod 0600 "${HOMES}/${1}/.ssh/authorized_keys"
}

acquire() {
  harbor_lock_acquire "${FIX_ROOT}" operator
}

journal_names() {
  ls -A "${FIX_ROOT}/journal"
}

inode_of() {
  ls -lid "${1}" | awk '{ print $1 }'
}

authorize() {
  harbor_ssh_authorize "${FIX_ROOT}" "${OPERATOR}" "${OP_HOME}" ${1+"$@"}
}

@test "the default source is the invoking SUDO_USER's own authorized_keys and is read from nowhere else" {
  # HOME, USER, and LOGNAME all name another account with a key of its own: the
  # default follows SUDO_USER and only SUDO_USER.
  HOME="${HOMES}/bob"
  USER=bob
  LOGNAME=bob
  export HOME USER LOGNAME
  run harbor_ssh_source ""
  assert_success
  assert_output "${HOMES}/alice/.ssh/authorized_keys"
  # No SUDO_USER at all: a precondition, never bob's key.
  SUDO_USER=""
  run harbor_ssh_source ""
  assert_equal "${status}" 3
  assert_output --partial 'ssh.no_sudo_user'
  assert_output --partial '--authorized-key-file'
  refute_output --partial bob
  # SUDO_USER=root is not a source either: the key must come from a non-root account.
  SUDO_USER=root
  run harbor_ssh_source ""
  assert_equal "${status}" 3
  assert_output --partial 'ssh.sudo_user_root'
  assert_output --partial '--authorized-key-file'
}

@test "a missing, unreadable, or empty default source exits 3 naming --authorized-key-file, copies nothing, and never falls back to another account" {
  # Missing: alice has an account but no key, while bob has one.
  rm "${HOMES}/alice/.ssh/authorized_keys"
  acquire
  run authorize
  assert_equal "${status}" 3
  assert_output --partial 'ssh.no_default_key'
  assert_output --partial "${HOMES}/alice/.ssh/authorized_keys"
  assert_output --partial '--authorized-key-file'
  refute_output --partial "${BOB_KEY}"
  refute_output --partial "${HOMES}/bob"
  assert [ ! -e "${TARGET}" ]
  assert_equal "$(journal_names)" ""
  # Empty: the file is there and readable, and is still not a source.
  : >"${HOMES}/alice/.ssh/authorized_keys"
  run authorize
  assert_equal "${status}" 3
  assert_output --partial 'ssh.empty_default_key'
  assert_output --partial '--authorized-key-file'
  assert [ ! -e "${TARGET}" ]
  assert_equal "$(journal_names)" ""
  # Unreadable: these tests are unprivileged, so mode 0000 really is unreadable.
  printf '%s\n' "${ALICE_KEY}" >"${HOMES}/alice/.ssh/authorized_keys"
  chmod 0000 "${HOMES}/alice/.ssh/authorized_keys"
  run authorize
  assert_equal "${status}" 3
  assert_output --partial 'ssh.unreadable_default_key'
  assert_output --partial '--authorized-key-file'
  assert [ ! -e "${TARGET}" ]
  assert_equal "$(journal_names)" ""
  chmod 0600 "${HOMES}/alice/.ssh/authorized_keys"
  harbor_lock_release "${FIX_ROOT}"
}

@test "an explicit --authorized-key-file path is used as given even when the SUDO_USER has a key of their own" {
  acquire
  run authorize "${GIVEN}"
  assert_success
  assert_equal "$(cat "${TARGET}")" "${GIVEN_KEY}"
  assert_equal "$(entry_raw "${FIX_ROOT}" 0001 target)" "\"${GIVEN}\""
  refute [ "$(cat "${TARGET}")" = "${ALICE_KEY}" ]
  # An explicit path that is missing or empty is a precondition too, and never a
  # silent fall back to the SUDO_USER's key, whose file is right there.
  rm -r "${SSH_DIR}"
  run authorize "${BATS_TEST_TMPDIR}/given/absent"
  assert_equal "${status}" 3
  assert_output --partial 'ssh.source_missing'
  assert_output --partial "${BATS_TEST_TMPDIR}/given/absent"
  assert [ ! -e "${TARGET}" ]
  : >"${BATS_TEST_TMPDIR}/given/empty"
  run authorize "${BATS_TEST_TMPDIR}/given/empty"
  assert_equal "${status}" 3
  assert_output --partial 'ssh.source_empty'
  assert [ ! -e "${TARGET}" ]
  harbor_lock_release "${FIX_ROOT}"
}

@test "the copied target is byte for byte the source, owned by the operator, 0600, inside a 0700 .ssh the copy created" {
  acquire
  assert [ ! -e "${SSH_DIR}" ]
  run authorize
  assert_success
  assert_equal "$(cat "${TARGET}")" "${ALICE_KEY}"
  assert_equal "$(harbor_sha256 "${TARGET}")" "$(harbor_sha256 "${HOMES}/alice/.ssh/authorized_keys")"
  assert_equal "$(harbor_stat_mode "${TARGET}")" 0600
  assert_equal "$(harbor_stat_owner "${TARGET}")" "${OPERATOR}"
  assert_equal "$(harbor_stat_mode "${SSH_DIR}")" 0700
  assert_equal "$(harbor_stat_owner "${SSH_DIR}")" "${OPERATOR}"
  # The source is left exactly as it was and no temporary file survives.
  assert_equal "$(harbor_stat_mode "${HOMES}/alice/.ssh/authorized_keys")" 0600
  assert_equal "$(ls -A "${SSH_DIR}")" authorized_keys
  # A source with a wider mode than the target still lands 0600: the target's mode
  # is Harbor's, and the source's own mode is what the journal records.
  rm -r "${SSH_DIR}"
  run authorize "${GIVEN}"
  assert_success
  assert_equal "$(harbor_stat_mode "${TARGET}")" 0600
  assert_equal "$(harbor_stat_mode "${GIVEN}")" 0644
  harbor_lock_release "${FIX_ROOT}"
}

@test "the entries record the source path and mode, the target path, and the SHA-256 of both" {
  acquire
  src="${HOMES}/alice/.ssh/authorized_keys"
  run authorize
  assert_success
  sha="$(harbor_sha256 "${src}")"
  run journal_names
  assert_line --index 0 0001-authorized-key-source.json
  assert_line --index 1 0002-authorized-key.json
  assert_equal "${#lines[@]}" 2
  # The source: its path is the entry's target, and its state carries the mode the
  # administrator's own file had and its SHA-256. It is read, never written, so the
  # entry is observed and directly applied.
  assert_equal "$(entry_raw "${FIX_ROOT}" 0001 target)" "\"${src}\""
  assert_equal "$(entry_raw "${FIX_ROOT}" 0001 ownership)" '"observed"'
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" applied
  assert_equal "$(entry_raw "${FIX_ROOT}" 0001 pre_state)" \
    "{\"sha256\":\"${sha}\",\"mode\":\"0600\",\"owner\":\"${OPERATOR}\"}"
  assert_equal "$(entry_raw "${FIX_ROOT}" 0001 post_state)" \
    "$(entry_raw "${FIX_ROOT}" 0001 pre_state)"
  # The target: its path is the entry's target, its pre_state is absent, and its
  # post_state carries the same SHA-256, so the pair proves what was copied where.
  assert_equal "$(entry_raw "${FIX_ROOT}" 0002 target)" "\"${TARGET}\""
  assert_equal "$(entry_raw "${FIX_ROOT}" 0002 ownership)" '"created"'
  assert_equal "$(entry_phase "${FIX_ROOT}" 0002)" applied
  assert_equal "$(entry_raw "${FIX_ROOT}" 0002 pre_state)" '"absent"'
  assert_equal "$(entry_raw "${FIX_ROOT}" 0002 post_state)" \
    "{\"sha256\":\"${sha}\",\"mode\":\"0600\",\"owner\":\"${OPERATOR}\"}"
  harbor_journal_validate "${FIX_ROOT}/journal/0001-authorized-key-source.json"
  harbor_journal_validate "${FIX_ROOT}/journal/0002-authorized-key.json"
  harbor_lock_release "${FIX_ROOT}"
}

@test "an existing operator authorized_keys is journaled observed, left byte for byte unchanged, and needs no source at all" {
  mkdir -p "${SSH_DIR}"
  chmod 0700 "${SSH_DIR}"
  printf '%s\n' 'ssh-ed25519 FIXTURE-KEY-ALREADY-THERE operator@example.com' >"${TARGET}"
  chmod 0644 "${TARGET}"
  before="$(harbor_sha256 "${TARGET}")"
  before_inode="$(inode_of "${TARGET}")"
  before_mode="$(harbor_stat_mode "${TARGET}")"
  # No SUDO_USER and no explicit path: inspection decides the step, so a key Harbor
  # did not place is never appended to, rewritten, removed, or re-moded, and no
  # source is required to prove that.
  SUDO_USER=""
  acquire
  run authorize
  assert_success
  assert_equal "$(harbor_sha256 "${TARGET}")" "${before}"
  assert_equal "$(inode_of "${TARGET}")" "${before_inode}"
  assert_equal "$(harbor_stat_mode "${TARGET}")" "${before_mode}"
  assert_equal "$(journal_names)" 0001-authorized-key.json
  assert_equal "$(entry_raw "${FIX_ROOT}" 0001 target)" "\"${TARGET}\""
  assert_equal "$(entry_raw "${FIX_ROOT}" 0001 ownership)" '"observed"'
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" applied
  assert_equal "$(entry_raw "${FIX_ROOT}" 0001 pre_state)" \
    "{\"sha256\":\"${before}\",\"mode\":\"${before_mode}\",\"owner\":\"${OPERATOR}\"}"
  assert_equal "$(entry_raw "${FIX_ROOT}" 0001 post_state)" \
    "$(entry_raw "${FIX_ROOT}" 0001 pre_state)"
  assert_equal "$(ls -A "${SSH_DIR}")" authorized_keys
  harbor_lock_release "${FIX_ROOT}"
}

@test "a second run copies nothing: the target is observed, the file is the same inode, and no new created entry is written" {
  acquire
  run authorize
  assert_success
  first="$(inode_of "${TARGET}")"
  run authorize
  assert_success
  assert_equal "$(inode_of "${TARGET}")" "${first}"
  assert_equal "$(cat "${TARGET}")" "${ALICE_KEY}"
  run journal_names
  assert_line --index 2 0003-authorized-key.json
  assert_equal "${#lines[@]}" 3
  assert_equal "$(entry_raw "${FIX_ROOT}" 0003 ownership)" '"observed"'
  assert_equal "$(entry_phase "${FIX_ROOT}" 0003)" applied
  harbor_lock_release "${FIX_ROOT}"
}

@test "a crash between the copy and the applied write leaves an entry recovery can decide" {
  # The crash window of design section 3.7: the rename into place landed or did not,
  # and the applied write never happened. The child holds its own lock and is killed
  # at the ssh-key-copied boundary by the only test hook Harbor has.
  run env HARBOR_TEST_HOOKS=1 HARBOR_FAIL_AFTER=ssh-key-copied SUDO_USER=alice \
    bash -c '. "${HARBOR_ROOT}/lib/log.sh"; . "${HARBOR_ROOT}/lib/lock.sh"; . "${HARBOR_ROOT}/lib/journal.sh"; . "${HARBOR_ROOT}/lib/ssh.sh"; HARBOR_PID=$$; harbor_lock_acquire "${1}" operator; harbor_ssh_authorize "${1}" "${2}" "${3}"' \
    _ "${FIX_ROOT}" "${OPERATOR}" "${OP_HOME}"
  assert_equal "${status}" 137
  assert_equal "$(cat "${TARGET}")" "${ALICE_KEY}"
  post="$(harbor_observe_file "${TARGET}")"
  run journal_names
  assert_line --index 1 0002-authorized-key.json
  assert_equal "${#lines[@]}" 2
  assert_equal "$(entry_phase "${FIX_ROOT}" 0002)" prepared
  # The killed child left its lock behind; production reclaims it, this test removes
  # it so recovery runs under a lock this process owns.
  rm -rf "${FIX_ROOT}/lock.d"
  acquire
  run harbor_journal_recover "${FIX_ROOT}"
  assert_success
  assert_equal "$(entry_phase "${FIX_ROOT}" 0002)" applied
  assert_equal "$(cat "${TARGET}")" "${ALICE_KEY}"
  # The other side of the same window: the rename had not landed, so the target is
  # still absent and the entry is reverted.
  rm "${TARGET}"
  fixture_entry "${FIX_ROOT}" 0003 authorized-key "${TARGET}" created prepared '"absent"' "${post}"
  run harbor_journal_recover "${FIX_ROOT}"
  assert_success
  assert_equal "$(entry_phase "${FIX_ROOT}" 0003)" reverted
  assert [ ! -e "${TARGET}" ]
  # A target matching neither recorded state is undecidable and blocks, rather than
  # being guessed at.
  printf '%s\n' 'ssh-ed25519 FIXTURE-KEY-SOMETHING-ELSE operator@example.com' >"${TARGET}"
  chmod 0600 "${TARGET}"
  fixture_entry "${FIX_ROOT}" 0004 authorized-key "${TARGET}" created prepared '"absent"' "${post}"
  run --separate-stderr harbor_journal_recover "${FIX_ROOT}"
  assert_equal "${status}" 2
  assert_regex "${stderr}" 'journal entry 0004-authorized-key.json is undecidable:'
  assert_regex "${stderr}" 'journal.undecidable: prepared entries 0004 cannot be decided'
  assert_equal "$(entry_phase "${FIX_ROOT}" 0004)" prepared
  harbor_lock_release "${FIX_ROOT}"
}

@test "a .ssh that is not a 0700 directory owned by the operator is a precondition: nothing copied, nothing journaled" {
  mkdir -p "${SSH_DIR}"
  chmod 0755 "${SSH_DIR}"
  acquire
  run authorize
  assert_equal "${status}" 3
  assert_output --partial 'ssh.ssh_dir_mode'
  assert_output --partial "${SSH_DIR}"
  assert [ ! -e "${TARGET}" ]
  assert_equal "$(journal_names)" ""
  # Harbor removes nothing it cannot prove it created: a non-directory at .ssh is
  # named for manual inspection, never replaced.
  rm -r "${SSH_DIR}"
  printf 'not a directory\n' >"${SSH_DIR}"
  run authorize
  assert_equal "${status}" 3
  assert_output --partial 'ssh.ssh_dir_foreign'
  assert_equal "$(cat "${SSH_DIR}")" 'not a directory'
  assert_equal "$(journal_names)" ""
  harbor_lock_release "${FIX_ROOT}"
}

@test "a foreign authorized_keys and a missing operator home are preconditions, and the argument list is checked" {
  mkdir -p "${SSH_DIR}"
  chmod 0700 "${SSH_DIR}"
  mkdir "${TARGET}"
  acquire
  run authorize
  assert_equal "${status}" 3
  assert_output --partial 'ssh.target_foreign'
  assert_output --partial "${TARGET}"
  assert [ -d "${TARGET}" ]
  assert_equal "$(journal_names)" ""
  run harbor_ssh_authorize "${FIX_ROOT}" "${OPERATOR}" "${BATS_TEST_TMPDIR}/no-such-home"
  assert_equal "${status}" 3
  assert_output --partial 'ssh.no_home'
  assert_equal "$(journal_names)" ""
  run harbor_ssh_authorize "${FIX_ROOT}" "${OPERATOR}"
  assert_equal "${status}" 3
  assert_output --partial usage
  run harbor_ssh_authorize "${FIX_ROOT}" "${OPERATOR}" "${OP_HOME}" "${GIVEN}" extra
  assert_equal "${status}" 3
  assert_output --partial usage
  harbor_lock_release "${FIX_ROOT}"
}
