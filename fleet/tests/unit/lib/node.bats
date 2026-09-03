#!/usr/bin/env bats
load '../test_helper'

setup() {
  # lib/node.sh depends on lib/log.sh, lib/lock.sh, lib/versions.sh, and
  # lib/journal.sh, so this file sources those five rather than harbor_load_libs.
  # shellcheck source=lib/log.sh
  . "${HARBOR_ROOT}/lib/log.sh"
  # shellcheck source=lib/lock.sh
  . "${HARBOR_ROOT}/lib/lock.sh"
  # shellcheck source=lib/versions.sh
  . "${HARBOR_ROOT}/lib/versions.sh"
  # shellcheck source=lib/journal.sh
  . "${HARBOR_ROOT}/lib/journal.sh"
  # shellcheck source=lib/node.sh
  . "${HARBOR_ROOT}/lib/node.sh"
  fixture_state_root
  HARBOR_PID="$$"
  # The production paths /opt/harbor/node and /usr/local/bin become fixture paths.
  FIX_OPT="${BATS_TEST_TMPDIR}/opt/harbor"
  PREFIX="${FIX_OPT}/node"
  # The sibling an interrupted swap parks the displaced runtime at.
  PREVIOUS="${PREFIX}.harbor-previous"
  BINDIR="${BATS_TEST_TMPDIR}/usr/local/bin"
  mkdir -p "${BINDIR}"
  # curl and runuser resolve to the shim; tar, mktemp, and sha256 are real.
  PATH="${HARBOR_ROOT}/tests/shims/bin:${PATH}"
  HARBOR_SHIM_LOG="${BATS_TEST_TMPDIR}/shim.log"
  export HARBOR_SHIM_LOG
  FX="${BATS_TEST_TMPDIR}/fx"
  mkdir -p "${FX}"
  cp -R "${HARBOR_ROOT}/tests/fixtures/shims/runuser" "${FX}/runuser"
  HARBOR_SHIM_FIXTURES="${FX}"
  export HARBOR_SHIM_FIXTURES
  NODE_VERSION=22.14.0
  NODE_URL="https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.gz"
  LOCK="${BATS_TEST_TMPDIR}/versions.lock"
  build_tarball
  write_lock "${TARBALL_SHA}"
  harbor_versions_load "${LOCK}"
}

fake_node() {
  # fake_node PATH VERSION: an executable that answers --version like node does
  printf '#!/bin/sh\necho v%s\n' "${2}" >"${1}"
  chmod 0755 "${1}"
}

build_tarball() {
  # A fake Node.js release tarball laid out like the vendor's (one top-level
  # directory, bin/node, and npm, npx, corepack as symlinks into lib/), served
  # by the curl shim as the download body: the shim cats its .out fixture and
  # lib/node.sh redirects that stdout into the temporary download file.
  local top="node-v${NODE_VERSION}-linux-x64" src key n
  src="${BATS_TEST_TMPDIR}/src/${top}"
  mkdir -p "${src}/bin" "${src}/lib/node_modules/npm/bin"
  fake_node "${src}/bin/node" "${NODE_VERSION}"
  printf '#!/bin/sh\nexit 0\n' >"${src}/lib/node_modules/npm/bin/npm-cli.js"
  chmod 0755 "${src}/lib/node_modules/npm/bin/npm-cli.js"
  for n in npm npx corepack; do
    ln -s ../lib/node_modules/npm/bin/npm-cli.js "${src}/bin/${n}"
  done
  key="$(printf '%s' "-fsSL --proto =https --tlsv1.2 ${NODE_URL}" | tr ' /' '_%')"
  mkdir -p "${FX}/curl/healthy"
  TARBALL="${FX}/curl/healthy/${key}.out"
  COPYFILE_DISABLE=1 tar -czf "${TARBALL}" -C "${BATS_TEST_TMPDIR}/src" "${top}"
  TARBALL_SHA="$(harbor_sha256 "${TARBALL}")"
}

write_lock() {
  # write_lock SHA256 [VERSION]: every schema key empty except the Node.js triple.
  # VERSION overrides the locked nodejs_version only, leaving the tarball the URL
  # names alone, so a test can lock a version the tarball does not carry.
  local k want="${2:-${NODE_VERSION}}"
  : >"${LOCK}"
  for k in ${HARBOR_VERSION_KEYS}; do
    case "${k}" in
      nodejs_version) printf 'nodejs_version=%s\n' "${want}" ;;
      nodejs_install) printf 'nodejs_install=%s\n' "${NODE_URL}" ;;
      nodejs_sha256) printf 'nodejs_sha256=%s\n' "${1}" ;;
      *) printf '%s=\n' "${k}" ;;
    esac >>"${LOCK}"
  done
}

seed_prefix() {
  # seed_prefix VERSION: a previously installed runtime at PREFIX with a marker
  # file that a fresh extraction would not carry
  local n
  mkdir -p "${PREFIX}/bin" "${PREFIX}/lib"
  fake_node "${PREFIX}/bin/node" "${1}"
  for n in npm npx corepack; do
    printf '#!/bin/sh\nexit 0\n' >"${PREFIX}/bin/${n}"
    chmod 0755 "${PREFIX}/bin/${n}"
  done
  printf 'previous\n' >"${PREFIX}/lib/marker"
}

acquire() {
  harbor_lock_acquire "${FIX_ROOT}" operator
}

fake_mv_failing_swap() {
  # A mv on PATH that refuses exactly the move of the staged tree into PREFIX and
  # passes every other move, the restore of PREVIOUS included, to the real one.
  local bin="${BATS_TEST_TMPDIR}/fakebin"
  mkdir -p "${bin}"
  {
    printf '#!/bin/sh\n'
    printf 'last=""\n'
    printf 'for a in "$@"; do last="${a}"; done\n'
    printf 'if [ "${1}" != "%s" ] && [ "${last}" = "%s" ]; then\n' "${PREVIOUS}" "${PREFIX}"
    printf '  echo "mv: refused by the test" >&2\n'
    printf '  exit 1\n'
    printf 'fi\n'
    printf 'exec /bin/mv "$@"\n'
  } >"${bin}/mv"
  chmod 0755 "${bin}/mv"
  PATH="${bin}:${PATH}"
}

journal_names() {
  ls -A "${FIX_ROOT}/journal"
}

inode_of() {
  ls -lid "${1}" | awk '{ print $1 }'
}

tab="$(printf '\t')"

@test "installed_version reports absent without a runtime, the bare version with one, and dies 2 on a runtime that cannot answer" {
  assert_equal "$(harbor_node_installed_version "${PREFIX}")" absent
  mkdir -p "${PREFIX}/bin"
  assert_equal "$(harbor_node_installed_version "${PREFIX}")" absent
  seed_prefix 20.11.1
  assert_equal "$(harbor_node_installed_version "${PREFIX}")" 20.11.1
  printf '#!/bin/sh\nexit 1\n' >"${PREFIX}/bin/node"
  run harbor_node_installed_version "${PREFIX}"
  assert_equal "${status}" 2
  assert_output --partial 'node.unreadable'
  assert_output --partial "${PREFIX}/bin/node"
  printf '#!/bin/sh\necho hello\n' >"${PREFIX}/bin/node"
  run harbor_node_installed_version "${PREFIX}"
  assert_equal "${status}" 2
  assert_output --partial 'node.unreadable'
  assert [ ! -s "${HARBOR_SHIM_LOG}" ]
}

@test "the tar flag follows the tarball suffix and any other install form exits 3" {
  assert_equal "$(harbor_node_tar_flag https://nodejs.org/dist/v24.20.0/node-v24.20.0-linux-x64.tar.xz)" J
  assert_equal "$(harbor_node_tar_flag "${NODE_URL}")" z
  run harbor_node_tar_flag https://nodejs.org/dist/v24.20.0/node-v24.20.0-linux-x64.zip
  assert_equal "${status}" 3
  assert_output --partial 'node.install_format'
}

@test "a matching installed version is a no-op: no shim call, no journal entry, the prefix untouched" {
  seed_prefix "${NODE_VERSION}"
  acquire
  run harbor_node_install "${FIX_ROOT}" "${PREFIX}"
  assert_success
  assert [ ! -s "${HARBOR_SHIM_LOG}" ]
  assert_equal "$(journal_names)" ""
  assert_equal "$(cat "${PREFIX}/lib/marker")" previous
  assert_equal "$(ls -A "${FIX_OPT}")" node
  harbor_lock_release "${FIX_ROOT}"
}

@test "an absent runtime is downloaded through curl, checksum-verified, extracted, and journaled created with pre_state absent" {
  acquire
  run harbor_node_install "${FIX_ROOT}" "${PREFIX}"
  assert_success
  assert_equal "$(harbor_node_installed_version "${PREFIX}")" "${NODE_VERSION}"
  assert [ -L "${PREFIX}/bin/npm" ]
  assert [ -x "${PREFIX}/bin/corepack" ]
  assert_equal "$(harbor_stat_mode "${PREFIX}")" 0755
  assert_equal "$(cat "${HARBOR_SHIM_LOG}")" "curl${tab}-fsSL${tab}--proto${tab}=https${tab}--tlsv1.2${tab}${NODE_URL}"
  assert_equal "$(journal_names)" 0001-runtime-install.json
  assert_equal "$(entry_raw "${FIX_ROOT}" 0001 target)" "\"${PREFIX}\""
  assert_equal "$(entry_raw "${FIX_ROOT}" 0001 ownership)" '"created"'
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" applied
  assert_equal "$(entry_raw "${FIX_ROOT}" 0001 pre_state)" '"absent"'
  assert_equal "$(entry_raw "${FIX_ROOT}" 0001 post_state)" "\"${NODE_VERSION}\""
  harbor_journal_validate "${FIX_ROOT}/journal/0001-runtime-install.json"
  # No download directory or staging tree survives beside the prefix.
  assert_equal "$(ls -A "${FIX_OPT}")" node
  harbor_lock_release "${FIX_ROOT}"
}

@test "a different installed version is replaced and journaled modified with the prior version as pre_state" {
  seed_prefix 20.11.1
  acquire
  run harbor_node_install "${FIX_ROOT}" "${PREFIX}"
  assert_success
  assert_equal "$(harbor_node_installed_version "${PREFIX}")" "${NODE_VERSION}"
  assert [ ! -e "${PREFIX}/lib/marker" ]
  assert_equal "$(journal_names)" 0001-runtime-install.json
  assert_equal "$(entry_raw "${FIX_ROOT}" 0001 ownership)" '"modified"'
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" applied
  assert_equal "$(entry_raw "${FIX_ROOT}" 0001 pre_state)" '"20.11.1"'
  assert_equal "$(entry_raw "${FIX_ROOT}" 0001 post_state)" "\"${NODE_VERSION}\""
  assert_equal "$(ls -A "${FIX_OPT}")" node
  # A second run is now a no-op.
  : >"${HARBOR_SHIM_LOG}"
  run harbor_node_install "${FIX_ROOT}" "${PREFIX}"
  assert_success
  assert [ ! -s "${HARBOR_SHIM_LOG}" ]
  assert_equal "$(journal_names)" 0001-runtime-install.json
  harbor_lock_release "${FIX_ROOT}"
}

@test "a checksum mismatch exits 2 naming both digests and the lock, unpacks nothing, discards the download, and leaves the entry prepared" {
  bad="$(printf '%064d' 0)"
  write_lock "${bad}"
  harbor_versions_load "${LOCK}"
  seed_prefix 20.11.1
  acquire
  run harbor_node_install "${FIX_ROOT}" "${PREFIX}"
  assert_equal "${status}" 2
  assert_output --partial 'node.checksum'
  assert_output --partial "${bad}"
  assert_output --partial "${TARBALL_SHA}"
  assert_output --partial "${LOCK}"
  assert_equal "$(cat "${HARBOR_SHIM_LOG}")" "curl${tab}-fsSL${tab}--proto${tab}=https${tab}--tlsv1.2${tab}${NODE_URL}"
  # The previous runtime is untouched and nothing was unpacked anywhere.
  assert_equal "$(harbor_node_installed_version "${PREFIX}")" 20.11.1
  assert_equal "$(cat "${PREFIX}/lib/marker")" previous
  assert_equal "$(ls -A "${FIX_OPT}")" node
  assert_equal "$(find "${BATS_TEST_TMPDIR}/opt" -name '*.tar.gz' -o -name 'npm-cli.js')" ""
  assert_equal "$(journal_names)" 0001-runtime-install.json
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" prepared
  assert_equal "$(entry_raw "${FIX_ROOT}" 0001 ownership)" '"modified"'
  assert_equal "$(entry_raw "${FIX_ROOT}" 0001 pre_state)" '"20.11.1"'
  harbor_lock_release "${FIX_ROOT}"
}

@test "a non-https install source exits 3 before any entry, download, or mutation" {
  NODE_URL="http://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.gz"
  write_lock "${TARBALL_SHA}"
  harbor_versions_load "${LOCK}"
  acquire
  run harbor_node_install "${FIX_ROOT}" "${PREFIX}"
  assert_equal "${status}" 3
  assert_output --partial 'node.install_scheme'
  assert [ ! -s "${HARBOR_SHIM_LOG}" ]
  assert_equal "$(journal_names)" ""
  assert [ ! -e "${BATS_TEST_TMPDIR}/opt" ]
  harbor_lock_release "${FIX_ROOT}"
}

@test "symlinks: absent is created, correct is observed without being touched, pointing elsewhere is modified with the prior target" {
  seed_prefix "${NODE_VERSION}"
  ln -s "${PREFIX}/bin/npm" "${BINDIR}/npm"
  ln -s /usr/bin/npx "${BINDIR}/npx"
  ln -s /usr/bin/corepack "${BINDIR}/corepack"
  npm_inode="$(inode_of "${BINDIR}/npm")"
  acquire
  run harbor_node_link "${FIX_ROOT}" "${PREFIX}" "${BINDIR}"
  assert_success
  for n in node npm npx corepack; do
    assert_equal "$(readlink "${BINDIR}/${n}")" "${PREFIX}/bin/${n}"
  done
  assert_equal "$(inode_of "${BINDIR}/npm")" "${npm_inode}"
  run journal_names
  assert_line --index 0 0001-file.json
  assert_line --index 1 0002-file.json
  assert_line --index 2 0003-file.json
  assert_line --index 3 0004-file.json
  assert_equal "${#lines[@]}" 4
  assert_equal "$(entry_raw "${FIX_ROOT}" 0001 target)" "\"${BINDIR}/node\""
  assert_equal "$(entry_raw "${FIX_ROOT}" 0001 ownership)" '"created"'
  assert_equal "$(entry_raw "${FIX_ROOT}" 0001 pre_state)" '"absent"'
  assert_equal "$(entry_raw "${FIX_ROOT}" 0001 post_state)" "{\"symlink\":\"${PREFIX}/bin/node\"}"
  assert_equal "$(entry_raw "${FIX_ROOT}" 0002 target)" "\"${BINDIR}/npm\""
  assert_equal "$(entry_raw "${FIX_ROOT}" 0002 ownership)" '"observed"'
  assert_equal "$(entry_raw "${FIX_ROOT}" 0002 pre_state)" "{\"symlink\":\"${PREFIX}/bin/npm\"}"
  assert_equal "$(entry_raw "${FIX_ROOT}" 0002 post_state)" "{\"symlink\":\"${PREFIX}/bin/npm\"}"
  assert_equal "$(entry_raw "${FIX_ROOT}" 0003 target)" "\"${BINDIR}/npx\""
  assert_equal "$(entry_raw "${FIX_ROOT}" 0003 ownership)" '"modified"'
  assert_equal "$(entry_raw "${FIX_ROOT}" 0003 pre_state)" '{"symlink":"/usr/bin/npx"}'
  assert_equal "$(entry_raw "${FIX_ROOT}" 0003 post_state)" "{\"symlink\":\"${PREFIX}/bin/npx\"}"
  assert_equal "$(entry_raw "${FIX_ROOT}" 0004 target)" "\"${BINDIR}/corepack\""
  assert_equal "$(entry_raw "${FIX_ROOT}" 0004 ownership)" '"modified"'
  assert_equal "$(entry_raw "${FIX_ROOT}" 0004 pre_state)" '{"symlink":"/usr/bin/corepack"}'
  for s in 0001 0002 0003 0004; do
    assert_equal "$(entry_phase "${FIX_ROOT}" "${s}")" applied
    harbor_journal_validate "${FIX_ROOT}"/journal/"${s}"-file.json
  done
  # No temporary symlink is left behind and no shim was called.
  assert_equal "$(ls -A "${BINDIR}" | sort | tr '\n' ' ')" 'corepack node npm npx '
  assert [ ! -s "${HARBOR_SHIM_LOG}" ]
  # A second run observes all four and moves nothing.
  node_inode="$(inode_of "${BINDIR}/node")"
  run harbor_node_link "${FIX_ROOT}" "${PREFIX}" "${BINDIR}"
  assert_success
  assert_equal "$(inode_of "${BINDIR}/node")" "${node_inode}"
  run journal_names
  assert_equal "${#lines[@]}" 8
  for s in 0005 0006 0007 0008; do
    assert_equal "$(entry_raw "${FIX_ROOT}" "${s}" ownership)" '"observed"'
    assert_equal "$(entry_phase "${FIX_ROOT}" "${s}")" applied
  done
  harbor_lock_release "${FIX_ROOT}"
}

@test "recovery decides a prepared runtime-install entry: the pre version is reverted, the locked version is applied, another version is undecidable" {
  # The crash window of design section 3.7: the swap into place landed or did not,
  # and the applied write never happened. Recovery observes the prefix and decides.
  acquire
  fixture_entry "${FIX_ROOT}" 0001 runtime-install "${PREFIX}" created prepared '"absent"' "\"${NODE_VERSION}\""
  run harbor_journal_recover "${FIX_ROOT}"
  assert_success
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" reverted
  seed_prefix 20.11.1
  fixture_entry "${FIX_ROOT}" 0002 runtime-install "${PREFIX}" modified prepared '"20.11.1"' "\"${NODE_VERSION}\""
  run harbor_journal_recover "${FIX_ROOT}"
  assert_success
  assert_equal "$(entry_phase "${FIX_ROOT}" 0002)" reverted
  fake_node "${PREFIX}/bin/node" "${NODE_VERSION}"
  fixture_entry "${FIX_ROOT}" 0003 runtime-install "${PREFIX}" modified prepared '"20.11.1"' "\"${NODE_VERSION}\""
  run harbor_journal_recover "${FIX_ROOT}"
  assert_success
  assert_equal "$(entry_phase "${FIX_ROOT}" 0003)" applied
  fake_node "${PREFIX}/bin/node" 18.20.8
  fixture_entry "${FIX_ROOT}" 0004 runtime-install "${PREFIX}" modified prepared '"20.11.1"' "\"${NODE_VERSION}\""
  run --separate-stderr harbor_journal_recover "${FIX_ROOT}"
  assert_equal "${status}" 2
  assert_regex "${stderr}" 'journal entry 0004-runtime-install.json is undecidable:'
  assert_regex "${stderr}" 'observed:   "18\.20\.8"'
  assert_regex "${stderr}" 'journal.undecidable: prepared entries 0004 cannot be decided'
  assert_equal "$(entry_phase "${FIX_ROOT}" 0004)" prepared
  # Deciding an entry inspects only: no download, no reinstall, nothing new.
  assert [ ! -s "${HARBOR_SHIM_LOG}" ]
  assert_equal "$(cat "${PREFIX}/lib/marker")" previous
  assert_equal "$(ls -A "${FIX_OPT}")" node
  run journal_names
  assert_equal "${#lines[@]}" 4
  harbor_lock_release "${FIX_ROOT}"
}

@test "an interrupted swap observes as the parked runtime, recovers reverted, and the next install restores it before reinstalling" {
  # The crash window inside the swap: the displaced tree is parked at PREVIOUS and
  # nothing is at the prefix yet. That is the pre-install state with the tree one
  # path over, so the observer reports the parked version rather than "absent".
  seed_prefix 20.11.1
  mv "${PREFIX}" "${PREVIOUS}"
  assert_equal "$(harbor_observe_op_runtime_install "${PREFIX}")" '"20.11.1"'
  acquire
  fixture_entry "${FIX_ROOT}" 0001 runtime-install "${PREFIX}" modified prepared '"20.11.1"' "\"${NODE_VERSION}\""
  run harbor_journal_recover "${FIX_ROOT}"
  assert_success
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" reverted
  # Recovery inspected only: the tree is still parked and nothing was downloaded.
  assert_equal "$(cat "${PREVIOUS}/lib/marker")" previous
  assert [ ! -e "${PREFIX}" ]
  assert [ ! -s "${HARBOR_SHIM_LOG}" ]
  # The next install puts the tree back where that observation says it is, says so,
  # and then installs over it.
  HARBOR_VERBOSE=1 run harbor_node_install "${FIX_ROOT}" "${PREFIX}"
  assert_success
  assert_output --partial "${PREVIOUS}"
  assert_equal "$(harbor_node_installed_version "${PREFIX}")" "${NODE_VERSION}"
  assert [ ! -e "${PREFIX}/lib/marker" ]
  assert_equal "$(entry_raw "${FIX_ROOT}" 0002 ownership)" '"modified"'
  assert_equal "$(entry_raw "${FIX_ROOT}" 0002 pre_state)" '"20.11.1"'
  assert_equal "$(entry_raw "${FIX_ROOT}" 0002 post_state)" "\"${NODE_VERSION}\""
  assert_equal "$(entry_phase "${FIX_ROOT}" 0002)" applied
  # Neither the parked tree nor the staging directory outlives the applied write.
  assert_equal "$(ls -A "${FIX_OPT}")" node
  harbor_lock_release "${FIX_ROOT}"
}

@test "a swap into place that fails restores the previous runtime, leaves the entry prepared and decidable, and exits 2" {
  seed_prefix 20.11.1
  fake_mv_failing_swap
  acquire
  run harbor_node_install "${FIX_ROOT}" "${PREFIX}"
  assert_equal "${status}" 2
  assert_output --partial 'node.swap_in'
  assert_output --partial "${PREFIX}"
  assert_output --partial "${PREVIOUS}"
  # The previous runtime is back at the prefix, whole, and nothing stays parked.
  assert_equal "$(harbor_node_installed_version "${PREFIX}")" 20.11.1
  assert_equal "$(cat "${PREFIX}/lib/marker")" previous
  assert [ ! -e "${PREVIOUS}" ]
  assert_equal "$(ls -A "${FIX_OPT}")" node
  assert_equal "$(journal_names)" 0001-runtime-install.json
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" prepared
  # The prefix holds pre_state again, so recovery decides the entry instead of blocking.
  run harbor_journal_recover "${FIX_ROOT}"
  assert_success
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" reverted
  harbor_lock_release "${FIX_ROOT}"
}

@test "a runtime that verifies as another version keeps both the previous tree and the staged tree: nothing is deleted before the applied write" {
  # The lock names a version the tarball does not carry, so both moves land and the
  # verification at the prefix fails. The previous runtime must still exist.
  write_lock "${TARBALL_SHA}" 24.0.0
  harbor_versions_load "${LOCK}"
  seed_prefix 20.11.1
  acquire
  run harbor_node_install "${FIX_ROOT}" "${PREFIX}"
  assert_equal "${status}" 2
  assert_output --partial 'node.verify'
  assert_equal "$(journal_names)" 0001-runtime-install.json
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" prepared
  assert_equal "$(harbor_node_installed_version "${PREVIOUS}")" 20.11.1
  assert_equal "$(cat "${PREVIOUS}/lib/marker")" previous
  assert [ -n "$(find "${FIX_OPT}" -maxdepth 1 -name '.node-install.*')" ]
  harbor_lock_release "${FIX_ROOT}"
}

@test "a prepared link entry left by a crash after the rename is decidable: the link in place is applied, the others are reverted" {
  seed_prefix "${NODE_VERSION}"
  acquire
  ln -s "${PREFIX}/bin/node" "${BINDIR}/node"
  ln -s /usr/bin/npx "${BINDIR}/npx"
  fixture_entry "${FIX_ROOT}" 0001 file "${BINDIR}/node" created prepared '"absent"' "{\"symlink\":\"${PREFIX}/bin/node\"}"
  fixture_entry "${FIX_ROOT}" 0002 file "${BINDIR}/npm" created prepared '"absent"' "{\"symlink\":\"${PREFIX}/bin/npm\"}"
  fixture_entry "${FIX_ROOT}" 0003 file "${BINDIR}/npx" modified prepared '{"symlink":"/usr/bin/npx"}' "{\"symlink\":\"${PREFIX}/bin/npx\"}"
  run harbor_journal_recover "${FIX_ROOT}"
  assert_success
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" applied
  assert_equal "$(entry_phase "${FIX_ROOT}" 0002)" reverted
  assert_equal "$(entry_phase "${FIX_ROOT}" 0003)" reverted
  # Deciding an entry inspects only.
  assert_equal "$(readlink "${BINDIR}/node")" "${PREFIX}/bin/node"
  assert_equal "$(readlink "${BINDIR}/npx")" /usr/bin/npx
  assert_equal "$(ls -A "${BINDIR}" | sort | tr '\n' ' ')" 'node npx '
  harbor_lock_release "${FIX_ROOT}"
}

@test "a foreign file at a link path or a missing link target refuses the whole step before any entry or mutation" {
  seed_prefix "${NODE_VERSION}"
  printf 'not a symlink\n' >"${BINDIR}/npx"
  ln -s /usr/bin/node "${BINDIR}/node"
  acquire
  run harbor_node_link "${FIX_ROOT}" "${PREFIX}" "${BINDIR}"
  assert_equal "${status}" 3
  assert_output --partial 'node.link_foreign'
  assert_output --partial "${BINDIR}/npx"
  assert_equal "$(journal_names)" ""
  assert_equal "$(cat "${BINDIR}/npx")" 'not a symlink'
  assert_equal "$(readlink "${BINDIR}/node")" /usr/bin/node
  rm "${BINDIR}/npx"
  rm "${PREFIX}/bin/corepack"
  run harbor_node_link "${FIX_ROOT}" "${PREFIX}" "${BINDIR}"
  assert_equal "${status}" 2
  assert_output --partial 'node.link_target'
  assert_output --partial "${PREFIX}/bin/corepack"
  assert_equal "$(journal_names)" ""
  assert_equal "$(readlink "${BINDIR}/node")" /usr/bin/node
  assert_equal "$(ls -A "${BINDIR}")" node
  harbor_lock_release "${FIX_ROOT}"
}

@test "the operator probe reports a matching version through runuser and mutates nothing" {
  run harbor_node_operator_probe harbor
  assert_success
  assert_output --partial 'node.operator_probe'
  assert_output --partial "v${NODE_VERSION}"
  refute_output --partial 'precondition'
  assert_equal "$(cat "${HARBOR_SHIM_LOG}")" "runuser${tab}-u${tab}harbor${tab}--${tab}sh${tab}-lc${tab}node --version"
  assert_equal "$(journal_names)" ""
  assert [ ! -e "${PREFIX}" ]
  assert_equal "$(ls -A "${BINDIR}")" ""
}

@test "the operator probe reports a missing node as a precondition and never reinstalls" {
  HARBOR_SHIM_SCENARIO=node-missing run harbor_node_operator_probe harbor
  assert_equal "${status}" 3
  assert_output --partial 'node.operator_probe'
  assert_output --partial 'precondition'
  assert_output --partial 'not found'
  assert_output --partial 'exit 127'
  assert_equal "$(cat "${HARBOR_SHIM_LOG}")" "runuser${tab}-u${tab}harbor${tab}--${tab}sh${tab}-lc${tab}node --version"
  assert_equal "$(journal_names)" ""
  assert [ ! -e "${PREFIX}" ]
  assert_equal "$(ls -A "${BINDIR}")" ""
}

@test "the operator probe reports a different version as a precondition naming both versions and never reinstalls" {
  seed_prefix "${NODE_VERSION}"
  HARBOR_SHIM_SCENARIO=node-other run harbor_node_operator_probe harbor
  assert_equal "${status}" 3
  assert_output --partial 'node.operator_probe'
  assert_output --partial 'precondition'
  assert_output --partial 'v20.11.1'
  assert_output --partial "v${NODE_VERSION}"
  assert_equal "$(cat "${HARBOR_SHIM_LOG}")" "runuser${tab}-u${tab}harbor${tab}--${tab}sh${tab}-lc${tab}node --version"
  assert_equal "$(journal_names)" ""
  assert_equal "$(cat "${PREFIX}/lib/marker")" previous
  assert_equal "$(ls -A "${BINDIR}")" ""
}
