#!/bin/bash
# SSH (design section 3.5): the operator's authorized key, copied from the invoking
# administrator's own and journaled by hash. The operator identity, its home, and the
# state root are parameters; production passes the real account and /var/lib/harbor,
# unit tests pass a fixture identity and a disposable root, exactly as lib/apt.sh
# takes its destination root and lib/node.sh its prefix. Depends on lib/log.sh
# (harbor_die, harbor_log, harbor_msg, harbor_step), lib/lock.sh (harbor_os,
# HARBOR_LOCK_ID_PID), and lib/journal.sh (harbor_observe_file, harbor_sha256,
# harbor_stat_mode, harbor_stat_owner, the entry writers).
#
# The transaction is two entries, because the journal decides a prepared entry by
# comparing what it observes at the entry's target with the entry's own pre_state and
# post_state, and an observer is handed that target and nothing else. Source facts
# folded into the target entry's post_state could never be reproduced from the target
# alone, so that entry would be undecidable at exactly the moment recovery needs it.
# The pair instead records:
#   authorized-key-source  target = the source path, observed and directly applied,
#                          state = its SHA-256, mode, and owner: it is read, never
#                          written, and its mode is the administrator's own.
#   authorized-key         target = the operator's authorized_keys, pre_state absent
#                          and post_state its SHA-256, mode, and owner, or observed
#                          when a key Harbor did not place is already there.
# The copy is byte for byte, so the two SHA-256 values are equal and a later run can
# prove what was copied from where by reading the adjacent pair.
# harbor_ssh_user_home USER: the home directory USER's passwd entry names. The home
# root is read from the environment only when the caller is not root, so that a unit
# test can stand in for accounts it cannot create; root, the only principal that runs
# bootstrap (design section 3.1), always resolves through the passwd database, and no
# root code path can see the override.
harbor_ssh_user_home() {
  local user="${1}" home
  if [ "$(id -u)" != 0 ] && [ -n "${HARBOR_SSH_HOME_ROOT:-}" ]; then
    printf '%s/%s' "${HARBOR_SSH_HOME_ROOT%/}" "${user}"
    return 0
  fi
  command -v getent >/dev/null 2>&1 \
    || harbor_die 3 ssh.no_getent "getent is not available, so the home directory of ${user} cannot be read from the passwd database; pass --authorized-key-file PATH"
  home="$(getent passwd "${user}" | sed -n 1p | cut -d: -f6)"
  [ -n "${home}" ] \
    || harbor_die 3 ssh.no_account "${user} has no passwd entry on this node, so Harbor cannot find an authorized_keys file for it; pass --authorized-key-file PATH"
  printf '%s' "${home}"
}
# harbor_ssh_source [PATH]: the file the operator's key is copied from, printed on
# stdout. PATH, the --authorized-key-file argument, is used as given. Without it the
# source is the invoking SUDO_USER's own ~/.ssh/authorized_keys and nothing else:
# never HOME, never the login name, never another account's file. A SUDO_USER that is
# empty or root, or whose file is missing, unreadable, or empty, is a precondition
# that names --authorized-key-file, because Harbor never guesses another account's
# key and never invents one.
harbor_ssh_source() {
  local given="${1:-}" user home path
  if [ -n "${given}" ]; then
    [ -e "${given}" ] \
      || harbor_die 3 ssh.source_missing "--authorized-key-file ${given} does not exist"
    [ -f "${given}" ] \
      || harbor_die 3 ssh.source_not_file "--authorized-key-file ${given} is not a regular file"
    [ -r "${given}" ] \
      || harbor_die 3 ssh.source_unreadable "--authorized-key-file ${given} cannot be read"
    [ -s "${given}" ] \
      || harbor_die 3 ssh.source_empty "--authorized-key-file ${given} is empty; Harbor copies a key, it never invents one"
    printf '%s' "${given}"
    return 0
  fi
  user="${SUDO_USER:-}"
  [ -n "${user}" ] \
    || harbor_die 3 ssh.no_sudo_user "there is no SUDO_USER to take an authorized key from; rerun through sudo from your own account or pass --authorized-key-file PATH"
  [ "${user}" != root ] \
    || harbor_die 3 ssh.sudo_user_root "SUDO_USER is root, which is not a non-root local account Harbor will take a key from; pass --authorized-key-file PATH"
  home="$(harbor_ssh_user_home "${user}")" || exit "$?"
  path="${home}/.ssh/authorized_keys"
  [ -e "${path}" ] \
    || harbor_die 3 ssh.no_default_key "${path} does not exist, so ${user} has no authorized key to copy; pass --authorized-key-file PATH"
  [ -f "${path}" ] \
    || harbor_die 3 ssh.default_key_not_file "${path} is not a regular file; pass --authorized-key-file PATH"
  [ -r "${path}" ] \
    || harbor_die 3 ssh.unreadable_default_key "${path} cannot be read; pass --authorized-key-file PATH"
  [ -s "${path}" ] \
    || harbor_die 3 ssh.empty_default_key "${path} is empty, so ${user} has no authorized key to copy; pass --authorized-key-file PATH"
  printf '%s' "${path}"
}
# harbor_observe_op_authorized_key TARGET and harbor_observe_op_authorized_key_source
# SOURCE: the observers harbor_journal_observe dispatches to for the two ops this
# library emits, so an entry left prepared by a crash between the rename into place
# and the applied write is decidable by recovery (design section 3.7). Both render a
# path in the same shape harbor_observe_file does, which is what both entries carry.
# Inspection only. Called only through harbor_journal_observe.
harbor_observe_op_authorized_key() {
  harbor_observe_file "${1}"
}
harbor_observe_op_authorized_key_source() {
  harbor_observe_file "${1}"
}
# harbor_ssh_authorize STATE_ROOT OPERATOR OPERATOR_HOME [SOURCE]: give OPERATOR the
# authorized key it needs before password authentication is disabled for it. The step
# is decided by inspection first (design section 6.1): an authorized_keys already at
# the target is journaled observed and left byte for byte alone, no source is consulted
# for it, and Harbor never appends to, rewrites, re-modes, or removes a key it did not
# place. Otherwise the source of harbor_ssh_source is copied to a temporary file beside
# the target, chmod 0600 and chowned to OPERATOR before it is anywhere the operator can
# read, journaled prepared, renamed into place in one step, and verified: owned by
# OPERATOR, mode 0600, inside a 0700 .ssh owned by OPERATOR. Only a .ssh Harbor creates
# is created 0700; one that is already there and is not a 0700 directory owned by
# OPERATOR is a precondition rather than a mode Harbor silently changes.
harbor_ssh_authorize() {
  local root operator home group ssh_dir target pre source src_state post tmp entry
  [ "$#" -ge 3 ] && [ "$#" -le 4 ] \
    || harbor_die 3 usage "usage: harbor_ssh_authorize <state-root> <operator> <operator-home> [source]"
  root="${1}"
  operator="${2}"
  home="${3}"
  group="$(id -gn "${operator}" 2>/dev/null)" \
    || harbor_die 3 ssh.no_operator "${operator} is not an account on this node, so its authorized key cannot be placed"
  [ -d "${home}" ] \
    || harbor_die 3 ssh.no_home "${home} is not a directory, so ${operator} has no home to place an authorized key in"
  ssh_dir="${home}/.ssh"
  target="${ssh_dir}/authorized_keys"
  if [ -e "${ssh_dir}" ] || [ -L "${ssh_dir}" ]; then
    { [ -d "${ssh_dir}" ] && [ ! -L "${ssh_dir}" ]; } \
      || harbor_die 3 ssh.ssh_dir_foreign "${ssh_dir} is already there and is not a directory; Harbor removes nothing it cannot prove it created: inspect it, remove it by hand if it is not needed, and rerun"
    [ "$(harbor_stat_owner "${ssh_dir}")" = "${operator}" ] \
      || harbor_die 3 ssh.ssh_dir_owner "${ssh_dir} is owned by $(harbor_stat_owner "${ssh_dir}"), not by ${operator}; fix its ownership by hand and rerun"
    [ "$(harbor_stat_mode "${ssh_dir}")" = 0700 ] \
      || harbor_die 3 ssh.ssh_dir_mode "${ssh_dir} is mode $(harbor_stat_mode "${ssh_dir}"), not 0700, and Harbor does not change the mode of a directory it did not create; fix it by hand and rerun"
  else
    mkdir "${ssh_dir}" \
      || harbor_die 2 ssh.ssh_dir_create "cannot create ${ssh_dir}"
    chmod 0700 "${ssh_dir}"
    chown "${operator}:${group}" "${ssh_dir}" \
      || harbor_die 2 ssh.ssh_dir_chown "cannot give ${ssh_dir} to ${operator}:${group}"
    harbor_log ssh "created ${ssh_dir} 0700 for ${operator}"
  fi
  pre="$(harbor_observe_file "${target}")"
  case "${pre}" in
    '"absent"') ;;
    '{"sha256":'*)
      harbor_journal_create "${root}" authorized-key "${target}" observed applied "${pre}" "${pre}"
      harbor_log ssh "${target} is already there; leaving it exactly as it is"
      harbor_msg "${operator} already has ${target}; it was recorded and left untouched"
      return 0
      ;;
    *)
      harbor_die 3 ssh.target_foreign "${target} is already there and is not a regular file; Harbor removes nothing it cannot prove it created: inspect it, remove it by hand if it is not needed, and rerun"
      ;;
  esac
  source="$(harbor_ssh_source "${4:-}")" || exit "$?"
  src_state="$(harbor_observe_file "${source}")"
  harbor_journal_create "${root}" authorized-key-source "${source}" observed applied "${src_state}" "${src_state}"
  tmp="${ssh_dir}/.tmp.authorized_keys.${HARBOR_LOCK_ID_PID:-$$}"
  rm -f "${tmp}"
  cp "${source}" "${tmp}" \
    || harbor_die 2 ssh.copy "copying ${source} to ${tmp} failed; ${target} is unchanged"
  chmod 0600 "${tmp}"
  chown "${operator}:${group}" "${tmp}" \
    || harbor_die 2 ssh.chown "cannot give ${tmp} to ${operator}:${group}; ${target} is unchanged"
  post="$(harbor_observe_file "${tmp}")"
  harbor_journal_create "${root}" authorized-key "${target}" created prepared "${pre}" "${post}"
  entry="${HARBOR_JOURNAL_ENTRY}"
  harbor_step ssh-key-prepared
  harbor_journal_sync_path "${tmp}"
  if ! mv -f "${tmp}" "${target}"; then
    rm -f "${tmp}"
    harbor_die 2 ssh.rename "renaming ${tmp} onto ${target} failed; ${target} holds what it held before and $(basename "${entry}") stays prepared, rerun after fixing the cause"
  fi
  harbor_journal_sync_path "${ssh_dir}"
  harbor_step ssh-key-copied
  [ "$(harbor_observe_file "${target}")" = "${post}" ] \
    || harbor_die 2 ssh.verify "${target} is not what was staged for it after the copy; $(basename "${entry}") stays prepared"
  [ "$(harbor_stat_mode "${target}")" = 0600 ] \
    || harbor_die 2 ssh.verify_mode "${target} is mode $(harbor_stat_mode "${target}") after the copy, not 0600; $(basename "${entry}") stays prepared"
  [ "$(harbor_stat_owner "${target}")" = "${operator}" ] \
    || harbor_die 2 ssh.verify_owner "${target} is owned by $(harbor_stat_owner "${target}") after the copy, not by ${operator}; $(basename "${entry}") stays prepared"
  [ "$(harbor_stat_mode "${ssh_dir}")" = 0700 ] && [ "$(harbor_stat_owner "${ssh_dir}")" = "${operator}" ] \
    || harbor_die 2 ssh.verify_dir "${ssh_dir} is mode $(harbor_stat_mode "${ssh_dir}") owned by $(harbor_stat_owner "${ssh_dir}") after the copy, not 0700 owned by ${operator}; $(basename "${entry}") stays prepared"
  harbor_journal_set_phase "${entry}" applied
  harbor_step ssh-key-applied
  harbor_msg "copied the authorized key from ${source} to ${target}"
}
