#!/usr/bin/env bats
load '../test_helper'

setup() {
  CHECK="${HARBOR_ROOT}/tests/lint/engines_check.sh"
  LOCK="${BATS_TEST_TMPDIR}/versions.lock"
}

fixture_lock() {
  # fixture_lock KEY=VALUE ...: the repository lock with each named key replaced.
  # The loader requires every schema key once and does not care about their order,
  # so a replacement drops the old line and appends the new one.
  local pair key tmp="${BATS_TEST_TMPDIR}/versions.lock.tmp"
  cp "${HARBOR_ROOT}/versions.lock" "${LOCK}"
  for pair in ${1+"$@"}; do
    key="${pair%%=*}"
    grep -v "^${key}=" "${LOCK}" >"${tmp}"
    printf '%s\n' "${pair}" >>"${tmp}"
    mv "${tmp}" "${LOCK}"
  done
}

@test "the repository's own locked pair passes with exit 0" {
  run "${CHECK}"
  assert_success
  assert_output --partial 'nodejs_version'
  assert_output --partial 't3_engines_node'
}

@test "a locked Node.js version outside the locked range exits 3 naming both values" {
  fixture_lock 'nodejs_version=22.15.0' 't3_engines_node=^22.16 || ^23.11 || >=24.10'
  run "${CHECK}" "${LOCK}"
  assert_equal "${status}" 3
  assert_output --partial 'versions.node_range'
  assert_output --partial '22.15.0'
  assert_output --partial '^22.16 || ^23.11 || >=24.10'
}

@test "a locked range in an unsupported form exits 3 rather than guessing" {
  fixture_lock 'nodejs_version=24.20.0' 't3_engines_node=~24.10'
  run "${CHECK}" "${LOCK}"
  assert_equal "${status}" 3
  assert_output --partial 'versions.semver_range'
}

@test "the check resolves its own lock from an unrelated working directory" {
  cd "${BATS_TEST_TMPDIR}"
  run "${CHECK}"
  assert_success
  assert_output --partial "${HARBOR_ROOT}/versions.lock"
}
