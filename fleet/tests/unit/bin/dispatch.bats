#!/usr/bin/env bats
load '../test_helper'

setup() {
  harbor_load_libs
  fixture_state_root
}

@test "the entry point is executable and runs under /bin/bash" {
  assert [ -x "${HARBOR}" ]
  assert_equal "$(head -n 1 "${HARBOR}")" '#!/bin/bash'
}

@test "unknown subcommand: exit 3, exactly one JSON object on stdout, one line on stderr" {
  run --separate-stderr "${HARBOR}" bogus
  assert_equal "${status}" 3
  assert_equal "${output}" '{"error":"unknown_subcommand","subcommand":"bogus"}'
  assert_equal "${stderr}" 'harbor: unknown subcommand: bogus'
}

@test "unknown subcommand with --json anywhere: the same reply" {
  run --separate-stderr "${HARBOR}" status --json
  assert_equal "${status}" 3
  assert_equal "${output}" '{"error":"unknown_subcommand","subcommand":"status"}'
  assert_equal "${stderr}" 'harbor: unknown subcommand: status'
}

@test "unknown subcommand name is JSON-escaped" {
  run --separate-stderr "${HARBOR}" 'we"ird'
  assert_equal "${status}" 3
  assert_equal "${output}" '{"error":"unknown_subcommand","subcommand":"we\"ird"}'
}

@test "unknown subcommand answers before any lock or journal access" {
  mkdir "${FIX_ROOT}/reclaim.d"
  fixture_undecidable_file_entry "${FIX_ROOT}" 0001
  run --separate-stderr env HOME="${FIX_HOME}" "${HARBOR}" provision
  assert_equal "${status}" 3
  assert_equal "${output}" '{"error":"unknown_subcommand","subcommand":"provision"}'
  assert [ -d "${FIX_ROOT}/reclaim.d" ]
  assert [ ! -e "${FIX_ROOT}/lock.d" ]
  assert [ ! -e "${FIX_ROOT}/harbor.log" ]
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" prepared
  fixture_home
  rm -r "${FIX_HOME}"
  mkdir "${FIX_HOME}"
  run env HOME="${FIX_HOME}" "${HARBOR}" bogus
  assert [ ! -e "${FIX_HOME}/.local" ]
}

@test "no subcommand prints usage to stderr and exits 3; help prints it to stdout and exits 0" {
  run --separate-stderr "${HARBOR}"
  assert_equal "${status}" 3
  assert_equal "${output}" ""
  assert_regex "${stderr}" '^usage: harbor <subcommand>'
  run --separate-stderr "${HARBOR}" help
  assert_success
  assert_regex "${output}" '^usage: harbor <subcommand>'
  assert_regex "${output}" 'journal resolve <NNNN> --reverted'
  run "${HARBOR}" --help
  assert_success
  run "${HARBOR}" -h
  assert_success
}

@test "the dispatcher runs from a symlink" {
  ln -s "${HARBOR}" "${BATS_TEST_TMPDIR}/harbor"
  run --separate-stderr "${BATS_TEST_TMPDIR}/harbor" bogus
  assert_equal "${status}" 3
  assert_equal "${output}" '{"error":"unknown_subcommand","subcommand":"bogus"}'
}
