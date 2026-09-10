#!/bin/bash
# The runtime-install op (design sections 2 and 3.7): the observer
# harbor_journal_observe dispatches every runtime-install entry to, the registry that
# says which library can read which target, and the generic "ask a CLI its version"
# reader the vendor libraries inspect with. Section 3.7 gives the op four targets —
# Node.js, Claude Code, Codex, and t3 — owned by three libraries, and an op has exactly
# one observer per process: two libraries defining harbor_observe_op_runtime_install
# means whichever is sourced last silently wins, and recovery would read one runtime's
# prepared entry with another runtime's reader and call it decided with the wrong
# answer. So the op lives here, knows nothing about any runtime, and asks whoever
# registered for the target. Depends on lib/log.sh only; every library that owns a
# target registers its reader at the bottom of its own file.
# HARBOR_RUNTIME_READERS: "name:function" pairs, space separated. bash 3.2 has no
# associative arrays, so the registry is one string and lookup is a scan over it.
HARBOR_RUNTIME_READERS=""
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
# command. A registered name whose function is not defined in this process is
# unobservable too, the same command -v test harbor_journal_observe applies to an
# observer: a library that registered and then failed to finish sourcing would
# otherwise take recovery down with a 127 instead of an answer it can act on.
# Inspection only; a reader that cannot read its runtime keeps its own exit.
harbor_observe_op_runtime_install() {
  local target="${1}" key fn version
  case "${target}" in
    /*) key=prefix ;;
    "" | *[!a-z0-9-]*) key="" ;;
    *) key="${target}" ;;
  esac
  if [ -n "${key}" ] && fn="$(harbor_runtime_reader_for "${key}")" \
    && [ "$(command -v "${fn}" 2>/dev/null)" = "${fn}" ]; then
    version="$("${fn}" "${target}")" || exit "$?"
    printf '"%s"' "$(harbor_json_escape "${version}")"
    return 0
  fi
  printf '"unobservable:runtime-install:%s"' "$(harbor_json_escape "${target}")"
}
# harbor_runtime_cli_version CMD: what CMD --version reports, in the three-way shape
# every runtime inspection in Harbor uses. "absent" when CMD is not an executable
# file, so a runtime that was never installed is a state and not a failure; the bare
# version when CMD answers with one, with a leading v stripped the way
# harbor_node_installed_version strips it, since versions.lock spells every version
# bare; exit 2 when CMD is there and cannot answer, because a runtime that is present
# and unreadable is a node the operator has to look at. An answer carrying anything
# but digits and dots is exit 2 with the raw text rather than the leading version
# taken on faith: this reader is generic across four vendors and has no vendor's shape
# to anchor a substring against, so a decorated answer is one its own library parses
# with its own anchored case (design section 7, vendor status honesty).
harbor_runtime_cli_version() {
  local cmd="${1}" out version
  if [ ! -f "${cmd}" ] || [ ! -x "${cmd}" ]; then
    printf 'absent'
    return 0
  fi
  out="$("${cmd}" --version 2>/dev/null)" || harbor_die 2 runtime.unreadable "${cmd} --version failed; reinstall it with harbor provision"
  version="${out#v}"
  case "${version}" in
    *[!0-9.]*) harbor_die 2 runtime.unreadable "${cmd} --version printed '${out}', which is not a bare version; reinstall it with harbor provision" ;;
  esac
  case "${version}" in
    [0-9]*.[0-9]*.[0-9]*) printf '%s' "${version}" ;;
    *) harbor_die 2 runtime.unreadable "${cmd} --version printed '${out}', not a version; reinstall it with harbor provision" ;;
  esac
}
