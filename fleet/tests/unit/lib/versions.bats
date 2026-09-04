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

  # t3_engines_node is the one key whose value may hold an internal space: the
  # range is copied verbatim from the pinned package and a semver AND range is
  # invalid without its space. Both sides of that exception are asserted here.
  write_lock "t3_engines_node=^22.16 || ^23.11 || >=24.10"
  harbor_versions_load "${LOCK}"
  assert_equal "$(harbor_version_get t3_engines_node)" "^22.16 || ^23.11 || >=24.10"

  write_lock "t3_engines_node=>=22.16 <23"
  harbor_versions_load "${LOCK}"
  assert_equal "$(harbor_version_get t3_engines_node)" ">=22.16 <23"

  write_lock "t3_engines_node= >=22.16.0"
  run harbor_versions_load "${LOCK}"
  assert_equal "${status}" 3
  assert_output --partial 'versions.syntax'

  write_lock "t3_engines_node=>=22.16.0 "
  run harbor_versions_load "${LOCK}"
  assert_equal "${status}" 3
  assert_output --partial 'versions.syntax'

  write_lock "$(printf 't3_engines_node=>=22.16.0\t||\t^23.11')"
  run harbor_versions_load "${LOCK}"
  assert_equal "${status}" 3
  assert_output --partial 'versions.syntax'

  write_lock "$(printf 't3_engines_node=\t^22.16')"
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
  # Only range syntax: digits, dots, the separating spaces, the comparator
  # prefixes, and the || separator. No quote, dollar, backtick, backslash,
  # semicolon, ampersand, or bracket.
  run printf '%s' "${range}"
  assert_output --regexp '^[0-9.^~<>=| ]+$'
  # Every || alternative is one comparator on a numeric version prefix, with the
  # spaces the verbatim range carries around each separator. The trailing newline
  # matters: without it read skips the last alternative.
  printf '%s\n' "${range}" | sed 's/||/\
/g' | while IFS= read -r alt; do
    printf '%s' "${alt}" | grep -Eq '^ *(\^|~|>=|>|<=|<)?[0-9]+(\.[0-9]+){0,2} *$' || {
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

sat() {
  # sat VERSION RANGE: fails the calling test unless VERSION satisfies RANGE
  run harbor_semver_satisfies "${1}" "${2}"
  if [ "${status}" != 0 ]; then
    printf 'expected %s to satisfy "%s", got status %s: %s\n' "${1}" "${2}" "${status}" "${output}"
    return 1
  fi
}

unsat() {
  # unsat VERSION RANGE: fails the calling test unless VERSION is a clean miss,
  # which is status 1 and never the fail-closed 3
  run harbor_semver_satisfies "${1}" "${2}"
  if [ "${status}" != 1 ]; then
    printf 'expected %s not to satisfy "%s", got status %s: %s\n' "${1}" "${2}" "${status}" "${output}"
    return 1
  fi
}

@test "harbor_semver_satisfies decides the >= > <= and < comparators" {
  sat 24.10.0 '>=24.10.0'
  sat 24.20.0 '>=24.10.0'
  unsat 24.9.0 '>=24.10.0'

  sat 24.10.1 '>24.10.0'
  unsat 24.10.0 '>24.10.0'
  unsat 24.9.0 '>24.10.0'

  sat 24.10.0 '<=24.10.0'
  sat 24.9.0 '<=24.10.0'
  unsat 24.10.1 '<=24.10.0'

  sat 24.9.0 '<24.10.0'
  unsat 24.10.0 '<24.10.0'
  unsat 24.11.0 '<24.10.0'

  # the two-component shorthand the pinned range uses fills the patch with zero
  sat 24.10.0 '>=24.10'
  sat 25.0.0 '>=24.10'
  unsat 24.9.0 '>=24.10'
}

@test "harbor_semver_satisfies compares each component numerically and never lexically" {
  # lexically "24.20.0" sorts below "24.9.0" and "10.0.0" below "9.0.0"
  sat 24.20.0 '>=24.9.0'
  unsat 24.9.0 '>=24.20.0'
  unsat 24.9.0 '>=24.10'
  sat 10.0.0 '>9.0.0'
  unsat 9.0.0 '>=10.0.0'
  sat 1.2.100 '>1.2.99'
}

@test "harbor_semver_satisfies decides the caret range and its two-component shorthand" {
  sat 22.16.0 '^22.16.0'
  sat 22.16.1 '^22.16.0'
  sat 22.99.9 '^22.16.0'
  unsat 22.15.9 '^22.16.0'
  unsat 23.0.0 '^22.16.0'
  unsat 21.99.0 '^22.16.0'

  sat 22.16.0 '^22.16'
  sat 22.20.1 '^22.16'
  unsat 22.15.0 '^22.16'
  unsat 23.0.0 '^22.16'

  # a zero major narrows the caret to the minor, as node-semver does
  sat 0.2.3 '^0.2.1'
  unsat 0.2.0 '^0.2.1'
  unsat 0.3.0 '^0.2.1'
}

@test "harbor_semver_satisfies decides an AND range of two comparators separated by a space" {
  sat 22.16.0 '>=22.16.0 <23.0.0'
  sat 22.99.9 '>=22.16.0 <23.0.0'
  unsat 22.15.0 '>=22.16.0 <23.0.0'
  unsat 23.0.0 '>=22.16.0 <23.0.0'

  sat 24.10.0 '>=24.10 <25'
  sat 24.99.0 '>=24.10 <25'
  unsat 25.0.0 '>=24.10 <25'
  unsat 24.9.0 '>=24.10 <25'
}

@test "harbor_semver_satisfies decides the || alternation of the supported forms" {
  sat 22.16.0 '^22.16 || ^23.11 || >=24.10'
  sat 22.20.5 '^22.16 || ^23.11 || >=24.10'
  sat 23.11.0 '^22.16 || ^23.11 || >=24.10'
  sat 23.99.0 '^22.16 || ^23.11 || >=24.10'
  sat 24.10.0 '^22.16 || ^23.11 || >=24.10'
  sat 24.20.0 '^22.16 || ^23.11 || >=24.10'
  sat 25.0.0 '^22.16 || ^23.11 || >=24.10'

  unsat 21.0.0 '^22.16 || ^23.11 || >=24.10'
  unsat 22.15.0 '^22.16 || ^23.11 || >=24.10'
  unsat 23.10.0 '^22.16 || ^23.11 || >=24.10'
  unsat 24.9.0 '^22.16 || ^23.11 || >=24.10'

  # the separator carries no required spacing, and an alternative may be an AND range
  sat 24.20.0 '^22.16||^23.11||>=24.10'
  sat 22.20.0 '>=22.16.0 <23.0.0 || ^23.11'
  sat 23.11.4 '>=22.16.0 <23.0.0 || ^23.11'
  unsat 23.10.0 '>=22.16.0 <23.0.0 || ^23.11'
}

@test "an unsupported range form exits 3 with versions.semver_range and never a silent true" {
  for bad in '~22.16.0' '22.x' '*' 'latest' '' '>=' '>= 22.16.0 <23' '>=22.16.0 <23.0.0 <24.0.0' '>=22.16.0 ||' '|| >=22.16.0' '>=22.16.0.1' '>=v22.16.0' '=22.16.0' '22.16.0' '>=22.16.0-rc.1'; do
    run harbor_semver_satisfies 24.20.0 "${bad}"
    if [ "${status}" != 3 ]; then
      printf 'range "%s" gave status %s: %s\n' "${bad}" "${status}" "${output}"
      return 1
    fi
    assert_output --partial 'versions.semver_range'
  done
}

@test "a version that is not an exact major.minor.patch exits 3 with versions.semver_version" {
  for bad in '24.20' '24' 'v24.20.0' 'latest' '' '24.20.0.1' '24.20.x' '24.09.0' '24.20.0-rc.1' ' 24.20.0'; do
    run harbor_semver_satisfies "${bad}" '>=22.16.0'
    if [ "${status}" != 3 ]; then
      printf 'version "%s" gave status %s: %s\n' "${bad}" "${status}" "${output}"
      return 1
    fi
    assert_output --partial 'versions.semver_version'
  done
}

@test "the locked nodejs_version satisfies the locked t3_engines_node" {
  harbor_versions_load "$(harbor_versions_lock_path)"
  run harbor_semver_satisfies "$(harbor_version_get nodejs_version)" "$(harbor_version_get t3_engines_node)"
  assert_success
  run harbor_versions_require_node_range "$(harbor_versions_lock_path)"
  assert_success
}

@test "harbor_versions_require_node_range exits 3 naming both values when the locked Node.js misses the range" {
  write_lock "nodejs_version=22.15.0" "t3_engines_node=^22.16 || ^23.11 || >=24.10"
  run harbor_versions_require_node_range "${LOCK}"
  assert_equal "${status}" 3
  assert_output --partial 'versions.node_range'
  assert_output --partial '22.15.0'
  assert_output --partial '^22.16 || ^23.11 || >=24.10'
}

@test "harbor_versions_require_node_range needs both keys pinned" {
  write_lock "t3_engines_node=>=22.16.0"
  run harbor_versions_require_node_range "${LOCK}"
  assert_equal "${status}" 3
  assert_output --partial 'versions.unset'
  assert_output --partial 'nodejs_version'
}
