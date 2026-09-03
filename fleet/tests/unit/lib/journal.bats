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

acquire() {
  harbor_lock_acquire "${FIX_ROOT}" operator
}

refuse_malformed() {
  # refuse_malformed ENTRY: harbor_journal_validate exits 2 journal.malformed naming ENTRY
  run harbor_journal_validate "${1}"
  assert_equal "${status}" 2
  assert_output --partial 'journal.malformed'
  assert_output --partial "$(basename "${1}")"
}

@test "entries are created through ln with unique ascending sequence numbers and no temporary file left" {
  acquire
  harbor_journal_create "${FIX_ROOT}" file /etc/a created prepared '"absent"' '{"sha256":"ab","mode":"0644","owner":"root"}'
  assert_equal "${HARBOR_JOURNAL_ENTRY}" "${FIX_ROOT}/journal/0001-file.json"
  harbor_journal_create "${FIX_ROOT}" file /etc/b modified prepared '{"sha256":"cd","mode":"0644","owner":"root"}' '{"sha256":"ef","mode":"0644","owner":"root"}'
  harbor_journal_create "${FIX_ROOT}" package curl observed applied '"unobservable:package"' '"unobservable:package"'
  run ls -A "${FIX_ROOT}/journal"
  assert_line --index 0 0001-file.json
  assert_line --index 1 0002-file.json
  assert_line --index 2 0003-package.json
  assert_equal "${#lines[@]}" 3
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" prepared
  assert_equal "$(entry_phase "${FIX_ROOT}" 0003)" applied
  assert_equal "$(cat "${FIX_ROOT}/journal/0001-file.json")" "$(harbor_journal_render file /etc/a created prepared '"absent"' '{"sha256":"ab","mode":"0644","owner":"root"}')"
  harbor_lock_release "${FIX_ROOT}"
}

@test "the sequence continues from the highest existing entry" {
  fixture_entry "${FIX_ROOT}" 0041 file /x created applied '"absent"' '"absent"'
  harbor_journal_next_seq "${FIX_ROOT}/journal"
  assert_equal "${HARBOR_JOURNAL_SEQ}" 0042
  rm "${FIX_ROOT}/journal/0041-file.json"
  harbor_journal_next_seq "${FIX_ROOT}/journal"
  assert_equal "${HARBOR_JOURNAL_SEQ}" 0001
  fixture_entry "${FIX_ROOT}" 9999 file /x created applied '"absent"' '"absent"'
  run harbor_journal_next_seq "${FIX_ROOT}/journal"
  assert_equal "${status}" 2
  assert_output --partial 'journal.full'
}

@test "a forced sequence collision aborts with exit 2 naming both files and overwrites nothing" {
  acquire
  harbor_journal_create "${FIX_ROOT}" file /etc/a created prepared '"absent"' '"absent"'
  before="$(cat "${FIX_ROOT}/journal/0001-file.json")"
  harbor_journal_next_seq() { HARBOR_JOURNAL_SEQ=0001; }
  run harbor_journal_create "${FIX_ROOT}" file /etc/other created prepared '"absent"' '"absent"'
  assert_equal "${status}" 2
  assert_output --partial 'journal.collision'
  assert_output --partial "${FIX_ROOT}/journal/0001-file.json"
  assert_output --partial "${FIX_ROOT}/journal/.tmp.0001.${HARBOR_PID}"
  assert_equal "$(cat "${FIX_ROOT}/journal/0001-file.json")" "${before}"
  run ls -A "${FIX_ROOT}/journal"
  assert_output 0001-file.json
  harbor_lock_release "${FIX_ROOT}"
}

@test "set_phase rewrites by rename-over, keeps every other field, and records operator resolution" {
  acquire
  harbor_journal_create "${FIX_ROOT}" file /etc/a created prepared '"absent"' '{"sha256":"ab","mode":"0644","owner":"root"}'
  e="${HARBOR_JOURNAL_ENTRY}"
  harbor_journal_set_phase "${e}" applied
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" applied
  assert_equal "$(harbor_journal_raw "${e}" post_state)" '{"sha256":"ab","mode":"0644","owner":"root"}'
  assert_equal "$(harbor_journal_string "${e}" target)" /etc/a
  assert_equal "$(harbor_journal_raw "${e}" resolved_by)" ""
  harbor_journal_set_phase "${e}" reverted operator
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" reverted
  assert_equal "$(harbor_journal_string "${e}" resolved_by)" operator
  assert_regex "$(harbor_journal_string "${e}" resolved_at)" '^[0-9]{8}T[0-9]{6}Z$'
  harbor_journal_validate "${e}"
  run ls -A "${FIX_ROOT}/journal"
  assert_output 0001-file.json
  run harbor_journal_set_phase "${e}" done
  assert_equal "${status}" 3
  assert_output --partial 'journal.phase'
  printf '{\n  "phase": "prepared"\n}\n' >"${FIX_ROOT}/journal/0002-file.json"
  run harbor_journal_set_phase "${FIX_ROOT}/journal/0002-file.json" applied
  assert_equal "${status}" 2
  assert_output --partial 'journal.malformed'
  harbor_lock_release "${FIX_ROOT}"
}

@test "a holder whose lock was reclaimed exits 2 before creating or rewriting any entry" {
  sleep 30 3>&- &
  KEEP_PID=$!
  acquire
  harbor_journal_create "${FIX_ROOT}" file /etc/a created prepared '"absent"' '"absent"'
  e="${HARBOR_JOURNAL_ENTRY}"
  holder_record "${KEEP_PID}" "$(harbor_lock_start_time "${KEEP_PID}")" >"${FIX_ROOT}/lock.d/holder"
  run harbor_journal_create "${FIX_ROOT}" file /etc/b created prepared '"absent"' '"absent"'
  assert_equal "${status}" 2
  assert_output --partial 'lock.lost'
  run harbor_journal_set_phase "${e}" applied
  assert_equal "${status}" 2
  assert_output --partial 'lock.lost'
  run ls -A "${FIX_ROOT}/journal"
  assert_output 0001-file.json
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" prepared
  rm -r "${FIX_ROOT}/lock.d"
}

@test "validate accepts a canonical entry and rejects a missing or empty target, a bad ownership or phase, a duplicate key, and a missing or empty state" {
  fixture_entry "${FIX_ROOT}" 0001 file /etc/a created prepared '"absent"' '"absent"'
  good="${FIX_ROOT}/journal/0001-file.json"
  bad="${FIX_ROOT}/journal/0002-file.json"
  harbor_journal_validate "${good}"
  grep -v '"target"' "${good}" >"${bad}"
  run harbor_journal_validate "${bad}"
  assert_equal "${status}" 2
  assert_output --partial 'journal.malformed'
  assert_output --partial '0002-file.json'
  sed 's|"target": "/etc/a"|"target": ""|' "${good}" >"${bad}"
  run harbor_journal_validate "${bad}"
  assert_equal "${status}" 2
  assert_output --partial 'journal.malformed'
  sed 's/"ownership": "created"/"ownership": "owned"/' "${good}" >"${bad}"
  run harbor_journal_validate "${bad}"
  assert_equal "${status}" 2
  assert_output --partial 'journal.malformed'
  sed 's/"phase": "prepared"/"phase": "done"/' "${good}" >"${bad}"
  run harbor_journal_validate "${bad}"
  assert_equal "${status}" 2
  assert_output --partial 'journal.malformed'
  sed '/"phase"/p' "${good}" >"${bad}"
  run harbor_journal_validate "${bad}"
  assert_equal "${status}" 2
  assert_output --partial 'journal.malformed'
  grep -v '"post_state"' "${good}" >"${bad}"
  run harbor_journal_validate "${bad}"
  assert_equal "${status}" 2
  assert_output --partial 'journal.malformed'
  sed 's/"pre_state": "absent"/"pre_state": /' "${good}" >"${bad}"
  run harbor_journal_validate "${bad}"
  assert_equal "${status}" 2
  assert_output --partial 'journal.malformed'
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" prepared
}

@test "validate rejects every departure from the canonical shape: unknown key, extra line, trailing content, missing newline, wrong order, comma faults, brace faults" {
  fixture_entry "${FIX_ROOT}" 0001 file /etc/a created prepared '"absent"' '"absent"'
  good="${FIX_ROOT}/journal/0001-file.json"
  bad="${FIX_ROOT}/journal/0002-file.json"
  harbor_journal_validate "${good}"
  sed 's/"ownership"/"owner"/' "${good}" >"${bad}"
  refuse_malformed "${bad}"
  awk 'NR == 4 { print; print "  \"extra\": \"x\","; next } { print }' "${good}" >"${bad}"
  refuse_malformed "${bad}"
  { cat "${good}"; printf 'junk\n'; } >"${bad}"
  refuse_malformed "${bad}"
  { cat "${good}"; printf '\n'; } >"${bad}"
  refuse_malformed "${bad}"
  printf '%s' "$(cat "${good}")" >"${bad}"
  refuse_malformed "${bad}"
  sed -e '2{h;d;}' -e '3G' "${good}" >"${bad}"
  refuse_malformed "${bad}"
  sed '2s/,$//' "${good}" >"${bad}"
  refuse_malformed "${bad}"
  sed '7s/$/,/' "${good}" >"${bad}"
  refuse_malformed "${bad}"
  sed '1s/{/[/' "${good}" >"${bad}"
  refuse_malformed "${bad}"
  sed '8s/}/]/' "${good}" >"${bad}"
  refuse_malformed "${bad}"
  sed '1d' "${good}" >"${bad}"
  refuse_malformed "${bad}"
  sed '$d' "${good}" >"${bad}"
  refuse_malformed "${bad}"
  sed 's/^  "op"/ "op"/' "${good}" >"${bad}"
  refuse_malformed "${bad}"
  sed 's/"op": "file"/"op":"file"/' "${good}" >"${bad}"
  refuse_malformed "${bad}"
  : >"${bad}"
  refuse_malformed "${bad}"
  harbor_journal_validate "${good}"
}

@test "validate accepts a canonical resolved entry and rejects a partial, duplicated, empty, unquoted, or misplaced resolution pair and resolution fields on a non-reverted entry" {
  full="${FIX_ROOT}/journal/0001-file.json"
  bad="${FIX_ROOT}/journal/0002-file.json"
  harbor_journal_render file /etc/a created reverted '"absent"' '"absent"' operator 20260902T120000Z >"${full}"
  harbor_journal_validate "${full}"
  harbor_journal_render file /etc/a created reverted '"absent"' '"absent"' >"${bad}"
  harbor_journal_validate "${bad}"
  grep -v '"resolved_at"' "${full}" | sed '8s/,$//' >"${bad}"
  refuse_malformed "${bad}"
  grep -v '"resolved_by"' "${full}" >"${bad}"
  refuse_malformed "${bad}"
  sed 's/"resolved_at": "20260902T120000Z"/"resolved_by": "operator"/' "${full}" >"${bad}"
  refuse_malformed "${bad}"
  sed 's/"resolved_by": "operator",/"resolved_at": "20260902T120000Z",/' "${full}" >"${bad}"
  refuse_malformed "${bad}"
  sed 's/"resolved_by": "operator"/"resolved_by": ""/' "${full}" >"${bad}"
  refuse_malformed "${bad}"
  sed 's/"resolved_at": "20260902T120000Z"/"resolved_at": ""/' "${full}" >"${bad}"
  refuse_malformed "${bad}"
  sed 's/"resolved_at": "20260902T120000Z"/"resolved_at": 20260902T120000Z/' "${full}" >"${bad}"
  refuse_malformed "${bad}"
  awk 'NR == 7 { held = $0; next } NR == 9 { print; print held; next } { print }' "${full}" >"${bad}"
  refuse_malformed "${bad}"
  harbor_journal_render file /etc/a created prepared '"absent"' '"absent"' operator 20260902T120000Z >"${bad}"
  refuse_malformed "${bad}"
  harbor_journal_render file /etc/a created applied '"absent"' '"absent"' operator 20260902T120000Z >"${bad}"
  refuse_malformed "${bad}"
  harbor_journal_validate "${full}"
}

@test "recovery marks a pre-equal entry reverted, a post-equal entry applied, and refuses on an undecidable one with exit 2" {
  acquire
  printf 'landed\n' >"${BATS_TEST_TMPDIR}/b"
  post_b="$(harbor_observe_file "${BATS_TEST_TMPDIR}/b")"
  fixture_entry "${FIX_ROOT}" 0001 file "${BATS_TEST_TMPDIR}/a" created prepared '"absent"' '{"sha256":"ab","mode":"0644","owner":"root"}'
  fixture_entry "${FIX_ROOT}" 0002 file "${BATS_TEST_TMPDIR}/b" created prepared '"absent"' "${post_b}"
  fixture_undecidable_file_entry "${FIX_ROOT}" 0003
  fixture_entry "${FIX_ROOT}" 0004 file "${BATS_TEST_TMPDIR}/d" created applied '"absent"' '"absent"'
  run --separate-stderr harbor_journal_recover "${FIX_ROOT}"
  assert_equal "${status}" 2
  assert_regex "${stderr}" 'journal entry 0003-file.json is undecidable:'
  assert_regex "${stderr}" 'journal.undecidable: prepared entries 0003 cannot be decided'
  assert_regex "${stderr}" 'harbor journal resolve <NNNN> --reverted'
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" reverted
  assert_equal "$(entry_phase "${FIX_ROOT}" 0002)" applied
  assert_equal "$(entry_phase "${FIX_ROOT}" 0003)" prepared
  assert_equal "$(entry_phase "${FIX_ROOT}" 0004)" applied
  assert_equal "$(cat "${FIX_ARTIFACT_0003}")" two
  harbor_lock_release "${FIX_ROOT}"
}

@test "recovery on a clean or absent journal returns 0 and touches nothing" {
  acquire
  fixture_entry "${FIX_ROOT}" 0001 file /x created applied '"absent"' '"absent"'
  harbor_journal_recover "${FIX_ROOT}"
  assert_equal "${HARBOR_JOURNAL_UNDECIDABLE}" ""
  rm -r "${FIX_ROOT}/journal"
  harbor_journal_recover "${FIX_ROOT}"
  assert [ ! -e "${FIX_ROOT}/journal" ]
  harbor_lock_release "${FIX_ROOT}"
}

@test "lenient recovery skips the named entry, recovers the decidable ones, reports the other undecidable one, and returns 0" {
  acquire
  fixture_undecidable_file_entry "${FIX_ROOT}" 0001
  fixture_entry "${FIX_ROOT}" 0002 file "${BATS_TEST_TMPDIR}/absent" created prepared '"absent"' '{"sha256":"ab","mode":"0644","owner":"root"}'
  fixture_undecidable_file_entry "${FIX_ROOT}" 0003
  run --separate-stderr harbor_journal_recover "${FIX_ROOT}" 0001
  assert_success
  assert_regex "${stderr}" 'journal entry 0003-file.json is undecidable:'
  refute_regex "${stderr}" '0001-file.json'
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" prepared
  assert_equal "$(entry_phase "${FIX_ROOT}" 0002)" reverted
  assert_equal "$(entry_phase "${FIX_ROOT}" 0003)" prepared
  harbor_journal_recover "${FIX_ROOT}" 0001 2>/dev/null
  assert_equal "${HARBOR_JOURNAL_UNDECIDABLE}" "0003"
  harbor_lock_release "${FIX_ROOT}"
}

@test "recovery refuses a malformed entry with exit 2 before rewriting anything, in strict and lenient mode alike" {
  acquire
  fixture_entry "${FIX_ROOT}" 0001 file "${BATS_TEST_TMPDIR}/absent" created prepared '"absent"' '{"sha256":"ab","mode":"0644","owner":"root"}'
  fixture_entry "${FIX_ROOT}" 0002 file /x created prepared '"absent"' '"absent"'
  grep -v '"target"' "${FIX_ROOT}/journal/0002-file.json" >"${BATS_TEST_TMPDIR}/stripped"
  cat "${BATS_TEST_TMPDIR}/stripped" >"${FIX_ROOT}/journal/0002-file.json"
  before="$(cat "${FIX_ROOT}/journal/0002-file.json")"
  run harbor_journal_recover "${FIX_ROOT}"
  assert_equal "${status}" 2
  assert_output --partial 'journal.malformed'
  assert_output --partial '0002-file.json'
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" prepared
  assert_equal "$(cat "${FIX_ROOT}/journal/0002-file.json")" "${before}"
  run harbor_journal_recover "${FIX_ROOT}" 0001
  assert_equal "${status}" 2
  assert_output --partial 'journal.malformed'
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" prepared
  assert_equal "$(cat "${FIX_ROOT}/journal/0002-file.json")" "${before}"
  run ls -A "${FIX_ROOT}/journal"
  assert_line --index 0 0001-file.json
  assert_line --index 1 0002-file.json
  assert_equal "${#lines[@]}" 2
  harbor_lock_release "${FIX_ROOT}"
}

@test "recovery's validation pre-pass refuses every non-canonical shape before rewriting anything, in strict and lenient mode alike" {
  acquire
  fixture_entry "${FIX_ROOT}" 0001 file "${BATS_TEST_TMPDIR}/absent" created prepared '"absent"' '{"sha256":"ab","mode":"0644","owner":"root"}'
  good="${BATS_TEST_TMPDIR}/good"
  resolved="${BATS_TEST_TMPDIR}/resolved"
  bad="${FIX_ROOT}/journal/0002-file.json"
  harbor_journal_render file /x created prepared '"absent"' '"absent"' >"${good}"
  harbor_journal_render file /x created reverted '"absent"' '"absent"' operator 20260902T120000Z >"${resolved}"
  for shape in unknown-key extra-line trailing-junk missing-newline wrong-order missing-comma bad-brace partial-pair duplicate-pair empty-pair resolution-on-prepared; do
    case "${shape}" in
      unknown-key) sed 's/"ownership"/"owner"/' "${good}" >"${bad}" ;;
      extra-line) awk 'NR == 4 { print; print "  \"extra\": \"x\","; next } { print }' "${good}" >"${bad}" ;;
      trailing-junk) { cat "${good}"; printf 'junk\n'; } >"${bad}" ;;
      missing-newline) printf '%s' "$(cat "${good}")" >"${bad}" ;;
      wrong-order) sed -e '2{h;d;}' -e '3G' "${good}" >"${bad}" ;;
      missing-comma) sed '2s/,$//' "${good}" >"${bad}" ;;
      bad-brace) sed '1s/{/[/' "${good}" >"${bad}" ;;
      partial-pair) grep -v '"resolved_at"' "${resolved}" | sed '8s/,$//' >"${bad}" ;;
      duplicate-pair) sed 's/"resolved_at": "20260902T120000Z"/"resolved_by": "operator"/' "${resolved}" >"${bad}" ;;
      empty-pair) sed 's/"resolved_by": "operator"/"resolved_by": ""/' "${resolved}" >"${bad}" ;;
      resolution-on-prepared) harbor_journal_render file /x created prepared '"absent"' '"absent"' operator 20260902T120000Z >"${bad}" ;;
    esac
    before="$(cat "${bad}")"
    run harbor_journal_recover "${FIX_ROOT}"
    assert_equal "${status}" 2
    assert_output --partial 'journal.malformed'
    assert_output --partial '0002-file.json'
    assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" prepared
    assert_equal "$(cat "${bad}")" "${before}"
    run harbor_journal_recover "${FIX_ROOT}" 0001
    assert_equal "${status}" 2
    assert_output --partial 'journal.malformed'
    assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" prepared
    assert_equal "$(cat "${bad}")" "${before}"
  done
  run ls -A "${FIX_ROOT}/journal"
  assert_line --index 0 0001-file.json
  assert_line --index 1 0002-file.json
  assert_equal "${#lines[@]}" 2
  cp "${resolved}" "${bad}"
  harbor_journal_recover "${FIX_ROOT}"
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" reverted
  assert_equal "$(entry_phase "${FIX_ROOT}" 0002)" reverted
  assert_equal "$(cat "${bad}")" "$(cat "${resolved}")"
  harbor_lock_release "${FIX_ROOT}"
}
