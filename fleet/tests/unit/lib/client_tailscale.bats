#!/usr/bin/env bats
# fleet/tests/unit/lib/client_tailscale.bats
setup() {
  [ "$(uname -s)" = Darwin ] || skip 'the client runs on macOS only'
  load '../test_helper'
  harbor_load_libs
  . "${HARBOR_ROOT}/lib/client.sh"
  HARBOR_CLIENT_TAILSCALE="${BATS_TEST_TMPDIR}/tailscale"
  export HARBOR_CLIENT_TAILSCALE
  FLAT="${BATS_TEST_TMPDIR}/flat"
}

# The shim answers with whatever fixture the test selected. Writing it as a file
# rather than a function matters: harbor_client_tailscale_status runs it as a
# command, and a function would let a bug that forgets to invoke it pass.
shim() {
  cat >"${HARBOR_CLIENT_TAILSCALE}" <<EOF
#!/bin/bash
cat "${1}"
EOF
  chmod 0755 "${HARBOR_CLIENT_TAILSCALE}"
}

fixture() {
  printf '%s' "${1}" >"${BATS_TEST_TMPDIR}/status.json"
  shim "${BATS_TEST_TMPDIR}/status.json"
}

@test "a missing CLI is a precondition naming where the app puts it" {
  rm -f "${HARBOR_CLIENT_TAILSCALE}"
  run harbor_client_preflight "${FLAT}"
  assert_failure 3
  assert_output --partial 'Tailscale'
}

@test "a backend that is not Running is a precondition, not a failure to read" {
  fixture '{"BackendState":"NeedsLogin","MagicDNSSuffix":"TAILNET.ts.net","Peer":{}}'
  run harbor_client_preflight "${FLAT}"
  assert_failure 3
  assert_output --partial 'NeedsLogin'
}

@test "MagicDNS off is a precondition, which section 5.5 names" {
  fixture '{"BackendState":"Running","MagicDNSSuffix":"","Peer":{}}'
  run harbor_client_preflight "${FLAT}"
  assert_failure 3
  assert_output --partial 'MagicDNS'
}

@test "a logged-in client with MagicDNS on passes and leaves the status flattened" {
  fixture '{"BackendState":"Running","MagicDNSSuffix":"TAILNET.ts.net","Peer":{"k1":{"HostName":"harbor-node","DNSName":"harbor-node.TAILNET.ts.net."}}}'
  run harbor_client_preflight "${FLAT}"
  assert_success
  harbor_client_preflight "${FLAT}"
  assert_equal 'Running' "$(harbor_client_json_field "${FLAT}" BackendState)"
}

@test "the node's MagicDNS name comes back without its trailing dot" {
  fixture '{"BackendState":"Running","MagicDNSSuffix":"TAILNET.ts.net","Peer":{"k1":{"HostName":"other","DNSName":"other.TAILNET.ts.net."},"k2":{"HostName":"harbor-node","DNSName":"harbor-node.TAILNET.ts.net."}}}'
  harbor_client_preflight "${FLAT}"
  run harbor_client_magicdns "${FLAT}" harbor-node
  assert_success
  assert_output 'harbor-node.TAILNET.ts.net'
}

@test "a tailnet with no such peer is a precondition, never an empty host name" {
  fixture '{"BackendState":"Running","MagicDNSSuffix":"TAILNET.ts.net","Peer":{"k1":{"HostName":"other","DNSName":"other.TAILNET.ts.net."}}}'
  harbor_client_preflight "${FLAT}"
  run harbor_client_magicdns "${FLAT}" harbor-node
  assert_failure 3
  assert_output --partial 'harbor-node'
}

@test "a status the CLI cannot produce is a precondition, not a crash" {
  cat >"${HARBOR_CLIENT_TAILSCALE}" <<'EOF'
#!/bin/bash
printf 'failed to connect to local tailscaled\n' >&2
exit 1
EOF
  chmod 0755 "${HARBOR_CLIENT_TAILSCALE}"
  run harbor_client_preflight "${FLAT}"
  assert_failure 3
}

@test "a peer that matches but carries no MagicDNS name is a precondition, not an empty name" {
  # The peer is present, so the "no such node" arm never fires -- and returning
  # the empty string here would put an empty HostName in the ssh block, which is
  # the exact outcome this function exists to prevent.
  fixture '{"BackendState":"Running","MagicDNSSuffix":"TAILNET.ts.net","Peer":{"k1":{"HostName":"harbor-node","DNSName":""}}}'
  harbor_client_preflight "${FLAT}"
  run harbor_client_magicdns "${FLAT}" harbor-node
  assert_failure 3
  assert_output --partial 'harbor-node'
}
