#!/usr/bin/env bats
load '../test_helper'

setup() {
  harbor_load_libs
  . "${HARBOR_ROOT}/lib/runtime.sh"
  . "${HARBOR_ROOT}/lib/agents.sh"
  . "${HARBOR_ROOT}/lib/t3.sh"
  fixture_state_root
  export HOME="${FIX_HOME}"
  export TEST_CONNECT_ROOT="${BATS_TEST_TMPDIR}"
  FIX_SHIM_LOG="${BATS_TEST_TMPDIR}/calls"
  : >"${FIX_SHIM_LOG}"
  # Boot identity is a system boundary, not the behavior under test. A fixed
  # fixture also works when the macOS sandbox denies kern.boottime reads.
  mkdir -p "${BATS_TEST_TMPDIR}/bin"
  cat >"${BATS_TEST_TMPDIR}/bin/sysctl" <<'SH'
#!/bin/bash
[ "$#" = 2 ] && [ "${1}" = -n ] && [ "${2}" = kern.boottime ] || exit 97
printf '{ sec = 1234567890, usec = 0 }\n'
SH
  chmod 0755 "${BATS_TEST_TMPDIR}/bin/sysctl"
  # ps is also sandbox-restricted. Preserve liveness via kill -0 while
  # supplying a stable start identity for this isolated fixture process.
  cat >"${BATS_TEST_TMPDIR}/bin/ps" <<'SH'
#!/bin/bash
[ "$#" = 4 ] || exit 97
if [ "${1}" = -p ] && [ "${3}" = -o ] && [ "${4}" = pid= ]; then
  kill -0 "${2}" 2>/dev/null || exit 1
  printf '%s\n' "${2}"
elif [ "${1}" = -o ] && [ "${2}" = lstart= ] && [ "${3}" = -p ]; then
  kill -0 "${4}" 2>/dev/null || exit 1
  printf 'Fri Sep 18 00:00:00 2026\n'
else
  exit 97
fi
SH
  chmod 0755 "${BATS_TEST_TMPDIR}/bin/ps"
  export PATH="${BATS_TEST_TMPDIR}/bin:${PATH}"
  harbor_versions_load "${HARBOR_ROOT}/versions.lock"
  export TEST_T3_VERSION="$(harbor_version_require t3_version)"
  mkdir -p "${FIX_HOME}/.local/harbor/npm/bin"
  cat >"${FIX_HOME}/.local/harbor/npm/bin/t3" <<'SH'
#!/bin/bash
set -euo pipefail
if [ "$#" = 1 ] && [ "${1}" = --version ]; then
  printf 't3 v%s\n' "${TEST_T3_VERSION}"
  exit 0
fi
printf '%s\n' "$*" >>"${TEST_CONNECT_ROOT}/calls"
if [ "$#" = 3 ] && [ "${1}" = connect ] && [ "${2}" = status ] && [ "${3}" = --json ]; then
  cat "${TEST_CONNECT_ROOT}/status"
elif [ "$#" = 2 ] && [ "${1}" = connect ] && [ "${2}" = link ]; then
  mode="$(cat "${TEST_CONNECT_ROOT}/mode")"
  [ "${mode}" != failure ] || exit 1
  if [ "${mode}" = prompts ]; then
    printf 'Download the relay client?\n'
    IFS= read -r answer
    printf '%s\n' "${answer}" >"${TEST_CONNECT_ROOT}/answer"
  fi
  cp "${HARBOR_ROOT}/tests/fixtures/t3/connect-status/healthy" "${TEST_CONNECT_ROOT}/status"
elif [ "$#" = 2 ] && [ "${1}" = service ] && [ "${2}" = restart ]; then
  exit 0
else
  exit 97
fi
SH
  chmod 0755 "${FIX_HOME}/.local/harbor/npm/bin/t3"
}

teardown() {
  harbor_lock_release "${FIX_ROOT}" 2>/dev/null || true
}

connect_status_fixture() {
  local name="${1}"
  [ "${name}" != authenticated-not-linked ] || name=needs-link
  cp "${HARBOR_ROOT}/tests/fixtures/t3/connect-status/${name}" "${BATS_TEST_TMPDIR}/status"
}

connect_link_shim() {
  printf '%s\n' "${1}" >"${BATS_TEST_TMPDIR}/mode"
}

# A fresh process makes the crash hook kill Harbor itself, never the Bats runner.
connect_run() {
  env HOME="${FIX_HOME}" HARBOR_DEV=1 "${HARBOR}" auth connect
}

@test "the link step journals prepared before the vendor runs, and applied after" {
  connect_status_fixture authenticated-not-linked
  connect_link_shim success
  run connect_run
  assert_success
  assert grep -q 'connect link' "${FIX_SHIM_LOG}"
  assert_equal "$(entry_raw "${FIX_ROOT}" 0001 op)" '"t3-connect-link"'
  assert_equal "$(entry_raw "${FIX_ROOT}" 0001 ownership)" '"created"'
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" applied
  assert_equal "$(entry_raw "${FIX_ROOT}" 0001 pre_state)" '"false"'
  assert_equal "$(entry_raw "${FIX_ROOT}" 0001 post_state)" '"true"'
}

@test "the entry is written before the vendor is invoked, not after it returns" {
  # The order is the contract: a crash during t3 connect link must leave an entry
  # recovery can decide. Proved by crashing at the boundary between them.
  connect_status_fixture authenticated-not-linked
  connect_link_shim success
  HARBOR_TEST_HOOKS=1 HARBOR_FAIL_AFTER=connect-link-prepared \
    run connect_run
  assert_equal "${status}" 137
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" prepared
  # And the vendor never ran, which is what makes this a revertible entry.
  refute grep -q 'connect link' "${FIX_SHIM_LOG}"
  assert grep -q 'connect status --json' "${FIX_SHIM_LOG}"
}

@test "a link the vendor did not complete leaves the entry prepared and says so" {
  connect_status_fixture authenticated-not-linked
  connect_link_shim failure
  run connect_run
  assert_equal "${status}" 1
  assert_output --partial 'stays prepared'
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" prepared
}

@test "the service is restarted after a successful link, so it reconciles" {
  connect_status_fixture authenticated-not-linked
  connect_link_shim success
  run connect_run
  assert_success
  assert grep -q 'service restart' "${FIX_SHIM_LOG}"
}

@test "an already-linked node runs no link and journals nothing" {
  connect_status_fixture healthy
  run connect_run
  assert_success
  assert_output --partial 'already authorized and linked'
  refute grep -q 'connect link' "${FIX_SHIM_LOG}"
  assert_equal "$(ls -A "${FIX_ROOT}/journal" | wc -l | tr -d ' ')" 0
}

@test "the vendor's prompt is not pre-answered and its streams are not captured" {
  # Section 3.6: pass the relay-client download prompt through. A captured stdout
  # is a prompt the operator never sees, and a supplied stdin is a prompt Harbor
  # answered on their behalf.
  connect_status_fixture authenticated-not-linked
  connect_link_shim prompts
  run connect_run <<<"operator-answer"
  assert_success
  assert_equal "$(cat "${BATS_TEST_TMPDIR}/answer")" operator-answer
  assert_output --partial 'Download the relay client?'
}

@test "a crashed link is decided by the vendor's own status on the next run" {
  connect_status_fixture authenticated-not-linked
  connect_link_shim success
  HARBOR_TEST_HOOKS=1 HARBOR_FAIL_AFTER=connect-link-prepared \
    run connect_run
  assert_equal "${status}" 137
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" prepared
  # The vendor never linked, so the world still equals pre_state and recovery
  # reverts. This is the case the -prepared boundary exists for.
  HARBOR_AGENTS_HOME="${FIX_HOME}"
  harbor_lock_acquire "${FIX_ROOT}" operator
  harbor_journal_recover "${FIX_ROOT}"
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" reverted
}

@test "a link the vendor completed before the crash is recovered as applied" {
  connect_status_fixture authenticated-not-linked
  connect_link_shim success
  HARBOR_TEST_HOOKS=1 HARBOR_FAIL_AFTER=connect-link \
    run connect_run
  assert_equal "${status}" 137
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" prepared
  # The vendor shim already linked before the crash; do not manufacture the
  # post-state here, or the recovery test would hide a missing vendor call.
  HARBOR_AGENTS_HOME="${FIX_HOME}"
  harbor_lock_acquire "${FIX_ROOT}" operator
  harbor_journal_recover "${FIX_ROOT}"
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" applied
}
