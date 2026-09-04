#!/usr/bin/env bats
load '../test_helper'

TAB="$(printf '\t')"

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
  # The installation user of design section 3.5: the account that invoked sudo, whose
  # effective sshd configuration the operator drop-in must leave untouched.
  ADMIN=alice
  # sshd and systemctl resolve to the PR 2 shim through links this test makes in its
  # own temporary directory, so no real daemon is ever asked and no real unit is ever
  # reloaded. The destination configuration root is a fixture directory, never /etc:
  # it is a parameter of the functions under test.
  BIN="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "${BIN}"
  ln -s "${HARBOR_ROOT}/tests/shims/bin/harbor-shim" "${BIN}/sshd"
  ln -s "${HARBOR_ROOT}/tests/shims/bin/harbor-shim" "${BIN}/systemctl"
  PATH="${BIN}:${PATH}"
  export PATH
  HARBOR_SHIM_LOG="${BATS_TEST_TMPDIR}/shim.log"
  export HARBOR_SHIM_LOG
  FX="${BATS_TEST_TMPDIR}/fx"
  HARBOR_SHIM_FIXTURES="${FX}"
  export HARBOR_SHIM_FIXTURES
  WITNESS="${BATS_TEST_TMPDIR}/witness.log"
  ETC="${BATS_TEST_TMPDIR}/etc"
  DROPIN="${ETC}/ssh/sshd_config.d/50-harbor-operator.conf"
  GLOBAL_DROPIN="${ETC}/ssh/sshd_config.d/51-harbor-global.conf"
  mkdir -p "${FX}/sshd/healthy" "${FX}/systemctl/healthy"
  service_state active
  reload_succeeds
  sshd_refresh
}

sshd_config_lines() {
  # The effective configuration of a node whose sshd has been asked nothing yet: the
  # directives both users start with. Only the keywords the drop-ins can move are
  # interesting; the rest are here so that "unchanged for every directive" has more
  # than the interesting ones to be true of.
  printf 'port 22\n'
  printf 'permitrootlogin prohibit-password\n'
  printf 'pubkeyauthentication yes\n'
  printf 'passwordauthentication yes\n'
  printf 'kbdinteractiveauthentication yes\n'
  printf 'usepam yes\n'
  printf 'x11forwarding yes\n'
  printf 'clientaliveinterval 0\n'
}

admin_config() {
  # What sshd -T -C user=<installation user> prints, computed from the drop-ins that
  # are on disk at this instant rather than canned, which is what makes the
  # before-and-after proof a real one.
  local lines
  lines="$(sshd_config_lines)"
  # The global drop-in of --harden-sshd changes the installation user's own
  # configuration: that is what the flag is.
  if [ -f "${GLOBAL_DROPIN}" ]; then
    lines="$(printf '%s\n' "${lines}" \
      | sed -e 's/^permitrootlogin .*/permitrootlogin no/' -e 's/^passwordauthentication .*/passwordauthentication no/')"
  fi
  # LEAK=1 models the defect the proof exists to catch: an operator drop-in that also
  # moves a directive for the installation user, and adds one they never had.
  if [ "${LEAK:-0}" = 1 ] && [ -f "${DROPIN}" ]; then
    lines="$(printf '%s\n' "${lines}" | sed -e 's/^passwordauthentication .*/passwordauthentication no/')"
    lines="${lines}
maxauthtries 3"
  fi
  # SHUFFLE=1 prints the same directives in another order, which a proof that compares
  # the whole normalized output must be indifferent to.
  if [ "${SHUFFLE:-0}" = 1 ]; then
    lines="$(printf '%s\n' "${lines}" | sort -r)"
  fi
  printf '%s\n' "${lines}"
}

operator_config() {
  # What sshd -T -C user=<operator> prints. The drop-in on disk is what makes the two
  # no values appear; OPERATOR_HARDENING says which of them the modeled sshd honors,
  # so a drop-in that did not take effect can be tested one directive at a time.
  local lines
  lines="$(sshd_config_lines)"
  [ -f "${DROPIN}" ] || {
    printf '%s\n' "${lines}"
    return 0
  }
  case "${OPERATOR_HARDENING:-both}" in
    both)
      lines="$(printf '%s\n' "${lines}" \
        | sed -e 's/^passwordauthentication .*/passwordauthentication no/' \
          -e 's/^kbdinteractiveauthentication .*/kbdinteractiveauthentication no/')"
      ;;
    password)
      lines="$(printf '%s\n' "${lines}" | sed -e 's/^passwordauthentication .*/passwordauthentication no/')"
      ;;
    none) ;;
  esac
  # OPERATOR_PUBKEY=no models the node the third assertion exists for: a drop-in
  # sorting before Harbor's, or a global PubkeyAuthentication no, was obtained first,
  # and OpenSSH keeps the first value it gets for a keyword, so the Match block's own
  # yes never takes effect and sshd reports all three keywords as no.
  [ "${OPERATOR_PUBKEY:-yes}" = yes ] \
    || lines="$(printf '%s\n' "${lines}" | sed -e 's/^pubkeyauthentication .*/pubkeyauthentication no/')"
  printf '%s\n' "${lines}"
}

sshd_refresh() {
  # The shim replies from files, so the modeled answers are rewritten immediately
  # before every call from the drop-ins that exist at that moment.
  admin_config >"${FX}/sshd/healthy/-T_-C_user=${ADMIN}.out"
  operator_config >"${FX}/sshd/healthy/-T_-C_user=${OPERATOR}.out"
  # EMPTY_CONFIG=1 models an sshd that exits 0 and says nothing, which no comparison
  # can be made against.
  [ "${EMPTY_CONFIG:-0}" = 0 ] || : >"${FX}/sshd/healthy/-T_-C_user=${ADMIN}.out"
  if [ "${SYNTAX_OK:-1}" = 1 ]; then
    : >"${FX}/sshd/healthy/-t.out"
    rm -f "${FX}/sshd/healthy/-t.exit"
  else
    printf 'line 5: Bad configuration option: Matchh\n' >"${FX}/sshd/healthy/-t.out"
    printf '255\n' >"${FX}/sshd/healthy/-t.exit"
  fi
}

sshd() {
  # The shim is stateless, so the effect the drop-ins have on sshd is modeled here and
  # the shim is still what runs and logs. The witness records, for every call, whether
  # the operator drop-in was on disk when the call was made, which is how "the
  # installation user's baseline was taken before the drop-in existed" is asserted.
  if [ -f "${DROPIN}" ]; then
    printf 'present'
  else
    printf 'absent'
  fi >>"${WITNESS}"
  printf '\t%s\n' "${*}" >>"${WITNESS}"
  sshd_refresh
  command sshd ${1+"$@"} || return "$?"
}

service_state() {
  # service_state WORD: what systemctl is-active ssh.service answers. Only active
  # exits 0, as the real systemctl does, so the library is proven to decide on the
  # word it prints and not on the exit code.
  printf '%s\n' "${1}" >"${FX}/systemctl/healthy/is-active_ssh.service.out"
  if [ "${1}" = active ]; then
    rm -f "${FX}/systemctl/healthy/is-active_ssh.service.exit"
  else
    printf '3\n' >"${FX}/systemctl/healthy/is-active_ssh.service.exit"
  fi
}

reload_succeeds() {
  : >"${FX}/systemctl/healthy/reload_ssh.service.out"
  rm -f "${FX}/systemctl/healthy/reload_ssh.service.exit"
}

reload_fails() {
  printf 'Job for ssh.service failed.\n' >"${FX}/systemctl/healthy/reload_ssh.service.out"
  printf '1\n' >"${FX}/systemctl/healthy/reload_ssh.service.exit"
}

shim_lines() {
  # Every shim call, in order. A shim log that was never created is no calls.
  [ -e "${HARBOR_SHIM_LOG}" ] || return 0
  cat "${HARBOR_SHIM_LOG}"
}

shim_calls() {
  # shim_calls [PATTERN]: how many shim calls the log holds, all of them by default
  [ -e "${HARBOR_SHIM_LOG}" ] || {
    printf '0\n'
    return 0
  }
  grep -c "${1:-.}" "${HARBOR_SHIM_LOG}" || true
}

dropin_settings() {
  # A drop-in without its comment header and blank lines.
  grep -v -e '^#' -e '^[[:space:]]*$' "${1}"
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

code_naming() {
  # code_naming PATTERN: the lines of lib/ssh.sh that are not comments and name
  # PATTERN. The prose above a function may name a production path to explain itself;
  # only the code can reach one.
  grep -v '^[[:space:]]*#' "${HARBOR_ROOT}/lib/ssh.sh" | grep "${1}" || true
}

configure() {
  harbor_ssh_configure "${FIX_ROOT}" "${OPERATOR}" "${ADMIN}" "${ETC}"
}

harden() {
  harbor_ssh_harden "${FIX_ROOT}" "${ADMIN}" "${ETC}"
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

@test "a source holding no usable key is refused in both branches, so Harbor never copies a file with no key in it" {
  # The site that decides what gets copied. [ -s ] is "not zero bytes", so a file of
  # nothing but comments passed it, Harbor installed it as the operator's
  # authorized_keys, and harbor_ssh_configure then took password authentication away
  # from the account whose only key was a comment.
  #
  # The explicit branch first: --authorized-key-file naming a comment-only file.
  printf '# my key is on the other laptop\n' >"${BATS_TEST_TMPDIR}/given/comments"
  assert [ -s "${BATS_TEST_TMPDIR}/given/comments" ]
  acquire
  run authorize "${BATS_TEST_TMPDIR}/given/comments"
  assert_equal "${status}" 3
  assert_output --partial 'ssh.source_empty'
  assert_output --partial 'no usable authorized-key line'
  assert [ ! -e "${TARGET}" ]
  assert_equal "$(journal_names)" ""
  # Whitespace alone is not zero bytes either, and is not a key.
  printf '\n   \n\t\n' >"${BATS_TEST_TMPDIR}/given/blanks"
  assert [ -s "${BATS_TEST_TMPDIR}/given/blanks" ]
  run authorize "${BATS_TEST_TMPDIR}/given/blanks"
  assert_equal "${status}" 3
  assert_output --partial 'ssh.source_empty'
  assert [ ! -e "${TARGET}" ]
  assert_equal "$(journal_names)" ""
  # The default branch: the invoking SUDO_USER's own file, holding only a comment.
  printf '# my key is on the other laptop\n' >"${HOMES}/alice/.ssh/authorized_keys"
  run authorize
  assert_equal "${status}" 3
  assert_output --partial 'ssh.empty_default_key'
  assert_output --partial 'no usable authorized-key line'
  assert_output --partial '--authorized-key-file'
  assert [ ! -e "${TARGET}" ]
  assert_equal "$(journal_names)" ""
  # A key carrying options before its type is a key: options are legal in
  # authorized_keys, and a predicate anchored on the type token would refuse a real
  # key, which is a lockout of its own kind.
  printf '# alice\n\nrestrict,from="10.0.0.0/8" %s\n' "${ALICE_KEY}" >"${HOMES}/alice/.ssh/authorized_keys"
  run authorize
  assert_success
  assert_equal "$(harbor_sha256 "${TARGET}")" "$(harbor_sha256 "${HOMES}/alice/.ssh/authorized_keys")"
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

@test "nothing root writes, chmods, or chowns for the key is named inside the operator's own .ssh" {
  # The escalation this staging root exists to make impossible: the operator owns
  # ~/.ssh and may unlink anything in it and put a symlink there instead, and the pid
  # in the staging name is not even a guess, because design section 5.2 makes the lock
  # holder record world-readable so the operator can read it. cp, chmod, and chown all
  # resolve the final component through a symlink, so a chown alone would have handed
  # the operator ownership of any file it could name. The link stands in for that: it
  # is planted at the path root used to stage at, before root gets there.
  mkdir -p "${SSH_DIR}"
  chmod 0700 "${SSH_DIR}"
  VICTIM="${BATS_TEST_TMPDIR}/root-only"
  printf 'a file only root may own or write\n' >"${VICTIM}"
  chmod 0444 "${VICTIM}"
  victim_sha="$(harbor_sha256 "${VICTIM}")"
  acquire
  planted="${SSH_DIR}/.tmp.authorized_keys.${HARBOR_LOCK_ID_PID}"
  ln -s "${VICTIM}" "${planted}"
  run authorize
  assert_success
  # The victim is byte for byte what it was and still has the mode it had: nothing
  # root did resolved through the planted link.
  assert_equal "$(harbor_sha256 "${VICTIM}")" "${victim_sha}"
  assert_equal "$(harbor_stat_mode "${VICTIM}")" 0444
  refute [ "$(cat "${VICTIM}")" = "${ALICE_KEY}" ]
  # And the link is still exactly the link the operator planted: Harbor never unlinked
  # it, never opened it, and never chowned it, because it named no path at all inside a
  # directory the operator controls. Narrowing the window would not show here; naming
  # nothing in that directory is what does.
  assert [ -L "${planted}" ]
  assert_equal "$(readlink "${planted}")" "${VICTIM}"
  # The key still landed, staged from the root-owned state root and renamed into place.
  assert_equal "$(cat "${TARGET}")" "${ALICE_KEY}"
  assert_equal "$(harbor_stat_mode "${TARGET}")" 0600
  assert_equal "$(harbor_stat_owner "${TARGET}")" "${OPERATOR}"
  harbor_lock_release "${FIX_ROOT}"
}

@test "the staged key carries its final mode and owner inside the state root, and .ssh holds no temporary file at any instant" {
  # The same property seen from the other side, at the one instant it matters. The
  # process is stopped at the ssh-key-prepared boundary, which is between the staged
  # file being given its final mode and owner and the rename that puts it in place:
  # exactly the window an escalation would be won in. Everything root wrote is in the
  # state root, which design section 5.2 creates 0755 root-owned under root-owned
  # ancestors, and the operator's own directory is empty.
  run env HARBOR_TEST_HOOKS=1 HARBOR_FAIL_AFTER=ssh-key-prepared SUDO_USER=alice \
    bash -c '. "${HARBOR_ROOT}/lib/log.sh"; . "${HARBOR_ROOT}/lib/lock.sh"; . "${HARBOR_ROOT}/lib/journal.sh"; . "${HARBOR_ROOT}/lib/ssh.sh"; HARBOR_PID=$$; harbor_lock_acquire "${1}" operator; harbor_ssh_authorize "${1}" "${2}" "${3}"' \
    _ "${FIX_ROOT}" "${OPERATOR}" "${OP_HOME}"
  assert_equal "${status}" 137
  # .ssh was created 0700 for the operator, and it is empty: there is no temporary file
  # at a path the operator could have replaced, so there was nothing to chown through.
  assert_equal "$(harbor_stat_mode "${SSH_DIR}")" 0700
  assert_equal "$(harbor_stat_owner "${SSH_DIR}")" "${OPERATOR}"
  assert_equal "$(ls -A "${SSH_DIR}")" ""
  assert [ ! -e "${TARGET}" ]
  # The staged file is in the state root and already carries the target's mode and owner.
  run find "${FIX_ROOT}" -maxdepth 1 -name '.tmp.authorized_keys.*'
  assert_equal "${#lines[@]}" 1
  staged="${lines[0]}"
  assert_equal "$(harbor_stat_mode "${staged}")" 0600
  assert_equal "$(harbor_stat_owner "${staged}")" "${OPERATOR}"
  assert_equal "$(cat "${staged}")" "${ALICE_KEY}"
  # The killed child left its lock behind; production reclaims it, this test removes it.
  rm -rf "${FIX_ROOT}/lock.d"
}

@test "a state root and an operator .ssh on different filesystems are refused by name, because there mv is a copy that follows a symlink" {
  # The gate the staging mechanism rests on: rename(2) resolves neither final component,
  # so a symlink planted at the destination is unlinked rather than written through, but
  # mv degrades to copy-and-unlink across filesystems and a copy does follow it.
  run harbor_ssh_assert_one_filesystem "${FIX_ROOT}" "${OP_HOME}" "${TARGET}"
  assert_success
  # /dev is a filesystem of its own on both platforms the unit lane runs on. Nothing
  # here writes to it or reads anything out of it; it is only asked which device it is.
  if [ "$(harbor_ssh_device /)" = "$(harbor_ssh_device /dev)" ]; then
    skip "/ and /dev report one device on this machine"
  fi
  run harbor_ssh_assert_one_filesystem / /dev "${TARGET}"
  assert_equal "${status}" 3
  assert_output --partial 'ssh.cross_filesystem'
  assert_output --partial '/dev'
  assert_output --partial "${TARGET}"
  # A path whose filesystem cannot be read is fail-closed too, rather than assumed same.
  run harbor_ssh_assert_one_filesystem "${FIX_ROOT}" "${BATS_TEST_TMPDIR}/no-such-dir" "${TARGET}"
  assert_equal "${status}" 3
  assert_output --partial 'ssh.device'
  assert_output --partial "${BATS_TEST_TMPDIR}/no-such-dir"
}

@test "an existing authorized_keys holding no usable key exits 3 rather than leaving the operator an account with no way in" {
  # The lockout the observed arm used to walk into. Any regular file was accepted and
  # journaled observed, and harbor_ssh_configure then took password and
  # keyboard-interactive authentication away from that account: putting the key row
  # before the drop-in row does not save an operator whose file holds no key.
  mkdir -p "${SSH_DIR}"
  chmod 0700 "${SSH_DIR}"
  : >"${TARGET}"
  chmod 0600 "${TARGET}"
  before_inode="$(inode_of "${TARGET}")"
  acquire
  run authorize
  assert_equal "${status}" 3
  assert_output --partial 'ssh.target_no_key'
  assert_output --partial "${TARGET}"
  assert_output --partial 'no usable authorized-key line'
  assert_output --partial 'password authentication'
  assert_output --partial 'rerun'
  # Harbor overwrites nothing it cannot prove it created: the file is the same empty
  # file, and nothing was journaled, so no later row can act on a key that is not there.
  assert_equal "$(inode_of "${TARGET}")" "${before_inode}"
  assert [ ! -s "${TARGET}" ]
  assert_equal "$(journal_names)" ""
  # Blank lines and comments are not keys either: sshd skips leading blanks and then
  # ignores a line that is empty or begins with '#'.
  printf '\n# %s\n   \n\t# and another\n' "${ALICE_KEY}" >"${TARGET}"
  run authorize
  assert_equal "${status}" 3
  assert_output --partial 'ssh.target_no_key'
  assert_equal "$(journal_names)" ""
  # Whitespace alone is not a key, and it is not zero bytes either, which is exactly
  # what [ -s ] could not tell apart.
  printf '\n   \n\t\n' >"${TARGET}"
  assert [ -s "${TARGET}" ]
  run authorize
  assert_equal "${status}" 3
  assert_output --partial 'ssh.target_no_key'
  assert_equal "$(journal_names)" ""
  # One real key line among the comments is a key, and it is still left exactly as it is.
  printf '# a comment\n\n%s\n' "${ALICE_KEY}" >"${TARGET}"
  sha="$(harbor_sha256 "${TARGET}")"
  run authorize
  assert_success
  assert_equal "$(harbor_sha256 "${TARGET}")" "${sha}"
  assert_equal "$(inode_of "${TARGET}")" "${before_inode}"
  assert_equal "$(journal_names)" 0001-authorized-key.json
  assert_equal "$(entry_raw "${FIX_ROOT}" 0001 ownership)" '"observed"'
  harbor_lock_release "${FIX_ROOT}"
}

@test "the operator drop-in is one Match block for the operator, at 0644 under the destination root it is given" {
  acquire
  run configure
  assert_success
  run dropin_settings "${DROPIN}"
  assert_line --index 0 "Match User ${OPERATOR}"
  assert_line --index 1 '  PubkeyAuthentication yes'
  assert_line --index 2 '  PasswordAuthentication no'
  assert_line --index 3 '  KbdInteractiveAuthentication no'
  assert_equal "${#lines[@]}" 4
  # No directive that changes who may log in, anywhere in the file, comments included.
  run cat "${DROPIN}"
  refute_output --partial AllowUsers
  refute_output --partial DenyUsers
  refute_output --partial AllowGroups
  refute_output --partial DenyGroups
  refute_output --partial PermitRootLogin
  assert_equal "$(harbor_stat_mode "${DROPIN}")" 0644
  assert_equal "$(harbor_stat_mode "$(dirname "${DROPIN}")")" 0755
  assert_entry 0001 file "${DROPIN}" created applied '"absent"' "$(harbor_observe_file "${DROPIN}")"
  run ls -A "$(dirname "${DROPIN}")"
  refute_output --partial '.tmp'
  assert_output 50-harbor-operator.conf
  harbor_lock_release "${FIX_ROOT}"
}

@test "the production drop-in paths are the design section 3.5 paths and are only defaults" {
  assert_equal "$(harbor_ssh_dropin_path)" /etc/ssh/sshd_config.d/50-harbor-operator.conf
  assert_equal "$(harbor_ssh_global_dropin_path)" /etc/ssh/sshd_config.d/51-harbor-global.conf
  assert_equal "$(harbor_ssh_dropin_path "${ETC}")" "${DROPIN}"
  assert_equal "$(harbor_ssh_global_dropin_path "${ETC}")" "${GLOBAL_DROPIN}"
  acquire
  run configure
  assert_success
  run harden
  assert_success
  # Nothing outside the fixture configuration root was written.
  run find "${BATS_TEST_TMPDIR}" -name '5?-harbor-*.conf'
  assert_line --index 0 --regexp "^${ETC}/ssh/sshd_config.d/5[01]-harbor-"
  assert_equal "${#lines[@]}" 2
  harbor_lock_release "${FIX_ROOT}"
}

@test "the installation user's whole effective configuration is captured before the drop-in and proved unchanged after it" {
  acquire
  run configure
  assert_success
  run shim_lines
  assert_line --index 0 "sshd${TAB}-T${TAB}-C${TAB}user=${ADMIN}"
  assert_line --index 1 "sshd${TAB}-t"
  assert_line --index 2 "sshd${TAB}-T${TAB}-C${TAB}user=${ADMIN}"
  assert_line --index 3 "sshd${TAB}-T${TAB}-C${TAB}user=${OPERATOR}"
  assert_line --index 4 "systemctl${TAB}is-active${TAB}ssh.service"
  assert_line --index 5 "systemctl${TAB}reload${TAB}ssh.service"
  assert_equal "${#lines[@]}" 6
  # The baseline is the state of the node before the drop-in existed, and the second
  # reading is taken with it in place: that is what makes the comparison a proof.
  run cat "${WITNESS}"
  assert_line --index 0 "absent${TAB}-T -C user=${ADMIN}"
  assert_line --index 1 "present${TAB}-t"
  assert_line --index 2 "present${TAB}-T -C user=${ADMIN}"
  assert_line --index 3 "present${TAB}-T -C user=${OPERATOR}"
  harbor_lock_release "${FIX_ROOT}"
}

@test "a drop-in that moves or adds any directive for the installation user exits 2, names it, and reloads nothing" {
  LEAK=1
  acquire
  run configure
  assert_equal "${status}" 2
  assert_output --partial 'ssh.admin_changed'
  assert_output --partial "${ADMIN}"
  # Every directive that differs is named, the one that moved and the one that appeared.
  assert_output --partial '-passwordauthentication yes'
  assert_output --partial '+passwordauthentication no'
  assert_output --partial '+maxauthtries 3'
  assert_output --partial "${DROPIN}"
  assert_equal "$(shim_calls "reload")" 0
  # The file is in place and the entry stays prepared for recovery, which is what the
  # message says.
  assert [ -f "${DROPIN}" ]
  assert_entry 0001 file "${DROPIN}" created prepared '"absent"' "$(harbor_observe_file "${DROPIN}")"
  # The operator is never asked about while the installation user's proof is failing.
  assert_equal "$(shim_calls "user=${OPERATOR}")" 0
  harbor_lock_release "${FIX_ROOT}"
}

@test "the order sshd prints its directives in does not defeat the proof" {
  SHUFFLE=1
  acquire
  run configure
  assert_success
  assert_equal "$(shim_calls "reload")" 1
  harbor_lock_release "${FIX_ROOT}"
}

@test "both no values are asserted for the operator, and a drop-in that did not take effect exits 2 without reloading" {
  OPERATOR_HARDENING=none
  acquire
  run configure
  assert_equal "${status}" 2
  assert_output --partial 'ssh.operator_not_hardened'
  assert_output --partial 'passwordauthentication no'
  assert_output --partial "${OPERATOR}"
  assert_equal "$(shim_calls "reload")" 0
  assert_entry 0001 file "${DROPIN}" created prepared '"absent"' "$(harbor_observe_file "${DROPIN}")"
  # The other half of the pair: password authentication is off but keyboard-interactive
  # is not, which is still not the row of design section 5.2.
  OPERATOR_HARDENING=password
  run configure
  assert_equal "${status}" 2
  assert_output --partial 'ssh.operator_not_hardened'
  assert_output --partial 'kbdinteractiveauthentication no'
  assert_equal "$(shim_calls "reload")" 0
  harbor_lock_release "${FIX_ROOT}"
}

@test "a failing sshd -t reloads nothing and leaves the entry prepared" {
  SYNTAX_OK=0
  acquire
  run configure
  assert_equal "${status}" 2
  assert_output --partial 'ssh.syntax'
  assert_output --partial 'Bad configuration option'
  assert_output --partial "${DROPIN}"
  assert_equal "$(shim_calls "reload")" 0
  # sshd is never asked for an effective configuration once its own syntax check has
  # refused the file.
  assert_equal "$(shim_calls "user=${OPERATOR}")" 0
  assert_entry 0001 file "${DROPIN}" created prepared '"absent"' "$(harbor_observe_file "${DROPIN}")"
  harbor_lock_release "${FIX_ROOT}"
}

@test "a rerun that finds the drop-in identical journals observed, rewrites nothing, and reloads nothing" {
  acquire
  run configure
  assert_success
  before="$(harbor_observe_file "${DROPIN}")"
  : >"${HARBOR_SHIM_LOG}"
  run configure
  assert_success
  assert_equal "$(harbor_observe_file "${DROPIN}")" "${before}"
  assert_equal "$(shim_calls "reload")" 0
  assert_equal "$(shim_calls "is-active")" 0
  # The assertions still run: they are inspections, and they are what proves the
  # posture of a node Harbor did not have to touch.
  assert_equal "$(shim_calls "^sshd${TAB}-t\$")" 1
  assert_entry 0002 file "${DROPIN}" observed applied "${before}" "${before}"
  run ls -A "${FIX_ROOT}/journal"
  assert_equal "${#lines[@]}" 2
  harbor_lock_release "${FIX_ROOT}"
}

@test "a failing reload exits 2 and leaves the entry prepared, because the running sshd never read the drop-in" {
  reload_fails
  acquire
  run configure
  assert_equal "${status}" 2
  assert_output --partial 'ssh.reload'
  assert_output --partial 'ssh.service'
  # The file is in place and sshd is still holding the configuration it had, so the
  # transaction is not finished and the entry says so rather than claiming it is.
  assert_entry 0001 file "${DROPIN}" created prepared '"absent"' "$(harbor_observe_file "${DROPIN}")"
  harbor_lock_release "${FIX_ROOT}"
}

@test "a rerun after a failed reload reloads the unit the failed run left holding its old configuration" {
  # The convergence a rerun owes. Run one writes the drop-in and the reload fails, so
  # the node is reported unhardened, exit 2. Run two finds the drop-in byte for byte
  # what Harbor renders and rewrites nothing at all; if the reload rode on whether
  # this run wrote the file, run two would return here and report a hardened node
  # while the running sshd still had the configuration it had before.
  reload_fails
  acquire
  run configure
  assert_equal "${status}" 2
  assert_output --partial 'ssh.reload'
  assert [ -f "${DROPIN}" ]
  assert_entry 0001 file "${DROPIN}" created prepared '"absent"' "$(harbor_observe_file "${DROPIN}")"
  before="$(harbor_observe_file "${DROPIN}")"
  reload_succeeds
  : >"${HARBOR_SHIM_LOG}"
  run configure
  assert_success
  # Nothing was rewritten, and the reload that was owed was made.
  assert_equal "$(harbor_observe_file "${DROPIN}")" "${before}"
  assert_equal "$(shim_calls "reload")" 1
  assert_equal "$(entry_raw "${FIX_ROOT}" 0002 ownership)" '"observed"'
  # The transaction the failed run left open is closed only now that sshd has read the
  # file, which is what makes the entry the record of a finished transaction.
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" applied
  # And a third run, on a node that is now genuinely healthy, still makes no mutating
  # call and asks systemctl nothing at all.
  : >"${HARBOR_SHIM_LOG}"
  run configure
  assert_success
  assert_equal "$(shim_calls "reload")" 0
  assert_equal "$(shim_calls "is-active")" 0
  harbor_lock_release "${FIX_ROOT}"
}

@test "the operator assertion proves public-key authentication is on, so an sshd reporting all three as no is refused" {
  # The lockout the two no assertions cannot see. sshd obtained PubkeyAuthentication
  # no ahead of Harbor's Match block, so it reports pubkey, password, and
  # keyboard-interactive all no: both values the row turns off are exactly what the
  # row wants, and the account has no way in at all.
  OPERATOR_PUBKEY=no
  acquire
  run configure
  assert_equal "${status}" 2
  assert_output --partial 'ssh.operator_not_hardened'
  assert_output --partial 'pubkeyauthentication yes'
  # The refusal names what sshd actually reported, not only what Harbor wanted.
  assert_output --partial "it reports 'pubkeyauthentication no'"
  assert_output --partial "${OPERATOR}"
  # The same guarantee the other two carry: exit 2, nothing reloaded, entry prepared.
  assert_equal "$(shim_calls "reload")" 0
  assert_entry 0001 file "${DROPIN}" created prepared '"absent"' "$(harbor_observe_file "${DROPIN}")"
  harbor_lock_release "${FIX_ROOT}"
}

@test "a socket-activated ssh.service is not reloaded, and an unreadable unit state is fail-closed" {
  service_state inactive
  acquire
  run configure
  assert_success
  assert_output --partial 'inactive'
  assert_equal "$(shim_calls "reload")" 0
  assert_entry 0001 file "${DROPIN}" created applied '"absent"' "$(harbor_observe_file "${DROPIN}")"
  # A word outside the vocabulary is what an unreachable manager prints, and it is
  # fail-closed rather than read as "nothing to reload".
  rm -f "${DROPIN}"
  service_state 'Failed to connect to bus: No such file or directory'
  run configure
  assert_equal "${status}" 2
  assert_output --partial 'ssh.service_state'
  assert_equal "$(shim_calls "reload")" 0
  harbor_lock_release "${FIX_ROOT}"
}

@test "a foreign non-regular file at a drop-in path exits 3 untouched, with nothing journaled and no sshd call" {
  mkdir -p "${DROPIN}"
  acquire
  run configure
  assert_equal "${status}" 3
  assert_output --partial 'ssh.dropin_foreign'
  assert_output --partial "${DROPIN}"
  assert [ -d "${DROPIN}" ]
  assert_equal "$(shim_calls)" 0
  assert_equal "$(journal_names)" ""
  # A symlink is not a regular file either, and Harbor removes nothing it cannot prove
  # it created.
  rm -r "${DROPIN}"
  ln -s "${BATS_TEST_TMPDIR}/elsewhere" "${DROPIN}"
  run configure
  assert_equal "${status}" 3
  assert_output --partial 'ssh.dropin_foreign'
  assert [ -L "${DROPIN}" ]
  assert_equal "$(journal_names)" ""
  harbor_lock_release "${FIX_ROOT}"
}

@test "recovery decides a prepared drop-in entry from the states harbor_observe_file renders" {
  acquire
  run configure
  assert_success
  post="$(harbor_observe_file "${DROPIN}")"
  rm -f "${DROPIN}"
  fixture_entry "${FIX_ROOT}" 0002 file "${DROPIN}" created prepared '"absent"' "${post}"
  run harbor_journal_recover "${FIX_ROOT}"
  assert_success
  assert_equal "$(entry_phase "${FIX_ROOT}" 0002)" reverted
  run configure
  assert_success
  fixture_entry "${FIX_ROOT}" 0004 file "${DROPIN}" created prepared '"absent"' "${post}"
  run harbor_journal_recover "${FIX_ROOT}"
  assert_success
  assert_equal "$(entry_phase "${FIX_ROOT}" 0004)" applied
  harbor_lock_release "${FIX_ROOT}"
}

@test "--harden-sshd refuses unless the installation user has an authorized key" {
  acquire
  # Missing: the global drop-in would take away the installation user's password and
  # leave them nothing to log in with.
  rm "${HOMES}/${ADMIN}/.ssh/authorized_keys"
  run harden
  assert_equal "${status}" 3
  assert_output --partial 'ssh.harden_no_key'
  assert_output --partial "${HOMES}/${ADMIN}/.ssh/authorized_keys"
  assert_output --partial '--harden-sshd'
  assert [ ! -e "${GLOBAL_DROPIN}" ]
  assert_equal "$(journal_names)" ""
  assert_equal "$(shim_calls)" 0
  # Empty is not a key either.
  : >"${HOMES}/${ADMIN}/.ssh/authorized_keys"
  run harden
  assert_equal "${status}" 3
  assert_output --partial 'ssh.harden_no_key'
  assert [ ! -e "${GLOBAL_DROPIN}" ]
  # Unreadable is not a key either: these tests are unprivileged, so mode 0000 really
  # is unreadable.
  printf '%s\n' "${ALICE_KEY}" >"${HOMES}/${ADMIN}/.ssh/authorized_keys"
  chmod 0000 "${HOMES}/${ADMIN}/.ssh/authorized_keys"
  run harden
  assert_equal "${status}" 3
  assert_output --partial 'ssh.harden_no_key'
  assert [ ! -e "${GLOBAL_DROPIN}" ]
  assert_equal "$(journal_names)" ""
  chmod 0600 "${HOMES}/${ADMIN}/.ssh/authorized_keys"
  run harden
  assert_success
  assert [ -f "${GLOBAL_DROPIN}" ]
  harbor_lock_release "${FIX_ROOT}"
}

@test "--harden-sshd refuses a file that is not zero bytes and holds no key, which is what would strand the administrator mid-session" {
  # The one refusal standing between this flag and an unreachable node. It sets
  # PermitRootLogin no and PasswordAuthentication no for every account, so the account
  # it would strand is the administrator running the command over SSH at that moment,
  # and root behind them. [ -s ] accepted both of these files.
  acquire
  printf '# my key is on the other laptop\n' >"${HOMES}/${ADMIN}/.ssh/authorized_keys"
  assert [ -s "${HOMES}/${ADMIN}/.ssh/authorized_keys" ]
  run harden
  assert_equal "${status}" 3
  assert_output --partial 'ssh.harden_no_key'
  assert_output --partial 'no usable authorized-key line'
  assert_output --partial "${HOMES}/${ADMIN}/.ssh/authorized_keys"
  assert_output --partial '--harden-sshd'
  assert [ ! -e "${GLOBAL_DROPIN}" ]
  assert_equal "$(journal_names)" ""
  # Refused before any vendor command, so a node in that state is left exactly as it is.
  assert_equal "$(shim_calls)" 0
  # Whitespace alone is the same refusal.
  printf '\n   \n\t\n' >"${HOMES}/${ADMIN}/.ssh/authorized_keys"
  assert [ -s "${HOMES}/${ADMIN}/.ssh/authorized_keys" ]
  run harden
  assert_equal "${status}" 3
  assert_output --partial 'ssh.harden_no_key'
  assert [ ! -e "${GLOBAL_DROPIN}" ]
  assert_equal "$(shim_calls)" 0
  # A comment above a real key is a key, and the flag is allowed through.
  printf '# ubuntu\n%s\n' "${ALICE_KEY}" >"${HOMES}/${ADMIN}/.ssh/authorized_keys"
  run harden
  assert_success
  assert [ -f "${GLOBAL_DROPIN}" ]
  harbor_lock_release "${FIX_ROOT}"
}

@test "--harden-sshd writes a separate journaled file that the unchanged-directive proof does not judge" {
  acquire
  run configure
  assert_success
  operator_dropin="$(harbor_observe_file "${DROPIN}")"
  : >"${HARBOR_SHIM_LOG}"
  run harden
  assert_success
  run dropin_settings "${GLOBAL_DROPIN}"
  assert_line --index 0 'PermitRootLogin no'
  assert_line --index 1 'PasswordAuthentication no'
  assert_equal "${#lines[@]}" 2
  assert_equal "$(harbor_stat_mode "${GLOBAL_DROPIN}")" 0644
  # Its own entry, at its own path, and the operator drop-in untouched.
  assert_entry 0002 file "${GLOBAL_DROPIN}" created applied '"absent"' "$(harbor_observe_file "${GLOBAL_DROPIN}")"
  assert_equal "$(harbor_observe_file "${DROPIN}")" "${operator_dropin}"
  # Global hardening changes the installation user's own effective configuration, so
  # the operator drop-in's unchanged-for-every-directive proof is not applied to it.
  run admin_config
  assert_output --partial 'permitrootlogin no'
  run shim_lines
  assert_line --index 0 "sshd${TAB}-t"
  assert_line --index 1 "systemctl${TAB}is-active${TAB}ssh.service"
  assert_line --index 2 "systemctl${TAB}reload${TAB}ssh.service"
  assert_equal "${#lines[@]}" 3
  harbor_lock_release "${FIX_ROOT}"
}

@test "a user name sshd could not safely be told is refused, and the argument list is checked" {
  acquire
  run harbor_ssh_configure "${FIX_ROOT}" 'harbor
Match User root' "${ADMIN}" "${ETC}"
  assert_equal "${status}" 3
  assert_output --partial 'ssh.user_name'
  assert [ ! -e "${DROPIN}" ]
  assert_equal "$(journal_names)" ""
  assert_equal "$(shim_calls)" 0
  run harbor_ssh_configure "${FIX_ROOT}" "${OPERATOR}" 'alice bob' "${ETC}"
  assert_equal "${status}" 3
  assert_output --partial 'ssh.user_name'
  run harbor_ssh_configure "${FIX_ROOT}" "${OPERATOR}"
  assert_equal "${status}" 3
  assert_output --partial usage
  run harbor_ssh_configure "${FIX_ROOT}" "${OPERATOR}" "${ADMIN}" "${ETC}" extra
  assert_equal "${status}" 3
  assert_output --partial usage
  run harbor_ssh_harden "${FIX_ROOT}"
  assert_equal "${status}" 3
  assert_output --partial usage
  assert_equal "$(journal_names)" ""
  harbor_lock_release "${FIX_ROOT}"
}

@test "no cp, chmod, chown, or mkdir in lib/ssh.sh names a path under the operator's home" {
  # The required property read straight off the code, which is where it has to hold:
  # cp, chmod, chown, and mkdir all resolve the final component of their argument
  # through whatever symlink is there, and every component under the operator's home is
  # one the operator can unlink and replace. So none of them may name ${home},
  # ${ssh_dir}, or ${target}; they name a staging path in the root-owned state root
  # instead. The renames are exempt and are the only operations in this library allowed
  # to name those three, because rename(2) resolves neither final component and unlinks
  # a planted symlink rather than writing through it.
  run code_naming '^[[:space:]]*\(cp\|chmod\|chown\|mkdir\)[[:space:]]'
  assert_success
  refute_output --partial '"${home}"'
  refute_output --partial '"${ssh_dir}"'
  refute_output --partial '"${target}"'
  # The staging paths they do name are the two built from the state root.
  assert_output --partial '"${stage}"'
  assert_output --partial '"${tmp}"'
}

@test "lib/ssh.sh names no state root and reaches no system path but the /etc default" {
  run code_naming '/var/lib\|/usr/local\|/opt\|/home'
  assert_output ''
  # /etc is reached by no line of code but the default of the two destination-root
  # parameters, so no unit test can reach the production configuration root.
  run code_naming '/etc'
  assert_line --index 0 --partial '"${1:-/etc}"'
  assert_line --index 1 --partial '"${1:-/etc}"'
  assert_equal "${#lines[@]}" 2
}

@test "an sshd that exits 0 and prints no effective configuration at all is fail-closed" {
  EMPTY_CONFIG=1
  acquire
  run configure
  assert_equal "${status}" 2
  assert_output --partial 'ssh.effective'
  assert_output --partial "${ADMIN}"
  # It is refused before anything is written, so the proof is never passed by an empty
  # answer being equal to another empty answer.
  assert [ ! -e "${DROPIN}" ]
  assert_equal "$(journal_names)" ""
  assert_equal "$(shim_calls "reload")" 0
  harbor_lock_release "${FIX_ROOT}"
}
