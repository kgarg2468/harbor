#!/usr/bin/env bats
# fleet/tests/unit/lib/client_json.bats
setup() {
  [ "$(uname -s)" = Darwin ] || skip 'the client runs on macOS only'
  load '../test_helper'
  harbor_load_libs
  . "${HARBOR_ROOT}/lib/client.sh"
}

@test "an object flattens to one dotted path per scalar" {
  run harbor_client_json_flatten <<'JSON'
{"access":{"mode":"connect"},"n":3,"ok":true,"nil":null}
JSON
  assert_success
  assert_line "$(printf 'access.mode\t"connect"')"
  assert_line "$(printf 'n\t3')"
  assert_line "$(printf 'ok\ttrue')"
  assert_line "$(printf 'nil\tnull')"
}

@test "an array flattens to numeric path components" {
  run harbor_client_json_flatten <<'JSON'
{"checks":[{"id":"ssh.node","state":"pass"},{"id":"t3.environment","state":"fail"}]}
JSON
  assert_success
  assert_line "$(printf 'checks.0.id\t"ssh.node"')"
  assert_line "$(printf 'checks.1.state\t"fail"')"
}

@test "a value containing a newline or a tab still occupies one line" {
  run harbor_client_json_flatten <<'JSON'
{"detail":"first\nsecond\tthird"}
JSON
  assert_success
  assert_equal "${#lines[@]}" 1
  assert_line "$(printf 'detail\t"first\\nsecond\\tthird"')"
}

@test "a body that is not JSON fails rather than emitting nothing" {
  run harbor_client_json_flatten <<'BODY'
harbor: unknown subcommand: status
BODY
  assert_failure
}

@test "an empty body fails rather than flattening to nothing" {
  run harbor_client_json_flatten </dev/null
  assert_failure
}

@test "a field is returned decoded, and a missing one is distinguishable from an empty one" {
  printf 'a\t"x\\ty"\nb\t""\n' >"${BATS_TEST_TMPDIR}/flat"
  run harbor_client_json_field "${BATS_TEST_TMPDIR}/flat" a
  assert_success
  assert_output "$(printf 'x\ty')"
  run harbor_client_json_field "${BATS_TEST_TMPDIR}/flat" b
  assert_success
  assert_output ''
  run harbor_client_json_has "${BATS_TEST_TMPDIR}/flat" b
  assert_success
  run harbor_client_json_has "${BATS_TEST_TMPDIR}/flat" c
  assert_failure
}

@test "an encoded literal backslash-n stays two characters" {
  printf 'x\t"lit \\\\n not newline"\n' >"${BATS_TEST_TMPDIR}/flat"
  run harbor_client_json_field "${BATS_TEST_TMPDIR}/flat" x
  assert_success
  assert_output 'lit \n not newline'
}

@test "a dotted path is matched literally, not as a regular expression" {
  # Every flattened path is dotted, and an unescaped dot matches any character.
  # A reader asked for access.mode must not answer with the value of a key that
  # merely looks like it under a regex.
  printf 'accessXmode\t"wrong"\naccess.mode\t"connect"\n' >"${BATS_TEST_TMPDIR}/flat"
  run harbor_client_json_field "${BATS_TEST_TMPDIR}/flat" access.mode
  assert_success
  assert_output 'connect'
  printf 'accessXmode\t"wrong"\n' >"${BATS_TEST_TMPDIR}/only"
  run harbor_client_json_field "${BATS_TEST_TMPDIR}/only" access.mode
  assert_success
  assert_output ''
  run harbor_client_json_has "${BATS_TEST_TMPDIR}/only" access.mode
  assert_failure
}
