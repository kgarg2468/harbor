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
  # The default pair is an ownership Harbor holds and the version it holds it at, so the
  # key order test below reads a version rather than the blank a pre-existing Tailscale
  # renders; the blanking is asserted where the vocabulary is.
  TSOWN=harbor-installed
  TSVER=1.86.2
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
    "${NODEJS}" "${TSOWN}" "${TSVER}" "${OPERATOR}" "${OPUID}" "${OPGID}" "${OPHOME}"
}

key_raw() {
  # key_raw KEY: the raw JSON value the record puts on KEY's line, the separating comma
  # stripped, so a string comes back quoted and a number bare.
  sed -n "s/^  \"${1}\": \(.*\)\$/\1/p" "${RECORD}" | sed 's/,$//'
}

seed_record() {
  # seed_record TAG TIMESTAMP: a record an earlier run of this row left behind.
  harbor_state_record_render "${1}" "${ENTRYPOINT}" "${LOCK_SHA}" "${FLAGS}" "${NODEJS}" \
    "${TSOWN}" "${TSVER}" "${OPERATOR}" "${OPUID}" "${OPGID}" "${OPHOME}" "${2}" >"${RECORD}"
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
  assert_line --index 7 "  \"tailscale_version\": \"${TSVER}\","
  assert_line --index 8 "  \"operator\": \"${OPERATOR}\","
  assert_line --index 9 "  \"operator_uid\": ${OPUID},"
  assert_line --index 10 "  \"operator_gid\": ${OPGID},"
  assert_line --index 11 "  \"operator_home\": \"${OPHOME}\","
  assert_line --index 12 "  \"timestamp\": \"${stamp}\""
  assert_line --index 13 '}'
  assert_equal "${#lines[@]}" 14
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

@test "the Tailscale ownership is one of the three design section 5.2 names, and the version is named only beside the two Harbor holds" {
  # All three words are accepted, and each decides for itself whether a version is named
  # beside it. A harbor-installed or an adopted Tailscale is one Harbor moved to the lock,
  # so the version it has is the record's to carry; a pre-existing one is neither, so the
  # key is blank however loudly the caller passes a version. Anything outside the three is
  # refused, because a record naming an ownership teardown cannot read is one Harbor would
  # have to refuse to act on later.
  local word
  for word in harbor-installed adopted; do
    rm -f "${RECORD}"
    TSOWN="${word}"
    run record
    assert_success
    assert_equal "$(key_raw tailscale_ownership)" "\"${word}\""
    assert_equal "$(key_raw tailscale_version)" "\"${TSVER}\""
  done
  rm -f "${RECORD}"
  TSOWN=pre-existing
  run record
  assert_success
  assert_equal "$(key_raw tailscale_ownership)" '"pre-existing"'
  assert_equal "$(key_raw tailscale_version)" '""'
  rm -f "${RECORD}"
  TSOWN=installed
  run record
  assert_equal "${status}" 3
  assert_output --partial 'state.tailscale_ownership'
  assert_output --partial 'installed'
  assert [ ! -e "${RECORD}" ]
}

@test "an ownership Harbor holds with no version is refused with nothing written" {
  # The version is the pin section 6.4's harbor upgrade compares the installed daemon
  # against, so an ownership that claims Harbor put the daemon there and names no version
  # is a record no later command could use. The refusal is raised where the ownership and
  # the uid and gid refusals are, before anything is rendered and before an entry exists.
  run record
  assert_success
  local word
  TSVER=""
  for word in harbor-installed adopted; do
    rm -f "${RECORD}"
    TSOWN="${word}"
    run record
    assert_equal "${status}" 3
    assert_output --partial 'state.tailscale_version'
    assert_output --partial "${word}"
    assert [ ! -e "${RECORD}" ]
  done
  # Neither refusal journaled anything: both run before the entry is created, so the
  # journal still holds only the entry the successful call above wrote.
  run ls -A "${FIX_ROOT}/journal"
  assert_output 0001-file.json
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

# Task 19 reads real observers against disposable binaries and package metadata.
installed_fixture() {
  . "${HARBOR_ROOT}/lib/versions.sh"
  . "${HARBOR_ROOT}/lib/runtime.sh"
  . "${HARBOR_ROOT}/lib/agents.sh"
  . "${HARBOR_ROOT}/lib/t3.sh"
  . "${HARBOR_ROOT}/lib/apt.sh"
  . "${HARBOR_ROOT}/lib/auth.sh"
  HOME="${FIX_HOME}"
  export HOME
  HARBOR_DEV=1
  HARBOR_AUTH_FIXTURE_RECORD="${RECORD}"
  HARBOR_STATE_OS_RELEASE="${BATS_TEST_TMPDIR}/os-release"
  printf 'VERSION_ID="26.04"\n' >"${HARBOR_STATE_OS_RELEASE}"
  harbor_versions_load "${HARBOR_ROOT}/versions.lock"
  local bin="${HOME}/.local/harbor/npm/bin" shims="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "${bin}" "${shims}" "${HOME}/.local/harbor/npm/node_modules/t3"
  printf '#!/bin/bash\nprintf "2.0.1 (Claude Code)\\n"\n' >"${bin}/claude"
  printf '#!/bin/bash\nprintf "codex-cli 0.1.2\\n"\n' >"${bin}/codex"
  printf '#!/bin/bash\nprintf "t3 v0.0.1\\n"\n' >"${bin}/t3"
  printf '{\n  "engines": {\n    "node": ">=24.0.0"\n  }\n}\n' >"${HOME}/.local/harbor/npm/node_modules/t3/package.json"
  cat >"${shims}/sh" <<'SH'
#!/bin/bash
[ "$*" = '-lc node --version' ] || exit 99
printf 'v24.20.0\n'
SH
  cat >"${shims}/dpkg-query" <<'SH'
#!/bin/bash
[ "$*" = '-s tailscale' ] || exit 99
printf 'Status: install ok installed\nVersion: 1.80.0\n'
SH
  chmod 0755 "${bin}/"* "${shims}/"*
  PATH="${shims}:${PATH}"
  export PATH
  seed_record v0.3.0 20200101T000000Z
}

@test "installed lock records all thirteen observed and method keys, with bare versions" {
  installed_fixture
  run harbor_state_installed_lock_render
  assert_success
  assert_equal "${#lines[@]}" 13
  local pair key
  for pair in ubuntu_release=26.04 tailscale_version=1.80.0 nodejs_version=24.20.0 claude_code_version=2.0.1 codex_version=0.1.2 t3_version=0.0.1 't3_engines_node=>=24.0.0'; do
    assert_line "${pair}"
  done
  for key in claude_code_install codex_install t3_install nodejs_install nodejs_sha256 tailscale_apt_channel; do
    assert_line "${key}=$(harbor_version_require "${key}")"
  done
  refute_output --regexp '=$'
  for key in claude_code_version codex_version t3_version nodejs_version tailscale_version; do
    assert_regex "$(printf '%s\n' "${output}" | sed -n "s/^${key}=//p")" '^[0-9]+\.[0-9]+\.[0-9]+$'
  done
}

@test "each unobservable installed key exits 2 and names its reading without replacing a lock" {
  installed_fixture
  local key target original
  for key in claude_code_version codex_version t3_version t3_engines_node nodejs_version tailscale_version ubuntu_release; do
    case "${key}" in
      claude_code_version) target="${HOME}/.local/harbor/npm/bin/claude" ;;
      codex_version) target="${HOME}/.local/harbor/npm/bin/codex" ;;
      t3_version) target="${HOME}/.local/harbor/npm/bin/t3" ;;
      t3_engines_node) target="${HOME}/.local/harbor/npm/node_modules/t3/package.json" ;;
      nodejs_version) target="${BATS_TEST_TMPDIR}/bin/sh" ;;
      tailscale_version) target="${BATS_TEST_TMPDIR}/bin/dpkg-query" ;;
      ubuntu_release) target="${HARBOR_STATE_OS_RELEASE}" ;;
    esac
    original="$(cat "${target}")"
    printf '' >"${target}"
    printf 'previous\n' >"${FIX_ROOT}/installed.lock"
    run harbor_state_installed_lock_write "${FIX_ROOT}/installed.lock"
    assert_equal "${status}" 2
    assert_output --partial "${key}"
    case "${key}" in
      claude_code_version | codex_version) assert_output --partial harbor_agents_installed_version ;;
      t3_version) assert_output --partial harbor_t3_installed_version ;;
      t3_engines_node) assert_output --partial harbor_t3_package_engines ;;
      nodejs_version) assert_output --partial 'node --version' ;;
      tailscale_version) assert_output --partial dpkg ;;
      ubuntu_release) assert_output --partial VERSION_ID ;;
    esac
    assert_equal "$(cat "${FIX_ROOT}/installed.lock")" previous
    printf '%s\n' "${original}" >"${target}"
  done
}

@test "every observed version key is a bare version, with no vendor decoration" {
  installed_fixture
  run harbor_state_installed_lock_write "${FIX_ROOT}/installed.lock"
  assert_success
  local key value
  # The shape tests/unit/lib/versions.bats anchors the locked versions to. Asserted
  # on the observed keys because each one is read back out of a vendor's own output:
  # claude prints "2.0.1 (Claude Code)", codex "codex-cli 0.1.2", t3 "t3 v0.0.1" and
  # node "v24.20.0", and a decoration that survived any of those readers would read
  # to PR 7 as drift against a lock that has none.
  for key in claude_code_version codex_version t3_version nodejs_version tailscale_version; do
    value="$(sed -n "s/^${key}=//p" "${FIX_ROOT}/installed.lock")"
    run printf '%s' "${value}"
    assert_output --regexp '^[0-9]+\.[0-9]+\.[0-9]+$'
  done
  # The login shell's v is stripped, and a decorated answer is refused rather than
  # recorded with its suffix intact.
  printf '#!/bin/bash\n[ "$*" = "-lc node --version" ] || exit 99\nprintf "v24.20.0-nightly\\n"\n' >"${BATS_TEST_TMPDIR}/bin/sh"
  chmod 0755 "${BATS_TEST_TMPDIR}/bin/sh"
  run harbor_state_installed_lock_render
  assert_equal "${status}" 2
  assert_output --partial nodejs_version
  assert_output --partial 'bare'
  # The v is required and not merely tolerated. node --version prefixes one, so an
  # answer without it did not come from the reading this key names, whatever its
  # shape -- and stripping it optionally would have widened the check in the same
  # motion that narrowed it against the suffix above.
  printf '#!/bin/bash\n[ "$*" = "-lc node --version" ] || exit 99\nprintf "24.20.0\\n"\n' >"${BATS_TEST_TMPDIR}/bin/sh"
  chmod 0755 "${BATS_TEST_TMPDIR}/bin/sh"
  run harbor_state_installed_lock_render
  assert_equal "${status}" 2
  assert_output --partial nodejs_version
  assert_output --partial 'prefixes a v'
}

@test "an ownership outside the design section 5.2 vocabulary is refused, not copied through" {
  installed_fixture
  TSOWN=bogus
  seed_record v0.3.0 20200101T000000Z
  run harbor_state_provision_record "${FIX_ROOT}/provision.json" 20260101T000000Z connect healthy installed-current logged-in logged-in
  # 3 rather than 2: the bootstrap record is a precondition of this command, and it
  # is the same refusal harbor_state_record makes on the same word.
  assert_equal "${status}" 3
  assert_output --partial state.tailscale_ownership
  assert_output --partial bogus
  assert [ ! -e "${FIX_ROOT}/provision.json" ]
}

@test "a record with the right content at the wrong mode is repaired and restamped" {
  installed_fixture
  seed_record v0.3.0 20200101T000000Z
  run harbor_state_provision_record "${FIX_ROOT}/provision.json" 20260101T000000Z connect healthy installed-current logged-in logged-in
  assert_success
  chmod 0644 "${FIX_ROOT}/provision.json"
  # The writer compares the whole observation, so this record is going to be rewritten
  # whatever its content says; the stamp has to move with it rather than be preserved
  # off a content-only comparison.
  run harbor_state_provision_record "${FIX_ROOT}/provision.json" 20260202T000000Z connect healthy installed-current logged-in logged-in
  assert_success
  assert_equal "$(harbor_stat_mode "${FIX_ROOT}/provision.json")" 0600
  assert_equal "$(harbor_state_record_timestamp "${FIX_ROOT}/provision.json")" 20260202T000000Z
}

@test "a record with the right content owned by another user is restamped" {
  installed_fixture
  seed_record v0.3.0 20200101T000000Z
  run harbor_state_provision_record "${FIX_ROOT}/provision.json" 20260101T000000Z connect healthy installed-current logged-in logged-in
  assert_success
  # The one field of the observation a unit test cannot arrange for real, since
  # changing a file's owner needs privilege this lane will never take. The shim
  # answers only the owner query harbor_stat_owner makes, only for this path, and
  # only while that path is still the inode seeded above -- every other stat call,
  # the mode reads among them, goes to the real one. Scoping it to the inode is what
  # keeps the shim honest across the rename: once the writer moves its own staged
  # file into place the record really is the operator's, and a shim still claiming
  # otherwise would fail the writer's post-rename verify for a reason the test does
  # not mean. The flag word is passed through so one shim serves -c on Linux and -f
  # on Darwin.
  # Branching on the platform rather than trying -f and falling back to -c: GNU stat's
  # -f is --file-system, so it does not fail on Linux, it succeeds and answers the file
  # system id. The fallback would never run, the seeded value would never match an
  # inode, and the shim would quietly stop lying -- a test that passes for the wrong
  # reason on the one runner that matters most. The shim body needs no branch because
  # harbor_stat_owner already passes the right flag as its first argument.
  local stale flag='-c'
  [ "$(harbor_os)" != Darwin ] || flag='-f'
  stale="$(/usr/bin/stat "${flag}" '%i' "${FIX_ROOT}/provision.json")"
  cat >"${BATS_TEST_TMPDIR}/bin/stat" <<SH
#!/bin/bash
if [ "\${2}" = '%U' ] || [ "\${2}" = '%Su' ]; then
  if [ "\${3}" = '${FIX_ROOT}/provision.json' ] \\
    && [ "\$(/usr/bin/stat "\${1}" %i "\${3}" 2>/dev/null)" = '${stale}' ]; then
    printf 'someone-else\n'
    exit 0
  fi
fi
exec /usr/bin/stat "\$@"
SH
  chmod 0755 "${BATS_TEST_TMPDIR}/bin/stat"
  # The fixture asserted before it is relied on. A shim that silently fails to lie
  # turns the rest of this test into a check that an unchanged record keeps its stamp,
  # which is a different test that already exists and would pass here.
  assert_equal "$(harbor_stat_owner "${FIX_ROOT}/provision.json")" someone-else
  assert_equal "$(harbor_stat_mode "${FIX_ROOT}/provision.json")" 0600
  run harbor_state_provision_record "${FIX_ROOT}/provision.json" 20260202T000000Z connect healthy installed-current logged-in logged-in
  assert_success
  assert_equal "$(entry_raw "${FIX_ROOT}" 0002 ownership)" '"modified"'
  rm -f "${BATS_TEST_TMPDIR}/bin/stat"
  assert_equal "$(harbor_state_record_timestamp "${FIX_ROOT}/provision.json")" 20260202T000000Z
}

@test "an unchanged provision record keeps its stamp; a changed one takes the new one" {
  installed_fixture
  seed_record v0.3.0 20200101T000000Z
  run harbor_state_provision_record "${FIX_ROOT}/provision.json" 20260101T000000Z connect healthy installed-current logged-in logged-in
  assert_success
  assert_equal "$(harbor_state_record_timestamp "${FIX_ROOT}/provision.json")" 20260101T000000Z
  # Same arguments, later stamp: nothing this record describes has changed, so the
  # record must not change either -- it renders identically against its own stamp,
  # is journaled observed, and keeps 20260101. This is the half that makes a rerun
  # on a healthy node rewrite nothing.
  run harbor_state_provision_record "${FIX_ROOT}/provision.json" 20260202T000000Z connect healthy installed-current logged-in logged-in
  assert_success
  assert_equal "$(harbor_state_record_timestamp "${FIX_ROOT}/provision.json")" 20260101T000000Z
  assert_equal "$(entry_raw "${FIX_ROOT}" 0002 ownership)" '"observed"'
  # One argument different, so the record is going to be rewritten anyway, and the
  # stamp must become the caller's. Preserving it here would date the new content to
  # the previous run, and spec section 5.7's finalization compares that stamp against
  # the newest journal .done sibling: a record rewritten after journal activity but
  # dated before it reads as the stale one, which is what the field exists to prevent.
  run harbor_state_provision_record "${FIX_ROOT}/provision.json" 20260303T000000Z connect needs_connect_login installed-current logged-in logged-in
  assert_success
  assert_equal "$(harbor_state_record_timestamp "${FIX_ROOT}/provision.json")" 20260303T000000Z
  assert_equal "$(entry_raw "${FIX_ROOT}" 0003 ownership)" '"modified"'
  run jq -e '.access_state == "needs_connect_login"' "${FIX_ROOT}/provision.json"
  assert_success
}

@test "installed and provision records are private journaled files for both Tailscale ownerships" {
  installed_fixture
  local ownership
  for ownership in pre-existing harbor-installed; do
    TSOWN="${ownership}"
    seed_record v0.3.0 20200101T000000Z
    run harbor_state_installed_lock_write "${FIX_ROOT}/installed.lock"
    assert_success
    run harbor_state_provision_record "${FIX_ROOT}/provision.json" 20260914T010203Z connect healthy installed-current logged-in unsupported
    assert_success
    assert_equal "$(harbor_stat_mode "${FIX_ROOT}/installed.lock")" 0600
    assert_equal "$(harbor_stat_mode "${FIX_ROOT}/provision.json")" 0600
    assert_equal "$(harbor_state_record_timestamp "${FIX_ROOT}/provision.json")" 20260914T010203Z
    run jq -e --arg ownership "${ownership}" '.tailscale_ownership == $ownership and .tailscale_version == "1.80.0" and .nodejs_version == "24.20.0" and .claude_code_version == "2.0.1" and .codex_version == "0.1.2" and .t3_version == "0.0.1" and .t3_engines_node == ">=24.0.0" and .ubuntu_release == "26.04" and .access_mode == "connect" and .access_state == "healthy" and .service_state == "installed-current" and .claude_auth == "logged-in" and .codex_auth == "unsupported"' "${FIX_ROOT}/provision.json"
    assert_success
  done
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" applied
  assert_equal "$(entry_phase "${FIX_ROOT}" 0002)" applied
  run find "${FIX_ROOT}" -name '.tmp.*'
  assert_output ''
}

@test "provision record missing bootstrap is a precondition naming sudo harbor bootstrap" {
  installed_fixture
  rm "${RECORD}"
  run harbor_state_provision_record "${FIX_ROOT}/provision.json" 20260914T010203Z connect healthy installed-current logged-in logged-in
  assert_equal "${status}" 3
  assert_output --partial 'sudo harbor bootstrap'
  assert [ ! -e "${FIX_ROOT}/provision.json" ]
}

@test "both state renames preserve the previous file and leave prepared on failure" {
  installed_fixture
  cat >"${BATS_TEST_TMPDIR}/bin/mv" <<'SH'
#!/bin/bash
exit 1
SH
  chmod 0755 "${BATS_TEST_TMPDIR}/bin/mv"
  printf 'old lock\n' >"${FIX_ROOT}/installed.lock"
  printf 'old record\n' >"${FIX_ROOT}/provision.json"
  run harbor_state_installed_lock_write "${FIX_ROOT}/installed.lock"
  assert_equal "${status}" 2
  assert_output --partial 'stays prepared'
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" prepared
  assert_equal "$(cat "${FIX_ROOT}/installed.lock")" 'old lock'
  run harbor_state_provision_record "${FIX_ROOT}/provision.json" 20260914T010203Z connect healthy installed-current logged-in logged-in
  assert_equal "${status}" 2
  assert_output --partial 'stays prepared'
  assert_equal "$(entry_phase "${FIX_ROOT}" 0002)" prepared
  assert_equal "$(cat "${FIX_ROOT}/provision.json")" 'old record'
}

@test "editing desired versions cannot change the installed snapshot or rerun ownership" {
  installed_fixture
  run harbor_state_installed_lock_write "${FIX_ROOT}/installed.lock"
  assert_success
  local before
  before="$(cat "${FIX_ROOT}/installed.lock")"
  sed -e 's/^claude_code_version=.*/claude_code_version=9.9.9/' \
    -e 's/^tailscale_version=.*/tailscale_version=9.9.9/' \
    -e 's/^nodejs_version=.*/nodejs_version=99.0.0/' \
    -e 's/^t3_engines_node=.*/t3_engines_node=>=99.0.0/' \
    "${HARBOR_ROOT}/versions.lock" >"${BATS_TEST_TMPDIR}/changed.lock"
  harbor_versions_load "${BATS_TEST_TMPDIR}/changed.lock"
  run harbor_state_installed_lock_write "${FIX_ROOT}/installed.lock"
  assert_success
  assert_equal "$(cat "${FIX_ROOT}/installed.lock")" "${before}"
  assert_equal "$(entry_raw "${FIX_ROOT}" 0002 ownership)" '"observed"'
  assert_equal "$(entry_phase "${FIX_ROOT}" 0002)" applied
}

@test "an absent runtime is unobservable rather than a literal absent version" {
  installed_fixture
  rm "${HOME}/.local/harbor/npm/bin/claude"
  run harbor_state_installed_lock_render
  assert_equal "${status}" 2
  assert_output --partial claude_code_version
  assert_output --partial harbor_agents_installed_version
  refute_output --partial 'claude_code_version=absent'
}
