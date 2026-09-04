#!/usr/bin/env bats
load '../test_helper'

setup() {
  # lib/release.sh depends on lib/log.sh, lib/lock.sh, and lib/journal.sh, so this
  # file sources those four rather than harbor_load_libs. It also calls harbor_git,
  # which lib/checkout.sh defines in production; this file stubs that one seam so
  # the release tests stand alone and never source lib/checkout.sh.
  # shellcheck source=lib/log.sh
  . "${HARBOR_ROOT}/lib/log.sh"
  # shellcheck source=lib/lock.sh
  . "${HARBOR_ROOT}/lib/lock.sh"
  # shellcheck source=lib/journal.sh
  . "${HARBOR_ROOT}/lib/journal.sh"
  # shellcheck source=lib/release.sh
  . "${HARBOR_ROOT}/lib/release.sh"
  fixture_state_root
  HARBOR_PID="$$"
  # The production /usr/local/lib/harbor becomes a fixture directory, so nothing
  # here writes outside the test's own temporary directory.
  LIBDIR="${BATS_TEST_TMPDIR}/usr/local/lib/harbor"
  mkdir -p "${LIBDIR}"
  # The production /usr/local/bin becomes a fixture directory for the same reason,
  # so the entrypoint symlink tests never write at the real entrypoint path.
  BINDIR="${BATS_TEST_TMPDIR}/usr/local/bin"
  mkdir -p "${BINDIR}"
  LINK="${BINDIR}/harbor"
  CHECKOUT="${BATS_TEST_TMPDIR}/checkout"
  GIT_LOG="${BATS_TEST_TMPDIR}/git.log"
  : >"${GIT_LOG}"
  HARBOR_STUB_TAR=""
  TAG=v0.1.0
  DEST="${LIBDIR}/${TAG}"
}

harbor_git() {
  # The seam Task 7 fills in: every Git invocation lib/release.sh makes goes through
  # harbor_git <checkout> <git args...>. The stub records the argument vector and
  # then either replays a hand-built tar, for the archive of a tree carrying modes
  # Git itself cannot record, or runs the real Git in the fixture repository.
  local checkout="${1}"
  shift
  printf '%s\n' "$*" >>"${GIT_LOG}"
  if [ -n "${HARBOR_STUB_TAR:-}" ]; then
    case "${1}" in
      archive)
        cat "${HARBOR_STUB_TAR}"
        return 0
        ;;
      rev-parse)
        printf '%s\n' "${STUB_COMMIT}"
        return 0
        ;;
    esac
  fi
  git -C "${checkout}" "$@"
}

gitc() {
  git -C "${CHECKOUT}" -c user.name=Harbor -c user.email=harbor@example.com \
    -c commit.gpgsign=false -c init.defaultBranch=main -c core.hooksPath=/dev/null "$@"
}

git_repo() {
  # A disposable repository whose tag carries bin/harbor and a second executable
  # file, so the archived modes are not already the installed contract.
  mkdir -p "${CHECKOUT}"
  gitc init -q
  mkdir -p "${CHECKOUT}/bin" "${CHECKOUT}/lib" "${CHECKOUT}/tools"
  printf '#!/bin/bash\necho harbor\n' >"${CHECKOUT}/bin/harbor"
  printf '# committed\n' >"${CHECKOUT}/lib/log.sh"
  printf '#!/bin/sh\nexit 0\n' >"${CHECKOUT}/tools/hook.sh"
  printf 'committed readme\n' >"${CHECKOUT}/README.md"
  chmod 0755 "${CHECKOUT}/bin/harbor" "${CHECKOUT}/tools/hook.sh"
  chmod 0644 "${CHECKOUT}/lib/log.sh" "${CHECKOUT}/README.md"
  gitc add -A
  gitc commit -q -m 'the release commit'
  gitc tag "${TAG}"
}

dirty_worktree() {
  # Everything a work tree can carry that the tagged tree does not: an edit to a
  # tracked file, an untracked file, and a file added to the index but not committed.
  printf '# uncommitted edit\n' >"${CHECKOUT}/lib/log.sh"
  printf 'untracked\n' >"${CHECKOUT}/UNTRACKED.md"
  printf 'staged\n' >"${CHECKOUT}/STAGED.md"
  gitc add STAGED.md
}

odd_mode_tar() {
  # An archive carrying the modes the installed contract has to override, including
  # a group-writable file, an executable that is not bin/harbor, a world-writable
  # file, a private directory, a setgid directory, and a bin/harbor that is not
  # executable at all. Git records only 0644 and 0755, so this stands in for the
  # archive of a tag whose blobs came from anywhere else.
  local src="${BATS_TEST_TMPDIR}/odd"
  mkdir -p "${src}/bin" "${src}/lib" "${src}/tools"
  printf '#!/bin/bash\necho harbor\n' >"${src}/bin/harbor"
  printf '# lib\n' >"${src}/lib/log.sh"
  printf '#!/bin/sh\nexit 0\n' >"${src}/tools/hook.sh"
  printf 'readme\n' >"${src}/README.md"
  chmod 0600 "${src}/bin/harbor"
  chmod 0664 "${src}/lib/log.sh"
  chmod 0777 "${src}/tools/hook.sh"
  chmod 0666 "${src}/README.md"
  chmod 0700 "${src}/lib"
  chmod 2775 "${src}/tools"
  chmod 0775 "${src}/bin"
  STUB_COMMIT=0123456789abcdef0123456789abcdef01234567
  HARBOR_STUB_TAR="${BATS_TEST_TMPDIR}/odd.tar"
  (cd "${src}" && COPYFILE_DISABLE=1 tar -cf "${HARBOR_STUB_TAR}" .)
}

make_tree() {
  # make_tree DIR: two calls make two trees of identical content, path, and mode
  mkdir -p "${1}/bin" "${1}/lib"
  printf '#!/bin/bash\necho harbor\n' >"${1}/bin/harbor"
  printf '# lib\n' >"${1}/lib/log.sh"
  printf 'readme\n' >"${1}/README.md"
  chmod 0755 "${1}" "${1}/bin" "${1}/lib" "${1}/bin/harbor"
  chmod 0644 "${1}/lib/log.sh" "${1}/README.md"
}

acquire() {
  harbor_lock_acquire "${FIX_ROOT}" operator
}

journal_names() {
  ls -A "${FIX_ROOT}/journal"
}

inode_of() {
  ls -lid "${1}" | awk '{ print $1 }'
}

@test "the tree hash is the same for two identical trees whatever their timestamps" {
  make_tree "${BATS_TEST_TMPDIR}/a"
  make_tree "${BATS_TEST_TMPDIR}/b"
  find "${BATS_TEST_TMPDIR}/b" -exec touch -t 200001010101 {} +
  run harbor_release_tree_hash "${BATS_TEST_TMPDIR}/a"
  assert_success
  assert_regex "${output}" '^[0-9a-f]{64}$'
  assert_equal "$(harbor_release_tree_hash "${BATS_TEST_TMPDIR}/a")" \
    "$(harbor_release_tree_hash "${BATS_TEST_TMPDIR}/b")"
}

@test "the tree hash changes with content, with a path, and with a mode" {
  make_tree "${BATS_TEST_TMPDIR}/a"
  base="$(harbor_release_tree_hash "${BATS_TEST_TMPDIR}/a")"
  printf '# edited\n' >"${BATS_TEST_TMPDIR}/a/lib/log.sh"
  refute [ "$(harbor_release_tree_hash "${BATS_TEST_TMPDIR}/a")" = "${base}" ]
  printf '# lib\n' >"${BATS_TEST_TMPDIR}/a/lib/log.sh"
  assert_equal "$(harbor_release_tree_hash "${BATS_TEST_TMPDIR}/a")" "${base}"
  mv "${BATS_TEST_TMPDIR}/a/lib/log.sh" "${BATS_TEST_TMPDIR}/a/lib/other.sh"
  refute [ "$(harbor_release_tree_hash "${BATS_TEST_TMPDIR}/a")" = "${base}" ]
  mv "${BATS_TEST_TMPDIR}/a/lib/other.sh" "${BATS_TEST_TMPDIR}/a/lib/log.sh"
  assert_equal "$(harbor_release_tree_hash "${BATS_TEST_TMPDIR}/a")" "${base}"
  chmod 0664 "${BATS_TEST_TMPDIR}/a/lib/log.sh"
  refute [ "$(harbor_release_tree_hash "${BATS_TEST_TMPDIR}/a")" = "${base}" ]
  chmod 0644 "${BATS_TEST_TMPDIR}/a/lib/log.sh"
  chmod 0700 "${BATS_TEST_TMPDIR}/a/lib"
  refute [ "$(harbor_release_tree_hash "${BATS_TEST_TMPDIR}/a")" = "${base}" ]
  chmod 0755 "${BATS_TEST_TMPDIR}/a/lib"
  chmod 0700 "${BATS_TEST_TMPDIR}/a"
  refute [ "$(harbor_release_tree_hash "${BATS_TEST_TMPDIR}/a")" = "${base}" ]
}

@test "staging extracts the tag through harbor_git, writes RELEASE, and journals harbor-install created" {
  git_repo
  commit="$(gitc rev-parse "${TAG}^{commit}")"
  acquire
  run harbor_release_stage "${FIX_ROOT}" "${CHECKOUT}" "${TAG}" "${DEST}"
  assert_success
  assert [ -f "${DEST}/bin/harbor" ]
  assert [ -f "${DEST}/lib/log.sh" ]
  assert_equal "$(cat "${DEST}/lib/log.sh")" '# committed'
  # Git was reached only through the seam, and the archive was of the tag.
  assert_equal "$(grep -c . "${GIT_LOG}")" 2
  assert_equal "$(grep -c "archive --format=tar ${TAG}\$" "${GIT_LOG}")" 1
  # The RELEASE marker names the tag and the commit.
  assert_equal "$(sed -n 's/^tag=//p' "${DEST}/RELEASE")" "${TAG}"
  assert_equal "$(sed -n 's/^commit=//p' "${DEST}/RELEASE")" "${commit}"
  # One journaled harbor-install entry, created, applied, hash as post_state.
  assert_equal "$(journal_names)" 0001-harbor-install.json
  assert_equal "$(entry_raw "${FIX_ROOT}" 0001 target)" "\"${DEST}\""
  assert_equal "$(entry_raw "${FIX_ROOT}" 0001 ownership)" '"created"'
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" applied
  assert_equal "$(entry_raw "${FIX_ROOT}" 0001 pre_state)" '"absent"'
  assert_equal "$(entry_raw "${FIX_ROOT}" 0001 post_state)" \
    "$(harbor_observe_op_harbor_install "${DEST}")"
  harbor_journal_validate "${FIX_ROOT}/journal/0001-harbor-install.json"
  # No staging directory survives beside the release.
  assert_equal "$(ls -A "${LIBDIR}")" "${TAG}"
  harbor_lock_release "${FIX_ROOT}"
}

@test "the staged tree holds the installed modes whatever modes the tag carried" {
  git_repo
  # The tag carries an executable that is not bin/harbor.
  assert_equal "$(harbor_stat_mode "${CHECKOUT}/tools/hook.sh")" 0755
  acquire
  run harbor_release_stage "${FIX_ROOT}" "${CHECKOUT}" "${TAG}" "${DEST}"
  assert_success
  assert_equal "$(harbor_stat_mode "${DEST}")" 0755
  assert_equal "$(harbor_stat_mode "${DEST}/bin")" 0755
  assert_equal "$(harbor_stat_mode "${DEST}/lib")" 0755
  assert_equal "$(harbor_stat_mode "${DEST}/bin/harbor")" 0755
  assert_equal "$(harbor_stat_mode "${DEST}/tools/hook.sh")" 0644
  assert_equal "$(harbor_stat_mode "${DEST}/lib/log.sh")" 0644
  assert_equal "$(harbor_stat_mode "${DEST}/README.md")" 0644
  assert_equal "$(harbor_stat_mode "${DEST}/RELEASE")" 0644
  harbor_lock_release "${FIX_ROOT}"
}

@test "a group-writable, world-writable, or setgid archive entry is normalized to the installed contract" {
  odd_mode_tar
  # The archive really carries the modes the contract has to override.
  assert_equal "$(harbor_stat_mode "${BATS_TEST_TMPDIR}/odd/lib/log.sh")" 0664
  assert_equal "$(harbor_stat_mode "${BATS_TEST_TMPDIR}/odd/tools/hook.sh")" 0777
  assert_equal "$(harbor_stat_mode "${BATS_TEST_TMPDIR}/odd/README.md")" 0666
  assert_equal "$(harbor_stat_mode "${BATS_TEST_TMPDIR}/odd/bin/harbor")" 0600
  # tools/ is the setgid case, and it is the one an octal chmod alone does not settle:
  # GNU chmod leaves a directory's setuid, setgid, and sticky bits alone when the mode
  # does not mention them. Only the Linux lane proves it, because macOS drops the bit
  # when the fixture sets it, so the assertion below is 2775 there and 0775 here.
  case "$(harbor_stat_mode "${BATS_TEST_TMPDIR}/odd/tools")" in
    2775 | 0775) ;;
    *) fail "the odd-mode fixture directory is neither 2775 nor 0775" ;;
  esac
  acquire
  run harbor_release_stage "${FIX_ROOT}" "${CHECKOUT}" "${TAG}" "${DEST}"
  assert_success
  for d in "" /bin /lib /tools; do
    assert_equal "$(harbor_stat_mode "${DEST}${d}")" 0755
  done
  for f in /lib/log.sh /tools/hook.sh /README.md /RELEASE; do
    assert_equal "$(harbor_stat_mode "${DEST}${f}")" 0644
  done
  assert_equal "$(harbor_stat_mode "${DEST}/bin/harbor")" 0755
  assert_equal "$(sed -n 's/^commit=//p' "${DEST}/RELEASE")" "${STUB_COMMIT}"
  harbor_lock_release "${FIX_ROOT}"
}

@test "the work tree's uncommitted content never reaches the staged tree" {
  git_repo
  dirty_worktree
  acquire
  run harbor_release_stage "${FIX_ROOT}" "${CHECKOUT}" "${TAG}" "${DEST}"
  assert_success
  assert_equal "$(cat "${DEST}/lib/log.sh")" '# committed'
  assert [ ! -e "${DEST}/UNTRACKED.md" ]
  assert [ ! -e "${DEST}/STAGED.md" ]
  assert [ ! -e "${DEST}/.git" ]
  # The checkout itself is untouched.
  assert_equal "$(cat "${CHECKOUT}/lib/log.sh")" '# uncommitted edit'
  assert [ -f "${CHECKOUT}/UNTRACKED.md" ]
  harbor_lock_release "${FIX_ROOT}"
}

@test "two stagings of one tag hash the same and a changed tag hashes differently" {
  git_repo
  acquire
  harbor_release_stage "${FIX_ROOT}" "${CHECKOUT}" "${TAG}" "${LIBDIR}/one"
  harbor_release_stage "${FIX_ROOT}" "${CHECKOUT}" "${TAG}" "${LIBDIR}/two"
  find "${LIBDIR}/one" -exec touch -t 200001010101 {} +
  assert_equal "$(harbor_release_tree_hash "${LIBDIR}/one")" \
    "$(harbor_release_tree_hash "${LIBDIR}/two")"
  printf '# the next release\n' >"${CHECKOUT}/lib/log.sh"
  gitc add -A
  gitc commit -q -m 'the next commit'
  gitc tag v0.2.0
  harbor_release_stage "${FIX_ROOT}" "${CHECKOUT}" v0.2.0 "${LIBDIR}/v0.2.0"
  refute [ "$(harbor_release_tree_hash "${LIBDIR}/v0.2.0")" = "$(harbor_release_tree_hash "${LIBDIR}/one")" ]
  harbor_lock_release "${FIX_ROOT}"
}

@test "a release matching its applied entry is kept, not restaged, and journals nothing new" {
  git_repo
  acquire
  harbor_release_stage "${FIX_ROOT}" "${CHECKOUT}" "${TAG}" "${DEST}"
  dest_inode="$(inode_of "${DEST}")"
  file_inode="$(inode_of "${DEST}/bin/harbor")"
  hash="$(harbor_release_tree_hash "${DEST}")"
  : >"${GIT_LOG}"
  run harbor_release_stage "${FIX_ROOT}" "${CHECKOUT}" "${TAG}" "${DEST}"
  assert_success
  # Nothing was extracted, moved, or replaced: same directory, same file, same hash.
  assert_equal "$(inode_of "${DEST}")" "${dest_inode}"
  assert_equal "$(inode_of "${DEST}/bin/harbor")" "${file_inode}"
  assert_equal "$(harbor_release_tree_hash "${DEST}")" "${hash}"
  assert_equal "$(grep -c . "${GIT_LOG}")" 0
  assert_equal "$(journal_names)" 0001-harbor-install.json
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" applied
  assert_equal "$(ls -A "${LIBDIR}")" "${TAG}"
  harbor_lock_release "${FIX_ROOT}"
}

@test "a release directory with no applied entry exits 3 as an orphan and is left untouched" {
  git_repo
  mkdir -p "${DEST}/lib"
  printf 'mine\n' >"${DEST}/lib/mine.txt"
  before="$(harbor_release_tree_hash "${DEST}")"
  acquire
  run harbor_release_stage "${FIX_ROOT}" "${CHECKOUT}" "${TAG}" "${DEST}"
  assert_equal "${status}" 3
  assert_output --partial 'release.orphan'
  assert_output --partial "${DEST}"
  assert_equal "$(cat "${DEST}/lib/mine.txt")" mine
  assert_equal "$(harbor_release_tree_hash "${DEST}")" "${before}"
  assert_equal "$(journal_names)" ""
  assert_equal "$(grep -c . "${GIT_LOG}")" 0
  assert_equal "$(ls -A "${LIBDIR}")" "${TAG}"
  harbor_lock_release "${FIX_ROOT}"
}

@test "a release directory whose hash differs from its applied entry exits 3 as an orphan and is left untouched" {
  git_repo
  acquire
  harbor_release_stage "${FIX_ROOT}" "${CHECKOUT}" "${TAG}" "${DEST}"
  printf '# edited after installation\n' >>"${DEST}/lib/log.sh"
  before="$(harbor_release_tree_hash "${DEST}")"
  dest_inode="$(inode_of "${DEST}")"
  : >"${GIT_LOG}"
  run harbor_release_stage "${FIX_ROOT}" "${CHECKOUT}" "${TAG}" "${DEST}"
  assert_equal "${status}" 3
  assert_output --partial 'release.orphan'
  assert_output --partial "${DEST}"
  assert_equal "$(harbor_release_tree_hash "${DEST}")" "${before}"
  assert_equal "$(inode_of "${DEST}")" "${dest_inode}"
  assert_equal "$(grep -c . "${GIT_LOG}")" 0
  assert_equal "$(journal_names)" 0001-harbor-install.json
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" applied
  assert_equal "$(ls -A "${LIBDIR}")" "${TAG}"
  harbor_lock_release "${FIX_ROOT}"
}

@test "the harbor-install observer reports the tree hash, absent, and anything else as unobservable" {
  git_repo
  acquire
  assert_equal "$(harbor_observe_op_harbor_install "${DEST}")" '"absent"'
  harbor_release_stage "${FIX_ROOT}" "${CHECKOUT}" "${TAG}" "${DEST}"
  assert_equal "$(harbor_observe_op_harbor_install "${DEST}")" \
    "{\"tree_sha256\":\"$(harbor_release_tree_hash "${DEST}")\"}"
  # The journal dispatches to it by op name, with the hyphen mapped to underscore.
  assert_equal "$(harbor_journal_observe harbor-install "${DEST}")" \
    "$(harbor_observe_op_harbor_install "${DEST}")"
  printf 'foreign\n' >"${LIBDIR}/foreign"
  assert_equal "$(harbor_observe_op_harbor_install "${LIBDIR}/foreign")" \
    '"unobservable:not-a-directory"'
  harbor_lock_release "${FIX_ROOT}"
}

@test "recovery decides a prepared harbor-install entry from the observed tree" {
  # The crash window of design section 3.7: the move into place landed or did not,
  # and the applied write never happened. Recovery observes the release and decides.
  git_repo
  acquire
  fixture_entry "${FIX_ROOT}" 0001 harbor-install "${DEST}" created prepared \
    '"absent"' '{"tree_sha256":"0000000000000000000000000000000000000000000000000000000000000000"}'
  run harbor_journal_recover "${FIX_ROOT}"
  assert_success
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" reverted
  harbor_release_stage "${FIX_ROOT}" "${CHECKOUT}" "${TAG}" "${DEST}"
  post="$(harbor_observe_op_harbor_install "${DEST}")"
  fixture_entry "${FIX_ROOT}" 0003 harbor-install "${DEST}" created prepared '"absent"' "${post}"
  run harbor_journal_recover "${FIX_ROOT}"
  assert_success
  assert_equal "$(entry_phase "${FIX_ROOT}" 0003)" applied
  printf '# edited\n' >>"${DEST}/lib/log.sh"
  fixture_entry "${FIX_ROOT}" 0004 harbor-install "${DEST}" created prepared '"absent"' "${post}"
  run --separate-stderr harbor_journal_recover "${FIX_ROOT}"
  assert_equal "${status}" 2
  assert_regex "${stderr}" 'journal entry 0004-harbor-install.json is undecidable:'
  assert_equal "$(entry_phase "${FIX_ROOT}" 0004)" prepared
  harbor_lock_release "${FIX_ROOT}"
}

@test "the entrypoint symlink is created when nothing is at the link path" {
  make_tree "${DEST}"
  acquire
  run harbor_release_link "${FIX_ROOT}" "${DEST}" "${LINK}" "${LIBDIR}"
  assert_success
  assert [ -L "${LINK}" ]
  assert_equal "$(readlink "${LINK}")" "${DEST}/bin/harbor"
  assert_equal "$(cat "${LINK}")" "$(cat "${DEST}/bin/harbor")"
  assert_equal "$(journal_names)" 0001-file.json
  assert_equal "$(entry_raw "${FIX_ROOT}" 0001 target)" "\"${LINK}\""
  assert_equal "$(entry_raw "${FIX_ROOT}" 0001 ownership)" '"created"'
  assert_equal "$(entry_raw "${FIX_ROOT}" 0001 pre_state)" '"absent"'
  assert_equal "$(entry_raw "${FIX_ROOT}" 0001 post_state)" "{\"symlink\":\"${DEST}/bin/harbor\"}"
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" applied
  harbor_journal_validate "${FIX_ROOT}/journal/0001-file.json"
  # The post_state is what recovery would observe, and no temporary symlink survives.
  assert_equal "$(harbor_observe_file "${LINK}")" "$(entry_raw "${FIX_ROOT}" 0001 post_state)"
  assert_equal "$(ls -A "${BINDIR}")" harbor
  harbor_lock_release "${FIX_ROOT}"
}

@test "an entrypoint symlink already pointing at the release is journaled observed and is never rewritten" {
  make_tree "${DEST}"
  ln -s "${DEST}/bin/harbor" "${LINK}"
  link_inode="$(inode_of "${LINK}")"
  acquire
  run harbor_release_link "${FIX_ROOT}" "${DEST}" "${LINK}" "${LIBDIR}"
  assert_success
  # Same symlink, not a rewritten one.
  assert_equal "$(inode_of "${LINK}")" "${link_inode}"
  assert_equal "$(readlink "${LINK}")" "${DEST}/bin/harbor"
  assert_equal "$(journal_names)" 0001-file.json
  assert_equal "$(entry_raw "${FIX_ROOT}" 0001 ownership)" '"observed"'
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" applied
  assert_equal "$(entry_raw "${FIX_ROOT}" 0001 pre_state)" "{\"symlink\":\"${DEST}/bin/harbor\"}"
  assert_equal "$(entry_raw "${FIX_ROOT}" 0001 post_state)" "{\"symlink\":\"${DEST}/bin/harbor\"}"
  harbor_journal_validate "${FIX_ROOT}/journal/0001-file.json"
  assert_equal "$(ls -A "${BINDIR}")" harbor
  harbor_lock_release "${FIX_ROOT}"
}

@test "an entrypoint symlink pointing at another release is modified with the prior target as pre_state" {
  make_tree "${DEST}"
  make_tree "${LIBDIR}/v0.0.9"
  ln -s "${LIBDIR}/v0.0.9/bin/harbor" "${LINK}"
  acquire
  run harbor_release_link "${FIX_ROOT}" "${DEST}" "${LINK}" "${LIBDIR}"
  assert_success
  assert_equal "$(readlink "${LINK}")" "${DEST}/bin/harbor"
  assert_equal "$(journal_names)" 0001-file.json
  assert_equal "$(entry_raw "${FIX_ROOT}" 0001 target)" "\"${LINK}\""
  assert_equal "$(entry_raw "${FIX_ROOT}" 0001 ownership)" '"modified"'
  # The prior target is recorded, so the reverse walk of teardown restores it.
  assert_equal "$(entry_raw "${FIX_ROOT}" 0001 pre_state)" "{\"symlink\":\"${LIBDIR}/v0.0.9/bin/harbor\"}"
  assert_equal "$(entry_raw "${FIX_ROOT}" 0001 post_state)" "{\"symlink\":\"${DEST}/bin/harbor\"}"
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" applied
  harbor_journal_validate "${FIX_ROOT}/journal/0001-file.json"
  # The release that was pointed at is untouched, and no temporary symlink survives.
  assert [ -f "${LIBDIR}/v0.0.9/bin/harbor" ]
  assert_equal "$(ls -A "${BINDIR}")" harbor
  harbor_lock_release "${FIX_ROOT}"
}

@test "a symlink that does not point into the installed release root is foreign: exit 3, nothing journaled, nothing removed" {
  make_tree "${DEST}"
  make_tree "${LIBDIR}/v0.0.9"
  mkdir -p "${BATS_TEST_TMPDIR}/elsewhere/bin"
  printf '#!/bin/bash\necho elsewhere\n' >"${BATS_TEST_TMPDIR}/elsewhere/bin/harbor"
  chmod 0755 "${BATS_TEST_TMPDIR}/elsewhere/bin/harbor"
  ln -s "${BATS_TEST_TMPDIR}/elsewhere/bin/harbor" "${LINK}"
  acquire
  run harbor_release_link "${FIX_ROOT}" "${DEST}" "${LINK}" "${LIBDIR}"
  assert_equal "${status}" 3
  assert_output --partial 'release.link_foreign'
  assert_output --partial "${LINK}"
  assert_equal "$(readlink "${LINK}")" "${BATS_TEST_TMPDIR}/elsewhere/bin/harbor"
  assert_equal "$(journal_names)" ""
  # A target that only begins with the release root and reaches outside it through a
  # .. component is refused on the link's own text rather than normalized away.
  rm "${LINK}"
  ln -s "${LIBDIR}/../elsewhere/bin/harbor" "${LINK}"
  run harbor_release_link "${FIX_ROOT}" "${DEST}" "${LINK}" "${LIBDIR}"
  assert_equal "${status}" 3
  assert_output --partial 'release.link_foreign'
  assert_equal "$(readlink "${LINK}")" "${LIBDIR}/../elsewhere/bin/harbor"
  assert_equal "$(journal_names)" ""
  # A symlink to a directory inside the release root is refused too: a rename onto it
  # would land inside that directory instead of replacing the link.
  rm "${LINK}"
  ln -s "${DEST}" "${LINK}"
  run harbor_release_link "${FIX_ROOT}" "${DEST}" "${LINK}" "${LIBDIR}"
  assert_equal "${status}" 3
  assert_output --partial 'release.link_foreign'
  assert_equal "$(readlink "${LINK}")" "${DEST}"
  assert_equal "$(journal_names)" ""
  # Without the fourth argument the release root is the production one, so the same
  # fixture link into another fixture release is foreign and nothing is written.
  rm "${LINK}"
  ln -s "${LIBDIR}/v0.0.9/bin/harbor" "${LINK}"
  run harbor_release_link "${FIX_ROOT}" "${DEST}" "${LINK}"
  assert_equal "${status}" 3
  assert_output --partial 'release.link_foreign'
  assert_output --partial /usr/local/lib/harbor
  assert_equal "$(readlink "${LINK}")" "${LIBDIR}/v0.0.9/bin/harbor"
  assert_equal "$(journal_names)" ""
  assert_equal "$(ls -A "${BINDIR}")" harbor
  harbor_lock_release "${FIX_ROOT}"
}

@test "a foreign regular file at the link path exits 3, is left untouched, and journals nothing" {
  make_tree "${DEST}"
  printf '#!/bin/bash\necho not harbor\n' >"${LINK}"
  chmod 0755 "${LINK}"
  before="$(harbor_observe_file "${LINK}")"
  acquire
  run harbor_release_link "${FIX_ROOT}" "${DEST}" "${LINK}" "${LIBDIR}"
  assert_equal "${status}" 3
  assert_output --partial 'release.link_foreign'
  assert_output --partial "${LINK}"
  # Harbor removes nothing it cannot prove it created.
  assert [ ! -L "${LINK}" ]
  assert_equal "$(cat "${LINK}")" '#!/bin/bash
echo not harbor'
  assert_equal "$(harbor_observe_file "${LINK}")" "${before}"
  assert_equal "$(journal_names)" ""
  assert_equal "$(ls -A "${BINDIR}")" harbor
  harbor_lock_release "${FIX_ROOT}"
}

@test "a release without bin/harbor exits 2 before any entry and leaves the link path alone" {
  mkdir -p "${DEST}/lib"
  printf '# lib\n' >"${DEST}/lib/log.sh"
  acquire
  run harbor_release_link "${FIX_ROOT}" "${DEST}" "${LINK}" "${LIBDIR}"
  assert_equal "${status}" 2
  assert_output --partial 'release.link_target'
  assert_output --partial "${DEST}/bin/harbor"
  assert_equal "$(journal_names)" ""
  assert [ ! -e "${LINK}" ]
  assert_equal "$(ls -A "${BINDIR}")" ""
  harbor_lock_release "${FIX_ROOT}"
}

@test "the entrypoint is renamed into place: the temporary path is not the link path and the link never disappears" {
  # The atomicity claim of design section 5.2, asserted at the only instant a unit
  # test can observe it from a single process: the rename itself. A stub mv records
  # what the link path held and what the source path already resolved to at the
  # moment of each rename, then performs the real one.
  make_tree "${DEST}"
  make_tree "${LIBDIR}/v0.0.9"
  ln -s "${LIBDIR}/v0.0.9/bin/harbor" "${LINK}"
  MV_LOG="${BATS_TEST_TMPDIR}/mv.log"
  : >"${MV_LOG}"
  mv() {
    local src="${1}" dst="${2}" state=absent source_target=""
    if [ "${src}" = "-f" ]; then
      src="${2}"
      dst="${3}"
    fi
    if [ -L "${LINK}" ]; then
      state="$(readlink "${LINK}")"
    elif [ -e "${LINK}" ]; then
      state=not-a-symlink
    fi
    if [ -L "${src}" ]; then
      source_target="$(readlink "${src}")"
    fi
    printf '%s|%s|%s|%s\n' "${src}" "${dst}" "${state}" "${source_target}" >>"${MV_LOG}"
    command mv "$@"
  }
  acquire
  run harbor_release_link "${FIX_ROOT}" "${DEST}" "${LINK}" "${LIBDIR}"
  assert_success
  # Exactly one rename had the link path as its destination.
  run grep -c -F "|${LINK}|" "${MV_LOG}"
  assert_output 1
  line="$(grep -F "|${LINK}|" "${MV_LOG}")"
  src="${line%%|*}"
  rest="${line#*|}"
  rest="${rest#*|}"
  state="${rest%%|*}"
  source_target="${rest#*|}"
  # The source is a distinct path beside the link, so the link is replaced by a
  # rename and never unlinked first.
  refute [ "${src}" = "${LINK}" ]
  assert_equal "$(dirname "${src}")" "${BINDIR}"
  # At that instant the link still held the previous release, never nothing.
  assert_equal "${state}" "${LIBDIR}/v0.0.9/bin/harbor"
  # And the source already resolved to the whole new target, so no partial target is
  # ever reachable through the link path.
  assert_equal "${source_target}" "${DEST}/bin/harbor"
  assert_equal "$(readlink "${LINK}")" "${DEST}/bin/harbor"
  assert_equal "$(ls -A "${BINDIR}")" harbor
  harbor_lock_release "${FIX_ROOT}"
}

@test "a prepared entrypoint entry left by a crash is decidable: the renamed link is applied, the one not yet renamed is reverted" {
  # The crash window of design section 3.7: the rename landed or did not, and the
  # applied write never happened. Recovery observes the link path and decides.
  make_tree "${DEST}"
  acquire
  post="{\"symlink\":\"${DEST}/bin/harbor\"}"
  fixture_entry "${FIX_ROOT}" 0001 file "${LINK}" created prepared '"absent"' "${post}"
  run harbor_journal_recover "${FIX_ROOT}"
  assert_success
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" reverted
  assert [ ! -e "${LINK}" ]
  ln -s "${DEST}/bin/harbor" "${LINK}"
  fixture_entry "${FIX_ROOT}" 0002 file "${LINK}" created prepared '"absent"' "${post}"
  run harbor_journal_recover "${FIX_ROOT}"
  assert_success
  assert_equal "$(entry_phase "${FIX_ROOT}" 0002)" applied
  # Deciding an entry inspects only.
  assert_equal "$(readlink "${LINK}")" "${DEST}/bin/harbor"
  # A reinstall's modified entry is decidable the same way: the link renamed into
  # place equals the post_state, the one still at the prior target equals pre_state.
  make_tree "${LIBDIR}/v0.0.9"
  rm "${LINK}"
  ln -s "${LIBDIR}/v0.0.9/bin/harbor" "${LINK}"
  fixture_entry "${FIX_ROOT}" 0003 file "${LINK}" modified prepared \
    "{\"symlink\":\"${LIBDIR}/v0.0.9/bin/harbor\"}" "${post}"
  run harbor_journal_recover "${FIX_ROOT}"
  assert_success
  assert_equal "$(entry_phase "${FIX_ROOT}" 0003)" reverted
  assert_equal "$(readlink "${LINK}")" "${LIBDIR}/v0.0.9/bin/harbor"
  harbor_lock_release "${FIX_ROOT}"
}
