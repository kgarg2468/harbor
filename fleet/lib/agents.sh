#!/bin/bash
# The agent CLIs (design sections 2 and 5.4): Claude Code and Codex, installed from
# npm into an operator-owned prefix under the operator's home and inspected there.
# The home root is a parameter on every function rather than the ambient HOME,
# because provision reads the operator's home while the process that reads it may
# have another one, and the unit lane points these at a fixture directory.
HARBOR_AGENTS="claude codex"
# harbor_agents_lock_key AGENT FIELD: the versions.lock key holding FIELD for AGENT,
# which is the one place the two spellings of an agent meet: the journal target and
# the executable are both "claude", while the lock calls that same agent
# "claude_code", and a call site that pasted the key together itself would be a
# second place to fix when either spelling moves. FIELD is not checked here, because
# harbor_version_get already refuses a key outside the schema and it owns that list.
harbor_agents_lock_key() {
  case "${1}" in
    claude) printf 'claude_code_%s' "${2}" ;;
    codex) printf 'codex_%s' "${2}" ;;
    *) harbor_die 3 agents.unknown "'${1}' is not a Harbor agent; the agents are ${HARBOR_AGENTS}" ;;
  esac
}
# harbor_agents_prefix HOME: the operator-owned npm prefix the agents install into,
# so nothing needs root and nothing lands in a root-owned global (design section 2,
# install method). Inspection only: the directory is created 0755 by the install, and
# asking where it is must not be what brings it into existence.
harbor_agents_prefix() {
  printf '%s/.local/harbor/npm' "${1}"
}
# harbor_agents_bin AGENT HOME: the absolute path of AGENT's executable, which is
# where npm install --global --prefix puts a package's bin. The executable is named
# for the agent in both cases, so the case below is a fence rather than a mapping:
# the name reaches this library from a runtime-install journal target, and an
# unchecked one would build a path Harbor never pinned.
harbor_agents_bin() {
  case "${1}" in
    claude | codex) printf '%s/bin/%s' "$(harbor_agents_prefix "${2}")" "${1}" ;;
    *) harbor_die 3 agents.unknown "'${1}' is not a Harbor agent; the agents are ${HARBOR_AGENTS}" ;;
  esac
}
# harbor_agents_installed_version AGENT HOME: "absent" when AGENT's executable is not
# an executable file, else the bare version it reports. That is the three-way shape
# harbor_node_installed_version already uses, because recovery treats all four
# runtimes identically (design section 3.7). Both CLIs decorate their answer at the
# pinned releases — claude prints "2.1.267 (Claude Code)" and codex prints
# "codex-cli 0.154.0" — so each gets its own anchored case here instead of a shared
# reader, which would have to accept both shapes and would then accept one vendor's
# decoration from the other vendor. What the decoration leaves has to be a bare
# numeric version on its own; anything else is exit 2 quoting what was printed,
# never the substring that happens to sit where a version used to.
harbor_agents_installed_version() {
  local agent="${1}" bin out version=""
  bin="$(harbor_agents_bin "${agent}" "${2}")" || exit "$?"
  if [ ! -f "${bin}" ] || [ ! -x "${bin}" ]; then
    printf 'absent'
    return 0
  fi
  out="$("${bin}" --version 2>/dev/null)" || harbor_die 2 agents.unreadable "${bin} --version failed; remove ${bin} by hand and rerun harbor provision so ${agent} is reinstalled"
  case "${agent}" in
    claude)
      case "${out}" in
        *' (Claude Code)') version="${out% (Claude Code)}" ;;
      esac
      ;;
    codex)
      case "${out}" in
        'codex-cli '*) version="${out#codex-cli }" ;;
      esac
      ;;
  esac
  # The digits are enumerated rather than written [0-9], because a range in a bracket
  # expression is resolved by the locale's collating order, and this is the test that
  # decides whether a string a vendor printed becomes a version a journal entry
  # vouches for.
  case "${version}" in
    *[!0123456789.]*) version="" ;;
    [0123456789]*.[0123456789]*.[0123456789]*) ;;
    *) version="" ;;
  esac
  [ -n "${version}" ] || harbor_die 2 agents.unreadable "${bin} --version printed '${out}', not a ${agent} version; remove ${bin} by hand and rerun harbor provision so ${agent} is reinstalled"
  printf '%s' "${version}"
}
