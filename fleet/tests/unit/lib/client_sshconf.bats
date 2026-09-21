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

@test "a write that fails at the rename leaves no copy of the config beside the target" {
  # The rename is made to fail for real rather than stubbed. The target is an
  # unwritable directory, so mv cannot move into it, while the temp file -- which
  # lives in the parent, not the target -- is created and chmodded exactly as it
  # would be on a good run. That is the window the finding is about, and the one
  # a successful-write test cannot reach.
  #
  # An earlier spelling made the target a non-empty directory and proved nothing:
  # mv onto a directory succeeds, moving the file into it, so the write returned
  # 0 and the only nonzero status came from harbor_on_exit's own
  # "terminated before completion" rule. Measured; the mutation check caught it.
  local out="${BATS_TEST_TMPDIR}/harbor.conf"
  mkdir -p "${out}"
  chmod 0500 "${out}"
  run bash -c '
    set -euo pipefail
    . "${HARBOR_ROOT}/lib/log.sh"
    . "${HARBOR_ROOT}/lib/client.sh"
    harbor_install_traps
    harbor_client_conf_write "${1}" harbor-node.TAILNET.ts.net harbor
  ' bash "${out}"
  chmod 0700 "${out}"
  assert_failure
  assert_equal 0 "$(find "${BATS_TEST_TMPDIR}" -maxdepth 1 -name 'harbor.conf.tmp.*' | wc -l | tr -d ' ')"
}

@test "a permissive umask does not make the file readable by anyone else" {
  local out="${BATS_TEST_TMPDIR}/harbor.conf"
  (
    umask 000
    harbor_client_conf_write "${out}" harbor-node.TAILNET.ts.net harbor
  )
  assert_equal 600 "$(stat -f '%OLp' "${out}")"
}
