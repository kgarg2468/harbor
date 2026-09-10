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
  # lib/auth.sh for harbor_auth_refuse_root alone: harbor_agents_auth refuses root
  # through the same function harbor auth tailscale does, so there is one answer to
  # "which principal owns an attended login" and not two.
  # shellcheck source=lib/auth.sh
  . "${HARBOR_ROOT}/lib/auth.sh"
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

refusing_agent_clis() {
  # The same refusal for the two agent CLIs themselves, and for the same reason one
  # level up. Nothing in lib/agents.sh looks either name up on PATH — every call goes
  # through harbor_agents_bin, which builds an absolute path under the HOME it was
  # passed — so these are never what the code under test runs. They are here for the
  # helper that gets it wrong: a test that invokes a bare "claude" or "codex" by
  # mistake would otherwise reach whatever the developer has installed on the machine
  # and run a real vendor CLI against a real credential store. That is a thing this
  # file must make impossible rather than merely improbable, so both names resolve to
  # a refusal before PATH is ever consulted.
  local agent
  for agent in ${HARBOR_AGENTS}; do
    {
      printf '#!/bin/sh\n'
      printf 'echo "%s: a test invoked the real CLI by name; lib/agents.sh never does" >&2\n' "${agent}"
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

status_fixture() {
  # status_fixture AGENT NAME: the base path of the body captured from AGENT's pinned
  # release in state NAME, ".out" beside the exit status in ".exit" as the vendor shim
  # fixtures already spell it. The fixtures are the measurement, so a version bump moves
  # them with the lock rather than moving assertions written out here.
  printf '%s/tests/fixtures/agents/%s-status/%s' "${HARBOR_ROOT}" "${1}" "${2}"
}

status_log() {
  # Every argv the fake CLIs below were called with, one call per line: what the adapter
  # asked the tool, and every path it named while asking.
  printf '%s/status.log' "${BATS_TEST_TMPDIR}"
}

fake_status_agent() {
  # fake_status_agent HOME AGENT FIXTURE: an executable at AGENT's path under HOME that
  # replies to its status command from FIXTURE.out and exits with FIXTURE.exit, 0 when
  # that file is absent. Any --help exits 0, which is what a build that documents the
  # subcommand does and what tells the adapter an answer it did not recognize came from
  # a command that exists.
  local bin
  bin="$(harbor_agents_bin "${2}" "${1}")"
  mkdir -p "$(dirname "${bin}")"
  {
    printf '#!/bin/sh\n'
    printf 'printf "%%s\\n" "$*" >>"%s"\n' "$(status_log)"
    printf 'case "$*" in *--help*) exit 0 ;; esac\n'
    printf 'cat "%s.out"\n' "${3}"
    printf '[ -f "%s.exit" ] || exit 0\n' "${3}"
    printf 'exit "$(cat "%s.exit")"\n' "${3}"
  } >"${bin}"
  chmod 0755 "${bin}"
}

fake_status_body() {
  # fake_status_body HOME AGENT TEXT EXIT: the same, for a body this test invents rather
  # than one captured from a release, at whatever exit status it chooses
  local base="${BATS_TEST_TMPDIR}/body.${2}"
  printf '%s' "${3}" >"${base}.out"
  printf '%s\n' "${4}" >"${base}.exit"
  fake_status_agent "${1}" "${2}" "${base}"
}

no_status_agent() {
  # no_status_agent HOME AGENT: a build that has no status subcommand at all. It refuses
  # the status command and refuses its --help too, and the second refusal is what
  # separates "this build never had the command" from "the command said something new".
  local bin
  bin="$(harbor_agents_bin "${2}" "${1}")"
  mkdir -p "$(dirname "${bin}")"
  {
    printf '#!/bin/sh\n'
    printf 'printf "%%s\\n" "$*" >>"%s"\n' "$(status_log)"
    printf 'echo "error: unknown command" >&2\n'
    printf 'exit 1\n'
  } >"${bin}"
  chmod 0755 "${bin}"
}

status_calls() {
  # The recorded argv, one call per line joined by "|", so a whole conversation with the
  # vendor can be asserted as one string
  tr '\n' '|' <"$(status_log)"
}

assert_status_unknown() {
  # assert_status_unknown AGENT TEXT: AGENT's status command printing TEXT is "unknown"
  # at either exit status, and neither reading leaks TEXT
  local code
  for code in 0 1; do
    fake_status_body "${FIX_HOME}" "${1}" "${2}" "${code}"
    run harbor_agents_auth_status "${1}" "${FIX_HOME}"
    assert_success
    assert_output unknown
  done
}

@test "each captured auth-status fixture classifies to the answer it was recorded with" {
  # The four real cases of the measurement, read out of the bodies the pinned releases
  # print, through the home the parameter names.
  fake_status_agent "${FIX_HOME}" claude "$(status_fixture claude logged-in)"
  assert_equal "$(harbor_agents_auth_status claude "${FIX_HOME}")" logged-in
  fake_status_agent "${FIX_HOME}" claude "$(status_fixture claude logged-out)"
  assert_equal "$(harbor_agents_auth_status claude "${FIX_HOME}")" logged-out
  fake_status_agent "${FIX_HOME}" codex "$(status_fixture codex logged-in)"
  assert_equal "$(harbor_agents_auth_status codex "${FIX_HOME}")" logged-in
  fake_status_agent "${FIX_HOME}" codex "$(status_fixture codex logged-out)"
  assert_equal "$(harbor_agents_auth_status codex "${FIX_HOME}")" logged-out
  # Each agent was asked exactly its own documented status command and nothing else: a
  # recognized body settles the question, so no --help probe was needed.
  assert_equal "$(status_calls)" 'auth status --json|auth status --json|login status|login status|'
  # The ambient HOME holds the opposite answer for both agents throughout, so a reading
  # that came from the environment would be visible as that answer.
  fake_status_agent "${DECOY_HOME}" claude "$(status_fixture claude logged-in)"
  fake_status_agent "${DECOY_HOME}" codex "$(status_fixture codex logged-in)"
  assert_equal "${HOME}" "${DECOY_HOME}"
  assert_equal "$(harbor_agents_auth_status claude "${FIX_HOME}")" logged-out
  assert_equal "$(harbor_agents_auth_status codex "${FIX_HOME}")" logged-out
  assert_equal "$(harbor_agents_auth_status claude "${DECOY_HOME}")" logged-in
  assert_equal "$(harbor_agents_auth_status codex "${DECOY_HOME}")" logged-in
}

@test "a logged-out body is logged-out and never unknown, though both pinned CLIs exit 1 to say it" {
  # This is the whole reason the adapter classifies on the body: both captured logged-out
  # fixtures carry a non-zero exit status, and "unknown" never journals a transition, so
  # reading the exit status first would make a recorded login impossible.
  assert_equal "$(cat "$(status_fixture claude logged-out).exit")" 1
  assert_equal "$(cat "$(status_fixture codex logged-out).exit")" 1
  fake_status_agent "${FIX_HOME}" claude "$(status_fixture claude logged-out)"
  fake_status_agent "${FIX_HOME}" codex "$(status_fixture codex logged-out)"
  assert_equal "$(harbor_agents_auth_status claude "${FIX_HOME}")" logged-out
  assert_equal "$(harbor_agents_auth_status codex "${FIX_HOME}")" logged-out
  # The exit status only corroborates, in both directions: the same bodies at exit 0 are
  # the same answer, and the logged-in bodies delivered with exit 1 are still logged-in.
  fake_status_body "${FIX_HOME}" claude "$(cat "$(status_fixture claude logged-out).out")" 0
  fake_status_body "${FIX_HOME}" codex "$(cat "$(status_fixture codex logged-out).out")" 0
  assert_equal "$(harbor_agents_auth_status claude "${FIX_HOME}")" logged-out
  assert_equal "$(harbor_agents_auth_status codex "${FIX_HOME}")" logged-out
  fake_status_body "${FIX_HOME}" claude "$(cat "$(status_fixture claude logged-in).out")" 1
  fake_status_body "${FIX_HOME}" codex "$(cat "$(status_fixture codex logged-in).out")" 1
  assert_equal "$(harbor_agents_auth_status claude "${FIX_HOME}")" logged-in
  assert_equal "$(harbor_agents_auth_status codex "${FIX_HOME}")" logged-in
}

@test "an empty or unrecognized body is unknown at either exit status, for both agents" {
  # Nothing at all, prose where a body was expected, and a value that is not the boolean
  # the field is documented to carry.
  assert_status_unknown claude ''
  assert_status_unknown claude 'hello'
  assert_status_unknown claude '{
  "loggedIn": "yes",
  "authMethod": "none"
}'
  # Neither spelling of the literal is the literal. The fence enumerates nothing and
  # compares whole words, so a locale whose collating order folds case cannot make TRUE
  # an answer.
  assert_status_unknown claude '{
  "loggedIn": TRUE
}'
  assert_status_unknown claude '{
  "loggedIn": False
}'
  # The key has to begin a line, so a "loggedIn" the vendor interpolated into a value it
  # took from elsewhere is not read as the field.
  assert_status_unknown claude '{
  "orgName": "x\", \"loggedIn\": true",
  "authMethod": "none"
}'
  assert_status_unknown codex ''
  assert_status_unknown codex 'hello'
  assert_status_unknown codex 'error: could not check whether you are Logged in using ChatGPT'
  assert_status_unknown codex 'the account is Not logged in to anything, it says here'
}

@test "a build whose status subcommand is missing entirely is unsupported, not unknown" {
  # Neither pinned agent is unsupported, so the path is exercised with a CLI that has no
  # status subcommand: it refuses the command and refuses its own --help for it, which is
  # what says the command was never there.
  local agent
  for agent in ${HARBOR_AGENTS}; do
    no_status_agent "${FIX_HOME}" "${agent}"
    run harbor_agents_auth_status "${agent}" "${FIX_HOME}"
    assert_success
    assert_output unsupported
  done
  # The probe is second and only on the unrecognized path: each agent was asked its
  # status command first and its --help only after that answered nothing.
  assert_equal "$(status_calls)" 'auth status --json|auth status --help|login status|login status --help|'
  # A build that answers its --help has the command and merely said something new, which
  # is unknown rather than unsupported, and it costs a probe to tell the two apart.
  : >"$(status_log)"
  fake_status_body "${FIX_HOME}" claude 'something new' 1
  assert_equal "$(harbor_agents_auth_status claude "${FIX_HOME}")" unknown
  assert_equal "$(status_calls)" 'auth status --json|auth status --help|'
}

@test "an agent that is not installed is unknown, and a name that is not an agent is exit 3" {
  # Nothing was asked, so nothing can be claimed about what the release ships: the answer
  # is the fail-closed one, not unsupported.
  local name
  assert_equal "$(harbor_agents_auth_status claude "${FIX_HOME}")" unknown
  assert_equal "$(harbor_agents_auth_status codex "${FIX_HOME}")" unknown
  assert [ ! -e "$(status_log)" ]
  for name in t3 node '' 'claude code' Claude 'claude;rm -rf /'; do
    run harbor_agents_auth_status "${name}" "${FIX_HOME}"
    assert_equal "${status}" 3
    assert_output --partial 'agents.unknown'
  done
}

@test "the adapter prints only the status word: no part of the logged-in body reaches stdout or the log" {
  # The logged-in claude body is the one that carries an email, an organization, and a
  # subscription, so it is the body a caller capturing this function must not receive.
  local field
  harbor_log_open "${BATS_TEST_TMPDIR}/harbor.log" 0600
  fake_status_agent "${FIX_HOME}" claude "$(status_fixture claude logged-in)"
  run harbor_agents_auth_status claude "${FIX_HOME}"
  assert_success
  # The whole output, stdout and stderr together, is the one word.
  assert_output logged-in
  for field in 'operator@example.com' '00000000-0000-0000-0000-000000000000' 'OPERATOR org' SUBSCRIPTION claude.ai loggedIn authMethod projectsDirectory; do
    refute_output --partial "${field}"
    refute grep -qF -- "${field}" "${BATS_TEST_TMPDIR}/harbor.log"
  done
  # The log did record the reading, so what it holds is the answer and the exit status
  # and not the body that produced them.
  assert grep -q 'claude auth status is logged-in' "${BATS_TEST_TMPDIR}/harbor.log"
}

@test "the adapter reads only what the tool prints: no credential store is named or disturbed" {
  # Harbor never reads, copies, prints, or inspects a vendor credential store (design
  # section 3.6). Both stores are seeded here with a decoy secret, and the adapter is run
  # over every fixture for both agents.
  local before secret='DECOY-NOT-A-REAL-CREDENTIAL' out
  mkdir -p "${FIX_HOME}/.claude" "${FIX_HOME}/.codex"
  printf '{"accessToken":"%s"}\n' "${secret}" >"${FIX_HOME}/.claude/.credentials.json"
  printf '{"tokens":{"access_token":"%s"}}\n' "${secret}" >"${FIX_HOME}/.codex/auth.json"
  chmod 0600 "${FIX_HOME}/.claude/.credentials.json" "${FIX_HOME}/.codex/auth.json"
  fake_status_agent "${FIX_HOME}" claude "$(status_fixture claude logged-in)"
  fake_status_agent "${FIX_HOME}" codex "$(status_fixture codex logged-out)"
  before="$(tree_snapshot)"
  out="$(harbor_agents_auth_status claude "${FIX_HOME}")$(harbor_agents_auth_status codex "${FIX_HOME}")"
  assert_equal "${out}" logged-inlogged-out
  # Nothing under either store was created, removed, or rewritten.
  assert_equal "$(tree_snapshot)" "${before}"
  # No path under either store was ever passed to the vendor, and no secret reached the
  # answer.
  refute grep -qE -- '\.claude|\.codex|credential|auth\.json' "$(status_log)"
  refute grep -qF -- "${secret}" "$(status_log)"
  assert_equal "$(status_calls)" 'auth status --json|login status|'
}

# ---- harbor auth claude and harbor auth codex ---------------------------------------

auth_state() {
  # auth_state AGENT: the file the fake CLI below keeps its own login state in. The
  # login writes it and the status command reads it, so the second reading of a run is
  # the effect of that run's own login rather than something this test rewrote behind
  # the command's back.
  printf '%s/auth-state.%s' "${BATS_TEST_TMPDIR}" "${1}"
}

login_body() {
  # login_body AGENT: what the fake CLI prints for its login, the attended out-of-band
  # flow both vendors use over SSH. The URL is a fixture and the only place it may ever
  # appear is the terminal the vendor printed it to.
  printf '%s/login-body.%s' "${BATS_TEST_TMPDIR}" "${1}"
}

LOGIN_URL='https://vendor.example.com/activate/FIXTURE0000'

fake_login_agent() {
  # fake_login_agent AGENT PRE POST [LOGIN_EXIT]: an executable at AGENT's path under
  # FIX_HOME standing in for the vendor CLI through a whole attended login. It records
  # every argv it is called with, answers its status command out of the state file
  # (which starts at PRE), and answers its login command by printing an attended login's
  # output and writing POST into that state file. The two recognized states answer from
  # the bodies captured from the pinned releases, so the transition below is driven by
  # the same fixtures the adapter was measured against.
  local agent="${1}" pre="${2}" post="${3}" code="${4:-0}" bin login
  case "${agent}" in
    claude) login='auth login' ;;
    codex) login='login' ;;
  esac
  bin="$(harbor_agents_bin "${agent}" "${FIX_HOME}")"
  mkdir -p "$(dirname "${bin}")"
  printf '%s' "${pre}" >"$(auth_state "${agent}")"
  {
    printf 'To sign in, open this URL in a browser on your Mac:\n\n'
    printf '    %s\n\n' "${LOGIN_URL}"
    printf 'Waiting for the browser.\n'
  } >"$(login_body "${agent}")"
  {
    printf '#!/bin/sh\n'
    printf 'printf "%%s\\n" "$*" >>"%s"\n' "$(status_log)"
    printf 'state="$(cat "%s")"\n' "$(auth_state "${agent}")"
    printf 'case "$*" in\n'
    printf '  *--help*)\n'
    printf '    [ "${state}" != unsupported ] || exit 1\n'
    printf '    exit 0\n'
    printf '    ;;\n'
    printf '  "%s")\n' "${login}"
    printf '    cat "%s"\n' "$(login_body "${agent}")"
    printf '    printf "%%s" "%s" >"%s"\n' "${post}" "$(auth_state "${agent}")"
    printf '    exit %s\n' "${code}"
    printf '    ;;\n'
    printf 'esac\n'
    printf 'case "${state}" in\n'
    printf '  logged-in) cat "%s.out" ;;\n' "$(status_fixture "${agent}" logged-in)"
    printf '  logged-out)\n'
    printf '    cat "%s.out"\n' "$(status_fixture "${agent}" logged-out)"
    printf '    exit 1\n'
    printf '    ;;\n'
    printf '  unknown)\n'
    printf '    echo "a sentence this pinned adapter does not know"\n'
    printf '    exit 1\n'
    printf '    ;;\n'
    printf '  *)\n'
    printf '    echo "error: unknown command" >&2\n'
    printf '    exit 1\n'
    printf '    ;;\n'
    printf 'esac\n'
  } >"${bin}"
  chmod 0755 "${bin}"
}

agent_auth() {
  # agent_auth AGENT: the command in this process, then the lock released for the next.
  # The command takes the operator lock itself and a run subshell never reaches the EXIT
  # trap that would release it, which is the shape tests/unit/lib/auth.bats already uses
  # for harbor_auth_tailscale.
  run harbor_agents_auth "${FIX_ROOT}" "${FIX_HOME}" "${1}"
  harbor_lock_release "${FIX_ROOT}" 2>/dev/null || true
}

command_log() {
  cat "${FIX_ROOT}/harbor.log"
}

@test "auth: a logged-out agent that logs in journals one applied auth entry and exits 0" {
  local agent seq=0
  for agent in ${HARBOR_AGENTS}; do
    seq=$((seq + 1))
    fake_login_agent "${agent}" logged-out logged-in
    agent_auth "${agent}"
    assert_success
    assert_output --partial "${agent} reports logged-out; running its own login below"
    assert_output --partial "${agent} is logged in on this node"
    # The entry: op auth, target the bare agent name the way runtime-install targets it,
    # ownership created, and the two status words as the states it vouches for.
    assert_equal "$(entry_phase "${FIX_ROOT}" "000${seq}")" applied
    assert_equal "$(entry_raw "${FIX_ROOT}" "000${seq}" target)" "\"${agent}\""
    assert_equal "$(entry_raw "${FIX_ROOT}" "000${seq}" ownership)" '"created"'
    assert_equal "$(entry_raw "${FIX_ROOT}" "000${seq}" pre_state)" '"logged-out"'
    assert_equal "$(entry_raw "${FIX_ROOT}" "000${seq}" post_state)" '"logged-in"'
    harbor_journal_validate "${FIX_ROOT}/journal/000${seq}-auth.json"
  done
  # One entry per agent and nothing else, each named for the op recovery reads it as.
  assert_equal "$(journal_names | tr '\n' ' ')" '0001-auth.json 0002-auth.json '
  # The conversation with each vendor: the reading, the login, the reading again, and no
  # --help probe, because both bodies were recognized.
  assert_equal "$(status_calls)" 'auth status --json|auth login|auth status --json|login status|login|login status|'
}

@test "auth: an agent that is already logged in is exit 0 with no login call and no entry" {
  local agent
  for agent in ${HARBOR_AGENTS}; do
    fake_login_agent "${agent}" logged-in logged-in
    agent_auth "${agent}"
    assert_success
    assert_output --partial "${agent} is already logged in on this node"
    assert_output --partial "Harbor ran no login"
    refute_output --partial "${LOGIN_URL}"
  done
  # Nothing was journaled, and the only thing either vendor was asked is its status.
  assert_equal "$(journal_names)" ""
  assert_equal "$(status_calls)" 'auth status --json|login status|'
}

@test "auth: a login that leaves the tool logged out writes nothing and exits 1 naming the rerun" {
  # The declined or abandoned login: the vendor printed its URL, the operator never
  # approved it, and the tool says so itself. There is no transition, so there is no
  # entry, and the exit is the attended 1 rather than a failure of Harbor's.
  fake_login_agent claude logged-out logged-out 1
  agent_auth claude
  assert_failure 1
  assert_output --partial 'agents.auth_incomplete'
  assert_output --partial 'claude still reports logged-out after its own login exited 1'
  assert_output --partial 'harbor auth claude'
  assert_output --partial 'nothing was journaled'
  assert_equal "$(journal_names)" ""
  # A login that exits 0 and still leaves the tool logged out is the same answer: the
  # second reading decides, not the vendor's exit code.
  fake_login_agent codex logged-out logged-out 0
  agent_auth codex
  assert_failure 1
  assert_output --partial 'codex still reports logged-out after its own login exited 0'
  assert_equal "$(journal_names)" ""
}

@test "auth: unknown on either side is exit 1 and never journals a transition" {
  # Unknown before: the tool has the command and its answer is not one this pinned
  # adapter recognizes, so even a logged-in reading afterwards is not a transition
  # Harbor watched both ends of.
  fake_login_agent claude unknown logged-in
  agent_auth claude
  assert_failure 1
  assert_output --partial 'agents.auth_unverified'
  assert_output --partial 'claude reported unknown before its login and logged-in after it'
  assert_output --partial 'harbor auth claude'
  assert_equal "$(journal_names)" ""
  # Unknown after: the login ran, the tool answered something new, and Harbor will not
  # record a login it cannot read the result of.
  fake_login_agent codex logged-out unknown
  agent_auth codex
  assert_failure 1
  assert_output --partial 'agents.auth_unverified'
  assert_output --partial 'codex reported logged-out before its login and unknown after it'
  assert_equal "$(journal_names)" ""
  # The login did run in both cases: it is the operator's to complete either way.
  assert_equal "$(status_calls)" 'auth status --json|auth status --help|auth login|auth status --json|login status|login|login status|login status --help|'
}

@test "auth: an unsupported build still runs the login and exits 1 saying no entry was written" {
  # A build with no documented machine-readable status command at all. The login is
  # still the operator's to run; what Harbor cannot do is claim it saw a transition.
  local agent
  for agent in ${HARBOR_AGENTS}; do
    fake_login_agent "${agent}" unsupported unsupported
    agent_auth "${agent}"
    assert_failure 1
    assert_output --partial 'agents.auth_unsupported'
    assert_output --partial "${agent}'s login ran and exited 0"
    assert_output --partial 'documents no machine-readable status command'
    assert_output --partial 'wrote no journal entry'
    # The vendor's own login output still reached the terminal.
    assert_output --partial "${LOGIN_URL}"
    assert_equal "$(journal_names)" ""
  done
  assert_equal "$(status_calls)" 'auth status --json|auth status --help|auth login|auth status --json|auth status --help|login status|login status --help|login|login status|login status --help|'
}

@test "auth: an agent that is not installed is exit 3 naming harbor provision, before the lock" {
  local agent
  for agent in ${HARBOR_AGENTS}; do
    agent_auth "${agent}"
    assert_failure 3
    assert_output --partial 'agents.not_installed'
    assert_output --partial "$(harbor_agents_bin "${agent}" "${FIX_HOME}")"
    assert_output --partial 'harbor provision'
  done
  # Nothing was asked of any vendor, no lock was taken, and no log was opened.
  assert [ ! -e "$(status_log)" ]
  assert [ ! -e "${FIX_ROOT}/lock.d" ]
  assert [ ! -e "${FIX_ROOT}/harbor.log" ]
  assert_equal "$(journal_names)" ""
}

@test "auth: root is refused before the state root, the lock, or any vendor call" {
  local root="${BATS_TEST_TMPDIR}/root-state"
  fake_login_agent claude logged-out logged-in
  id() {
    if [ "${1:-}" = -u ]; then
      printf '0\n'
    else
      command id ${1+"$@"}
    fi
  }
  run harbor_agents_auth "${root}" "${FIX_HOME}" claude
  assert_failure 3
  assert_output --partial 'auth.root:'
  assert_output --partial 'without sudo'
  # The state root this run would have used was never created, so nothing was locked,
  # logged, or journaled, and the vendor was never called.
  assert [ ! -e "${root}" ]
  assert [ ! -e "$(status_log)" ]
  assert_equal "$(journal_names)" ""
  unset -f id
}

@test "auth: the vendor's login output reaches the terminal, and the status body reaches nothing" {
  local field
  fake_login_agent claude logged-out logged-in
  agent_auth claude
  assert_success
  # The vendor's login output is passed straight through: the whole body it printed
  # appears in the command's own output byte for byte, blank lines and indentation
  # included, in the order the vendor wrote it and with nothing of Harbor's inside it.
  assert_output --partial "$(cat "$(login_body claude)")"
  assert_line --index 1 'To sign in, open this URL in a browser on your Mac:'
  assert_line --index 2 "    ${LOGIN_URL}"
  assert_line --index 3 'Waiting for the browser.'
  # The URL reached the terminal and nowhere else: not the command log, not the journal,
  # and not a vendor argument.
  refute grep -qF -- "${LOGIN_URL}" "${FIX_ROOT}/harbor.log"
  refute grep -qF -- "${LOGIN_URL}" "$(status_log)"
  refute grep -rqF -- "${LOGIN_URL}" "${FIX_ROOT}/journal"
  # The status body is the one that carries an email, an org, and a subscription, and no
  # part of it reaches the terminal or the log at any point in the command.
  for field in 'operator@example.com' 'OPERATOR org' SUBSCRIPTION loggedIn authMethod; do
    refute_output --partial "${field}"
    refute grep -qF -- "${field}" "${FIX_ROOT}/harbor.log"
  done
  # What the log does hold is the argv, the steps, and the transition in words.
  run command_log
  assert_output --partial 'command auth claude'
  assert_output --partial 'step lock-acquired'
  assert_output --partial 'step recovery-scan'
  assert_output --partial 'step auth-claude-login'
  assert_output --partial 'step auth-claude-recorded'
  assert_output --partial 'vendor '"$(harbor_agents_bin claude "${FIX_HOME}")"' auth login'
  assert_output --partial 'claude auth status is logged-out'
  assert_output --partial 'claude auth logged-out to logged-in'
  assert_output --partial 'created 0001-auth.json created applied'
}

@test "auth: no credential store is read, named, or disturbed by the reading or the login" {
  # Harbor never reads, copies, prints, or inspects a vendor credential store (design
  # section 3.6), and the whole attended command is run here with both stores seeded.
  local secret='DECOY-NOT-A-REAL-CREDENTIAL' before
  mkdir -p "${FIX_HOME}/.claude" "${FIX_HOME}/.codex"
  printf '{"accessToken":"%s"}\n' "${secret}" >"${FIX_HOME}/.claude/.credentials.json"
  printf '{"tokens":{"access_token":"%s"}}\n' "${secret}" >"${FIX_HOME}/.codex/auth.json"
  chmod 0600 "${FIX_HOME}/.claude/.credentials.json" "${FIX_HOME}/.codex/auth.json"
  before="$(find "${FIX_HOME}/.claude" "${FIX_HOME}/.codex" -exec ls -ldn {} + | sort)"
  fake_login_agent claude logged-out logged-in
  fake_login_agent codex logged-out logged-in
  agent_auth claude
  assert_success
  refute_output --partial "${secret}"
  agent_auth codex
  assert_success
  refute_output --partial "${secret}"
  # Neither store was created, removed, or rewritten by Harbor: only the vendors own
  # them, and here the vendors are stand-ins that never touched them either.
  assert_equal "$(find "${FIX_HOME}/.claude" "${FIX_HOME}/.codex" -exec ls -ldn {} + | sort)" "${before}"
  # No path under either store was ever passed to a vendor, and no secret reached the
  # log or a journal entry.
  refute grep -qE -- '\.claude|\.codex|credential|auth\.json' "$(status_log)"
  refute grep -qF -- "${secret}" "${FIX_ROOT}/harbor.log"
  refute grep -rqF -- "${secret}" "${FIX_ROOT}/journal"
}
