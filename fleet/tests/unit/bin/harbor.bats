#!/usr/bin/env bats
load '../test_helper'
load '../../fixtures/pair_helpers'
setup() {
  pair_test_setup
  # Slice 5e owns mode validation and the support gate. Exercise the wrapper
  # behind those seams here; the real dispatcher refusal is tested separately.
  harbor_config_validate_mode() { :; }
  harbor_access_require_tailnet_supported() { :; }
  harbor_auth_refuse_root() { [ "${HARBOR_FAKE_UID:-1000}" != 0 ] || exit 3; }
}
teardown() { harbor_lock_release "${FIX_ROOT}"; }
harbor_usage() { "${HARBOR}" help; }
harbor_pair_cmd_test() (
  harbor_install_traps
  harbor_pair_cmd "$@" || exit "$?"
  HARBOR_COMPLETED=1
)

@test "pair refuses a node whose access mode is not tailnet" {
  config_fixture connect
  run harbor_pair_cmd_test
  assert_equal "${status}" 3
  assert_output --partial 'access_mode=connect'
  assert_output --partial 'harbor access set tailnet'
  refute_regex "$(cat "${FIX_SHIM_LOG}")" 't3 pair'
}

@test "pair refuses root" {
  config_fixture tailnet
  HARBOR_FAKE_UID=0 run harbor_pair_cmd_test
  assert_equal "${status}" 3
}

@test "pair takes the operator lock and recovers before it decides anything" {
  config_fixture tailnet
  serve_fixture absent
  runtime_fixture healthy
  pair_shim success
  serve_fixture_after_pair vendor-443
  descriptor_shim_for loopback valid
  descriptor_shim_for magicdns valid
  run harbor_pair_cmd_test
  assert_success
  assert_regex "$(cat "${FIX_ROOT}/harbor.log")" 'command pair'
  assert_regex "$(cat "${FIX_ROOT}/harbor.log")" 'step recovery-scan'
  assert [ ! -e "${FIX_ROOT}/lock.d" ]
}

@test "pair takes its MagicDNS name from the vendor, not from an assumed hostname" {
  config_fixture tailnet
  serve_fixture absent
  runtime_fixture healthy
  tailscale_status_fixture magicdns-name 'other-node.TAILNET.ts.net'
  pair_shim success
  serve_fixture_after_pair vendor-443
  descriptor_shim_for loopback valid
  descriptor_shim_for magicdns valid
  run harbor_pair_cmd_test
  # other-node, not harbor-node: the fixture deliberately does not match the
  # hostname bootstrap would have chosen, so a name Harbor assembled instead of
  # read cannot pass this by coincidence.
  assert_regex "$(cat "${FIX_SHIM_LOG}")" 'https://other-node\.TAILNET\.ts\.net/'
}

@test "the usage text lists pair" {
  run harbor_usage
  assert_output --partial 'pair'
  assert_output --partial 'tailnet'
}

@test "access dispatch reads the real config path and documents all modes" {
  config_fixture ssh
  run "${HARBOR}" access get
  assert_success
  assert_output ssh
  run "${HARBOR}" help
  assert_success
  assert_output --partial 'access get'
  assert_output --partial 'access set <connect|tailnet|ssh>'
}

@test "access dispatch refuses unmeasured tailnet before mutation" {
  config_fixture connect
  run "${HARBOR}" access set tailnet
  assert_equal "${status}" 3
  assert_output --partial access.tailnet_unverified
  assert_equal "$(cat "${FIX_HOME}/.config/harbor/config")" access_mode=connect
}
