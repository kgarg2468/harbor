#!/usr/bin/env bats
load '../test_helper'
load '../../fixtures/pair_helpers'
setup() { pair_test_setup; }
teardown() { harbor_lock_release "${FIX_ROOT}"; }

@test "no mapping means create" {
  serve_fixture absent
  runtime_fixture healthy
  assert_equal "$(harbor_pair_precheck "${FIX_ROOT}" "${FIX_HOME}" "${MAGICDNS}")" create
}

@test "a mapping that passes the environment check means reuse, journaled observed" {
  serve_fixture vendor-443
  runtime_fixture healthy
  descriptor_shim_for loopback valid
  descriptor_shim_for magicdns valid
  assert_equal "$(harbor_pair_precheck "${FIX_ROOT}" "${FIX_HOME}" "${MAGICDNS}")" reuse
  assert_equal "$(entry_raw "${FIX_ROOT}" 0001 op)" '"tailscale-serve"'
  assert_equal "$(entry_raw "${FIX_ROOT}" 0001 ownership)" '"observed"'
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" applied
}

@test "a foreign mapping exits 2 without calling the vendor and without touching Serve" {
  serve_fixture vendor-443
  runtime_fixture healthy
  descriptor_shim_for loopback valid
  descriptor_shim_for magicdns valid-other-id
  run harbor_pair_precheck "${FIX_ROOT}" "${FIX_HOME}" "${MAGICDNS}"
  assert_equal "${status}" 2
  assert_output --partial 'fronts something other than this node'
  # Both halves of the invariant, each asserted positively somewhere in this file
  # so the refutations cannot pass on a misspelled needle.
  refute_regex "$(cat "${FIX_SHIM_LOG}")" 't3 pair'
  refute_regex "$(cat "${FIX_SHIM_LOG}")" 'tailscale serve --'
  # And the remediation names the vendor command rather than another token.
  assert_output --partial 'tailscale serve status'
  refute_output --partial 'harbor pair'
}

@test "an unknown environment check exits 2, because unknown is never permission to act" {
  serve_fixture vendor-443
  runtime_fixture healthy
  descriptor_shim_for loopback valid
  descriptor_shim_for magicdns unreachable
  run harbor_pair_precheck "${FIX_ROOT}" "${FIX_HOME}" "${MAGICDNS}"
  assert_equal "${status}" 2
  refute_regex "$(cat "${FIX_SHIM_LOG}")" 't3 pair'
}

@test "a mapping the adapter cannot normalize exits 2" {
  serve_fixture garbage
  runtime_fixture healthy
  run harbor_pair_precheck "${FIX_ROOT}" "${FIX_HOME}" "${MAGICDNS}"
  assert_equal "${status}" 2
  refute_regex "$(cat "${FIX_SHIM_LOG}")" 't3 pair'
}

@test "a Funnel exposure exits 2 in every arm, whoever created it" {
  # Section 3.3: any Funnel exposure on any port makes this exit 2.
  serve_fixture funnel
  runtime_fixture healthy
  run harbor_pair_precheck "${FIX_ROOT}" "${FIX_HOME}" "${MAGICDNS}"
  assert_equal "${status}" 2
  assert_output --partial 'Funnel'
  refute_regex "$(cat "${FIX_SHIM_LOG}")" 't3 pair'
}

@test "the vendor is invoked in exactly one arm, which proves the refutations above" {
  # Correction 30: six refutations of "t3 pair" above, none of which has ever
  # failed. This is the positive form, and it is what makes them meaningful.
  serve_fixture absent
  runtime_fixture healthy
  descriptor_shim_for loopback valid
  descriptor_shim_for magicdns valid
  pair_shim success
  run harbor_pair "${FIX_ROOT}" "${FIX_HOME}" "${MAGICDNS}"
  assert_success
  assert_regex "$(cat "${FIX_SHIM_LOG}")" 't3 pair --tailscale'
}

@test "the prediction is built from the runtime port, in the normalized form" {
  runtime_fixture healthy
  assert_equal "$(harbor_pair_prediction "${FIX_HOME}")" \
    'https:443 -> http://loopback:3773'
}

@test "a node with no locatable T3 server cannot be paired, and says which reason" {
  run harbor_pair_prediction "${FIX_HOME}"
  assert_equal "${status}" 2
  assert_output --partial 'not-running'
}

@test "the entry is prepared with the prediction before the vendor runs" {
  serve_fixture absent
  runtime_fixture healthy
  pair_shim success
  HARBOR_TEST_HOOKS=1 HARBOR_FAIL_AFTER=pair-prepared \
    run harbor_pair "${FIX_ROOT}" "${FIX_HOME}" "${MAGICDNS}"
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" prepared
  assert_equal "$(entry_raw "${FIX_ROOT}" 0001 pre_state)" '"absent"'
  assert_equal "$(entry_raw "${FIX_ROOT}" 0001 post_state)" \
    '"https:443 -> http://loopback:3773"'
  refute_regex "$(cat "${FIX_SHIM_LOG}")" 't3 pair'
}

@test "a mapping matching the prediction with a passing check is created and exits 0" {
  serve_fixture absent
  runtime_fixture healthy
  pair_shim success
  serve_fixture_after_pair vendor-443
  descriptor_shim_for loopback valid
  descriptor_shim_for magicdns valid
  run harbor_pair "${FIX_ROOT}" "${FIX_HOME}" "${MAGICDNS}"
  assert_success
  assert_equal "$(entry_raw "${FIX_ROOT}" 0001 ownership)" '"created"'
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" applied
}

@test "a created mapping whose check is unknown exits 1 and is never called verified" {
  serve_fixture absent
  runtime_fixture healthy
  pair_shim success
  serve_fixture_after_pair vendor-443
  descriptor_shim_for loopback valid
  descriptor_shim_for magicdns unreachable
  run harbor_pair "${FIX_ROOT}" "${FIX_HOME}" "${MAGICDNS}"
  assert_equal "${status}" 1
  assert_output --partial 'harbor status'
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" applied
  refute_output --partial 'environment check confirms'
}

@test "a created mapping whose check is broken exits 2" {
  serve_fixture absent
  runtime_fixture healthy
  pair_shim success
  serve_fixture_after_pair vendor-443
  descriptor_shim_for loopback valid
  descriptor_shim_for magicdns valid-other-id
  run harbor_pair "${FIX_ROOT}" "${FIX_HOME}" "${MAGICDNS}"
  assert_equal "${status}" 2
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" applied
}

@test "a vendor that created nothing leaves the entry reverted and its own message standing" {
  serve_fixture absent
  runtime_fixture healthy
  pair_shim failure
  serve_fixture_after_pair absent
  run harbor_pair "${FIX_ROOT}" "${FIX_HOME}" "${MAGICDNS}"
  assert_failure
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" reverted
  assert_output --partial 'the vendor could not publish'
}

@test "a mapping that is neither absent nor the prediction is the undecidable case" {
  serve_fixture absent
  runtime_fixture healthy
  pair_shim success
  serve_fixture_after_pair foreign-443
  run harbor_pair "${FIX_ROOT}" "${FIX_HOME}" "${MAGICDNS}"
  assert_equal "${status}" 2
  # Left prepared for the section 3.7 recovery, with both sides printed.
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" prepared
  assert_output --partial 'https:443 -> http://loopback:3773'
  assert_output --partial 'https:443 -> http://loopback:8080'
  assert_output --partial 'harbor journal resolve'
}

@test "an interrupt leaves a prepared entry a later recovery decides by the prediction" {
  serve_fixture absent
  runtime_fixture healthy
  pair_shim success
  HARBOR_TEST_HOOKS=1 HARBOR_FAIL_AFTER=pair-vendor \
    run harbor_pair "${FIX_ROOT}" "${FIX_HOME}" "${MAGICDNS}"
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" prepared
  # The vendor did create the mapping before the crash; recovery recognizes it by
  # the predicted post_state, which is why the prediction is journaled at all.
  serve_fixture vendor-443
  harbor_journal_recover "${FIX_ROOT}"
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" applied
}

@test "a rerun on a healthy paired node mints no pairing token" {
  # Section 3.6: rerunning provision never mints a pairing token, and neither does
  # rerunning pair on a node whose mapping already fronts its own server.
  serve_fixture vendor-443
  runtime_fixture healthy
  descriptor_shim_for loopback valid
  descriptor_shim_for magicdns valid
  run harbor_pair "${FIX_ROOT}" "${FIX_HOME}" "${MAGICDNS}"
  assert_success
  refute_regex "$(cat "${FIX_SHIM_LOG}")" 't3 pair'
}

@test "all rejected mappings refuse through the whole transaction" {
  runtime_fixture healthy
  descriptor_shim_for loopback valid
  descriptor_shim_for magicdns valid
  local fixture
  for fixture in garbage ambiguous-443 no-root-443 funnel; do
    serve_fixture "${fixture}"
    run harbor_pair "${FIX_ROOT}" "${FIX_HOME}" "${MAGICDNS}"
    assert_equal "${status}" 2
    refute_regex "$(cat "${FIX_SHIM_LOG}")" 't3 pair'
    refute_regex "$(cat "${FIX_SHIM_LOG}")" 'tailscale serve --'
  done
}

@test "Funnel on another port refuses both absent and existing 443 arms" {
  runtime_fixture healthy
  descriptor_shim_for loopback valid
  descriptor_shim_for magicdns valid
  local mapping
  for mapping in absent vendor-443; do
    serve_fixture "${mapping}"
    if [ "${mapping}" = absent ]; then : >"${FIX_PAIR_DIR}/serve"; fi
    printf 'https://harbor-node.TAILNET.ts.net:8443 (Funnel on)\n|-- / proxy http://127.0.0.1:9000\n' >>"${FIX_PAIR_DIR}/serve"
    run harbor_pair "${FIX_ROOT}" "${FIX_HOME}" "${MAGICDNS}"
    assert_equal "${status}" 2
    assert_output --partial Funnel
    refute_regex "$(cat "${FIX_SHIM_LOG}")" 't3 pair'
  done
}

@test "mixed listeners reuse the verified 443 mapping without a token" {
  serve_fixture mixed-listeners
  runtime_fixture healthy
  descriptor_shim_for loopback valid
  descriptor_shim_for magicdns valid
  run harbor_pair "${FIX_ROOT}" "${FIX_HOME}" "${MAGICDNS}"
  assert_success
  refute_regex "$(cat "${FIX_SHIM_LOG}")" 't3 pair'
}

@test "vendor streams pass through and stdin comes from the caller" {
  serve_fixture absent
  runtime_fixture healthy
  descriptor_shim_for loopback valid
  descriptor_shim_for magicdns valid
  pair_shim stdin
  run harbor_pair "${FIX_ROOT}" "${FIX_HOME}" "${MAGICDNS}" <<< 'operator answer'
  assert_success
  assert_output --partial 'vendor pairing URL and QR'
  assert_output --partial 'vendor stderr'
  assert_equal "$(cat "${FIX_PAIR_DIR}/answer")" 'operator answer'
  refute_regex "$(cat "${FIX_ROOT}/journal/"*.json)" 'vendor pairing URL'
  assert_regex "$(cat "${FIX_SHIM_LOG}")" 'tailscale serve --'
}

@test "a hung vendor is bounded and post-state decides the journal" {
  runtime_fixture healthy
  descriptor_shim_for loopback valid
  descriptor_shim_for magicdns valid
  pair_shim hang
  local after expected seq=0
  for after in absent vendor-443 foreign-443; do
    seq=$((seq + 1))
    serve_fixture absent
    serve_fixture_after_pair "${after}"
    HARBOR_TEST_HOOKS=1 HARBOR_PAIR_TIMEOUT_SECONDS=1 \
      run harbor_pair "${FIX_ROOT}" "${FIX_HOME}" "${MAGICDNS}"
    case "${after}" in
      # 2, not the vendor's 124: Harbor has five exit codes and a mapping that
      # was meant to be created and was not is what 2 means.
      absent) assert_equal "${status}" 2; expected=reverted ;;
      vendor-443) assert_success; expected=applied ;;
      foreign-443) assert_equal "${status}" 2; expected=prepared ;;
    esac
    assert_equal "$(entry_phase "${FIX_ROOT}" "000${seq}")" "${expected}"
    assert [ -f "${FIX_PAIR_DIR}/vendor.pid" ]
    run kill -0 "$(cat "${FIX_PAIR_DIR}/vendor.pid")"
    assert_failure
  done
}

@test "Funnel introduced by the vendor is refused after journaling the mapping" {
  serve_fixture absent
  runtime_fixture healthy
  pair_shim success
  serve_fixture_after_pair funnel
  descriptor_shim_for loopback valid
  descriptor_shim_for magicdns valid
  run harbor_pair "${FIX_ROOT}" "${FIX_HOME}" "${MAGICDNS}"
  assert_equal "${status}" 2
  assert_output --partial Funnel
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" applied
}

@test "a vendor that exits 0 without creating the mapping is a failed pair, not a success" {
  # The dangerous spelling is harbor_die "${rc}": with rc=0 it prints a failure
  # message and then exits 0, so a caller and CI both read a failed pair as done.
  serve_fixture absent
  runtime_fixture healthy
  pair_shim success
  serve_fixture_after_pair absent
  run harbor_pair "${FIX_ROOT}" "${FIX_HOME}" "${MAGICDNS}"
  assert_equal "${status}" 2
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" reverted
  assert_output --partial 'reported success but left no HTTPS 443 mapping'
}

@test "a passing environment check leaves no reason behind, rather than the verdict" {
  serve_fixture vendor-443
  runtime_fixture healthy
  descriptor_shim_for loopback valid
  descriptor_shim_for magicdns valid
  harbor_pair_environment "${FIX_HOME}" "${MAGICDNS}"
  assert_equal "${HARBOR_PAIR_VERDICT}" pass
  assert_equal "${HARBOR_PAIR_ENVIRONMENT_WHY}" ''
}
