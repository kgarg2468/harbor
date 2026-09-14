#!/usr/bin/env bats
load '../test_helper'

# Every command runs against a disposable HOME and release. The shell shim answers
# the login-shell probe itself, because running a real login shell would read the
# runner's profile and could resolve its real Node instead of the fixture's version.
setup() {
  harbor_load_libs
  fixture_state_root
  rm -r "${FIX_ROOT}"
  RELEASE="${BATS_TEST_TMPDIR}/release"
  BIN="${BATS_TEST_TMPDIR}/bin"
  RECORD="${BATS_TEST_TMPDIR}/bootstrap.json"
  mkdir -p "${RELEASE}/bin" "${RELEASE}/node" "${BIN}"
  cp -R "${HARBOR_ROOT}/lib" "${RELEASE}/lib"
  cp "${HARBOR}" "${RELEASE}/bin/harbor"
  cp "${HARBOR_ROOT}/versions.lock" "${RELEASE}/versions.lock"
  if [ -f "${HARBOR_ROOT}/node/provision.sh" ]; then
    cp "${HARBOR_ROOT}/node/provision.sh" "${RELEASE}/node/provision.sh"
  fi
  printf '{\n  "tailscale_ownership": "harbor-installed"\n}\n' >"${RECORD}"
  cat >"${BIN}/tailscale" <<'SH'
#!/bin/bash
[ "$*" = 'status --json' ] || exit 99
printf '{"BackendState":"%s"}\n' "${TEST_BACKEND:-Running}"
exit "${TEST_BACKEND_RC:-0}"
SH
  cat >"${BIN}/loginctl" <<'SH'
#!/bin/bash
[ "$*" = "show-user $(id -un) -p Linger --value" ] || exit 99
printf '%s\n' "${TEST_LINGER:-yes}"
exit "${TEST_LINGER_RC:-0}"
SH
  cat >"${BIN}/sh" <<'SH'
#!/bin/bash
[ "$*" = '-lc node --version' ] || exit 99
printf '%s\n' "${TEST_NODE}"
exit "${TEST_NODE_RC:-0}"
SH
  chmod 0755 "${BIN}/tailscale" "${BIN}/loginctl" "${BIN}/sh"
  NODE_LOCKED="$(sed -n 's/^nodejs_version=//p' "${HARBOR_ROOT}/versions.lock")"
}

provision() {
  env HOME="${FIX_HOME}" PATH="${BIN}:${PATH}" HARBOR_DEV=1 \
    HARBOR_AUTH_FIXTURE_RECORD="${RECORD}" HARBOR_VERBOSE=1 \
    TEST_NODE="v${NODE_LOCKED}" "$@" "${RELEASE}/bin/harbor" provision
}

@test "root is refused before any operator state is created" {
  cat >"${BIN}/id" <<'SH'
#!/bin/bash
printf '0\n'
SH
  chmod 0755 "${BIN}/id"
  run provision
  assert_equal "${status}" 3
  assert_output --partial 'provision.root'
  assert_output --partial 'operator'
  assert [ ! -e "${FIX_ROOT}" ]
}

@test "a checkout is refused before the backend or state root is touched" {
  run provision HARBOR_DEV=0
  assert_equal "${status}" 3
  assert_output --partial 'entrypoint.location'
  refute_output --partial 'vendor: tailscale'
  assert [ ! -e "${FIX_ROOT}" ]
}

@test "a Harbor-installed backend needing login exits attended before linger and state creation" {
  run provision TEST_BACKEND=NeedsLogin TEST_LINGER=no
  assert_equal "${status}" 1
  assert_output --partial 'needs_tailscale_login'
  assert_output --partial 'harbor auth tailscale'
  refute_output --partial 'provision.linger'
  assert [ ! -e "${FIX_ROOT}" ]
}

@test "a pre-existing backend needing login names the owner's tailscale up" {
  printf '{\n  "tailscale_ownership": "pre-existing"\n}\n' >"${RECORD}"
  run provision TEST_BACKEND=NeedsLogin
  assert_equal "${status}" 1
  assert_output --partial 'tailscale up'
  refute_output --partial 'harbor auth tailscale'
  assert [ ! -e "${FIX_ROOT}" ]
}

@test "a failed backend read is attended even if its output says Running" {
  run provision TEST_BACKEND_RC=1
  assert_equal "${status}" 1
  assert_output --partial 'needs_tailscale_login'
  assert [ ! -e "${FIX_ROOT}" ]
}

@test "linger off names the exact root command and creates nothing" {
  run provision TEST_LINGER=no
  assert_equal "${status}" 3
  assert_output --partial "sudo loginctl enable-linger $(id -un)"
  assert [ ! -e "${FIX_ROOT}" ]
}

@test "a failed linger read refuses even if its output says yes" {
  run provision TEST_LINGER_RC=1
  assert_equal "${status}" 3
  assert_output --partial 'provision.linger'
  assert [ ! -e "${FIX_ROOT}" ]
}

@test "a state-root creation failure exits broken without taking a lock or writing a journal" {
  rm -r "${FIX_HOME}/.local"
  printf 'foreign\n' >"${FIX_HOME}/.local"
  run provision
  assert_equal "${status}" 2
  assert_output --partial 'provision.state_root'
  assert_equal "$(cat "${FIX_HOME}/.local")" foreign
  refute_output --partial 'step provision-lock'
}

@test "the state root is 0700 at lock-gate before any journal exists" {
  run provision HARBOR_TEST_HOOKS=1 HARBOR_FAIL_AFTER=lock-gate
  assert_equal "${status}" 137
  run ls -ld "${FIX_ROOT}"
  assert_output --regexp '^drwx------'
  assert [ ! -e "${FIX_ROOT}/journal" ]
  assert [ ! -e "${FIX_ROOT}/lock.d" ]
  run ls -ld "${FIX_ROOT}/reclaim.d"
  assert_output --regexp '^drwx------'
  run ls -l "${FIX_ROOT}/reclaim.d/holder"
  assert_output --regexp '^-rw-------'
  run cat "${FIX_ROOT}/harbor.log"
  assert_output --partial 'step lock-gate'
}

@test "a malformed versions lock refuses before Node and recovery" {
  printf 'foreign=value\n' >>"${RELEASE}/versions.lock"
  run provision
  assert_equal "${status}" 3
  assert_output --partial 'versions.unknown_key'
  refute_output --partial 'step provision-node'
  assert [ ! -e "${FIX_ROOT}/journal" ]
}

@test "a malformed command lock refuses before Node and recovery" {
  mkdir -p "${FIX_ROOT}/lock.d"
  printf 'broken\n' >"${FIX_ROOT}/lock.d/holder"
  run provision
  assert_equal "${status}" 3
  assert_output --partial 'lock.'
  refute_output --partial 'step provision-node'
  assert_equal "$(cat "${FIX_ROOT}/lock.d/holder")" broken
  assert [ ! -e "${FIX_ROOT}/journal" ]
}

@test "an incompatible login-shell Node refuses before journal recovery" {
  run provision TEST_NODE=v1.0.0
  assert_equal "${status}" 3
  assert_output --partial 'provision.node'
  assert_output --partial 't3_engines_node'
  assert [ ! -e "${FIX_ROOT}/journal" ]
  assert [ ! -e "${FIX_ROOT}/lock.d" ]
}

@test "a failed login-shell Node read refuses before recovery" {
  run provision TEST_NODE_RC=1
  assert_equal "${status}" 3
  assert_output --partial 'provision.node'
  assert [ ! -e "${FIX_ROOT}/journal" ]
}

@test "undecidable recovery exits broken and leaves the artifact and entry unchanged" {
  fixture_undecidable_file_entry "${FIX_ROOT}" 0001
  run provision
  assert_equal "${status}" 2
  assert_output --partial 'journal.undecidable'
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" prepared
  assert_equal "$(cat "${FIX_ARTIFACT_0001}")" two
  refute_output --partial 'preflight complete'
}

@test "healthy preflight runs in table order and stops before provision rows" {
  run provision
  assert_success
  assert_output --partial 'preflight complete'
  # Two expressions rather than one \(a\|b\): alternation inside \(...\) is a GNU
  # extension, and BSD sed on the macos-14 runner matches nothing at all rather than
  # failing, so the single-pattern form reads every step list as empty and would have
  # passed this assertion only on Linux.
  steps="$(printf '%s\n' "${output}" \
    | sed -n -e 's/^harbor: step: \(provision-.*\)$/\1/p' -e 's/^harbor: step: \(recovery-scan\)$/\1/p')"
  assert_equal "${steps}" 'provision-principal
provision-entrypoint
provision-backend
provision-linger
provision-state-root
provision-lock
provision-node
recovery-scan'
  assert [ ! -e "${FIX_ROOT}/lock.d" ]
  assert [ ! -e "${FIX_ROOT}/journal" ]
  assert [ ! -e "${FIX_ROOT}/installed.lock" ]
  assert [ ! -e "${FIX_ROOT}/provision.json" ]
  assert [ ! -e "${FIX_HOME}/.config" ]
}
