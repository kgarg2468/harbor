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

@test "MagicDNS off is caught on the vendor's own shape, where the suffix is still there" {
  # The shape the pinned Tailscale actually produces. From
  # ipn/ipnstate/ipnstate.go at v1.102.3: CurrentTailnet.MagicDNSSuffix "should
  # be populated regardless of whether a domain has MagicDNS enabled", and the
  # top-level MagicDNSSuffix is "Deprecated: use CurrentTailnet.MagicDNSSuffix
  # instead". A check for a non-empty suffix therefore passes here -- on exactly
  # the tailnet it exists to refuse -- and setup goes on to write an ssh block
  # for a name that does not resolve. MagicDNSEnabled is the flag.
  fixture '{"BackendState":"Running","MagicDNSSuffix":"TAILNET.ts.net","CurrentTailnet":{"MagicDNSSuffix":"TAILNET.ts.net","MagicDNSEnabled":false},"Peer":{}}'
  run harbor_client_preflight "${FLAT}"
  assert_failure 3
  assert_output --partial 'MagicDNS'
}

@test "MagicDNS on in the current tailnet passes" {
  fixture '{"BackendState":"Running","MagicDNSSuffix":"TAILNET.ts.net","CurrentTailnet":{"MagicDNSSuffix":"TAILNET.ts.net","MagicDNSEnabled":true},"Peer":{}}'
  run harbor_client_preflight "${FLAT}"
  assert_success
}

@test "a client that reports no flag at all is judged on the suffix it does report" {
  # Absent is not false: a status document without the field is one Harbor cannot
  # read the flag out of, and refusing it would turn an unreadable answer into a
  # verdict about the tailnet. The legacy suffix is what is left to go on.
  fixture '{"BackendState":"Running","MagicDNSSuffix":"TAILNET.ts.net","Peer":{}}'
  run harbor_client_preflight "${FLAT}"
  assert_success
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

@test "two peers calling themselves the same thing do not decide which node is reached" {
  # Tailscale documents PeerStatus.HostName as "not a DNS name or necessarily
  # unique" (ipnstate.go, v1.102.3) and resolves the collision in DNSName, where
  # the loser becomes harbor-node-1. Keyed off HostName this returns whichever
  # peer the flattener emitted first -- here harbor-node-1, listed first on
  # purpose -- and the ssh block points at a machine chosen by iteration order.
  fixture '{"BackendState":"Running","MagicDNSSuffix":"TAILNET.ts.net","Peer":{"k1":{"HostName":"harbor-node","DNSName":"harbor-node-1.TAILNET.ts.net."},"k2":{"HostName":"harbor-node","DNSName":"harbor-node.TAILNET.ts.net."}}}'
  harbor_client_preflight "${FLAT}"
  run harbor_client_magicdns "${FLAT}" harbor-node
  assert_success
  assert_output 'harbor-node.TAILNET.ts.net'
}

@test "the other machine in that collision is still reachable by the name it actually has" {
  fixture '{"BackendState":"Running","MagicDNSSuffix":"TAILNET.ts.net","Peer":{"k1":{"HostName":"harbor-node","DNSName":"harbor-node-1.TAILNET.ts.net."},"k2":{"HostName":"harbor-node","DNSName":"harbor-node.TAILNET.ts.net."}}}'
  harbor_client_preflight "${FLAT}"
  run harbor_client_magicdns "${FLAT}" harbor-node-1
  assert_success
  assert_output 'harbor-node-1.TAILNET.ts.net'
}

@test "a machine shared in from another tailnet is not mistaken for this tailnet's node" {
  # A shared-in machine sits in the same Peer map and carries the *sharer's*
  # MagicDNS suffix, because DNSName "has the form host.<MagicDNSSuffix>." and the
  # suffix is theirs. Matched on the first label alone, a colleague who happens to
  # have named a machine harbor-node wins whenever the flattener emits them first,
  # and Harbor writes an ssh block -- and later points an HTTPS check -- at a node
  # in someone else's tailnet. The shared peer is listed first here for that
  # reason.
  fixture '{"BackendState":"Running","MagicDNSSuffix":"TAILNET.ts.net","CurrentTailnet":{"MagicDNSSuffix":"TAILNET.ts.net","MagicDNSEnabled":true},"Peer":{"k1":{"HostName":"harbor-node","DNSName":"harbor-node.SHARED.ts.net."},"k2":{"HostName":"harbor-node","DNSName":"harbor-node.TAILNET.ts.net."}}}'
  harbor_client_preflight "${FLAT}"
  run harbor_client_magicdns "${FLAT}" harbor-node
  assert_success
  assert_output 'harbor-node.TAILNET.ts.net'
}

@test "a tailnet holding only the shared machine has no node of that name at all" {
  fixture '{"BackendState":"Running","MagicDNSSuffix":"TAILNET.ts.net","CurrentTailnet":{"MagicDNSSuffix":"TAILNET.ts.net","MagicDNSEnabled":true},"Peer":{"k1":{"HostName":"harbor-node","DNSName":"harbor-node.SHARED.ts.net."}}}'
  harbor_client_preflight "${FLAT}"
  run harbor_client_magicdns "${FLAT}" harbor-node
  assert_failure 3
  assert_output --partial 'client.node_absent'
}

@test "a node renamed in the admin console is absent, not unnamed" {
  # HostName is whatever the machine calls itself and does not follow a rename, so
  # a peer can hold HostName harbor-node and a DNSName under a different name for
  # as long as nobody changes the machine's own hostname. It has a MagicDNS name;
  # telling the operator it has none sends them to check MagicDNS and registration
  # over a node that is registered and named. The name they asked for is simply
  # not in this tailnet.
  fixture '{"BackendState":"Running","MagicDNSSuffix":"TAILNET.ts.net","CurrentTailnet":{"MagicDNSSuffix":"TAILNET.ts.net","MagicDNSEnabled":true},"Peer":{"k1":{"HostName":"harbor-node","DNSName":"renamed-node.TAILNET.ts.net."}}}'
  harbor_client_preflight "${FLAT}"
  run harbor_client_magicdns "${FLAT}" harbor-node
  assert_failure 3
  assert_output --partial 'client.node_absent'
  refute_output --partial 'client.node_unnamed'
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
