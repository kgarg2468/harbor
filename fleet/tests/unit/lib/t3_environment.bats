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

@test "equal IDs from both endpoints is the only pass" {
  runtime_fixture healthy
  descriptor_shim_for loopback valid
  descriptor_shim_for magicdns valid
  environment_read pass
}

@test "a different ID at the MagicDNS endpoint is broken, because the route fronts a stranger" {
  runtime_fixture healthy
  descriptor_shim_for loopback valid
  descriptor_shim_for magicdns valid-other-id
  environment_read broken
  assert_regex "${HARBOR_T3_ENVIRONMENT_WHY}" '^tailscale\.serve: '
}

@test "a MagicDNS endpoint answering something that is not a descriptor is broken" {
  runtime_fixture healthy
  descriptor_shim_for loopback valid
  descriptor_shim_for magicdns not-t3
  environment_read broken
}

@test "a MagicDNS endpoint that did not answer is unknown, never broken and never a pass" {
  # The asymmetry: answering wrongly is a finding, not answering is not.
  runtime_fixture healthy
  descriptor_shim_for loopback valid
  descriptor_shim_for magicdns unreachable
  environment_read unknown
  assert_regex "${HARBOR_T3_ENVIRONMENT_WHY}" '^tailscale\.(serve|running): '
}

@test "an unreadable local runtime state is unknown under service.t3" {
  runtime_fixture garbage
  descriptor_shim_for magicdns valid
  environment_read unknown
  assert_regex "${HARBOR_T3_ENVIRONMENT_WHY}" '^service\.t3: unreadable'
}

@test "no running local server is unknown under service.t3, not broken" {
  descriptor_shim_for magicdns valid
  environment_read unknown
  assert_regex "${HARBOR_T3_ENVIRONMENT_WHY}" '^service\.t3: not-running'
}

@test "a local server that answers nothing is unknown, because Harbor has nothing to compare" {
  runtime_fixture healthy
  descriptor_shim_for loopback unreachable
  descriptor_shim_for magicdns valid
  environment_read unknown
  assert_regex "${HARBOR_T3_ENVIRONMENT_WHY}" '^service\.t3: '
}

@test "the local endpoint is built from the runtime port, never from the Serve target" {
  # Section 5.5: "Harbor never uses the proxy target to locate the T3 server."
  # A Serve mapping pointing somewhere else must not change which local endpoint
  # Harbor asks, or a foreign mapping could make itself agree with itself.
  runtime_fixture nondefault
  serve_fixture foreign-443
  descriptor_shim_for loopback valid
  descriptor_shim_for magicdns valid
  harbor_t3_environment "${FIX_HOME}" harbor-node.TAILNET.ts.net >/dev/null
  assert_regex "$(cat "${FIX_SHIM_LOG}")" 'http://127\.0\.0\.1:41773/\.well-known/t3/environment'
  refute_regex "$(cat "${FIX_SHIM_LOG}")" 'http://127\.0\.0\.1:8080/'
}
@test "no environment ID reaches the log, the journal, stdout, or any file Harbor wrote" {
  runtime_fixture healthy
  descriptor_shim_for loopback valid
  descriptor_shim_for magicdns valid-other-id
  harbor_log_open "${FIX_ROOT}/harbor.log" 0600
  harbor_journal_init "${FIX_ROOT}"
  export TMPDIR="${BATS_TEST_TMPDIR}/owned-tmp"
  mkdir -p "${TMPDIR}"
  local out
  environment_read broken
  out="$(cat "${FIX_ROOT}/verdict")"
  assert_equal "${out}" broken
  # The two IDs from the fixtures, by their literal values.
  local id
  for id in env_2f7a91c4 env_9b3e04d1; do
    refute_regex "${out}" "${id}"
    refute_regex "${HARBOR_T3_ENVIRONMENT_WHY}" "${id}"
    assert_equal "$({ grep -rl "${id}" "${FIX_HOME}" "${TMPDIR}" "${BATS_TEST_TMPDIR}" 2>/dev/null || :; } | wc -l | tr -d ' ')" 0
  done
}

@test "the ID leak guard is not vacuous" {
  # Correction 30 again: prove the grep finds an ID when one is there.
  printf 'env_2f7a91c4\n' >"${FIX_ROOT}/planted"
  assert_equal "$(grep -rl env_2f7a91c4 "${FIX_ROOT}" | wc -l | tr -d ' ')" 1
  rm -f "${FIX_ROOT}/planted"
}

@test "an empty MagicDNS response and an HTTP error are broken" {
  runtime_fixture healthy
  descriptor_shim_for loopback valid
  descriptor_shim_for magicdns empty
  environment_read broken
  descriptor_shim_for magicdns http-error
  environment_read broken
}

@test "a local non-descriptor is unknown" {
  runtime_fixture healthy
  descriptor_shim_for loopback not-t3
  environment_read unknown
  assert_regex "${HARBOR_T3_ENVIRONMENT_WHY:-}" '^service\.t3: not-a-descriptor'
}

@test "inherited tracing never discloses IDs and is restored for every verdict" {
  runtime_fixture healthy
  descriptor_shim_for loopback valid
  local fixture id
  for fixture in valid valid-other-id not-t3 unreachable; do
    descriptor_shim_for magicdns "${fixture}"
    (
      set -x
      harbor_t3_environment "${FIX_HOME}" harbor-node.TAILNET.ts.net
      case "$-" in *x*) ;; *) exit 91 ;; esac
      # Read the result while caller tracing is still enabled.
      id="${HARBOR_T3_DESCRIPTOR_ID:-}"
      test -z "${id}"
      # The environment check must discard its in-memory descriptor result.
      test -z "${HARBOR_T3_DESCRIPTOR_ID:-}"
      # The former public reader must not offer a second way to recover an ID
      # after the protected comparison returns. Exercise that escape if present.
      if command -v harbor_t3_descriptor_id >/dev/null; then
        harbor_t3_descriptor_id http://loopback.invalid/.well-known/t3/environment >/dev/null
        id="${HARBOR_T3_DESCRIPTOR_ID:-}"
      fi
      set +x
    ) >"${FIX_ROOT}/trace-out" 2>"${FIX_ROOT}/trace-err"
    for id in env_2f7a91c4 env_9b3e04d1; do
      run grep -r "${id}" "${FIX_HOME}"
      assert_failure 1
    done
  done
}

@test "both ID leak needles catch stdout, diagnostics, and persisted artifacts" {
  local id
  for id in env_2f7a91c4 env_9b3e04d1; do
    assert_regex "${id}" "${id}"
    printf '%s\n' "${id}" >"${FIX_ROOT}/planted"
    run grep -r "${id}" "${FIX_HOME}"
    assert_success
    assert_output --partial "${id}"
    rm "${FIX_ROOT}/planted"
  done
  assert_regex 'http://127.0.0.1:8080/' 'http://127\.0\.0\.1:8080/'
}

@test "malformed MagicDNS descriptors with the same local ID are broken" {
  runtime_fixture healthy
  descriptor_shim_for loopback valid
  local fixture
  for fixture in missing-label missing-platform missing-serverVersion missing-capabilities missing-os missing-arch non-object; do
    descriptor_shim_for magicdns "${fixture}"
    environment_read broken
    assert_regex "${HARBOR_T3_ENVIRONMENT_WHY:-}" '^tailscale\.serve: not-a-descriptor'
  done
}

@test "escaped different IDs never compare equal" {
  runtime_fixture healthy
  descriptor_shim_for loopback escaped-local
  descriptor_shim_for magicdns escaped-remote
  environment_read broken
}

@test "nested wrapper with the local ID is not a descriptor" {
  runtime_fixture healthy
  descriptor_shim_for loopback valid
  descriptor_shim_for magicdns nested-wrapper
  environment_read broken
}

@test "redirect descriptor bodies cannot verify the MagicDNS route" {
  runtime_fixture healthy
  descriptor_shim_for loopback valid
  descriptor_shim_for magicdns valid
  export FIX_HTTP_CODE=302
  environment_read broken
}

@test "duplicate descriptor members and nested platform fields cannot verify a route" {
  runtime_fixture healthy
  descriptor_shim_for loopback valid
  local fixture
  for fixture in duplicate-id nested-platform sentinel-body; do
    descriptor_shim_for magicdns "${fixture}"
    environment_read broken
  done
}
