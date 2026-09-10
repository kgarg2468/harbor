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
# harbor_agents_auth_status AGENT HOME: what AGENT's own status command says about
# whether the operator is logged in — "logged-in", "logged-out", "unknown" when the
# command answered something this pinned adapter does not recognize, and "unsupported"
# when the installed build documents no such command at all (design section 3.6). The
# last two are kept apart because harbor auth acts on them differently: "unknown" is a
# tool that could have answered and did not, "unsupported" is a tool that was never
# going to, and only the second is a reason to stop expecting an answer.
#
# The answer is read out of the body, and the exit status only corroborates it. Both
# pinned CLIs exit 1 to say logged out — claude auth status --json exits 1 carrying
# "loggedIn": false, codex login status exits 1 carrying "Not logged in" — so an
# adapter that classified on the exit status would call every logged-out node
# "unknown", and since "unknown" never journals a transition, harbor auth could then
# never record a login that succeeded. A recognized body is therefore its own answer
# whatever the exit status was, and an empty or unrecognized body is "unknown" whatever
# the exit status was. The status is logged beside the word for the operator to read,
# which is the whole of what it decides here.
#
# claude's answer is read out of the JSON its own --help calls the default output, with
# the same anchored sed harbor_auth_record_value reads bootstrap.json with, because
# nothing under lib/ may depend on jq. The key has to begin a line: a JSON string cannot
# carry a raw newline, so no value the vendor interpolates into the body — an
# organization name, an email — can forge a "loggedIn" line, while an unanchored match
# could be led to one inside a value. codex ships no --json flag at this release, so its
# answer is prose, and each outcome gets one anchored case the way
# harbor_agents_installed_version anchors each vendor's --version spelling; the phrase
# has to begin a line there for the same reason. Both bodies are read with stderr
# merged, since a command that exits non-zero to report a state may say it on either
# stream and the body is what decides.
#
# "unsupported" is asked of the tool rather than assumed, and asked only when the body
# was not an answer: the status command's own --help is what documents the subcommand,
# and it is what the pinned measurement was taken from. Exit 0 there is a build that has
# the command and merely said something this adapter does not know, which is "unknown";
# a non-zero --help is a build without the command. An executable that is not there is
# "unknown" too, because nothing was asked and so nothing can be claimed about what the
# release ships.
#
# Harbor reads only what the tool prints. Nothing here opens, stats, or builds a path
# under a credential directory, and the body reaches neither stdout nor the log: the
# whole output of this function is one of the four words, because the logged-in claude
# body carries the operator's email, organization, and subscription, and a caller
# capturing this function must never capture those.
harbor_agents_auth_status() {
  local agent="${1}" home="${2}" bin body value rc=0 word=unknown newline
  newline='
'
  bin="$(harbor_agents_bin "${agent}" "${home}")" || exit "$?"
  if [ ! -f "${bin}" ] || [ ! -x "${bin}" ]; then
    printf 'unknown'
    return 0
  fi
  case "${agent}" in
    claude)
      harbor_log_vendor "${bin}" auth status --json
      body="$("${bin}" auth status --json 2>&1)" || rc="$?"
      # The value is taken as the run of characters up to the field separator, so a
      # trailing comma is not part of it and only the two literals below are answers.
      value="$(printf '%s\n' "${body}" \
        | sed -n 's/^[[:space:]]*"loggedIn"[[:space:]]*:[[:space:]]*\([^,[:space:]]*\).*$/\1/p' | sed -n 1p)"
      case "${value}" in
        true) word=logged-in ;;
        false) word=logged-out ;;
        *)
          harbor_log_vendor "${bin}" auth status --help
          "${bin}" auth status --help >/dev/null 2>&1 || word=unsupported
          ;;
      esac
      ;;
    codex)
      harbor_log_vendor "${bin}" login status
      body="$("${bin}" login status 2>&1)" || rc="$?"
      # A newline is prepended so that the first line of the body is anchored by the
      # same pattern as every other line, rather than needing a second case arm.
      case "${newline}${body}" in
        *"${newline}Logged in using ChatGPT"*) word=logged-in ;;
        *"${newline}Not logged in"*) word=logged-out ;;
        *)
          harbor_log_vendor "${bin}" login status --help
          "${bin}" login status --help >/dev/null 2>&1 || word=unsupported
          ;;
      esac
      ;;
  esac
  harbor_log agents "${agent} auth status is ${word}; ${bin} exited ${rc}"
  printf '%s' "${word}"
}
# harbor_agents_auth_login AGENT HOME: run AGENT's own login and return what it
# returned. The login is attended and interactive (design section 3.6), so the vendor's
# output is neither captured nor reprinted: whatever the CLI writes — a URL, a code, a
# prompt — reaches the operator's terminal where the vendor put it, and Harbor never
# pre-answers a prompt and never puts a secret on a command line (section 3.8). Nothing
# here logs the tool out: the login subcommand is the only thing either CLI is asked
# for, and neither vendor's logout appears anywhere in this file.
#
# The two argv are the siblings of the status subcommands the Task 7 measurement pinned,
# and were read from the same CLIs' own --help: claude auth --help lists
# "login  Sign in to your Anthropic account" beside the "status" this file already
# reads, so the login is claude auth login; codex login --help shows status as a
# subcommand of login, so the bare codex login is the login and codex login status is
# the reading. Each is spelled once, in its own anchored case arm, for the reason
# harbor_agents_installed_version gives: one vendor's spelling must never be reachable
# through the other's name.
#
# A non-zero exit is returned rather than fatal, because it is the second status reading
# and not the CLI's exit code that decides what this run may claim. A login that was
# declined, abandoned, or interrupted says so by leaving the tool logged out, the vendor
# has already printed why on the terminal, and harbor_agents_auth reports that pair.
harbor_agents_auth_login() {
  local agent="${1}" home="${2}" bin rc=0
  bin="$(harbor_agents_bin "${agent}" "${home}")" || exit "$?"
  case "${agent}" in
    claude)
      harbor_log_vendor "${bin}" auth login
      "${bin}" auth login || rc="$?"
      ;;
    codex)
      harbor_log_vendor "${bin}" login
      "${bin}" login || rc="$?"
      ;;
  esac
  harbor_log agents "${agent} login exited ${rc}"
  return "${rc}"
}
# harbor_agents_auth STATE_ROOT HOME AGENT: harbor auth <claude|codex>, the attended
# agent login of design section 3.6. The order is harbor_auth_tailscale's, and for its
# reasons: root is refused before anything is read or created, because the login binds
# this node to whoever completes it and the state root is the operator's own; then the
# operator state root with its section 3.7 modes, the log, the operator lock, and the
# recovery scan every command owes under its lock. Then the reading, the login, and the
# reading again.
#
# Only a logged-out to logged-in pair is journaled, and every other pair writes nothing
# at all:
#   already logged-in    -> exit 0, no login call and no entry: there is nothing to do
#                           and running a login over a live session would be a mutation
#                           the operator did not ask for;
#   logged-out           -> exit 1 naming the rerun, because the tool is still logged
#                           out and no transition happened to record;
#   unknown either side  -> exit 1: the adapter had the command and did not recognize
#                           the answer, so Harbor cannot say a transition occurred and
#                           never journals one it did not see;
#   unsupported          -> exit 1: the login still runs, because it is the operator's
#                           to complete either way, and the refusal says no entry was
#                           written and that the pinned build documents no status
#                           command to verify it with.
#
# The entry is written applied rather than prepared-then-applied, and that is the
# section 3.7 protocol rather than a shortcut around it. The prepared phase exists so a
# crash between the write and the mutation leaves recovery something to decide; here the
# mutation is the vendor's own login, Harbor has no inverse for it and never logs the
# tool out, and the entry is written only once both readings are in hand — the
# transition is over before the first byte of the entry exists. A prepared auth entry
# would also be undecidable forever, since the op has no observer, so a crash mid-login
# would block every later operator command on an entry recording a login that in fact
# succeeded. One applied write is the only shape under which "every other pair writes
# nothing" stays literally true.
#
# Harbor never reads, copies, prints, or inspects the credential store: the whole of
# what this function knows about the login is the word its own status adapter returned,
# and that adapter never lets the vendor's body reach stdout or the log.
harbor_agents_auth() {
  local root="${1}" home="${2}" agent="${3}" bin pre post entry rc=0
  harbor_auth_refuse_root
  bin="$(harbor_agents_bin "${agent}" "${home}")" || exit "$?"
  # An executable that is not there is not a login Harbor can run: the adapter would
  # read the absent tool as "unknown", which is one of the pairs below, but getting
  # there would mean invoking a path that does not exist and reporting an unverifiable
  # transition for a tool that was never installed. The install is a different command
  # and this names it.
  [ -f "${bin}" ] && [ -x "${bin}" ] \
    || harbor_die 3 agents.not_installed "${bin} is not an installed executable, so there is no ${agent} on this node to log in; install the pinned agents first, as the operator, with: harbor provision; nothing was changed"
  harbor_state_root_create "${root}" operator
  harbor_log_open "${root}/harbor.log" 0600
  harbor_log command "auth ${agent}"
  harbor_lock_acquire "${root}" operator
  harbor_journal_init "${root}"
  # The home the readers answer out of, set before recovery runs: a crashed provision
  # can leave a claude or codex runtime-install entry prepared in this same operator
  # journal, and the registered readers can only decide it in a process that has been
  # told which home holds the agents (see harbor_agents_home).
  HARBOR_AGENTS_HOME="${home}"
  harbor_journal_recover "${root}"
  harbor_step recovery-scan
  pre="$(harbor_agents_auth_status "${agent}" "${home}")" || exit "$?"
  if [ "${pre}" = logged-in ]; then
    harbor_msg "auth.${agent}: ${agent} is already logged in on this node (its own status command says so); nothing to do, and Harbor ran no login"
    return 0
  fi
  harbor_msg "auth.${agent}: ${agent} reports ${pre}; running its own login below — follow what it prints, on your Mac if it asks for a browser"
  harbor_agents_auth_login "${agent}" "${home}" || rc="$?"
  harbor_step "auth-${agent}-login"
  post="$(harbor_agents_auth_status "${agent}" "${home}")" || exit "$?"
  harbor_log agents "${agent} auth ${pre} to ${post} (login exited ${rc})"
  case "${pre}:${post}" in
    logged-out:logged-in) ;;
    logged-out:logged-out)
      harbor_die 1 agents.auth_incomplete "${agent} still reports logged-out after its own login exited ${rc}, so the login was not completed and there is no transition to record; the vendor's output above says what it asked for, and rerunning is safe: harbor auth ${agent}; nothing was journaled"
      ;;
    *unsupported*)
      harbor_die 1 agents.auth_unsupported "${agent}'s login ran and exited ${rc}, but this pinned build documents no machine-readable status command, so Harbor cannot verify whether the login took and wrote no journal entry (design section 3.6 journals only a logged-out to logged-in transition it observed); ask ${agent} itself whether it is signed in"
      ;;
    *)
      harbor_die 1 agents.auth_unverified "${agent} reported ${pre} before its login and ${post} after it (the login exited ${rc}), and Harbor journals a transition only when it read both ends of it, so nothing was written; rerun harbor auth ${agent} once ${agent} answers its own status command"
      ;;
  esac
  harbor_journal_create "${root}" auth "${agent}" created applied "\"${pre}\"" "\"${post}\""
  entry="${HARBOR_JOURNAL_ENTRY}"
  harbor_step "auth-${agent}-recorded"
  harbor_msg "${agent} is logged in on this node; recorded the ${pre} to ${post} transition as $(basename "${entry}")"
}
# The readers are registered at source time, beside the definitions above, so any
# process that sourced this library can observe a claude or codex runtime-install
# entry — including harbor journal resolve, which reaches recovery through bin/harbor
# without ever calling anything else in this file.
harbor_runtime_reader_register claude harbor_agents_reader_claude
harbor_runtime_reader_register codex harbor_agents_reader_codex
