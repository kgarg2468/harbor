#!/usr/bin/env bats
load '../test_helper'

setup() {
  SHIM_BIN="${HARBOR_ROOT}/tests/shims/bin"
  LOG="${BATS_TEST_TMPDIR}/shim.log"
}

@test "a shim takes its name from the symlink and replies from the healthy scenario by default" {
  assert [ -L "${SHIM_BIN}/fakevendor" ]
  assert_equal "$(readlink "${SHIM_BIN}/fakevendor")" harbor-shim
  run env PATH="${SHIM_BIN}:${PATH}" HARBOR_SHIM_LOG="${LOG}" fakevendor version
  assert_success
  assert_output 'fakevendor 1.2.3'
}

@test "the failing scenario replies with its exit file" {
  run env HARBOR_SHIM_SCENARIO=failing "${SHIM_BIN}/fakevendor" version
  assert_equal "${status}" 2
  assert_output 'fakevendor: boom'
}

@test "every invocation appends its argv tab-separated to the shim log" {
  tab="$(printf '\t')"
  env HARBOR_SHIM_LOG="${LOG}" "${SHIM_BIN}/fakevendor" version
  env HARBOR_SHIM_LOG="${LOG}" HARBOR_SHIM_SCENARIO=failing "${SHIM_BIN}/fakevendor" version || true
  run cat "${LOG}"
  assert_line --index 0 "fakevendor${tab}version"
  assert_line --index 1 "fakevendor${tab}version"
  assert_equal "${#lines[@]}" 2
}

@test "a missing fixture is a test error with exit 97 and is still logged" {
  run env HARBOR_SHIM_LOG="${LOG}" "${SHIM_BIN}/fakevendor" serve --https=443 /path
  assert_equal "${status}" 97
  assert_output --partial 'no fixture'
  assert_output --partial 'fakevendor/healthy/serve_--https=443_%path.out'
  run "${SHIM_BIN}/fakevendor"
  assert_equal "${status}" 97
  assert_output --partial '/_noargs.out'
  assert_equal "$(cat "${LOG}")" "$(printf 'fakevendor\tserve\t--https=443\t/path')"
}

@test "HARBOR_SHIM_FIXTURES redirects fixture lookup" {
  mkdir -p "${BATS_TEST_TMPDIR}/fx/fakevendor/healthy"
  printf 'elsewhere\n' >"${BATS_TEST_TMPDIR}/fx/fakevendor/healthy/version.out"
  run env HARBOR_SHIM_FIXTURES="${BATS_TEST_TMPDIR}/fx" "${SHIM_BIN}/fakevendor" version
  assert_success
  assert_output elsewhere
}
