#!/usr/bin/env bats
load '../test_helper'

setup() {
  # lib/checkout.sh depends on lib/log.sh (harbor_die) and lib/lock.sh (harbor_os),
  # so this file sources those three rather than harbor_load_libs.
  # shellcheck source=lib/log.sh
  . "${HARBOR_ROOT}/lib/log.sh"
  # shellcheck source=lib/lock.sh
  . "${HARBOR_ROOT}/lib/lock.sh"
  # shellcheck source=lib/checkout.sh
  . "${HARBOR_ROOT}/lib/checkout.sh"
  TEST_USER="$(id -un)"
  # The rules judge every component from / to the checkout root, so the fixture cannot
  # live under BATS_TEST_TMPDIR: on Linux that sits under /tmp, whose 1777 mode the
  # rules reject, correctly. Every component of ${HOME} is owned by root or by the
  # test user and none is group- or world-writable on either platform, so a disposable
  # directory there is the one fixture base whose ancestors pass. It is canonical
  # already, so the paths the rules name are the paths the fixture built.
  FIX_BASE="$(cd "$(mktemp -d "${HOME}/.harbor-checkout-test.XXXXXX")" && pwd -P)"
  FIX_CO="${FIX_BASE}/checkout"
  build_checkout "${FIX_CO}"
  # Production trusts root and the invoking SUDO_USER. An unprivileged unit test can
  # create neither a root-owned fixture nor a second account, so the test user stands
  # in for SUDO_USER. The set is a stand-in, never a relaxation: every rule below still
  # runs, and lib/checkout.sh ignores this variable when the caller is root.
  HARBOR_CHECKOUT_TRUSTED_USERS="root ${TEST_USER}"
  # The Git fixtures below judge no ownership, so they live in the per-test tmpdir
  # rather than under ${HOME}. Built on demand: most tests here need no repository.
  REPO="${BATS_TEST_TMPDIR}/repo"
}

teardown() {
  case "${FIX_BASE:-}" in
    /*/.harbor-checkout-test.??????) rm -rf "${FIX_BASE}" ;;
  esac
}

build_checkout() {
  # build_checkout DIR: a checkout as a clone at a tag leaves it, with one symlink
  # inside the tree whose target satisfies the rules.
  local co="${1}"
  mkdir -p "${co}/bin" "${co}/lib" "${co}/node"
  printf '#!/bin/bash\nexit 0\n' >"${co}/bin/harbor"
  printf '# lib\n' >"${co}/lib/log.sh"
  printf '# node\n' >"${co}/node/bootstrap.sh"
  ln -s log.sh "${co}/lib/alias.sh"
  chmod 0755 "${co}" "${co}/bin" "${co}/lib" "${co}/node" "${co}/bin/harbor"
  chmod 0644 "${co}/lib/log.sh" "${co}/node/bootstrap.sh"
}

owner_of() {
  # owner_of PATH: the owner of PATH with symlinks followed
  case "$(uname -s)" in
    Linux) stat -L -c '%U' -- "${1}" ;;
    Darwin) stat -L -f '%Su' -- "${1}" ;;
  esac
}

first_not_owned_by_root() {
  # first_not_owned_by_root PATH: the first component of PATH from / that root does
  # not own, which is the path the rules name when root alone is trusted. Computed
  # rather than written down because it is ${HOME} on one platform and another
  # directory on the next.
  local rest="${1#/}" prefix="" part
  while [ -n "${rest}" ]; do
    part="${rest%%/*}"
    prefix="${prefix}/${part}"
    if [ "$(owner_of "${prefix}")" != root ]; then
      printf '%s\n' "${prefix}"
      return 0
    fi
    case "${rest}" in
      */*) rest="${rest#*/}" ;;
      *) rest="" ;;
    esac
  done
  return 1
}

operator_group() {
  # A group the test user belongs to that is neither its primary group nor the name of
  # an account, so a fixture path can carry it and lib/checkout.sh resolves an operator
  # of that name to it. An unprivileged test cannot create a group, so this stands in
  # for the operator's group the way the trusted set stands in for SUDO_USER.
  local g primary
  primary="$(id -gn)"
  for g in $(id -Gn); do
    [ "${g}" != "${primary}" ] || continue
    if ! id -gn "${g}" >/dev/null 2>&1; then
      printf '%s\n' "${g}"
      return 0
    fi
  done
  return 1
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

@test "the relative, parent-relative, and absolute spellings of one script give one root" {
  local expected="${FIX_CO}"
  assert_equal "$(harbor_checkout_root_from_argv0 "${FIX_CO}/bin/harbor")" "${expected}"
  cd "${FIX_CO}"
  assert_equal "$(harbor_checkout_root_from_argv0 ./bin/harbor)" "${expected}"
  assert_equal "$(harbor_checkout_root_from_argv0 bin/harbor)" "${expected}"
  cd "${FIX_BASE}"
  assert_equal "$(harbor_checkout_root_from_argv0 checkout/bin/harbor)" "${expected}"
  cd "${FIX_CO}/bin"
  assert_equal "$(harbor_checkout_root_from_argv0 ../bin/harbor)" "${expected}"
}

@test "a symlinked entrypoint resolves to the root of the checkout it really lives in" {
  ln -s "${FIX_CO}/bin/harbor" "${FIX_BASE}/harbor-link"
  assert_equal "$(harbor_checkout_root_from_argv0 "${FIX_BASE}/harbor-link")" "${FIX_CO}"
  ln -s harbor-link "${FIX_BASE}/harbor-link-2"
  assert_equal "$(harbor_checkout_root_from_argv0 "${FIX_BASE}/harbor-link-2")" "${FIX_CO}"
}

@test "a parent directory not named bin exits 3" {
  mkdir -p "${FIX_CO}/sbin"
  cp "${FIX_CO}/bin/harbor" "${FIX_CO}/sbin/harbor"
  run harbor_checkout_root_from_argv0 "${FIX_CO}/sbin/harbor"
  assert_equal "${status}" 3
  assert_output --partial 'checkout.layout'
  assert_output --partial "${FIX_CO}/sbin"
  run harbor_checkout_root_from_argv0 "${FIX_CO}/bin/harbor/nowhere"
  assert_equal "${status}" 3
  run harbor_checkout_root_from_argv0 ""
  assert_equal "${status}" 3
}

@test "a checkout whose every component is trusted passes, with and without an operator" {
  run harbor_checkout_trusted "${FIX_CO}"
  assert_success
  assert_output ""
  run harbor_checkout_trusted "${FIX_CO}" harbor-operator
  assert_success
  assert_output ""
}

@test "a group-writable directory inside the checkout exits 3 naming it" {
  chmod 0775 "${FIX_CO}/lib"
  run harbor_checkout_trusted "${FIX_CO}"
  assert_equal "${status}" 3
  assert_output --partial 'checkout.mode'
  assert_output --partial "${FIX_CO}/lib"
}

@test "a group-writable component above the checkout exits 3 naming it" {
  chmod 0775 "${FIX_BASE}"
  run harbor_checkout_trusted "${FIX_CO}"
  assert_equal "${status}" 3
  assert_output --partial 'checkout.mode'
  assert_output --partial "${FIX_BASE}"
}

@test "a world-writable file inside the checkout exits 3 naming it" {
  chmod 0666 "${FIX_CO}/node/bootstrap.sh"
  run harbor_checkout_trusted "${FIX_CO}"
  assert_equal "${status}" 3
  assert_output --partial 'checkout.mode'
  assert_output --partial "${FIX_CO}/node/bootstrap.sh"
}

@test "a component owned by neither trusted identity exits 3 naming it" {
  local expected
  expected="$(first_not_owned_by_root "${FIX_CO}")"
  HARBOR_CHECKOUT_TRUSTED_USERS="root"
  run harbor_checkout_trusted "${FIX_CO}"
  assert_equal "${status}" 3
  assert_output --partial 'checkout.owner'
  assert_output --partial "${expected}"
  assert_output --partial "${TEST_USER}"
}

@test "a path owned by the operator is rejected outright even though its owner is trusted" {
  local expected
  expected="$(first_not_owned_by_root "${FIX_CO}")"
  run harbor_checkout_trusted "${FIX_CO}"
  assert_success
  run harbor_checkout_trusted "${FIX_CO}" "${TEST_USER}"
  assert_equal "${status}" 3
  assert_output --partial 'checkout.operator'
  assert_output --partial "${expected}"
}

@test "a file in the operator's group exits 3 naming it, writable by that group or not" {
  local group
  group="$(operator_group)" || skip "the test user is in no group that is not also an account name"
  # node/bootstrap.sh, not lib/log.sh: lib/alias.sh is a symlink to log.sh, and the
  # walk follows symlinks, so putting log.sh in the group puts two paths in it and
  # which one the walk reaches first is filesystem order. The rule rejects either,
  # but the name in the message would then differ by platform. bootstrap.sh has no
  # alias, so the path the message names is the path this test changed.
  chgrp "${group}" "${FIX_CO}/node/bootstrap.sh"
  run harbor_checkout_trusted "${FIX_CO}"
  assert_success
  run harbor_checkout_trusted "${FIX_CO}" "${group}"
  assert_equal "${status}" 3
  assert_output --partial 'checkout.operator_group'
  assert_output --partial "${FIX_CO}/node/bootstrap.sh"
  chmod 0664 "${FIX_CO}/node/bootstrap.sh"
  run harbor_checkout_trusted "${FIX_CO}" "${group}"
  assert_equal "${status}" 3
  assert_output --partial 'checkout.operator_group'
  assert_output --partial "${FIX_CO}/node/bootstrap.sh"
}

@test "a symlink inside the checkout whose target breaks the rule exits 3 naming both" {
  printf 'x\n' >"${FIX_BASE}/outside"
  chmod 0666 "${FIX_BASE}/outside"
  ln -s "${FIX_BASE}/outside" "${FIX_CO}/lib/evil.sh"
  run harbor_checkout_trusted "${FIX_CO}"
  assert_equal "${status}" 3
  assert_output --partial 'checkout.mode'
  assert_output --partial "${FIX_CO}/lib/evil.sh"
  assert_output --partial "${FIX_BASE}/outside"
}

@test "a symlink inside the checkout that resolves to nothing exits 3 naming it" {
  ln -s ./missing.sh "${FIX_CO}/lib/dangling.sh"
  run harbor_checkout_trusted "${FIX_CO}"
  assert_equal "${status}" 3
  assert_output --partial 'checkout.unresolved'
  assert_output --partial "${FIX_CO}/lib/dangling.sh"
}

@test "a checkout path that is not a readable directory exits 3" {
  run harbor_checkout_trusted "${FIX_BASE}/absent"
  assert_equal "${status}" 3
  assert_output --partial 'checkout.absent'
  assert_output --partial "${FIX_BASE}/absent"
}

@test "no call modifies anything under the fixture root" {
  local before after
  before="$(snapshot "${FIX_BASE}")"
  run harbor_checkout_root_from_argv0 "${FIX_CO}/bin/harbor"
  assert_success
  run harbor_checkout_trusted "${FIX_CO}"
  assert_success
  run harbor_checkout_trusted "${FIX_CO}" harbor-operator
  assert_success
  run harbor_checkout_trusted "${FIX_CO}" "${TEST_USER}"
  assert_equal "${status}" 3
  HARBOR_CHECKOUT_TRUSTED_USERS="root"
  run harbor_checkout_trusted "${FIX_CO}"
  assert_equal "${status}" 3
  after="$(snapshot "${FIX_BASE}")"
  assert_equal "${after}" "${before}"
}

# The hardened Git invocation and the clean exact tag check (design section 5.1).

fixture_git() {
  # fixture_git DIR ARGS...: the Git that builds a throwaway fixture repository, never
  # the function under test. Isolated from the machine's configuration the same way the
  # hardened form is, with the identity given per invocation, so building a fixture
  # writes nothing outside the fixture repository itself.
  local dir="${1}"
  shift
  GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git -C "${dir}" \
    -c init.defaultBranch=main -c user.name=Harbor -c user.email=harbor@example.com \
    -c commit.gpgsign=false -c tag.gpgSign=false -c core.hooksPath=/dev/null "$@"
}

build_repo() {
  # build_repo DIR: one commit with the tag v0.1.0 on it, as a clone at a tag leaves it
  mkdir -p "${1}"
  fixture_git "${1}" init --quiet
  printf 'one\n' >"${1}/file"
  fixture_git "${1}" add file
  fixture_git "${1}" commit --quiet -m one
  fixture_git "${1}" tag v0.1.0
}

commit_repo() {
  # commit_repo DIR MESSAGE: append MESSAGE to the tracked file and commit it
  printf '%s\n' "${2}" >>"${1}/file"
  fixture_git "${1}" add file
  fixture_git "${1}" commit --quiet -m "${2}"
}

git_shim() {
  # git_shim DIR: a git on PATH that records the environment the hardened form sets
  # and its own argument vector, one entry per line, and does nothing else. The log is
  # the only way to see the exact vector: the real Git would not report it.
  mkdir -p "${1}"
  SHIM_LOG="${1}/git.log"
  cat >"${1}/git" <<'SHIM'
#!/bin/bash
{
  printf 'GIT_CONFIG_NOSYSTEM=%s\n' "${GIT_CONFIG_NOSYSTEM-<unset>}"
  printf 'GIT_CONFIG_GLOBAL=%s\n' "${GIT_CONFIG_GLOBAL-<unset>}"
  printf 'argv=%s\n' "${0##*/}"
  for shim_arg in ${1+"$@"}; do
    printf 'argv=%s\n' "${shim_arg}"
  done
} >>"${HARBOR_GIT_SHIM_LOG}"
SHIM
  chmod 0755 "${1}/git"
  PATH="${1}:${PATH}"
  HARBOR_GIT_SHIM_LOG="${SHIM_LOG}"
  export PATH HARBOR_GIT_SHIM_LOG
}

@test "harbor_git runs exactly the hardened invocation of design section 5.1" {
  local expected
  git_shim "${BATS_TEST_TMPDIR}/shimbin"
  run harbor_git "${FIX_CO}" rev-parse --verify HEAD
  assert_success
  assert_output ""
  expected="GIT_CONFIG_NOSYSTEM=1
GIT_CONFIG_GLOBAL=/dev/null
argv=git
argv=-C
argv=${FIX_CO}
argv=-c
argv=safe.directory=${FIX_CO}
argv=-c
argv=core.fsmonitor=false
argv=-c
argv=core.hooksPath=/dev/null
argv=rev-parse
argv=--verify
argv=HEAD"
  assert_equal "$(cat "${SHIM_LOG}")" "${expected}"
}

@test "the hardened invocation carries arguments through unaltered, spaces and all" {
  local expected
  git_shim "${BATS_TEST_TMPDIR}/shimbin"
  run harbor_git "${FIX_CO}" log -1 --format=%s 'a b'
  assert_success
  expected="argv=log
argv=-1
argv=--format=%s
argv=a b"
  assert_equal "$(sed -n '12,$p' "${SHIM_LOG}")" "${expected}"
}

@test "harbor_git without a checkout and arguments exits 3" {
  run harbor_git
  assert_equal "${status}" 3
  assert_output --partial usage
  run harbor_git "${FIX_CO}"
  assert_equal "${status}" 3
  assert_output --partial usage
}

@test "harbor_git gives Git's own stdout and exit status to its caller" {
  local head
  build_repo "${REPO}"
  head="$(fixture_git "${REPO}" rev-parse HEAD)"
  run harbor_git "${REPO}" rev-parse HEAD
  assert_success
  assert_output "${head}"
  harbor_git "${REPO}" archive --format=tar v0.1.0 >"${BATS_TEST_TMPDIR}/tag.tar"
  run tar -tf "${BATS_TEST_TMPDIR}/tag.tar"
  assert_output "file"
  run harbor_git "${REPO}" rev-parse --verify refs/tags/absent
  assert_failure
}

@test "a clean work tree at an exact tag gives the tag, on a branch and detached" {
  build_repo "${REPO}"
  run harbor_checkout_tag "${REPO}"
  assert_success
  assert_output v0.1.0
  fixture_git "${REPO}" checkout --quiet --detach v0.1.0
  run harbor_checkout_tag "${REPO}"
  assert_success
  assert_output v0.1.0
}

@test "a dirty work tree at a tag exits 3 naming the modification" {
  build_repo "${REPO}"
  printf 'two\n' >>"${REPO}/file"
  run harbor_checkout_tag "${REPO}"
  assert_equal "${status}" 3
  assert_output --partial 'checkout.dirty'
  assert_output --partial 'file'
  fixture_git "${REPO}" add file
  run harbor_checkout_tag "${REPO}"
  assert_equal "${status}" 3
  assert_output --partial 'checkout.dirty'
}

@test "an untracked file at a tag exits 3 naming it, not as a dirty work tree" {
  build_repo "${REPO}"
  printf 'scratch\n' >"${REPO}/scratch"
  run harbor_checkout_tag "${REPO}"
  assert_equal "${status}" 3
  assert_output --partial 'checkout.untracked'
  assert_output --partial 'scratch'
  refute_output --partial 'checkout.dirty'
}

@test "a detached HEAD no tag names or follows exits 3" {
  local repo="${BATS_TEST_TMPDIR}/untagged"
  mkdir -p "${repo}"
  fixture_git "${repo}" init --quiet
  printf 'one\n' >"${repo}/file"
  fixture_git "${repo}" add file
  fixture_git "${repo}" commit --quiet -m one
  fixture_git "${repo}" checkout --quiet --detach HEAD
  run harbor_checkout_tag "${repo}"
  assert_equal "${status}" 3
  assert_output --partial 'checkout.no_tag'
  refute_output --partial 'checkout.between_tags'
}

@test "a commit between tags exits 3 naming the tag it is past" {
  local middle
  build_repo "${REPO}"
  commit_repo "${REPO}" two
  middle="$(fixture_git "${REPO}" rev-parse HEAD)"
  commit_repo "${REPO}" three
  fixture_git "${REPO}" tag v0.2.0
  run harbor_checkout_tag "${REPO}"
  assert_success
  assert_output v0.2.0
  fixture_git "${REPO}" checkout --quiet --detach "${middle}"
  run harbor_checkout_tag "${REPO}"
  assert_equal "${status}" 3
  assert_output --partial 'checkout.between_tags'
  assert_output --partial 'v0.1.0'
  refute_output --partial 'checkout.no_tag'
  fixture_git "${REPO}" checkout --quiet --detach main
  commit_repo "${REPO}" four
  run harbor_checkout_tag "${REPO}"
  assert_equal "${status}" 3
  assert_output --partial 'checkout.between_tags'
  assert_output --partial 'v0.2.0'
}

@test "a path that is not a Git checkout with a commit at HEAD exits 3" {
  mkdir -p "${REPO}"
  run harbor_checkout_tag "${REPO}"
  assert_equal "${status}" 3
  assert_output --partial 'checkout.no_head'
  run harbor_checkout_tag ""
  assert_equal "${status}" 3
  assert_output --partial usage
}

@test "HARBOR_DEV=1 relaxes neither function, so no root command stages dirty work" {
  build_repo "${REPO}"
  HARBOR_DEV=1
  export HARBOR_DEV
  run harbor_checkout_tag "${REPO}"
  assert_success
  printf 'two\n' >>"${REPO}/file"
  run harbor_checkout_tag "${REPO}"
  assert_equal "${status}" 3
  assert_output --partial 'checkout.dirty'
  fixture_git "${REPO}" checkout --quiet -- file
  printf 'scratch\n' >"${REPO}/scratch"
  run harbor_checkout_tag "${REPO}"
  assert_equal "${status}" 3
  assert_output --partial 'checkout.untracked'
  # The root case cannot be built by an unprivileged unit test, so it is proved
  # structurally instead: no code line of lib/checkout.sh reads HARBOR_DEV at all, so
  # there is no branch for the caller's identity to take and nothing to relax.
  run grep -v '^[[:space:]]*#' "${HARBOR_ROOT}/lib/checkout.sh"
  assert_success
  refute_output --partial 'HARBOR_DEV'
}

@test "neither function writes to any Git configuration" {
  local home="${BATS_TEST_TMPDIR}/githome" before after
  build_repo "${REPO}"
  mkdir -p "${home}"
  before="$(cat "${REPO}/.git/config")"
  HOME="${home}"
  XDG_CONFIG_HOME="${home}/config"
  export HOME XDG_CONFIG_HOME
  run harbor_checkout_tag "${REPO}"
  assert_success
  run harbor_git "${REPO}" rev-parse HEAD
  assert_success
  after="$(cat "${REPO}/.git/config")"
  assert_equal "${after}" "${before}"
  run find "${home}" -type f
  assert_success
  assert_output ""
}
