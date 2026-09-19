#!/usr/bin/env bats
load '../test_helper'

setup() {
  harbor_load_libs
  . "${HARBOR_ROOT}/lib/runtime.sh"
  . "${HARBOR_ROOT}/lib/serve.sh"
  . "${HARBOR_ROOT}/lib/t3.sh"
  fixture_state_root
  export HOME="${FIX_HOME}"
  export FIX_SHIM_LOG="${BATS_TEST_TMPDIR}/curl.argv"
  export FIX_LOOPBACK=unreachable FIX_MAGICDNS=unreachable
  mkdir -p "${BATS_TEST_TMPDIR}/bin"
  cat >"${BATS_TEST_TMPDIR}/bin/curl" <<'SHIM'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$@" >>"${FIX_SHIM_LOG}"
for arg in "$@"; do url="${arg}"; done
case "${url}" in
  http://*) fixture="${FIX_LOOPBACK}" ;;
  https://*) fixture="${FIX_MAGICDNS}" ;;
  *) exit 97 ;;
esac
case "${fixture}" in
  unreachable) exit 7 ;;
  http-error) exit 22 ;;
esac
cat "${HARBOR_ROOT}/tests/fixtures/t3/environment/${fixture}"
SHIM
  chmod +x "${BATS_TEST_TMPDIR}/bin/curl"
  export PATH="${BATS_TEST_TMPDIR}/bin:${PATH}"
  set -euo pipefail
}

runtime_fixture() {
  mkdir -p "${FIX_HOME}/.t3/userdata"
  cp "${HARBOR_ROOT}/tests/fixtures/t3/server-runtime/${1}" \
    "${FIX_HOME}/.t3/userdata/server-runtime.json"
}

descriptor_shim() { export FIX_LOOPBACK="${1}"; }
descriptor_shim_for() {
  case "${1}" in
    loopback) export FIX_LOOPBACK="${2}" ;;
    magicdns) export FIX_MAGICDNS="${2}" ;;
  esac
}

# Direct calls preserve the reason globals; $() forks and discards them.
runtime_read() {
  harbor_t3_runtime_port "${FIX_HOME}" >"${BATS_TEST_TMPDIR}/port"
  assert_equal "$(cat "${BATS_TEST_TMPDIR}/port")" "${1}"
}
descriptor_read() {
  local HARBOR_T3_DESCRIPTOR_ID
  harbor_t3_descriptor_read http://loopback.invalid/.well-known/t3/environment >/dev/null
  assert_equal "${HARBOR_T3_DESCRIPTOR_ID:-}" "${1}"
}
environment_read() {
  harbor_t3_environment "${FIX_HOME}" harbor-node.TAILNET.ts.net >"${FIX_ROOT}/verdict" 2>"${FIX_ROOT}/stderr"
  assert_equal "$(cat "${FIX_ROOT}/verdict")" "${1}"
}
serve_fixture() {
  HARBOR_SERVE_RAW="$(cat "${HARBOR_ROOT}/tests/fixtures/tailscale/serve-status/${1}")"
}

@test "the pinned paths are the measured ones and creating nothing" {
  assert_equal "$(harbor_t3_state_dir "${FIX_HOME}")" "${FIX_HOME}/.t3/userdata"
  assert_equal "$(harbor_t3_runtime_path "${FIX_HOME}")" \
    "${FIX_HOME}/.t3/userdata/server-runtime.json"
  # Asking where it is must not bring it into existence, the same rule
  # harbor_t3_bin and harbor_t3_package_dir already hold.
  assert [ ! -e "${FIX_HOME}/.t3" ]
}

@test "the pinned one-line body yields the port" {
  runtime_fixture healthy
  runtime_read 3773
}

@test "indentation is not what the reader depends on" {
  # The vendor writes one line. A reader that only works on one line would be
  # right today and wrong the moment the vendor pretty-prints, and a reader that
  # only works pretty-printed is wrong right now. Both shapes answer.
  runtime_fixture pretty-printed
  runtime_read 3773
}

@test "an absent file is an absent server, with a reason" {
  runtime_read ''
  assert_equal "${HARBOR_T3_RUNTIME_WHY}" not-running
}

@test "a version other than the measured literal is refused, not read" {
  runtime_fixture wrong-version
  runtime_read ''
  assert_equal "${HARBOR_T3_RUNTIME_WHY}" unrecognized-version
}

@test "a non-loopback host is refused, because the loopback assumption does not describe it" {
  runtime_fixture non-loopback-host
  runtime_read ''
  assert_equal "${HARBOR_T3_RUNTIME_WHY}" not-loopback
}

@test "a missing port and an unreadable body are each their own reason" {
  runtime_fixture no-port
  runtime_read ''
  assert_equal "${HARBOR_T3_RUNTIME_WHY}" no-port
  runtime_fixture garbage
  runtime_read ''
  assert_equal "${HARBOR_T3_RUNTIME_WHY}" unreadable
}

@test "a symlink at the runtime path is refused before it is followed" {
  # lib/t3.sh refuses a linked package and lib/ssh.sh a linked .ssh for the same
  # reason: a reader that follows a link lets a file outside this path decide.
  mkdir -p "${FIX_HOME}/.t3/userdata"
  touch "${BATS_TEST_TMPDIR}/foreign"
  ln -s "${BATS_TEST_TMPDIR}/foreign" "${FIX_HOME}/.t3/userdata/server-runtime.json"
  runtime_read ''
  assert_equal "${HARBOR_T3_RUNTIME_WHY}" foreign
}

@test "the reader never writes to the vendor's directory" {
  runtime_fixture healthy
  # cksum, not sha256sum: this suite runs on the macOS runners too, and stock
  # macOS has no sha256sum. lib/t3.bats already hashes this way for the same
  # reason; sha256sum appears only in the integration lane, which is Ubuntu only.
  local before
  before="$(find "${FIX_HOME}/.t3" -type f -exec cksum {} + | LC_ALL=C sort)"
  harbor_t3_runtime_port "${FIX_HOME}" >/dev/null
  assert_equal "$(find "${FIX_HOME}/.t3" -type f -exec cksum {} + | LC_ALL=C sort)" \
    "${before}"
}
@test "a valid descriptor yields its environmentId" {
  descriptor_shim valid
  descriptor_read env_2f7a91c4
  run harbor_t3_descriptor_read http://loopback.invalid/.well-known/t3/environment
  assert_success
  assert_output ''
}

@test "a body that is not a T3 descriptor is refused with its own reason" {
  descriptor_shim not-t3
  descriptor_read ''
  assert_equal "${HARBOR_T3_DESCRIPTOR_WHY}" not-a-descriptor
}

@test "an empty body and an unreachable endpoint are different reasons" {
  descriptor_shim empty
  descriptor_read ''
  assert_equal "${HARBOR_T3_DESCRIPTOR_WHY}" not-a-descriptor
  descriptor_shim unreachable
  descriptor_read ''
  assert_equal "${HARBOR_T3_DESCRIPTOR_WHY}" unreachable
}

@test "the fetch carries no credential and follows no redirect" {
  descriptor_shim valid
  harbor_t3_descriptor_read http://loopback.invalid/.well-known/t3/environment >/dev/null
  local argv
  argv="$(cat "${FIX_SHIM_LOG}")"
  # The positive form as well as the refutations, because a refutation whose
  # needle is misspelled cannot fail (Correction 30).
  assert_equal "${argv}" '-q
-fsS
--no-progress-meter
--connect-timeout
5
--max-time
15
http://loopback.invalid/.well-known/t3/environment'
  assert_regex "${argv}" '--max-time'
  refute_regex "${argv}" '--location'
  refute_regex "${argv}" '(-u|--user|--header|Authorization|--netrc)'
}

@test "an HTTP error answered and is not a descriptor, not unreachable" {
  descriptor_shim http-error
  descriptor_read ''
  assert_equal "${HARBOR_T3_DESCRIPTOR_WHY:-}" not-a-descriptor
}

@test "the credential and redirect needles match planted arguments" {
  local argv='--location -u --user --header Authorization --netrc'
  assert_regex "${argv}" '--location'
  assert_regex "${argv}" '(-u|--user|--header|Authorization|--netrc)'
}

@test "descriptor structure rejects missing-label despite a valid ID" {
  descriptor_shim missing-label
  descriptor_read ''
  assert_equal "${HARBOR_T3_DESCRIPTOR_WHY:-}" not-a-descriptor
}

@test "descriptor structure rejects missing-platform despite a valid ID" {
  descriptor_shim missing-platform
  descriptor_read ''
  assert_equal "${HARBOR_T3_DESCRIPTOR_WHY:-}" not-a-descriptor
}

@test "descriptor structure rejects missing-serverVersion despite a valid ID" {
  descriptor_shim missing-serverVersion
  descriptor_read ''
  assert_equal "${HARBOR_T3_DESCRIPTOR_WHY:-}" not-a-descriptor
}

@test "descriptor structure rejects missing-capabilities despite a valid ID" {
  descriptor_shim missing-capabilities
  descriptor_read ''
  assert_equal "${HARBOR_T3_DESCRIPTOR_WHY:-}" not-a-descriptor
}

@test "descriptor structure rejects missing-os despite a valid ID" {
  descriptor_shim missing-os
  descriptor_read ''
  assert_equal "${HARBOR_T3_DESCRIPTOR_WHY:-}" not-a-descriptor
}

@test "descriptor structure rejects missing-arch despite a valid ID" {
  descriptor_shim missing-arch
  descriptor_read ''
  assert_equal "${HARBOR_T3_DESCRIPTOR_WHY:-}" not-a-descriptor
}

@test "descriptor structure rejects non-object despite a valid ID" {
  descriptor_shim non-object
  descriptor_read ''
  assert_equal "${HARBOR_T3_DESCRIPTOR_WHY:-}" not-a-descriptor
}
