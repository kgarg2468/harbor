#!/usr/bin/env bats
load '../test_helper'

setup() {
  # lib/journal.sh depends only on lib/log.sh and lib/lock.sh, so this file sources
  # those three rather than harbor_load_libs, which also loads the other libraries.
  # shellcheck source=lib/log.sh
  . "${HARBOR_ROOT}/lib/log.sh"
  # shellcheck source=lib/lock.sh
  . "${HARBOR_ROOT}/lib/lock.sh"
  # shellcheck source=lib/journal.sh
  . "${HARBOR_ROOT}/lib/journal.sh"
  fixture_state_root
  HARBOR_PID="$$"
  KEEP_PID=""
}

teardown() {
  if [ -n "${KEEP_PID}" ]; then
    kill "${KEEP_PID}" 2>/dev/null || true
  fi
}

@test "sha256, mode, and owner observe a regular file" {
  printf 'hello\n' >"${BATS_TEST_TMPDIR}/f"
  chmod 0640 "${BATS_TEST_TMPDIR}/f"
  assert_equal "$(harbor_sha256 "${BATS_TEST_TMPDIR}/f")" 5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03
  assert_equal "$(harbor_stat_mode "${BATS_TEST_TMPDIR}/f")" 0640
  assert_equal "$(harbor_stat_owner "${BATS_TEST_TMPDIR}/f")" "$(id -un)"
}

@test "harbor_observe_file renders absent, non-regular, and regular targets" {
  assert_equal "$(harbor_observe_file "${BATS_TEST_TMPDIR}/nope")" '"absent"'
  mkdir "${BATS_TEST_TMPDIR}/dir"
  assert_equal "$(harbor_observe_file "${BATS_TEST_TMPDIR}/dir")" '"unobservable:not-a-regular-file"'
  ln -s "${BATS_TEST_TMPDIR}/nope" "${BATS_TEST_TMPDIR}/link"
  assert_equal "$(harbor_observe_file "${BATS_TEST_TMPDIR}/link")" '"unobservable:not-a-regular-file"'
  printf 'hello\n' >"${BATS_TEST_TMPDIR}/f"
  chmod 0644 "${BATS_TEST_TMPDIR}/f"
  assert_equal "$(harbor_observe_file "${BATS_TEST_TMPDIR}/f")" "{\"sha256\":\"5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03\",\"mode\":\"0644\",\"owner\":\"$(id -un)\"}"
  assert_equal "$(harbor_journal_observe file "${BATS_TEST_TMPDIR}/nope")" '"absent"'
  assert_equal "$(harbor_journal_observe package curl)" '"unobservable:package"'
}

@test "the sync helper uses per-file sync on Linux and whole-filesystem sync on Darwin" {
  printf 'x\n' >"${BATS_TEST_TMPDIR}/f"
  harbor_journal_sync_path "${BATS_TEST_TMPDIR}/f"
  case "$(uname -s)" in
    Linux) assert_equal "${HARBOR_SYNC_MODE}" file ;;
    Darwin) assert_equal "${HARBOR_SYNC_MODE}" fs ;;
  esac
  HARBOR_SYNC_MODE=file
  run harbor_journal_sync_path "${BATS_TEST_TMPDIR}/missing"
  if [ "$(uname -s)" = "Linux" ]; then
    assert_equal "${status}" 2
    assert_output --partial 'journal.sync'
  fi
  HARBOR_OS=Plan9
  HARBOR_SYNC_MODE=""
  run harbor_journal_sync_path "${BATS_TEST_TMPDIR}/f"
  assert_equal "${status}" 3
  assert_output --partial 'journal.platform'
}

@test "harbor_journal_init creates a 0700 journal directory once" {
  rm -r "${FIX_ROOT}/journal"
  harbor_journal_init "${FIX_ROOT}"
  run ls -ld "${FIX_ROOT}/journal"
  assert_output --regexp '^drwx------'
  assert_equal "$(harbor_journal_dir "${FIX_ROOT}")" "${FIX_ROOT}/journal"
  harbor_journal_init "${FIX_ROOT}"
}

@test "render produces the canonical entry text with and without resolution fields" {
  run harbor_journal_render file /etc/x created prepared '"absent"' '{"sha256":"ab","mode":"0644","owner":"root"}'
  assert_line --index 0 '{'
  assert_line --index 1 '  "op": "file",'
  assert_line --index 2 '  "target": "/etc/x",'
  assert_line --index 3 '  "ownership": "created",'
  assert_line --index 4 '  "phase": "prepared",'
  assert_line --index 5 '  "pre_state": "absent",'
  assert_line --index 6 '  "post_state": {"sha256":"ab","mode":"0644","owner":"root"}'
  assert_line --index 7 '}'
  assert_equal "${#lines[@]}" 8
  run harbor_journal_render file '/tmp/we"ird' created reverted '"absent"' '"absent"' operator 20260902T120000Z
  assert_line --index 2 '  "target": "/tmp/we\"ird",'
  assert_line --index 6 '  "post_state": "absent",'
  assert_line --index 7 '  "resolved_by": "operator",'
  assert_line --index 8 '  "resolved_at": "20260902T120000Z"'
  assert_line --index 9 '}'
}

@test "field, raw, string, and unquote read a canonical entry back" {
  fixture_entry "${FIX_ROOT}" 0001 file '/tmp/we\"ird' created prepared '"absent"' '{"sha256":"ab","mode":"0644","owner":"root"}'
  e="${FIX_ROOT}/journal/0001-file.json"
  assert_equal "$(harbor_journal_field "${e}" post_state)" '{"sha256":"ab","mode":"0644","owner":"root"}'
  assert_equal "$(harbor_journal_field "${e}" pre_state)" '"absent"'
  run harbor_journal_field "${e}" resolved_by
  assert_failure
  assert_equal "$(harbor_journal_raw "${e}" resolved_by)" ""
  assert_equal "$(harbor_journal_string "${e}" target)" '/tmp/we"ird'
  assert_equal "$(harbor_journal_string "${e}" phase)" prepared
  assert_equal "$(harbor_json_unquote '"a\\b"')" 'a\b'
  assert_equal "$(harbor_json_unquote '{"k":1}')" '{"k":1}'
}

@test "print_entry writes the undecidable block to stderr" {
  fixture_entry "${FIX_ROOT}" 0002 file /etc/x created prepared '"absent"' '{"sha256":"ab","mode":"0644","owner":"root"}'
  run --separate-stderr harbor_journal_print_entry "${FIX_ROOT}/journal/0002-file.json" '{"sha256":"cd","mode":"0644","owner":"root"}'
  assert_equal "${output}" ""
  assert_equal "${stderr_lines[0]}" 'journal entry 0002-file.json is undecidable:'
  assert_equal "${stderr_lines[1]}" '  op:         file'
  assert_equal "${stderr_lines[2]}" '  target:     /etc/x'
  assert_equal "${stderr_lines[3]}" '  pre_state:  "absent"'
  assert_equal "${stderr_lines[4]}" '  post_state: {"sha256":"ab","mode":"0644","owner":"root"}'
  assert_equal "${stderr_lines[5]}" '  observed:   {"sha256":"cd","mode":"0644","owner":"root"}'
}
