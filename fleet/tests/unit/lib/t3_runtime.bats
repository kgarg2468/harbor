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
write_code=no
for arg in "$@"; do
  [ "${arg}" != -w ] || write_code=yes
  url="${arg}"
done
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
if [ "${write_code}" = yes ]; then
  code=200
  case "${url}" in https://*) code="${FIX_HTTP_CODE:-200}" ;; esac
  printf '\nHARBOR_HTTP_CODE:%s' "${code}"
fi
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
  local before paths ref="${BATS_TEST_TMPDIR}/reference"
  paths="$(find "${FIX_HOME}/.t3" -print | LC_ALL=C sort)"
  before="$(find "${FIX_HOME}/.t3" -type f -exec cksum {} + | LC_ALL=C sort)"
  touch "${ref}"
  # Ensure a subsequent touch is newer even on coarse timestamp filesystems.
  sleep 1
  harbor_t3_runtime_port "${FIX_HOME}" >/dev/null
  assert_equal "$(find "${FIX_HOME}/.t3" -print | LC_ALL=C sort)" "${paths}"
  assert_equal "$(find "${FIX_HOME}/.t3" -type f -exec cksum {} + | LC_ALL=C sort)" "${before}"
  assert_equal "$(find "${FIX_HOME}/.t3" -newer "${ref}")" ''
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
-w
\nHARBOR_HTTP_CODE:%{http_code}
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

@test "top-level runtime port ignores nested port" {
  runtime_fixture healthy
  printf '%s' '{"version":1,"port":3773,"extra":{"port":8080}}' >"${FIX_HOME}/.t3/userdata/server-runtime.json"
  runtime_read 3773
}

@test "top-level runtime version cannot be overridden by nested version" {
  runtime_fixture healthy
  printf '%s' '{"version":2,"port":3773,"extra":{"version":1}}' >"${FIX_HOME}/.t3/userdata/server-runtime.json"
  runtime_read ''
  assert_equal "${HARBOR_T3_RUNTIME_WHY}" unrecognized-version
}

@test "runtime ports reject invalid spelling and range without arithmetic overflow" {
  runtime_fixture healthy
  local port
  # Legal JSON numbers that are not usable ports. The file is readable and says
  # what it says; what it says is not a port Harbor can dial.
  for port in 0 65536 999999999999999999999999999999999 -1 1.5 1e3; do
    printf '{"version":1,"port":%s}' "${port}" >"${FIX_HOME}/.t3/userdata/server-runtime.json"
    runtime_read ''
    assert_equal "${HARBOR_T3_RUNTIME_WHY}" no-port
  done
}

@test "a port spelled in a way JSON does not allow makes the whole file unreadable" {
  # 00080 is not a JSON numeral, so the document does not parse at all. Reporting
  # no-port here would describe a corrupt file as a healthy server that happens to
  # be missing a port, and send the operator looking for the wrong thing.
  runtime_fixture healthy
  printf '%s' '{"version":1,"port":00080}' >"${FIX_HOME}/.t3/userdata/server-runtime.json"
  runtime_read ''
  assert_equal "${HARBOR_T3_RUNTIME_WHY}" unreadable
}

@test "JSON tabs around the environment ID colon are accepted" {
  descriptor_shim tabs
  descriptor_read env_2f7a91c4
}

@test "direct descriptor calls suspend and restore inherited tracing on every path" {
  local fixture
  for fixture in valid not-t3 empty unreachable http-error escaped-local; do
    descriptor_shim "${fixture}"
    (
      set -x
      harbor_t3_descriptor_read http://loopback.invalid/.well-known/t3/environment
      case "$-" in *x*) ;; *) exit 91 ;; esac
      set +x
    ) >"${BATS_TEST_TMPDIR}/trace-out" 2>"${BATS_TEST_TMPDIR}/trace-err"
    run grep -E 'env_2f7a91c4|env_prefix' "${BATS_TEST_TMPDIR}/trace-out" "${BATS_TEST_TMPDIR}/trace-err"
    assert_failure 1
  done
}

@test "JSON extractor preserves tokens and refuses ambiguous or malformed documents" {
  local body
  run harbor_t3_json_top port <<'JSON'
 {"extra":{"port":8080}, "port" : [ "a,}\\\"b", {"x":true} ] }
JSON
  assert_success
  assert_output '[ "a,}\\\"b", {"x":true} ]'
  for body in '{"port":1,"port":2}' '{"port":1} garbage' '[{"port":1}]' '{"port":1' '{"port":"unterminated}' '{"port":1,}' '{"port":[1,]}' '{"port":true false}' '{"port":"bad\q"}'; do
    run harbor_t3_json_top port <<<"${body}"
    assert_failure
    assert_output ''
  done
}

@test "a raw control byte inside a string makes the document unreadable" {
  # JSON requires control characters below 0x20 to be escaped, so a raw one is a
  # byte no conforming writer produced. Refusing the whole document is the only
  # answer that does not involve guessing what the writer meant -- and it keeps
  # the extractor from handing back a token whose bytes it never validated.
  runtime_fixture healthy
  local body
  body="$(printf '{"label":"a\001b","port":3773}')"
  run harbor_t3_json_top port <<<"${body}"
  assert_failure
  assert_output ''
  printf '%s' "${body}" >"${FIX_HOME}/.t3/userdata/server-runtime.json"
  runtime_read ''
  assert_equal "${HARBOR_T3_RUNTIME_WHY}" unreadable
}

@test "runtime host must be a top-level quoted loopback value and may be empty" {
  runtime_fixture healthy
  local host
  for host in '""' '"127.0.0.1"'; do
    printf '{"version":1,"port":65535,"host":%s,"extra":{"host":"foreign"}}' "${host}" >"${FIX_HOME}/.t3/userdata/server-runtime.json"
    runtime_read 65535
  done
  for host in null true 127 '"foreign"'; do
    printf '{"version":1,"port":1,"host":%s}' "${host}" >"${FIX_HOME}/.t3/userdata/server-runtime.json"
    runtime_read ''
    assert_equal "${HARBOR_T3_RUNTIME_WHY}" not-loopback
  done
  printf '%s' '{"version":1.0,"port":1}' >"${FIX_HOME}/.t3/userdata/server-runtime.json"
  runtime_read ''
  assert_equal "${HARBOR_T3_RUNTIME_WHY}" unrecognized-version
}

@test "JSON extractor keeps multiline token bytes and whitespace out of scalar tokens" {
  run harbor_t3_json_top value <<'JSON'
{
  "value": {
    "text": "literal {}[],: and \\" ,
    "array": [false, null, -1.2e+3]
  }
}
JSON
  assert_success
  assert_output '{
    "text": "literal {}[],: and \\" ,
    "array": [false, null, -1.2e+3]
  }'
  run harbor_t3_json_top value <<'JSON'
 { "value" : 1 }
JSON
  assert_success
  assert_output 1
}
