#!/usr/bin/env bats
# fleet/tests/unit/lib/client_sshconf.bats
setup() {
  [ "$(uname -s)" = Darwin ] || skip 'the client runs on macOS only'
  load '../test_helper'
  harbor_load_libs
  . "${HARBOR_ROOT}/lib/client.sh"
}

@test "the block is exactly the three directives section 5.5 names" {
  run harbor_client_conf_body harbor-node.TAILNET.ts.net harbor
  assert_success
  assert_line 'Host harbor-node'
  assert_line '  HostName harbor-node.TAILNET.ts.net'
  assert_line '  User harbor'
  assert_line '  IdentitiesOnly yes'
}

@test "the file is written 0600 and its bytes are the body" {
  local out="${BATS_TEST_TMPDIR}/harbor.conf"
  harbor_client_conf_write "${out}" harbor-node.TAILNET.ts.net harbor
  assert_equal 600 "$(stat -f '%OLp' "${out}")"
  assert_equal "$(harbor_client_conf_body harbor-node.TAILNET.ts.net harbor)" "$(cat "${out}")"
}

@test "a rewrite replaces the file rather than appending to it" {
  local out="${BATS_TEST_TMPDIR}/harbor.conf"
  # The two writes have to differ or this proves nothing, and the tailnet suffix
  # cannot be the thing that differs: tests/lint/placeholder_scan.sh permits
  # exactly one MagicDNS name in this repository. The node name carries it.
  harbor_client_conf_write "${out}" harbor-node.TAILNET.ts.net harbor
  harbor_client_conf_write "${out}" other-node.TAILNET.ts.net harbor
  assert_equal 1 "$(grep -c '^Host harbor-node$' "${out}")"
  assert_equal '  HostName other-node.TAILNET.ts.net' "$(sed -n 2p "${out}")"
}

@test "no temp file survives a successful write" {
  local out="${BATS_TEST_TMPDIR}/harbor.conf"
  harbor_client_conf_write "${out}" harbor-node.TAILNET.ts.net harbor
  assert_equal 1 "$(find "${BATS_TEST_TMPDIR}" -maxdepth 1 -type f | wc -l | tr -d ' ')"
}

@test "a permissive umask does not make the file readable by anyone else" {
  local out="${BATS_TEST_TMPDIR}/harbor.conf"
  (
    umask 000
    harbor_client_conf_write "${out}" harbor-node.TAILNET.ts.net harbor
  )
  assert_equal 600 "$(stat -f '%OLp' "${out}")"
}
