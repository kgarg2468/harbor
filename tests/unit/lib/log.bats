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
