#!/usr/bin/env bats
load '../test_helper'

# Every command runs against a disposable HOME and release. The shell shim answers
# the login-shell probe itself, because running a real login shell would read the
# runner's profile and could resolve its real Node instead of the fixture's version.
setup() {
  harbor_load_libs
  fixture_state_root
  rm -r "${FIX_ROOT}"
  RELEASE="${BATS_TEST_TMPDIR}/release"
  BIN="${BATS_TEST_TMPDIR}/bin"
  RECORD="${BATS_TEST_TMPDIR}/bootstrap.json"
  mkdir -p "${RELEASE}/bin" "${RELEASE}/node" "${BIN}"
  cp -R "${HARBOR_ROOT}/lib" "${RELEASE}/lib"
  cp "${HARBOR}" "${RELEASE}/bin/harbor"
  cp "${HARBOR_ROOT}/versions.lock" "${RELEASE}/versions.lock"
  if [ -f "${HARBOR_ROOT}/node/provision.sh" ]; then
    cp "${HARBOR_ROOT}/node/provision.sh" "${RELEASE}/node/provision.sh"
  fi
  printf '{\n  "tailscale_ownership": "harbor-installed"\n}\n' >"${RECORD}"
  cat >"${BIN}/tailscale" <<'SH'
#!/bin/bash
[ "$*" = 'status --json' ] || exit 99
printf '{"BackendState":"%s"}\n' "${TEST_BACKEND:-Running}"
exit "${TEST_BACKEND_RC:-0}"
SH
  cat >"${BIN}/loginctl" <<'SH'
#!/bin/bash
[ "$*" = "show-user $(id -un) -p Linger --value" ] || exit 99
printf '%s\n' "${TEST_LINGER:-yes}"
exit "${TEST_LINGER_RC:-0}"
SH
  cat >"${BIN}/sh" <<'SH'
#!/bin/bash
[ "$*" = '-lc node --version' ] || exit 99
printf '%s\n' "${TEST_NODE}"
exit "${TEST_NODE_RC:-0}"
SH
  chmod 0755 "${BIN}/tailscale" "${BIN}/loginctl" "${BIN}/sh"
  provision_vendor_fixtures
  NODE_LOCKED="$(sed -n 's/^nodejs_version=//p' "${HARBOR_ROOT}/versions.lock")"
}

provision() {
  env HOME="${FIX_HOME}" PATH="${BIN}:${PATH}" HARBOR_DEV=1 \
    HARBOR_AUTH_FIXTURE_RECORD="${RECORD}" HARBOR_VERBOSE=1 \
    TEST_FIXTURE="${BATS_TEST_TMPDIR}" TEST_NODE="v${NODE_LOCKED}" "$@" "${RELEASE}/bin/harbor" provision
}

@test "root is refused before any operator state is created" {
  cat >"${BIN}/id" <<'SH'
#!/bin/bash
printf '0\n'
SH
  chmod 0755 "${BIN}/id"
  run provision
  assert_equal "${status}" 3
  assert_output --partial 'provision.root'
  assert_output --partial 'operator'
  assert [ ! -e "${FIX_ROOT}" ]
}

@test "a checkout is refused before the backend or state root is touched" {
  run provision HARBOR_DEV=0
  assert_equal "${status}" 3
  assert_output --partial 'entrypoint.location'
  refute_output --partial 'vendor: tailscale'
  assert [ ! -e "${FIX_ROOT}" ]
}

@test "a Harbor-installed backend needing login exits attended before linger and state creation" {
  run provision TEST_BACKEND=NeedsLogin TEST_LINGER=no
  assert_equal "${status}" 1
  assert_output --partial 'needs_tailscale_login'
  assert_output --partial 'harbor auth tailscale'
  refute_output --partial 'provision.linger'
  assert [ ! -e "${FIX_ROOT}" ]
}

@test "a pre-existing backend needing login names the owner's tailscale up" {
  printf '{\n  "tailscale_ownership": "pre-existing"\n}\n' >"${RECORD}"
  run provision TEST_BACKEND=NeedsLogin
  assert_equal "${status}" 1
  assert_output --partial 'tailscale up'
  refute_output --partial 'harbor auth tailscale'
  assert [ ! -e "${FIX_ROOT}" ]
}

@test "a failed backend read is attended even if its output says Running" {
  run provision TEST_BACKEND_RC=1
  assert_equal "${status}" 1
  assert_output --partial 'needs_tailscale_login'
  assert [ ! -e "${FIX_ROOT}" ]
}

@test "linger off names the exact root command and creates nothing" {
  run provision TEST_LINGER=no
  assert_equal "${status}" 3
  assert_output --partial "sudo loginctl enable-linger $(id -un)"
  assert [ ! -e "${FIX_ROOT}" ]
}

@test "a failed linger read refuses even if its output says yes" {
  run provision TEST_LINGER_RC=1
  assert_equal "${status}" 3
  assert_output --partial 'provision.linger'
  assert [ ! -e "${FIX_ROOT}" ]
}

@test "a state-root creation failure exits broken without taking a lock or writing a journal" {
  rm -r "${FIX_HOME}/.local"
  printf 'foreign\n' >"${FIX_HOME}/.local"
  run provision
  assert_equal "${status}" 2
  assert_output --partial 'provision.state_root'
  assert_equal "$(cat "${FIX_HOME}/.local")" foreign
  refute_output --partial 'step provision-lock'
}

@test "the state root is 0700 at lock-gate before any journal exists" {
  run provision HARBOR_TEST_HOOKS=1 HARBOR_FAIL_AFTER=lock-gate
  assert_equal "${status}" 137
  run ls -ld "${FIX_ROOT}"
  assert_output --regexp '^drwx------'
  assert [ ! -e "${FIX_ROOT}/journal" ]
  assert [ ! -e "${FIX_ROOT}/lock.d" ]
  run ls -ld "${FIX_ROOT}/reclaim.d"
  assert_output --regexp '^drwx------'
  run ls -l "${FIX_ROOT}/reclaim.d/holder"
  assert_output --regexp '^-rw-------'
  run cat "${FIX_ROOT}/harbor.log"
  assert_output --partial 'step lock-gate'
}

@test "a malformed versions lock refuses before Node and recovery" {
  printf 'foreign=value\n' >>"${RELEASE}/versions.lock"
  run provision
  assert_equal "${status}" 3
  assert_output --partial 'versions.unknown_key'
  refute_output --partial 'step provision-node'
  assert [ ! -e "${FIX_ROOT}/journal" ]
}

@test "a malformed command lock refuses before Node and recovery" {
  mkdir -p "${FIX_ROOT}/lock.d"
  printf 'broken\n' >"${FIX_ROOT}/lock.d/holder"
  run provision
  assert_equal "${status}" 3
  assert_output --partial 'lock.'
  refute_output --partial 'step provision-node'
  assert_equal "$(cat "${FIX_ROOT}/lock.d/holder")" broken
  assert [ ! -e "${FIX_ROOT}/journal" ]
}

@test "an incompatible login-shell Node refuses before journal recovery" {
  run provision TEST_NODE=v1.0.0
  assert_equal "${status}" 3
  assert_output --partial 'provision.node'
  assert_output --partial 't3_engines_node'
  assert [ ! -e "${FIX_ROOT}/journal" ]
  assert [ ! -e "${FIX_ROOT}/lock.d" ]
}

@test "a failed login-shell Node read refuses before recovery" {
  run provision TEST_NODE_RC=1
  assert_equal "${status}" 3
  assert_output --partial 'provision.node'
  assert [ ! -e "${FIX_ROOT}/journal" ]
}

@test "undecidable recovery exits broken and leaves the artifact and entry unchanged" {
  fixture_undecidable_file_entry "${FIX_ROOT}" 0001
  run provision
  assert_equal "${status}" 2
  assert_output --partial 'journal.undecidable'
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" prepared
  assert_equal "$(cat "${FIX_ARTIFACT_0001}")" two
  refute_output --partial 'preflight complete'
}

@test "healthy provision runs preflight and rows in table order" {
  run provision
  assert_success
  assert_output --partial 'provision complete'
  # Two expressions rather than one \(a\|b\): alternation inside \(...\) is a GNU
  # extension, and BSD sed on the macos-14 runner matches nothing at all rather than
  # failing, so the single-pattern form reads every step list as empty and would have
  # passed this assertion only on Linux.
  steps="$(printf '%s\n' "${output}" \
    | sed -n -e 's/^harbor: step: \(provision-.*\)$/\1/p' -e 's/^harbor: step: \(recovery-scan\)$/\1/p')"
  assert_equal "${steps}" 'provision-principal
provision-entrypoint
provision-backend
provision-linger
provision-state-root
provision-lock
provision-node
recovery-scan
provision-journal-config
provision-runtime-install
provision-runtime-auth
provision-t3-install
provision-vendor-service
provision-access-mode'
  assert [ ! -e "${FIX_ROOT}/lock.d" ]
  assert [ -d "${FIX_ROOT}/journal" ]
  assert [ ! -e "${FIX_ROOT}/installed.lock" ]
  assert [ ! -e "${FIX_ROOT}/provision.json" ]
  assert_equal "$(cat "${FIX_HOME}/.config/harbor/config")" access_mode=connect
  assert [ ! -e "${FIX_HOME}/.config/systemd" ]
}

# All vendor executables, including npm's install payloads, live in this test's
# temporary directory. Unexpected commands fail closed instead of reaching a host CLI.
provision_vendor_fixtures() {
  local tool prefix range
  prefix="${FIX_HOME}/.local/harbor/npm"
  mkdir -p "${BATS_TEST_TMPDIR}/payload" "${prefix}/bin"
  # The library uses node_modules directly beneath the npm prefix.
  mkdir -p "${prefix}/node_modules/t3"
  cp -R "${HARBOR_ROOT}/tests/fixtures/t3" "${BATS_TEST_TMPDIR}/t3-fixtures"
  cp "${HARBOR_ROOT}/versions.lock" "${BATS_TEST_TMPDIR}/versions.lock"
  range="$(sed -n 's/^t3_engines_node=//p' "${HARBOR_ROOT}/versions.lock")"
  printf '{\n  "engines": {\n    "node": "%s"\n  }\n}\n' "${range}" >"${prefix}/node_modules/t3/package.json"
  printf 'installed-current\n' >"${BATS_TEST_TMPDIR}/service"
  : >"${BATS_TEST_TMPDIR}/mutations"
  cat >"${BATS_TEST_TMPDIR}/payload/vendor" <<'SH'
#!/bin/bash
set -eu
tool="$(basename "${0}")"
printf '%s %s\n' "${tool}" "$*" >>"${TEST_FIXTURE}/calls"
if [ "$*" = --version ]; then
  case "${tool}" in
    claude) sed -n 's/^claude_code_version=\(.*\)$/\1 (Claude Code)/p' "${TEST_FIXTURE}/versions.lock" ;;
    codex) sed -n 's/^codex_version=\(.*\)$/codex-cli \1/p' "${TEST_FIXTURE}/versions.lock" ;;
    t3) sed -n 's/^t3_version=\(.*\)$/t3 v\1/p' "${TEST_FIXTURE}/versions.lock" ;;
  esac
  exit 0
fi
case "${tool}:$*" in
  'claude:auth status --json')
    case "${TEST_CLAUDE_AUTH:-logged-in}" in
      logged-in) printf '{\n  "loggedIn": true\n}\n' ;;
      logged-out) printf '{\n  "loggedIn": false\n}\n' ;;
      *) printf 'unrecognized\n' ;;
    esac ;;
  'claude:auth status --help') [ "${TEST_CLAUDE_AUTH:-logged-in}" != unsupported ] ;;
  'codex:login status')
    case "${TEST_CODEX_AUTH:-logged-in}" in
      logged-in) printf 'Logged in using ChatGPT\n' ;;
      logged-out) printf 'Not logged in\n' ;;
      *) printf 'unrecognized\n' ;;
    esac ;;
  'codex:login status --help') [ "${TEST_CODEX_AUTH:-logged-in}" != unsupported ] ;;
  't3:service status') cat "${TEST_FIXTURE}/t3-fixtures/service-status/$(cat "${TEST_FIXTURE}/service")" ;;
  't3:service install')
    printf 'service install\n' >>"${TEST_FIXTURE}/mutations"
    [ "${TEST_SERVICE_FAIL:-0}" = 0 ] || exit 1
    printf 'installed-current\n' >"${TEST_FIXTURE}/service" ;;
  't3:connect status --json') cat "${TEST_FIXTURE}/t3-fixtures/connect-status/${TEST_CONNECT:-healthy}" ;;
  *) exit 97 ;;
esac
SH
  for tool in claude codex t3; do
    cp "${BATS_TEST_TMPDIR}/payload/vendor" "${BATS_TEST_TMPDIR}/payload/${tool}"
    chmod 0755 "${BATS_TEST_TMPDIR}/payload/${tool}"
    cp "${BATS_TEST_TMPDIR}/payload/${tool}" "${prefix}/bin/${tool}"
  done
  cat >"${BIN}/npm" <<'SH'
#!/bin/bash
set -eu
[ "$#" = 5 ] && [ "${1} ${2} ${3}" = 'install --global --prefix' ] || exit 97
[ "${4}" = "${HOME}/.local/harbor/npm" ] || exit 97
case "${5}" in
  @anthropic-ai/claude-code@*) tool=claude ;;
  @openai/codex@*) tool=codex ;;
  t3@*) tool=t3 ;;
  *) exit 97 ;;
esac
printf 'install %s\n' "${tool}" >>"${TEST_FIXTURE}/mutations"
[ "${TEST_INSTALL_FAIL:-}" != "${tool}" ] || exit 1
mkdir -p "${4}/bin"
cp "${TEST_FIXTURE}/payload/${tool}" "${4}/bin/${tool}"
SH
  cat >"${BIN}/systemctl" <<'SH'
#!/bin/bash
[ "$*" = '--user is-active t3code.service' ] || exit 97
if [ "$(cat "${TEST_FIXTURE}/service")" = installed-current ]; then
  printf 'active\n'
else
  printf 'inactive\n'
  exit 3
fi
SH
  for tool in sudo claude codex t3; do
    printf '#!/bin/bash\nexit 97\n' >"${BIN}/${tool}"
  done
  chmod 0755 "${BIN}/"*
}

@test "healthy rerun makes no vendor mutations or new ownership claims" {
  rm "${FIX_HOME}/.local/harbor/npm/bin/claude" "${FIX_HOME}/.local/harbor/npm/bin/codex" "${FIX_HOME}/.local/harbor/npm/bin/t3"
  printf 'not-installed\n' >"${BATS_TEST_TMPDIR}/service"
  run provision
  assert_success
  assert_equal "$(cat "${BATS_TEST_TMPDIR}/mutations")" 'install claude
install codex
install t3
service install'
  before="$(grep -l -e '"ownership": "created"' -e '"ownership": "modified"' "${FIX_ROOT}/journal/"*.json)"
  : >"${BATS_TEST_TMPDIR}/mutations"
  run provision
  assert_success
  assert [ ! -s "${BATS_TEST_TMPDIR}/mutations" ]
  assert_equal "$(grep -l -e '"ownership": "created"' -e '"ownership": "modified"' "${FIX_ROOT}/journal/"*.json)" "${before}"
  run grep '"phase": "prepared"' "${FIX_ROOT}/journal/"*.json
  assert_equal "${status}" 1
}

@test "connect login is attended and names harbor auth connect" {
  run provision TEST_CONNECT=needs-login
  assert_equal "${status}" 1
  assert_output --partial needs_connect_login
  assert_output --partial 'harbor auth connect'
}

@test "connect link is attended and names the PR 5 link step" {
  run provision TEST_CONNECT=needs-link
  assert_equal "${status}" 1
  assert_output --partial needs_connect_link
  assert_output --partial 'PR 5'
  assert_output --partial 'harbor auth connect'
}

@test "missing and unsupported relays are degraded with the vendor status word" {
  for relay in missing unsupported; do
    run provision TEST_CONNECT="relay-${relay}"
    assert_equal "${status}" 1
    assert_output --partial degraded
    assert_output --partial "relayClient.status=${relay}"
    assert_output --partial 'harbor service'
  done
}

@test "unparseable connect status and undesired connect never pass" {
  run provision TEST_CONNECT=unparseable
  assert_equal "${status}" 1
  assert_output --partial unknown
  sed 's/"desired": true/"desired": false/' "${BATS_TEST_TMPDIR}/t3-fixtures/connect-status/healthy" >"${BATS_TEST_TMPDIR}/t3-fixtures/connect-status/undesired"
  run provision TEST_CONNECT=undesired
  assert_equal "${status}" 1
  assert_output --partial unknown
  # The note must not offer harbor auth connect as the remedy. That command branches
  # on authenticated and linked alone and answers a true:true pair with "nothing to
  # do" and exit 0, so presenting it here would be an attended step no command can
  # satisfy -- the defect this task refuses for unsupported. Asserting the two claims
  # that carry that rather than refuting a phrasing: a refutation of "harbor auth
  # connect" cannot distinguish naming it as the fix from naming it to say it is not,
  # and the note does the second deliberately, because that is the command an
  # operator reaches for first.
  assert_output --partial 'desired=false'
  assert_output --partial 'Harbor ships no command'
}

@test "unknown anywhere in connect wins over a partial login or link answer" {
  sed 's/"linked": false/"linked": null/' "${BATS_TEST_TMPDIR}/t3-fixtures/connect-status/needs-login" >"${BATS_TEST_TMPDIR}/t3-fixtures/connect-status/partial"
  run provision TEST_CONNECT=partial
  assert_equal "${status}" 1
  assert_output --partial unknown
  refute_output --partial needs_connect_login
}

@test "logged-out and unknown agent states name the CLI auth and repeat after later rows" {
  for state in logged-out unknown; do
    run provision TEST_CLAUDE_AUTH="${state}" TEST_CODEX_AUTH="${state}"
    assert_equal "${status}" 1
    assert_output --partial 'harbor auth claude'
    assert_output --partial 'harbor auth codex'
    assert_output --partial 'step: provision-access-mode'
    notes="$(printf '%s\n' "${output}" | sed -n '/provision.attended:/,$p')"
    assert_equal "$(printf '%s\n' "${notes}" | grep -c 'harbor auth')" 2
  done
}

@test "unsupported agent auth is informational once per tool and contributes zero" {
  run provision TEST_CLAUDE_AUTH=unsupported TEST_CODEX_AUTH=unsupported
  assert_success
  assert_equal "$(printf '%s\n' "${output}" | grep -c 'auth_status_unsupported: claude')" 1
  assert_equal "$(printf '%s\n' "${output}" | grep -c 'auth_status_unsupported: codex')" 1
  refute_output --partial 'provision.attended:'
}

@test "invalid existing access mode refuses before runtime calls and is preserved" {
  mkdir -p "${FIX_HOME}/.config/harbor"
  printf 'access_mode=tailnet\n' >"${FIX_HOME}/.config/harbor/config"
  chmod 0600 "${FIX_HOME}/.config/harbor/config"
  run provision
  assert_equal "${status}" 3
  assert_output --partial config.tailnet
  assert_equal "$(cat "${FIX_HOME}/.config/harbor/config")" access_mode=tailnet
  assert [ ! -e "${BATS_TEST_TMPDIR}/calls" ]
}

@test "failed runtime installs leave prepared and stop subsequent rows" {
  for tool in claude codex t3; do
    rm -rf "${FIX_ROOT}"
    cp "${BATS_TEST_TMPDIR}/payload/claude" "${FIX_HOME}/.local/harbor/npm/bin/claude"
    cp "${BATS_TEST_TMPDIR}/payload/codex" "${FIX_HOME}/.local/harbor/npm/bin/codex"
    rm -f "${FIX_HOME}/.local/harbor/npm/bin/${tool}"
    run provision TEST_INSTALL_FAIL="${tool}"
    assert_equal "${status}" 2
    assert_output --partial 'stays prepared'
    assert_equal "$(entry_phase "${FIX_ROOT}" 0002)" prepared
    case "${tool}" in
      claude | codex) refute_output --partial 'step: provision-runtime-auth' ;;
      t3) refute_output --partial 'step: provision-vendor-service' ;;
    esac
  done
}

@test "missing engines and incompatible engines stop before service with 2 and 3" {
  package="${FIX_HOME}/.local/harbor/npm/node_modules/t3/package.json"
  rm "${package}"
  run provision
  assert_equal "${status}" 2
  refute_output --partial 'step: provision-vendor-service'
  printf '{\n  "engines": {\n    "node": ">=999.0.0"\n  }\n}\n' >"${package}"
  run provision
  assert_equal "${status}" 3
  refute_output --partial 'step: provision-vendor-service'
}

@test "service apply failure leaves prepared and stops before access mode" {
  printf 'not-installed\n' >"${BATS_TEST_TMPDIR}/service"
  run provision TEST_SERVICE_FAIL=1
  assert_equal "${status}" 2
  assert_equal "$(entry_phase "${FIX_ROOT}" 0002)" prepared
  refute_output --partial 'step: provision-access-mode'
}

@test "unknown service pre-state refuses without service mutation or prepared entry" {
  printf 'unrecognized-text\n' >"${BATS_TEST_TMPDIR}/service"
  run provision
  assert_equal "${status}" 3
  assert_output --partial t3.service_unknown
  assert [ ! -s "${BATS_TEST_TMPDIR}/mutations" ]
  refute_output --partial 'step: provision-access-mode'
  run grep '"phase": "prepared"' "${FIX_ROOT}/journal/"*.json
  assert_equal "${status}" 1
}

@test "config apply failure leaves prepared and stops before runtime install" {
  cat >"${BIN}/mv" <<'SH'
#!/bin/bash
for arg in "$@"; do
  [ "${arg}" != "${HOME}/.config/harbor/config" ] || exit 1
done
exec /bin/mv "$@"
SH
  chmod 0755 "${BIN}/mv"
  run provision
  assert_equal "${status}" 2
  assert_output --partial config.rename
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" prepared
  assert [ ! -e "${FIX_HOME}/.config/harbor/config" ]
  assert [ ! -e "${BATS_TEST_TMPDIR}/calls" ]
  refute_output --partial 'step: provision-runtime-install'
}

@test "journal initialization failure is broken and stops before config creation" {
  cat >"${BIN}/mkdir" <<'SH'
#!/bin/bash
for arg in "$@"; do
  [ "${arg}" != "${HOME}/.local/state/harbor/journal" ] || exit 1
done
exec /bin/mkdir "$@"
SH
  chmod 0755 "${BIN}/mkdir"
  run provision
  assert_equal "${status}" 2
  assert_output --partial provision.journal
  assert [ ! -e "${FIX_HOME}/.config/harbor/config" ]
  assert [ ! -e "${BATS_TEST_TMPDIR}/calls" ]
  refute_output --partial 'step: provision-runtime-install'
}
