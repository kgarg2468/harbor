#!/usr/bin/env bats
load '../test_helper'

setup() {
  harbor_load_libs
  fixture_state_root
  fixture_undecidable_file_entry "${FIX_ROOT}" 0001
  PAUSED_PIDS=""
  KEEP_PID=""
}

teardown() {
  # Resume and reap every paused command so a failed assertion leaks nothing.
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

paused_resolve() {
  # paused_resolve STEP OUTFILE: a background resolve of 0001 paused at STEP until
  # its sentinel appears. env execs bin/harbor, so PAUSED_PID is the harbor
  # process itself: the pid in its holder record and in its sentinel name.
  env HOME="${FIX_HOME}" HARBOR_DEV=1 HARBOR_TEST_HOOKS=1 HARBOR_PAUSE_AFTER="${1}" \
    "${HARBOR}" journal resolve 0001 --reverted <<<"0001" >"${2}" 2>&1 3>&- &
  PAUSED_PID=$!
  PAUSED_PIDS="${PAUSED_PIDS} ${PAUSED_PID}"
}

gone_pid() {
  sleep 0.01 3>&- &
  local p=$!
  wait "${p}"
  printf '%s' "${p}"
}

stale_count() {
  find "${FIX_ROOT}" -maxdepth 1 -name 'lock.*.stale' | wc -l | tr -d ' '
}

@test "held lock: resolve against a paused command exits 3 with lock.busy and writes nothing" {
  paused_resolve lock-acquired "${BATS_TEST_TMPDIR}/a.out"
  pa="${PAUSED_PID}"
  wait_for_log_step "${FIX_ROOT}" lock-acquired
  before="$(cat "${FIX_ROOT}/lock.d/holder")"
  assert_equal "$(holder_pid "${FIX_ROOT}")" "${pa}"
  run resolve_cmd 0001 0001
  assert_equal "${status}" 3
  assert_output --partial 'lock.busy'
  assert_output --partial "pid ${pa}"
  assert_equal "$(cat "${FIX_ROOT}/lock.d/holder")" "${before}"
  assert [ ! -e "${FIX_ROOT}/reclaim.d" ]
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" prepared
  resume_holder "${FIX_ROOT}" lock-acquired
  wait "${pa}"
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" reverted
  assert [ ! -e "${FIX_ROOT}/lock.d" ]
}

@test "nested command: a resolve launched while this process holds the lock exits 3 with lock.busy and leaves the parent's lock and the entry alone" {
  HARBOR_PID="$$"
  harbor_lock_acquire "${FIX_ROOT}" operator
  before="$(cat "${FIX_ROOT}/lock.d/holder")"
  run resolve_cmd 0001 0001
  assert_equal "${status}" 3
  assert_output --partial 'lock.busy'
  assert_output --partial "pid $$"
  assert_equal "$(cat "${FIX_ROOT}/lock.d/holder")" "${before}"
  assert [ ! -e "${FIX_ROOT}/reclaim.d" ]
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" prepared
  harbor_lock_release "${FIX_ROOT}"
  assert [ ! -e "${FIX_ROOT}/lock.d" ]
}

@test "double contender on an absent lock: exactly one holder, one exit 3, no reclaim.d left" {
  paused_resolve lock-acquired "${BATS_TEST_TMPDIR}/a.out"
  pa="${PAUSED_PID}"
  paused_resolve lock-acquired "${BATS_TEST_TMPDIR}/b.out"
  pb="${PAUSED_PID}"
  # A contender's exit is not the point at which the winner is quiescent. The loser
  # can lose at the gate mkdir rather than at the lock, and that happens while the
  # winner is still inside harbor_lock_acquire, before it has created lock.d or
  # written its holder record: asserting on the loser's exit alone races the winner
  # and fails on whichever runner is fast enough to land in that window.
  # harbor_step logs its step before harbor_test_hook pauses, and lock-acquired is
  # stepped after harbor_lock_gate_release, so this log line is exactly the point at
  # which the holder record is written and the gate is gone. Wait for it first, and
  # wait_for_one_exit below then waits for the loser, the winner being paused.
  wait_for_log_step "${FIX_ROOT}" lock-acquired
  wait_for_one_exit "${pa}" "${pb}"
  assert [ -f "${FIX_ROOT}/lock.d/holder" ]
  assert [ ! -d "${FIX_ROOT}/reclaim.d" ]
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
  assert [ ! -d "${FIX_ROOT}/lock.d" ]
  assert [ ! -d "${FIX_ROOT}/reclaim.d" ]
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" reverted
  assert_equal "$(stale_count)" 0
  run cat "${BATS_TEST_TMPDIR}/a.out" "${BATS_TEST_TMPDIR}/b.out"
  assert_output --partial 'lock.'
  refute_output --partial 'failed at step'
}

@test "double contender on a stale lock: exactly one holder, one exit 3, one archived lock.*.stale, no reclaim.d left" {
  mkdir "${FIX_ROOT}/lock.d"
  holder_record "$(gone_pid)" "whatever" "harbor crashed" >"${FIX_ROOT}/lock.d/holder"
  paused_resolve lock-acquired "${BATS_TEST_TMPDIR}/a.out"
  pa="${PAUSED_PID}"
  paused_resolve lock-acquired "${BATS_TEST_TMPDIR}/b.out"
  pb="${PAUSED_PID}"
  # Same reason as the test above, and one window wider here: the winner reclaims by
  # renaming lock.d aside before it makes its own, so there is a moment in a stale
  # reclaim when lock.d does not exist at all.
  wait_for_log_step "${FIX_ROOT}" lock-acquired
  wait_for_one_exit "${pa}" "${pb}"
  assert [ -f "${FIX_ROOT}/lock.d/holder" ]
  assert [ ! -d "${FIX_ROOT}/reclaim.d" ]
  resume_holder "${FIX_ROOT}" lock-acquired
  sa=0
  wait "${pa}" || sa=$?
  sb=0
  wait "${pb}" || sb=$?
  assert_equal "$(( (sa == 0) + (sb == 0) ))" 1
  assert_equal "$(( (sa == 3) + (sb == 3) ))" 1
  assert [ ! -d "${FIX_ROOT}/lock.d" ]
  assert [ ! -d "${FIX_ROOT}/reclaim.d" ]
  assert_equal "$(stale_count)" 1
  assert_equal "$(sed -n 's/^cmdline=//p' "${FIX_ROOT}"/lock.*.stale/holder)" 'harbor crashed'
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" reverted
  run cat "${BATS_TEST_TMPDIR}/a.out" "${BATS_TEST_TMPDIR}/b.out"
  refute_output --partial 'failed at step'
}

@test "interrupted acquisition after the gate: reclaim.d stays, the next command refuses and touches nothing, manual removal lets it acquire" {
  run resolve_cmd 0001 0001 HARBOR_TEST_HOOKS=1 HARBOR_FAIL_AFTER=lock-gate
  assert_equal "${status}" 137
  assert [ -f "${FIX_ROOT}/reclaim.d/holder" ]
  assert [ ! -e "${FIX_ROOT}/lock.d" ]
  gate_before="$(cat "${FIX_ROOT}/reclaim.d/holder")"
  run resolve_cmd 0001 0001
  assert_equal "${status}" 3
  assert_output --partial 'lock.gate_busy'
  assert_output --partial "ls -la ${FIX_ROOT}/reclaim.d ${FIX_ROOT}/lock.d"
  assert_equal "$(cat "${FIX_ROOT}/reclaim.d/holder")" "${gate_before}"
  assert [ ! -e "${FIX_ROOT}/lock.d" ]
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" prepared
  rm -r "${FIX_ROOT}/reclaim.d"
  run resolve_cmd 0001 0001
  assert_success
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" reverted
  assert [ ! -e "${FIX_ROOT}/lock.d" ]
  assert [ ! -e "${FIX_ROOT}/reclaim.d" ]
}

@test "interrupted acquisition after mkdir lock.d: reclaim.d and an unpopulated lock.d stay, the next command refuses, removing both lets it acquire" {
  run resolve_cmd 0001 0001 HARBOR_TEST_HOOKS=1 HARBOR_FAIL_AFTER=lock-mkdir
  assert_equal "${status}" 137
  assert [ -f "${FIX_ROOT}/reclaim.d/holder" ]
  assert [ -d "${FIX_ROOT}/lock.d" ]
  assert [ ! -e "${FIX_ROOT}/lock.d/holder" ]
  run resolve_cmd 0001 0001
  assert_equal "${status}" 3
  assert_output --partial 'lock.gate_busy'
  assert [ -f "${FIX_ROOT}/reclaim.d/holder" ]
  assert [ ! -e "${FIX_ROOT}/lock.d/holder" ]
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" prepared
  rm -r "${FIX_ROOT}/reclaim.d"
  run resolve_cmd 0001 0001
  assert_equal "${status}" 3
  assert_output --partial 'lock.unreadable'
  assert [ -d "${FIX_ROOT}/lock.d" ]
  assert [ ! -e "${FIX_ROOT}/reclaim.d" ]
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" prepared
  rmdir "${FIX_ROOT}/lock.d"
  run resolve_cmd 0001 0001
  assert_success
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" reverted
  assert [ ! -e "${FIX_ROOT}/lock.d" ]
  assert_equal "$(stale_count)" 0
}

@test "ownership re-check: a holder paused before the journal write whose holder record is forged exits 2 and writes nothing" {
  sleep 30 3>&- &
  KEEP_PID=$!
  paused_resolve resolve-confirmed "${BATS_TEST_TMPDIR}/a.out"
  pa="${PAUSED_PID}"
  wait_for_log_step "${FIX_ROOT}" resolve-confirmed
  holder_record "${KEEP_PID}" "$(harbor_lock_start_time "${KEEP_PID}")" "harbor other" >"${FIX_ROOT}/lock.d/holder"
  # The holder record is forged now, so resume by the paused pid, not the holder.
  touch "$(pause_sentinel "${pa}" resolve-confirmed)"
  sa=0
  wait "${pa}" || sa=$?
  assert_equal "${sa}" 2
  run cat "${BATS_TEST_TMPDIR}/a.out"
  assert_output --partial 'lock.lost'
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" prepared
  assert_equal "$(entry_raw "${FIX_ROOT}" 0001 resolved_by)" ""
  assert_equal "$(sed -n 's/^cmdline=//p' "${FIX_ROOT}/lock.d/holder")" 'harbor other'
  run ls -A "${FIX_ROOT}/journal"
  assert_output 0001-file.json
}
