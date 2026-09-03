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

@test "the shipped versions.lock parses with the eight PR 3 keys pinned and the five PR 4 keys empty" {
  harbor_versions_load "$(harbor_versions_lock_path)"
  assert_equal "$(harbor_versions_lock_path)" "${HARBOR_ROOT}/versions.lock"
  for k in ubuntu_release tailscale_apt_channel tailscale_version nodejs_version nodejs_install nodejs_sha256 t3_version t3_engines_node; do
    run harbor_version_require "${k}"
    assert_success
    refute_output ''
  done
  for k in claude_code_version claude_code_install codex_version codex_install t3_install; do
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

@test "the pinned nodejs_version is a bare exact version and nodejs_install names that exact linux-x64 tarball" {
  harbor_versions_load "$(harbor_versions_lock_path)"
  run printf '%s' "$(harbor_version_get nodejs_version)"
  assert_output --regexp '^[0-9]+\.[0-9]+\.[0-9]+$'
  run printf '%s' "$(harbor_version_get nodejs_install)"
  assert_output "https://nodejs.org/dist/v$(harbor_version_get nodejs_version)/node-v$(harbor_version_get nodejs_version)-linux-x64.tar.xz"
}

@test "the pinned nodejs_sha256 is 64 lowercase hex characters" {
  harbor_versions_load "$(harbor_versions_lock_path)"
  run printf '%s' "$(harbor_version_get nodejs_sha256)"
  assert_output --regexp '^[0-9a-f]{64}$'
}

@test "the pinned t3_engines_node is a semver range of exact-prefix comparators joined by || and holds no shell metacharacter" {
  harbor_versions_load "$(harbor_versions_lock_path)"
  range="$(harbor_version_get t3_engines_node)"
  [ -n "${range}" ]
  # Only range syntax: digits, dots, the comparator prefixes, and the || separator.
  # No quote, dollar, backtick, backslash, semicolon, ampersand, or bracket.
  run printf '%s' "${range}"
  assert_output --regexp '^[0-9.^~<>=|]+$'
  # Every || alternative is one comparator on a numeric version prefix. The
  # trailing newline matters: without it read skips the last alternative.
  printf '%s\n' "${range}" | sed 's/||/\
/g' | while IFS= read -r alt; do
    printf '%s' "${alt}" | grep -Eq '^(\^|~|>=|>|<=|<)?[0-9]+(\.[0-9]+){0,2}$' || {
      printf 'not a comparator: %s\n' "${alt}"
      exit 1
    }
  done
}

@test "the pinned t3_version and tailscale_version are bare exact versions and ubuntu_release is the two-part LTS number" {
  harbor_versions_load "$(harbor_versions_lock_path)"
  run printf '%s' "$(harbor_version_get t3_version)"
  assert_output --regexp '^[0-9]+\.[0-9]+\.[0-9]+$'
  run printf '%s' "$(harbor_version_get tailscale_version)"
  assert_output --regexp '^[0-9]+\.[0-9]+\.[0-9]+$'
  run printf '%s' "$(harbor_version_get ubuntu_release)"
  assert_output --regexp '^[0-9]{2}\.[0-9]{2}$'
  run printf '%s' "$(harbor_version_get tailscale_apt_channel)"
  assert_output 'stable/ubuntu/noble'
}
