#!/usr/bin/env bats
load '../test_helper'

setup() {
  # lib/log.sh depends on nothing, so this file sources it alone rather than
  # through harbor_load_libs, which also loads the libraries later tasks create.
  # shellcheck source=lib/log.sh
  . "${HARBOR_ROOT}/lib/log.sh"
}

@test "harbor_utc_now prints a compact UTC timestamp" {
  run harbor_utc_now
  assert_success
  assert_output --regexp '^[0-9]{8}T[0-9]{6}Z$'
}

@test "harbor_msg writes one prefixed line to stderr and nothing to stdout" {
  run --separate-stderr harbor_msg hello world
  assert_success
  assert_equal "${output}" ""
  assert_equal "${stderr}" "harbor: hello world"
}

@test "harbor_log appends timestamped lines only when a log file is open" {
  run harbor_log step lock-gate
  assert_success
  assert_output ""
  harbor_log_open "${BATS_TEST_TMPDIR}/h.log" 0600
  harbor_log step lock-gate
  harbor_log exit 0
  run cat "${BATS_TEST_TMPDIR}/h.log"
  assert_line --index 0 --regexp '^[0-9]{8}T[0-9]{6}Z step lock-gate$'
  assert_line --index 1 --regexp '^[0-9]{8}T[0-9]{6}Z exit 0$'
  run ls -l "${BATS_TEST_TMPDIR}/h.log"
  assert_output --regexp '^-rw-------'
}

@test "harbor_log echoes to stderr under HARBOR_VERBOSE=1" {
  HARBOR_VERBOSE=1
  run --separate-stderr harbor_log step lock-gate
  assert_equal "${stderr}" "harbor: step: lock-gate"
}

@test "harbor_json_escape escapes backslash, quote, tab, and newline" {
  tab="$(printf '\t')"
  nl="$(printf '\n.')"
  nl="${nl%.}"
  run harbor_json_escape "a\"b\\c${tab}d${nl}e"
  assert_success
  assert_output 'a\"b\\c\td\ne'
  run harbor_json_escape "a${nl}${nl}"
  assert_output 'a\n\n'
  run harbor_json_escape "${nl}a"
  assert_output '\na'
}

@test "harbor_die prints the id and message, exits with the code, and emits JSON only under HARBOR_JSON=1" {
  run --separate-stderr harbor_die 3 lock.busy "held by pid 42"
  assert_equal "${status}" 3
  assert_equal "${output}" ""
  assert_equal "${stderr}" "harbor: lock.busy: held by pid 42"
  HARBOR_JSON=1
  run --separate-stderr harbor_die 2 journal.collision "entry exists"
  assert_equal "${status}" 2
  assert_equal "${output}" '{"error":"journal.collision"}'
  assert_equal "${stderr}" "harbor: journal.collision: entry exists"
}

@test "harbor_die logs the error id and exit code" {
  harbor_log_open "${BATS_TEST_TMPDIR}/h.log" 0600
  run harbor_die 4 hook.pause_timeout "waited"
  assert_equal "${status}" 4
  run cat "${BATS_TEST_TMPDIR}/h.log"
  assert_output --regexp ' error hook.pause_timeout exit=4$'
}

@test "harbor_die keeps its exit code when the log file cannot be written" {
  # A fresh shell under set -euo pipefail, as bin/harbor runs, so a failing log
  # append would abort the shell before exit CODE if harbor_die let it.
  run --separate-stderr /bin/bash -euo pipefail -c \
    '. "${1}"; HARBOR_LOG_FILE="${2}"; harbor_die 3 lock.busy "held"' \
    _ "${HARBOR_ROOT}/lib/log.sh" "${BATS_TEST_TMPDIR}/missing/h.log"
  assert_equal "${status}" 3
  assert_equal "${output}" ""
  assert_equal "${stderr_lines[0]}" "harbor: lock.busy: held"
}

@test "harbor_redact_argv drops secret values and strips URL queries and fragments" {
  run harbor_redact_argv tailscale up --auth-key SECRETVALUE --hostname harbor-node
  assert_output 'tailscale up --auth-key --hostname harbor-node'
  run harbor_redact_argv t3 connect --token=SECRETVALUE 'https://RELAY_HOSTNAME/pair?x=1#frag' --ssh
  assert_output 't3 connect --token https://RELAY_HOSTNAME/pair --ssh'
  run harbor_redact_argv codex --key SECRETVALUE --api-key SECRETVALUE --password SECRETVALUE --secret SECRETVALUE --authkey SECRETVALUE
  assert_output 'codex --key --api-key --password --secret --authkey'
  run harbor_redact_argv curl 'https://user:SECRETPW@RELAY_HOSTNAME/x?y#z'
  assert_output 'curl https://RELAY_HOSTNAME/x'
  refute_output --partial SECRETPW
  run harbor_redact_argv curl 'https://RELAY_HOSTNAME/p@th'
  assert_output 'curl https://RELAY_HOSTNAME/p@th'
  run harbor_redact_argv
  assert_output ''
}

@test "harbor_log_vendor writes the redacted argv at level vendor" {
  harbor_log_open "${BATS_TEST_TMPDIR}/h.log" 0600
  harbor_log_vendor tailscale up --auth-key SECRETVALUE
  run cat "${BATS_TEST_TMPDIR}/h.log"
  assert_output --regexp ' vendor tailscale up --auth-key$'
  refute_output --partial SECRETVALUE
}

@test "harbor_step records the current step and logs it" {
  harbor_log_open "${BATS_TEST_TMPDIR}/h.log" 0600
  harbor_step lock-gate
  assert_equal "${HARBOR_CURRENT_STEP}" lock-gate
  run cat "${BATS_TEST_TMPDIR}/h.log"
  assert_output --regexp ' step lock-gate$'
}

@test "hooks are inert without HARBOR_TEST_HOOKS=1" {
  run env HARBOR_FAIL_AFTER=lock-gate HARBOR_PAUSE_AFTER=lock-gate \
    bash -c '. "${HARBOR_ROOT}/lib/log.sh"; HARBOR_PID=$$; harbor_step lock-gate; echo survived'
  assert_success
  assert_output survived
  run env HARBOR_TEST_HOOKS=0 HARBOR_FAIL_AFTER=lock-gate HARBOR_PAUSE_AFTER=lock-gate \
    bash -c '. "${HARBOR_ROOT}/lib/log.sh"; HARBOR_PID=$$; harbor_step lock-gate; echo survived'
  assert_success
  assert_output survived
}

@test "the pause sentinel is derived from TMPDIR, HARBOR_PID, and the step, and matches the harness helper" {
  run env TMPDIR=/x/ bash -c '. "${HARBOR_ROOT}/lib/log.sh"; HARBOR_PID=4242; harbor_test_pause_sentinel lock-gate'
  assert_output '/x/harbor-pause.4242.lock-gate'
  run env -u TMPDIR bash -c '. "${HARBOR_ROOT}/lib/log.sh"; HARBOR_PID=4242; harbor_test_pause_sentinel lock-gate'
  assert_output '/tmp/harbor-pause.4242.lock-gate'
  run env TMPDIR=/x bash -c '. "${HARBOR_ROOT}/lib/log.sh"; harbor_test_pause_sentinel resolve-confirmed'
  assert_output --regexp '^/x/harbor-pause\.[0-9]+\.resolve-confirmed$'
  HARBOR_PID=4242
  assert_equal "$(harbor_test_pause_sentinel lock-gate)" "$(pause_sentinel 4242 lock-gate)"
}

@test "HARBOR_FAIL_AFTER kills the process at exactly that boundary" {
  run env HARBOR_TEST_HOOKS=1 HARBOR_FAIL_AFTER=lock-mkdir \
    bash -c '. "${HARBOR_ROOT}/lib/log.sh"; HARBOR_PID=$$; harbor_step lock-gate; echo passed-gate; harbor_step lock-mkdir; echo survived'
  assert_equal "${status}" 137
  assert_output passed-gate
}

@test "HARBOR_PAUSE_AFTER pauses at exactly that step until this process's sentinel appears, then consumes it" {
  env HARBOR_TEST_HOOKS=1 HARBOR_PAUSE_AFTER=lock-acquired \
    bash -c '. "${HARBOR_ROOT}/lib/log.sh"; HARBOR_PID=$$; harbor_step lock-gate; harbor_step lock-acquired; echo resumed' \
    >"${BATS_TEST_TMPDIR}/out" 3>&- &
  pid=$!
  sleep 1
  kill -0 "${pid}"
  assert_equal "$(cat "${BATS_TEST_TMPDIR}/out")" ""
  touch "$(pause_sentinel "$((pid + 1))" lock-acquired)" "$(pause_sentinel "${pid}" lock-gate)"
  sleep 0.5
  kill -0 "${pid}"
  assert_equal "$(cat "${BATS_TEST_TMPDIR}/out")" ""
  touch "$(pause_sentinel "${pid}" lock-acquired)"
  wait "${pid}"
  assert_equal "$(cat "${BATS_TEST_TMPDIR}/out")" resumed
  assert [ ! -e "$(pause_sentinel "${pid}" lock-acquired)" ]
  assert [ -e "$(pause_sentinel "$((pid + 1))" lock-acquired)" ]
  assert [ -e "$(pause_sentinel "${pid}" lock-gate)" ]
  rm -f "$(pause_sentinel "$((pid + 1))" lock-acquired)" "$(pause_sentinel "${pid}" lock-gate)"
}

@test "HARBOR_PAUSE_AFTER for a different step does not pause" {
  run env HARBOR_TEST_HOOKS=1 HARBOR_PAUSE_AFTER=lock-mkdir \
    bash -c '. "${HARBOR_ROOT}/lib/log.sh"; HARBOR_PID=$$; harbor_step lock-gate; echo survived'
  assert_success
  assert_output survived
}

@test "ERR trap names the step, the command, and the next command" {
  run --separate-stderr bash -c '. "${HARBOR_ROOT}/lib/log.sh"; set -euo pipefail; harbor_install_traps; harbor_step lock-gate; false'
  assert_equal "${status}" 1
  assert_regex "${stderr_lines[0]}" '^harbor: failed at step lock-gate \(exit 1\) running: false$'
  assert_equal "${stderr_lines[1]}" 'harbor: next: rerun the same command after fixing the cause'
  run --separate-stderr bash -c '. "${HARBOR_ROOT}/lib/log.sh"; set -euo pipefail; harbor_install_traps; HARBOR_NEXT_COMMAND="harbor journal resolve 0001 --reverted"; false'
  assert_equal "${stderr_lines[1]}" 'harbor: next: harbor journal resolve 0001 --reverted'
}

@test "INT and TERM exit 4 and print the interrupted JSON object under HARBOR_JSON=1" {
  run --separate-stderr bash -c '. "${HARBOR_ROOT}/lib/log.sh"; set -euo pipefail; harbor_install_traps; HARBOR_JSON=1; kill -TERM $$; sleep 5; echo survived'
  assert_equal "${status}" 4
  assert_equal "${output}" '{"error":"interrupted"}'
  run bash -c '. "${HARBOR_ROOT}/lib/log.sh"; set -euo pipefail; harbor_install_traps; kill -INT $$; sleep 5; echo survived'
  assert_equal "${status}" 4
  assert_output ''
}

@test "EXIT trap logs the exit code and preserves it" {
  run bash -c '. "${HARBOR_ROOT}/lib/log.sh"; set -euo pipefail; harbor_install_traps; harbor_log_open "'"${BATS_TEST_TMPDIR}"'/h.log" 0600; exit 3'
  assert_equal "${status}" 3
  run cat "${BATS_TEST_TMPDIR}/h.log"
  assert_output --regexp ' exit 3$'
}

@test "EXIT trap reports exit 2 when the process reaches status 0 without HARBOR_COMPLETED=1" {
  # bash 3.2 presents $? as 0 inside the EXIT trap after a fatal set -u abort, so
  # a crash would otherwise be logged and reported as success. First the exact
  # contract for a plain status 0 with no completion flag, which every bash gives;
  # then the abort itself: exit 2 wherever bash discards the status, never 0.
  run --separate-stderr bash -c '. "${HARBOR_ROOT}/lib/log.sh"; set -euo pipefail; harbor_install_traps; harbor_log_open "'"${BATS_TEST_TMPDIR}"'/h.log" 0600; true'
  assert_equal "${status}" 2
  assert_equal "${stderr}" 'harbor: terminated before completion (exit 2)'
  run tail -n 1 "${BATS_TEST_TMPDIR}/h.log"
  assert_output --regexp ' exit 2 incomplete$'
  probe="$(bash -c 'set -eu; trap "printf %s \$?" EXIT; echo "${NOPE}"' 2>/dev/null)"
  run --separate-stderr bash -c '. "${HARBOR_ROOT}/lib/log.sh"; set -euo pipefail; harbor_install_traps; harbor_log_open "'"${BATS_TEST_TMPDIR}"'/h.log" 0600; echo "${NOPE}"'
  assert_not_equal "${status}" 0
  assert_equal "${output}" ""
  run tail -n 1 "${BATS_TEST_TMPDIR}/h.log"
  if [ "${probe}" = 0 ]; then
    assert_output --regexp ' exit 2 incomplete$'
  else
    assert_output --regexp " exit ${probe}\$"
  fi
}

@test "EXIT trap keeps exit 0 once HARBOR_COMPLETED=1 is set" {
  run --separate-stderr bash -c '. "${HARBOR_ROOT}/lib/log.sh"; set -euo pipefail; harbor_install_traps; harbor_log_open "'"${BATS_TEST_TMPDIR}"'/h.log" 0600; HARBOR_COMPLETED=1; exit 0'
  assert_equal "${status}" 0
  assert_equal "${stderr}" ""
  run tail -n 1 "${BATS_TEST_TMPDIR}/h.log"
  assert_output --regexp ' exit 0$'
}

@test "EXIT trap keeps the exit code and the interrupt contract when the lock release fails" {
  # harbor_lock_release arrives in Task 8; here it is undefined, so the call fails.
  run bash -c '. "${HARBOR_ROOT}/lib/log.sh"; set -euo pipefail; harbor_install_traps; HARBOR_LOCK_ROOT=/tmp/x; exit 3'
  assert_equal "${status}" 3
  run --separate-stderr bash -c '. "${HARBOR_ROOT}/lib/log.sh"; set -euo pipefail; harbor_install_traps; HARBOR_JSON=1; HARBOR_LOCK_ROOT=/tmp/x; kill -TERM $$; sleep 5; echo survived'
  assert_equal "${status}" 4
  assert_equal "${output}" '{"error":"interrupted"}'
}

@test "HUP exits 4 and prints the interrupted JSON object under HARBOR_JSON=1" {
  run --separate-stderr bash -c '. "${HARBOR_ROOT}/lib/log.sh"; set -euo pipefail; harbor_install_traps; HARBOR_JSON=1; kill -HUP $$; sleep 5; echo survived'
  assert_equal "${status}" 4
  assert_equal "${output}" '{"error":"interrupted"}'
}

@test "ERR trap reports a failing command substitution once, naming the enclosing command" {
  run --separate-stderr bash -c '. "${HARBOR_ROOT}/lib/log.sh"; set -euo pipefail; harbor_install_traps; harbor_step lock-gate; v=$(false)'
  assert_equal "${status}" 1
  assert_equal "${#stderr_lines[@]}" 2
  assert_equal "${stderr_lines[0]}" 'harbor: failed at step lock-gate (exit 1) running: v=$(false)'
  assert_equal "${stderr_lines[1]}" 'harbor: next: rerun the same command after fixing the cause'
}

@test "harbor_test_hook refuses a non-numeric HARBOR_PID before signalling, and only once gated" {
  # A witness process proves the refusal happened before any kill: with
  # HARBOR_PID=-1 an unguarded kill -KILL would signal every process of this user.
  sleep 30 3>&- &
  witness=$!
  run --separate-stderr env HARBOR_TEST_HOOKS=1 HARBOR_FAIL_AFTER=lock-gate HARBOR_PID=-1 \
    bash -c '. "${HARBOR_ROOT}/lib/log.sh"; harbor_step lock-gate; echo survived'
  kill -0 "${witness}"
  kill "${witness}"
  assert_equal "${status}" 3
  assert_equal "${output}" ""
  assert_regex "${stderr}" 'hook\.bad_pid'
  run env HARBOR_FAIL_AFTER=lock-gate HARBOR_PID=-1 \
    bash -c '. "${HARBOR_ROOT}/lib/log.sh"; harbor_step lock-gate; echo survived'
  assert_success
  assert_output survived
}
