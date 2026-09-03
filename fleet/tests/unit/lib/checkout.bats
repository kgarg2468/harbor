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
  chgrp "${group}" "${FIX_CO}/lib/log.sh"
  run harbor_checkout_trusted "${FIX_CO}"
  assert_success
  run harbor_checkout_trusted "${FIX_CO}" "${group}"
  assert_equal "${status}" 3
  assert_output --partial 'checkout.operator_group'
  assert_output --partial "${FIX_CO}/lib/log.sh"
  chmod 0664 "${FIX_CO}/lib/log.sh"
  run harbor_checkout_trusted "${FIX_CO}" "${group}"
  assert_equal "${status}" 3
  assert_output --partial 'checkout.operator_group'
  assert_output --partial "${FIX_CO}/lib/log.sh"
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
