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
    harbor_ssh_has_usable_key "${given}" \
      || harbor_die 3 ssh.source_empty "--authorized-key-file ${given} holds no usable authorized-key line: it is empty, or every line in it is blank or a comment; Harbor copies a key, it never invents one, and it will not install a file with no key in it and then disable password authentication for the account that would need it"
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
  harbor_ssh_has_usable_key "${path}" \
    || harbor_die 3 ssh.empty_default_key "${path} holds no usable authorized-key line (it is empty, or every line in it is blank or a comment), so ${user} has no authorized key to copy; pass --authorized-key-file PATH"
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
# harbor_ssh_device PATH: the number this platform gives the filesystem PATH sits on,
# printed on stdout, or nothing when it cannot be read. Inspection only, in the same
# two-platform shape harbor_stat_mode and harbor_stat_owner use.
harbor_ssh_device() {
  case "$(harbor_os)" in
    Linux) stat -c '%d' "${1}" 2>/dev/null || true ;;
    Darwin) stat -f '%d' "${1}" 2>/dev/null || true ;;
  esac
}
# harbor_ssh_assert_one_filesystem STAGE DEST WHAT: refuse unless STAGE and DEST are on
# one filesystem, naming both paths. Everything root writes, chmods, and chowns for the
# operator's key is staged in the root-owned state root and moved into the operator's
# own directory in one step, and that step is sound only because rename(2) never
# resolves the final component of either path: a symlink an unprivileged user planted at
# the destination is unlinked by the rename rather than written through. mv degrades to
# copy-and-unlink across filesystems, and a copy does follow that symlink, so a
# destination on another filesystem is refused rather than served by the weaker
# mechanism. Exit 3: it is a property of how this node is partitioned, which Harbor
# cannot fix and will not work around.
harbor_ssh_assert_one_filesystem() {
  local stage="${1}" dest="${2}" what="${3}" from to
  from="$(harbor_ssh_device "${stage}")"
  to="$(harbor_ssh_device "${dest}")"
  { [ -n "${from}" ] && [ -n "${to}" ]; } \
    || harbor_die 3 ssh.device "the filesystem of ${stage} or of ${dest} cannot be read, so Harbor cannot prove that moving ${what} between them would be a rename rather than a copy that follows a symlink an unprivileged user can plant; nothing was written; install ${what} by hand"
  [ "${from}" = "${to}" ] \
    || harbor_die 3 ssh.cross_filesystem "${stage} and ${dest} are on different filesystems, so moving ${what} between them would be a copy that follows a symlink an unprivileged user can plant at the destination, not a rename that unlinks it; Harbor stages every mode and every owner where only root can write and will not weaken that: install ${what} by hand, or give ${stage} and ${dest} one filesystem, and rerun; nothing was written"
}
# harbor_ssh_has_usable_key PATH: 0 when PATH holds at least one line sshd would read as
# an authorized key. It is the one predicate every place in this library that asks "is
# there a key here" uses, because the three places that ask are the three that stand
# between a flag and an unreachable node, and three copies of the question are how they
# drift apart:
#   harbor_ssh_source              the key Harbor is about to copy, in both its branches
#   harbor_ssh_authorize           the operator's own file, already at the target
#   harbor_ssh_admin_authorized_keys  the installation user's file, gating --harden-sshd
# Every one of them used to ask [ -s PATH ], which is "not zero bytes". A file holding
# one newline, or one line reading '# my key is elsewhere', is not zero bytes and holds
# no key, and each of those three sites then went on to take password authentication
# away from the account whose file it had just approved.
#
# The rule is sshd's own and no more: sshd skips leading blanks and then ignores a line
# that is empty or whose first non-blank character is '#' (auth2-pubkey.c), so a file of
# nothing but blank lines and comments carries no key however many bytes it has. Anything
# else counts. That is deliberately generous rather than clever: an authorized_keys line
# may carry options before the key type, so a line like
# restrict,from="10.0.0.0/8" ssh-ed25519 AAAA... is a key and a test anchored on a key
# type token at the start of the line would reject it. Refusing a real key is a lockout
# of its own kind, the administrator denied a flag they should have had, so this rejects
# only what cannot be a key and never guesses at what can.
#
# Text rather than ssh-keygen -l -f, which would be OpenSSH's own answer: the unit lane's
# fixture keys are the deliberately unreal placeholder strings of design section 3.8, so
# ssh-keygen would refuse every one of them, and answering it instead would mean a shim
# under tests/shims/. Inspection only, and stderr is discarded because an unreadable file
# is a separate refusal each caller makes before this one.
harbor_ssh_has_usable_key() {
  grep -q -v -e '^[[:space:]]*$' -e '^[[:space:]]*#' -- "${1}" 2>/dev/null
}
# harbor_ssh_prepared_entry_for STATE_ROOT PATH: the newest journal entry that is still
# prepared, targets PATH, and records as its post_state exactly what PATH observes as
# now, printed on stdout, or nothing. That is the signature of a file transaction whose
# artifact landed and whose transaction never completed, which is what makes the reload
# below owed by a rerun rather than only by the run that wrote the file. An entry whose
# post_state is not what is on disk is a crash window recovery decides, never this.
# Inspection only.
harbor_ssh_prepared_entry_for() {
  local root="${1}" path="${2}" dir observed entry found=""
  dir="${root}/journal"
  [ -d "${dir}" ] || return 0
  observed="$(harbor_observe_file "${path}")"
  for entry in "${dir}"/[0-9][0-9][0-9][0-9]-*.json; do
    [ -e "${entry}" ] || continue
    [ "$(harbor_journal_string "${entry}" phase)" = prepared ] || continue
    [ "$(harbor_journal_string "${entry}" target)" = "${path}" ] || continue
    [ "$(harbor_journal_raw "${entry}" post_state)" = "${observed}" ] || continue
    found="${entry}"
  done
  printf '%s' "${found}"
}
# harbor_ssh_authorize STATE_ROOT OPERATOR OPERATOR_HOME [SOURCE]: give OPERATOR the
# authorized key it needs before password authentication is disabled for it. The step
# is decided by inspection first (design section 6.1): an authorized_keys already at
# the target is journaled observed and left byte for byte alone, no source is consulted
# for it, and Harbor never appends to, rewrites, re-modes, or removes a key it did not
# place. Otherwise the source of harbor_ssh_source is staged, chmod 0600 and chowned to
# OPERATOR before it is anywhere the operator can read, journaled prepared, renamed into
# place in one step, and verified: owned by OPERATOR, mode 0600, inside a 0700 .ssh owned
# by OPERATOR. Only a .ssh Harbor creates is created 0700; one that is already there and
# is not a 0700 directory owned by OPERATOR is a precondition rather than a mode Harbor
# silently changes.
#
# Where the staging happens is a privilege boundary, not a convenience. OPERATOR may be
# an account that already existed and that a real person is logged into: the design
# section 5.2 preflight refuses root, the invoking SUDO_USER, and any sudo or admin group
# member, but an ordinary existing account is allowed, and the branch below that accepts
# a pre-existing ~/.ssh exists for exactly that account. Everything root writes, chmods,
# or chowns therefore happens inside STATE_ROOT, which design section 5.2 creates 0755
# root-owned under root-owned ancestors, so no unprivileged user can create, replace, or
# redirect any component of a staging path. cp, chmod, and chown all resolve the final
# component of their argument through whatever symlink is there; run inside ~/.ssh, which
# the operator owns and may empty at will, chown alone would hand the operator any file
# on this node it could name. Run inside STATE_ROOT there is nothing to name.
#
# The one step that touches a path the operator controls is the rename, and rename(2)
# resolves neither final component: a symlink planted at the destination is unlinked by
# the rename rather than written through, so the operator can destroy their own planted
# link and nothing else. That holds only for a true rename, which is why both renames are
# gated on harbor_ssh_assert_one_filesystem: mv degrades to copy-and-unlink across
# filesystems and a copy does follow the destination symlink. The directory is created
# the same way and for the same reason, staged and renamed rather than mkdir'd and then
# chowned in place, because ~/.ssh is itself an entry in a directory the operator owns
# and a chown of it is the same escalation as a chown of the key.
harbor_ssh_authorize() {
  local root operator home group ssh_dir target pre source src_state post tmp stage entry
  [ "$#" -ge 3 ] && [ "$#" -le 4 ] \
    || harbor_die 3 usage "usage: harbor_ssh_authorize <state-root> <operator> <operator-home> [source]"
  root="${1}"
  operator="${2}"
  home="${3}"
  group="$(id -gn "${operator}" 2>/dev/null)" \
    || harbor_die 3 ssh.no_operator "${operator} is not an account on this node, so its authorized key cannot be placed"
  # The staging root is the whole soundness argument above, so its absence is a
  # precondition rather than something to work around by staging somewhere weaker.
  [ -d "${root}" ] \
    || harbor_die 3 ssh.no_state_root "${root} is not a directory, and it is the only place Harbor will stage the mode and the owner of an authorized key, because it is the only directory on the path no unprivileged user can replace; nothing was written"
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
    harbor_ssh_assert_one_filesystem "${root}" "${home}" "${ssh_dir}"
    stage="${root}/.tmp.ssh.${HARBOR_LOCK_ID_PID:-$$}"
    rm -rf "${stage}"
    mkdir "${stage}" \
      || harbor_die 2 ssh.ssh_dir_stage "cannot create ${stage}, where ${ssh_dir} is staged; ${ssh_dir} does not exist and nothing was written"
    chmod 0700 "${stage}" \
      || harbor_die 2 ssh.ssh_dir_stage "cannot give ${stage} mode 0700; ${ssh_dir} does not exist and nothing was written"
    chown "${operator}:${group}" "${stage}" \
      || harbor_die 2 ssh.ssh_dir_chown "cannot give ${stage} to ${operator}:${group}; ${ssh_dir} does not exist and nothing was written"
    if ! mv "${stage}" "${ssh_dir}"; then
      rm -rf "${stage}"
      harbor_die 2 ssh.ssh_dir_create "cannot create ${ssh_dir} by renaming ${stage} onto it; nothing was written"
    fi
    harbor_log ssh "created ${ssh_dir} 0700 for ${operator}"
  fi
  pre="$(harbor_observe_file "${target}")"
  case "${pre}" in
    '"absent"') ;;
    '{"sha256":'*)
      # A file is not a key. harbor_ssh_configure writes the drop-in that takes password
      # and keyboard-interactive authentication away from this one account, and the row
      # order of design section 5.2 puts the key before the drop-in so that no ordering
      # of the two can leave the operator with no way in. Ordering does not save an
      # account whose authorized_keys is empty or is nothing but comments, so an existing
      # file is accepted only once it is proved to hold a line sshd would read as a key.
      # Harbor changes nothing it cannot prove it created, so the file is named for the
      # administrator rather than silently overwritten.
      harbor_ssh_has_usable_key "${target}" \
        || harbor_die 3 ssh.target_no_key "${target} is already there and holds no usable authorized-key line (it is empty, or every line in it is blank or a comment), so ${operator} has no key to log in with. Harbor will not disable password authentication for an account that would then have no way in, and it overwrites nothing it cannot prove it created: add ${operator}'s public key to ${target}, or remove ${target} and rerun to have Harbor copy one in; nothing was written"
      harbor_journal_create "${root}" authorized-key "${target}" observed applied "${pre}" "${pre}"
      harbor_log ssh "${target} is already there; leaving it exactly as it is"
      harbor_msg "${operator} already has ${target}; it was recorded and left untouched"
      return 0
      ;;
    *)
      harbor_die 3 ssh.target_foreign "${target} is already there and is not a regular file; Harbor removes nothing it cannot prove it created: inspect it, remove it by hand if it is not needed, and rerun"
      ;;
  esac
  # Before the first journal entry of the copy, so a node whose partitioning makes the
  # sound mechanism impossible is refused having written nothing and recorded nothing.
  harbor_ssh_assert_one_filesystem "${root}" "${ssh_dir}" "${target}"
  source="$(harbor_ssh_source "${4:-}")" || exit "$?"
  src_state="$(harbor_observe_file "${source}")"
  harbor_journal_create "${root}" authorized-key-source "${source}" observed applied "${src_state}" "${src_state}"
  tmp="${root}/.tmp.authorized_keys.${HARBOR_LOCK_ID_PID:-$$}"
  rm -f "${tmp}"
  cp "${source}" "${tmp}" \
    || harbor_die 2 ssh.copy "copying ${source} to ${tmp} failed; ${target} is unchanged"
  chmod 0600 "${tmp}" \
    || harbor_die 2 ssh.mode "cannot give ${tmp} mode 0600; ${target} is unchanged"
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
# The operator-scoped sshd drop-in of design section 3.5 and the SSH row of section
# 5.2, the global --harden-sshd drop-in beside it, and the assertions that prove both.
# The destination configuration root is a parameter defaulting to the production /etc,
# exactly as lib/power.sh takes the root of its logind drop-in, so a unit test writes
# inside its own fixture root and no unit test can reach /etc. Each drop-in is one
# journaled file transaction of design section 3.7: a temporary file, a rename, and
# both states rendered by harbor_observe_file, which is what harbor_journal_observe
# hands a file entry, so an entry left prepared by a crash between the rename and the
# applied write is decidable by recovery. sshd and systemctl are asked through the
# PATH, which is the seam the unit lane substitutes.
HARBOR_SSH_UNIT="ssh.service"
# harbor_ssh_dropin_path [DEST_ROOT] and harbor_ssh_global_dropin_path [DEST_ROOT]: the
# two drop-ins of design section 3.5 under the configuration root DEST_ROOT, which
# defaults to the production /etc. They are separate files with separate journal
# entries because --harden-sshd is removable on its own with
# harbor teardown --unharden-sshd, which can only be true of a file of its own.
harbor_ssh_dropin_path() {
  printf '%s/ssh/sshd_config.d/50-harbor-operator.conf' "${1:-/etc}"
}
harbor_ssh_global_dropin_path() {
  printf '%s/ssh/sshd_config.d/51-harbor-global.conf' "${1:-/etc}"
}
# harbor_ssh_operator_render OPERATOR: the operator drop-in. One Match block naming one
# account, holding only the three authentication keywords of design section 3.5, and no
# keyword that changes who may log in. Byte-stable, so a rerun observes the same sha256
# and rewrites nothing.
#
# The Match block is the whole file and ends with it. OpenSSH's Include saves the
# including file's match state and restores it after the included file is parsed
# (servconf.c, "Don't let included files clobber the containing file's Match state"), so
# this block scopes to this file alone and nothing in /etc/ssh/sshd_config after the
# Include line becomes conditional on it. That is what lets the drop-in be a Match block
# at all: a block that leaked would put the rest of the distribution's own configuration
# inside it, where keywords like UsePAM and Subsystem are not permitted, and sshd -t
# would refuse the whole configuration.
harbor_ssh_operator_render() {
  printf '# Managed by Harbor: public-key-only authentication for one account.\n'
  printf '# It is scoped to that account and adds no keyword that decides who may log in.\n'
  printf '# Remove this file and reload %s to restore the system default for it.\n' "${HARBOR_SSH_UNIT}"
  printf 'Match User %s\n' "${1}"
  printf '  PubkeyAuthentication yes\n'
  printf '  PasswordAuthentication no\n'
  printf '  KbdInteractiveAuthentication no\n'
}
# harbor_ssh_global_render: the --harden-sshd drop-in of design section 3.5. It is
# global by intent, which is why it is opt-in, journaled on its own, and refused unless
# the installation user has an authorized key.
harbor_ssh_global_render() {
  printf '# Managed by Harbor: global SSH hardening, written only for --harden-sshd.\n'
  printf '# Remove it with: harbor teardown --unharden-sshd.\n'
  printf 'PermitRootLogin no\n'
  printf 'PasswordAuthentication no\n'
}
# harbor_ssh_check_user_name NAME ROLE: refuse a name that could not be written into a
# configuration file as one word. The operator name reaches both the drop-in and an
# sshd -C argument, so a name carrying a newline, a space, or a shell or glob character
# is refused before anything is written rather than rendered into a file where it would
# be a second directive.
harbor_ssh_check_user_name() {
  case "${1}" in
    "" | -* | *[!A-Za-z0-9._-]*)
      harbor_die 3 ssh.user_name "the ${2} name '${1}' is not a portable account name (letters, digits, dot, underscore, and hyphen, not leading with a hyphen); Harbor will not write it into an sshd configuration file; nothing was written"
      ;;
  esac
}
# harbor_sshd_effective USER SITUATION: the effective configuration sshd reports for
# USER, normalized by sorting so that the comparison below is over the set of
# directives and not over the order sshd happens to print them in. Inspection only. A
# non-zero exit is fail-closed, exit 2, naming SITUATION, the state the node is in at
# that point, because a configuration that cannot be read cannot be proved unchanged.
harbor_sshd_effective() {
  local user="${1}" situation="${2}" out rc=0
  harbor_log_vendor sshd -T -C "user=${user}"
  out="$(sshd -T -C "user=${user}" 2>&1)" || rc="$?"
  [ "${rc}" = 0 ] \
    || harbor_die 2 ssh.effective "sshd -T -C user=${user} failed (exit ${rc}): ${out}; ${situation}"
  # An empty answer would make every comparison below trivially true, so it is refused
  # rather than read as "the configuration is unchanged".
  [ -n "${out}" ] \
    || harbor_die 2 ssh.effective "sshd -T -C user=${user} exited 0 and printed no configuration at all, so nothing can be proved about it; ${situation}"
  printf '%s\n' "${out}" | LC_ALL=C sort
}
# harbor_ssh_config_diff BEFORE AFTER: every directive the two normalized outputs do not
# share, one per line, "-" for one only BEFORE holds and "+" for one only AFTER holds.
# Used only to say exactly what changed when the proof below fails.
harbor_ssh_config_diff() {
  local before="${1}" after="${2}" line
  printf '%s\n' "${before}" | while IFS= read -r line; do
    [ -n "${line}" ] || continue
    printf '%s\n' "${after}" | grep -qxF -- "${line}" || printf -- '  -%s\n' "${line}"
  done
  printf '%s\n' "${after}" | while IFS= read -r line; do
    [ -n "${line}" ] || continue
    printf '%s\n' "${before}" | grep -qxF -- "${line}" || printf -- '  +%s\n' "${line}"
  done
}
# harbor_sshd_test SITUATION: sshd's own syntax check. A configuration sshd refuses is
# exit 2 naming SITUATION, and nothing is reloaded after it, so the running sshd keeps
# the configuration it has rather than being told to read one sshd has just refused.
harbor_sshd_test() {
  local out rc=0
  harbor_log_vendor sshd -t
  out="$(sshd -t 2>&1)" || rc="$?"
  [ "${rc}" = 0 ] \
    || harbor_die 2 ssh.syntax "sshd -t refuses the configuration (exit ${rc}): ${out}; nothing was reloaded, so the running sshd still has the configuration it had before; ${1}"
}
# harbor_ssh_service_state: the activation state systemctl reports for the ssh unit, one
# word. The decision is made on the word printed, never on the exit status, because
# systemctl is-active exits non-zero for every state that is not active, inactive among
# them, and inactive is the ordinary state of a socket-activated sshd. A word outside
# the vocabulary, which is what an unreachable manager prints, is fail-closed: exit 2,
# nothing reloaded.
harbor_ssh_service_state() {
  local out rc=0
  out="$(systemctl is-active "${HARBOR_SSH_UNIT}" 2>&1)" || rc="$?"
  out="$(printf '%s\n' "${out}" | sed -n 1p)"
  case "${out}" in
    active | reloading | activating | deactivating | inactive | failed)
      printf '%s' "${out}"
      ;;
    *)
      harbor_die 2 ssh.service_state "systemctl is-active ${HARBOR_SSH_UNIT} printed '${out}' (exit ${rc}), which is not a unit activation state; nothing was reloaded"
      ;;
  esac
}
# harbor_ssh_reload: tell the running sshd to read the drop-in. Nothing is journaled: a
# reload leaves no artifact to own or invert. A unit that is not running is not reloaded
# and is not a failure, because Ubuntu 24.04 activates sshd from a socket by default and
# a socket-activated sshd reads the configuration afresh for every connection; that is
# reported rather than guessed at.
harbor_ssh_reload() {
  local state out rc=0
  state="$(harbor_ssh_service_state)" || exit "$?"
  case "${state}" in
    active | reloading) ;;
    *)
      harbor_log ssh "${HARBOR_SSH_UNIT} is ${state}, so there is no running sshd to reload"
      harbor_msg "${HARBOR_SSH_UNIT} is ${state}, so nothing was reloaded; the drop-in is read by the next connection"
      return 0
      ;;
  esac
  harbor_log_vendor systemctl reload "${HARBOR_SSH_UNIT}"
  out="$(systemctl reload "${HARBOR_SSH_UNIT}" 2>&1)" || rc="$?"
  [ "${rc}" = 0 ] \
    || harbor_die 2 ssh.reload "systemctl reload ${HARBOR_SSH_UNIT} failed (exit ${rc}): ${out}; the drop-in is in place and sshd -t accepts it, but the running sshd still has the configuration it had before, so fix the cause and rerun"
  harbor_step ssh-reloaded
}
# harbor_ssh_dropin_refuse_foreign PATH: anything at PATH that is not a regular file is
# foreign. Harbor removes nothing it cannot prove it created, so it exits 3 naming the
# path for manual inspection and touches nothing. Called before any vendor command, so
# a node in that state is refused without sshd being asked anything at all.
harbor_ssh_dropin_refuse_foreign() {
  case "$(harbor_observe_file "${1}")" in
    '"unobservable:'* | '{"symlink":'*)
      harbor_die 3 ssh.dropin_foreign "${1} is already there and is not a regular file; Harbor removes nothing it cannot prove it created: inspect it, remove it by hand if it is not needed, and rerun; nothing was written"
      ;;
  esac
}
# harbor_ssh_dropin_write STATE_ROOT PATH STEP RENDER [ARG]: one drop-in as one journaled
# file transaction. A drop-in already byte for byte what RENDER would write is journaled
# observed and left alone, which is what makes a rerun write nothing and reload nothing.
# Otherwise the entry is prepared before the rename, the rename is checked, and what
# landed is compared with the post_state the entry recorded; a failure at any of those
# leaves the entry prepared and says so. Sets HARBOR_SSH_DROPIN_CHANGED to 1 when the
# file was written and HARBOR_SSH_DROPIN_ENTRY to the entry still to be marked applied,
# which is empty when there was nothing to write.
harbor_ssh_dropin_write() {
  local root="${1}" path="${2}" step="${3}" render="${4}" arg="${5:-}"
  local dir pre post ownership tmp entry
  HARBOR_SSH_DROPIN_CHANGED=0
  HARBOR_SSH_DROPIN_ENTRY=""
  dir="$(dirname "${path}")"
  if [ ! -d "${dir}" ]; then
    mkdir -p "${dir}" \
      || harbor_die 2 ssh.dropin_dir "cannot create ${dir}; nothing was written and nothing was reloaded"
    chmod 0755 "${dir}" \
      || harbor_die 2 ssh.dropin_dir "cannot give ${dir} mode 0755; nothing was written and nothing was reloaded"
  fi
  harbor_ssh_dropin_refuse_foreign "${path}"
  pre="$(harbor_observe_file "${path}")"
  tmp="${dir}/.tmp.$(basename "${path}").${HARBOR_LOCK_ID_PID:-$$}"
  rm -f "${tmp}"
  if [ -n "${arg}" ]; then
    "${render}" "${arg}" >"${tmp}" \
      || harbor_die 2 ssh.dropin_stage "cannot stage ${tmp}; ${path} is unchanged and nothing was reloaded"
  else
    "${render}" >"${tmp}" \
      || harbor_die 2 ssh.dropin_stage "cannot stage ${tmp}; ${path} is unchanged and nothing was reloaded"
  fi
  chmod 0644 "${tmp}" \
    || harbor_die 2 ssh.dropin_stage "cannot give ${tmp} mode 0644; ${path} is unchanged and nothing was reloaded"
  post="$(harbor_observe_file "${tmp}")"
  if [ "${post}" = "${pre}" ]; then
    rm -f "${tmp}"
    harbor_journal_create "${root}" file "${path}" observed applied "${pre}" "${post}"
    harbor_log ssh "${path} is already byte for byte what Harbor writes; leaving it exactly as it is"
    return 0
  fi
  ownership=modified
  [ "${pre}" != '"absent"' ] || ownership=created
  harbor_journal_create "${root}" file "${path}" "${ownership}" prepared "${pre}" "${post}"
  entry="${HARBOR_JOURNAL_ENTRY}"
  harbor_journal_sync_path "${tmp}"
  if ! mv -f "${tmp}" "${path}"; then
    rm -f "${tmp}"
    harbor_die 2 ssh.dropin_rename "renaming ${tmp} onto ${path} failed; ${path} holds what it held before, nothing was reloaded, and $(basename "${entry}") stays prepared, rerun after fixing the cause"
  fi
  harbor_journal_sync_path "${dir}"
  harbor_step "${step}"
  [ "$(harbor_observe_file "${path}")" = "${post}" ] \
    || harbor_die 2 ssh.dropin_verify "${path} is not what was staged for it; nothing was reloaded and $(basename "${entry}") stays prepared"
  HARBOR_SSH_DROPIN_CHANGED=1
  HARBOR_SSH_DROPIN_ENTRY="${entry}"
}
# harbor_ssh_assert_operator OPERATOR SITUATION: the operator half of the design section
# 3.5 acceptance. sshd itself is asked what it would do for that account, and all three
# values harbor_ssh_operator_render writes must be the values it wrote; anything else
# means the drop-in did not take effect and is exit 2 with the node's state, before any
# reload.
#
# All three, not only the two the row turns off. OpenSSH keeps the first value it obtains
# for a keyword, Ubuntu's /etc/ssh/sshd_config begins with Include
# /etc/ssh/sshd_config.d/*.conf, and those files are read in lexical order, so a drop-in
# sorting before Harbor's, or a global PubkeyAuthentication no obtained ahead of this
# Match block, leaves the block's own value ignored. sshd -T -C user=OPERATOR then
# reports pubkey, password, and keyboard-interactive all no: asserting only the two no
# values would pass on exactly the node where the operator has been left with no way in
# at all, on an account whose drop-in says public-key-only authentication. The expected
# value therefore travels with each directive rather than being assumed to be no, and the
# refusal quotes what sshd actually reported for the directive that failed.
harbor_ssh_assert_operator() {
  local operator="${1}" situation="${2}" effective pair directive expected reported
  effective="$(harbor_sshd_effective "${operator}" "${situation}")" || exit "$?"
  for pair in pubkeyauthentication=yes passwordauthentication=no kbdinteractiveauthentication=no; do
    directive="${pair%%=*}"
    expected="${pair#*=}"
    if printf '%s\n' "${effective}" | grep -qxF -- "${directive} ${expected}"; then
      continue
    fi
    reported="$(printf '%s\n' "${effective}" | grep -- "^${directive} " | sed -n 1p || true)"
    [ -n "${reported}" ] || reported="no ${directive} line at all"
    harbor_die 2 ssh.operator_not_hardened "sshd -T -C user=${operator} does not report '${directive} ${expected}', it reports '${reported}', so the drop-in did not take effect for ${operator}; nothing was reloaded; ${situation}"
  done
}
# harbor_ssh_configure STATE_ROOT OPERATOR ADMIN [DEST_ROOT]: the SSH row of design
# section 5.2. Write the operator drop-in, run sshd's own syntax check, prove with sshd
# that the drop-in changed nothing at all for the installation user and that it did
# change both authentication settings for the operator, and only then reload.
#
# The proof is a comparison of two whole normalized sshd -T -C user=ADMIN outputs, one
# taken before the drop-in exists and one with it in place, not a check of a chosen
# subset: a drop-in that moved a directive nobody thought to name would fail it just as
# a directive that was named would. Because the earlier reading has to be of a node
# without the drop-in, it is taken before anything is written, and because the later one
# has to be of a node with it, it is taken after the rename and before the reload. A
# difference is exit 2 naming every directive that differs, with the drop-in still in
# place, its entry still prepared, and the running sshd still holding the configuration
# it had, which is the state the message reports.
#
# The baseline is a true with-versus-without reading in the two states that matter: a
# path that was absent, and a path already holding byte for byte what Harbor renders,
# where the file is provably Harbor's own bytes and the proof belongs to the run that
# created it. It is not one when a differing drop-in was already at the path, which is
# an upgrade from an older render: there the comparison is between two drop-ins rather
# than between having one and not, so a leak both of them share would not show. That is
# a property of two Harbor renders rather than of this node, and the renders are fixed
# strings the tests below read, so it is recorded here and left to the upgrade slice
# rather than papered over with a mutation taken before its entry exists.
harbor_ssh_configure() {
  local root operator admin dest path before after changed entry owed situation diff
  [ "$#" -ge 3 ] && [ "$#" -le 4 ] \
    || harbor_die 3 usage "usage: harbor_ssh_configure <state-root> <operator> <installation-user> [dest-root]"
  root="${1}"
  operator="${2}"
  admin="${3}"
  dest="${4:-}"
  harbor_ssh_check_user_name "${operator}" operator
  harbor_ssh_check_user_name "${admin}" "installation user"
  path="$(harbor_ssh_dropin_path "${dest}")"
  # A foreign file at the path is refused before sshd is asked anything, so a node in
  # that state is left exactly as it is.
  harbor_ssh_dropin_refuse_foreign "${path}"
  before="$(harbor_sshd_effective "${admin}" "nothing has been written and nothing has been reloaded")" || exit "$?"
  if [ -e "${path}" ]; then
    harbor_log ssh "${path} was already there before this run, so the reading above is of a node that already had a drop-in"
  fi
  harbor_ssh_dropin_write "${root}" "${path}" ssh-dropin-operator harbor_ssh_operator_render "${operator}"
  changed="${HARBOR_SSH_DROPIN_CHANGED}"
  entry="${HARBOR_SSH_DROPIN_ENTRY}"
  if [ "${changed}" = 1 ]; then
    situation="${path} is in place and $(basename "${entry}") stays prepared for recovery"
  else
    situation="${path} was already there byte for byte and was not rewritten"
  fi
  harbor_sshd_test "${situation}"
  after="$(harbor_sshd_effective "${admin}" "${situation}")" || exit "$?"
  if [ "${after}" != "${before}" ]; then
    diff="$(harbor_ssh_config_diff "${before}" "${after}")"
    harbor_die 2 ssh.admin_changed "the operator drop-in changes the effective sshd configuration of the installation user ${admin}, which it must leave untouched directive for directive; - is what sshd reported before it and + what sshd reports with it:
${diff}
nothing was reloaded, so the running sshd still has the configuration it had before; ${situation}; remove ${path} and rerun"
  fi
  harbor_ssh_assert_operator "${operator}" "${situation}"
  harbor_step ssh-dropin-applied
  harbor_log ssh "${path} leaves ${admin} unchanged for every directive and gives ${operator} public-key-only authentication"
  # What decides the reload is whether this drop-in's transaction has completed, not
  # whether this run happened to be the one that wrote the file. A run whose reload
  # failed exits 2 leaving its entry prepared, so the drop-in is on disk and the running
  # sshd is still holding the configuration it had; the next run finds the file byte for
  # byte what it renders and writes nothing, and would report a hardened node while sshd
  # had never read the file. The prepared entry is what that unfinished transaction left
  # behind, and it is what makes the reload still owed. The applied write comes after the
  # reload for the same reason: until sshd has read the file the transaction is not done.
  #
  # A rerun on a healthy node finds no such entry and returns here, before
  # harbor_ssh_reload asks systemctl anything, so it still makes no mutating call and no
  # vendor call about the unit at all.
  owed="${entry}"
  [ -n "${owed}" ] || owed="$(harbor_ssh_prepared_entry_for "${root}" "${path}")"
  if [ "${changed}" != 1 ] && [ -z "${owed}" ]; then
    return 0
  fi
  harbor_ssh_reload
  [ -z "${owed}" ] || harbor_journal_set_phase "${owed}" applied
  if [ "${changed}" = 1 ]; then
    harbor_msg "wrote ${path} and reloaded ${HARBOR_SSH_UNIT}"
  else
    harbor_msg "${path} was already in place but its transaction had not completed, so ${HARBOR_SSH_UNIT} was reloaded"
  fi
}
# harbor_ssh_admin_authorized_keys ADMIN: the installation user's own authorized_keys,
# printed on stdout, or exit 3. This is the refusal --harden-sshd is gated on: the global
# drop-in takes away password authentication for every account and root's login with it,
# so an installation user with no key of their own would be left with no way back into
# the node. The file must exist, be a regular file, be readable, and hold a key, the same
# test harbor_ssh_source applies to the key it copies, and it is asked of the installation
# user's own account whatever --authorized-key-file said, because it is that account the
# flag could lock out.
#
# "The same test" is literally the same predicate, harbor_ssh_has_usable_key, and not a
# second spelling of it. This is the one refusal standing between --harden-sshd and an
# unreachable node: the flag takes password authentication away from every account and
# root's login with it, and the account it would strand is the administrator running the
# command over SSH at that moment. Asking [ -s PATH ] here meant that a file holding a
# single newline, or a single line reading '# my key is elsewhere', satisfied the check
# that exists precisely to prove a key is there.
harbor_ssh_admin_authorized_keys() {
  local admin="${1}" home path
  [ "${admin}" != root ] \
    || harbor_die 3 ssh.harden_no_key "--harden-sshd sets PermitRootLogin no, so root is not the installation user it can be given to; rerun through sudo from your own account, or drop --harden-sshd; nothing was written"
  home="$(harbor_ssh_user_home "${admin}")" || exit "$?"
  path="${home}/.ssh/authorized_keys"
  { [ -f "${path}" ] && [ -r "${path}" ] && harbor_ssh_has_usable_key "${path}"; } \
    || harbor_die 3 ssh.harden_no_key "--harden-sshd sets PermitRootLogin no and PasswordAuthentication no for every account, and ${path} is missing, unreadable, or holds no usable authorized-key line (it is empty, or every line in it is blank or a comment), so ${admin} would have no way left to log in to this node; add ${admin}'s own public key to that file and rerun, or rerun without --harden-sshd; nothing was written"
  printf '%s' "${path}"
}
# harbor_ssh_harden STATE_ROOT ADMIN [DEST_ROOT]: the --harden-sshd drop-in of design
# section 3.5, a file of its own with a journal entry of its own so that
# harbor teardown --unharden-sshd can remove it and nothing else. The refusal above runs
# before anything is written or any vendor command is called. sshd's syntax check runs
# after the write and a refusal reloads nothing, exactly as for the operator drop-in;
# the unchanged-for-every-directive proof does not apply here, because changing the
# effective configuration of every account, the installation user included, is what this
# flag is, and what protects that account is the authorized-key refusal instead.
harbor_ssh_harden() {
  local root admin dest path key changed entry situation owed
  [ "$#" -ge 2 ] && [ "$#" -le 3 ] \
    || harbor_die 3 usage "usage: harbor_ssh_harden <state-root> <installation-user> [dest-root]"
  root="${1}"
  admin="${2}"
  dest="${3:-}"
  harbor_ssh_check_user_name "${admin}" "installation user"
  key="$(harbor_ssh_admin_authorized_keys "${admin}")" || exit "$?"
  path="$(harbor_ssh_global_dropin_path "${dest}")"
  harbor_ssh_dropin_refuse_foreign "${path}"
  harbor_log ssh "--harden-sshd: ${admin} has an authorized key in ${key}"
  harbor_ssh_dropin_write "${root}" "${path}" ssh-dropin-global harbor_ssh_global_render
  changed="${HARBOR_SSH_DROPIN_CHANGED}"
  entry="${HARBOR_SSH_DROPIN_ENTRY}"
  if [ "${changed}" = 1 ]; then
    situation="${path} is in place and $(basename "${entry}") stays prepared for recovery"
  else
    situation="${path} was already there byte for byte and was not rewritten"
  fi
  harbor_sshd_test "${situation}"
  harbor_step ssh-global-applied
  # The same unfinished transaction the operator drop-in above guards against, and for a
  # sharper reason: this file is what takes password authentication away from every
  # account on the node. A run that wrote it and then failed to reload left sshd holding
  # the configuration it had, and a rerun that finds the file byte for byte what it
  # renders would otherwise write nothing, reload nothing, and report a hardened node
  # sshd had never read. So the reload is owed while the transaction is unfinished, and
  # the applied write comes after it rather than before.
  owed="${entry}"
  [ -n "${owed}" ] || owed="$(harbor_ssh_prepared_entry_for "${root}" "${path}")"
  if [ "${changed}" != 1 ] && [ -z "${owed}" ]; then
    return 0
  fi
  harbor_ssh_reload
  [ -z "${owed}" ] || harbor_journal_set_phase "${owed}" applied
  if [ "${changed}" = 1 ]; then
    harbor_msg "--harden-sshd wrote ${path}; remove it with: harbor teardown --unharden-sshd"
  else
    harbor_msg "${path} was already in place but its transaction had not completed, so ${HARBOR_SSH_UNIT} was reloaded"
  fi
}
