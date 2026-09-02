#!/usr/bin/env bats
load '../test_helper'

setup() {
  # lib/checks.sh depends only on lib/log.sh, so this file sources those two
  # rather than harbor_load_libs, which also loads the libraries later tasks create.
  # shellcheck source=lib/log.sh
  . "${HARBOR_ROOT}/lib/log.sh"
  # shellcheck source=lib/checks.sh
  . "${HARBOR_ROOT}/lib/checks.sh"
  harbor_check_reset
}

@test "an empty check set exits 0 and renders an empty list" {
  assert_equal "$(harbor_check_exit_code)" 0
  assert_equal "$(harbor_checks_json)" '{"checks":[]}'
  assert_equal "$(harbor_checks_text)" ""
}

@test "pass and unknown with an allowed reason keep exit 0" {
  harbor_check_add tailscale.installed pass
  harbor_check_add ufw.default unknown requires_root "run sudo harbor status --system"
  harbor_check_add sshd.dropin unknown busy
  harbor_check_add t3.linked unknown requires_operator
  assert_equal "$(harbor_check_exit_code)" 0
}

@test "degraded and unknown with another reason give exit 1, broken gives exit 2" {
  harbor_check_add a degraded
  assert_equal "$(harbor_check_exit_code)" 1
  harbor_check_reset
  harbor_check_add root.lock unknown stale_lock "see design section 3.7"
  assert_equal "$(harbor_check_exit_code)" 1
  harbor_check_add b broken "unit not running"
  assert_equal "$(harbor_check_exit_code)" 2
}

@test "an unknown state name is a usage error" {
  run harbor_check_add x maybe
  assert_equal "${status}" 3
  assert_output --partial 'checks.state'
}

@test "JSON output escapes and orders records" {
  harbor_check_add node.version pass "" 'v22 "exact"'
  harbor_check_add ufw.default unknown requires_root
  assert_equal "$(harbor_checks_json)" '{"checks":[{"id":"node.version","state":"pass","reason":"","detail":"v22 \"exact\""},{"id":"ufw.default","state":"unknown","reason":"requires_root","detail":""}]}'
}

@test "text output is one line per record with tabs replaced" {
  tab="$(printf '\t')"
  harbor_check_add node.version pass "" "one${tab}two"
  harbor_check_add b degraded slow
  run harbor_checks_text
  assert_line --index 0 'node.version pass  one two'
  assert_line --index 1 'b degraded slow '
}

@test "tabs and newlines in any field cannot split or shift a record" {
  tab="$(printf '\t')"
  nl="$(printf '\n.')"
  nl="${nl%.}"
  harbor_check_add "a${tab}b" broken "r${nl}s" "d${nl}e"
  assert_equal "$(harbor_check_exit_code)" 2
  assert_equal "$(harbor_checks_json)" '{"checks":[{"id":"a b","state":"broken","reason":"r s","detail":"d e"}]}'
}
