#!/usr/bin/env bats
load '../test_helper'

setup() {
  harbor_load_libs
  fixture_state_root
}

root_fixture() {
  # root_fixture: make the libraries in this test process believe the principal
  # is root with a state root under BATS_TEST_TMPDIR (ROOT_FIX). The override
  # lives in this process only; nothing under /var/lib is touched.
  ROOT_FIX="${BATS_TEST_TMPDIR}/var-lib-harbor"
  harbor_state_root_for_principal() {
    HARBOR_STATE_ROOT="${ROOT_FIX}"
    HARBOR_LOCK_KIND=root
  }
  HARBOR_PID="$$"
  HARBOR_CMDLINE="harbor journal resolve"
}

root_resolve() {
  # root_resolve TYPED SEQ: harbor_journal_resolve in this process, TYPED on stdin
  harbor_journal_resolve "${2}" --reverted <<<"${1}"
}

@test "journal without resolve, a bad entry number, and a missing --reverted are usage errors" {
  run env HOME="${FIX_HOME}" "${HARBOR}" journal
  assert_equal "${status}" 3
  assert_output --partial 'usage: harbor journal resolve <NNNN> --reverted'
  run env HOME="${FIX_HOME}" "${HARBOR}" journal frobnicate
  assert_equal "${status}" 3
  run env HOME="${FIX_HOME}" "${HARBOR}" journal resolve 1 --reverted
  assert_equal "${status}" 3
  assert_output --partial 'four digits'
  run env HOME="${FIX_HOME}" "${HARBOR}" journal resolve 0001
  assert_equal "${status}" 3
  run env HOME="${FIX_HOME}" "${HARBOR}" journal resolve 0001 --applied
  assert_equal "${status}" 3
  assert [ ! -e "${FIX_ROOT}/lock.d" ]
}

@test "the operator state root, journal, and log are created with their modes when absent" {
  rm -r "${FIX_ROOT}"
  run resolve_cmd 0001 0001
  assert_equal "${status}" 3
  assert_output --partial 'journal.resolve_missing'
  run ls -ld "${FIX_ROOT}" "${FIX_ROOT}/journal"
  assert_line --index 0 --regexp '^drwx------'
  assert_line --index 1 --regexp '^drwx------'
  run ls -l "${FIX_ROOT}/harbor.log"
  assert_output --regexp '^-rw-------'
  assert [ ! -e "${FIX_ROOT}/lock.d" ]
  assert [ ! -e "${FIX_ROOT}/reclaim.d" ]
  run cat "${FIX_ROOT}/harbor.log"
  assert_output --partial 'command journal resolve 0001 --reverted'
  assert_output --partial 'step recovery-scan'
  assert_output --regexp 'error journal.resolve_missing exit=3'
  assert_output --regexp ' exit 3$'
}

@test "resolving an undecidable entry marks it reverted with resolved_by operator and never touches the artifact" {
  fixture_undecidable_file_entry "${FIX_ROOT}" 0001
  run --separate-stderr resolve_cmd 0001 0001
  assert_success
  assert_equal "${output}" ""
  assert_regex "${stderr}" 'journal entry 0001-file.json is undecidable:'
  assert_regex "${stderr}" "Type the entry number 0001 to mark it reverted without touching ${FIX_ARTIFACT_0001}: "
  assert_regex "${stderr}" 'entry 0001 marked reverted \(resolved_by: operator\)'
  refute_regex "${stderr}" 'failed at step'
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" reverted
  assert_equal "$(entry_raw "${FIX_ROOT}" 0001 resolved_by)" '"operator"'
  assert_regex "$(entry_raw "${FIX_ROOT}" 0001 resolved_at)" '^"[0-9]{8}T[0-9]{6}Z"$'
  assert_equal "$(cat "${FIX_ARTIFACT_0001}")" two
  assert [ ! -e "${FIX_ROOT}/lock.d" ]
  assert [ ! -e "${FIX_ROOT}/reclaim.d" ]
  run ls -A "${FIX_ROOT}/journal"
  assert_output 0001-file.json
  run cat "${FIX_ROOT}/harbor.log"
  assert_output --partial 'step resolve-confirmed'
  assert_output --partial '0001-file.json reverted resolved_by=operator'
  assert_output --regexp ' exit 0$'
}

@test "resolve refuses without the exact entry number typed back and writes nothing" {
  fixture_undecidable_file_entry "${FIX_ROOT}" 0001
  run resolve_cmd 0002 0001
  assert_equal "${status}" 3
  assert_output --partial 'journal.resolve_unconfirmed'
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" prepared
  run resolve_cmd '' 0001
  assert_equal "${status}" 3
  assert_output --partial 'journal.resolve_unconfirmed'
  run env HOME="${FIX_HOME}" HARBOR_DEV=1 "${HARBOR}" journal resolve 0001 --reverted </dev/null
  assert_equal "${status}" 3
  assert_output --partial 'journal.resolve_unconfirmed'
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" prepared
  assert_equal "$(entry_raw "${FIX_ROOT}" 0001 resolved_by)" ""
  assert [ ! -e "${FIX_ROOT}/lock.d" ]
  run cat "${FIX_ROOT}/harbor.log"
  refute_output --partial 'step resolve-confirmed'
}

@test "resolve acts only on a prepared, undecidable entry" {
  fixture_entry "${FIX_ROOT}" 0001 file "${BATS_TEST_TMPDIR}/absent" created prepared '"absent"' '{"sha256":"ab","mode":"0644","owner":"root"}'
  run resolve_cmd 0001 0001
  assert_equal "${status}" 3
  assert_output --partial 'journal.resolve_decidable'
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" prepared
  fixture_entry "${FIX_ROOT}" 0002 file /x created applied '"absent"' '"absent"'
  run resolve_cmd 0002 0002
  assert_equal "${status}" 3
  assert_output --partial 'journal.resolve_not_prepared'
  assert_output --partial 'is applied'
  run resolve_cmd 0009 0009
  assert_equal "${status}" 3
  assert_output --partial 'journal.resolve_missing'
  assert [ ! -e "${FIX_ROOT}/lock.d" ]
}

@test "three entries: the decidable one is recovered, the other undecidable one is reported and kept, only the named one is resolved, and ordinary recovery still exits 2 naming it" {
  fixture_undecidable_file_entry "${FIX_ROOT}" 0001
  fixture_entry "${FIX_ROOT}" 0002 file "${BATS_TEST_TMPDIR}/absent" created prepared '"absent"' '{"sha256":"ab","mode":"0644","owner":"root"}'
  fixture_undecidable_file_entry "${FIX_ROOT}" 0003
  run --separate-stderr resolve_cmd 0001 0001
  assert_success
  assert_regex "${stderr}" 'journal entry 0003-file.json is undecidable:'
  assert_regex "${stderr}" 'journal entry 0001-file.json is undecidable:'
  assert_regex "${stderr}" 'still undecidable and blocking ordinary commands: 0003'
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" reverted
  assert_equal "$(entry_raw "${FIX_ROOT}" 0001 resolved_by)" '"operator"'
  assert_equal "$(entry_phase "${FIX_ROOT}" 0002)" reverted
  assert_equal "$(entry_raw "${FIX_ROOT}" 0002 resolved_by)" ""
  assert_equal "$(entry_phase "${FIX_ROOT}" 0003)" prepared
  assert_equal "$(cat "${FIX_ARTIFACT_0001}")" two
  assert_equal "$(cat "${FIX_ARTIFACT_0003}")" two

  HARBOR_PID="$$"
  harbor_lock_acquire "${FIX_ROOT}" operator
  run --separate-stderr harbor_journal_recover "${FIX_ROOT}"
  assert_equal "${status}" 2
  assert_regex "${stderr}" 'journal.undecidable: prepared entries 0003 cannot be decided'
  harbor_lock_release "${FIX_ROOT}"

  run resolve_cmd 0003 0003
  assert_success
  assert_equal "$(entry_phase "${FIX_ROOT}" 0003)" reverted
  harbor_lock_acquire "${FIX_ROOT}" operator
  harbor_journal_recover "${FIX_ROOT}"
  assert_equal "${HARBOR_JOURNAL_UNDECIDABLE}" ""
  harbor_lock_release "${FIX_ROOT}"
}

@test "a malformed named entry is refused with exit 2 journal.malformed, left unchanged, and no lock is left behind" {
  fixture_undecidable_file_entry "${FIX_ROOT}" 0001
  grep -v '"target"' "${FIX_ROOT}/journal/0001-file.json" >"${BATS_TEST_TMPDIR}/stripped"
  cat "${BATS_TEST_TMPDIR}/stripped" >"${FIX_ROOT}/journal/0001-file.json"
  before="$(cat "${FIX_ROOT}/journal/0001-file.json")"
  run resolve_cmd 0001 0001
  assert_equal "${status}" 2
  assert_output --partial 'journal.malformed'
  assert_output --partial '0001-file.json'
  refute_output --partial 'Type the entry number'
  assert_equal "$(cat "${FIX_ROOT}/journal/0001-file.json")" "${before}"
  assert_equal "$(cat "${FIX_ARTIFACT_0001}")" two
  assert [ ! -e "${FIX_ROOT}/lock.d" ]
  run ls -A "${FIX_ROOT}/journal"
  assert_output 0001-file.json
}

@test "root branch: an absent state root is refused with exit 3 naming sudo harbor bootstrap, and nothing is created" {
  root_fixture
  run root_resolve 0001 0001
  assert_equal "${status}" 3
  assert_output --partial 'journal.no_state_root'
  assert_output --partial 'sudo harbor bootstrap'
  assert [ ! -e "${ROOT_FIX}" ]
  assert [ ! -e "${FIX_ROOT}/lock.d" ]
}

@test "root branch: an existing state root keeps its mode; journal 0700, bootstrap.log 0600, lock.d 0755 with a 0644 holder, no harbor.log" {
  root_fixture
  mkdir "${ROOT_FIX}"
  chmod 0750 "${ROOT_FIX}"
  run root_resolve 0001 0001
  assert_equal "${status}" 3
  assert_output --partial 'journal.resolve_missing'
  run ls -ld "${ROOT_FIX}" "${ROOT_FIX}/journal"
  assert_line --index 0 --regexp '^drwxr-x---'
  assert_line --index 1 --regexp '^drwx------'
  run ls -l "${ROOT_FIX}/bootstrap.log"
  assert_output --regexp '^-rw-------'
  assert [ ! -e "${ROOT_FIX}/harbor.log" ]
  run cat "${ROOT_FIX}/bootstrap.log"
  assert_output --partial 'command journal resolve 0001 --reverted'
  assert_output --partial 'step recovery-scan'
  assert_output --regexp 'error journal.resolve_missing exit=3'
  # harbor_die ended the run capture, not this process, and no Harbor EXIT trap
  # is installed here, so the lock the capture took is still on disk with the
  # root modes and this process's pid; the body releases it.
  run ls -ld "${ROOT_FIX}/lock.d"
  assert_output --regexp '^drwxr-xr-x'
  run ls -l "${ROOT_FIX}/lock.d/holder"
  assert_output --regexp '^-rw-r--r--'
  assert_equal "$(holder_pid "${ROOT_FIX}")" "$$"
  assert [ ! -e "${ROOT_FIX}/reclaim.d" ]
  harbor_lock_release "${ROOT_FIX}"
  assert [ ! -e "${ROOT_FIX}/lock.d" ]
}

@test "root branch: an undecidable entry under an existing state root is resolved by the typed number and the artifact is untouched" {
  root_fixture
  mkdir "${ROOT_FIX}"
  fixture_undecidable_file_entry "${ROOT_FIX}" 0001
  run --separate-stderr root_resolve 0001 0001
  assert_success
  assert_equal "${output}" ""
  assert_regex "${stderr}" 'journal entry 0001-file.json is undecidable:'
  assert_regex "${stderr}" 'entry 0001 marked reverted \(resolved_by: operator\)'
  assert_equal "$(entry_phase "${ROOT_FIX}" 0001)" reverted
  assert_equal "$(entry_raw "${ROOT_FIX}" 0001 resolved_by)" '"operator"'
  assert_equal "$(cat "${FIX_ARTIFACT_0001}")" two
  run cat "${ROOT_FIX}/bootstrap.log"
  assert_output --partial 'step resolve-confirmed'
  assert_output --partial '0001-file.json reverted resolved_by=operator'
  assert [ ! -e "${ROOT_FIX}/harbor.log" ]
  harbor_lock_release "${ROOT_FIX}"
  assert [ ! -e "${ROOT_FIX}/lock.d" ]
}
