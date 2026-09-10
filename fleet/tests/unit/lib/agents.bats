#!/usr/bin/env bats
load '../test_helper'

setup() {
  # lib/agents.sh depends on lib/log.sh for harbor_die and on lib/versions.sh for the
  # keys harbor_agents_lock_key names, so this file sources those two rather than
  # harbor_load_libs. Version inspection holds no lock and writes no journal.
  # shellcheck source=lib/log.sh
  . "${HARBOR_ROOT}/lib/log.sh"
  # shellcheck source=lib/versions.sh
  . "${HARBOR_ROOT}/lib/versions.sh"
  # shellcheck source=lib/agents.sh
  . "${HARBOR_ROOT}/lib/agents.sh"
  fixture_home
  # The ambient HOME is a decoy for this whole file: it exists, it is not FIX_HOME,
  # and tests seed agent executables of their own into it, so every path and every
  # version below is shown to follow the parameter rather than the environment.
  DECOY_HOME="${BATS_TEST_TMPDIR}/decoy"
  mkdir -p "${DECOY_HOME}"
  HOME="${DECOY_HOME}"
  # The real lock, so the strings the parser is measured against are the pinned
  # releases' own and a version bump moves the fixtures with it.
  harbor_versions_load "${HARBOR_ROOT}/versions.lock"
  CLAUDE_VERSION="$(harbor_version_require claude_code_version)"
  CODEX_VERSION="$(harbor_version_require codex_version)"
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
