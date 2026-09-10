#!/usr/bin/env bats
load '../test_helper'

setup() {
  # lib/agents.sh depends on lib/log.sh for harbor_die, on lib/versions.sh for the
  # keys harbor_agents_lock_key names, on lib/lock.sh and lib/journal.sh for the
  # journaled install, and on lib/runtime.sh for the registry it registers its two
  # readers in at source time. lib/runtime.sh therefore comes before lib/agents.sh,
  # exactly as node/provision.sh sources them. Version inspection still holds no lock
  # and writes no journal; only harbor_agents_install does either.
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
  # The real lock, so the strings the parser is measured against are the pinned
  # releases' own and a version bump moves the fixtures with it.
  harbor_versions_load "${HARBOR_ROOT}/versions.lock"
  CLAUDE_VERSION="$(harbor_version_require claude_code_version)"
  CODEX_VERSION="$(harbor_version_require codex_version)"
  # The npm spec each agent's install method names, with the method prefix stripped
  # the way harbor_agents_install strips it: what the vendor command line has to
  # carry, taken from the lock rather than spelled out here.
  CLAUDE_SPEC="$(harbor_version_require claude_code_install)"
  CLAUDE_SPEC="${CLAUDE_SPEC#npm:}"
  CODEX_SPEC="$(harbor_version_require codex_install)"
  CODEX_SPEC="${CODEX_SPEC#npm:}"
  # What the two CLIs print for --version at those pinned versions, captured from
  # the releases: both decorate the number, and each decorates it differently.
  CLAUDE_OUT="${CLAUDE_VERSION} (Claude Code)"
  CODEX_OUT="codex-cli ${CODEX_VERSION}"
}

fake_agent() {
  # fake_agent HOME AGENT TEXT: an executable at AGENT's path under HOME that prints
  # TEXT, standing in for the vendor CLI answering --version
  local bin
  bin="$(harbor_agents_bin "${2}" "${1}")"
  mkdir -p "$(dirname "${bin}")"
  printf "#!/bin/sh\ncat <<'EOF'\n%s\nEOF\n" "${3}" >"${bin}"
  chmod 0755 "${bin}"
}

failing_agent() {
  # failing_agent HOME AGENT: an executable that exits non-zero, as a half-installed
  # or broken package does
  local bin
  bin="$(harbor_agents_bin "${2}" "${1}")"
  mkdir -p "$(dirname "${bin}")"
  printf '#!/bin/sh\nexit 1\n' >"${bin}"
  chmod 0755 "${bin}"
}

assert_unreadable() {
  # assert_unreadable AGENT TEXT: AGENT's CLI printing TEXT is exit 2 quoting the
  # raw text and naming the executable, rather than any version guessed out of it
  fake_agent "${FIX_HOME}" "${1}" "${2}"
  run harbor_agents_installed_version "${1}" "${FIX_HOME}"
  assert_equal "${status}" 2
  assert_output --partial 'agents.unreadable'
  assert_output --partial "printed '${2}'"
  assert_output --partial "$(harbor_agents_bin "${1}" "${FIX_HOME}")"
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
  # write_install_lock VALUE: a lock carrying VALUE as claude_code_install and the
  # pinned version beside it, every other key empty, so a malformed install method
  # can be driven without editing the repository's own lock
  local k
  BAD_LOCK="${BATS_TEST_TMPDIR}/versions.lock"
  : >"${BAD_LOCK}"
  for k in ${HARBOR_VERSION_KEYS}; do
    case "${k}" in
      claude_code_version) printf 'claude_code_version=%s\n' "${CLAUDE_VERSION}" ;;
      claude_code_install) printf 'claude_code_install=%s\n' "${1}" ;;
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

@test "the prefix and both bin paths are derived from the HOME parameter and never from the ambient HOME" {
  assert_equal "$(harbor_agents_prefix "${FIX_HOME}")" "${FIX_HOME}/.local/harbor/npm"
  assert_equal "$(harbor_agents_bin claude "${FIX_HOME}")" "${FIX_HOME}/.local/harbor/npm/bin/claude"
  assert_equal "$(harbor_agents_bin codex "${FIX_HOME}")" "${FIX_HOME}/.local/harbor/npm/bin/codex"
  # HOME is a different directory, and none of the three answers mentions it.
  assert_equal "${HOME}" "${DECOY_HOME}"
  run harbor_agents_prefix "${FIX_HOME}"
  refute_output --partial "${DECOY_HOME}"
  run harbor_agents_bin claude "${FIX_HOME}"
  refute_output --partial "${DECOY_HOME}"
  run harbor_agents_bin codex "${FIX_HOME}"
  refute_output --partial "${DECOY_HOME}"
  # The same functions asked about that other home answer under it, so the parameter
  # is what moves the answer.
  assert_equal "$(harbor_agents_prefix "${DECOY_HOME}")" "${DECOY_HOME}/.local/harbor/npm"
  assert_equal "$(harbor_agents_bin codex "${DECOY_HOME}")" "${DECOY_HOME}/.local/harbor/npm/bin/codex"
}

@test "the lock key maps each agent onto the versions.lock key its pinned values live under" {
  assert_equal "$(harbor_agents_lock_key claude version)" claude_code_version
  assert_equal "$(harbor_agents_lock_key claude install)" claude_code_install
  assert_equal "$(harbor_agents_lock_key codex version)" codex_version
  assert_equal "$(harbor_agents_lock_key codex install)" codex_install
  # Each key is one the schema actually has, so the mapping is checked against the
  # lock rather than against itself.
  local agent field key
  for agent in ${HARBOR_AGENTS}; do
    for field in version install; do
      key="$(harbor_agents_lock_key "${agent}" "${field}")"
      case " ${HARBOR_VERSION_KEYS} " in
        *" ${key} "*) ;;
        *) fail "harbor_agents_lock_key ${agent} ${field} produced ${key}, which is not a versions.lock key" ;;
      esac
      assert [ -n "$(harbor_version_require "${key}")" ]
    done
  done
}

@test "a name that is not one of the two agents is refused with exit 3 before any key or path is built" {
  local name
  for name in t3 node '' 'claude code' Claude 'claude;rm -rf /'; do
    run harbor_agents_lock_key "${name}" version
    assert_equal "${status}" 3
    assert_output --partial 'agents.unknown'
    assert_output --partial 'claude codex'
    run harbor_agents_bin "${name}" "${FIX_HOME}"
    assert_equal "${status}" 3
    assert_output --partial 'agents.unknown'
    refute_output --partial "${FIX_HOME}/.local"
    run harbor_agents_installed_version "${name}" "${FIX_HOME}"
    assert_equal "${status}" 3
    assert_output --partial 'agents.unknown'
  done
}

@test "an executable that is not there, is not a file, or is not executable is absent for both agents" {
  local agent bin
  for agent in ${HARBOR_AGENTS}; do
    assert_equal "$(harbor_agents_installed_version "${agent}" "${FIX_HOME}")" absent
    bin="$(harbor_agents_bin "${agent}" "${FIX_HOME}")"
    # The prefix exists but holds nothing: still absent, not exit 2.
    mkdir -p "${bin}"
    assert_equal "$(harbor_agents_installed_version "${agent}" "${FIX_HOME}")" absent
    rmdir "${bin}"
    # A file that is there but carries no execute bit is absent too, because there
    # is nothing to ask.
    printf 'not an executable\n' >"${bin}"
    chmod 0644 "${bin}"
    assert_equal "$(harbor_agents_installed_version "${agent}" "${FIX_HOME}")" absent
    rm -f "${bin}"
  done
}

@test "the version string each pinned CLI prints is read back bare, out of the home the parameter names" {
  # The ambient HOME holds both agents at another version throughout, so an answer
  # that came from it would be visible as that version rather than these.
  fake_agent "${DECOY_HOME}" claude "9.9.9 (Claude Code)"
  fake_agent "${DECOY_HOME}" codex "codex-cli 9.9.9"
  assert_equal "$(harbor_agents_installed_version claude "${FIX_HOME}")" absent
  assert_equal "$(harbor_agents_installed_version codex "${FIX_HOME}")" absent
  fake_agent "${FIX_HOME}" claude "${CLAUDE_OUT}"
  fake_agent "${FIX_HOME}" codex "${CODEX_OUT}"
  assert_equal "$(harbor_agents_installed_version claude "${FIX_HOME}")" "${CLAUDE_VERSION}"
  assert_equal "$(harbor_agents_installed_version codex "${FIX_HOME}")" "${CODEX_VERSION}"
  # And the other home still answers with its own, so the two never crossed.
  assert_equal "$(harbor_agents_installed_version claude "${DECOY_HOME}")" 9.9.9
  assert_equal "$(harbor_agents_installed_version codex "${DECOY_HOME}")" 9.9.9
}

@test "an agent executable that exits non-zero is exit 2 naming the command it ran" {
  local agent bin
  for agent in ${HARBOR_AGENTS}; do
    failing_agent "${FIX_HOME}" "${agent}"
    bin="$(harbor_agents_bin "${agent}" "${FIX_HOME}")"
    run harbor_agents_installed_version "${agent}" "${FIX_HOME}"
    assert_equal "${status}" 2
    assert_output --partial 'agents.unreadable'
    assert_output --partial "${bin} --version failed"
    assert_output --partial "${agent}"
  done
}

@test "an agent executable that prints something other than its own version string is exit 2 quoting it" {
  # Every case here is text a version could be guessed out of by a looser reader:
  # prose, nothing at all, the bare number without the vendor's decoration, the
  # other vendor's decoration, and the vendor's decoration around something that is
  # not a version at all.
  assert_unreadable claude 'hello'
  assert_unreadable claude ''
  assert_unreadable claude "${CLAUDE_VERSION}"
  assert_unreadable claude "(Claude Code)"
  assert_unreadable claude "${CODEX_OUT}"
  assert_unreadable claude 'not logged in (Claude Code)'
  assert_unreadable codex 'hello'
  assert_unreadable codex ''
  assert_unreadable codex "${CODEX_VERSION}"
  assert_unreadable codex 'codex-cli'
  assert_unreadable codex "${CLAUDE_OUT}"
  assert_unreadable codex 'codex-cli not-a-version'
}

@test "nothing in this library writes: both fixture homes are identical after every inspection" {
  fake_agent "${FIX_HOME}" claude "${CLAUDE_OUT}"
  fake_agent "${DECOY_HOME}" codex "${CODEX_OUT}"
  local before fresh
  before="$(tree_snapshot)"
  harbor_agents_prefix "${FIX_HOME}" >/dev/null
  harbor_agents_bin claude "${FIX_HOME}" >/dev/null
  harbor_agents_bin codex "${FIX_HOME}" >/dev/null
  harbor_agents_lock_key claude version >/dev/null
  harbor_agents_lock_key codex install >/dev/null
  assert_equal "$(harbor_agents_installed_version claude "${FIX_HOME}")" "${CLAUDE_VERSION}"
  assert_equal "$(harbor_agents_installed_version codex "${FIX_HOME}")" absent
  assert_equal "$(harbor_agents_installed_version codex "${DECOY_HOME}")" "${CODEX_VERSION}"
  assert_equal "$(harbor_agents_installed_version claude "${DECOY_HOME}")" absent
  assert_equal "$(tree_snapshot)" "${before}"
  # Asking where the npm prefix is does not create it, nor any part of the home
  # above it: the install owns that directory, inspection only reports on it.
  fresh="${BATS_TEST_TMPDIR}/fresh"
  harbor_agents_prefix "${fresh}" >/dev/null
  assert_equal "$(harbor_agents_installed_version claude "${fresh}")" absent
  assert [ ! -e "${fresh}" ]
}

@test "an absent agent is installed through npm at the locked spec and journaled created with pre_state absent" {
  local prefix
  prefix="$(harbor_agents_prefix "${FIX_HOME}")"
  fake_npm claude "${CLAUDE_OUT}"
  acquire
  run harbor_agents_install "${FIX_ROOT}" "${FIX_HOME}" claude
  assert_success
  assert_output --partial "installed claude ${CLAUDE_VERSION}"
  assert_equal "$(harbor_agents_installed_version claude "${FIX_HOME}")" "${CLAUDE_VERSION}"
  # The vendor command line carries the prefix and the lock's own spec, package and
  # version together as one string, rather than anything this library assembled.
  assert_equal "$(cat "${NPM_LOG}")" "install --global --prefix ${prefix} ${CLAUDE_SPEC}"
  assert_equal "$(harbor_stat_mode "${prefix}")" 0755
  assert_equal "$(journal_names)" 0001-runtime-install.json
  # The target is the bare agent name, which is what lib/runtime.sh dispatches on and
  # therefore what recovery can decide; the executable's path would be unreadable.
  assert_equal "$(entry_raw "${FIX_ROOT}" 0001 target)" '"claude"'
  assert_equal "$(entry_raw "${FIX_ROOT}" 0001 ownership)" '"created"'
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" applied
  assert_equal "$(entry_raw "${FIX_ROOT}" 0001 pre_state)" '"absent"'
  assert_equal "$(entry_raw "${FIX_ROOT}" 0001 post_state)" "\"${CLAUDE_VERSION}\""
  harbor_journal_validate "${FIX_ROOT}/journal/0001-runtime-install.json"
  # The second agent is its own entry, with its own target and its own locked spec.
  fake_npm codex "${CODEX_OUT}"
  run harbor_agents_install "${FIX_ROOT}" "${FIX_HOME}" codex
  assert_success
  assert_equal "$(harbor_agents_installed_version codex "${FIX_HOME}")" "${CODEX_VERSION}"
  assert_equal "$(tail -n 1 "${NPM_LOG}")" "install --global --prefix ${prefix} ${CODEX_SPEC}"
  assert_equal "$(journal_names | tr '\n' ' ')" '0001-runtime-install.json 0002-runtime-install.json '
  assert_equal "$(entry_raw "${FIX_ROOT}" 0002 target)" '"codex"'
  assert_equal "$(entry_raw "${FIX_ROOT}" 0002 ownership)" '"created"'
  assert_equal "$(entry_phase "${FIX_ROOT}" 0002)" applied
  assert_equal "$(entry_raw "${FIX_ROOT}" 0002 post_state)" "\"${CODEX_VERSION}\""
  harbor_journal_validate "${FIX_ROOT}/journal/0002-runtime-install.json"
  harbor_lock_release "${FIX_ROOT}"
}

@test "an agent installed at another version is replaced and journaled modified with the prior version as pre_state" {
  fake_agent "${FIX_HOME}" claude "1.0.0 (Claude Code)"
  fake_npm claude "${CLAUDE_OUT}"
  acquire
  run harbor_agents_install "${FIX_ROOT}" "${FIX_HOME}" claude
  assert_success
  assert_equal "$(harbor_agents_installed_version claude "${FIX_HOME}")" "${CLAUDE_VERSION}"
  assert_equal "$(journal_names)" 0001-runtime-install.json
  assert_equal "$(entry_raw "${FIX_ROOT}" 0001 ownership)" '"modified"'
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" applied
  assert_equal "$(entry_raw "${FIX_ROOT}" 0001 pre_state)" '"1.0.0"'
  assert_equal "$(entry_raw "${FIX_ROOT}" 0001 post_state)" "\"${CLAUDE_VERSION}\""
  # The version now matches the lock, so a rerun is the no-op below: converging.
  : >"${NPM_LOG}"
  run harbor_agents_install "${FIX_ROOT}" "${FIX_HOME}" claude
  assert_success
  assert [ ! -s "${NPM_LOG}" ]
  assert_equal "$(journal_names)" 0001-runtime-install.json
  harbor_lock_release "${FIX_ROOT}"
}

@test "an installed version that already equals the lock is a no-op: no npm call, no entry, nothing touched" {
  fake_agent "${FIX_HOME}" claude "${CLAUDE_OUT}"
  fake_agent "${FIX_HOME}" codex "${CODEX_OUT}"
  acquire
  local before
  before="$(tree_snapshot)"
  run harbor_agents_install "${FIX_ROOT}" "${FIX_HOME}" claude
  assert_success
  run harbor_agents_install "${FIX_ROOT}" "${FIX_HOME}" codex
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
  run harbor_agents_install "${FIX_ROOT}" "${FIX_HOME}" claude
  assert_equal "${status}" 2
  assert_output --partial 'agents.install_failed'
  assert_output --partial "${CLAUDE_SPEC}"
  assert_output --partial 'E404'
  assert_output --partial '0001-runtime-install.json'
  assert_equal "$(journal_names)" 0001-runtime-install.json
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" prepared
  assert_equal "$(entry_raw "${FIX_ROOT}" 0001 pre_state)" '"absent"'
  assert_equal "$(harbor_agents_installed_version claude "${FIX_HOME}")" absent
  # The home holds pre_state, so recovery decides the entry rather than blocking.
  HARBOR_AGENTS_HOME="${FIX_HOME}"
  run harbor_journal_recover "${FIX_ROOT}"
  assert_success
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" reverted
  harbor_lock_release "${FIX_ROOT}"
}

@test "an npm install that reports success but leaves another version behind stays prepared and exits 2" {
  fake_npm claude '9.9.9 (Claude Code)'
  acquire
  run harbor_agents_install "${FIX_ROOT}" "${FIX_HOME}" claude
  assert_equal "${status}" 2
  assert_output --partial 'agents.verify'
  assert_output --partial 9.9.9
  assert_output --partial "${CLAUDE_SPEC}"
  assert_output --partial '0001-runtime-install.json'
  assert_equal "$(journal_names)" 0001-runtime-install.json
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" prepared
  assert_equal "$(entry_raw "${FIX_ROOT}" 0001 post_state)" "\"${CLAUDE_VERSION}\""
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
  fake_npm claude "${CLAUDE_OUT}"
  run env HARBOR_TEST_HOOKS=1 HARBOR_FAIL_AFTER=agents-claude-installed \
    bash -c '. "${HARBOR_ROOT}/lib/log.sh"; . "${HARBOR_ROOT}/lib/lock.sh"; . "${HARBOR_ROOT}/lib/versions.sh"; . "${HARBOR_ROOT}/lib/journal.sh"; . "${HARBOR_ROOT}/lib/runtime.sh"; . "${HARBOR_ROOT}/lib/agents.sh"; HARBOR_PID=$$; harbor_versions_load "${HARBOR_ROOT}/versions.lock"; harbor_lock_acquire "${1}" operator; harbor_agents_install "${1}" "${2}" claude' \
    _ "${FIX_ROOT}" "${FIX_HOME}"
  assert_equal "${status}" 137
  assert_equal "$(harbor_agents_installed_version claude "${FIX_HOME}")" "${CLAUDE_VERSION}"
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
  rm -f "$(harbor_agents_bin claude "${FIX_HOME}")"
  fixture_entry "${FIX_ROOT}" 0002 runtime-install claude created prepared '"absent"' "\"${CLAUDE_VERSION}\""
  run harbor_journal_recover "${FIX_ROOT}"
  assert_success
  assert_equal "$(entry_phase "${FIX_ROOT}" 0002)" reverted
  # Deciding an entry inspects only: nothing was installed or reinstalled.
  assert_equal "$(cat "${NPM_LOG}")" "install --global --prefix $(harbor_agents_prefix "${FIX_HOME}") ${CLAUDE_SPEC}"
  harbor_lock_release "${FIX_ROOT}"
}

@test "the two readers are registered, answer out of HARBOR_AGENTS_HOME, and refuse with exit 2 when it is unset" {
  assert_equal "$(harbor_runtime_reader_for claude)" harbor_agents_reader_claude
  assert_equal "$(harbor_runtime_reader_for codex)" harbor_agents_reader_codex
  # The ambient HOME holds an agent of its own, so a reader that fell back to it
  # would answer 9.9.9 instead of refusing, and that answer would be the pre_state
  # of an entry recovery is about to decide.
  fake_agent "${DECOY_HOME}" claude "9.9.9 (Claude Code)"
  unset HARBOR_AGENTS_HOME
  run harbor_journal_observe runtime-install claude
  assert_equal "${status}" 2
  assert_output --partial 'agents.home_unset'
  refute_output --partial 9.9.9
  run harbor_journal_observe runtime-install codex
  assert_equal "${status}" 2
  assert_output --partial 'agents.home_unset'
  # Set, the answer is what that home holds, and it moves when the variable moves.
  HARBOR_AGENTS_HOME="${FIX_HOME}"
  assert_equal "$(harbor_journal_observe runtime-install claude)" '"absent"'
  assert_equal "$(harbor_journal_observe runtime-install codex)" '"absent"'
  fake_agent "${FIX_HOME}" claude "${CLAUDE_OUT}"
  fake_agent "${FIX_HOME}" codex "${CODEX_OUT}"
  assert_equal "$(harbor_journal_observe runtime-install claude)" "\"${CLAUDE_VERSION}\""
  assert_equal "$(harbor_journal_observe runtime-install codex)" "\"${CODEX_VERSION}\""
  HARBOR_AGENTS_HOME="${DECOY_HOME}"
  assert_equal "$(harbor_journal_observe runtime-install claude)" '"9.9.9"'
  # An agent that is there but cannot answer keeps its own exit 2 through the
  # dispatcher, rather than reading as absent.
  HARBOR_AGENTS_HOME="${FIX_HOME}"
  failing_agent "${FIX_HOME}" claude
  run harbor_journal_observe runtime-install claude
  assert_equal "${status}" 2
  assert_output --partial 'agents.unreadable'
  # Observation only: nothing was installed and no entry was written.
  assert [ ! -s "${NPM_LOG}" ]
  assert_equal "$(journal_names)" ""
}

@test "an install method that is not npm:<package>@<version> exits 3 before any entry, npm call, or prefix" {
  local bad
  acquire
  for bad in 'tarball:@anthropic-ai/claude-code@2.1.267' 'npm:@anthropic-ai/claude-code' 'npm:@2.1.267' 'npm:' '@anthropic-ai/claude-code@2.1.267'; do
    write_install_lock "${bad}"
    run harbor_agents_install "${FIX_ROOT}" "${FIX_HOME}" claude
    assert_equal "${status}" 3
    assert_output --partial 'agents.install_method'
    assert_output --partial "${bad}"
    assert_output --partial "${BAD_LOCK}"
    assert [ ! -s "${NPM_LOG}" ]
    assert_equal "$(journal_names)" ""
    assert [ ! -e "$(harbor_agents_prefix "${FIX_HOME}")" ]
  done
  harbor_lock_release "${FIX_ROOT}"
}

@test "the install writes only under the HOME parameter: both agents land there and the ambient HOME is untouched" {
  local before
  before="$(decoy_snapshot)"
  fake_npm claude "${CLAUDE_OUT}"
  acquire
  run harbor_agents_install "${FIX_ROOT}" "${FIX_HOME}" claude
  assert_success
  fake_npm codex "${CODEX_OUT}"
  run harbor_agents_install "${FIX_ROOT}" "${FIX_HOME}" codex
  assert_success
  assert [ -x "$(harbor_agents_bin claude "${FIX_HOME}")" ]
  assert [ -x "$(harbor_agents_bin codex "${FIX_HOME}")" ]
  # HOME is still the decoy, and nothing under it was created, removed, or rewritten.
  assert_equal "${HOME}" "${DECOY_HOME}"
  assert_equal "$(decoy_snapshot)" "${before}"
  assert [ ! -e "${DECOY_HOME}/.local" ]
  # Neither vendor command line named any path outside the fixture home.
  run cat "${NPM_LOG}"
  assert_equal "${#lines[@]}" 2
  refute_output --partial "${DECOY_HOME}"
  harbor_lock_release "${FIX_ROOT}"
}
