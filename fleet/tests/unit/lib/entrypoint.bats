#!/usr/bin/env bats
load '../test_helper'

setup() {
  # lib/entrypoint.sh depends on lib/log.sh (harbor_die, harbor_log), lib/lock.sh
  # (harbor_os, and the ownership assertion every journal write makes), and, for the
  # flag binding and the harbor-install proof below, lib/journal.sh, so this file
  # sources those four rather than harbor_load_libs.
  # shellcheck source=lib/log.sh
  . "${HARBOR_ROOT}/lib/log.sh"
  # shellcheck source=lib/lock.sh
  . "${HARBOR_ROOT}/lib/lock.sh"
  # shellcheck source=lib/journal.sh
  . "${HARBOR_ROOT}/lib/journal.sh"
  # shellcheck source=lib/entrypoint.sh
  . "${HARBOR_ROOT}/lib/entrypoint.sh"
  # The lock identity is derived from the top-level PID, as it is for every command.
  HARBOR_PID="$$"
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

@test "the recorded tag is read from release_tag and from no second spelling of it" {
  assert_equal "$(harbor_entrypoint_record_tag "${RECORD}")" "${TAG}"
  # lib/state.sh writes release_tag, so that is the only key this reader answers from: a
  # record spelling it any other way is not a record Harbor wrote, and reading it under a
  # second name would let a hand-written file decide which release every command trusts.
  printf '{\n  "tag": "%s"\n}\n' "${TAG}" >"${RECORD}"
  run harbor_entrypoint_record_tag "${RECORD}"
  assert_failure
  assert_output ''
  run harbor_entrypoint_check "${ARGV0}" "${RECORD}"
  assert_equal "${status}" 3
  assert_output --partial 'entrypoint.record_unreadable'
  # An absent record is still the record-less form and never an unreadable one.
  rm "${RECORD}"
  run harbor_entrypoint_record_tag "${RECORD}"
  assert_failure
  assert_output ''
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

# The flag binding of design section 5.2 and the harbor-install proof the two
# deferral forms owe. FIX_STATE stands in for /var/lib/harbor, as it already does
# for the record above; nothing here writes outside the test's own directory.

flags_fixture() {
  # The invoking administrator's authorized_keys, the source a bootstrap run
  # resolves when no --authorized-key-file is given.
  OPERATOR=harbor
  KEY_DIR="${FIX_BASE}/home/admin/.ssh"
  mkdir -p "${KEY_DIR}"
  printf 'ssh-ed25519 AAAAC3NzaC1lZDI1 admin@example\n' >"${KEY_DIR}/authorized_keys"
  KEY="${KEY_DIR}/authorized_keys"
}

other_admin_key() {
  # A second administrator's own key path, the one a recovery run resolves.
  OTHER_KEY_DIR="${FIX_BASE}/home/other/.ssh"
  mkdir -p "${OTHER_KEY_DIR}"
  printf 'ssh-ed25519 AAAAC3NzaC1lZDI1 other@example\n' >"${OTHER_KEY_DIR}/authorized_keys"
  OTHER_KEY="${OTHER_KEY_DIR}/authorized_keys"
}

state_journal() {
  # The root state root as bootstrap leaves it before the flag binding runs: the
  # journal directory exists and recovery has run over it.
  harbor_journal_init "${FIX_STATE}"
}

hold_lock() {
  harbor_lock_acquire "${FIX_STATE}" root
}

flags_set() {
  harbor_bootstrap_flags_normalize "${OPERATOR}" "${KEY}" ${1+"$@"}
}

all_flags() {
  printf '%s' '--tailscale-ssh --allow-lan-ssh --harden-sshd --adopt-firewall --adopt-tailscale'
}

flags_without() {
  # all_flags with the named one left out, so a set differing in exactly one flag
  local drop="${1}" f out="" sep=""
  for f in $(all_flags); do
    [ "${f}" != "${drop}" ] || continue
    out="${out}${sep}${f}"
    sep=" "
  done
  printf '%s' "${out}"
}

journal_entries() {
  ls -A "${FIX_STATE}/journal"
}

@test "the normalized set is identical however the flags were ordered" {
  flags_fixture
  local forward reverse
  forward="$(flags_set --tailscale-ssh --allow-lan-ssh --harden-sshd --adopt-firewall --adopt-tailscale)"
  reverse="$(flags_set --adopt-tailscale --adopt-firewall --harden-sshd --allow-lan-ssh --tailscale-ssh)"
  assert_equal "${reverse}" "${forward}"
  assert_equal "$(flags_set --harden-sshd --tailscale-ssh)" "$(flags_set --tailscale-ssh --harden-sshd)"
  # Whether a flag was given is the intent, so giving one twice is the same set.
  assert_equal "$(flags_set --harden-sshd --harden-sshd)" "$(flags_set --harden-sshd)"
  # Every flag of the set is rendered, given or not, in one fixed order.
  assert_equal "${forward}" \
    "operator=harbor authorized-key-source=${KEY} adopt-firewall=yes adopt-tailscale=yes allow-lan-ssh=yes harden-sshd=yes tailscale-ssh=yes"
  assert_equal "$(flags_set)" \
    "operator=harbor authorized-key-source=${KEY} adopt-firewall=no adopt-tailscale=no allow-lan-ssh=no harden-sshd=no tailscale-ssh=no"
}

@test "the normalized set is identical however the key path was spelled" {
  flags_fixture
  local canonical spelling
  canonical="$(flags_set --harden-sshd)"
  for spelling in "${KEY_DIR}/./authorized_keys" "${KEY_DIR}//authorized_keys" \
    "${KEY_DIR}/../.ssh/authorized_keys" "${FIX_BASE}/home/admin/../admin/.ssh/authorized_keys"; do
    assert_equal "$(harbor_bootstrap_flags_normalize "${OPERATOR}" "${spelling}" --harden-sshd)" "${canonical}"
  done
  # A spelling through a symlinked ancestor is the same path.
  ln -s "${KEY_DIR}" "${FIX_BASE}/keys"
  assert_equal "$(harbor_bootstrap_flags_normalize "${OPERATOR}" "${FIX_BASE}/keys/authorized_keys" --harden-sshd)" \
    "${canonical}"
  # A relative spelling is resolved against the working directory, never recorded.
  assert_equal "$(cd "${KEY_DIR}" && harbor_bootstrap_flags_normalize "${OPERATOR}" authorized_keys --harden-sshd)" \
    "${canonical}"
}

@test "the normalized set differs when any one flag, the operator, or the key path differs" {
  flags_fixture
  other_admin_key
  local base f
  base="$(flags_set --tailscale-ssh --allow-lan-ssh --harden-sshd --adopt-firewall --adopt-tailscale)"
  for f in $(all_flags); do
    refute [ "$(flags_set $(flags_without "${f}"))" = "${base}" ]
  done
  refute [ "$(harbor_bootstrap_flags_normalize other "${KEY}" $(all_flags))" = "${base}" ]
  refute [ "$(harbor_bootstrap_flags_normalize "${OPERATOR}" "${OTHER_KEY}" $(all_flags))" = "${base}" ]
}

@test "an unrecognized flag is refused rather than dropped from the intent" {
  flags_fixture
  run harbor_bootstrap_flags_normalize "${OPERATOR}" "${KEY}" --harden-sshd --adopt-everything
  assert_equal "${status}" 3
  assert_output --partial 'flags.unknown'
  assert_output --partial 'adopt-everything'
  run harbor_bootstrap_flags_normalize "" "${KEY}"
  assert_equal "${status}" 3
  run harbor_bootstrap_flags_normalize "${OPERATOR}" "${FIX_BASE}/absent-dir/authorized_keys"
  assert_equal "${status}" 3
  assert_output --partial 'flags.key_source'
}

@test "the bootstrap-flags observer answers that intent has no observable state" {
  flags_fixture
  state_journal
  # The op is dispatched by lib/journal.sh, so an entry of it is never unobservable
  # for want of an observer; what it answers is that intent has no artifact to read.
  assert_equal "$(harbor_journal_observe bootstrap-flags "$(flags_set)")" '"unobservable:intent"'
  # An entry written directly applied is never observed by recovery. One that is
  # prepared can only be a forged or hand-edited journal, and is undecidable rather
  # than guessed.
  fixture_entry "${FIX_STATE}" 0001 bootstrap-flags "$(flags_set)" observed prepared \
    '{"flags":"x"}' '{"flags":"x"}'
  run harbor_journal_recover "${FIX_STATE}"
  assert_equal "${status}" 2
  assert_output --partial 'journal.undecidable'
  assert_equal "$(entry_phase "${FIX_STATE}" 0001)" prepared
}

@test "the first run creates the bootstrap-flags entry applied, before any other entry and before any mutation" {
  flags_fixture
  state_journal
  hold_lock
  local flags before
  flags="$(flags_set --harden-sshd --adopt-firewall)"
  before="$(snapshot "${FIX_INSTALL}"; snapshot "${RECORD}"; snapshot "${KEY_DIR}")"
  run harbor_bootstrap_flags_bind "${FIX_STATE}" "${flags}"
  assert_success
  # It is the journal's first entry, so it precedes every mutation Harbor journals.
  assert_equal "$(journal_entries)" 0001-bootstrap-flags.json
  assert_equal "$(entry_phase "${FIX_STATE}" 0001)" applied
  assert_equal "$(entry_raw "${FIX_STATE}" 0001 ownership)" '"observed"'
  assert_equal "$(entry_raw "${FIX_STATE}" 0001 target)" "\"${flags}\""
  assert_equal "$(entry_raw "${FIX_STATE}" 0001 pre_state)" "$(entry_raw "${FIX_STATE}" 0001 post_state)"
  harbor_journal_validate "${FIX_STATE}/journal/0001-bootstrap-flags.json"
  # Nothing was mutated: not the release, not the record, not the key source.
  assert_equal "$(snapshot "${FIX_INSTALL}"; snapshot "${RECORD}"; snapshot "${KEY_DIR}")" "${before}"
  harbor_lock_release "${FIX_STATE}"
}

@test "a later run whose set equals the recorded set proceeds and writes no new entry" {
  flags_fixture
  state_journal
  hold_lock
  local flags entry before
  flags="$(flags_set --harden-sshd --adopt-firewall)"
  harbor_bootstrap_flags_bind "${FIX_STATE}" "${flags}"
  entry="${FIX_STATE}/journal/0001-bootstrap-flags.json"
  before="$(cat "${entry}")"
  # The same intent spelled another way is the same set, so a rerun proceeds.
  run harbor_bootstrap_flags_bind "${FIX_STATE}" \
    "$(harbor_bootstrap_flags_normalize "${OPERATOR}" "${KEY_DIR}/./authorized_keys" --adopt-firewall --harden-sshd)"
  assert_success
  assert_equal "$(journal_entries)" 0001-bootstrap-flags.json
  assert_equal "$(cat "${entry}")" "${before}"
  harbor_lock_release "${FIX_STATE}"
}

@test "each differing flag, the operator, and the key path exit 3 printing both values" {
  flags_fixture
  other_admin_key
  state_journal
  hold_lock
  local recorded f
  recorded="$(flags_set $(all_flags))"
  harbor_bootstrap_flags_bind "${FIX_STATE}" "${recorded}"
  for f in $(all_flags); do
    run harbor_bootstrap_flags_bind "${FIX_STATE}" "$(flags_set $(flags_without "${f}"))"
    assert_equal "${status}" 3
    assert_output --partial 'flags.mismatch'
    assert_output --partial " ${f}: this run no, recorded yes"
  done
  # The sixth differing input: the operator name.
  run harbor_bootstrap_flags_bind "${FIX_STATE}" "$(harbor_bootstrap_flags_normalize other "${KEY}" $(all_flags))"
  assert_equal "${status}" 3
  assert_output --partial 'flags.mismatch'
  assert_output --partial ' operator: this run other, recorded harbor'
  # The seventh: the authorized-key source path.
  run harbor_bootstrap_flags_bind "${FIX_STATE}" \
    "$(harbor_bootstrap_flags_normalize "${OPERATOR}" "${OTHER_KEY}" $(all_flags))"
  assert_equal "${status}" 3
  assert_output --partial "${OTHER_KEY}"
  assert_output --partial "${KEY}"
  # Nothing was written by any of the refusals.
  assert_equal "$(journal_entries)" 0001-bootstrap-flags.json
  assert_equal "$(entry_raw "${FIX_STATE}" 0001 target)" "\"${recorded}\""
  harbor_lock_release "${FIX_STATE}"
}

@test "a different administrator's key path exits 3 naming the recorded path" {
  flags_fixture
  other_admin_key
  state_journal
  hold_lock
  local before
  harbor_bootstrap_flags_bind "${FIX_STATE}" "$(flags_set --harden-sshd)"
  before="$(snapshot "${FIX_INSTALL}"; snapshot "${RECORD}")"
  run harbor_bootstrap_flags_bind "${FIX_STATE}" \
    "$(harbor_bootstrap_flags_normalize "${OPERATOR}" "${OTHER_KEY}" --harden-sshd)"
  assert_equal "${status}" 3
  assert_output --partial 'flags.mismatch'
  assert_output --partial " authorized-key-source: this run ${OTHER_KEY}, recorded ${KEY}"
  # The runbook's line for that case, with the recorded path to pass back.
  assert_output --partial "--authorized-key-file ${KEY}"
  assert_equal "$(snapshot "${FIX_INSTALL}"; snapshot "${RECORD}")" "${before}"
  harbor_lock_release "${FIX_STATE}"
}

release_observer() {
  # The harbor-install observer lives in lib/release.sh, the library that owns the op.
  # The proof reaches it through harbor_journal_observe's dispatch, exactly as recovery
  # does, so lib/entrypoint.sh keeps its dependencies (lib/log.sh, lib/lock.sh,
  # lib/journal.sh) and gains none on lib/release.sh; what must have loaded it is the
  # command that runs the proof, and this helper stands in for that command.
  # shellcheck source=lib/release.sh
  . "${HARBOR_ROOT}/lib/release.sh"
}

release_state() {
  # The state a harbor-install entry's post_state carries for RELEASE_DIR, rendered by
  # the same observer the proof reads the release back with, so a fixture entry vouches
  # for the release the way harbor_release_stage's does.
  harbor_journal_observe harbor-install "${RELEASE_DIR}"
}

proven_release() {
  # The journal of a node whose executing release Harbor installed: one applied
  # harbor-install entry naming it and recording the state it observes as now.
  state_journal
  fixture_entry "${FIX_STATE}" 0001 harbor-install "${RELEASE_DIR}" created applied \
    '"absent"' "$(release_state)"
}

@test "a release with no applied harbor-install entry exits 3 naming the reinstall" {
  release_observer
  state_journal
  run harbor_entrypoint_install_proof "${FIX_STATE}" "${RELEASE_DIR}"
  assert_equal "${status}" 3
  assert_output --partial 'entrypoint.install_proof'
  assert_output --partial "${RELEASE_DIR}"
  assert_output --partial './bin/harbor bootstrap'
  # An applied entry for another release directory proves nothing about this one.
  fixture_entry "${FIX_STATE}" 0001 harbor-install "${FIX_INSTALL}/${OTHER_TAG}" created applied \
    '"absent"' '{"tree_sha256":"aaaa"}'
  run harbor_entrypoint_install_proof "${FIX_STATE}" "${RELEASE_DIR}"
  assert_equal "${status}" 3
  assert_output --partial 'entrypoint.install_proof'
  # Nor does one that recovery could not decide.
  fixture_entry "${FIX_STATE}" 0002 harbor-install "${RELEASE_DIR}" created prepared \
    '"absent"' '{"tree_sha256":"bbbb"}'
  run harbor_entrypoint_install_proof "${FIX_STATE}" "${RELEASE_DIR}"
  assert_equal "${status}" 3
  assert_output --partial 'entrypoint.install_proof'
  # The applied entry for this release directory is the proof, and only while it
  # vouches for what is in the release now, so its post_state is the state the
  # release observes as rather than a stand-in hash.
  fixture_entry "${FIX_STATE}" 0003 harbor-install "${RELEASE_DIR}" created applied \
    '"absent"' "$(release_state)"
  run harbor_entrypoint_install_proof "${FIX_STATE}" "${RELEASE_DIR}"
  assert_success
}

@test "a reverted harbor-install entry for the executing release exits 3 naming the reinstall" {
  state_journal
  fixture_entry "${FIX_STATE}" 0001 harbor-install "${RELEASE_DIR}" created reverted \
    '"absent"' '{"tree_sha256":"bbbb"}'
  run harbor_entrypoint_install_proof "${FIX_STATE}" "${RELEASE_DIR}"
  assert_equal "${status}" 3
  assert_output --partial 'entrypoint.install_reverted'
  assert_output --partial "${RELEASE_DIR}"
  assert_output --partial './bin/harbor bootstrap'
  assert_output --partial 'teardown'
  # The proof is read-only: a refusal leaves the journal exactly as it was.
  assert_equal "$(entry_phase "${FIX_STATE}" 0001)" reverted
  assert_equal "$(journal_entries)" 0001-harbor-install.json
}

@test "the newest entry for the release is the journal's word about it, applied or reverted" {
  release_observer
  # The mid-teardown state of design section 5.7, and the one an older applied entry
  # must not talk over: the reverse walk marks the harbor-install entry reverted
  # before it removes anything, so the release still observes as exactly the tree hash
  # the earlier applied entry recorded. The hash matching is not the question; what the
  # journal last said about this release is, and it said unwound.
  proven_release
  fixture_entry "${FIX_STATE}" 0002 harbor-install "${RELEASE_DIR}" created reverted \
    '"absent"' "$(release_state)"
  assert_equal "$(entry_raw "${FIX_STATE}" 0001 post_state)" "$(release_state)"
  run harbor_entrypoint_install_proof "${FIX_STATE}" "${RELEASE_DIR}"
  assert_equal "${status}" 3
  assert_output --partial 'entrypoint.install_reverted'
  assert_output --partial "${RELEASE_DIR}"
  # A reinstall after a teardown is legitimate, so an applied entry newer than the
  # reverted one is the newest word and proves the release again.
  fixture_entry "${FIX_STATE}" 0003 harbor-install "${RELEASE_DIR}" created applied \
    '"absent"' "$(release_state)"
  run harbor_entrypoint_install_proof "${FIX_STATE}" "${RELEASE_DIR}"
  assert_success
  # An entry for another release is never a word about this one, whichever phase it
  # carries, so it neither proves nor takes away the proof above.
  fixture_entry "${FIX_STATE}" 0004 harbor-install "${FIX_INSTALL}/${OTHER_TAG}" created reverted \
    '"absent"' '{"tree_sha256":"aaaa"}'
  run harbor_entrypoint_install_proof "${FIX_STATE}" "${RELEASE_DIR}"
  assert_success
  # A newest entry that is neither applied nor reverted is a phase recovery would have
  # settled, so it proves nothing and refuses through the no-proof arm.
  fixture_entry "${FIX_STATE}" 0005 harbor-install "${RELEASE_DIR}" created prepared \
    '"absent"' "$(release_state)"
  run harbor_entrypoint_install_proof "${FIX_STATE}" "${RELEASE_DIR}"
  assert_equal "${status}" 3
  assert_output --partial 'entrypoint.install_proof'
  # None of it wrote anything: the proof reads the journal and never edits it.
  assert_equal "$(entry_phase "${FIX_STATE}" 0001)" applied
  assert_equal "$(entry_phase "${FIX_STATE}" 0002)" reverted
  assert_equal "$(entry_phase "${FIX_STATE}" 0003)" applied
  assert_equal "$(entry_phase "${FIX_STATE}" 0005)" prepared
}

@test "a release whose tree hash equals its applied harbor-install entry passes" {
  release_observer
  proven_release
  run harbor_entrypoint_install_proof "${FIX_STATE}" "${RELEASE_DIR}"
  assert_success
  assert_output ""
  # The proof writes nothing and touches no artifact, on the passing path as on the
  # refusing ones.
  assert_equal "$(journal_entries)" 0001-harbor-install.json
  assert_equal "$(entry_phase "${FIX_STATE}" 0001)" applied
}

@test "a release altered since its harbor-install entry was written exits 3 naming the reinstall" {
  release_observer
  proven_release
  local before
  before="$(snapshot "${FIX_STATE}/journal")"
  # A file's content changed. The entry still names this release directory, so only the
  # tree hash tells Harbor that what it installed is not what it would now execute.
  printf '# altered\n' >>"${RELEASE_DIR}/lib/log.sh"
  run harbor_entrypoint_install_proof "${FIX_STATE}" "${RELEASE_DIR}"
  assert_equal "${status}" 3
  assert_output --partial 'entrypoint.install_changed'
  assert_output --partial "${RELEASE_DIR}"
  assert_output --partial './bin/harbor bootstrap'
  # The same reinstall-and-clear-by-hand resume the other two refusals name.
  assert_output --partial 'by hand'
  printf '# lib\n' >"${RELEASE_DIR}/lib/log.sh"
  run harbor_entrypoint_install_proof "${FIX_STATE}" "${RELEASE_DIR}"
  assert_success
  # A file added. Nothing that was installed changed, and the release is still not the
  # tree the entry vouches for.
  printf '# extra\n' >"${RELEASE_DIR}/lib/extra.sh"
  chmod 0644 "${RELEASE_DIR}/lib/extra.sh"
  run harbor_entrypoint_install_proof "${FIX_STATE}" "${RELEASE_DIR}"
  assert_equal "${status}" 3
  assert_output --partial 'entrypoint.install_changed'
  rm -f "${RELEASE_DIR}/lib/extra.sh"
  run harbor_entrypoint_install_proof "${FIX_STATE}" "${RELEASE_DIR}"
  assert_success
  # A file's mode changed, with every byte of content the same.
  chmod 0600 "${RELEASE_DIR}/lib/journal.sh"
  run harbor_entrypoint_install_proof "${FIX_STATE}" "${RELEASE_DIR}"
  assert_equal "${status}" 3
  assert_output --partial 'entrypoint.install_changed'
  chmod 0644 "${RELEASE_DIR}/lib/journal.sh"
  run harbor_entrypoint_install_proof "${FIX_STATE}" "${RELEASE_DIR}"
  assert_success
  # None of the refusals wrote anything: the journal is byte for byte what it was.
  assert_equal "$(snapshot "${FIX_STATE}/journal")" "${before}"
  assert_equal "$(entry_phase "${FIX_STATE}" 0001)" applied
}

@test "an applied entry recording another tree hash proves nothing about this release" {
  release_observer
  state_journal
  # The entry names the executing release and is applied, so the target and the phase
  # are satisfied; what it records is another tree, which is the state a release
  # reinstalled by hand over an old entry, or a hand-edited journal, presents.
  fixture_entry "${FIX_STATE}" 0001 harbor-install "${RELEASE_DIR}" created applied \
    '"absent"' '{"tree_sha256":"0000000000000000000000000000000000000000000000000000000000000000"}'
  run harbor_entrypoint_install_proof "${FIX_STATE}" "${RELEASE_DIR}"
  assert_equal "${status}" 3
  assert_output --partial 'entrypoint.install_changed'
  assert_output --partial "${RELEASE_DIR}"
  assert_output --partial './bin/harbor bootstrap'
  assert_equal "$(entry_phase "${FIX_STATE}" 0001)" applied
  assert_equal "$(journal_entries)" 0001-harbor-install.json
}

@test "the proof refuses rather than passes when the harbor-install observer is not loaded" {
  release_observer
  proven_release
  # A process that never loaded lib/release.sh cannot read the release's current state:
  # the dispatch answers that the op is unobservable here, which is not a match and must
  # never be read as one, since the entry alone names the release without vouching for
  # what is in it now.
  unset -f harbor_observe_op_harbor_install
  assert_equal "$(harbor_journal_observe harbor-install "${RELEASE_DIR}")" '"unobservable:harbor-install"'
  run harbor_entrypoint_install_proof "${FIX_STATE}" "${RELEASE_DIR}"
  assert_equal "${status}" 3
  assert_output --partial 'entrypoint.install_observer'
  assert_output --partial "${RELEASE_DIR}"
  assert_output --partial 'lib/release.sh'
  assert_equal "$(entry_phase "${FIX_STATE}" 0001)" applied
}
