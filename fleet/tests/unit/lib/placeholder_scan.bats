#!/usr/bin/env bats
load '../test_helper'

setup() {
  SCAN="${HARBOR_ROOT}/tests/lint/placeholder_scan.sh"
  REPO="${BATS_TEST_TMPDIR}/repo"
  mkdir -p "${REPO}/tests/lint" "${REPO}/fleet/tests/fixtures" "${REPO}/docs"
  cp "${HARBOR_ROOT}/tests/lint/placeholder-patterns.txt" "${REPO}/tests/lint/"
  git -C "${REPO}" init -q
  git -C "${REPO}" config user.email operator@example.com
  git -C "${REPO}" config user.name OPERATOR
  printf '# clean\n\nnode harbor-node on TAILNET.ts.net at TAILNET_IP for operator@example.com via RELAY_HOSTNAME\n' >"${REPO}/docs/clean.md"
  git -C "${REPO}" add -A
}

scan() {
  run "${SCAN}" "${REPO}"
}

@test "a repository using only the placeholders passes" {
  scan
  assert_success
  assert_output ''
}

@test "work-in-progress markers are reported with file and line" {
  m=TO
  printf 'first\n%sDO: later\n' "${m}" >"${REPO}/docs/wip.md"
  git -C "${REPO}" add -A
  scan
  assert_failure
  assert_output --partial 'docs/wip.md:2:'
  m=FIX
  printf '# %sME later\n' "${m}" >"${REPO}/docs/wip.md"
  git -C "${REPO}" add -A
  scan
  assert_failure
}

@test "identifiers outside the placeholder list are reported" {
  printf 'node.mytailnet.ts.%s\n' net >"${REPO}/docs/dns.md"
  git -C "${REPO}" add -A
  scan
  assert_failure
  assert_output --partial 'MagicDNS name outside the placeholder list'
  rm "${REPO}/docs/dns.md"
  printf 'mail someone@%s\n' corp.example >"${REPO}/docs/mail.md"
  git -C "${REPO}" add -A
  scan
  assert_failure
  assert_output --partial 'email outside example.com'
  rm "${REPO}/docs/mail.md"
  printf 'ip 100.%s.1.2\n' 64 >"${REPO}/docs/ip.md"
  git -C "${REPO}" add -A
  scan
  assert_failure
  assert_output --partial 'docs/ip.md:1:'
  rm "${REPO}/docs/ip.md"
  printf 'key tskey%s-abc123\n' - >"${REPO}/docs/key.md"
  printf 'https://RELAY_HOSTNAME/x?%s=abc\n' token >>"${REPO}/docs/key.md"
  printf 'id user_%s\n' 2NNEqL2nrIRdJ194ndJqAHwEfxC >>"${REPO}/docs/key.md"
  git -C "${REPO}" add -A
  scan
  assert_failure
  assert_output --partial 'docs/key.md:1:'
  assert_output --partial 'docs/key.md:2:'
  assert_output --partial 'docs/key.md:3:'
}

@test "files under fleet/tests/fixtures and untracked files are ignored" {
  m=TO
  printf '%sDO in a fixture\n' "${m}" >"${REPO}/fleet/tests/fixtures/service-status.txt"
  printf 'node.mytailnet.ts.%s\n' net >>"${REPO}/fleet/tests/fixtures/service-status.txt"
  printf '%sDO untracked\n' "${m}" >"${REPO}/docs/untracked.md"
  git -C "${REPO}" add fleet/tests/fixtures
  scan
  assert_success
}

@test "the patterns file and .gitleaks.toml are scanned like any other tracked file" {
  m=TO
  printf 'title = "x" # %sDO tighten\n' "${m}" >"${REPO}/.gitleaks.toml"
  git -C "${REPO}" add -A
  scan
  assert_failure
  assert_output --partial '.gitleaks.toml:1:'
  rm "${REPO}/.gitleaks.toml"
  printf '%sDO\n' "${m}" >>"${REPO}/tests/lint/placeholder-patterns.txt"
  git -C "${REPO}" add -A
  scan
  assert_failure
  assert_output --partial 'tests/lint/placeholder-patterns.txt:10:'
}

@test "the real repository passes the scan" {
  run "${SCAN}" "${HARBOR_ROOT}/.."
  assert_success
}
