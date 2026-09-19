#!/usr/bin/env bats
load '../test_helper'
load '../../fixtures/pair_helpers'
setup() {
  pair_test_setup
  . "${HARBOR_ROOT}/lib/access.sh"
  harbor_log_open "${FIX_ROOT}/harbor.log" 0600
  FIX_CONFIG="${FIX_HOME}/.config/harbor/config"
  FIX_PROBE="${BATS_TEST_TMPDIR}/probe"
  harbor_access_probe_path() { printf '%s' "${FIX_PROBE}"; }
  export FIX_OFF_RC=0 FIX_CONNECT=healthy
  FIX_SERVE_ABSENT="${HARBOR_ROOT}/tests/fixtures/tailscale/serve-status/absent"
  export FIX_SERVE_ABSENT
  rm -f "${FIX_PAIR_DIR}/connect.override"
  cat >"${BATS_TEST_TMPDIR}/bin/tailscale" <<'SH'
#!/bin/bash
set -euo pipefail
printf 'tailscale %s\n' "$*" >>"${FIX_SHIM_LOG}"
if [ "$#" = 2 ] && [ "${1}" = serve ] && [ "${2}" = status ]; then
  cat "${FIX_PAIR_DIR}/serve"
elif [ "$#" = 3 ] && [ "${1}" = serve ] && [ "${2}" = --https=443 ] && [ "${3}" = off ]; then
  # A shim that only reports success is a shim that cannot tell a reversion from
  # a vendor that did nothing, which is the distinction the code now checks for.
  # FIX_OFF_APPLIES=no is the vendor Corrections 35 and 36 measured: exit 0, world
  # unchanged.
  if [ "${FIX_OFF_RC}" = 0 ] && [ "${FIX_OFF_APPLIES:-yes}" = yes ]; then
    cp "${FIX_SERVE_ABSENT}" "${FIX_PAIR_DIR}/serve"
  fi
  exit "${FIX_OFF_RC}"
else
  exit 97
fi
SH
  cat >"${FIX_HOME}/.local/harbor/npm/bin/t3" <<'SH'
#!/bin/bash
set -euo pipefail
printf 't3 %s\n' "$*" >>"${FIX_SHIM_LOG}"
if [ "$#" = 1 ] && [ "${1}" = --version ]; then
  printf 't3 v%s\n' "${FIX_T3_VERSION}"
elif [ "$#" = 3 ] && [ "${1}" = connect ] && [ "${2}" = status ] && [ "${3}" = --json ]; then
  fix_connect="${FIX_CONNECT}"
  if [ -f "${FIX_PAIR_DIR}/connect.override" ]; then
    . "${FIX_PAIR_DIR}/connect.override"
    fix_connect="${FIX_CONNECT}"
  fi
  cat "${HARBOR_ROOT}/tests/fixtures/t3/connect-status/${fix_connect}"
elif [ "$#" = 2 ] && [ "${1}" = connect ] && [ "${2}" = unlink ]; then
  # Same reason as the serve shim: the unlink has to move the world the observer
  # reads, or "the entry was reverted" is asserted against a node that still says
  # linked.
  if [ "${FIX_UNLINK_APPLIES:-yes}" = yes ]; then
    printf 'FIX_CONNECT=needs-link\n' >"${FIX_PAIR_DIR}/connect.override"
  fi
  exit 0
else
  exit 97
fi
SH
}
teardown() { harbor_lock_release "${FIX_ROOT}"; }
seed_entry() { fixture_entry "${FIX_ROOT}" "$@"; }
probe_fixture() {
  # The gate reads the two measured_ pins as well as the result, so a fixture that
  # writes only a result is a fixture that can never say supported. Taking the
  # values from the lock the code will compare against keeps the fixture honest
  # about what it is asserting: the result word, not a stale pin.
  printf 'result=%s\nmeasured_tailscale_version=%s\nmeasured_t3_version=%s\n' "${1}" \
    "$(sed -n 's/^tailscale_version=//p' "${HARBOR_ROOT}/versions.lock")" \
    "$(sed -n 's/^t3_version=//p' "${HARBOR_ROOT}/versions.lock")" >"${FIX_PROBE}"
}
connect_status_fixture() { export FIX_CONNECT="${1}"; }
serve_off_shim() { export FIX_OFF_RC=97; }
# The vendor that reports success and changes nothing.
serve_off_noop() { export FIX_OFF_APPLIES=no; }
connect_unlink_noop() { export FIX_UNLINK_APPLIES=no; }

@test "each mode owns exactly the ops it journals" {
  assert_equal "$(harbor_access_mode_ops connect)" 't3-connect-link'
  assert_equal "$(harbor_access_mode_ops tailnet)" 'tailscale-serve'
  assert_equal "$(harbor_access_mode_ops ssh)" ''
}

@test "a created serve entry whose mapping still matches is reverted with the vendor's inverse" {
  seed_entry 0001 tailscale-serve https-443 created applied \
    '"absent"' '"https:443 -> http://loopback:3773"'
  serve_fixture vendor-443
  run harbor_access_revert "${FIX_ROOT}" tailnet
  assert_success
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" reverted
  assert_regex "$(cat "${FIX_SHIM_LOG}")" 'tailscale serve --https=443 off'
}

@test "an observed entry is never reverted and the vendor is never called for it" {
  seed_entry 0001 tailscale-serve https-443 observed applied \
    '"https:443 -> http://loopback:3773"' '"https:443 -> http://loopback:3773"'
  serve_fixture vendor-443
  run harbor_access_revert "${FIX_ROOT}" tailnet
  assert_success
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" applied
  assert_output --partial 'Harbor did not create'
  refute_regex "$(cat "${FIX_SHIM_LOG}")" 'serve --https=443 off'
}

@test "a created entry whose mapping has changed is reported and left alone" {
  seed_entry 0001 tailscale-serve https-443 created applied \
    '"absent"' '"https:443 -> http://loopback:3773"'
  serve_fixture foreign-443
  run harbor_access_revert "${FIX_ROOT}" tailnet
  assert_equal "${status}" 1
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" applied
  assert_output --partial 'has changed since Harbor created it'
  refute_regex "$(cat "${FIX_SHIM_LOG}")" 'serve --https=443 off'
}

@test "newest first, and the inverse is never run twice for one artifact" {
  # Two entries recording the same link is the shape a crashed-and-rerun session
  # leaves. Once 0002's unlink has actually moved the world, 0001's recorded
  # post_state no longer describes what is there -- and the rule that a created
  # entry is reverted only while the world still equals its post_state is exactly
  # what stops Harbor unlinking a second time on behalf of an entry whose
  # artifact is already gone.
  seed_entry 0001 t3-connect-link connect created applied '"false"' '"true"'
  seed_entry 0002 t3-connect-link connect created applied '"false"' '"true"'
  connect_status_fixture healthy
  run harbor_access_revert "${FIX_ROOT}" connect
  # Attended, because 0001 was reported rather than reverted.
  assert_equal "${status}" 1
  assert_equal "$(grep -c 'connect unlink' "${FIX_SHIM_LOG}")" 1
  assert_equal "$(entry_phase "${FIX_ROOT}" 0002)" reverted
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" applied
  assert_output --partial 'has changed since Harbor created it'
  # Newest first is what made that the order: 0002 is the one that ran.
  assert_regex "$(cat "${FIX_ROOT}/harbor.log")" '0002-.*reverted'
  refute_regex "$(cat "${FIX_ROOT}/harbor.log")" '0001-.*reverted'
}

@test "an inverse that reports success and changes nothing is not recorded as a reversion" {
  # The vendor Corrections 35 and 36 measured: exit 0, world untouched. Recording
  # reverted here would be the worst of both -- the mapping is still published,
  # and reverted is the one phase harbor_journal_recover skips, so nothing would
  # ever come back to it and a later run would meet the mapping as a stranger's.
  seed_entry 0001 tailscale-serve https-443 created applied \
    '"absent"' '"https:443 -> http://loopback:3773"'
  serve_fixture vendor-443
  serve_off_noop
  run harbor_access_revert "${FIX_ROOT}" tailnet
  assert_equal "${status}" 1
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" applied
  assert_output --partial 'reported success and changed nothing'
  assert_equal "$(grep -c 'serve --https=443 off' "${FIX_SHIM_LOG}")" 1
}

@test "a switch whose previous mode was not fully unwound exits 1, not 0" {
  config_fixture tailnet
  probe_fixture supported
  seed_entry 0001 tailscale-serve https-443 created applied \
    '"absent"' '"https:443 -> http://loopback:3773"'
  serve_fixture vendor-443
  serve_off_noop
  run access_cmd set connect
  assert_equal "${status}" 1
  assert_output --partial access.previous_mode_attended
  assert_output --partial 'may still be reachable the old way'
  # The switch itself still happened: the attended work is about the old mode.
  assert_equal "$(cat "${FIX_CONFIG}")" access_mode=connect
}

@test "an inverse Harbor cannot verify afterwards is exit 2, and the entry stays applied" {
  seed_entry 0001 tailscale-serve https-443 created applied \
    '"absent"' '"https:443 -> http://loopback:3773"'
  serve_fixture vendor-443
  # The first observation, before the inverse, must succeed; only the confirming
  # read fails. A counter in a file is the only way to make one shim answer twice.
  printf '0' >"${FIX_PAIR_DIR}/observe.count"
  harbor_journal_observe() {
    local n
    n="$(cat "${FIX_PAIR_DIR}/observe.count")"
    printf '%s' "$((n + 1))" >"${FIX_PAIR_DIR}/observe.count"
    [ "${n}" = 0 ] || return 97
    printf '"https:443 -> http://loopback:3773"'
  }
  run harbor_access_revert "${FIX_ROOT}" tailnet
  assert_equal "${status}" 2
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" applied
  assert_output --partial access.revert_unverifiable
}

@test "another mode's entries are not touched" {
  seed_entry 0001 tailscale-serve https-443 created applied \
    '"absent"' '"https:443 -> http://loopback:3773"'
  serve_fixture vendor-443
  run harbor_access_revert "${FIX_ROOT}" connect
  assert_success
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" applied
  refute_regex "$(cat "${FIX_SHIM_LOG}")" 'serve --https=443 off'
}

@test "the revert guard is not vacuous" {
  # Correction 30: the three refutations above have never failed. Prove the
  # positive form reaches the shim log in the one arm that must call the vendor.
  seed_entry 0001 tailscale-serve https-443 created applied \
    '"absent"' '"https:443 -> http://loopback:3773"'
  serve_fixture vendor-443
  harbor_access_revert "${FIX_ROOT}" tailnet
  assert_equal "$(grep -c 'serve --https=443 off' "${FIX_SHIM_LOG}")" 1
}

@test "modified ownership is not permission to remove a Serve mapping" {
  seed_entry 0001 tailscale-serve https-443 modified applied \
    '"absent"' '"https:443 -> http://loopback:3773"'
  serve_fixture vendor-443
  run harbor_access_revert "${FIX_ROOT}" tailnet
  assert_success
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" applied
  refute_regex "$(cat "${FIX_SHIM_LOG}")" 'serve --https=443 off'
}

@test "a prepared entry is left for recovery, never reverted by a mode switch" {
  # The phase guard is the whole of this. harbor pair leaves a prepared
  # tailscale-serve entry exactly when it could not tell whether the vendor's
  # surviving child would land the mapping, and harbor_journal_recover is the
  # only thing entitled to decide it. Reverting it here would run the vendor's
  # inverse on a mapping whose ownership is still open and then mark the entry
  # reverted, which recovery skips -- the undecided case resolved by erasing the
  # question rather than answering it.
  seed_entry 0001 tailscale-serve https-443 created prepared \
    '"absent"' '"https:443 -> http://loopback:3773"'
  serve_fixture vendor-443
  run harbor_access_revert "${FIX_ROOT}" tailnet
  assert_success
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" prepared
  refute_regex "$(cat "${FIX_SHIM_LOG}")" 'serve --https=443 off'
}

@test "an already reverted entry is not reverted a second time" {
  seed_entry 0001 t3-connect-link connect created reverted '"false"' '"true"'
  connect_status_fixture healthy
  run harbor_access_revert "${FIX_ROOT}" connect
  assert_success
  refute_regex "$(cat "${FIX_SHIM_LOG}")" 'connect unlink'
}

@test "switching away from ssh runs no inverse, because ssh journals nothing" {
  # ssh's op list is empty by design (section 5.5: nothing on the node beyond
  # bootstrap and the vendor service), so a switch away from it has nothing of
  # its own to unwind -- and must not reach for another mode's entries to find
  # something to do.
  seed_entry 0001 tailscale-serve https-443 created applied \
    '"absent"' '"https:443 -> http://loopback:3773"'
  serve_fixture vendor-443
  run harbor_access_revert "${FIX_ROOT}" ssh
  assert_success
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" applied
  refute_regex "$(cat "${FIX_SHIM_LOG}")" 'serve --https=443 off'
}

@test "an observer failure is broken, never a raw vendor exit" {
  seed_entry 0001 tailscale-serve https-443 created applied \
    '"absent"' '"https:443 -> http://loopback:3773"'
  harbor_observe_op_tailscale_serve() { return 97; }
  run harbor_access_revert "${FIX_ROOT}" tailnet
  assert_equal "${status}" 2
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" applied
  refute_regex "$(cat "${FIX_SHIM_LOG}")" 'serve --https=443 off'
}

@test "get prints the configured mode" {
  config_fixture connect
  run access_cmd get
  assert_success
  assert_output connect
}

@test "setting the mode already configured changes nothing and says so" {
  config_fixture connect
  run access_cmd set connect
  assert_success
  assert_output --partial 'already connect'
  assert_equal "$(ls -A "${FIX_ROOT}/journal" | wc -l | tr -d ' ')" 0
}

@test "switching reverts the old mode's entries before it writes the new config" {
  config_fixture tailnet
  probe_fixture supported
  seed_entry 0001 tailscale-serve https-443 created applied \
    '"absent"' '"https:443 -> http://loopback:3773"'
  serve_fixture vendor-443
  run access_cmd set connect
  assert_success
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" reverted
  assert_equal "$(cat "${FIX_CONFIG}")" access_mode=connect
  # Order: the revert's log line precedes the config write's journal entry.
  assert_regex "$(cat "${FIX_ROOT}/harbor.log")" '0001-.*reverted(.|\n)*config-file'
}

@test "a failed revert leaves the old mode configured, not a half-switched node" {
  config_fixture tailnet
  probe_fixture supported
  seed_entry 0001 tailscale-serve https-443 created applied \
    '"absent"' '"https:443 -> http://loopback:3773"'
  serve_fixture vendor-443
  serve_off_shim failure
  run access_cmd set connect
  assert_equal "${status}" 2
  assert_output --partial 'rerun the intended harbor access set command'
  assert_equal "$(cat "${FIX_CONFIG}")" access_mode=tailnet
}

@test "switching to tailnet is refused while the revalidation is unrecorded" {
  config_fixture connect
  probe_fixture unsupported
  run access_cmd set tailnet
  assert_equal "${status}" 3
  assert_output --partial 'has not been verified on the pinned tailscale and t3 versions'
  assert_equal "$(cat "${FIX_CONFIG}")" access_mode=connect
}

@test "each new mode reports the attended step it still needs" {
  config_fixture connect
  probe_fixture supported
  connect_status_fixture needs-link
  run access_cmd set tailnet
  assert_success
  assert_output --partial 'harbor pair'
  config_fixture tailnet
  run access_cmd set connect
  assert_success
  assert_output --partial 'harbor auth connect'
  config_fixture connect
  run access_cmd set ssh
  assert_success
  assert_output --partial 'no further step on this node'
}

@test "set refuses an unknown mode without touching the config" {
  config_fixture connect
  run access_cmd set wireguard
  assert_equal "${status}" 3
  assert_equal "$(cat "${FIX_CONFIG}")" access_mode=connect
}

@test "set with no mode, and get with one, are usage errors" {
  run access_cmd set
  assert_equal "${status}" 3
  run access_cmd get connect
  assert_equal "${status}" 3
}

access_cmd() (
  harbor_lock_release "${FIX_ROOT}"
  harbor_install_traps
  harbor_access_cmd "$@" || exit "$?"
  HARBOR_COMPLETED=1
)

@test "interrupted config write stays prepared and recovery finishes it" {
  config_fixture connect
  HARBOR_TEST_HOOKS=1 HARBOR_FAIL_AFTER=config-file run access_cmd set ssh
  assert_equal "${status}" 4
  assert_equal "$(cat "${FIX_CONFIG}")" access_mode=ssh
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" prepared
  run access_cmd set ssh
  assert_success
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" applied
  assert [ ! -d "${FIX_ROOT}/lock.d" ]
}
