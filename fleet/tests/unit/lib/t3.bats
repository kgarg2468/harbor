#!/usr/bin/env bats
load '../test_helper'

setup() {
  # The sibling libraries own the lock, journal, lock values, prefix, and recovery
  # registry. Source runtime and agents before t3 so its reader can register.
  # shellcheck source=lib/log.sh
  . "${HARBOR_ROOT}/lib/log.sh"
  # shellcheck source=lib/lock.sh
  . "${HARBOR_ROOT}/lib/lock.sh"
  # shellcheck source=lib/versions.sh
  . "${HARBOR_ROOT}/lib/versions.sh"
  # shellcheck source=lib/journal.sh
  . "${HARBOR_ROOT}/lib/journal.sh"
  # shellcheck source=lib/runtime.sh
  . "${HARBOR_ROOT}/lib/runtime.sh"
  # shellcheck source=lib/agents.sh
  . "${HARBOR_ROOT}/lib/agents.sh"
  fixture_state_root
  HARBOR_PID="$$"
  # The ambient HOME is a decoy for this whole file: it exists, it is not FIX_HOME,
  # and tests seed agent executables of their own into it, so every path and every
  # version below is shown to follow the parameter rather than the environment.
  DECOY_HOME="${BATS_TEST_TMPDIR}/decoy"
  mkdir -p "${DECOY_HOME}"
  HOME="${DECOY_HOME}"
  # npm resolves to a fake one in a directory this file owns. It starts as a refusal
  # rather than as nothing, so that a test which forgets to install a fake npm fails
  # loudly here instead of reaching the machine's real npm and installing a package
  # into a real prefix; 97 is the same "this is a test error" code the vendor shim
  # uses for a missing fixture.
  FAKE_BIN="${BATS_TEST_TMPDIR}/fakebin"
  mkdir -p "${FAKE_BIN}"
  NPM_LOG="${BATS_TEST_TMPDIR}/npm.log"
  refusing_npm
  PATH="${FAKE_BIN}:${PATH}"
  refusing_agent_clis
  # The real lock, so the strings the parser is measured against are the pinned
  # releases' own and a version bump moves the fixtures with it.
  harbor_versions_load "${HARBOR_ROOT}/versions.lock"
  T3_VERSION="$(harbor_version_require t3_version)"
  T3_SPEC="$(harbor_version_require t3_install)"
  T3_SPEC="${T3_SPEC#npm:}"
  T3_OUT="t3 v${T3_VERSION}"
  # shellcheck source=lib/t3.sh
  . "${HARBOR_ROOT}/lib/t3.sh"
}

fake_agent() {
  # fake_agent HOME AGENT TEXT: an executable at AGENT's path under HOME that prints
  # TEXT, standing in for the vendor CLI answering --version
  local bin
  bin="$(harbor_t3_bin "${1}")"
  mkdir -p "$(dirname "${bin}")"
  printf "#!/bin/sh\ncat <<'EOF'\n%s\nEOF\n" "${3}" >"${bin}"
  chmod 0755 "${bin}"
}

failing_agent() {
  # failing_agent HOME AGENT: an executable that exits non-zero, as a half-installed
  # or broken package does
  local bin
  bin="$(harbor_t3_bin "${1}")"
  mkdir -p "$(dirname "${bin}")"
  printf '#!/bin/sh\nexit 1\n' >"${bin}"
  chmod 0755 "${bin}"
}

assert_unreadable() {
  # assert_unreadable AGENT TEXT: AGENT's CLI printing TEXT is exit 2 quoting the
  # raw text and naming the executable, rather than any version guessed out of it
  fake_agent "${FIX_HOME}" "${1}" "${2}"
  run harbor_t3_installed_version "${FIX_HOME}"
  assert_equal "${status}" 2
  assert_output --partial 't3.unreadable'
  assert_output --partial "printed '${2}'"
  assert_output --partial "$(harbor_t3_bin "${FIX_HOME}")"
}

tree_snapshot() {
  # Every path under the two fixture homes with its mode, owner, size, and mtime, so
  # a function that created, removed, or rewrote anything shows up as a difference
  find "${FIX_HOME}" "${DECOY_HOME}" -exec ls -ldn {} + | sort
}

decoy_snapshot() {
  # The same, for the ambient HOME alone: what an install that read the environment
  # instead of its HOME parameter would disturb
  find "${DECOY_HOME}" -exec ls -ldn {} + | sort
}

refusing_npm() {
  # The npm every test starts with: it records the call and refuses. A test that
  # arranges no npm of its own must not reach the machine's real npm and install a
  # package into a real prefix, so the default is a refusal rather than nothing, and
  # 97 is the code the vendor shim already uses for "this is a defect in the test".
  {
    printf '#!/bin/sh\n'
    printf 'printf "%%s\\n" "$*" >>"%s"\n' "${NPM_LOG}"
    printf 'echo "npm: this test arranged no npm of its own" >&2\n'
    printf 'exit 97\n'
  } >"${FAKE_BIN}/npm"
  chmod 0755 "${FAKE_BIN}/npm"
}

refusing_agent_clis() {
  # Seal all three vendor CLI names on PATH. T3 calls use its absolute fixture
  # path; an accidental bare CLI must refuse before reaching a real installation.
  local agent
  for agent in claude codex t3; do
    {
      printf '#!/bin/sh\n'
      printf 'echo "%s: a test invoked the real CLI by name; lib/t3.sh never does" >&2\n' "${agent}"
      printf 'exit 97\n'
    } >"${FAKE_BIN}/${agent}"
    chmod 0755 "${FAKE_BIN}/${agent}"
  done
}

fake_npm() {
  # fake_npm AGENT TEXT: an npm that records its argv and then, as the real one does,
  # leaves AGENT's executable in the bin directory of the prefix its own --prefix
  # argument names. That executable prints TEXT for --version, so a test chooses what
  # the package turns out to have installed rather than assuming it was the lock.
  local payload="${BATS_TEST_TMPDIR}/payload.${1}"
  printf "#!/bin/sh\ncat <<'EOF'\n%s\nEOF\n" "${2}" >"${payload}"
  chmod 0755 "${payload}"
  {
    printf '#!/bin/sh\n'
    printf 'printf "%%s\\n" "$*" >>"%s"\n' "${NPM_LOG}"
    printf 'prefix=""\n'
    printf 'while [ "$#" -gt 0 ]; do\n'
    printf '  if [ "${1}" = --prefix ]; then\n'
    printf '    prefix="${2}"\n'
    printf '    shift 2\n'
    printf '  else\n'
    printf '    shift\n'
    printf '  fi\n'
    printf 'done\n'
    printf 'mkdir -p "${prefix}/bin"\n'
    printf 'cp "%s" "${prefix}/bin/%s"\n' "${payload}" "${1}"
    printf 'chmod 0755 "${prefix}/bin/%s"\n' "${1}"
  } >"${FAKE_BIN}/npm"
  chmod 0755 "${FAKE_BIN}/npm"
}

failing_npm() {
  # failing_npm: an npm that records its argv, installs nothing, and fails the way a
  # registry error does, with its reason in its own output and nowhere else
  {
    printf '#!/bin/sh\n'
    printf 'printf "%%s\\n" "$*" >>"%s"\n' "${NPM_LOG}"
    printf 'echo "npm error code E404" >&2\n'
    printf 'echo "npm error 404 Not Found - GET https://registry.npmjs.org/nope" >&2\n'
    printf 'exit 1\n'
  } >"${FAKE_BIN}/npm"
  chmod 0755 "${FAKE_BIN}/npm"
}

write_install_lock() {
  # write_install_lock VALUE: a lock carrying VALUE as t3_install and the
  # pinned version beside it, every other key empty, so a malformed install method
  # can be driven without editing the repository's own lock
  local k
  BAD_LOCK="${BATS_TEST_TMPDIR}/versions.lock"
  : >"${BAD_LOCK}"
  for k in ${HARBOR_VERSION_KEYS}; do
    case "${k}" in
      t3_version) printf 't3_version=%s\n' "${T3_VERSION}" ;;
      t3_install) printf 't3_install=%s\n' "${1}" ;;
      *) printf '%s=\n' "${k}" ;;
    esac >>"${BAD_LOCK}"
  done
  harbor_versions_load "${BAD_LOCK}"
}

acquire() {
  harbor_lock_acquire "${FIX_ROOT}" operator
}

journal_names() {
  ls -A "${FIX_ROOT}/journal"
}

@test "t3 installed at another version is replaced and journaled modified with the prior version as pre_state" {
  fake_agent "${FIX_HOME}" t3 "t3 v1.0.0"
  fake_npm t3 "${T3_OUT}"
  acquire
  run harbor_t3_install "${FIX_ROOT}" "${FIX_HOME}"
  assert_success
  assert_equal "$(harbor_t3_installed_version "${FIX_HOME}")" "${T3_VERSION}"
  assert_equal "$(journal_names)" 0001-runtime-install.json
  assert_equal "$(entry_raw "${FIX_ROOT}" 0001 ownership)" '"modified"'
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" applied
  assert_equal "$(entry_raw "${FIX_ROOT}" 0001 pre_state)" '"1.0.0"'
  assert_equal "$(entry_raw "${FIX_ROOT}" 0001 post_state)" "\"${T3_VERSION}\""
  # The version now matches the lock, so a rerun is the no-op below: converging.
  : >"${NPM_LOG}"
  run harbor_t3_install "${FIX_ROOT}" "${FIX_HOME}"
  assert_success
  assert [ ! -s "${NPM_LOG}" ]
  assert_equal "$(journal_names)" 0001-runtime-install.json
  harbor_lock_release "${FIX_ROOT}"
}

@test "an installed version that already equals the lock is a no-op: no npm call, no entry, nothing touched" {
  fake_agent "${FIX_HOME}" t3 "${T3_OUT}"
  acquire
  local before
  before="$(tree_snapshot)"
  run harbor_t3_install "${FIX_ROOT}" "${FIX_HOME}"
  assert_success
  # The comparison happens before anything acts, so npm is never reached at all.
  assert [ ! -s "${NPM_LOG}" ]
  assert_equal "$(journal_names)" ""
  assert_equal "$(tree_snapshot)" "${before}"
  harbor_lock_release "${FIX_ROOT}"
}

@test "an npm install that fails leaves the entry prepared and exits 2 naming the entry and the vendor output" {
  failing_npm
  acquire
  run harbor_t3_install "${FIX_ROOT}" "${FIX_HOME}"
  assert_equal "${status}" 2
  assert_output --partial 't3.install_failed'
  assert_output --partial "${T3_SPEC}"
  assert_output --partial 'E404'
  assert_output --partial '0001-runtime-install.json'
  assert_equal "$(journal_names)" 0001-runtime-install.json
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" prepared
  assert_equal "$(entry_raw "${FIX_ROOT}" 0001 pre_state)" '"absent"'
  assert_equal "$(harbor_t3_installed_version "${FIX_HOME}")" absent
  # The home holds pre_state, so recovery decides the entry rather than blocking.
  HARBOR_AGENTS_HOME="${FIX_HOME}"
  run harbor_journal_recover "${FIX_ROOT}"
  assert_success
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" reverted
  harbor_lock_release "${FIX_ROOT}"
}

@test "an npm install that reports success but leaves another version behind stays prepared and exits 2" {
  fake_npm t3 't3 v9.9.9'
  acquire
  run harbor_t3_install "${FIX_ROOT}" "${FIX_HOME}"
  assert_equal "${status}" 2
  assert_output --partial 't3.verify'
  assert_output --partial 9.9.9
  assert_output --partial "${T3_SPEC}"
  assert_output --partial '0001-runtime-install.json'
  assert_equal "$(journal_names)" 0001-runtime-install.json
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" prepared
  assert_equal "$(entry_raw "${FIX_ROOT}" 0001 post_state)" "\"${T3_VERSION}\""
  # What is there is neither recorded state, so recovery blocks on it by name rather
  # than calling an entry applied that vouches for a version nothing reports.
  HARBOR_AGENTS_HOME="${FIX_HOME}"
  run --separate-stderr harbor_journal_recover "${FIX_ROOT}"
  assert_equal "${status}" 2
  assert_regex "${stderr}" 'journal entry 0001-runtime-install.json is undecidable:'
  assert_regex "${stderr}" 'observed:   "9\.9\.9"'
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" prepared
  harbor_lock_release "${FIX_ROOT}"
}

@test "HARBOR_FAIL_AFTER between the install and the applied write leaves a prepared entry recovery decides through the dispatcher" {
  # The crash window of design section 3.7: npm has left the agent in the prefix and
  # the applied write never happened. The child holds its own lock and is killed at
  # that boundary by the only test hook Harbor has.
  fake_npm t3 "${T3_OUT}"
  run env HARBOR_TEST_HOOKS=1 HARBOR_FAIL_AFTER=t3-installed \
    bash -c '. "${HARBOR_ROOT}/lib/log.sh"; . "${HARBOR_ROOT}/lib/lock.sh"; . "${HARBOR_ROOT}/lib/versions.sh"; . "${HARBOR_ROOT}/lib/journal.sh"; . "${HARBOR_ROOT}/lib/runtime.sh"; . "${HARBOR_ROOT}/lib/agents.sh"; . "${HARBOR_ROOT}/lib/t3.sh"; HARBOR_PID=$$; harbor_versions_load "${HARBOR_ROOT}/versions.lock"; harbor_lock_acquire "${1}" operator; harbor_t3_install "${1}" "${2}"' \
    _ "${FIX_ROOT}" "${FIX_HOME}"
  assert_equal "${status}" 137
  assert_equal "$(harbor_t3_installed_version "${FIX_HOME}")" "${T3_VERSION}"
  assert_equal "$(journal_names)" 0001-runtime-install.json
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" prepared
  # The killed child left its lock behind; production reclaims it, this test removes
  # it so recovery runs under a lock this process owns.
  rm -rf "${FIX_ROOT}/lock.d"
  acquire
  # What the provision preflight sets before recovery runs, and the only thing that
  # tells the registered reader which home to look in.
  HARBOR_AGENTS_HOME="${FIX_HOME}"
  run harbor_journal_recover "${FIX_ROOT}"
  assert_success
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" applied
  # The other side of the same window: npm had not landed, so the agent is absent,
  # that is the entry's pre_state, and recovery reverts it.
  rm -f "$(harbor_t3_bin "${FIX_HOME}")"
  fixture_entry "${FIX_ROOT}" 0002 runtime-install t3 created prepared '"absent"' "\"${T3_VERSION}\""
  run harbor_journal_recover "${FIX_ROOT}"
  assert_success
  assert_equal "$(entry_phase "${FIX_ROOT}" 0002)" reverted
  # Deciding an entry inspects only: nothing was installed or reinstalled.
  assert_equal "$(cat "${NPM_LOG}")" "install --global --prefix $(harbor_agents_prefix "${FIX_HOME}") ${T3_SPEC}"
  harbor_lock_release "${FIX_ROOT}"
}

@test "paths and version inspection follow the home parameter without creating anything" {
  local before
  before="$(tree_snapshot)"
  assert_equal "$(harbor_t3_bin "${FIX_HOME}")" "$(harbor_agents_prefix "${FIX_HOME}")/bin/t3"
  assert_equal "$(harbor_t3_package_dir "${FIX_HOME}")" "$(harbor_agents_prefix "${FIX_HOME}")/node_modules/t3"
  assert_equal "$(harbor_t3_installed_version "${FIX_HOME}")" absent
  assert_equal "$(tree_snapshot)" "${before}"
  fake_agent "${DECOY_HOME}" t3 't3 v9.9.9'
  fake_agent "${FIX_HOME}" t3 "${T3_OUT}"
  assert_equal "$(harbor_t3_installed_version "${FIX_HOME}")" "${T3_VERSION}"
  assert_equal "$(harbor_t3_installed_version "${DECOY_HOME}")" 9.9.9
  chmod 0644 "$(harbor_t3_bin "${FIX_HOME}")"
  assert_equal "$(harbor_t3_installed_version "${FIX_HOME}")" absent
}

@test "failed and malformed version answers are exit 2, never a guessed version" {
  local text
  failing_agent "${FIX_HOME}" t3
  run harbor_t3_installed_version "${FIX_HOME}"
  assert_failure 2
  assert_output --partial '--version failed'
  for text in '' hello "${T3_VERSION}" "t3 ${T3_VERSION}" 't3 v1..2' 't3 v1.2.3.4' 't3 v1.2.x' 't3 v1.2.3 suffix' 'codex-cli 1.2.3'; do
    assert_unreadable t3 "${text}"
  done
}

@test "an absent t3 is installed at the locked spec with one created applied entry" {
  fake_npm t3 "${T3_OUT}"
  acquire
  run harbor_t3_install "${FIX_ROOT}" "${FIX_HOME}"
  assert_success
  assert_equal "$(cat "${NPM_LOG}")" "install --global --prefix $(harbor_agents_prefix "${FIX_HOME}") ${T3_SPEC}"
  assert_equal "$(harbor_stat_mode "$(harbor_agents_prefix "${FIX_HOME}")")" 0755
  assert_equal "$(journal_names)" 0001-runtime-install.json
  assert_equal "$(entry_raw "${FIX_ROOT}" 0001 target)" '"t3"'
  assert_equal "$(entry_raw "${FIX_ROOT}" 0001 ownership)" '"created"'
  assert_equal "$(entry_raw "${FIX_ROOT}" 0001 pre_state)" '"absent"'
  assert_equal "$(entry_raw "${FIX_ROOT}" 0001 post_state)" "\"${T3_VERSION}\""
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" applied
  harbor_journal_validate "${FIX_ROOT}/journal/0001-runtime-install.json"
  harbor_lock_release "${FIX_ROOT}"
}

@test "the source-time reader follows HARBOR_AGENTS_HOME and never falls back to HOME" {
  assert_equal "$(harbor_runtime_reader_for t3)" harbor_t3_reader
  fake_agent "${DECOY_HOME}" t3 't3 v9.9.9'
  unset HARBOR_AGENTS_HOME
  run harbor_journal_observe runtime-install t3
  assert_failure 2
  assert_output --partial agents.home_unset
  HARBOR_AGENTS_HOME="${FIX_HOME}"
  assert_equal "$(harbor_journal_observe runtime-install t3)" '"absent"'
  fake_agent "${FIX_HOME}" t3 "${T3_OUT}"
  assert_equal "$(harbor_journal_observe runtime-install t3)" "\"${T3_VERSION}\""
  HARBOR_AGENTS_HOME="${DECOY_HOME}"
  assert_equal "$(harbor_journal_observe runtime-install t3)" '"9.9.9"'
}

package_fixture() {
  local package
  package="$(harbor_t3_package_dir "${FIX_HOME}")/package.json"
  mkdir -p "$(dirname "${package}")"
  cat >"${package}" <<'JSON'
{
  "volta": {
    "node": "wrong-before"
  },
  "engines": {
    "node": "^22.16 || ^23.11 || >=24.10"
  },
  "other": {
    "node": "wrong-after"
  }
}
JSON
}

@test "package engines is read only inside the anchored engines object" {
  package_fixture
  run harbor_t3_package_engines "${FIX_HOME}"
  assert_success
  assert_output '^22.16 || ^23.11 || >=24.10'
  assert_equal "${output}" "$(harbor_version_require t3_engines_node)"
}

@test "absent, unreadable, and engines-less packages are exit 2 naming the package" {
  local package
  package="$(harbor_t3_package_dir "${FIX_HOME}")/package.json"
  run harbor_t3_package_engines "${FIX_HOME}"
  assert_failure 2
  assert_output --partial "${package}"
  package_fixture
  chmod 000 "${package}"
  run harbor_t3_package_engines "${FIX_HOME}"
  chmod 0600 "${package}"
  assert_failure 2
  assert_output --partial "${package}"
  printf '{\n  "volta": {\n    "node": "wrong"\n  }\n}\n' >"${package}"
  run harbor_t3_package_engines "${FIX_HOME}"
  assert_failure 2
  assert_output --partial "${package}"
}

fake_runnable_t3() {
  # Version queries are inspection; record only the operation beyond that gate, with
  # one argument per line so spaces and empty arguments cannot disappear unnoticed.
  local bin
  bin="$(harbor_t3_bin "${FIX_HOME}")"
  mkdir -p "$(dirname "${bin}")"
  {
    printf '#!/bin/sh\n'
    printf 'if [ "${1:-}" = --version ]; then echo "t3 v%s"; exit 0; fi\n' "${1}"
    printf 'printf "<%%s>\\n" "$@" >"%s/vendor.log"\n' "${BATS_TEST_TMPDIR}"
    printf 'echo vendor-output\nexit 7\n'
  } >"${bin}"
  chmod 0755 "${bin}"
}

@test "run refuses absent or mismatched versions with exit 3 and makes no vendor operation call" {
  run harbor_t3_run "${FIX_HOME}" service status
  assert_failure 3
  assert_output --partial 'harbor provision'
  fake_runnable_t3 9.9.9
  run harbor_t3_run "${FIX_HOME}" service status
  assert_failure 3
  assert_output --partial 'harbor provision'
  assert [ ! -e "${BATS_TEST_TMPDIR}/vendor.log" ]
}

@test "run logs the locked vendor call, preserves arguments, output, and exit status" {
  fake_runnable_t3 "${T3_VERSION}"
  harbor_log_open "${BATS_TEST_TMPDIR}/harbor.log" 0600
  run harbor_t3_run "${FIX_HOME}" service 'two words' ''
  assert_failure 7
  assert_output vendor-output
  assert_equal "$(cat "${BATS_TEST_TMPDIR}/vendor.log")" "$(printf '<service>\n<two words>\n<>')"
  assert grep -qF "vendor $(harbor_t3_bin "${FIX_HOME}") service" "${BATS_TEST_TMPDIR}/harbor.log"
}

@test "install and inspection leave the ambient home, systemd user files, and T3 home untouched" {
  local before protected
  export T3_HOME="${FIX_HOME}/t3-home"
  mkdir -p "${T3_HOME}" "${FIX_HOME}/.config/systemd/user"
  printf 'sentinel\n' >"${T3_HOME}/sentinel"
  printf 'sentinel\n' >"${FIX_HOME}/.config/systemd/user/sentinel"
  before="$(decoy_snapshot)"
  protected="$(find "${T3_HOME}" "${FIX_HOME}/.config" -exec ls -ldn {} + | sort)"
  fake_npm t3 "${T3_OUT}"
  acquire
  run harbor_t3_install "${FIX_ROOT}" "${FIX_HOME}"
  assert_success
  package_fixture
  harbor_t3_package_engines "${FIX_HOME}" >/dev/null
  harbor_t3_run "${FIX_HOME}" service status >/dev/null
  assert_equal "$(decoy_snapshot)" "${before}"
  assert_equal "$(find "${T3_HOME}" "${FIX_HOME}/.config" -exec ls -ldn {} + | sort)" "${protected}"
  harbor_lock_release "${FIX_ROOT}"
}

@test "an unsupported install method refuses before any journal, prefix, or npm call" {
  local bad
  for bad in 'tarball:t3@0.0.38' 'npm:t3' 'npm:@0.0.38' 'npm:'; do
    write_install_lock "${bad}"
    run harbor_t3_install "${FIX_ROOT}" "${FIX_HOME}"
    assert_failure 3
    assert_output --partial t3.install_method
    assert_output --partial "${BAD_LOCK}"
    assert [ ! -s "${NPM_LOG}" ]
    assert_equal "$(journal_names)" ''
    assert [ ! -e "$(harbor_agents_prefix "${FIX_HOME}")" ]
  done
}

fake_service_t3() {
  # The real run seam still checks --version; only the formatter and exit are fake.
  local bin
  bin="$(harbor_t3_bin "${FIX_HOME}")"
  mkdir -p "$(dirname "${bin}")"
  cp "${HARBOR_ROOT}/tests/fixtures/t3/service-status/${1}" "${BATS_TEST_TMPDIR}/service-body"
  {
    printf '#!/bin/sh\n'
    printf 'if [ "${1:-}" = --version ]; then echo "t3 v%s"; exit 0; fi\n' "${T3_VERSION}"
    printf 'printf "%%s\\n" "$*" >"%s/service-call"\n' "${BATS_TEST_TMPDIR}"
    printf '[ "$*" = "service status" ] || exit 97\n'
    printf 'cat "%s/service-body"\nexit %s\n' "${BATS_TEST_TMPDIR}" "${2:-0}"
  } >"${bin}"
  chmod 0755 "${bin}"
}

fake_systemctl() {
  # A fixture executable seals the systemctl name, including on macOS.
  {
    printf '#!/bin/sh\n'
    printf 'printf "%%s\\n" "$HOME" "$*" >"%s/systemctl-call"\n' "${BATS_TEST_TMPDIR}"
    printf '[ "$*" = "--user is-active t3code.service" ] || exit 97\n'
    printf "cat <<'BODY'\n%s\nBODY\nexit %s\n" "${1}" "${2:-0}"
  } >"${FAKE_BIN}/systemctl"
  chmod 0755 "${FAKE_BIN}/systemctl"
}

@test "service formatter fixtures classify by whole status lines" {
  local fixture expected
  for fixture in installed-current update-pending not-installed unsupported installed-other-version unrecognized-text empty; do
    expected="${fixture}"
    case "${fixture}" in installed-other-version | unrecognized-text | empty) expected=unknown ;; esac
    fake_service_t3 "${fixture}"
    run harbor_t3_service_status "${FIX_HOME}"
    assert_success
    assert_output "${expected}"
    assert_equal "$(cat "${BATS_TEST_TMPDIR}/service-call")" 'service status'
  done
}

@test "service status body wins over nonzero exits and zero never makes unknown text current" {
  local fixture
  for fixture in installed-current update-pending not-installed unsupported; do
    fake_service_t3 "${fixture}" 7
    run harbor_t3_service_status "${FIX_HOME}"
    assert_success
    assert_output "${fixture}"
  done
  fake_service_t3 unrecognized-text 0
  run harbor_t3_service_status "${FIX_HOME}"
  assert_success
  assert_output unknown
}

@test "service phrases cannot come from a neighbouring path or have trailing text" {
  local phrase prefix suffix
  fake_service_t3 empty
  for phrase in "  Status: installed · t3@${T3_VERSION}" '  Status: needs an update or repair' '  Status: not installed' '  Status: unavailable on this machine'; do
    for prefix in '  Unit: /home/OPERATOR/' '  Logs: /home/OPERATOR/' ''; do
      suffix=''
      [ -n "${prefix}" ] || suffix=' extra'
      printf 'T3 Code service\n%s%s%s\n' "${prefix}" "${phrase}" "${suffix}" >"${BATS_TEST_TMPDIR}/service-body"
      run harbor_t3_service_status "${FIX_HOME}"
      assert_success
      assert_output unknown
    done
  done
}

@test "service current phrase follows the loaded lock and the run version gate" {
  fake_service_t3 installed-current
  T3_VERSION=0.0.37
  write_install_lock npm:t3@0.0.37
  # The executable still reports the old version: the seam refuses before status.
  run harbor_t3_service_status "${FIX_HOME}"
  assert_success
  assert_output unknown
  assert [ ! -e "${BATS_TEST_TMPDIR}/service-call" ]
  fake_service_t3 installed-current
  run harbor_t3_service_status "${FIX_HOME}"
  assert_success
  assert_output unknown
  fake_service_t3 installed-other-version
  run harbor_t3_service_status "${FIX_HOME}"
  assert_success
  assert_output installed-current
}

@test "service health requires current status and exactly active from systemctl" {
  local answer
  fake_service_t3 installed-current
  for answer in inactive 'active extra' ' active' "$(printf 'active\ninactive')" ''; do
    fake_systemctl "${answer}"
    run harbor_t3_service_healthy "${FIX_HOME}"
    assert_failure
    assert_output ''
  done
  fake_systemctl active 1
  run harbor_t3_service_healthy "${FIX_HOME}"
  assert_failure
  fake_systemctl active
  run harbor_t3_service_healthy "${FIX_HOME}"
  assert_success
  assert_output ''
  assert_equal "$(cat "${BATS_TEST_TMPDIR}/systemctl-call")" "$(printf '%s\n--user is-active t3code.service' "${FIX_HOME}")"
  rm "${BATS_TEST_TMPDIR}/systemctl-call"
  fake_service_t3 unrecognized-text
  run harbor_t3_service_healthy "${FIX_HOME}"
  assert_failure
  assert_output ''
  assert [ ! -e "${BATS_TEST_TMPDIR}/systemctl-call" ]
}

@test "service status and health do not write systemd user files or create vendor logs" {
  local before fixture
  mkdir -p "${FIX_HOME}/.config/systemd/user" "${DECOY_HOME}/.config/systemd/user"
  printf 'sentinel\n' >"${FIX_HOME}/.config/systemd/user/sentinel"
  fake_service_t3 installed-current
  fake_systemctl active
  before="$(tree_snapshot)"
  run harbor_t3_service_status "${FIX_HOME}"
  assert_success
  run harbor_t3_service_healthy "${FIX_HOME}"
  assert_success
  assert_equal "$(tree_snapshot)" "${before}"
  for fixture in update-pending not-installed unsupported unrecognized-text empty; do
    cp "${HARBOR_ROOT}/tests/fixtures/t3/service-status/${fixture}" "${BATS_TEST_TMPDIR}/service-body"
    run harbor_t3_service_healthy "${FIX_HOME}"
    assert_failure
    assert_equal "$(tree_snapshot)" "${before}"
  done
}
