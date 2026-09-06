#!/usr/bin/env bats
load '../test_helper'

# The contract of the design section 5.2 State record row, key by key. The record is
# written inside this test's own state root and nowhere else: the state root is a
# parameter of the function under test, so nothing here touches /var/lib, and the one
# production path this file names at all is the one it asserts is only a default.

setup() {
  # lib/state.sh depends on lib/log.sh, lib/lock.sh, and lib/journal.sh. lib/entrypoint.sh
  # is sourced beside them because the record's first reader in production is its
  # harbor_entrypoint_record_tag, and a record no later command could read the release tag
  # out of would be a record that passes every assertion here and locks the node out.
  # shellcheck source=lib/log.sh
  . "${HARBOR_ROOT}/lib/log.sh"
  # shellcheck source=lib/lock.sh
  . "${HARBOR_ROOT}/lib/lock.sh"
  # shellcheck source=lib/journal.sh
  . "${HARBOR_ROOT}/lib/journal.sh"
  # shellcheck source=lib/entrypoint.sh
  . "${HARBOR_ROOT}/lib/entrypoint.sh"
  # shellcheck source=lib/state.sh
  . "${HARBOR_ROOT}/lib/state.sh"
  fixture_state_root
  HARBOR_PID="$$"
  RECORD="${FIX_ROOT}/bootstrap.json"
  # The values the rows of design section 5.2 hand the record. They are deliberately
  # unlike each other, so a row's value landing under another row's key is a failure.
  TAG=v0.3.0
  # The absolute entrypoint, at a fixture path: the record carries the path as a value and
  # this library never touches it, but no test of Harbor's names /usr/local/bin/harbor as
  # something it might write.
  ENTRYPOINT="${BATS_TEST_TMPDIR}/usr/local/bin/harbor"
  LOCK_SHA=3b1f9e2c4d5a6b7c8d9e0f1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e
  FLAGS='operator=harbor authorized-key-source=/home/ubuntu/.ssh/authorized_keys adopt-firewall=no adopt-tailscale=no allow-lan-ssh=no harden-sshd=no tailscale-ssh=no'
  NODEJS=22.16.0
  TSOWN=pre-existing
  OPERATOR=harbor
  OPUID=4242
  OPGID=4243
  OPHOME=/home/harbor
  harbor_lock_acquire "${FIX_ROOT}" operator
}

teardown() {
  harbor_lock_release "${FIX_ROOT}"
}

record() {
  # The row as node/bootstrap.sh calls it, with this test's values.
  harbor_state_record "${FIX_ROOT}" "${TAG}" "${ENTRYPOINT}" "${LOCK_SHA}" "${FLAGS}" \
    "${NODEJS}" "${TSOWN}" "${OPERATOR}" "${OPUID}" "${OPGID}" "${OPHOME}"
}

key_raw() {
  # key_raw KEY: the raw JSON value the record puts on KEY's line, the separating comma
  # stripped, so a string comes back quoted and a number bare.
  sed -n "s/^  \"${1}\": \(.*\)\$/\1/p" "${RECORD}" | sed 's/,$//'
}

seed_record() {
  # seed_record TAG TIMESTAMP: a record an earlier run of this row left behind.
  harbor_state_record_render "${1}" "${ENTRYPOINT}" "${LOCK_SHA}" "${FLAGS}" "${NODEJS}" \
    "${TSOWN}" "${OPERATOR}" "${OPUID}" "${OPGID}" "${OPHOME}" "${2}" >"${RECORD}"
  chmod 0644 "${RECORD}"
}

assert_entry() {
  # assert_entry SEQ OP TARGET OWNERSHIP PHASE PRE POST
  assert [ -f "${FIX_ROOT}/journal/${1}-${2}.json" ]
  assert_equal "$(entry_raw "${FIX_ROOT}" "${1}" target)" "\"${3}\""
  assert_equal "$(entry_raw "${FIX_ROOT}" "${1}" ownership)" "\"${4}\""
  assert_equal "$(entry_phase "${FIX_ROOT}" "${1}")" "${5}"
  assert_equal "$(entry_raw "${FIX_ROOT}" "${1}" pre_state)" "${6}"
  assert_equal "$(entry_raw "${FIX_ROOT}" "${1}" post_state)" "${7}"
}

@test "the record is mode 0644 and holds exactly the keys of the contract, in one fixed order" {
  run record
  assert_success
  assert_equal "$(harbor_stat_mode "${RECORD}")" 0644
  local stamp
  stamp="$(harbor_state_record_timestamp "${RECORD}")"
  run cat "${RECORD}"
  assert_line --index 0 '{'
  assert_line --index 1 "  \"release_tag\": \"${TAG}\","
  assert_line --index 2 "  \"entrypoint\": \"${ENTRYPOINT}\","
  assert_line --index 3 "  \"lock_sha256\": \"${LOCK_SHA}\","
  assert_line --index 4 "  \"flags\": \"${FLAGS}\","
  assert_line --index 5 "  \"nodejs_version\": \"${NODEJS}\","
  assert_line --index 6 "  \"tailscale_ownership\": \"${TSOWN}\","
  assert_line --index 7 "  \"operator\": \"${OPERATOR}\","
  assert_line --index 8 "  \"operator_uid\": ${OPUID},"
  assert_line --index 9 "  \"operator_gid\": ${OPGID},"
  assert_line --index 10 "  \"operator_home\": \"${OPHOME}\","
  assert_line --index 11 "  \"timestamp\": \"${stamp}\""
  assert_line --index 12 '}'
  assert_equal "${#lines[@]}" 13
  # The timestamp is the one format design section 5.7 compares lexicographically, UTC
  # at one-second resolution.
  assert_regex "${stamp}" '^[0-9]{8}T[0-9]{6}Z$'
}

@test "the record is written as one journaled file transaction and leaves no temporary file" {
  run record
  assert_success
  assert_entry 0001 file "${RECORD}" created applied '"absent"' "$(harbor_observe_file "${RECORD}")"
  run ls -A "${FIX_ROOT}"
  refute_output --partial '.tmp'
  run ls -A "${FIX_ROOT}/journal"
  assert_equal "${#lines[@]}" 1
}

@test "the release tag the record carries is the one harbor_entrypoint_record_tag reads back" {
  run record
  assert_success
  assert_equal "$(harbor_entrypoint_record_tag "${RECORD}")" "${TAG}"
  # And the key is release_tag alone: a record spelling it any other way names no tag.
  printf '{\n  "tag": "%s"\n}\n' "${TAG}" >"${RECORD}"
  run harbor_entrypoint_record_tag "${RECORD}"
  assert_failure
  assert_output ''
}

@test "the production record path is the design section 5.2 path and is only a default" {
  assert_equal "$(harbor_state_record_path /var/lib/harbor)" /var/lib/harbor/bootstrap.json
  assert_equal "$(harbor_state_record_path "${FIX_ROOT}")" "${RECORD}"
  run record
  assert_success
  # Nothing outside this test's own state root was written.
  run find "${BATS_TEST_TMPDIR}" -name bootstrap.json
  assert_output "${RECORD}"
}

@test "the uid and the gid are recorded as JSON numbers, and a non-numeric one is refused" {
  run record
  assert_success
  assert_equal "$(key_raw operator_uid)" "${OPUID}"
  assert_equal "$(key_raw operator_gid)" "${OPGID}"
  rm -f "${RECORD}"
  OPGID=""
  run record
  assert_equal "${status}" 3
  assert_output --partial 'state.number'
  assert_output --partial 'the operator gid'
  assert [ ! -e "${RECORD}" ]
  OPUID=4242x
  run record
  assert_equal "${status}" 3
  assert_output --partial 'the operator uid'
  # Neither refusal journaled anything: both run before the entry is created, so the
  # journal still holds only the entry the successful call above wrote.
  run ls -A "${FIX_ROOT}/journal"
  assert_output 0001-file.json
}

@test "the Tailscale ownership is one of the three design section 5.2 names, with no version key here" {
  # This release installs no Tailscale and adopts none, so pre-existing is what
  # node/bootstrap.sh records and no version key is written beside it. The other two
  # words are the vocabulary slice 3d makes reachable, and the version key is its own to
  # add: this library refuses anything outside the three and invents no version.
  local word
  for word in pre-existing harbor-installed adopted; do
    rm -f "${RECORD}"
    TSOWN="${word}"
    run record
    assert_success
    assert_equal "$(key_raw tailscale_ownership)" "\"${word}\""
    run cat "${RECORD}"
    refute_output --partial 'tailscale_version'
  done
  rm -f "${RECORD}"
  TSOWN=installed
  run record
  assert_equal "${status}" 3
  assert_output --partial 'state.tailscale_ownership'
  assert_output --partial 'installed'
  assert [ ! -e "${RECORD}" ]
}

@test "a rerun that finds the record identical journals observed, rewrites nothing, and keeps the timestamp" {
  run record
  assert_success
  local before stamp
  before="$(harbor_observe_file "${RECORD}")"
  stamp="$(harbor_state_record_timestamp "${RECORD}")"
  run record
  assert_success
  assert_equal "$(harbor_observe_file "${RECORD}")" "${before}"
  assert_equal "$(harbor_state_record_timestamp "${RECORD}")" "${stamp}"
  assert_entry 0002 file "${RECORD}" observed applied "${before}" "${before}"
}

@test "a record carrying another value is rewritten, journaled modified, and stamped afresh" {
  # The record an earlier lifecycle of this node left, at an earlier tag and an earlier
  # moment, which is the mismatch form of design section 5.2 ending.
  seed_record v0.2.0 20200101T000000Z
  local pre
  pre="$(harbor_observe_file "${RECORD}")"
  run record
  assert_success
  assert_equal "$(key_raw release_tag)" "\"${TAG}\""
  assert_entry 0001 file "${RECORD}" modified applied "${pre}" "$(harbor_observe_file "${RECORD}")"
  refute [ "$(harbor_state_record_timestamp "${RECORD}")" = 20200101T000000Z ]
  assert_equal "$(harbor_stat_mode "${RECORD}")" 0644
}

@test "a record whose mode is not 0644 is rewritten to 0644" {
  run record
  assert_success
  chmod 0600 "${RECORD}"
  local pre
  pre="$(harbor_observe_file "${RECORD}")"
  run record
  assert_success
  assert_equal "$(harbor_stat_mode "${RECORD}")" 0644
  assert_entry 0002 file "${RECORD}" modified applied "${pre}" "$(harbor_observe_file "${RECORD}")"
}

@test "a foreign non-regular file at the record path exits 3 untouched with nothing journaled" {
  mkdir "${RECORD}"
  run record
  assert_equal "${status}" 3
  assert_output --partial 'state.foreign'
  assert_output --partial "${RECORD}"
  assert [ -d "${RECORD}" ]
  run ls -A "${FIX_ROOT}/journal"
  assert_output ''
}

@test "a symlink at the record path exits 3 with its target left alone" {
  # harbor_observe_file reports a symlink as a symlink rather than as unobservable, so the
  # test above does not reach this case and it needs one of its own. Harbor writes the record
  # as an ordinary file, so a symlink here is something else's: renaming over it would remove
  # it and leave whatever it pointed at orphaned, unmentioned by any message.
  local target="${FIX_ROOT}/somebody-elses.json"
  printf 'not harbors\n' >"${target}"
  ln -s "${target}" "${RECORD}"
  run record
  assert_equal "${status}" 3
  assert_output --partial 'state.foreign'
  assert_output --partial "${RECORD}"
  assert [ -L "${RECORD}" ]
  assert_equal "$(cat "${target}")" 'not harbors'
  run ls -A "${FIX_ROOT}/journal"
  assert_output ''
}

@test "recovery decides a prepared record entry from the states harbor_observe_file renders" {
  # The crash window of design section 3.7: the rename onto the record happened or it did
  # not, and the applied write never did. The op is the file op, whose observer
  # lib/journal.sh already defines, so recovery decides without asking the operator and
  # what it decides against is a whole record either way, never half of one.
  run record
  assert_success
  local post
  post="$(harbor_observe_file "${RECORD}")"
  fixture_entry "${FIX_ROOT}" 0002 file "${RECORD}" created prepared '"absent"' "${post}"
  run harbor_journal_recover "${FIX_ROOT}"
  assert_success
  assert_equal "$(entry_phase "${FIX_ROOT}" 0002)" applied
  rm -f "${RECORD}"
  fixture_entry "${FIX_ROOT}" 0003 file "${RECORD}" created prepared '"absent"' "${post}"
  run harbor_journal_recover "${FIX_ROOT}"
  assert_success
  assert_equal "$(entry_phase "${FIX_ROOT}" 0003)" reverted
}

@test "the row takes every value as a parameter and refuses a call that is short of one" {
  run harbor_state_record "${FIX_ROOT}" "${TAG}"
  assert_equal "${status}" 3
  assert_output --partial 'usage'
  assert_output --partial 'harbor_state_record'
  assert [ ! -e "${RECORD}" ]
  run ls -A "${FIX_ROOT}/journal"
  assert_output ''
}
