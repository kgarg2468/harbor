#!/usr/bin/env bats
load '../test_helper'

setup() {
  # lib/versions.sh depends only on lib/log.sh, so this file sources the two
  # directly rather than through harbor_load_libs, which also loads the
  # libraries later tasks create.
  # shellcheck source=lib/log.sh
  . "${HARBOR_ROOT}/lib/log.sh"
  # shellcheck source=lib/versions.sh
  . "${HARBOR_ROOT}/lib/versions.sh"
  LOCK="${BATS_TEST_TMPDIR}/versions.lock"
}

write_lock() {
  # write_lock [KEY=VALUE ...]: every schema key empty, then the given overrides appended
  local k
  : >"${LOCK}"
  for k in ${HARBOR_VERSION_KEYS}; do
    case " ${*} " in
      *" ${k}="*) ;;
      *) printf '%s=\n' "${k}" >>"${LOCK}" ;;
    esac
  done
  for k in ${1+"$@"}; do
    printf '%s\n' "${k}" >>"${LOCK}"
  done
}

@test "the schema lists the thirteen keys of design section 2 in order" {
  assert_equal "${HARBOR_VERSION_KEYS}" "ubuntu_release tailscale_apt_channel tailscale_version nodejs_version nodejs_install nodejs_sha256 claude_code_version claude_code_install codex_version codex_install t3_version t3_install t3_engines_node"
}

@test "the shipped versions.lock parses with every key present and empty" {
  harbor_versions_load "$(harbor_versions_lock_path)"
  assert_equal "$(harbor_versions_lock_path)" "${HARBOR_ROOT}/versions.lock"
  for k in ${HARBOR_VERSION_KEYS}; do
    assert_equal "$(harbor_version_get "${k}")" ""
  done
}

@test "values are returned exactly and comments and blank lines are ignored" {
  write_lock "t3_version=1.2.3" "t3_engines_node=>=22.0.0"
  printf '\n# trailing comment\n' >>"${LOCK}"
  harbor_versions_load "${LOCK}"
  assert_equal "$(harbor_version_get t3_version)" "1.2.3"
  assert_equal "$(harbor_version_get t3_engines_node)" ">=22.0.0"
  assert_equal "$(harbor_version_require t3_version)" "1.2.3"
}

@test "an unset key is a precondition failure for harbor_version_require" {
  write_lock
  harbor_versions_load "${LOCK}"
  run harbor_version_require nodejs_version
  assert_equal "${status}" 3
  assert_output --partial 'versions.unset'
  assert_output --partial 'nodejs_version'
}

@test "a missing file, a non key=value line, an unknown key, a duplicate, whitespace, and a missing key each exit 3 with their id" {
  run harbor_versions_load "${BATS_TEST_TMPDIR}/absent"
  assert_equal "${status}" 3
  assert_output --partial 'versions.missing'

  write_lock
  printf 'not a pair\n' >>"${LOCK}"
  run harbor_versions_load "${LOCK}"
  assert_equal "${status}" 3
  assert_output --partial 'versions.syntax'

  write_lock "bogus_key=1"
  run harbor_versions_load "${LOCK}"
  assert_equal "${status}" 3
  assert_output --partial 'versions.unknown_key'

  write_lock
  printf 't3_version=1\n' >>"${LOCK}"
  run harbor_versions_load "${LOCK}"
  assert_equal "${status}" 3
  assert_output --partial 'versions.duplicate_key'

  write_lock "t3_version=1 2"
  run harbor_versions_load "${LOCK}"
  assert_equal "${status}" 3
  assert_output --partial 'versions.syntax'

  write_lock
  grep -v '^codex_install=' "${LOCK}" >"${LOCK}.short"
  run harbor_versions_load "${LOCK}.short"
  assert_equal "${status}" 3
  assert_output --partial 'versions.missing_key'
  assert_output --partial 'codex_install'
}

@test "harbor_version_get rejects a key outside the schema" {
  write_lock
  harbor_versions_load "${LOCK}"
  run harbor_version_get bogus_key
  assert_equal "${status}" 3
  assert_output --partial 'versions.unknown_key'
}
