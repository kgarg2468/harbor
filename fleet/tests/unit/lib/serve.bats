#!/usr/bin/env bats
load '../test_helper'

setup() {
  harbor_load_libs
  # The optional source lets the first red run exercise missing functions.
  if [ -f "${HARBOR_ROOT}/lib/serve.sh" ]; then
    . "${HARBOR_ROOT}/lib/serve.sh"
  fi
  fixture_home
  export HOME="${FIX_HOME}"
  mkdir -p "${BATS_TEST_TMPDIR}/bin"
  ln -s "${HARBOR_ROOT}/tests/shims/bin/harbor-shim" "${BATS_TEST_TMPDIR}/bin/tailscale"
  export PATH="${BATS_TEST_TMPDIR}/bin:${PATH}"
  export HARBOR_SHIM_FIXTURES="${BATS_TEST_TMPDIR}/fx"
  export HARBOR_SHIM_SCENARIO=healthy
  export HARBOR_SHIM_LOG="${BATS_TEST_TMPDIR}/shim.log"
  mkdir -p "${HARBOR_SHIM_FIXTURES}/tailscale/healthy"
}

serve_fixture() {
  serve_fixture_body "$(cat "${HARBOR_ROOT}/tests/fixtures/tailscale/serve-status/${1}")"
}

serve_fixture_body() {
  printf '%s' "${1}" >"${HARBOR_SHIM_FIXTURES}/tailscale/healthy/serve_status.out"
  HARBOR_SERVE_RAW="$(cat "${HARBOR_SHIM_FIXTURES}/tailscale/healthy/serve_status.out")"
}

@test "the vendor's own 443 mapping normalizes to the loopback form" {
  serve_fixture vendor-443
  assert_equal "$(harbor_serve_mapping)" 'https:443 -> http://loopback:3773'
}

@test "the three loopback spellings are one identity" {
  local spelling
  for spelling in localhost 127.0.0.1 '[::1]'; do
    serve_fixture_body "https://harbor-node.TAILNET.ts.net (tailnet only)
|-- / proxy http://${spelling}:3773"
    assert_equal "$(harbor_serve_mapping)" 'https:443 -> http://loopback:3773'
  done
}

@test "a non-loopback proxy target keeps its host, because it is not this node's server" {
  serve_fixture_body "https://harbor-node.TAILNET.ts.net (tailnet only)
|-- / proxy http://10.0.0.7:3773"
  assert_equal "$(harbor_serve_mapping)" 'https:443 -> http://10.0.0.7:3773'
}

@test "no mapping is absent, and a mapping on another port is also absent at 443" {
  serve_fixture absent
  assert_equal "$(harbor_serve_mapping)" absent
  serve_fixture non-443
  assert_equal "$(harbor_serve_mapping)" absent
}

@test "a 443 listener below a non-443 one is still found" {
  # The bug this replaces read line 1 to decide the port and then grepped the whole
  # body for a target. On this input those two halves disagree: line 1 says 8443,
  # and the grep would have returned the 443 listener's target. The half that won
  # returned absent, and harbor_pair_precheck treats absent as permission to
  # create a mapping -- so a parse bug ended in Harbor mutating a node that
  # already had a 443 listener.
  serve_fixture mixed-listeners
  assert_equal "$(harbor_serve_mapping)" 'https:443 -> http://loopback:3773'
}

@test "a non-443 listener's target is never borrowed for the 443 answer" {
  # The same disagreement in the other direction: only an 8443 listener exists, so
  # there is nothing at 443, and its target must not be reported as if there were.
  serve_fixture_body "https://harbor-node.TAILNET.ts.net:8443 (tailnet only)
|-- / proxy http://127.0.0.1:9000"
  assert_equal "$(harbor_serve_mapping)" absent
}

@test "two root handlers in one 443 listener is unnormalizable, not a coin flip" {
  serve_fixture ambiguous-443
  assert_equal "$(harbor_serve_mapping)" unnormalizable
}

@test "a 443 listener with no root handler is unnormalizable, never absent" {
  # Something is at 443, so absent would be false and would license a create.
  # Harbor cannot describe it, so it is not a mapping either.
  serve_fixture no-root-443
  assert_equal "$(harbor_serve_mapping)" unnormalizable
}

@test "a handler with no listener above it is unnormalizable, never absent" {
  # Ignoring the orphan and falling through to "no 443 header was seen" would
  # report a malformed body as an empty one, and absent is what licenses a create.
  serve_fixture_body "|-- / proxy http://127.0.0.1:3773"
  assert_equal "$(harbor_serve_mapping)" unnormalizable
}

@test "an orphan handler above a real 443 listener still refuses the body" {
  # The 443 listener is right there and readable. It does not rescue a body whose
  # earlier lines Harbor could not account for.
  serve_fixture_body "|-- / proxy http://127.0.0.1:9000
https://harbor-node.TAILNET.ts.net (tailnet only)
|-- / proxy http://127.0.0.1:3773"
  assert_equal "$(harbor_serve_mapping)" unnormalizable
}

@test "every unreadable-body arm ends somewhere other than absent" {
  # The invariant behind the last three tests, asserted as one: absent is the word
  # that authorizes harbor pair to mutate Serve, so no arm that failed to
  # understand its input may reach it. The positive control is last.
  local body got
  for body in "|-- / proxy http://127.0.0.1:3773" \
    "some new line a later tailscale prints" \
    "https://harbor-node.TAILNET.ts.net (tailnet only)
|-- / proxy http://127.0.0.1:3773
|-- / proxy http://127.0.0.1:9000"; do
    serve_fixture_body "${body}"
    got="$(harbor_serve_mapping)"
    assert [ "${got}" != absent ]
  done
  serve_fixture absent
  assert_equal "$(harbor_serve_mapping)" absent
}

@test "a line this adapter has no reading for makes the whole body unnormalizable" {
  # A future vendor format must not be silently parsed as the current one.
  serve_fixture_body "https://harbor-node.TAILNET.ts.net (tailnet only)
|-- / proxy http://127.0.0.1:3773
some new line a later tailscale prints"
  assert_equal "$(harbor_serve_mapping)" unnormalizable
}

@test "output this adapter cannot reduce is unnormalizable, never absent" {
  local name
  for name in garbage empty; do
    serve_fixture "${name}"
    assert_equal "$(harbor_serve_mapping)" unnormalizable
  done
}

@test "funnel is detected from the vendor's own word and is not a mapping question" {
  serve_fixture funnel
  assert_equal "$(harbor_serve_funnel)" present
  serve_fixture vendor-443
  assert_equal "$(harbor_serve_funnel)" none
  serve_fixture garbage
  assert_equal "$(harbor_serve_funnel)" unknown
}

@test "the observer answers the journal's three comparisons in the journal's own form" {
  serve_fixture vendor-443
  assert_equal "$(harbor_observe_op_tailscale_serve https-443)" \
    '"https:443 -> http://loopback:3773"'
  serve_fixture absent
  assert_equal "$(harbor_observe_op_tailscale_serve https-443)" '"absent"'
  serve_fixture garbage
  assert_equal "$(harbor_observe_op_tailscale_serve https-443)" '"unnormalizable"'
}

@test "the observer reaches the journal through its op name, not by being called directly" {
  # The dispatch in lib/journal.sh is what recovery actually uses; a function that
  # is correct but unreachable under its op name decides nothing.
  serve_fixture vendor-443
  assert_equal "$(harbor_journal_observe tailscale-serve https-443)" \
    '"https:443 -> http://loopback:3773"'
}

@test "the observer re-reads rather than answering from the last reading" {
  serve_fixture absent
  assert_equal "$(harbor_observe_op_tailscale_serve https-443)" '"absent"'
  serve_fixture vendor-443
  HARBOR_SERVE_RAW="No serve config"
  assert_equal "$(harbor_observe_op_tailscale_serve https-443)" \
    '"https:443 -> http://loopback:3773"'
}

# serve_stub STDOUT STDERR EXIT -- a tailscale on PATH that answers exactly this.
# The generic shim has no stderr fixture, and stderr is the whole point of the two
# tests below, so they bring their own vendor rather than widen a shim every other
# suite shares.
serve_stub() {
  cat >"${BATS_TEST_TMPDIR}/bin/tailscale" <<STUB
#!/bin/bash
printf '%s' "\${1:-}" >/dev/null
cat <<'OUT'
${1}
OUT
cat >&2 <<'ERR'
${2}
ERR
exit ${3}
STUB
  chmod 0755 "${BATS_TEST_TMPDIR}/bin/tailscale"
}

@test "the vendor's version-skew warning on stderr does not become the config" {
  # Measured against a real tailscale: a 1.96.4 CLI talking to a 1.98.2 daemon
  # prints this warning on stderr and "No serve config" on stdout. Capturing both
  # streams made a healthy node read as unnormalizable, which made harbor pair
  # exit 2 on a node with nothing wrong with it.
  rm -f "${BATS_TEST_TMPDIR}/bin/tailscale"
  serve_stub 'No serve config' \
    'Warning: client version "1.96.4-t41cb72f27" != tailscaled server version "1.98.2-taaf7caef1"' 0
  harbor_serve_status
  assert_equal "${HARBOR_SERVE_RAW}" 'No serve config'
  assert_equal "$(harbor_serve_mapping)" absent
  assert_equal "$(harbor_serve_funnel)" none
}

@test "the skew-warning guard is not vacuous" {
  # Correction 30: prove the stub really does write to stderr, so the test above
  # is passing because the reader ignores that stream and not because the stream
  # was empty.
  rm -f "${BATS_TEST_TMPDIR}/bin/tailscale"
  serve_stub 'No serve config' 'Warning: client version mismatch' 0
  assert_equal "$(tailscale serve status 2>&1 >/dev/null)" 'Warning: client version mismatch'
  assert_equal "$(tailscale serve status 2>/dev/null)" 'No serve config'
}

@test "a vendor that exited non-zero is not parsed, whatever it printed" {
  # The exit code is the vendor saying it did not answer. Stdout that looks like a
  # Serve configuration is not one, and both readers must fail closed.
  rm -f "${BATS_TEST_TMPDIR}/bin/tailscale"
  serve_stub 'No serve config' 'failed to connect to local tailscaled' 1
  harbor_serve_status
  assert_equal "${HARBOR_SERVE_RAW}" ''
  assert_equal "$(harbor_serve_mapping)" unnormalizable
  assert_equal "$(harbor_serve_funnel)" unknown
  assert_regex "${HARBOR_SERVE_WHY}" 'exited 1'
}

@test "harbor_serve_status reads a real mapping off stdout end to end" {
  # The positive form of the two refutations above: the same function, the same
  # stub, a body that is a configuration, and the mapping comes out.
  rm -f "${BATS_TEST_TMPDIR}/bin/tailscale"
  serve_stub 'https://harbor-node.TAILNET.ts.net (tailnet only)
|-- / proxy http://127.0.0.1:3773' \
    'Warning: client version "1.96.4" != tailscaled server version "1.98.2"' 0
  harbor_serve_status
  assert_equal "$(harbor_serve_mapping)" 'https:443 -> http://loopback:3773'
}

@test "no library invokes tailscale funnel, in any code path" {
  # Section 3.3: Harbor never invokes tailscale funnel. The only permitted
  # appearances of the word are in prose -- a comment or a message telling the
  # operator what the vendor command would be -- never as a command.
  local hits
  hits="$(grep -rn 'tailscale funnel' "${HARBOR_ROOT}/lib" "${HARBOR_ROOT}/node" \
    "${HARBOR_ROOT}/bin" || :)"
  # Every hit must be inside a comment or a quoted message. A bare invocation is
  # a line whose first word after optional whitespace is `tailscale`.
  local bare
  bare="$(printf '%s\n' "${hits}" | sed -n 's/^[^:]*:[0-9]*: *//p' \
    | grep -c '^tailscale funnel' || :)"
  assert_equal "${bare}" 0
}

@test "the funnel guard is not vacuous" {
  # Correction 30: a refutation that has never failed is not a test. Prove this
  # one can fail by giving it a file that violates the rule.
  mkdir -p "${BATS_TEST_TMPDIR}/lib"
  printf '#!/bin/bash\ntailscale funnel 443 on\n' >"${BATS_TEST_TMPDIR}/lib/bad.sh"
  local bare
  bare="$(grep -rn 'tailscale funnel' "${BATS_TEST_TMPDIR}/lib" \
    | sed -n 's/^[^:]*:[0-9]*: *//p' | grep -c '^tailscale funnel' || :)"
  assert_equal "${bare}" 1
}
