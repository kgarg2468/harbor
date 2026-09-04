#!/usr/bin/env bats
load '../test_helper'

setup() {
  # lib/entrypoint.sh depends on lib/log.sh (harbor_die, harbor_log) and lib/lock.sh
  # (harbor_os), so this file sources those three rather than harbor_load_libs.
  # shellcheck source=lib/log.sh
  . "${HARBOR_ROOT}/lib/log.sh"
  # shellcheck source=lib/lock.sh
  . "${HARBOR_ROOT}/lib/lock.sh"
  # shellcheck source=lib/entrypoint.sh
  . "${HARBOR_ROOT}/lib/entrypoint.sh"
  TEST_USER="$(id -un)"
  TAG="v0.3.0"
  OTHER_TAG="v0.2.0"
  # The check judges the release directory and its contents, never the components
  # above the install root, so unlike the checkout rules this fixture can live under
  # BATS_TEST_TMPDIR. It is canonicalized because the resolved entrypoint path is
  # canonical: on macOS ${BATS_TEST_TMPDIR} is spelled through /var, which resolves to
  # /private/var.
  FIX_BASE="$(cd "${BATS_TEST_TMPDIR}" && pwd -P)"
  FIX_INSTALL="${FIX_BASE}/usr/local/lib/harbor"
  FIX_STATE="${FIX_BASE}/var/lib/harbor"
  mkdir -p "${FIX_INSTALL}" "${FIX_STATE}"
  build_release "${FIX_INSTALL}" "${TAG}"
  RELEASE_DIR="${FIX_INSTALL}/${TAG}"
  ARGV0="${RELEASE_DIR}/bin/harbor"
  RECORD="${FIX_STATE}/bootstrap.json"
  write_record "${TAG}"
  # Production requires /usr/local/lib/harbor and an owner of root. An unprivileged
  # unit test can create neither a root-owned tree nor anything under /usr/local, so
  # the fixture install root and the test user stand in for them. They are stand-ins,
  # never a relaxation: every path, ownership, and mode rule below still runs, and
  # lib/entrypoint.sh reads both variables only when the caller is not root, the same
  # gate under which HARBOR_DEV=1 already skips this check outright.
  HARBOR_ENTRYPOINT_INSTALL_ROOT="${FIX_INSTALL}"
  HARBOR_ENTRYPOINT_TRUSTED_OWNER="${TEST_USER}"
}

build_release() {
  # build_release INSTALL_ROOT TAG: a release directory with the installed modes of
  # design section 5.2, as harbor_release_stage leaves one.
  local rel="${1}/${2}"
  mkdir -p "${rel}/bin" "${rel}/lib" "${rel}/node"
  printf '#!/bin/bash\nexit 0\n' >"${rel}/bin/harbor"
  printf '# lib\n' >"${rel}/lib/log.sh"
  printf '# lib\n' >"${rel}/lib/journal.sh"
  printf '# node\n' >"${rel}/node/bootstrap.sh"
  printf 'tag=%s\ncommit=%s\n' "${2}" "0123456789abcdef0123456789abcdef01234567" >"${rel}/RELEASE"
  chmod 0755 "${rel}" "${rel}/bin" "${rel}/lib" "${rel}/node" "${rel}/bin/harbor"
  chmod 0644 "${rel}/RELEASE" "${rel}/lib/log.sh" "${rel}/lib/journal.sh" "${rel}/node/bootstrap.sh"
}

build_checkout() {
  # build_checkout DIR: a checkout entrypoint, the path an operator runs under
  # HARBOR_DEV=1 and the path every other command must refuse.
  local co="${1}"
  mkdir -p "${co}/bin"
  printf '#!/bin/bash\nexit 0\n' >"${co}/bin/harbor"
  chmod 0755 "${co}/bin/harbor"
}

write_record() {
  # write_record TAG: bootstrap.json as the last step of bootstrap writes it, mode
  # 0644 and world-readable, carrying the release tag this check compares against.
  printf '{\n  "release_tag": "%s",\n  "entrypoint": "/usr/local/bin/harbor",\n  "operator": "harbor"\n}\n' \
    "${1}" >"${RECORD}"
  chmod 0644 "${RECORD}"
}

snapshot() {
  # snapshot DIR: every path under DIR with its type, mode, owner, group, size, and
  # modification time, the link itself rather than its target.
  local p
  find "${1}" | sort | while IFS= read -r p; do
    case "$(uname -s)" in
      Linux) stat -c '%n %A %u %g %s %Y' -- "${p}" ;;
      Darwin) stat -f '%N %Sp %u %g %z %m' -- "${p}" ;;
    esac
  done
}

@test "an installed release with the installed modes and a matching record passes" {
  run harbor_entrypoint_check "${ARGV0}" "${RECORD}"
  assert_success
  assert_output ""
  run harbor_entrypoint_check "${ARGV0}" "${RECORD}" bootstrap
  assert_success
  run harbor_entrypoint_check "${ARGV0}" "${RECORD}" journal-resolve
  assert_success
}

@test "the executing path is resolved through symlinks, so the entrypoint link passes" {
  ln -s "${ARGV0}" "${FIX_BASE}/harbor"
  run harbor_entrypoint_check "${FIX_BASE}/harbor" "${RECORD}"
  assert_success
  ln -s harbor "${FIX_BASE}/harbor-2"
  run harbor_entrypoint_check "${FIX_BASE}/harbor-2" "${RECORD}"
  assert_success
}

@test "a group-writable directory in the release exits 3 naming it" {
  chmod 0775 "${RELEASE_DIR}/lib"
  run harbor_entrypoint_check "${ARGV0}" "${RECORD}"
  assert_equal "${status}" 3
  assert_output --partial 'entrypoint.mode'
  assert_output --partial "${RELEASE_DIR}/lib"
  assert_output --partial '0775'
}

@test "a group-writable release directory itself exits 3 naming it" {
  chmod 0775 "${RELEASE_DIR}"
  run harbor_entrypoint_check "${ARGV0}" "${RECORD}"
  assert_equal "${status}" 3
  assert_output --partial 'entrypoint.mode'
  assert_output --partial "${RELEASE_DIR}"
}

@test "a world-writable file in the release exits 3 naming it" {
  chmod 0666 "${RELEASE_DIR}/node/bootstrap.sh"
  run harbor_entrypoint_check "${ARGV0}" "${RECORD}"
  assert_equal "${status}" 3
  assert_output --partial 'entrypoint.mode'
  assert_output --partial "${RELEASE_DIR}/node/bootstrap.sh"
}

@test "a lib/*.sh marked executable exits 3 naming it, since lib files are sourced" {
  chmod 0755 "${RELEASE_DIR}/lib/journal.sh"
  run harbor_entrypoint_check "${ARGV0}" "${RECORD}"
  assert_equal "${status}" 3
  assert_output --partial 'entrypoint.mode'
  assert_output --partial "${RELEASE_DIR}/lib/journal.sh"
  assert_output --partial '0644'
}

@test "a bin/harbor that is not 0755 exits 3 naming it" {
  chmod 0644 "${ARGV0}"
  run harbor_entrypoint_check "${ARGV0}" "${RECORD}"
  assert_equal "${status}" 3
  assert_output --partial 'entrypoint.mode'
  assert_output --partial "${ARGV0}"
}

@test "a path in the release owned by another identity exits 3 naming it" {
  HARBOR_ENTRYPOINT_TRUSTED_OWNER="root"
  run harbor_entrypoint_check "${ARGV0}" "${RECORD}"
  assert_equal "${status}" 3
  assert_output --partial 'entrypoint.owner'
  assert_output --partial "${RELEASE_DIR}"
  assert_output --partial "${TEST_USER}"
}

@test "a symlink in the release that resolves to nothing exits 3 naming it" {
  ln -s ./missing.sh "${RELEASE_DIR}/lib/dangling.sh"
  run harbor_entrypoint_check "${ARGV0}" "${RECORD}"
  assert_equal "${status}" 3
  assert_output --partial 'entrypoint.unresolved'
  assert_output --partial "${RELEASE_DIR}/lib/dangling.sh"
}

@test "a missing RELEASE marker exits 3 naming it" {
  rm "${RELEASE_DIR}/RELEASE"
  run harbor_entrypoint_check "${ARGV0}" "${RECORD}"
  assert_equal "${status}" 3
  assert_output --partial 'entrypoint.release_marker'
  assert_output --partial "${RELEASE_DIR}/RELEASE"
}

@test "a RELEASE naming another tag than its own directory exits 3 naming both" {
  printf 'tag=%s\ncommit=%s\n' "${OTHER_TAG}" deadbeef >"${RELEASE_DIR}/RELEASE"
  run harbor_entrypoint_check "${ARGV0}" "${RECORD}"
  assert_equal "${status}" 3
  assert_output --partial 'entrypoint.release_tag'
  assert_output --partial "${OTHER_TAG}"
  assert_output --partial "${TAG}"
}

@test "an argv0 outside the install root exits 3 naming the installed entrypoint" {
  build_checkout "${FIX_BASE}/checkout"
  run harbor_entrypoint_check "${FIX_BASE}/checkout/bin/harbor" "${RECORD}"
  assert_equal "${status}" 3
  assert_output --partial 'entrypoint.location'
  assert_output --partial '/usr/local/bin/harbor'
  run harbor_entrypoint_check "${FIX_BASE}/checkout/bin/harbor" "${RECORD}" bootstrap
  assert_equal "${status}" 3
  assert_output --partial 'entrypoint.location'
}

@test "an argv0 nested deeper than <tag>/bin/harbor exits 3" {
  mkdir -p "${RELEASE_DIR}/vendor/bin"
  cp "${ARGV0}" "${RELEASE_DIR}/vendor/bin/harbor"
  run harbor_entrypoint_check "${RELEASE_DIR}/vendor/bin/harbor" "${RECORD}"
  assert_equal "${status}" 3
  assert_output --partial 'entrypoint.location'
}

@test "an argv0 whose parent is not named bin exits 3, and an absent one exits 3" {
  mkdir -p "${RELEASE_DIR}/sbin"
  cp "${ARGV0}" "${RELEASE_DIR}/sbin/harbor"
  run harbor_entrypoint_check "${RELEASE_DIR}/sbin/harbor" "${RECORD}"
  assert_equal "${status}" 3
  assert_output --partial 'entrypoint.layout'
  run harbor_entrypoint_check "${RELEASE_DIR}/bin/absent" "${RECORD}"
  assert_equal "${status}" 3
  assert_output --partial 'entrypoint.argv0'
  run harbor_entrypoint_check "" "${RECORD}"
  assert_equal "${status}" 3
  assert_output --partial 'entrypoint.argv0'
}

@test "the record-less form defers only for bootstrap and root journal resolve" {
  rm "${RECORD}"
  run harbor_entrypoint_check "${ARGV0}" "${RECORD}" bootstrap
  assert_success
  assert_output ""
  run harbor_entrypoint_check "${ARGV0}" "${RECORD}" journal-resolve
  assert_success
  run harbor_entrypoint_check "${ARGV0}" "${RECORD}"
  assert_equal "${status}" 3
  assert_output --partial 'entrypoint.record_absent'
  assert_output --partial "${RECORD}"
  assert_output --partial 'sudo harbor bootstrap'
}

@test "the record-less form still enforces every path, ownership, and mode rule" {
  rm "${RECORD}"
  chmod 0775 "${RELEASE_DIR}/lib"
  run harbor_entrypoint_check "${ARGV0}" "${RECORD}" bootstrap
  assert_equal "${status}" 3
  assert_output --partial 'entrypoint.mode'
  chmod 0755 "${RELEASE_DIR}/lib"
  HARBOR_ENTRYPOINT_TRUSTED_OWNER="root"
  run harbor_entrypoint_check "${ARGV0}" "${RECORD}" bootstrap
  assert_equal "${status}" 3
  assert_output --partial 'entrypoint.owner'
  HARBOR_ENTRYPOINT_TRUSTED_OWNER="${TEST_USER}"
  printf 'tag=%s\ncommit=%s\n' "${OTHER_TAG}" deadbeef >"${RELEASE_DIR}/RELEASE"
  run harbor_entrypoint_check "${ARGV0}" "${RECORD}" journal-resolve
  assert_equal "${status}" 3
  assert_output --partial 'entrypoint.release_tag'
}

@test "an absent record with no state root names the checkout bootstrap instead" {
  rm "${RECORD}"
  rmdir "${FIX_STATE}"
  run harbor_entrypoint_check "${ARGV0}" "${RECORD}"
  assert_equal "${status}" 3
  assert_output --partial 'entrypoint.record_absent'
  assert_output --partial './bin/harbor bootstrap'
}

@test "the mismatch form defers only for bootstrap and root journal resolve" {
  write_record "${OTHER_TAG}"
  run harbor_entrypoint_check "${ARGV0}" "${RECORD}" bootstrap
  assert_success
  assert_output ""
  run harbor_entrypoint_check "${ARGV0}" "${RECORD}" journal-resolve
  assert_success
  run harbor_entrypoint_check "${ARGV0}" "${RECORD}"
  assert_equal "${status}" 3
  assert_output --partial 'entrypoint.record_mismatch'
}

@test "the mismatch message names both causes, both tags, and both resumes" {
  write_record "${OTHER_TAG}"
  run harbor_entrypoint_check "${ARGV0}" "${RECORD}"
  assert_equal "${status}" 3
  assert_output --partial "${TAG}"
  assert_output --partial "${OTHER_TAG}"
  assert_output --partial 'upgrade --system'
  assert_output --partial 'teardown --level node'
  assert_output --partial 'reverted'
  assert_output --partial "--from"
}

@test "the mismatch form still enforces every path, ownership, and mode rule" {
  write_record "${OTHER_TAG}"
  chmod 0666 "${RELEASE_DIR}/node/bootstrap.sh"
  run harbor_entrypoint_check "${ARGV0}" "${RECORD}" bootstrap
  assert_equal "${status}" 3
  assert_output --partial 'entrypoint.mode'
  chmod 0644 "${RELEASE_DIR}/node/bootstrap.sh"
  rm "${RELEASE_DIR}/RELEASE"
  run harbor_entrypoint_check "${ARGV0}" "${RECORD}" journal-resolve
  assert_equal "${status}" 3
  assert_output --partial 'entrypoint.release_marker'
}

@test "a record that names no tag at all fails closed for every form" {
  printf '{\n  "operator": "harbor"\n}\n' >"${RECORD}"
  run harbor_entrypoint_check "${ARGV0}" "${RECORD}"
  assert_equal "${status}" 3
  assert_output --partial 'entrypoint.record_unreadable'
  run harbor_entrypoint_check "${ARGV0}" "${RECORD}" bootstrap
  assert_equal "${status}" 3
  assert_output --partial 'entrypoint.record_unreadable'
  run harbor_entrypoint_check "${ARGV0}" "${RECORD}" journal-resolve
  assert_equal "${status}" 3
  assert_output --partial 'entrypoint.record_unreadable'
}

@test "HARBOR_DEV=1 relaxes the check for a non-root operator command" {
  build_checkout "${FIX_BASE}/checkout"
  rm "${RECORD}"
  HARBOR_DEV=1
  run harbor_entrypoint_check "${FIX_BASE}/checkout/bin/harbor" "${RECORD}"
  assert_success
  assert_output ""
  chmod 0775 "${RELEASE_DIR}/lib"
  run harbor_entrypoint_check "${ARGV0}" "${RECORD}"
  assert_success
}

@test "HARBOR_DEV=1 and the fixture overrides are both ignored when the caller is root" {
  # An unprivileged test cannot run as root, and the one thing that decides this is
  # the caller's uid, so the uid is what the test stands in for. Shadowing id here
  # rather than reading a variable in lib/entrypoint.sh keeps the seam entirely
  # inside the test: production has no way to say it is not root.
  id() {
    case "${1}" in
      -u) printf '0\n' ;;
      *) command id "$@" ;;
    esac
  }
  HARBOR_DEV=1
  run harbor_entrypoint_check "${ARGV0}" "${RECORD}"
  assert_equal "${status}" 3
  # Root judges against the production install root, never the fixture one, so the
  # fixture release is refused for being outside /usr/local/lib/harbor.
  assert_output --partial 'entrypoint.location'
  assert_output --partial '/usr/local/lib/harbor'
  build_checkout "${FIX_BASE}/checkout"
  run harbor_entrypoint_check "${FIX_BASE}/checkout/bin/harbor" "${RECORD}" bootstrap
  assert_equal "${status}" 3
  assert_output --partial 'entrypoint.location'
}

@test "no call modifies anything under the fixture root" {
  local before after stale
  # Every fixture this test reads exists before the snapshot is taken, so nothing but
  # the calls under test could account for a difference.
  stale="${FIX_STATE}/stale.json"
  printf '{\n  "release_tag": "%s"\n}\n' "${OTHER_TAG}" >"${stale}"
  before="$(snapshot "${FIX_BASE}")"
  run harbor_entrypoint_check "${ARGV0}" "${RECORD}"
  assert_success
  run harbor_entrypoint_check "${ARGV0}" "${RECORD}" bootstrap
  assert_success
  HARBOR_ENTRYPOINT_TRUSTED_OWNER="root"
  run harbor_entrypoint_check "${ARGV0}" "${RECORD}"
  assert_equal "${status}" 3
  HARBOR_ENTRYPOINT_TRUSTED_OWNER="${TEST_USER}"
  run harbor_entrypoint_check "${ARGV0}" "${stale}"
  assert_equal "${status}" 3
  run harbor_entrypoint_check "${ARGV0}" "${FIX_STATE}/absent.json"
  assert_equal "${status}" 3
  after="$(snapshot "${FIX_BASE}")"
  assert_equal "${after}" "${before}"
}
