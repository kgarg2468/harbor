#!/bin/bash
# The state record (design section 5.2, the State record row): bootstrap.json, the flat,
# non-secret JSON the last row of bootstrap writes into the root state root. It is mode
# 0644 and root-owned, so the operator can read the release tag, the entrypoint, and the
# account Harbor made for them, and only root can write it. Every value it carries is a
# value an earlier row already proved and is taken as a parameter: this library inspects no
# package, no account, and no runtime of its own, so nothing here can disagree with the row
# that owns the value. The state root is a parameter too; production passes /var/lib/harbor.
#
# The write is one journaled transaction of design section 3.7 in the shape every other file
# this release writes uses: a prepared entry, a temporary file, a rename over the record, the
# step boundary, then the applied write. The op is the file op, whose observer
# harbor_observe_op_file lib/journal.sh already defines, so a crash between the rename and the
# applied write leaves an entry recovery can decide against a record that is either the whole
# new one or the whole old one and never half of either. Depends on lib/log.sh
# (harbor_json_escape, harbor_die, harbor_step), lib/lock.sh (HARBOR_LOCK_ID_PID) and
# lib/journal.sh (the entry, the observation, and the platform sync).
# The three ownerships design section 5.2 lets the record name for Tailscale. The word is a
# parameter because the Tailscale rows of that table are the rows that learn it; this library
# only refuses one outside the vocabulary, fail-closed, since a record naming an ownership
# teardown cannot read is a record it would have to refuse to act on later.
HARBOR_STATE_TAILSCALE_OWNERSHIPS="harbor-installed adopted pre-existing"
# harbor_state_record_path STATE_ROOT: the record inside the state root, the one path this
# library names and the path design section 5.2 calls /var/lib/harbor/bootstrap.json.
harbor_state_record_path() {
  printf '%s/bootstrap.json' "${1}"
}
# harbor_state_record_number VALUE LABEL: VALUE must be a decimal number, because the record
# writes it unquoted. An empty or non-numeric uid or gid is refused rather than written: the
# name service answered something Harbor cannot record as the number it is, and a record that
# is not JSON is a record no later command could read at all.
harbor_state_record_number() {
  case "${1}" in
    "") harbor_die 3 state.number "${2} is empty, and the record carries it as a number" ;;
    *[!0-9]*) harbor_die 3 state.number "${2} '${1}' is not a decimal number, and the record carries it as one" ;;
  esac
}
# harbor_state_record_render TAG ENTRYPOINT LOCK_SHA256 FLAGS NODEJS_VERSION
# TAILSCALE_OWNERSHIP OPERATOR UID GID HOME TIMESTAMP: the record itself, built with printf
# and harbor_json_escape rather than with jq, because every function under lib/ runs before
# the Packages row could have installed one. One key per line in a fixed order, so a reader
# as small as the sed of harbor_entrypoint_record_tag can find a value and so two records
# built from equal values are equal byte for byte, which is what makes the rerun below
# rewrite nothing. The uid and the gid are numbers; every other value is a string.
#
# Tailscale carries its ownership and, when Harbor installed or adopted the daemon, the
# version it installed. This release installs no Tailscale and adopts none, so the only
# ownership it can truthfully record is pre-existing and there is no version to name: slice
# 3d, which owns lib/tailscale.sh, is what makes harbor-installed and adopted reachable and
# what adds the version key beside this one.
harbor_state_record_render() {
  printf '{\n'
  printf '  "release_tag": "%s",\n' "$(harbor_json_escape "${1}")"
  printf '  "entrypoint": "%s",\n' "$(harbor_json_escape "${2}")"
  printf '  "lock_sha256": "%s",\n' "$(harbor_json_escape "${3}")"
  printf '  "flags": "%s",\n' "$(harbor_json_escape "${4}")"
  printf '  "nodejs_version": "%s",\n' "$(harbor_json_escape "${5}")"
  printf '  "tailscale_ownership": "%s",\n' "$(harbor_json_escape "${6}")"
  printf '  "operator": "%s",\n' "$(harbor_json_escape "${7}")"
  printf '  "operator_uid": %s,\n' "${8}"
  printf '  "operator_gid": %s,\n' "${9}"
  printf '  "operator_home": "%s",\n' "$(harbor_json_escape "${10}")"
  printf '  "timestamp": "%s"\n' "$(harbor_json_escape "${11}")"
  printf '}\n'
}
# harbor_state_record_timestamp RECORD: the timestamp RECORD carries, or nothing when there
# is no record or it carries none. Read with sed for the same reason the record is built with
# printf: no jq is available to lib/. It is read rather than replaced on a rerun so that the
# timestamp keeps meaning what design section 5.7 compares against, the moment this node's
# record was established, and so a rerun that changes nothing else leaves the record byte for
# byte as it was rather than rewriting it once a second.
harbor_state_record_timestamp() {
  local record="${1}"
  [ -f "${record}" ] || return 0
  sed -n 's/^  "timestamp": "\([^"]*\)"$/\1/p' "${record}" | sed -n 1p
}
# harbor_state_record STATE_ROOT TAG ENTRYPOINT LOCK_SHA256 FLAGS NODEJS_VERSION
# TAILSCALE_OWNERSHIP OPERATOR UID GID HOME: the State record row of design section 5.2,
# written last and journaled as one file transaction. A record that is already, byte for
# byte, what would be written is journaled observed and left alone, which is what makes a
# rerun on a healthy node rewrite nothing; a record whose content, mode, or owner differs is
# rewritten with a fresh timestamp and journaled modified with the prior state; an absent one
# is journaled created. Anything at the path that is not a regular file is foreign and exits 3
# untouched, because Harbor overwrites nothing it cannot prove it wrote.
harbor_state_record() {
  local root tag entrypoint lock flags nodejs tailscale operator uid gid home
  local record pre post stamp tmp ownership entry known=0 word
  [ "$#" -eq 11 ] \
    || harbor_die 3 usage "usage: harbor_state_record <state-root> <release-tag> <entrypoint> <lock-sha256> <flag-set> <nodejs-version> <tailscale-ownership> <operator> <uid> <gid> <home>"
  root="${1}"
  tag="${2}"
  entrypoint="${3}"
  lock="${4}"
  flags="${5}"
  nodejs="${6}"
  tailscale="${7}"
  operator="${8}"
  uid="${9}"
  gid="${10}"
  home="${11}"
  for word in ${HARBOR_STATE_TAILSCALE_OWNERSHIPS}; do
    [ "${word}" != "${tailscale}" ] || known=1
  done
  [ "${known}" = 1 ] \
    || harbor_die 3 state.tailscale_ownership "'${tailscale}' is not one of the Tailscale ownerships design section 5.2 records (${HARBOR_STATE_TAILSCALE_OWNERSHIPS}); nothing was written"
  harbor_state_record_number "${uid}" "the operator uid"
  harbor_state_record_number "${gid}" "the operator gid"
  record="$(harbor_state_record_path "${root}")"
  pre="$(harbor_observe_file "${record}")"
  case "${pre}" in
    '"unobservable:'*)
      harbor_die 3 state.foreign "${record} exists and is not a regular file; inspect it and remove it by hand, then rerun"
      ;;
    '{"symlink"'*)
      # A symlink is named separately because harbor_observe_file reports one as a symlink
      # rather than as unobservable, so the arm above never sees it. Harbor writes the record
      # as an ordinary file, so a symlink here is something else's, and replacing it would
      # remove whatever an administrator pointed at from under them.
      harbor_die 3 state.foreign "${record} is a symlink to $(readlink "${record}"), and Harbor writes the record as an ordinary file; inspect it and remove it by hand, then rerun"
      ;;
  esac
  tmp="${root}/.tmp.$(basename "${record}").${HARBOR_LOCK_ID_PID}"
  rm -f "${tmp}"
  # The comparison is made against the timestamp the record already carries, so a record that
  # is otherwise unchanged compares equal and is left exactly as it is. Only once the record
  # is going to be rewritten anyway does the timestamp become this moment.
  stamp="$(harbor_state_record_timestamp "${record}")"
  if [ -n "${stamp}" ]; then
    harbor_state_record_render "${tag}" "${entrypoint}" "${lock}" "${flags}" "${nodejs}" \
      "${tailscale}" "${operator}" "${uid}" "${gid}" "${home}" "${stamp}" >"${tmp}"
    chmod 0644 "${tmp}"
    post="$(harbor_observe_file "${tmp}")"
    if [ "${post}" = "${pre}" ]; then
      rm -f "${tmp}"
      harbor_journal_create "${root}" file "${record}" observed applied "${pre}" "${post}"
      harbor_log state "${record} already records this node; nothing to do"
      return 0
    fi
  fi
  harbor_state_record_render "${tag}" "${entrypoint}" "${lock}" "${flags}" "${nodejs}" \
    "${tailscale}" "${operator}" "${uid}" "${gid}" "${home}" "$(harbor_utc_now)" >"${tmp}"
  chmod 0644 "${tmp}"
  post="$(harbor_observe_file "${tmp}")"
  ownership=modified
  [ "${pre}" != '"absent"' ] || ownership=created
  harbor_journal_create "${root}" file "${record}" "${ownership}" prepared "${pre}" "${post}"
  entry="${HARBOR_JOURNAL_ENTRY}"
  harbor_journal_sync_path "${tmp}"
  if ! mv -f "${tmp}" "${record}"; then
    rm -f "${tmp}"
    harbor_die 2 state.rename "renaming ${tmp} onto ${record} failed; ${record} holds what it held before and $(basename "${entry}") stays prepared, rerun after fixing the cause"
  fi
  harbor_journal_sync_path "${root}"
  harbor_step state-record
  # Section 6.1: the check runs again after the apply, and a second failure aborts naming the
  # record, leaving its entry prepared for the next run to decide.
  [ "$(harbor_observe_file "${record}")" = "${post}" ] \
    || harbor_die 2 state.verify "${record} is not what was just written to it; $(basename "${entry}") stays prepared"
  harbor_journal_set_phase "${entry}" applied
}
