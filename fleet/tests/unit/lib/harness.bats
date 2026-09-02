#!/usr/bin/env bats
load '../test_helper'

@test "helper exposes the repository root and the entry point path" {
  assert [ -d "${HARBOR_ROOT}/tests/unit" ]
  assert_equal "${HARBOR}" "${HARBOR_ROOT}/bin/harbor"
}

@test "fixture_home creates HOME but not the state root" {
  fixture_home
  assert [ -d "${FIX_HOME}" ]
  assert [ ! -e "${FIX_ROOT}" ]
  case "${FIX_HOME}" in
    "${BATS_TEST_TMPDIR}"/*) ;;
    *) fail "fixture home ${FIX_HOME} is outside BATS_TEST_TMPDIR" ;;
  esac
}

@test "fixture_state_root creates a 0700 root with a 0700 journal" {
  fixture_state_root
  assert [ -d "${FIX_ROOT}/journal" ]
  run ls -ld "${FIX_ROOT}" "${FIX_ROOT}/journal"
  assert_line --index 0 --regexp '^drwx------'
  assert_line --index 1 --regexp '^drwx------'
}

@test "fixture_entry writes a canonical entry that entry_phase and entry_raw read back" {
  fixture_state_root
  fixture_entry "${FIX_ROOT}" 0007 file /tmp/x created prepared '"absent"' '{"sha256":"ab","mode":"0644","owner":"me"}'
  assert [ -f "${FIX_ROOT}/journal/0007-file.json" ]
  assert_equal "$(entry_phase "${FIX_ROOT}" 0007)" prepared
  assert_equal "$(entry_raw "${FIX_ROOT}" 0007 post_state)" '{"sha256":"ab","mode":"0644","owner":"me"}'
  assert_equal "$(entry_raw "${FIX_ROOT}" 0007 pre_state)" '"absent"'
}

@test "pause_sentinel builds the Task 4 sentinel path under TMPDIR without a double slash" {
  assert_equal "$(TMPDIR=/x/ pause_sentinel 4242 lock-gate)" /x/harbor-pause.4242.lock-gate
  assert_equal "$(TMPDIR=/x pause_sentinel 4242 lock-gate)" /x/harbor-pause.4242.lock-gate
  assert_equal "$(unset TMPDIR; pause_sentinel 4242 resolve-confirmed)" /tmp/harbor-pause.4242.resolve-confirmed
}

@test "on macos-14 the suite runs under bash 3.2" {
  if [ "$(uname -s)" = "Darwin" ] && [ "${HARBOR_EXPECT_BASH32:-0}" = "1" ]; then
    case "${BASH_VERSION}" in
      3.2.*) ;;
      *) fail "expected bash 3.2 under macos-14, got ${BASH_VERSION}" ;;
    esac
  else
    skip "bash version pin is asserted only where HARBOR_EXPECT_BASH32=1"
  fi
}
