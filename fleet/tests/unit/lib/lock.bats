#!/usr/bin/env bats
load '../test_helper'

setup() {
  # lib/lock.sh depends only on lib/log.sh, so this file sources those two
  # rather than harbor_load_libs, which also loads the libraries later tasks create.
  # shellcheck source=lib/log.sh
  . "${HARBOR_ROOT}/lib/log.sh"
  # shellcheck source=lib/lock.sh
  . "${HARBOR_ROOT}/lib/lock.sh"
  fixture_state_root
  KEEP_PID=""
  PAUSED_PIDS=""
}

teardown() {
  # Resume and reap any process a test left paused (Task 8 contenders), then
  # remove its sentinels, so a failed assertion never leaks a paused process.
  local p s
  for p in ${PAUSED_PIDS}; do
    for s in lock-acquired resolve-confirmed; do
      touch "$(pause_sentinel "${p}" "${s}")"
    done
    wait "${p}" 2>/dev/null || true
    for s in lock-acquired resolve-confirmed; do
      rm -f "$(pause_sentinel "${p}" "${s}")"
    done
  done
  if [ -n "${KEEP_PID}" ]; then
    kill "${KEEP_PID}" 2>/dev/null || true
  fi
}

start_sleeper() {
  # start_sleeper: a live process the test owns; KEEP_PID and KEEP_START are set
  sleep 30 3>&- &
  KEEP_PID=$!
  KEEP_START="$(harbor_lock_start_time "${KEEP_PID}")"
}

gone_pid() {
  # gone_pid: prints the pid of a process that has already exited
  sleep 0.01 3>&- &
  local p=$!
  wait "${p}"
  printf '%s' "${p}"
}

@test "the operator state root lives under HOME and the root one under /var/lib" {
  HOME="${FIX_HOME}" harbor_state_root_for_principal
  if [ "$(id -u)" = "0" ]; then
    assert_equal "${HARBOR_STATE_ROOT}" /var/lib/harbor
    assert_equal "${HARBOR_LOCK_KIND}" root
  else
    assert_equal "${HARBOR_STATE_ROOT}" "${FIX_HOME}/.local/state/harbor"
    assert_equal "${HARBOR_LOCK_KIND}" operator
  fi
}

@test "harbor_state_root_create makes a 0700 operator root or a 0755 root root and leaves an existing one alone" {
  harbor_state_root_create "${BATS_TEST_TMPDIR}/op" operator
  harbor_state_root_create "${BATS_TEST_TMPDIR}/rt" root
  run ls -ld "${BATS_TEST_TMPDIR}/op" "${BATS_TEST_TMPDIR}/rt"
  assert_line --index 0 --regexp '^drwx------'
  assert_line --index 1 --regexp '^drwxr-xr-x'
  chmod 0750 "${BATS_TEST_TMPDIR}/op"
  harbor_state_root_create "${BATS_TEST_TMPDIR}/op" operator
  run ls -ld "${BATS_TEST_TMPDIR}/op"
  assert_output --regexp '^drwxr-x---'
  run harbor_state_root_create "${BATS_TEST_TMPDIR}/x" other
  assert_equal "${status}" 3
  assert_output --partial 'lock.kind'
}

@test "boot id and own start time are readable on this platform" {
  run harbor_lock_boot_id
  assert_success
  refute_output ''
  run harbor_lock_start_time "$$"
  assert_success
  refute_output ''
}

@test "harbor_lock_pid_alive distinguishes a live pid from a gone one without tripping the ERR trap" {
  start_sleeper
  harbor_lock_pid_alive "${KEEP_PID}"
  gone="$(gone_pid)"
  run --separate-stderr harbor_lock_pid_alive "${gone}"
  assert_failure
  assert_equal "${stderr}" ""
  run --separate-stderr harbor_lock_start_time "${gone}"
  assert_output ''
  assert_equal "${stderr}" ""
}

@test "identity is computed once from HARBOR_PID and HARBOR_CMDLINE" {
  HARBOR_PID="$$"
  HARBOR_CMDLINE="harbor journal resolve 0001 --reverted"
  harbor_lock_identity
  assert_equal "${HARBOR_LOCK_ID_HOSTNAME}" "$(uname -n)"
  assert_equal "${HARBOR_LOCK_ID_BOOT_ID}" "$(harbor_lock_boot_id)"
  assert_equal "${HARBOR_LOCK_ID_PID}" "$$"
  assert_equal "${HARBOR_LOCK_ID_START_TIME}" "$(harbor_lock_start_time "$$")"
  assert_equal "${HARBOR_LOCK_ID_CMDLINE}" "harbor journal resolve 0001 --reverted"
  HARBOR_CMDLINE="changed"
  harbor_lock_identity
  assert_equal "${HARBOR_LOCK_ID_CMDLINE}" "harbor journal resolve 0001 --reverted"
}

@test "holder record is written by rename with the requested mode and parses back" {
  mkdir "${BATS_TEST_TMPDIR}/d"
  HARBOR_PID="$$"
  HARBOR_CMDLINE="harbor test"
  harbor_lock_write_holder "${BATS_TEST_TMPDIR}/d" 0600
  run ls -A "${BATS_TEST_TMPDIR}/d"
  assert_output holder
  run ls -l "${BATS_TEST_TMPDIR}/d/holder"
  assert_output --regexp '^-rw-------'
  run cat "${BATS_TEST_TMPDIR}/d/holder"
  assert_line --index 0 "hostname=$(uname -n)"
  assert_line --index 1 "boot_id=$(harbor_lock_boot_id)"
  assert_line --index 2 "pid=$$"
  assert_line --index 3 "start_time=$(harbor_lock_start_time "$$")"
  assert_line --index 4 "cmdline=harbor test"
  harbor_lock_parse_holder "${BATS_TEST_TMPDIR}/d/holder"
  assert_equal "${HARBOR_HOLDER_PID}" "$$"
  assert_equal "${HARBOR_HOLDER_CMDLINE}" "harbor test"
}

@test "a command line with embedded line breaks is normalized to one line before the holder is written" {
  mkdir "${BATS_TEST_TMPDIR}/d"
  HARBOR_PID="$$"
  HARBOR_CMDLINE="$(printf 'harbor a\nb\rc')"
  harbor_lock_write_holder "${BATS_TEST_TMPDIR}/d" 0600
  assert_equal "$(wc -l <"${BATS_TEST_TMPDIR}/d/holder" | tr -d ' ')" 5
  assert_equal "$(sed -n 's/^cmdline=//p' "${BATS_TEST_TMPDIR}/d/holder")" 'harbor a b c'
  harbor_lock_parse_holder "${BATS_TEST_TMPDIR}/d/holder"
  assert_equal "${HARBOR_HOLDER_CMDLINE}" 'harbor a b c'
}

@test "holder parsing rejects a missing file, an unknown key, a duplicate key, a missing key, a line without =, an empty field, and a non-numeric pid" {
  run harbor_lock_parse_holder "${BATS_TEST_TMPDIR}/absent"
  assert_failure
  printf 'hostname=h\nboot_id=b\npid=1\nstart_time=s\ncmdline=c\nextra=x\n' >"${BATS_TEST_TMPDIR}/h1"
  run harbor_lock_parse_holder "${BATS_TEST_TMPDIR}/h1"
  assert_failure
  printf 'hostname=h\nboot_id=b\npid=1\nstart_time=s\ncmdline=c\npid=2\n' >"${BATS_TEST_TMPDIR}/h5"
  run harbor_lock_parse_holder "${BATS_TEST_TMPDIR}/h5"
  assert_failure
  printf 'hostname=h\nboot_id=b\npid=1\nstart_time=s\n' >"${BATS_TEST_TMPDIR}/h6"
  run harbor_lock_parse_holder "${BATS_TEST_TMPDIR}/h6"
  assert_failure
  printf 'hostname=h\nboot_id=b\npid=1\nstart_time=s\ncmdline=c\nsecond line of a command line\n' >"${BATS_TEST_TMPDIR}/h7"
  run harbor_lock_parse_holder "${BATS_TEST_TMPDIR}/h7"
  assert_failure
  printf 'hostname=h\nboot_id=\npid=1\nstart_time=s\ncmdline=c\n' >"${BATS_TEST_TMPDIR}/h2"
  run harbor_lock_parse_holder "${BATS_TEST_TMPDIR}/h2"
  assert_failure
  printf 'hostname=h\nboot_id=b\npid=12a\nstart_time=s\ncmdline=c\n' >"${BATS_TEST_TMPDIR}/h3"
  run harbor_lock_parse_holder "${BATS_TEST_TMPDIR}/h3"
  assert_failure
}

@test "holder parsing rejects an empty cmdline and leaves no field set" {
  printf 'hostname=h\nboot_id=b\npid=12\nstart_time=s\ncmdline=\n' >"${BATS_TEST_TMPDIR}/h4"
  run harbor_lock_parse_holder "${BATS_TEST_TMPDIR}/h4"
  assert_failure
  printf 'hostname=h\nboot_id=b\npid=12\nstart_time=s\ncmdline=harbor test\n' >"${BATS_TEST_TMPDIR}/h8"
  harbor_lock_parse_holder "${BATS_TEST_TMPDIR}/h8"
  assert_equal "${HARBOR_HOLDER_CMDLINE}" "harbor test"
  harbor_lock_parse_holder "${BATS_TEST_TMPDIR}/h4" || true
  assert_equal "${HARBOR_HOLDER_CMDLINE}" ""
}

@test "classification: live holder" {
  start_sleeper
  mkdir "${FIX_ROOT}/lock.d"
  holder_record "${KEEP_PID}" "${KEEP_START}" >"${FIX_ROOT}/lock.d/holder"
  harbor_lock_classify "${FIX_ROOT}/lock.d"
  assert_equal "${HARBOR_LOCK_CLASS}" live
}

@test "classification: stale when the pid is gone, the start time differs, or the boot id differs" {
  mkdir "${FIX_ROOT}/lock.d"
  holder_record "$(gone_pid)" "whatever" >"${FIX_ROOT}/lock.d/holder"
  harbor_lock_classify "${FIX_ROOT}/lock.d"
  assert_equal "${HARBOR_LOCK_CLASS}" stale
  start_sleeper
  holder_record "${KEEP_PID}" "not-${KEEP_START}" >"${FIX_ROOT}/lock.d/holder"
  harbor_lock_classify "${FIX_ROOT}/lock.d"
  assert_equal "${HARBOR_LOCK_CLASS}" stale
  holder_record "${KEEP_PID}" "${KEEP_START}" | sed 's/^boot_id=.*/boot_id=other-boot/' >"${FIX_ROOT}/lock.d/holder"
  harbor_lock_classify "${FIX_ROOT}/lock.d"
  assert_equal "${HARBOR_LOCK_CLASS}" stale
}

@test "classification: unknown for a different hostname, no holder, an unparseable record, or an unreadable start time" {
  mkdir "${FIX_ROOT}/lock.d"
  harbor_lock_classify "${FIX_ROOT}/lock.d"
  assert_equal "${HARBOR_LOCK_CLASS}" unknown
  printf 'garbage\n' >"${FIX_ROOT}/lock.d/holder"
  harbor_lock_classify "${FIX_ROOT}/lock.d"
  assert_equal "${HARBOR_LOCK_CLASS}" unknown
  start_sleeper
  holder_record "${KEEP_PID}" "${KEEP_START}" | sed 's/^hostname=.*/hostname=harbor-node-other/' >"${FIX_ROOT}/lock.d/holder"
  harbor_lock_classify "${FIX_ROOT}/lock.d"
  assert_equal "${HARBOR_LOCK_CLASS}" unknown
  holder_record "${KEEP_PID}" "${KEEP_START}" >"${FIX_ROOT}/lock.d/holder"
  harbor_lock_identity
  harbor_lock_start_time() { printf ''; }
  harbor_lock_classify "${FIX_ROOT}/lock.d"
  assert_equal "${HARBOR_LOCK_CLASS}" unknown
}

@test "the recorded start time does not depend on the caller's TZ" {
  [ "$(uname -s)" = Darwin ] || skip "lstart is only used on Darwin"
  start_sleeper
  a="$(TZ=UTC harbor_lock_start_time "${KEEP_PID}")"
  b="$(TZ=Asia/Tokyo harbor_lock_start_time "${KEEP_PID}")"
  assert [ -n "${a}" ]
  assert_equal "${a}" "${b}"
}
