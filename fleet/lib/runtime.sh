#!/bin/bash
# The runtime-install op (design sections 2 and 3.7): the observer
# harbor_journal_observe dispatches every runtime-install entry to, and the registry
# that says which library can read which target. Section 3.7 gives the op four targets —
# Node.js, Claude Code, Codex, and t3 — owned by three libraries, and an op has exactly
# one observer per process: two libraries defining harbor_observe_op_runtime_install
# means whichever is sourced last silently wins, and recovery would read one runtime's
# prepared entry with another runtime's reader and call it decided with the wrong
# answer. So the op lives here, knows nothing about any runtime, and asks whoever
# registered for the target. Depends on lib/log.sh only; every library that owns a
# target registers its reader at the bottom of its own file.
#
# There is deliberately no generic "ask a CLI its version" reader here. At the pinned
# releases all three vendor CLIs decorate their answer — claude prints
# "2.1.267 (Claude Code)", codex prints "codex-cli 0.154.0", t3 prints "t3 v0.0.38" —
# and node prints "v24.20.0", which lib/node.sh already reads. A shared reader would
# have to accept every one of those shapes, which is to say it would accept a decorated
# string from the wrong vendor as a version. Each library anchors its own vendor's
# spelling in its own case instead (design section 7, vendor status honesty).
# HARBOR_RUNTIME_READERS: "name:function" pairs, space separated. bash 3.2 has no
# associative arrays, so the registry is one string and lookup is a scan over it.
#
# Kept rather than reset, because re-sourcing a library into a process that already
# has it is deliberate here: bin/harbor sources lib/ and then sources node/bootstrap.sh
# into the same process, which sources much of lib/ again. A plain assignment would
# empty the registry on that second pass and only the readers whose libraries are
# sourced again below it would come back — so a process that had registered claude,
# codex, and t3 would come out the other side able to observe none of them, and every
# prepared runtime-install entry for those three would read as unobservable and land on
# the operator as a manual journal resolution. Re-registering an unchanged pair is
# already a no-op, so keeping the registry across a re-source changes nothing else.
#
# What is not kept is a registry that arrived from outside this process. Harbor runs
# the agents as the operator and treats that account as untrusted, so a registry from
# the environment is that account's input rather than Harbor's own state: honouring it
# would let it say what a runtime-install entry records a version as, and would let one
# conflicting prefix pair turn lib/node.sh's source-time registration into a
# runtime.reader_conflict that aborts harbor bootstrap before preflight.
#
# The two are told apart by a companion variable holding the pid that initialised the
# registry. Same pid means this process built it and a re-source must leave it alone;
# anything else, including both variables arriving together from a parent, means it is
# not ours and the registry starts empty. The pid is what makes the marker hard to
# supply from outside, since an operator exporting one would have to name the pid
# harbor has not been given yet.
#
# Reading the export bit with declare -p was the obvious way to ask this and is the
# wrong one, in three ways that between them cover both directions of the answer. It
# says "not ours" for a registry this process built under set -a, where every
# assignment is exported and SHELLOPTS can turn that on from the environment. It
# aborts under set -e if a caller ever made the variable readonly, because the reset
# assignment runs on every source rather than only the first. And clearing it needs
# unset, a builtin an exported shell function can shadow into a no-op, which hands
# back the exact registry the check exists to discard. Comparing a pid needs none of
# those: no unset, no export bit, and on a re-source no assignment at all.
if [ "${HARBOR_RUNTIME_READERS_PID:-}" != "$$" ]; then
  HARBOR_RUNTIME_READERS=""
  HARBOR_RUNTIME_READERS_PID="$$"
fi
# harbor_runtime_reader_register NAME FN: FN is the version reader for the target key
# NAME. Called at source time by the library that owns NAME, so the dispatch below can
# find it in any process that sourced that library.
#
# Registering NAME again with the same FN is a no-op, because sourcing a library twice
# is something node/bootstrap.sh does deliberately and must keep changing nothing.
# Registering NAME with a different FN is a refusal, not a silent first-match win: two
# libraries claiming one target is the same defect this file exists to fix, one level
# down, and a registry that quietly kept the first would hand recovery a reader the
# owning library never chose. It fails at source time, where the collision is a
# programming error a test sees, rather than at recovery time on a real node.
harbor_runtime_reader_register() {
  local existing
  if existing="$(harbor_runtime_reader_for "${1}")"; then
    [ "${existing}" != "${2}" ] || return 0
    harbor_die 2 runtime.reader_conflict "the runtime-install target '${1}' is already read by ${existing} and ${2} claims it too; one target has one reader, so whichever library is wrong has to be fixed before either can be trusted"
  fi
  HARBOR_RUNTIME_READERS="${HARBOR_RUNTIME_READERS} ${1}:${2}"
}
# harbor_runtime_reader_for NAME: the function registered for NAME, or return 1 when
# nothing is registered for it. A miss is a return rather than a death, because the
# caller's answer to an unreadable target is "unobservable", not an exit.
harbor_runtime_reader_for() {
  local want="${1}" pair
  for pair in ${HARBOR_RUNTIME_READERS}; do
    [ "${pair%%:*}" != "${want}" ] || {
      printf '%s' "${pair#*:}"
      return 0
    }
  done
  return 1
}
# harbor_observe_op_runtime_install TARGET: the state of TARGET in the pre_state and
# post_state form of the runtime-install op, so an entry left prepared by a crash
# between the install and the applied write is decidable by recovery (design section
# 3.7). The target says which reader answers it: an absolute path is a filesystem
# prefix and is read by whatever registered for prefix, and a bare name in the
# [a-z0-9-] journal vocabulary is a runtime name and is read by whatever registered
# for that name. A target with no registered reader renders
# "unobservable:runtime-install:<target>" rather than guessing, the same fail-closed
# shape harbor_journal_observe already uses for an op with no observer, and a target
# outside that vocabulary is refused before any lookup — the target comes out of a
# journal file, so it selects a registered function and is never expanded into a
# command. A registered name whose reader is not a shell function defined in this
# process is unobservable too, for two reasons. A library that registered and then
# failed to finish sourcing would otherwise take recovery down with a 127 instead of an
# answer it can act on. And because the registry survives a re-source it can also
# arrive from the environment, and the operator account that would set it is the same
# untrusted account the agents run as — so the test is declare -F rather than
# command -v, which would have accepted a builtin or anything on PATH and let an
# exported HARBOR_RUNTIME_READERS choose what a journal entry claims a runtime's
# version is. Only a function this process defined itself can answer.
# Inspection only; a reader that cannot read its runtime keeps its own exit.
harbor_observe_op_runtime_install() {
  local target="${1}" key fn version
  # The vocabulary class is spelled out rather than written [a-z0-9-], because a range
  # in a bracket expression is resolved by the locale's collating order: under
  # en_US.UTF-8, which is what the macOS runners set, a-z covers the uppercase letters
  # too and "Claude" passes a fence that is documented to reject it. Enumerating the
  # characters is the only spelling that means the same thing in every locale, and this
  # fence stands between a journal file's contents and a function call.
  case "${target}" in
    /*) key=prefix ;;
    "" | *[!abcdefghijklmnopqrstuvwxyz0123456789-]*) key="" ;;
    *) key="${target}" ;;
  esac
  if [ -n "${key}" ] && fn="$(harbor_runtime_reader_for "${key}")" \
    && declare -F "${fn}" >/dev/null 2>&1; then
    version="$("${fn}" "${target}")" || exit "$?"
    printf '"%s"' "$(harbor_json_escape "${version}")"
    return 0
  fi
  printf '"unobservable:runtime-install:%s"' "$(harbor_json_escape "${target}")"
}
