#!/bin/bash
# The installed-entrypoint row of the design section 5.2 map, asserted through the one
# operator command this release ships: harbor auth tailscale (design sections 3.6 and
# 5.3). The bootstrap job has already produced a bootstrapped node; this script drives
# the attended login against it, on the real paths, and asserts what design section 7's
# test map asks of that row: the writable-release exit 3, the deleted-checkout success,
# and kill-and-rerun, plus the four properties the login itself owes -- the operator
# state root created 0700 before the lock is taken, exit 0 against a not-running
# Tailscale whose up transitions to Running, nothing journaled and no state record
# written, and a login URL that reaches the terminal and no log.
#
# Runs as root (sudo bash assert_auth.sh), like assert_bootstrap.sh, because it reads
# the root-owned /var/lib/harbor and the operator's own 0700 state root, and because
# becoming the operator is runuser and runuser is root's. It never runs Harbor as root:
# harbor auth tailscale refuses root before it reads anything, which is the design
# section 3.6 rule this script stands on rather than works around. The lane's one
# root-phase Harbor call site, run_root.sh, is untouched and unused here -- it runs
# bootstrap as root, and nothing below is either of those things.
#
# One check per line, failures collected and counted at the end: this lane cannot be
# run locally, so it is written to fail loudly rather than to pass quietly.
set -euo pipefail

# shellcheck source=lib/common.sh
. "$(cd "$(dirname "${0}")" && pwd -P)/lib/common.sh"

[ "$(id -u)" = 0 ] || {
  printf 'assert_auth.sh must run as root\n' >&2
  exit 1
}

tag="$(it_release_tag)"
release="${IT_INSTALL_ROOT}/${tag}"
probe="${release}/vendor-smoke/tailscale-ssh.probe"
# The file made group-writable for the writable-release case. versions.lock is chosen
# because Harbor reads it on every auth run, so a release that was let through with a
# loose mode would be a release whose pinned versions anyone could have rewritten.
loosened="${release}/versions.lock"
operator_home="$(it_operator_home)"
op_root="${operator_home}/.local/state/harbor"
op_log="${op_root}/harbor.log"
op_journal="${op_root}/journal"
# Renamed, not deleted, for the deleted-checkout case, so the runner is handed back
# what it checked out. A rename keeps every open file descriptor valid, this script's
# own included, which is why it is safe to rename the tree this script is read from.
checkout_moved="${IT_FLEET}.moved-by-assert-auth"

section() {
  printf '\n-- %s\n' "${*}"
}

# The lane must be handed back exactly what it lent, whichever assertion failed and
# wherever it_done exited. Both restorations are idempotent and neither hides a
# failure: they put back state this script deliberately broke.
auth_restore() {
  if [ -e "${loosened}" ]; then
    chmod 0644 "${loosened}"
  fi
  if [ -d "${checkout_moved}" ] && [ ! -e "${IT_FLEET}" ]; then
    mv "${checkout_moved}" "${IT_FLEET}"
  fi
}
trap auth_restore EXIT

# auth_root_journal -- one hash over every entry in the root journal, so "the root
# journal is untouched" is a single comparable reading. Empty is a hash too.
auth_root_journal() {
  find "${IT_HARBOR_JOURNAL}" -maxdepth 1 -type f -name '*.json' -exec sha256sum {} + \
    | LC_ALL=C sort | sha256sum | cut -d ' ' -f 1
}

auth_sha() {
  sha256sum "${1}" | cut -d ' ' -f 1
}

# auth_run [--fail-after STEP] [-- ARG...] -- run the installed entrypoint's
# "harbor auth tailscale" AS THE OPERATOR, leaving its status in AUTH_RC and its
# combined output in AUTH_OUT.
#
# The rule of design section 7, kept exactly as run_root.sh keeps it: the account
# Harbor runs as never inherits this script's environment. There is no sudo -E
# anywhere in this lane, no sudoers env_keep for HARBOR_TEST_HOOKS, HARBOR_FAIL_AFTER,
# HARBOR_PAUSE_AFTER, HARBOR_PID or TMPDIR, and no sudoers rule of any kind is
# involved here at all: this script is already root and drops to the operator with
# runuser, the same way the linger and Node.js probes in assert_bootstrap.sh do. Every
# variable the operator is to see is one literal element of the env argument list
# below, and a run without --fail-after passes no hook variable at all, so
# HARBOR_TEST_HOOKS is not even set and harbor_test_hook returns at its first line.
#
# HOME is named because the operator state root of design section 3.7 is derived from
# it, and su-style environment handling differs between util-linux versions; naming it
# makes the state root under test the operator's own by construction rather than by
# hope. HARBOR_PID is never passed: bin/harbor sets it to its own $$, which is the
# process a --fail-after must kill.
#
# The output is captured only so the assertions can read it, and it is printed
# immediately, so what the operator would have seen is in the job log either way.
# "the login URL reached the terminal" is asserted against exactly these bytes.
auth_run() {
  local fail_after=""
  local -a argv
  while [ "$#" -gt 0 ]; do
    case "${1}" in
      --fail-after)
        fail_after="${2:?--fail-after needs a step name}"
        shift 2
        ;;
      --)
        shift
        break
        ;;
      *)
        printf 'assert_auth.sh: auth_run: unknown option %s\n' "${1}" >&2
        exit 1
        ;;
    esac
  done
  argv=(runuser -u "${IT_OPERATOR}" -- env
    "PATH=${IT_PATH}"
    "HOME=${operator_home}")
  if [ -n "${fail_after}" ]; then
    argv+=("HARBOR_TEST_HOOKS=1" "HARBOR_FAIL_AFTER=${fail_after}")
  fi
  argv+=("${IT_LINK}" auth tailscale)
  if [ "$#" -gt 0 ]; then
    argv+=("$@")
  fi
  printf '\n+ %s\n' "${argv[*]}"
  AUTH_RC=0
  AUTH_OUT="$("${argv[@]}" 2>&1)" || AUTH_RC="$?"
  printf '%s\n' "${AUTH_OUT}"
  printf '+ exit %s\n' "${AUTH_RC}"
}

# auth_killed LABEL -- a run that died at its --fail-after boundary, which every
# assertion after one of these stands on. Only the SIGKILL will do here.
#
# harbor_test_hook sends SIGKILL to HARBOR_PID and then exits 4 if it is still running,
# and that second path is not the same event: exit 4 is an ordinary exit, so the EXIT
# trap of lib/log.sh runs, and harbor_lock_release releases the very lock or gate the
# next assertions are about to read. A run that ended that way has not left the
# filesystem in the shape being asserted, so it is a failure here rather than a second
# acceptable outcome, whatever it may be elsewhere.
auth_killed() {
  case "${AUTH_RC}" in
    137) it_pass "${1}: the run was SIGKILLed at its boundary (exit 137)" ;;
    4) it_fail "${1}: the hook's SIGKILL did not land and the run exited 4 through its EXIT trap, which releases the lock these assertions read" ;;
    0) it_fail "${1}: the run finished normally, so that boundary was never reached" ;;
    *) it_fail "${1}: the run exited ${AUTH_RC}, which is not the SIGKILL 137 this boundary owes" ;;
  esac
}

# auth_untouched LABEL -- the four readings a refused run may not have moved: the
# vendor-call log, its mutating half, the root state record, and the root journal.
# Only sound before the first successful login, which is the only run in this script
# that legitimately calls a vendor at all.
auth_untouched() {
  it_eq "${1}: made no vendor call" "${base_shim}" "$(auth_sha "${IT_SHIM_LOG}")"
  it_eq "${1}: made no mutating vendor call" "${base_mut}" "$(auth_sha "${IT_MUT_LOG}")"
  it_eq "${1}: left bootstrap.json untouched" "${base_record}" "$(auth_sha "${IT_HARBOR_RECORD}")"
  it_eq "${1}: left the root journal untouched" "${base_journal}" "$(auth_root_journal)"
}

# ---------------------------------------------------------------------------
section 'preconditions: a bootstrapped node, a closed --ssh gate, no login yet'
# ---------------------------------------------------------------------------
base_shim="$(auth_sha "${IT_SHIM_LOG}")"
base_mut="$(auth_sha "${IT_MUT_LOG}")"
base_record="$(auth_sha "${IT_HARBOR_RECORD}")"
base_journal="$(auth_root_journal)"

it_symlink 'the installed entrypoint under test' "${release}/bin/harbor" "${IT_LINK}"
it_file 'the state record the command reads' 0644 root root "${IT_HARBOR_RECORD}"
it_contains 'it records the Tailscale as Harbor-installed' \
  '"tailscale_ownership": "harbor-installed"' "$(cat "${IT_HARBOR_RECORD}")"
it_contains 'and it records the operator this login runs as' \
  "\"operator\": \"${IT_OPERATOR}\"" "$(cat "${IT_HARBOR_RECORD}")"
# The --ssh gate of design section 3.6, read out of the installed release rather than
# out of the checkout, because the release is what the command executes from.
it_file 'the vendor-smoke probe record in the release' 0644 root root "${probe}"
it_contains 'the release records the --ssh gate as not run' 'result=not-run' "$(cat "${probe}")"
it_eq 'bootstrap granted the operator the Tailscale read' "${IT_OPERATOR}" "$(cat "${IT_TS_OPERATOR}")"
it_eq 'and the stand-in daemon has never logged in' NeedsLogin "$(cat "${IT_TS_BACKEND}")"
# Everything asserted below about "before the lock was taken" rests on this: bootstrap
# is root and takes the root lock in /var/lib/harbor, so the operator state root does
# not exist yet, and a lock cannot exist without the root it lives in.
it_file_absent 'the operator state root does not exist before the first auth run' "${op_root}"

# ---------------------------------------------------------------------------
section 'the --ssh gate is closed: an explicit --tailscale-ssh is exit 3'
# ---------------------------------------------------------------------------
auth_run -- --tailscale-ssh
it_eq 'an explicit --tailscale-ssh exits 3' 3 "${AUTH_RC}"
it_contains 'refused as an unsupported flag of this release' \
  '--tailscale-ssh is not a supported flag of this release' "${AUTH_OUT}"
it_contains 'and it names the probe reading that closed the gate' 'result=not-run' "${AUTH_OUT}"
it_contains 'and it hands Tailscale SSH back to the owner' 'sudo tailscale set --ssh' "${AUTH_OUT}"
it_file_absent 'refused before the operator state root existed, so before any lock' "${op_root}"
auth_untouched 'the --tailscale-ssh refusal'

# ---------------------------------------------------------------------------
section 'writable release: exit 3 naming the path, before the lock, mutating nothing'
# ---------------------------------------------------------------------------
# Group-writable, which is the loosest thing an installed release may not be: the
# entrypoint preflight walks the release before the command does anything else, so
# this must be refused before the state root is created and before the lock is taken.
chmod g+w "${loosened}"
it_file 'the release now carries a group-writable file' 0664 root root "${loosened}"
auth_run
it_eq 'a group-writable release is a precondition failure' 3 "${AUTH_RC}"
it_contains 'and the refusal names the offending path' "${loosened}" "${AUTH_OUT}"
it_contains 'and says what mode it should have carried' 'not the installed 0644' "${AUTH_OUT}"
it_contains 'and it is the entrypoint mode rule that refused' 'entrypoint.mode' "${AUTH_OUT}"
it_file_absent 'refused before the operator state root existed, so before any lock' "${op_root}"
auth_untouched 'the writable-release refusal'
chmod 0644 "${loosened}"
it_file 'the release is restored' 0644 root root "${loosened}"

# ---------------------------------------------------------------------------
section 'the state root is created 0700 BEFORE the operator lock is taken'
# ---------------------------------------------------------------------------
# The ordering, not the end state. lock-gate is a harbor_step boundary inside
# harbor_lock_acquire that sits strictly between two things: lib/auth.sh has already
# called harbor_state_root_create, and lib/lock.sh has not yet reached its
# mkdir of lock.d. A SIGKILL there freezes the filesystem in a shape that can only
# exist if the state root was made first -- and if the order were the other way round,
# harbor_lock_acquire would have died at lock.no_state_root before ever logging
# lock-gate, so the run would exit 3 and auth_killed below would fail rather than a
# mode assertion quietly passing on a directory some later step created.
auth_run --fail-after lock-gate
auth_killed 'the lock-gate boundary'
it_dir 'the operator state root exists at that boundary' 0700 \
  "${IT_OPERATOR}" "${IT_OPERATOR}" "${op_root}"
it_dir 'the run was inside the lock gate when it died' 0700 \
  "${IT_OPERATOR}" "${IT_OPERATOR}" "${op_root}/reclaim.d"
it_file 'and the gate carries its holder record' 0600 \
  "${IT_OPERATOR}" "${IT_OPERATOR}" "${op_root}/reclaim.d/holder"
it_file_absent 'while the lock itself had not been taken yet' "${op_root}/lock.d"
it_file 'the operator log was opened before the lock too' 0600 \
  "${IT_OPERATOR}" "${IT_OPERATOR}" "${op_log}"
it_contains 'and it names the command that created the state root' \
  'command auth tailscale' "$(cat "${op_log}")"
it_contains 'and its last step is the lock gate' 'step lock-gate' "$(cat "${op_log}")"
it_eq 'nothing was journaled on the way to the lock' 0 \
  "$(find "${op_root}" -maxdepth 2 -type f -name '*.json' | wc -l | tr -d ' ')"
auth_untouched 'the run killed at lock-gate'
# The remedy harbor_lock_inspect_hint prints for exactly this crash: remove the gate
# and rerun. Done as the operator, because the state root is the operator's own.
runuser -u "${IT_OPERATOR}" -- rm -f "${op_root}/reclaim.d/holder"
runuser -u "${IT_OPERATOR}" -- rmdir "${op_root}/reclaim.d"
it_file_absent 'the crashed lock gate is cleared, as the command own hint says to' \
  "${op_root}/reclaim.d"

# ---------------------------------------------------------------------------
section 'kill under the lock: SIGKILL at recovery-scan'
# ---------------------------------------------------------------------------
# recovery-scan is the boundary immediately after the lock is held and the recovery
# every command owes under it has run, and before the first vendor call. A SIGKILL
# here leaves the lock held by a process that no longer exists, which is the case the
# rerun below has to reclaim.
auth_run --fail-after recovery-scan
auth_killed 'the recovery-scan boundary'
it_dir 'the operator lock is held by the killed run' 0700 \
  "${IT_OPERATOR}" "${IT_OPERATOR}" "${op_root}/lock.d"
it_file 'and it carries that run holder record' 0600 \
  "${IT_OPERATOR}" "${IT_OPERATOR}" "${op_root}/lock.d/holder"
it_file_absent 'the lock gate was released once the lock was taken' "${op_root}/reclaim.d"
it_dir 'the operator journal directory was created under the lock' 0700 \
  "${IT_OPERATOR}" "${IT_OPERATOR}" "${op_journal}"
it_eq 'and the crashed run journaled nothing into it' 0 \
  "$(find "${op_journal}" -maxdepth 1 -type f -name '*.json' | wc -l | tr -d ' ')"
auth_untouched 'the run killed at recovery-scan'

# ---------------------------------------------------------------------------
section 'the rerun converges, reclaims the lock, and logs the node in'
# ---------------------------------------------------------------------------
# No hook variable is passed at all. This is the run that does the real work: it
# reclaims the stale lock, finds BackendState NeedsLogin, runs tailscale up, and waits
# for Running.
auth_run
it_eq 'the rerun after the crash exits 0' 0 "${AUTH_RC}"
it_contains 'and it reclaimed the lock the killed run left behind' \
  'reclaimed stale lock held by pid' "${AUTH_OUT}"
it_eq 'the reclaimed lock was archived rather than deleted' 1 \
  "$(find "${op_root}" -maxdepth 1 -type d -name 'lock.*.stale' | wc -l | tr -d ' ')"
it_file_absent 'and the lock is released when the rerun ends' "${op_root}/lock.d"
it_contains 'the run announced the form it was about to run' \
  'logging this node in with: tailscale up --hostname=harbor-node' "${AUTH_OUT}"
it_contains 'and it reports the node logged in' \
  'this node is logged in to its tailnet (BackendState Running)' "${AUTH_OUT}"
it_eq 'the stand-in daemon transitioned to Running' Running "$(cat "${IT_TS_BACKEND}")"

# The --ssh gate is closed in this release, so the up carries no --ssh. Asserted from
# the shim log, which records the argv the vendor was actually called with, rather
# than from anything Harbor said about itself. One line, and that line exactly.
up_argv="$(awk -F '\t' '$3 == "tailscale" && $4 == "up" {
  out = $4
  for (i = 5; i <= NF; i++) { out = out " " $i }
  print out
}' "${IT_SHIM_LOG}")"
it_eq 'exactly one tailscale up, in exactly the recorded form' \
  'up --hostname=harbor-node' "${up_argv}"
it_lacks 'and it carried no --ssh' ' --ssh ' " ${up_argv} "

# ---------------------------------------------------------------------------
section 'nothing was journaled and no state record was written'
# ---------------------------------------------------------------------------
# Design section 3.6: Tailscale authentication is vendor state Harbor observes and
# never journals, because it has no automatic inverse. lib/auth.sh runs
# harbor_journal_init and harbor_journal_recover and writes nothing.
it_dir 'the operator journal directory exists' 0700 \
  "${IT_OPERATOR}" "${IT_OPERATOR}" "${op_journal}"
it_eq 'and the login journaled no entry into it' 0 \
  "$(find "${op_journal}" -maxdepth 1 -type f -name '*.json' | wc -l | tr -d ' ')"
it_eq 'the root journal is exactly what bootstrap left' "${base_journal}" "$(auth_root_journal)"
it_eq 'and bootstrap.json is byte for byte what bootstrap wrote' \
  "${base_record}" "$(auth_sha "${IT_HARBOR_RECORD}")"
it_file_absent 'no state record was written under the operator state root' \
  "${op_root}/bootstrap.json"

# ---------------------------------------------------------------------------
section 'the login URL reached the terminal and no log'
# ---------------------------------------------------------------------------
# The needle first has to be real: an absence assertion against a string nothing ever
# printed proves nothing at all. This is the URL the vendor stand-in printed, and the
# assertion above found it in the bytes the operator saw.
it_contains 'the vendor printed the login URL on the operator terminal' \
  "${IT_LOGIN_URL}" "${AUTH_OUT}"
it_contains 'the operator log did record the vendor call that printed it' \
  'vendor tailscale up --hostname=harbor-node' "$(cat "${op_log}")"
for file in "${op_log}" "${IT_SHIM_LOG}" "${IT_MUT_LOG}" "${IT_HARBOR_LOG}"; do
  if grep -qF -- "${IT_LOGIN_URL}" "${file}"; then
    it_fail "${file} carries the login URL"
  else
    it_pass "${file} carries no login URL"
  fi
done
if grep -rqF -- "${IT_LOGIN_URL}" "${IT_HARBOR_JOURNAL}"; then
  it_fail 'a journal entry carries the login URL'
else
  it_pass 'no journal entry carries the login URL'
fi

# ---------------------------------------------------------------------------
section 'deleted checkout: the installed entrypoint reads nothing from it'
# ---------------------------------------------------------------------------
mv "${IT_FLEET}" "${checkout_moved}"
it_file_absent 'the checkout the release was built from is gone' "${IT_FLEET}"
auth_run
it_eq 'harbor auth tailscale still exits 0 with the checkout gone' 0 "${AUTH_RC}"
it_contains 'and it read the node state it needed from the installed release' \
  'this node is already logged in (BackendState Running)' "${AUTH_OUT}"
mv "${checkout_moved}" "${IT_FLEET}"
if [ -d "${IT_FLEET}" ] && [ ! -e "${checkout_moved}" ]; then
  it_pass "the checkout is back at ${IT_FLEET}"
else
  it_fail "the checkout was not restored to ${IT_FLEET}"
fi

# ---------------------------------------------------------------------------
section 'what the whole exercise left in the operator state root'
# ---------------------------------------------------------------------------
# The stale archive carries a timestamp, so it is folded to a fixed name; everything
# else is spelled out. A state record, a second journal, or anything else appearing
# here would be lib/auth.sh writing something design section 3.6 says it must not.
op_entries="$(ls -A "${op_root}" \
  | LC_ALL=C sed 's/^lock\.[0-9TZ.]*\.stale$/lock.STAMP.stale/' \
  | LC_ALL=C sort | tr '\n' ' ' | sed 's/ *$//')"
it_eq 'the operator state root holds the log, the empty journal, the archived lock, and nothing else' \
  'harbor.log journal lock.STAMP.stale' "${op_entries}"

it_done "assert_auth ($(cat "${IT_SCENARIO_FILE}"))"
