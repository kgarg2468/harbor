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
# harbor_agents_home: the home root the two readers below inspect, which is
# HARBOR_AGENTS_HOME and nothing else. Unset is exit 2 rather than a fallback to
# $HOME, because every other function in this file takes the home as a parameter for
# a reason: the process that reads the operator's agents need not be the process
# whose home holds them. A reader that fell back would answer for whatever home the
# caller happens to have, and "absent" is the pre_state of every runtime-install
# entry these two targets appear in — so the wrong home does not produce an error,
# it produces a confident revert of an install that actually landed (design section
# 3.7). Being unable to name the home is an answer recovery can act on; guessing it
# is not.
harbor_agents_home() {
  [ -n "${HARBOR_AGENTS_HOME:-}" ] || harbor_die 2 agents.home_unset "HARBOR_AGENTS_HOME is unset, so which home holds the agent CLIs is not known and a claude or codex runtime-install entry cannot be observed; it is set by harbor provision, which is what writes those entries"
  printf '%s' "${HARBOR_AGENTS_HOME}"
}
# harbor_agents_reader_claude and harbor_agents_reader_codex: the version readers
# lib/runtime.sh dispatches the bare runtime-install targets "claude" and "codex" to,
# so an entry left prepared by a crash between the install and the applied write is
# decidable by recovery. One function per agent, each naming its own agent as a
# literal, because the target these are selected by comes out of a journal file: the
# registry's whole purpose is that such a string picks a registered function rather
# than being passed into one as data, and a single shared reader taking the target as
# its argument would put that string back on the inside. Inspection only; an agent
# that is present but cannot answer keeps the exit 2 of
# harbor_agents_installed_version, and an unset home keeps the exit 2 above.
harbor_agents_reader_claude() {
  local home
  home="$(harbor_agents_home)" || exit "$?"
  harbor_agents_installed_version claude "${home}"
}
harbor_agents_reader_codex() {
  local home
  home="$(harbor_agents_home)" || exit "$?"
  harbor_agents_installed_version codex "${home}"
}
# harbor_agents_install STATE_ROOT HOME AGENT: install AGENT at its locked version
# into the operator-owned npm prefix under HOME. A matching installed version is a
# no-op with no entry and no vendor call, so a rerun on a healthy node runs npm not
# at all. Otherwise one runtime-install entry, target the bare agent name, pre_state
# the previous version or "absent", post_state the locked version, prepared before
# the install and applied only after the installed executable itself reports the
# locked version. The target is the bare name rather than the executable's path
# because that is what the readers above are registered under and therefore what
# recovery can decide (design sections 2 and 5.4).
#
# The package and the version both come out of the *_install lock value, which is
# never taken apart into a package here and pasted back together with the version
# from *_version: the lock is meant to be the single source of the identity being
# installed, and a command line assembled from two keys would install whatever their
# disagreement produced while the entry vouched for one of them. The two keys are
# proved to agree by tests/lint/engines_check.sh, which is where that check belongs,
# since a lock that disagrees with itself is a repository defect rather than a state
# of this node. The form is still checked here, because npm: is what says the value
# is an npm spec at all and this file cannot install anything else.
harbor_agents_install() {
  local root="${1}" home="${2}" agent="${3}"
  local version_key install_key locked method spec prefix bin
  local pre pre_json ownership entry post out
  version_key="$(harbor_agents_lock_key "${agent}" version)" || exit "$?"
  install_key="$(harbor_agents_lock_key "${agent}" install)" || exit "$?"
  locked="$(harbor_version_require "${version_key}")" || exit "$?"
  method="$(harbor_version_require "${install_key}")" || exit "$?"
  case "${method}" in
    npm:?*@?*) spec="${method#npm:}" ;;
    *) harbor_die 3 agents.install_method "${install_key} is '${method}' in ${HARBOR_VERSIONS_FILE}, which is not the npm:<package>@<version> form design section 2 records an install method in; nothing was installed" ;;
  esac
  prefix="$(harbor_agents_prefix "${home}")"
  bin="$(harbor_agents_bin "${agent}" "${home}")" || exit "$?"
  # Set before the first thing that can fail, so that every exit below this line
  # leaves the readers above able to observe the entry this run may have written.
  HARBOR_AGENTS_HOME="${home}"
  pre="$(harbor_agents_installed_version "${agent}" "${home}")" || exit "$?"
  if [ "${pre}" = "${locked}" ]; then
    harbor_log agents "${agent} ${locked} at ${bin} equals the lock; nothing to do"
    return 0
  fi
  if [ "${pre}" = absent ]; then
    ownership=created
    pre_json='"absent"'
  else
    ownership=modified
    pre_json="\"${pre}\""
  fi
  harbor_journal_create "${root}" runtime-install "${agent}" "${ownership}" prepared "${pre_json}" "\"${locked}\""
  entry="${HARBOR_JOURNAL_ENTRY}"
  harbor_step "agents-${agent}-prepared"
  # The prefix is this install's to create, which is why nothing above it creates one:
  # inspection reports on the prefix and must not be what brings it into existence.
  mkdir -p "${prefix}"
  chmod 0755 "${prefix}"
  harbor_log_vendor npm install --global --prefix "${prefix}" "${spec}"
  # The vendor's own output is captured rather than passed through, so the failure
  # below can name it: an npm that fails says why in its output and nowhere else, and
  # an operator reading a prepared entry needs that text beside the entry's name. It
  # is folded onto one line for the same reason harbor_node_operator_probe folds its
  # probe output, and it reaches the terminal only, never the log, since harbor_die
  # logs the id and the exit code and not the message.
  if ! out="$(npm install --global --prefix "${prefix}" "${spec}" 2>&1)"; then
    out="$(printf '%s' "${out}" | tr '\n\r' '  ')"
    harbor_die 2 agents.install_failed "npm install --global --prefix ${prefix} ${spec} failed: ${out}; $(basename "${entry}") stays prepared, rerun after fixing the cause"
  fi
  harbor_step "agents-${agent}-installed"
  post="$(harbor_agents_installed_version "${agent}" "${home}")" || exit "$?"
  if [ "${post}" != "${locked}" ]; then
    harbor_die 2 agents.verify "${bin} --version reports ${post} after installing ${spec}; $(basename "${entry}") stays prepared and recovery will decide it from what is at ${bin}"
  fi
  harbor_journal_set_phase "${entry}" applied
  harbor_step "agents-${agent}-applied"
  harbor_msg "installed ${agent} ${locked} at ${bin}"
}
# The readers are registered at source time, beside the definitions above, so any
# process that sourced this library can observe a claude or codex runtime-install
# entry — including harbor journal resolve, which reaches recovery through bin/harbor
# without ever calling anything else in this file.
harbor_runtime_reader_register claude harbor_agents_reader_claude
harbor_runtime_reader_register codex harbor_agents_reader_codex
