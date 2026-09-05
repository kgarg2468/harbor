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
  # sshd's own default, and the one Harbor asserts rather than sets: it is what makes an
  # authorized_keys owned by neither root nor the account logging in be ignored.
  printf 'strictmodes yes\n'
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
  # ADMIN_PUBKEY=no models the node --harden-sshd must refuse before it reloads: a drop-in
  # sorting before Harbor's, or a global PubkeyAuthentication no, was obtained ahead of
  # 51-harbor-global.conf, and OpenSSH keeps the first value it gets for a keyword, so key
  # authentication is off for the installation user whatever Harbor's file says. The
  # configuration still parses, so sshd -t has nothing to object to; what the reload would
  # do is take this account's password and root login away as well.
  if [ "${ADMIN_PUBKEY:-yes}" != yes ]; then
    lines="$(printf '%s\n' "${lines}" | sed -e 's/^pubkeyauthentication .*/pubkeyauthentication no/')"
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
  # OPERATOR_STRICTMODES=no models an administrator who turned StrictModes off. Harbor
  # never writes that directive, so the only honest answer to finding it off is a refusal:
  # the placement of an authorized key stops being self-guarding without it.
  [ "${OPERATOR_STRICTMODES:-yes}" = yes ] \
    || lines="$(printf '%s\n' "${lines}" | sed -e 's/^strictmodes .*/strictmodes no/')"
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

admin_key() {
  printf '%s/%s/.ssh/authorized_keys' "${HOMES}" "${ADMIN}"
}

admin_key_owner() {
  # admin_key_owner [NAME]: make the installation user's own authorized_keys report NAME,
  # the installation user by default, as its owner. chown is the one call an unprivileged
  # test cannot make, so a file belonging to an account the test cannot create has no other
  # way to exist in a fixture: every file here belongs to the account the tests run as,
  # which is neither ${ADMIN} nor root, so without this seam every --harden-sshd test would
  # be modeling the very node the refusal under test exists to catch rather than the path it
  # is about. The library's own helper is the seam, wrapped for that one path; every other
  # path in the run is answered the real way, read exactly as lib/journal.sh reads it, so
  # nothing else any test observes is faked.
  FAKE_ADMIN_KEY_OWNER="${1:-${ADMIN}}"
  ADMIN_KEY_PATH="$(admin_key)"
  harbor_stat_owner() {
    if [ "${1}" = "${ADMIN_KEY_PATH}" ]; then
      printf '%s' "${FAKE_ADMIN_KEY_OWNER}"
      return 0
    fi
    case "$(harbor_os)" in
      Linux) stat -c '%U' "${1}" ;;
      Darwin) stat -f '%Su' "${1}" ;;
    esac
  }
}

staged_key_dir() {
  # The directory the authorized key is staged in, which is a directory of its own inside
  # the state root rather than a file lying directly in it.
  ls -d "${FIX_ROOT}"/.tmp.key.* 2>/dev/null || true
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
  # The name is the one Harbor stages the key under, which is now a directory in the state
  # root: mkdir, cp, chmod, and chown would each resolve a link at it if any of them ever
  # named it under the operator's home.
  planted="${SSH_DIR}/.tmp.key.${HARBOR_LOCK_ID_PID}"
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
  #
  # The state root being 0755 is why the key is not staged directly in it. 0755 is
  # traversable by every account on the node, so a file lying in it that has been chowned
  # to the operator is a file the operator can open and write; the key is staged one level
  # down instead, in a directory of its own that is created 0700 and never given away, and
  # search permission on that directory is what the operator does not have.
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
  run find "${FIX_ROOT}" -maxdepth 1 -name '.tmp.key.*'
  assert_equal "${#lines[@]}" 1
  staged_dir="${lines[0]}"
  staged="${staged_dir}/authorized_keys"
  assert_equal "$(harbor_stat_mode "${staged}")" 0600
  assert_equal "$(harbor_stat_owner "${staged}")" "${OPERATOR}"
  assert_equal "$(cat "${staged}")" "${ALICE_KEY}"
  # And the directory holding it is 0700. These tests are unprivileged, so root and the
  # operator are one account here and no assertion made in this fixture can tell a
  # root-owned directory from an operator-owned one; the mode is the half that is
  # observable, and that the directory is never chowned is read straight off the code by
  # the test below. The file is the only thing in there, so nothing else was staged at a
  # name the operator could have guessed.
  assert_equal "$(harbor_stat_mode "${staged_dir}")" 0700
  assert_equal "$(ls -A "${staged_dir}")" authorized_keys
  # Nothing is staged directly in the 0755 state root, which is where it used to be.
  run find "${FIX_ROOT}" -maxdepth 1 -type f -name '.tmp.*'
  assert_equal "${#lines[@]}" 0
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

@test "a pre-existing authorized_keys owned by another account is refused, and one owned by root is not" {
  # Content is not the whole of it. StrictModes, which harbor_ssh_assert_operator now
  # asserts of this node, makes sshd refuse an authorized_keys owned by neither root nor
  # the account logging in, whatever key is in it. A file holding a perfectly good key that
  # sshd will not read strands the operator exactly as a file holding no key does: the sshd
  # row takes password and keyboard-interactive authentication away from an account sshd
  # will not let in by key either, and the observed arm judged content alone.
  mkdir -p "${SSH_DIR}"
  chmod 0700 "${SSH_DIR}"
  printf '%s\n' "${ALICE_KEY}" >"${TARGET}"
  chmod 0600 "${TARGET}"
  before_inode="$(inode_of "${TARGET}")"
  # chown is the one call an unprivileged test cannot make, so a file belonging to a third
  # account has no other way to exist in a fixture. The library's own helper is the seam,
  # wrapped for that one path; every other path in the run is answered the real way, read
  # exactly as lib/journal.sh reads it.
  harbor_stat_owner() {
    if [ "${1}" = "${TARGET}" ]; then
      printf '%s' "${FAKE_TARGET_OWNER}"
      return 0
    fi
    case "$(harbor_os)" in
      Linux) stat -c '%U' "${1}" ;;
      Darwin) stat -f '%Su' "${1}" ;;
    esac
  }
  FAKE_TARGET_OWNER=mallory
  acquire
  run authorize
  assert_equal "${status}" 3
  assert_output --partial 'ssh.target_unusable'
  assert_output --partial mallory
  assert_output --partial 'StrictModes'
  assert_output --partial "${TARGET}"
  assert_output --partial 'password'
  # A refusal, never a repair: Harbor changes nothing it did not create, so the file keeps
  # its mode and its inode, and nothing is journaled for a later row to act on.
  assert_equal "$(inode_of "${TARGET}")" "${before_inode}"
  assert_equal "$(harbor_stat_mode "${TARGET}")" 0600
  assert_equal "$(journal_names)" ""
  # root is the other owner sshd reads a key file from, so a file root owns is accepted and
  # journaled observed, exactly as the operator's own is.
  FAKE_TARGET_OWNER=root
  run authorize
  assert_success
  assert_equal "$(inode_of "${TARGET}")" "${before_inode}"
  assert_equal "$(journal_names)" 0001-authorized-key.json
  assert_equal "$(entry_raw "${FIX_ROOT}" 0001 ownership)" '"observed"'
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" applied
  harbor_lock_release "${FIX_ROOT}"
}

@test "a pre-existing authorized_keys that is group- or world-writable is refused, and 0640 and 0644 are not" {
  # The other half of what StrictModes tests: sshd refuses a key file its group or the
  # whole node can write, because anyone who can write it can add a key to it. Harbor
  # accepting one and then taking password authentication away from the account is a
  # lockout Harbor causes.
  mkdir -p "${SSH_DIR}"
  chmod 0700 "${SSH_DIR}"
  printf '%s\n' "${ALICE_KEY}" >"${TARGET}"
  chmod 0664 "${TARGET}"
  before_inode="$(inode_of "${TARGET}")"
  sha="$(harbor_sha256 "${TARGET}")"
  acquire
  run authorize
  assert_equal "${status}" 3
  assert_output --partial 'ssh.target_unusable'
  assert_output --partial 'group-writable'
  assert_output --partial '0664'
  assert_output --partial 'StrictModes'
  assert_equal "$(harbor_stat_mode "${TARGET}")" 0664
  assert_equal "$(inode_of "${TARGET}")" "${before_inode}"
  assert_equal "$(journal_names)" ""
  # World-writable is named for what it is rather than folded into the group case.
  chmod 0666 "${TARGET}"
  run authorize
  assert_equal "${status}" 3
  assert_output --partial 'ssh.target_unusable'
  assert_output --partial 'world-writable'
  assert_output --partial '0666'
  assert_equal "$(harbor_stat_mode "${TARGET}")" 0666
  assert_equal "$(journal_names)" ""
  # And the modes sshd reads are still accepted. The test is writability, not equality with
  # 0600: 0640 and 0644 are legitimate administrator choices that StrictModes has nothing
  # against, and refusing a node Harbor has no complaint about is a lockout of its own kind.
  chmod 0640 "${TARGET}"
  run authorize
  assert_success
  assert_equal "$(harbor_stat_mode "${TARGET}")" 0640
  assert_equal "$(journal_names)" 0001-authorized-key.json
  chmod 0644 "${TARGET}"
  run authorize
  assert_success
  assert_equal "$(harbor_stat_mode "${TARGET}")" 0644
  assert_equal "$(harbor_sha256 "${TARGET}")" "${sha}"
  assert_equal "$(inode_of "${TARGET}")" "${before_inode}"
  run journal_names
  assert_line --index 1 0002-authorized-key.json
  assert_equal "${#lines[@]}" 2
  assert_equal "$(entry_raw "${FIX_ROOT}" 0002 ownership)" '"observed"'
  assert_equal "$(entry_phase "${FIX_ROOT}" 0002)" applied
  harbor_lock_release "${FIX_ROOT}"
}

paused_authorize() {
  # paused_authorize STEP: harbor_ssh_authorize in a child paused at STEP, so the window
  # between two steps can be interposed on the way an operator with a process on the node
  # would interpose on it. env execs bash, so PAUSED_PID is the process whose $$ becomes
  # HARBOR_PID: the pid in the pause sentinel's name and in the staged file's name both.
  PAUSE_LOG="${BATS_TEST_TMPDIR}/steps.log"
  : >"${PAUSE_LOG}"
  env HARBOR_TEST_HOOKS=1 HARBOR_PAUSE_AFTER="${1}" SUDO_USER=alice HARBOR_LOG_FILE="${PAUSE_LOG}" \
    bash -c '. "${HARBOR_ROOT}/lib/log.sh"; . "${HARBOR_ROOT}/lib/lock.sh"; . "${HARBOR_ROOT}/lib/journal.sh"; . "${HARBOR_ROOT}/lib/ssh.sh"; HARBOR_PID=$$; harbor_lock_acquire "${1}" operator; harbor_ssh_authorize "${1}" "${2}" "${3}"' \
    _ "${FIX_ROOT}" "${OPERATOR}" "${OP_HOME}" >"${BATS_TEST_TMPDIR}/child.out" 2>&1 &
  PAUSED_PID=$!
  # harbor_step logs its step before harbor_test_hook pauses on it, so this line appearing
  # is the child having reached the boundary, not merely being on its way to it.
  local i=0
  until grep -q "step ${1}\$" "${PAUSE_LOG}" 2>/dev/null; do
    i=$((i + 1))
    [ "${i}" -le 100 ] || fail "the child never reached ${1}"
    sleep 0.1
  done
}

resume_paused() {
  # resume_paused STEP: release the child paused at STEP and return its exit status.
  touch "$(pause_sentinel "${PAUSED_PID}" "${1}")"
  PAUSED_STATUS=0
  wait "${PAUSED_PID}" || PAUSED_STATUS="$?"
  # The child held its own lock and died holding it; production reclaims a lock like that,
  # and these tests remove it so a later acquire in the same test is not refused.
  rm -rf "${FIX_ROOT}/lock.d" "${FIX_ROOT}/reclaim.d"
}

@test "a .ssh swapped for a symlink between the check and the rename does not redirect the key, and is refused by name" {
  # rename(2) resolves the directories above its destination at the instant it runs, and ~
  # is the operator's, so proving ~/.ssh is a 0700 directory owned by the operator proves
  # nothing about what ~/.ssh will be by the time the key is renamed into it. An operator
  # with a process on the node replaces it in that window and root writes the key through
  # the link. The rename enters a directory and proves that ~/.ssh still denotes that very
  # directory and is not a symlink, so it must not follow.
  mkdir -p "${SSH_DIR}"
  chmod 0700 "${SSH_DIR}"
  decoy="${BATS_TEST_TMPDIR}/decoy"
  mkdir -p "${decoy}"
  paused_authorize ssh-key-prepared
  rmdir "${SSH_DIR}"
  ln -s "${decoy}" "${SSH_DIR}"
  resume_paused ssh-key-prepared
  # First, and on its own: the key is not in the directory the operator aimed the link at.
  # An unpinned rename fails this line and only then reports, having already written the
  # key through the link, which is the difference between refusing and noticing too late.
  assert [ ! -e "${decoy}/authorized_keys" ]
  assert_equal "${PAUSED_STATUS}" 2
  run cat "${BATS_TEST_TMPDIR}/child.out"
  assert_output --partial 'ssh.ssh_dir_swapped'
  # And nothing was left staged in the state root for a later run to pick up.
  assert [ -z "$(staged_key_dir)" ]
  # The transaction is unfinished, not silently abandoned: recovery still owns it.
  assert_equal "$(entry_phase "${FIX_ROOT}" 0002)" prepared
}

@test "a .ssh swapped for another 0700 directory the operator owns is refused by identity, not by mode" {
  # Owner and mode do not identify a directory. The operator owns its home and may own
  # other 0700 directories under it, so a link aimed at one of those answers both of those
  # checks while the key lands where the operator chose. The operator would then have no
  # key where sshd looks for one, and the sshd row would take password authentication away
  # from the account regardless, so this is a lockout the checks would have waved through.
  # What '.' is held against is the name itself: ~/.ssh must not be a symlink and must reach
  # the very directory the rename entered, which a name aimed elsewhere cannot do.
  mkdir -p "${SSH_DIR}"
  chmod 0700 "${SSH_DIR}"
  decoy="${BATS_TEST_TMPDIR}/decoy"
  mkdir -p "${decoy}"
  chmod 0700 "${decoy}"
  paused_authorize ssh-key-prepared
  rmdir "${SSH_DIR}"
  ln -s "${decoy}" "${SSH_DIR}"
  resume_paused ssh-key-prepared
  assert [ ! -e "${decoy}/authorized_keys" ]
  assert_equal "${PAUSED_STATUS}" 2
  run cat "${BATS_TEST_TMPDIR}/child.out"
  assert_output --partial 'ssh.ssh_dir_swapped'
  # By identity rather than by mode, which the decoy deliberately satisfies.
  assert_output --partial 'no longer the same directory'
  assert [ -z "$(staged_key_dir)" ]
  assert_equal "$(entry_phase "${FIX_ROOT}" 0002)" prepared
}

@test "a .ssh swapped before anything downstream has read the name lands no key in the decoy either" {
  # The window the two tests above cannot see. Both of them interpose after ~/.ssh had
  # already been read once by the run they interrupt, so neither covers a run that reads the
  # name for the first time with the operator's decoy already under it: the identity the
  # rename used to be held against was itself read by path, in this window, and a reading
  # taken here is a reading of whatever the operator has just put there.
  #
  # What the run must do is the same in both windows, and it is proved in the pin rather
  # than by anything read outside it: the key goes into the directory the name ${SSH_DIR}
  # denotes at the moment of the write, and a name that is a symlink denotes no such
  # directory. Nothing read here is consulted for it, so nothing done here can be trusted.
  #
  # This does not fail against the shape it replaced, and the summary of the change says so:
  # harbor_ssh_path_id reads with lstat, so the identity captured here was the link's own and
  # never agreed with a directory that had been entered. The refusal below was reached by
  # that accident before and is reached by a stated check now.
  mkdir -p "${SSH_DIR}"
  chmod 0700 "${SSH_DIR}"
  decoy="${BATS_TEST_TMPDIR}/decoy"
  mkdir -p "${decoy}"
  chmod 0700 "${decoy}"
  paused_authorize ssh-dir-checked
  rmdir "${SSH_DIR}"
  ln -s "${decoy}" "${SSH_DIR}"
  resume_paused ssh-dir-checked
  # First, and on its own: no key is in the directory the operator aimed the name at, and
  # nothing else was put there either. A run that trusted an identity captured by path
  # fails this line having already written the key through the link.
  assert [ ! -e "${decoy}/authorized_keys" ]
  assert_equal "$(ls -A "${decoy}")" ""
  assert_equal "${PAUSED_STATUS}" 2
  run cat "${BATS_TEST_TMPDIR}/child.out"
  assert_output --partial 'ssh.ssh_dir_swapped'
  assert_output --partial 'no longer the same directory'
  # Nothing was left staged in the state root for a later run to pick up, and the
  # transaction is unfinished rather than abandoned: recovery still owns it.
  assert [ -z "$(staged_key_dir)" ]
  assert_equal "$(entry_phase "${FIX_ROOT}" 0002)" prepared
}

@test "a .ssh that is a different directory by the time the key is written is still written into, because by then it is ~/.ssh" {
  # The other half of proving the directory inside the pin rather than carrying a value into
  # it, and the half that says which of the two shapes is the sound one. An identity read
  # before the rename says what ~/.ssh was then; what the write has to be about is what
  # ~/.ssh is at the moment of the write. An operator that moves a 0700 directory of its own
  # onto ~/.ssh has an ~/.ssh that is that directory: nothing is being redirected, that is
  # the operator's own .ssh now, and a key there is a key where sshd looks for one, which is
  # what was asked for. A rename held against an identity read earlier refuses this run
  # instead and leaves the account with no key at all, which is the same account with no way
  # in seen from the other side, so it is the earlier reading that has to go rather than be
  # taken more carefully.
  mkdir -p "${SSH_DIR}"
  chmod 0700 "${SSH_DIR}"
  other="${BATS_TEST_TMPDIR}/other"
  mkdir -p "${other}"
  chmod 0700 "${other}"
  paused_authorize ssh-key-prepared
  mv "${SSH_DIR}" "${BATS_TEST_TMPDIR}/hidden"
  mv "${other}" "${SSH_DIR}"
  resume_paused ssh-key-prepared
  run cat "${BATS_TEST_TMPDIR}/child.out"
  assert_equal "${PAUSED_STATUS}" 0
  # The key is at the path sshd reads, is the key that was staged, and carries the mode and
  # the owner Harbor stages before anything of the operator's is touched.
  assert_equal "$(cat "${TARGET}")" "${ALICE_KEY}"
  assert_equal "$(harbor_stat_mode "${TARGET}")" 0600
  assert_equal "$(harbor_stat_owner "${TARGET}")" "${OPERATOR}"
  # And nothing was written into the directory that stopped being ~/.ssh, which is the
  # directory the checks before the pin had passed on.
  assert_equal "$(ls -A "${BATS_TEST_TMPDIR}/hidden")" ""
  assert [ -z "$(staged_key_dir)" ]
  assert_equal "$(entry_phase "${FIX_ROOT}" 0002)" applied
}

@test "a staged key whose bytes change before it is journaled is refused rather than journaled as the key" {
  # What the journal records for the key is one observation of the staged file, and that
  # observation is also what the check after the rename compares what landed against, so a
  # file whose bytes are not the ones read from the source must never reach it: the two
  # would agree on the wrong key and the journal would vouch for it. The sha taken before
  # the chown is what the observation is held against, and it is the observation itself
  # that is checked rather than a further reading of the file, so what is checked and what
  # is used are one value.
  #
  # A 0700 staging directory is what keeps the operator out of this window on a real node;
  # this test is unprivileged and owns everything in the fixture, so it stands in for any
  # cause at all of the staged bytes changing and proves the refusal, not the permission.
  mkdir -p "${SSH_DIR}"
  chmod 0700 "${SSH_DIR}"
  paused_authorize ssh-key-staged
  printf '%s\n' 'ssh-ed25519 FIXTUREKEYMALLORY mallory@example.com' >"${FIX_ROOT}/.tmp.key.${PAUSED_PID}/authorized_keys"
  resume_paused ssh-key-staged
  assert_equal "${PAUSED_STATUS}" 2
  run cat "${BATS_TEST_TMPDIR}/child.out"
  assert_output --partial 'ssh.stage_changed'
  assert [ ! -e "${TARGET}" ]
  refute_output --partial FIXTUREKEYMALLORY
  # Nothing was journaled for the target at all, so no later row can act on a key that was
  # never proved to be the administrator's.
  assert_equal "$(journal_names)" 0001-authorized-key-source.json
}

@test "a file of prose is not a key: the predicate takes options and certificates and refuses text" {
  # Every caller of this predicate stands between a flag and an account with no way in, so
  # it is wrong in both directions: refusing a real key denies the administrator a flag,
  # and accepting text disables password authentication for an account that cannot log in.
  local f="${BATS_TEST_TMPDIR}/k"
  # Keys, including the option-prefixed and certificate forms an anchored test would miss.
  for line in \
    'ssh-ed25519 AAAAC3NzaC1lZDI1 alice@example.com' \
    'restrict,from="10.0.0.0/8" ssh-ed25519 AAAAC3NzaC1lZDI1 alice' \
    'command="ls -l",no-pty ssh-rsa AAAAB3NzaC1yc2E bob' \
    'ssh-ed25519-cert-v01@openssh.com AAAAIHNzaC1 cert' \
    'sk-ssh-ed25519@openssh.com AAAAGnNrLXNz token' \
    'ecdsa-sha2-nistp256 AAAAE2VjZHNh e'; do
    printf '%s\n' "${line}" >"${f}"
    harbor_ssh_has_usable_key "${f}" || fail "refused a key: ${line}"
  done
  # A key among comments is still a key.
  printf '# mine\n\nssh-rsa AAAAB3NzaC1yc2E bob\n' >"${f}"
  assert harbor_ssh_has_usable_key "${f}"
  # Not keys. The commented-out key is why comments are stripped before the type token is
  # looked for rather than after: one pass over the whole file would match it.
  for line in \
    'my key is on the other laptop' \
    'hello world' \
    '# ssh-ed25519 AAAAC3NzaC1lZDI1 alice@example.com' \
    'ssh-ed25519'; do
    printf '%s\n' "${line}" >"${f}"
    ! harbor_ssh_has_usable_key "${f}" || fail "accepted text as a key: ${line}"
  done
}

@test "an sshd with StrictModes off is refused: without it a key file reaching the wrong path is a key file that works there" {
  # The one asserted directive Harbor does not write. sshd ignores an authorized_keys
  # owned by neither root nor the account logging in, and that is the backstop behind the
  # directory the key is renamed into. Harbor asserts it rather than turning it back on.
  # The drop-in takes effect for all three directives it writes, so this node differs from
  # a good one in StrictModes alone and nothing else can be what the refusal is about.
  OPERATOR_STRICTMODES=no
  acquire
  run configure
  assert_equal "${status}" 2
  assert_output --partial 'ssh.operator_not_hardened'
  assert_output --partial 'strictmodes yes'
  assert_output --partial "it reports 'strictmodes no'"
  # Refused before anything is reloaded, as the other assertions on this row are.
  assert_equal "$(shim_calls "reload")" 0
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
  admin_key_owner
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
  admin_key_owner
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
  admin_key_owner
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
  admin_key_owner
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
  # sshd is asked what it would do for the installation user between its own syntax check
  # and the reload, which is the whole of what stands between this flag and an account
  # with no way in once its password and root login are gone.
  run shim_lines
  assert_line --index 0 "sshd${TAB}-t"
  assert_line --index 1 "sshd${TAB}-T${TAB}-C${TAB}user=${ADMIN}"
  assert_line --index 2 "systemctl${TAB}is-active${TAB}ssh.service"
  assert_line --index 3 "systemctl${TAB}reload${TAB}ssh.service"
  assert_equal "${#lines[@]}" 4
  harbor_lock_release "${FIX_ROOT}"
}

@test "--harden-sshd refuses an installation user's key file sshd would ignore, and writes nothing when it does" {
  # The gate judged this file by its bytes alone. StrictModes makes sshd ignore an
  # authorized_keys owned by neither root nor the account logging in, and ignore one that
  # is group- or world-writable, whatever key is in it, so a file full of perfectly good
  # keys can be a file sshd will never read. --harden-sshd sets PermitRootLogin no and
  # PasswordAuthentication no for every account, so the administrator whose own key file
  # sshd ignores loses password login, root login, and key login in one reload, from the
  # session they are running the command in. Content alone cannot tell that node from a
  # healthy one.
  acquire
  # Owned by a third account: neither root nor the installation user.
  admin_key_owner mallory
  run harden
  assert_equal "${status}" 3
  assert_output --partial 'ssh.harden_key_unusable'
  assert_output --partial mallory
  assert_output --partial 'StrictModes'
  assert_output --partial "$(admin_key)"
  assert_output --partial '--harden-sshd'
  assert_output --partial "${ADMIN}"
  # Nothing written, nothing journaled, and refused before any vendor command, so the node
  # is left exactly as it is and --harden-sshd is not applied.
  assert [ ! -e "${GLOBAL_DROPIN}" ]
  assert_equal "$(journal_names)" ""
  assert_equal "$(shim_calls)" 0
  # A refusal, never a repair: Harbor changes nothing it did not create, so the file keeps
  # the mode it had.
  assert_equal "$(harbor_stat_mode "$(admin_key)")" 0600
  # Group-writable: sshd refuses a key file every member of its group could add a key to.
  admin_key_owner
  chmod 0664 "$(admin_key)"
  run harden
  assert_equal "${status}" 3
  assert_output --partial 'ssh.harden_key_unusable'
  assert_output --partial 'group-writable'
  assert_output --partial '0664'
  assert_output --partial 'StrictModes'
  assert [ ! -e "${GLOBAL_DROPIN}" ]
  assert_equal "$(journal_names)" ""
  assert_equal "$(shim_calls)" 0
  assert_equal "$(harbor_stat_mode "$(admin_key)")" 0664
  # World-writable is named for what it is rather than folded into the group case.
  chmod 0666 "$(admin_key)"
  run harden
  assert_equal "${status}" 3
  assert_output --partial 'ssh.harden_key_unusable'
  assert_output --partial 'world-writable'
  assert_output --partial '0666'
  assert [ ! -e "${GLOBAL_DROPIN}" ]
  assert_equal "$(journal_names)" ""
  assert_equal "$(shim_calls)" 0
  harbor_lock_release "${FIX_ROOT}"
}

@test "--harden-sshd accepts an installation user's key file at any mode sshd reads, and one owned by root" {
  # The other direction, and the reason the mode test is writability rather than equality
  # with 0600: 0644 is a mode sshd reads happily and an administrator's own choice, and
  # refusing it would deny a flag that was safe to give, which is a lockout of its own
  # kind. root is the other owner sshd reads a key file from.
  admin_key_owner
  chmod 0644 "$(admin_key)"
  acquire
  run harden
  assert_success
  assert [ -f "${GLOBAL_DROPIN}" ]
  assert_equal "$(harbor_stat_mode "$(admin_key)")" 0644
  assert_entry 0001 file "${GLOBAL_DROPIN}" created applied '"absent"' "$(harbor_observe_file "${GLOBAL_DROPIN}")"
  # A file owned by root is read by sshd for any account, so it is accepted too.
  rm -f "${GLOBAL_DROPIN}"
  admin_key_owner root
  chmod 0600 "$(admin_key)"
  run harden
  assert_success
  assert [ -f "${GLOBAL_DROPIN}" ]
  harbor_lock_release "${FIX_ROOT}"
}

@test "--harden-sshd refuses to reload a node whose installation user has no key authentication left" {
  # sshd -t proves the configuration parses and says nothing about which value any keyword
  # ends up with. OpenSSH keeps the first value it obtains for a keyword and Ubuntu's
  # sshd_config includes sshd_config.d/*.conf in lexical order, so a drop-in sorting before
  # 51-harbor-global.conf, or a global PubkeyAuthentication no, is the value sshd uses.
  # That node passes the syntax check, and the reload it would be given takes password
  # authentication and root login away from every account: the administrator running the
  # command over SSH has no password, no root login, and no key authentication either.
  ADMIN_PUBKEY=no
  admin_key_owner
  acquire
  run harden
  assert_equal "${status}" 2
  assert_output --partial 'ssh.harden_admin_no_pubkey'
  assert_output --partial 'pubkeyauthentication yes'
  # The refusal names what sshd actually reported, not only what Harbor wanted.
  assert_output --partial "it reports 'pubkeyauthentication no'"
  assert_output --partial "${ADMIN}"
  # Nothing was reloaded, and the unit was never even asked about: the running sshd still
  # has the configuration it had, which is the one this account can still log in under.
  assert_equal "$(shim_calls "reload")" 0
  assert_equal "$(shim_calls "is-active")" 0
  # sshd's own syntax check passed, which is exactly why it is not enough on its own.
  assert_equal "$(shim_calls "^sshd${TAB}-t\$")" 1
  # The drop-in is on disk and its entry stays prepared for recovery, which is what the
  # message says, and what makes the reload still owed by a later run.
  assert [ -f "${GLOBAL_DROPIN}" ]
  assert_entry 0001 file "${GLOBAL_DROPIN}" created prepared '"absent"' "$(harbor_observe_file "${GLOBAL_DROPIN}")"
  # And the positive: the same node with public-key authentication on for that account
  # reloads. The file is byte for byte what Harbor renders by now, so nothing is rewritten,
  # and the reload happens because the transaction the refusal left open is still unfinished.
  ADMIN_PUBKEY=yes
  : >"${HARBOR_SHIM_LOG}"
  run harden
  assert_success
  assert_equal "$(shim_calls "reload")" 1
  assert_equal "$(shim_calls "user=${ADMIN}")" 1
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" applied
  harbor_lock_release "${FIX_ROOT}"
}

@test "the directory the authorized key is staged in is never given away, and nothing is staged loose in the state root" {
  # The property read straight off the code, which is where it has to hold. The state root
  # is 0755, so every account on the node may traverse it: a key file lying directly in it
  # and chowned to the operator is a file the operator can open and write, and every read
  # of it after that chown is a read of a file the operator may have rewritten. The key is
  # staged in a directory of its own instead, created 0700 and never chowned, and search
  # permission on that directory is what the operator does not have.
  #
  # chmod and chown between them are the whole of it: the directory must be moded 0700, and
  # it must never appear as a chown argument, or the account it were given to could enter
  # it and reach the file inside.
  run code_naming '^[[:space:]]*chown[[:space:]]'
  assert_success
  refute_output --partial '"${key_stage}"'
  assert_output --partial '"${tmp}"'
  run code_naming 'chmod 0700 "\${key_stage}"'
  assert_equal "${#lines[@]}" 1
  # And the key is staged inside that directory rather than beside it in the state root.
  run code_naming 'key_stage="\${root}'
  assert_equal "${#lines[@]}" 1
  run code_naming 'tmp="\${key_stage}/authorized_keys"'
  assert_equal "${#lines[@]}" 1
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
