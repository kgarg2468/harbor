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

open_log() {
  harbor_log_open "${FIX_ROOT}/harbor.log" 0600
}

contender() {
  # contender OUTFILE: a background library-level acquisition of FIX_ROOT that
  # pauses at lock-acquired. env execs bash, so CONTENDER_PID is the acquiring
  # process and its EXIT trap releases the lock when the test resumes it.
  env HARBOR_TEST_HOOKS=1 HARBOR_PAUSE_AFTER=lock-acquired \
    bash -c '. "${HARBOR_ROOT}/lib/log.sh"; . "${HARBOR_ROOT}/lib/lock.sh"; set -euo pipefail; HARBOR_PID=$$; harbor_install_traps; harbor_lock_acquire "$1" operator; HARBOR_COMPLETED=1; exit 0' _ "${FIX_ROOT}" >"${1}" 2>&1 3>&- &
  CONTENDER_PID=$!
  PAUSED_PIDS="${PAUSED_PIDS} ${CONTENDER_PID}"
}

@test "acquire on an absent lock: gate taken and released, lock.d holder names this process, operator modes, steps logged" {
  open_log
  HARBOR_PID="$$"
  harbor_lock_acquire "${FIX_ROOT}" operator
  assert [ -f "${FIX_ROOT}/lock.d/holder" ]
  assert [ ! -e "${FIX_ROOT}/reclaim.d" ]
  assert_equal "${HARBOR_LOCK_ROOT}" "${FIX_ROOT}"
  harbor_lock_parse_holder "${FIX_ROOT}/lock.d/holder"
  assert_equal "${HARBOR_HOLDER_PID}" "$$"
  run ls -ld "${FIX_ROOT}/lock.d"
  assert_output --regexp '^drwx------'
  run ls -l "${FIX_ROOT}/lock.d/holder"
  assert_output --regexp '^-rw-------'
  run grep -o 'step lock-[a-z]*$' "${FIX_ROOT}/harbor.log"
  assert_line --index 0 'step lock-gate'
  assert_line --index 1 'step lock-mkdir'
  assert_line --index 2 'step lock-acquired'
  harbor_lock_release "${FIX_ROOT}"
  assert [ ! -e "${FIX_ROOT}/lock.d" ]
  assert_equal "${HARBOR_LOCK_ROOT}" ""
}

@test "acquire with kind root uses 0755 directories and 0644 holders" {
  HARBOR_PID="$$"
  harbor_lock_acquire "${FIX_ROOT}" root
  run ls -ld "${FIX_ROOT}/lock.d"
  assert_output --regexp '^drwxr-xr-x'
  run ls -l "${FIX_ROOT}/lock.d/holder"
  assert_output --regexp '^-rw-r--r--'
  harbor_lock_release "${FIX_ROOT}"
}

@test "acquire without a state root exits 3 and creates nothing" {
  run harbor_lock_acquire "${BATS_TEST_TMPDIR}/nowhere" operator
  assert_equal "${status}" 3
  assert_output --partial 'lock.no_state_root'
  assert [ ! -e "${BATS_TEST_TMPDIR}/nowhere" ]
}

@test "a present reclaim.d refuses immediately without claiming or releasing it and without touching lock.d" {
  mkdir "${FIX_ROOT}/reclaim.d"
  printf 'hostname=x\n' >"${FIX_ROOT}/reclaim.d/holder"
  run harbor_lock_acquire "${FIX_ROOT}" operator
  assert_equal "${status}" 3
  assert_output --partial 'lock.gate_busy'
  assert_output --partial "ls -la ${FIX_ROOT}/reclaim.d ${FIX_ROOT}/lock.d"
  assert_equal "$(cat "${FIX_ROOT}/reclaim.d/holder")" 'hostname=x'
  assert [ ! -e "${FIX_ROOT}/lock.d" ]
}

@test "a live holder exits 3 with lock.busy naming it, releases only the own gate, and leaves the holder unchanged" {
  start_sleeper
  mkdir "${FIX_ROOT}/lock.d"
  holder_record "${KEEP_PID}" "${KEEP_START}" "harbor other" >"${FIX_ROOT}/lock.d/holder"
  before="$(cat "${FIX_ROOT}/lock.d/holder")"
  run harbor_lock_acquire "${FIX_ROOT}" operator
  assert_equal "${status}" 3
  assert_output --partial 'lock.busy'
  assert_output --partial "pid ${KEEP_PID}"
  assert_output --partial 'harbor other'
  assert [ ! -e "${FIX_ROOT}/reclaim.d" ]
  assert_equal "$(cat "${FIX_ROOT}/lock.d/holder")" "${before}"
  refute_output --partial 'failed at step'
}

@test "a stale holder (pid gone) is archived as lock.<timestamp>.stale under the gate and the command proceeds" {
  mkdir "${FIX_ROOT}/lock.d"
  holder_record "$(gone_pid)" "whatever" >"${FIX_ROOT}/lock.d/holder"
  HARBOR_PID="$$"
  run harbor_lock_acquire "${FIX_ROOT}" operator
  assert_success
  assert_output --partial 'reclaimed stale lock'
  harbor_lock_parse_holder "${FIX_ROOT}/lock.d/holder"
  assert_equal "${HARBOR_HOLDER_PID}" "$$"
  assert [ ! -e "${FIX_ROOT}/reclaim.d" ]
  run find "${FIX_ROOT}" -maxdepth 1 -name 'lock.*.stale'
  assert_equal "${#lines[@]}" 1
  harbor_lock_parse_holder "${lines[0]}/holder"
  assert_equal "${HARBOR_HOLDER_START_TIME}" whatever
  harbor_lock_release "${FIX_ROOT}"
  assert [ ! -e "${FIX_ROOT}/lock.d" ]
}

@test "a stale holder by start-time mismatch or by boot id is reclaimed the same way" {
  start_sleeper
  mkdir "${FIX_ROOT}/lock.d"
  holder_record "${KEEP_PID}" "not-${KEEP_START}" >"${FIX_ROOT}/lock.d/holder"
  HARBOR_PID="$$"
  harbor_lock_acquire "${FIX_ROOT}" operator
  harbor_lock_parse_holder "${FIX_ROOT}/lock.d/holder"
  assert_equal "${HARBOR_HOLDER_PID}" "$$"
  harbor_lock_release "${FIX_ROOT}"
  mkdir "${FIX_ROOT}/lock.d"
  holder_record "${KEEP_PID}" "${KEEP_START}" | sed 's/^boot_id=.*/boot_id=other-boot/' >"${FIX_ROOT}/lock.d/holder"
  harbor_lock_acquire "${FIX_ROOT}" operator
  harbor_lock_parse_holder "${FIX_ROOT}/lock.d/holder"
  assert_equal "${HARBOR_HOLDER_PID}" "$$"
  harbor_lock_release "${FIX_ROOT}"
  run find "${FIX_ROOT}" -maxdepth 1 -name 'lock.*.stale'
  assert_equal "${#lines[@]}" 2
}

@test "a different hostname, an unreadable start time, or a lock.d without holder is refused with the inspection command and left in place" {
  start_sleeper
  mkdir "${FIX_ROOT}/lock.d"
  holder_record "${KEEP_PID}" "${KEEP_START}" | sed 's/^hostname=.*/hostname=harbor-node-other/' >"${FIX_ROOT}/lock.d/holder"
  before="$(cat "${FIX_ROOT}/lock.d/holder")"
  run harbor_lock_acquire "${FIX_ROOT}" operator
  assert_equal "${status}" 3
  assert_output --partial 'lock.unreadable'
  assert_output --partial "cat ${FIX_ROOT}/reclaim.d/holder ${FIX_ROOT}/lock.d/holder"
  assert_equal "$(cat "${FIX_ROOT}/lock.d/holder")" "${before}"
  assert [ ! -e "${FIX_ROOT}/reclaim.d" ]

  holder_record "${KEEP_PID}" "${KEEP_START}" >"${FIX_ROOT}/lock.d/holder"
  harbor_lock_identity
  harbor_lock_start_time() { printf ''; }
  run harbor_lock_acquire "${FIX_ROOT}" operator
  assert_equal "${status}" 3
  assert_output --partial 'lock.unreadable'
  assert [ -f "${FIX_ROOT}/lock.d/holder" ]
  assert [ ! -e "${FIX_ROOT}/reclaim.d" ]

  rm "${FIX_ROOT}/lock.d/holder"
  run harbor_lock_acquire "${FIX_ROOT}" operator
  assert_equal "${status}" 3
  assert_output --partial 'lock.unreadable'
  assert [ -d "${FIX_ROOT}/lock.d" ]
  assert [ ! -e "${FIX_ROOT}/reclaim.d" ]
  run find "${FIX_ROOT}" -maxdepth 1 -name 'lock.*.stale'
  assert_output ''
}

@test "release treats an absent lock.d as already released" {
  HARBOR_LOCK_ROOT="${FIX_ROOT}"
  harbor_lock_release "${FIX_ROOT}"
  assert_equal "${HARBOR_LOCK_ROOT}" ""
  assert [ ! -e "${FIX_ROOT}/lock.d" ]
}

@test "release never removes a lock.d whose holder names another process" {
  start_sleeper
  HARBOR_PID="$$"
  harbor_lock_acquire "${FIX_ROOT}" operator
  holder_record "${KEEP_PID}" "${KEEP_START}" >"${FIX_ROOT}/lock.d/holder"
  harbor_lock_release "${FIX_ROOT}"
  assert [ -f "${FIX_ROOT}/lock.d/holder" ]
  assert_equal "${HARBOR_LOCK_ROOT}" ""
  rm -r "${FIX_ROOT}/lock.d"
}

@test "a child process, an actual ( ) subshell, a command substitution, and a Bats run capture never release the parent's lock; the parent then does" {
  HARBOR_PID="$$"
  harbor_lock_acquire "${FIX_ROOT}" operator
  bash -c '. "${HARBOR_ROOT}/lib/log.sh"; . "${HARBOR_ROOT}/lib/lock.sh"; HARBOR_PID=$$; harbor_lock_release "$1"' _ "${FIX_ROOT}"
  assert [ -f "${FIX_ROOT}/lock.d/holder" ]
  # $$ is unchanged inside ( ), so only the BASH_SUBSHELL guard stops these three
  ( harbor_lock_release "${FIX_ROOT}" )
  assert [ -f "${FIX_ROOT}/lock.d/holder" ]
  assert_equal "$(harbor_lock_release "${FIX_ROOT}"; ls -A "${FIX_ROOT}/lock.d")" holder
  run harbor_lock_release "${FIX_ROOT}"
  assert_success
  assert [ -f "${FIX_ROOT}/lock.d/holder" ]
  assert_equal "${HARBOR_LOCK_ROOT}" "${FIX_ROOT}"
  harbor_lock_release "${FIX_ROOT}"
  assert [ ! -e "${FIX_ROOT}/lock.d" ]
  assert_equal "${HARBOR_LOCK_ROOT}" ""
}

@test "the EXIT trap releases an owned lock at the top level only and leaves a foreign one in place" {
  run bash -c '. "${HARBOR_ROOT}/lib/log.sh"; . "${HARBOR_ROOT}/lib/lock.sh"; set -euo pipefail; HARBOR_PID=$$; harbor_install_traps; harbor_lock_acquire "$1" operator; ( true ); [ -f "$1/lock.d/holder" ] || exit 9; ( harbor_lock_release "$1" ); [ -f "$1/lock.d/holder" ] || exit 8; x="$(harbor_lock_release "$1")"; [ -f "$1/lock.d/holder" ] || exit 7; HARBOR_COMPLETED=1; exit 0' _ "${FIX_ROOT}"
  assert_success
  assert [ ! -e "${FIX_ROOT}/lock.d" ]
  run bash -c '. "${HARBOR_ROOT}/lib/log.sh"; . "${HARBOR_ROOT}/lib/lock.sh"; set -euo pipefail; HARBOR_PID=$$; harbor_install_traps; harbor_lock_acquire "$1" operator; printf "hostname=%s\nboot_id=%s\npid=1\nstart_time=other\ncmdline=forged\n" "$(uname -n)" "$(harbor_lock_boot_id)" >"$1/lock.d/holder"; HARBOR_COMPLETED=1; exit 0' _ "${FIX_ROOT}"
  assert_success
  assert [ -f "${FIX_ROOT}/lock.d/holder" ]
  assert_equal "$(sed -n 's/^cmdline=//p' "${FIX_ROOT}/lock.d/holder")" forged
}

@test "repeated stale reclaims in the same second take lock.<utc>.<n>.stale names that do not exist yet and never nest" {
  harbor_utc_now() { printf '20260902T120000Z'; }
  mkdir "${FIX_ROOT}/lock.20260902T120000Z.stale" "${FIX_ROOT}/lock.20260902T120000Z.1.stale"
  HARBOR_PID="$$"
  for n in 2 3 4; do
    mkdir "${FIX_ROOT}/lock.d"
    holder_record "$(gone_pid)" "whatever" "harbor reclaim ${n}" >"${FIX_ROOT}/lock.d/holder"
    harbor_lock_acquire "${FIX_ROOT}" operator
    assert_equal "$(holder_pid "${FIX_ROOT}")" "$$"
    assert_equal "$(sed -n 's/^cmdline=//p' "${FIX_ROOT}/lock.20260902T120000Z.${n}.stale/holder")" "harbor reclaim ${n}"
    harbor_lock_release "${FIX_ROOT}"
  done
  run find "${FIX_ROOT}" -mindepth 2 -name '*.stale'
  assert_output ''
  run find "${FIX_ROOT}" -maxdepth 1 -name 'lock.*.stale'
  assert_equal "${#lines[@]}" 5
  assert [ ! -e "${FIX_ROOT}/reclaim.d" ]
}

@test "when a thousand archive names already exist the reclaim dies 3 lock.archive, releases its gate, and leaves lock.d in place" {
  harbor_utc_now() { printf '20260902T120000Z'; }
  mkdir "${FIX_ROOT}/lock.20260902T120000Z.stale"
  n=1
  while [ "${n}" -le 999 ]; do
    mkdir "${FIX_ROOT}/lock.20260902T120000Z.${n}.stale"
    n=$((n + 1))
  done
  mkdir "${FIX_ROOT}/lock.d"
  holder_record "$(gone_pid)" "whatever" "harbor crashed" >"${FIX_ROOT}/lock.d/holder"
  HARBOR_PID="$$"
  run harbor_lock_acquire "${FIX_ROOT}" operator
  assert_equal "${status}" 3
  assert_output --partial 'lock.archive'
  assert_equal "$(sed -n 's/^cmdline=//p' "${FIX_ROOT}/lock.d/holder")" 'harbor crashed'
  assert [ ! -e "${FIX_ROOT}/reclaim.d" ]
  assert [ ! -e "${FIX_ROOT}/lock.20260902T120000Z.1000.stale" ]
}

@test "double contender on an absent lock (library level): exactly one holder, one exit 3, no reclaim.d or archive left" {
  contender "${BATS_TEST_TMPDIR}/a.out"
  pa="${CONTENDER_PID}"
  contender "${BATS_TEST_TMPDIR}/b.out"
  pb="${CONTENDER_PID}"
  wait_for_one_exit "${pa}" "${pb}"
  assert [ -f "${FIX_ROOT}/lock.d/holder" ]
  assert [ ! -e "${FIX_ROOT}/reclaim.d" ]
  case "$(holder_pid "${FIX_ROOT}")" in
    "${pa}" | "${pb}") ;;
    *) fail "the holder names neither contender" ;;
  esac
  resume_holder "${FIX_ROOT}" lock-acquired
  sa=0
  wait "${pa}" || sa=$?
  sb=0
  wait "${pb}" || sb=$?
  assert_equal "$(( (sa == 0) + (sb == 0) ))" 1
  assert_equal "$(( (sa == 3) + (sb == 3) ))" 1
  assert [ ! -e "${FIX_ROOT}/lock.d" ]
  assert [ ! -e "${FIX_ROOT}/reclaim.d" ]
  run find "${FIX_ROOT}" -maxdepth 1 -name 'lock.*.stale'
  assert_output ''
  run cat "${BATS_TEST_TMPDIR}/a.out" "${BATS_TEST_TMPDIR}/b.out"
  assert_output --regexp 'lock\.(busy|gate_busy)'
  refute_output --partial 'failed at step'
}

@test "double contender on a stale lock (library level): exactly one holder, one exit 3, one archive, no reclaim.d left" {
  mkdir "${FIX_ROOT}/lock.d"
  holder_record "$(gone_pid)" "whatever" "harbor crashed" >"${FIX_ROOT}/lock.d/holder"
  contender "${BATS_TEST_TMPDIR}/a.out"
  pa="${CONTENDER_PID}"
  contender "${BATS_TEST_TMPDIR}/b.out"
  pb="${CONTENDER_PID}"
  wait_for_one_exit "${pa}" "${pb}"
  assert [ -f "${FIX_ROOT}/lock.d/holder" ]
  assert [ ! -e "${FIX_ROOT}/reclaim.d" ]
  resume_holder "${FIX_ROOT}" lock-acquired
  sa=0
  wait "${pa}" || sa=$?
  sb=0
  wait "${pb}" || sb=$?
  assert_equal "$(( (sa == 0) + (sb == 0) ))" 1
  assert_equal "$(( (sa == 3) + (sb == 3) ))" 1
  assert [ ! -e "${FIX_ROOT}/lock.d" ]
  assert [ ! -e "${FIX_ROOT}/reclaim.d" ]
  run find "${FIX_ROOT}" -maxdepth 1 -name 'lock.*.stale'
  assert_equal "${#lines[@]}" 1
  assert_equal "$(sed -n 's/^cmdline=//p' "${lines[0]}/holder")" 'harbor crashed'
  run cat "${BATS_TEST_TMPDIR}/a.out" "${BATS_TEST_TMPDIR}/b.out"
  assert_output --partial 'reclaimed stale lock'
  refute_output --partial 'failed at step'
}

@test "interrupted acquisition after lock-gate (library level): reclaim.d stays with its holder, the next acquisition refuses and touches nothing, removing reclaim.d lets it acquire" {
  run env HARBOR_TEST_HOOKS=1 HARBOR_FAIL_AFTER=lock-gate \
    bash -c '. "${HARBOR_ROOT}/lib/log.sh"; . "${HARBOR_ROOT}/lib/lock.sh"; HARBOR_PID=$$; harbor_lock_acquire "$1" operator' _ "${FIX_ROOT}"
  assert_equal "${status}" 137
  assert [ -f "${FIX_ROOT}/reclaim.d/holder" ]
  assert [ ! -e "${FIX_ROOT}/lock.d" ]
  gate_before="$(cat "${FIX_ROOT}/reclaim.d/holder")"
  HARBOR_PID="$$"
  run harbor_lock_acquire "${FIX_ROOT}" operator
  assert_equal "${status}" 3
  assert_output --partial 'lock.gate_busy'
  assert_output --partial "ls -la ${FIX_ROOT}/reclaim.d ${FIX_ROOT}/lock.d"
  assert_equal "$(cat "${FIX_ROOT}/reclaim.d/holder")" "${gate_before}"
  assert [ ! -e "${FIX_ROOT}/lock.d" ]
  rm -r "${FIX_ROOT}/reclaim.d"
  harbor_lock_acquire "${FIX_ROOT}" operator
  assert_equal "$(holder_pid "${FIX_ROOT}")" "$$"
  assert [ ! -e "${FIX_ROOT}/reclaim.d" ]
  harbor_lock_release "${FIX_ROOT}"
  assert [ ! -e "${FIX_ROOT}/lock.d" ]
}

@test "interrupted acquisition after lock-mkdir (library level): reclaim.d and a holderless lock.d stay, the next acquisition refuses, removing both lets it acquire" {
  run env HARBOR_TEST_HOOKS=1 HARBOR_FAIL_AFTER=lock-mkdir \
    bash -c '. "${HARBOR_ROOT}/lib/log.sh"; . "${HARBOR_ROOT}/lib/lock.sh"; HARBOR_PID=$$; harbor_lock_acquire "$1" operator' _ "${FIX_ROOT}"
  assert_equal "${status}" 137
  assert [ -f "${FIX_ROOT}/reclaim.d/holder" ]
  assert [ -d "${FIX_ROOT}/lock.d" ]
  assert [ ! -e "${FIX_ROOT}/lock.d/holder" ]
  HARBOR_PID="$$"
  run harbor_lock_acquire "${FIX_ROOT}" operator
  assert_equal "${status}" 3
  assert_output --partial 'lock.gate_busy'
  assert [ -f "${FIX_ROOT}/reclaim.d/holder" ]
  assert [ ! -e "${FIX_ROOT}/lock.d/holder" ]
  rm -r "${FIX_ROOT}/reclaim.d"
  run harbor_lock_acquire "${FIX_ROOT}" operator
  assert_equal "${status}" 3
  assert_output --partial 'lock.unreadable'
  assert [ -d "${FIX_ROOT}/lock.d" ]
  assert [ ! -e "${FIX_ROOT}/reclaim.d" ]
  rmdir "${FIX_ROOT}/lock.d"
  harbor_lock_acquire "${FIX_ROOT}" operator
  assert_equal "$(holder_pid "${FIX_ROOT}")" "$$"
  harbor_lock_release "${FIX_ROOT}"
  assert [ ! -e "${FIX_ROOT}/lock.d" ]
  run find "${FIX_ROOT}" -maxdepth 1 -name 'lock.*.stale'
  assert_output ''
}
