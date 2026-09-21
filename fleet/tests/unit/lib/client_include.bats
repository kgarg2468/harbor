#!/usr/bin/env bats
# fleet/tests/unit/lib/client_include.bats
setup() {
  [ "$(uname -s)" = Darwin ] || skip 'the client runs on macOS only'
  load '../test_helper'
  harbor_load_libs
  . "${HARBOR_ROOT}/lib/client.sh"
  ROOT="${BATS_TEST_TMPDIR}/state"
  CONFIG="${BATS_TEST_TMPDIR}/ssh/config"
  mkdir -p "${ROOT}/journal" "$(dirname "${CONFIG}")"
  HARBOR_PID="$$"
  HARBOR_LOCK_ID_PID=$$
  HARBOR_LOCK_ID_HOSTNAME=fixture
  HARBOR_LOCK_ID_BOOT_ID=fixture
  HARBOR_LOCK_ID_START_TIME=fixture
  HARBOR_LOCK_ID_CMDLINE=client-include-test
  export HARBOR_LOCK_ID_PID HARBOR_LOCK_ID_HOSTNAME HARBOR_LOCK_ID_BOOT_ID
  export HARBOR_LOCK_ID_START_TIME HARBOR_LOCK_ID_CMDLINE
  harbor_lock_acquire "${ROOT}" operator
}

entry() {
  find "${ROOT}/journal" -name '*.json' | LC_ALL=C sort | sed -n "${1:-1}p"
}

@test "the include goes in once, at the top, and is journaled created when there was no config" {
  harbor_client_include_add "${ROOT}" "${CONFIG}"
  assert_equal "$(harbor_client_include_line)" "$(sed -n 1p "${CONFIG}")"
  assert_equal created "$(harbor_journal_string "$(entry)" ownership)"
  assert_equal applied "$(harbor_journal_string "$(entry)" phase)"
  assert_equal ssh-include "$(harbor_journal_string "$(entry)" op)"
  assert_equal "$(harbor_observe_file "${CONFIG}")" "$(harbor_journal_raw "$(entry)" post_state)"
  assert_equal "$(harbor_observe_file "${CONFIG}")" "$(harbor_journal_observe ssh-include "${CONFIG}")"
}

@test "an existing config is modified, not created, and keeps every line it had" {
  printf 'Host example\n  User someone\n' >"${CONFIG}"
  harbor_client_include_add "${ROOT}" "${CONFIG}"
  assert_equal "$(harbor_client_include_line)" "$(sed -n 1p "${CONFIG}")"
  run cat "${CONFIG}"
  assert_success
  assert_line --index 1 'Host example'
  assert_line '  User someone'
  assert_equal modified "$(harbor_journal_string "$(entry)" ownership)"
}

@test "the include precedes every Host block, because ssh ignores one that does not" {
  printf 'Host example\n  User someone\n' >"${CONFIG}"
  harbor_client_include_add "${ROOT}" "${CONFIG}"
  local include_at host_at
  include_at="$(grep -n '^Include ' "${CONFIG}" | cut -d: -f1)"
  host_at="$(grep -n '^Host ' "${CONFIG}" | head -1 | cut -d: -f1)"
  [ "${include_at}" -lt "${host_at}" ]
}

@test "a second run adds nothing and journals nothing" {
  harbor_client_include_add "${ROOT}" "${CONFIG}"
  local before after
  before="$(shasum -a 256 "${CONFIG}" | cut -d' ' -f1)"
  harbor_client_include_add "${ROOT}" "${CONFIG}"
  after="$(shasum -a 256 "${CONFIG}" | cut -d' ' -f1)"
  assert_equal "${before}" "${after}"
  assert_equal 1 "$(find "${ROOT}/journal" -name '*.json' | wc -l | tr -d ' ')"
}

@test "an include already present by the operator's own hand is left alone without a journal entry" {
  printf '%s\nHost example\n' "$(harbor_client_include_line)" >"${CONFIG}"
  harbor_client_include_add "${ROOT}" "${CONFIG}"
  assert_equal 0 "$(find "${ROOT}/journal" -name '*.json' | wc -l | tr -d ' ')"
}

@test "a line that merely matches the include as a pattern does not count as present" {
  # The include literal carries a dot, and a dot in a pattern matches any
  # character. Read as a pattern, this line answers yes -- and a yes here is
  # setup reporting success having written nothing, with ssh still not loading
  # harbor.conf.
  printf 'Include ~/.ssh/harborAconf\n' >"${CONFIG}"
  run harbor_client_include_present "${CONFIG}"
  assert_failure
  harbor_client_include_add "${ROOT}" "${CONFIG}"
  assert_equal "$(harbor_client_include_line)" "$(sed -n 1p "${CONFIG}")"
  assert_equal 'Include ~/.ssh/harborAconf' "$(sed -n 2p "${CONFIG}")"
  assert_equal 1 "$(find "${ROOT}/journal" -name '*.json' | wc -l | tr -d ' ')"
}

@test "a symlinked config is refused rather than replaced with a regular file" {
  # The rename would put a regular file where the link was, orphaning whatever
  # it pointed at -- a config symlinked into a dotfiles checkout silently
  # becomes an unmanaged copy, and every edit made in the checkout afterwards
  # reaches nothing. Harbor recorded that as ownership modified, phase applied.
  local real="${BATS_TEST_TMPDIR}/dotfiles/sshconfig"
  mkdir -p "$(dirname "${real}")"
  printf 'Host example\n  User someone\n' >"${real}"
  rm -f "${CONFIG}"
  ln -s "${real}" "${CONFIG}"
  run harbor_client_include_add "${ROOT}" "${CONFIG}"
  assert_failure 3
  assert_output --partial 'client.config_symlink'
  assert [ -L "${CONFIG}" ]
  assert_equal "$(printf 'Host example\n  User someone')" "$(cat "${real}")"
  assert_equal 0 "$(find "${ROOT}/journal" -name '*.json' | wc -l | tr -d ' ')"
}

@test "a config edited while the entry was preparing is refused, not overwritten" {
  # The staged copy was built from the file as it stood before the entry was
  # written. Replacing the file wholesale now would discard whatever arrived in
  # between without a word, and what arrives in between is the operator's own
  # edit to their own ssh config.
  printf 'Host example\n' >"${CONFIG}"
  run bash -c '
    set -euo pipefail
    . "${HARBOR_ROOT}/lib/log.sh"
    . "${HARBOR_ROOT}/lib/checks.sh"
    . "${HARBOR_ROOT}/lib/lock.sh"
    . "${HARBOR_ROOT}/lib/journal.sh"
    . "${HARBOR_ROOT}/lib/client.sh"
    HARBOR_LOCK_ID_PID=$$
    harbor_lock_acquire "${1}" operator
    # Stand in for the editor that saves between the read and the rename. The
    # first call is the pre_state, taken before anything is staged; the edit
    # lands after that and before the second call, which is the check. The tally
    # is a file because both calls are inside command substitutions, and a
    # variable incremented in a subshell is a variable the next call never sees.
    tally="${3}"
    harbor_journal_observe() {
      printf "x" >>"${tally}"
      if [ "$(wc -c <"${tally}" | tr -d " ")" = 2 ]; then
        printf "Host example\nHost added-since\n" >"${2}"
      fi
      harbor_observe_file "${2}"
    }
    harbor_client_include_add "${1}" "${2}"
  ' bash "${ROOT}" "${CONFIG}" "${BATS_TEST_TMPDIR}/tally"
  assert_failure 1
  assert_output --partial 'client.config_moved'
  assert_equal "$(printf 'Host example\nHost added-since')" "$(cat "${CONFIG}")"
}

@test "the config is checked for changes only once the copy that would replace it exists" {
  # What the check is worth is decided by where it stands. Taken before the
  # staged copy is built, it leaves the whole of mktemp and install between the
  # look and the rename -- and that stretch is long enough for the editor this
  # test stands in for. Taken after, the only thing left is the rename itself,
  # which is the irreducible window POSIX gives no way to close.
  #
  # The order is measured rather than inferred, because an assertion about the
  # outcome cannot tell the two placements apart: both make the same second
  # observe call, and both refuse the same edit. install is shadowed by a
  # function, which bash resolves before /usr/bin/install, so the trace records
  # the staging step itself and not a stand-in for it.
  printf 'Host example\n' >"${CONFIG}"
  local trace="${BATS_TEST_TMPDIR}/trace"
  run bash -c '
    set -euo pipefail
    . "${HARBOR_ROOT}/lib/log.sh"
    . "${HARBOR_ROOT}/lib/checks.sh"
    . "${HARBOR_ROOT}/lib/lock.sh"
    . "${HARBOR_ROOT}/lib/journal.sh"
    . "${HARBOR_ROOT}/lib/client.sh"
    HARBOR_LOCK_ID_PID=$$
    harbor_lock_acquire "${1}" operator
    trace="${3}"
    harbor_journal_observe() {
      printf "observe\n" >>"${trace}"
      harbor_observe_file "${2}"
    }
    install() {
      printf "install\n" >>"${trace}"
      command install "$@"
    }
    harbor_client_include_add "${1}" "${2}"
  ' bash "${ROOT}" "${CONFIG}" "${trace}"
  assert_success
  assert_equal "$(printf 'observe\ninstall\nobserve')" "$(cat "${trace}")"
}

@test "a fifo where the config belongs is refused, not destroyed and journaled as created" {
  # -f is false for a fifo, so ownership came out "created" -- Harbor claiming an
  # object it did not make -- and harbor_observe_file answers
  # "unobservable:not-a-regular-file" for it, which compares equal to itself, so
  # the moved-config check passed too. The rename then replaced the fifo with a
  # regular file and the entry recorded created/applied: a destroyed object,
  # reported as a success.
  rm -f "${CONFIG}"
  mkfifo "${CONFIG}"
  run harbor_client_include_add "${ROOT}" "${CONFIG}"
  assert_failure 3
  assert_output --partial 'client.path_irregular'
  assert [ -p "${CONFIG}" ]
  assert_equal 0 "$(find "${ROOT}/journal" -name '*.json' | wc -l | tr -d ' ')"
}

@test "a directory where the config belongs is refused rather than written inside" {
  # The other half of the same hole, and the quieter one: mv -f onto a directory
  # succeeds by moving the staged file into it, so the entry would be marked
  # applied while the path itself is still a directory and ssh still has no
  # include.
  rm -f "${CONFIG}"
  mkdir "${CONFIG}"
  run harbor_client_include_add "${ROOT}" "${CONFIG}"
  assert_failure 3
  assert_output --partial 'client.path_irregular'
  assert [ -d "${CONFIG}" ]
  assert_equal 0 "$(find "${CONFIG}" -type f | wc -l | tr -d ' ')"
  assert_equal 0 "$(find "${ROOT}/journal" -name '*.json' | wc -l | tr -d ' ')"
}

@test "a symlink planted at the include writer's temp path is not written through" {
  # This writer uses install rather than a redirection, and measured, BSD install
  # replaces a symlink at its destination instead of following it -- so unlike
  # harbor_client_conf_write this one was never exploitable. The temp name is
  # unguessable regardless, and this test is what would notice if the install
  # ever became a "cat >", which is the one-character difference between the two
  # writers that made only one of them a hole.
  local victim="${BATS_TEST_TMPDIR}/victim"
  printf 'VICTIM DATA\n' >"${victim}"
  ln -s "${victim}" "${CONFIG}.tmp.$$"
  harbor_client_include_add "${ROOT}" "${CONFIG}"
  assert_equal 'VICTIM DATA' "$(cat "${victim}")"
  assert_equal "$(harbor_client_include_line)" "$(sed -n 1p "${CONFIG}")"
}

@test "the entry is prepared before the file changes and applied after" {
  run /bin/bash -c '
    set -euo pipefail
    . "${HARBOR_ROOT}/lib/log.sh"
    . "${HARBOR_ROOT}/lib/checks.sh"
    . "${HARBOR_ROOT}/lib/lock.sh"
    . "${HARBOR_ROOT}/lib/journal.sh"
    . "${HARBOR_ROOT}/lib/client.sh"
    HARBOR_PID=$$
    HARBOR_TEST_HOOKS=1
    HARBOR_FAIL_AFTER=client-include-prepared
    harbor_client_include_add "${1}" "${2}"
  ' bash "${ROOT}" "${CONFIG}"
  assert_failure
  assert_equal prepared "$(harbor_journal_string "$(entry)" phase)"
  assert_equal "$(harbor_journal_raw "$(entry)" pre_state)" "$(harbor_journal_observe file "${CONFIG}")"
}

@test "a journal that cannot be written leaves no unjournaled file beside the config" {
  # The temp file sits next to its target so the rename is atomic, which is also
  # what makes it dangerous: recovery only ever looks at entries, so a temp file
  # left behind by a failed prepare is an artifact nothing in Harbor collects.
  printf 'Host example\n' >"${CONFIG}"
  chmod 0500 "${ROOT}/journal"
  run harbor_client_include_add "${ROOT}" "${CONFIG}"
  chmod 0700 "${ROOT}/journal"
  assert_failure
  assert_equal 0 "$(find "$(dirname "${CONFIG}")" -maxdepth 1 -name '.harbor.*' | wc -l | tr -d ' ')"
  assert_equal 'Host example' "$(cat "${CONFIG}")"
}

@test "the staged copy is built under TMPDIR, at 0600, with the content that is about to land" {
  # The fail-after hook is a SIGKILL, so no trap runs and the staging directory
  # is still there to look at. That is the leak the exit trap cannot cover, and
  # inspecting it is the only way to pin down where the staging goes: an earlier
  # spelling used "mktemp -d -t", which on macOS ignores TMPDIR and answers with
  # the per-user /var/folders directory, and every assertion about the staging
  # location was vacuously true.
  local stage="${BATS_TEST_TMPDIR}/tmp" dir
  mkdir -p "${stage}"
  printf 'Host example\n' >"${CONFIG}"
  run env TMPDIR="${stage}" /bin/bash -c '
    set -euo pipefail
    . "${HARBOR_ROOT}/lib/log.sh"
    . "${HARBOR_ROOT}/lib/checks.sh"
    . "${HARBOR_ROOT}/lib/lock.sh"
    . "${HARBOR_ROOT}/lib/journal.sh"
    . "${HARBOR_ROOT}/lib/client.sh"
    HARBOR_PID=$$
    HARBOR_TEST_HOOKS=1
    HARBOR_FAIL_AFTER=client-include-prepared
    harbor_client_include_add "${1}" "${2}"
  ' bash "${ROOT}" "${CONFIG}"
  assert_failure
  dir="$(find "${stage}" -mindepth 1 -maxdepth 1 -type d -name 'harbor-client.*')"
  assert_equal 1 "$(printf '%s\n' "${dir}" | wc -l | tr -d ' ')"
  assert_equal 600 "$(stat -f '%OLp' "${dir}/config")"
  assert_equal "$(harbor_client_include_line)" "$(sed -n 1p "${dir}/config")"
  assert_equal 'Host example' "$(sed -n 2p "${dir}/config")"
  # The post-state the entry recorded was measured on this file, and it has to
  # still describe it after the move -- that is what lets recovery decide.
  assert_equal "$(harbor_observe_file "${dir}/config")" "$(harbor_journal_raw "$(entry)" post_state)"
}

@test "a run that dies mid-write takes its staged copy of the config with it" {
  # The staging directory holds the operator's whole ssh config, and the write
  # that would have consumed it never happens: harbor_journal_create exits
  # rather than returning, so nothing written after the call runs. Only the exit
  # trap is left, which is the point of naming the directory in a global.
  local stage="${BATS_TEST_TMPDIR}/tmp"
  mkdir -p "${stage}"
  printf 'Host example\n' >"${CONFIG}"
  chmod 0500 "${ROOT}/journal"
  run env TMPDIR="${stage}" /bin/bash -c '
    set -euo pipefail
    . "${HARBOR_ROOT}/lib/log.sh"
    . "${HARBOR_ROOT}/lib/checks.sh"
    . "${HARBOR_ROOT}/lib/lock.sh"
    . "${HARBOR_ROOT}/lib/journal.sh"
    . "${HARBOR_ROOT}/lib/client.sh"
    harbor_install_traps
    harbor_client_include_add "${1}" "${2}"
  ' bash "${ROOT}" "${CONFIG}"
  chmod 0700 "${ROOT}/journal"
  assert_failure
  assert_equal 0 "$(find "${stage}" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')"
}
