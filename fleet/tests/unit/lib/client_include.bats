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
  assert_equal 0 "$(find "$(dirname "${CONFIG}")" -maxdepth 1 -name 'config.tmp.*' | wc -l | tr -d ' ')"
  assert_equal 'Host example' "$(cat "${CONFIG}")"
}
