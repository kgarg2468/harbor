#!/bin/bash
# Attended vendor login (design sections 3.6 and 5.3): harbor auth tailscale, the one
# command of this release that logs the node in to its tailnet. Login is attended and
# never scripted: the vendor's own tailscale up prints the login URL, this library
# passes that output straight through to the operator's terminal and never captures,
# reprints, logs, or journals it. Tailscale authentication is vendor state Harbor
# observes but never journals, because it has no automatic inverse (section 3.6), so
# nothing in this file writes a journal entry or a state record, and the operator
# journal is opened only for the recovery scan every command owes under its lock
# (section 3.7). The command is the operator's, unprivileged, and refuses root before
# it reads anything. Depends on lib/log.sh, lib/lock.sh, lib/journal.sh (recovery and
# harbor_json_unquote), lib/versions.sh (the pinned tailscale_version), and
# lib/entrypoint.sh (the installed-entrypoint check and harbor_bootstrap_flags_field).
# HARBOR_AUTH_* globals are set here and read by callers.
# shellcheck disable=SC2034
HARBOR_AUTH_HOSTNAME="harbor-node"
# The state record of design section 5.2, root-owned and 0644, which is why the
# operator can read the Tailscale ownership and the recorded flag set out of it without
# sudo. The one production path this library names.
HARBOR_AUTH_RECORD="/var/lib/harbor/bootstrap.json"
# The vendor-smoke record of the --ssh feature gate, relative to the release the
# command executes from. The value that opens the gate is spelled once.
HARBOR_AUTH_PROBE_RELATIVE="vendor-smoke/tailscale-ssh.probe"
HARBOR_AUTH_PROBE_ACCEPTED="accepted"
# The wait of design section 5.3: up to ten minutes for BackendState Running once
# tailscale up has returned, read every few seconds.
HARBOR_AUTH_POLL_SECONDS=5
HARBOR_AUTH_TIMEOUT_SECONDS=600
HARBOR_AUTH_USAGE="usage: harbor auth tailscale [--tailscale-ssh] | harbor auth claude | harbor auth codex"
# harbor_auth_refuse_root: exit 3 as root. The login URL binds this node to whoever
# opens it, the state root this command takes its lock in is the operator's own, and
# the daemon grant of design section 5.2 is what makes the unprivileged up possible at
# all, so a root run is refused before anything is read.
#
# The message names "harbor auth" rather than one subcommand, because all three attended
# logins refuse through this one function and a message naming tailscale would be read
# by an operator who typed claude.
harbor_auth_refuse_root() {
  [ "$(id -u)" != 0 ] \
    || harbor_die 3 auth.root "harbor auth is the operator's attended login and runs unprivileged (design section 3.6): rerun it as the operator without sudo; nothing was changed"
}
# harbor_auth_record_value RECORD KEY: the string value bootstrap.json carries under
# KEY, or nothing when the record is absent, unreadable, or carries no such string. A
# narrow reader for the flat record lib/state.sh writes, one "key": value per line with
# a two-space indent, in the same spelling harbor_entrypoint_record_tag reads the
# release tag with; sed rather than jq because every function under lib/ runs before
# the packages step could have installed one. The value is unquoted and unescaped the
# way a journal string is, so a flag set carrying an escaped character reads back as
# the set the run recorded.
harbor_auth_record_value() {
  local raw
  [ -f "${1}" ] || return 0
  raw="$(sed -n "s/^  \"${2}\": \(\".*\"\),*\$/\1/p" "${1}" 2>/dev/null | sed -n 1p)"
  [ -n "${raw}" ] || return 0
  harbor_json_unquote "${raw}"
}
# harbor_auth_probe_read PROBE: the vendor-smoke record of the --ssh feature gate,
# key=value lines, into HARBOR_AUTH_PROBE_DATE, HARBOR_AUTH_PROBE_VERSION, and
# HARBOR_AUTH_PROBE_RESULT. Every reading is empty when the file is absent or
# unreadable, and a key given twice keeps its first value; the gate below treats every
# reading it cannot make as a closed gate rather than an error, so a record that is
# malformed can never open it. Comment lines and blank lines are skipped and the note
# is not read: it is written for the reviewer, not for this library.
harbor_auth_probe_read() {
  local file="${1}" line key value
  HARBOR_AUTH_PROBE_DATE=""
  HARBOR_AUTH_PROBE_VERSION=""
  HARBOR_AUTH_PROBE_RESULT=""
  if [ ! -f "${file}" ] || [ ! -r "${file}" ]; then
    return 0
  fi
  while IFS= read -r line || [ -n "${line}" ]; do
    case "${line}" in
      '' | '#'*) continue ;;
      *=*) ;;
      *) continue ;;
    esac
    key="${line%%=*}"
    value="${line#*=}"
    case "${key}" in
      date) [ -n "${HARBOR_AUTH_PROBE_DATE}" ] || HARBOR_AUTH_PROBE_DATE="${value}" ;;
      tailscale_version) [ -n "${HARBOR_AUTH_PROBE_VERSION}" ] || HARBOR_AUTH_PROBE_VERSION="${value}" ;;
      result) [ -n "${HARBOR_AUTH_PROBE_RESULT}" ] || HARBOR_AUTH_PROBE_RESULT="${value}" ;;
    esac
  done <"${file}"
}
# harbor_auth_ssh_gate PROBE LOCKED: the --ssh feature gate of design section 3.6, in
# HARBOR_AUTH_SSH_GATE as open or closed, with the reason in HARBOR_AUTH_SSH_GATE_WHY.
# Open only when the vendor-smoke record says the operator user ran the exact
# tailscale up --hostname=harbor-node --ssh form without sudo and the daemon accepted
# it, and said so about the Tailscale version versions.lock pins: an acceptance
# recorded against another version is a measurement of another daemon. Anything else,
# a refusal, an absent or unreadable record, a record without the key, is closed, which
# is the state this release ships in. Inspection only.
harbor_auth_ssh_gate() {
  local probe="${1}" locked="${2}" dated
  harbor_auth_probe_read "${probe}"
  HARBOR_AUTH_SSH_GATE=closed
  dated="${HARBOR_AUTH_PROBE_DATE:-undated}"
  if [ ! -f "${probe}" ] || [ ! -r "${probe}" ]; then
    HARBOR_AUTH_SSH_GATE_WHY="the vendor-smoke probe record ${probe} is absent or unreadable, so nothing shows that the operator user can run tailscale up --hostname=${HARBOR_AUTH_HOSTNAME} --ssh without sudo"
  elif [ "${HARBOR_AUTH_PROBE_RESULT}" != "${HARBOR_AUTH_PROBE_ACCEPTED}" ]; then
    # What the record says, and what the gate needs, without a claim about which of the
    # two the difference is. A result may be missing because no run has been made, and it
    # may be missing because a run was made and its answer is not one this release adopts;
    # the record itself is where the difference is written, and a message that guessed
    # would send an operator to rerun a probe that has already answered.
    HARBOR_AUTH_SSH_GATE_WHY="the vendor-smoke probe record ${probe} (${dated}) records result=${HARBOR_AUTH_PROBE_RESULT:-nothing}, and this gate opens only on result=${HARBOR_AUTH_PROBE_ACCEPTED} for the pinned Tailscale, so Harbor runs tailscale up without --ssh; read that record for what was measured"
  elif [ "${HARBOR_AUTH_PROBE_VERSION}" != "${locked}" ]; then
    HARBOR_AUTH_SSH_GATE_WHY="the vendor-smoke probe record ${probe} (${dated}) records acceptance for tailscale ${HARBOR_AUTH_PROBE_VERSION:-an unnamed version}, not the ${locked} that ${HARBOR_VERSIONS_FILE:-versions.lock} pins"
  else
    HARBOR_AUTH_SSH_GATE=open
    HARBOR_AUTH_SSH_GATE_WHY="the vendor-smoke probe record ${probe} (${dated}) records that the operator user ran tailscale up --hostname=${HARBOR_AUTH_HOSTNAME} --ssh without sudo on tailscale ${locked} and the daemon accepted it"
  fi
}
# harbor_auth_backend_state: tailscale status --json as the caller, without sudo, with
# HARBOR_AUTH_BACKEND_STATE set to the BackendState it carries and the vendor's output
# in HARBOR_AUTH_STATUS_OUT. Returns the CLI's own non-zero status when it fails, and 1
# when it exits 0 without a BackendState, so each caller can say what that means at its
# point in the command: before the up it is the operator grant of design section 5.2
# missing, after it a daemon that stopped answering. Inspection only; the readings are
# globals for the reason lib/tailscale.sh gives, a command substitution would lose them.
harbor_auth_backend_state() {
  local rc=0
  HARBOR_AUTH_BACKEND_STATE=""
  harbor_log_vendor tailscale status --json
  HARBOR_AUTH_STATUS_OUT="$(tailscale status --json 2>&1)" || rc="$?"
  [ "${rc}" = 0 ] || return "${rc}"
  HARBOR_AUTH_BACKEND_STATE="$(printf '%s\n' "${HARBOR_AUTH_STATUS_OUT}" \
    | sed -n 's/.*"BackendState"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | sed -n 1p)"
  [ -n "${HARBOR_AUTH_BACKEND_STATE}" ] || return 1
}
# harbor_auth_tailscale STATE_ROOT RECORD PROBE LOCKED [--tailscale-ssh]: the command
# of design sections 3.6 and 5.3. In order, and with nothing touched before whatever
# would touch it has been proved sound:
#   root is refused;
#   the record must name the Tailscale as harbor-installed, because Harbor never logs
#   in, out, or reconfigures an installation it did not create (section 3.6), so an
#   adopted or pre-existing one is exit 3 naming what was found;
#   --ssh is decided from the record's flag set and the feature gate: it is added only
#   when bootstrap recorded --tailscale-ssh and the gate is open, and while the gate is
#   closed the record's intent is met by printing the root-owned alternative,
#   sudo tailscale set --ssh, and an explicit --tailscale-ssh is refused, exit 3, as an
#   unsupported flag;
#   the operator state root is created with its section 3.7 modes if absent, the
#   operator lock is taken, and recovery runs, since every command owes that under its
#   lock, though this one journals nothing;
#   BackendState is read as the operator without sudo, which is the read the section
#   5.2 grant made possible, and Running is already logged in, exit 0 with no up;
#   then tailscale up --hostname=harbor-node, plus --ssh when decided, with its output
#   passed straight through so the operator sees the login URL where the vendor prints
#   it. A non-zero up is exit 3 with the vendor's output already on the terminal and
#   the sudo form for the owner to run outside Harbor, because a daemon that refuses
#   the operator's write for lack of authority is exactly what the read-only probe of
#   section 5.2 could not rule out; a declined login lands on the same line and is
#   simply rerun. Then up to ten minutes for Running, exit 3 on timeout.
# Nothing here is journaled and no state record is written, on any path.
harbor_auth_tailscale() {
  local root record probe locked want_ssh=0 ownership operator flags recorded ssh=""
  local rc=0 waited=0 form
  [ "$#" -ge 4 ] || harbor_die 3 usage "usage: harbor_auth_tailscale <state-root> <record> <probe> <locked-tailscale-version> [--tailscale-ssh]"
  root="${1}"
  record="${2}"
  probe="${3}"
  locked="${4}"
  shift 4
  while [ "$#" -gt 0 ]; do
    case "${1}" in
      --tailscale-ssh) want_ssh=1 ;;
      *) harbor_die 3 usage "${HARBOR_AUTH_USAGE}" ;;
    esac
    shift
  done
  harbor_auth_refuse_root
  ownership="$(harbor_auth_record_value "${record}" tailscale_ownership)"
  case "${ownership}" in
    harbor-installed) ;;
    "")
      harbor_die 3 auth.record "${record} is absent, unreadable, or names no tailscale_ownership, so Harbor cannot tell whose Tailscale this node runs and will not log it in: a bootstrapped node records it, so run sudo harbor bootstrap; nothing was changed"
      ;;
    *)
      harbor_die 3 auth.ownership "${record} records the Tailscale on this node as ${ownership}, not harbor-installed, and Harbor never logs in an installation it did not create (design section 3.6): bring it up yourself, outside Harbor, with your own preferences; nothing was changed"
      ;;
  esac
  operator="$(harbor_auth_record_value "${record}" operator)"
  flags="$(harbor_auth_record_value "${record}" flags)"
  recorded="$(harbor_bootstrap_flags_field "${flags}" tailscale-ssh)"
  harbor_auth_ssh_gate "${probe}" "${locked}"
  if [ "${want_ssh}" = 1 ]; then
    [ "${HARBOR_AUTH_SSH_GATE}" = open ] \
      || harbor_die 3 auth.ssh_gate "--tailscale-ssh is not a supported flag of this release: ${HARBOR_AUTH_SSH_GATE_WHY}; harbor auth tailscale logs this node in without --ssh, and Tailscale SSH is the owner's to enable outside Harbor with: sudo tailscale set --ssh; nothing was changed"
    [ "${recorded}" = yes ] \
      || harbor_die 3 auth.ssh_unrecorded "bootstrap did not record --tailscale-ssh for this node (its flag set records tailscale-ssh=${recorded:-no}), and the posture of a bootstrapped node is the one its first bootstrap recorded (design section 5.2): enable Tailscale SSH outside Harbor with sudo tailscale set --ssh, or run sudo harbor teardown --level node and bootstrap again with --tailscale-ssh; nothing was changed"
  fi
  if [ "${recorded}" = yes ]; then
    if [ "${HARBOR_AUTH_SSH_GATE}" = open ]; then
      ssh="--ssh"
    else
      harbor_msg "auth.ssh_gate: bootstrap recorded --tailscale-ssh for this node, but ${HARBOR_AUTH_SSH_GATE_WHY}, so the login runs without --ssh; enable Tailscale SSH outside Harbor, as the owner, with: sudo tailscale set --ssh"
    fi
  fi
  form="tailscale up --hostname=${HARBOR_AUTH_HOSTNAME}${ssh:+ ${ssh}}"
  # The operator state root, created with the design section 3.7 modes before the lock
  # is taken, as every operator command that takes the lock does; the check runs again
  # after the apply (section 6.1).
  harbor_state_root_create "${root}" operator
  [ -d "${root}" ] \
    || harbor_die 2 auth.state_root "${root} is still not a directory after Harbor created it, so the operator lock has nowhere to live and nothing further was attempted; check the filesystem it sits on and rerun"
  harbor_log_open "${root}/harbor.log" 0600
  harbor_log command "auth tailscale${want_ssh:+ --tailscale-ssh}"
  harbor_lock_acquire "${root}" operator
  harbor_journal_init "${root}"
  harbor_journal_recover "${root}"
  harbor_step recovery-scan
  rc=0
  harbor_auth_backend_state || rc="$?"
  [ "${rc}" = 0 ] \
    || harbor_die 3 auth.status "tailscale status --json failed as $(id -un) without sudo (exit ${rc}): ${HARBOR_AUTH_STATUS_OUT}; the login needs the operator grant of design section 5.2 first, which the owner makes outside Harbor with: sudo tailscale set --operator=${operator:-OPERATOR}, then rerun; nothing was changed"
  if [ "${HARBOR_AUTH_BACKEND_STATE}" = Running ]; then
    harbor_msg "auth.tailscale: this node is already logged in (BackendState Running); nothing to do"
    return 0
  fi
  harbor_log auth "BackendState is ${HARBOR_AUTH_BACKEND_STATE}; running ${form}"
  harbor_msg "logging this node in with: ${form}; open the login URL the vendor prints below on your Mac and approve the node"
  # The vendor's output is not captured: the login URL reaches the operator where
  # tailscale prints it and nowhere else, never a variable, a message, or the log.
  harbor_log_vendor tailscale up "--hostname=${HARBOR_AUTH_HOSTNAME}" ${ssh:+"${ssh}"}
  rc=0
  tailscale up "--hostname=${HARBOR_AUTH_HOSTNAME}" ${ssh:+"${ssh}"} || rc="$?"
  harbor_step tailscale-up
  [ "${rc}" = 0 ] \
    || harbor_die 3 auth.up "${form} exited ${rc}, and the vendor's own output above says why; if the daemon refused the operator's request for lack of authority, the login is the owner's to run outside Harbor with: sudo ${form}; if the login was declined, rerun harbor auth tailscale; nothing was changed and nothing was journaled"
  while :; do
    rc=0
    harbor_auth_backend_state || rc="$?"
    [ "${rc}" = 0 ] \
      || harbor_die 2 auth.status "${form} exited 0 but tailscale status --json now fails (exit ${rc}): ${HARBOR_AUTH_STATUS_OUT}; inspect tailscaled on this node and rerun harbor auth tailscale; nothing was journaled"
    [ "${HARBOR_AUTH_BACKEND_STATE}" != Running ] || break
    [ "${waited}" -lt "${HARBOR_AUTH_TIMEOUT_SECONDS}" ] \
      || harbor_die 3 auth.timeout "${form} exited 0 but BackendState is still ${HARBOR_AUTH_BACKEND_STATE} after ${HARBOR_AUTH_TIMEOUT_SECONDS}s, so the login was not completed or the node was not approved; rerun harbor auth tailscale; nothing was changed and nothing was journaled"
    sleep "${HARBOR_AUTH_POLL_SECONDS}"
    waited=$((waited + HARBOR_AUTH_POLL_SECONDS))
  done
  harbor_msg "this node is logged in to its tailnet (BackendState Running); next, as the operator: harbor provision"
}
# harbor_auth_cmd TOOL [flag...]: the dispatcher's entry, harbor auth <tool>. tailscale
# is this file's own command, claude and codex are lib/agents.sh's, and connect is still
# named as a later step of this release rather than as unknown. Root is refused first,
# before the entrypoint check judges anything. The record and the probe are production
# paths, and both take a fixture stand-in for the unit lane in the way lib/entrypoint.sh
# takes its own: the caller is never root here, so a stand-in grants nothing, since
# every path it can name is one it could already read, and the command reads those two
# files and mutates neither. Then the installed-entrypoint check of design section 5.2,
# the pinned tailscale_version for the gate, and the operator state root of section 3.7.
#
# The agent arm reads neither of those two files and takes no flags. Whose Tailscale
# this node runs says nothing about whose Anthropic or OpenAI account the operator is
# about to sign in to, and the pinned tailscale_version decides nothing there either, so
# the arm goes straight to lib/agents.sh, which refuses root and creates the operator
# state root itself, in the order harbor_auth_tailscale established.
harbor_auth_cmd() {
  local tool="${1:-}" record probe locked
  case "${tool}" in
    tailscale) shift ;;
    claude | codex)
      shift
      [ "$#" -eq 0 ] || harbor_die 3 usage "${HARBOR_AUTH_USAGE}"
      harbor_state_root_for_principal
      harbor_agents_auth "${HARBOR_STATE_ROOT}" "${HOME}" "${tool}"
      return 0
      ;;
    connect)
      harbor_die 3 usage "harbor auth ${tool} is not part of this release (design section 8, PR 4); ${HARBOR_AUTH_USAGE}"
      ;;
    *) harbor_die 3 usage "${HARBOR_AUTH_USAGE}" ;;
  esac
  harbor_auth_refuse_root
  # The record and the probe are what this command reads to decide whose Tailscale
  # this is and whether --ssh is a supported flag, so the stand-ins the tests point at
  # them are honoured only under HARBOR_DEV, the same switch the installed-entrypoint
  # check below already treats as the mark of a checkout. The operator this command
  # runs as is untrusted (design section 2), and a released Harbor that took the path
  # of its own authorization inputs from that account's environment would be reading
  # its answer from the party it is deciding about.
  record="${HARBOR_AUTH_RECORD}"
  probe="${HARBOR_ROOT}/${HARBOR_AUTH_PROBE_RELATIVE}"
  if [ -n "${HARBOR_DEV:-}" ]; then
    record="${HARBOR_AUTH_FIXTURE_RECORD:-${record}}"
    probe="${HARBOR_AUTH_FIXTURE_PROBE:-${probe}}"
  fi
  harbor_entrypoint_check "${0}" "${record}"
  harbor_versions_load "$(harbor_versions_lock_path)"
  locked="$(harbor_version_require tailscale_version)" || exit "$?"
  harbor_state_root_for_principal
  harbor_auth_tailscale "${HARBOR_STATE_ROOT}" "${record}" "${probe}" "${locked}" ${1+"$@"}
}
