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
# The rule is sshd's shape, one step tighter than sshd's own parser. sshd skips leading
# blanks and then ignores a line that is empty or whose first non-blank character is '#'
# (auth2-pubkey.c), so comments and blank lines are dropped first and exactly as sshd
# drops them. What is left must then look like a key rather than merely be text: a key
# type token, then whitespace, then a non-empty field. Treating whatever was not a comment
# as a key is what this asked before, and it approved a file reading 'my key is on the
# other laptop' and went on to take password authentication away from that account.
#
# The token is matched anywhere on the line and never anchored to its start. An
# authorized_keys line may carry options ahead of the type, so
# restrict,from="10.0.0.0/8" ssh-ed25519 AAAA... is a key and an anchored test would
# reject it: refusing a real key is a lockout of its own kind, the administrator denied a
# flag they should have had. The certificate types are named beside the plain ones for the
# same reason, a -cert-v01@openssh.com line being a key sshd reads.
#
# Comments are stripped before the token is looked for rather than after, because
# '# ssh-ed25519 AAAA...' is a commented-out key and carries a token a single pass over
# the whole file would match.
#
# One residual is accepted knowingly: prose that happens to carry a type token followed by
# another word, 'prefer ssh-ed25519 over ssh-rsa', still counts as a key. Closing it means
# demanding the base64 body of the key, and the paragraph below is why that is not asked.
#
# Text rather than ssh-keygen -l -f, which would be OpenSSH's own answer: the unit lane's
# fixture keys are the deliberately unreal placeholder strings of design section 3.8, so
# ssh-keygen would refuse every one of them, and answering it instead would mean a shim
# under tests/shims/. Inspection only, and stderr is discarded because an unreadable file
# is a separate refusal each caller makes before this one.
#
# A here-string rather than a second pipeline stage: bin/harbor sets pipefail, and grep -q
# stops at its first match, which hands the upstream grep a SIGPIPE and would fail the
# pipeline on exactly the files that do hold a key.
harbor_ssh_has_usable_key() {
  local body
  body="$(grep -v -e '^[[:space:]]*#' -- "${1}" 2>/dev/null || true)"
  [ -n "${body}" ] || return 1
  grep -Eq -e '(^|[[:space:]])(ssh-(rsa|dss|ed25519)(-cert-v01@openssh\.com)?|ecdsa-sha2-nistp(256|384|521)(-cert-v01@openssh\.com)?|sk-(ssh-ed25519|ecdsa-sha2-nistp256)(-cert-v01)?@openssh\.com)[[:space:]]+[^[:space:]]+' <<<"${body}"
}
# harbor_ssh_path_id PATH: the filesystem identity of PATH, its device and inode, printed
# as device:inode. Two names print the same value exactly when they name the same file,
# which a path by itself never settles: a check written as a path is re-resolved through
# whatever the directories above it are at the instant it runs, so a check and the thing
# it was meant to be about can be two different files. Inspection only. A path that cannot
# be stat'ed prints nothing rather than failing, so a caller comparing two of these reads
# a mismatch, which is the answer it wanted, instead of an error it would have to handle.
harbor_ssh_path_id() {
  case "$(harbor_os)" in
    Linux) stat -c '%d:%i' "${1}" 2>/dev/null || true ;;
    Darwin) stat -f '%d:%i' "${1}" 2>/dev/null || true ;;
  esac
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
# place. It is accepted only once it is proved to be a file sshd would actually read,
# which is a question about its owner and its mode as much as about its content: the
# branch itself says why. Otherwise the source of harbor_ssh_source is staged in a
# root-owned 0700 directory of its own, chmod 0600 and chowned to OPERATOR while it is
# still somewhere the operator cannot reach at all, journaled prepared,
# renamed into place in one step, and verified: owned by OPERATOR, mode 0600, inside a
# 0700 .ssh owned by OPERATOR. Only a .ssh Harbor creates is created 0700; one that is already there and
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
# 0755 is traversable, though, and a chown gives a file away to an account that may then
# reach it through that traversal, so the key itself is staged one level further down, in a
# 0700 root-owned directory of its own that no unprivileged user may enter. The write below
# says what that closes.
#
# The one step that touches a path the operator controls is the rename, and it takes two
# separate arguments to be sound. rename(2) does not resolve its final component, so a
# symlink planted at the destination is unlinked by the rename rather than written
# through, and the operator can destroy its own planted link and nothing else. That much
# holds only for a true rename, which is why both renames are gated on
# harbor_ssh_assert_one_filesystem: mv degrades to copy-and-unlink across filesystems and
# a copy does follow the destination symlink.
#
# rename(2) does resolve every component above the last, though, and ~ is the operator's,
# so the final component being safe says nothing about ~/.ssh. An operator that replaces
# ~/.ssh with a symlink after the checks above have passed redirects the key into whatever
# that link names, and the checks cannot catch it by looking again, because looking again
# is another path resolution and resolves to the new thing too. The rename below therefore
# runs from inside ~/.ssh onto a relative name, a working directory being a held handle to
# a directory rather than a name that is resolved afresh, and the file that lands is proved
# by device and inode rather than by its path. Everything that has to be true of that
# directory is proved from inside the pin, about the directory that was entered, and
# nothing read by path outside the pin is carried into it: a reading taken outside is
# taken through whatever ~/.ssh resolves to at that instant, which is the operator's to
# choose. StrictModes, which harbor_ssh_assert_operator requires, is the backstop
# underneath all of it: sshd ignores an authorized_keys owned by neither root nor the
# account logging in.
#
# The directory is created the same way and for the same reason, staged and renamed rather
# than mkdir'd and then chowned in place, because ~/.ssh is itself an entry in a directory
# the operator owns and a chown of it is the same escalation as a chown of the key. That
# rename needs no pinning: the component above it is ~ itself, which sits in a root-owned
# /home the operator cannot rename or replace.
harbor_ssh_authorize() {
  local root operator home group ssh_dir target pre source src_state post tmp stage entry
  local key_stage staged_sha staged_id rename_rc verify_rc target_owner target_mode
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
  # The boundary at which ~/.ssh is settled: it is there, it is a directory and not a
  # symlink, it is 0700, and it is the operator's.
  #
  # Settled, and not carried forward as a value. The device and inode of ${ssh_dir} were
  # read here, by path, so that the rename below could hold the directory it was standing in
  # against them. That reading is a fresh path resolution of its own, taken after the checks
  # above and through a ~ the operator owns, so it is about whatever ~/.ssh is at this
  # instant rather than about the directory those checks passed on: an operator with a
  # process on this node can re-point the name in the window between the two, and a value
  # read here would then be the one the rename trusted. What kept that from being an opening
  # was one property nothing here stated: harbor_ssh_path_id reads with lstat, so a name
  # re-pointed at a decoy read as the link itself and could never equal the identity of a
  # directory that had been entered. A check made in one place about a name resolved in
  # another, standing only on the default of stat(1), is not an argument this file should be
  # resting the operator's way into the node on.
  #
  # So nothing about the directory is read by path here at all. Every fact the write depends
  # on is proved inside the pin below, about the directory that has been entered, at the
  # moment it is used, and holds however stat(1) treats a link.
  harbor_step ssh-dir-checked
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
      # And a key is not a key sshd will read. StrictModes, which harbor_ssh_assert_operator
      # requires of this node, makes sshd refuse an authorized_keys that is owned by neither
      # root nor the account logging in, and refuse one that is group- or world-writable,
      # whatever key it holds. A pre-existing file carrying a perfectly good key that sshd
      # will not read strands the operator exactly as a file carrying no key does: the row
      # below takes password and keyboard-interactive authentication away from an account
      # sshd will not let in by key either, and content alone cannot tell the two apart. The
      # check became owed the moment StrictModes stopped being a default sshd happens to have
      # and became something Harbor asserts of this node and rests on.
      #
      # Both properties are refusals rather than repairs. Harbor changes nothing it did not
      # create, and a chmod or a chown here would be Harbor deciding that a file it found is
      # its own; the administrator is told which property failed and what sshd does about it.
      target_owner="$(harbor_stat_owner "${target}")"
      { [ "${target_owner}" = "${operator}" ] || [ "${target_owner}" = root ]; } \
        || harbor_die 3 ssh.target_unusable "${target} is already there and is owned by ${target_owner}, which is neither ${operator} nor root, so sshd ignores it: StrictModes reads an authorized_keys only when it belongs to root or to the account logging in. ${operator} would have no key sshd will read, and the sshd row would take password and keyboard-interactive authentication away from it anyway. Harbor changes nothing it did not create: give ${target} to ${operator} by hand, or remove it and rerun to have Harbor copy a key in; nothing was written"
      # The mode test is group- and world-writability, which is what StrictModes tests, and
      # not equality with 0600. 0644 and 0640 are modes sshd reads happily and are an
      # administrator's own choice; refusing them would be Harbor refusing a node it has
      # nothing to complain about, which is a lockout of its own kind. harbor_stat_mode
      # prints four octal digits, so the last is the world's and the one before it the
      # group's, and a digit of 2, 3, 6, or 7 carries the write bit.
      target_mode="$(harbor_stat_mode "${target}")"
      case "${target_mode}" in
        *[2367])
          harbor_die 3 ssh.target_unusable "${target} is already there and is mode ${target_mode}, which is world-writable, so sshd ignores it: StrictModes refuses an authorized_keys any account on this node could add a key to. ${operator} would have no key sshd will read, and the sshd row would take password and keyboard-interactive authentication away from it anyway. Harbor changes nothing it did not create: narrow the mode of ${target} by hand, or remove it and rerun to have Harbor copy a key in; nothing was written"
          ;;
        *[2367][0-7])
          harbor_die 3 ssh.target_unusable "${target} is already there and is mode ${target_mode}, which is group-writable, so sshd ignores it: StrictModes refuses an authorized_keys every member of its group could add a key to. ${operator} would have no key sshd will read, and the sshd row would take password and keyboard-interactive authentication away from it anyway. Harbor changes nothing it did not create: narrow the mode of ${target} by hand, or remove it and rerun to have Harbor copy a key in; nothing was written"
          ;;
      esac
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
  # The key is staged inside a directory of its own, created 0700 and left root-owned, and
  # that directory is the whole reason the chown below opens no window. STATE_ROOT is 0755,
  # so every unprivileged user on this node may traverse it and read the names in it; the
  # staged key used to lie directly in it, and the chown that gives the file to OPERATOR
  # made it, from that instant, a file the operator could both name and write. Everything
  # between that chown and the rename was then a read of a file the operator was free to
  # rewrite between one read and the next, and post_state is what those reads decide: the
  # journal's record of the key, and the value the verification after the rename compares
  # what landed against. Both would have agreed on bytes the operator supplied.
  #
  # A 0700 root-owned directory is not a narrower window, it is no window. Reaching a file
  # requires search permission on every directory above it, and the operator has none on
  # this one, so no name it can construct resolves to the staged key: it cannot open it,
  # cannot link it, cannot rename it, and owning it grants none of those, ownership being a
  # property of the file rather than a way to reach one. Nothing can be planted at the path
  # first either, because only root may create an entry in the 0755 root-owned STATE_ROOT.
  # So the file carries its final mode and owner while it is still somewhere only root can
  # touch it, and it is already the operator's when it lands: nothing is chowned after the
  # rename, and there is no instant at which the file at ${target} is owned by anyone but
  # OPERATOR. That is what keeps the entry below decidable. Its post_state is the state the
  # file has when it lands and the state it keeps, so a crash anywhere after the rename
  # leaves recovery a target that equals post_state exactly, and a crash before it leaves
  # one that equals pre_state exactly; a shape that renamed a root-owned file into place and
  # chowned it afterwards would leave, for the width of that chown, a file matching neither.
  key_stage="${root}/.tmp.key.${HARBOR_LOCK_ID_PID:-$$}"
  tmp="${key_stage}/authorized_keys"
  rm -rf "${key_stage}"
  mkdir "${key_stage}" \
    || harbor_die 2 ssh.key_stage "cannot create ${key_stage}, the only directory Harbor will stage an authorized key in; ${target} is unchanged"
  chmod 0700 "${key_stage}" \
    || harbor_die 2 ssh.key_stage "cannot give ${key_stage} mode 0700, and it is that mode that keeps ${operator} from reaching the key staged in it; ${target} is unchanged"
  cp "${source}" "${tmp}" \
    || harbor_die 2 ssh.copy "copying ${source} to ${tmp} failed; ${target} is unchanged"
  chmod 0600 "${tmp}" \
    || harbor_die 2 ssh.mode "cannot give ${tmp} mode 0600; ${target} is unchanged"
  # The content is fixed before the chown and the file is observed once afterwards, and the
  # comparison is of that one observation rather than of a second reading of the file. What
  # is checked has to be what is used: two reads, one to check and one to record, are two
  # answers about a file at two instants, and only the second of them reaches the journal.
  # So ${post} is read exactly once, everything downstream is that value, and the check is
  # made about it. Mode and owner are read here rather than earlier because the chown is
  # what sets them.
  staged_sha="$(harbor_sha256 "${tmp}")"
  chown "${operator}:${group}" "${tmp}" \
    || harbor_die 2 ssh.chown "cannot give ${tmp} to ${operator}:${group}; ${target} is unchanged"
  harbor_step ssh-key-staged
  post="$(harbor_observe_file "${tmp}")"
  case "${post}" in
    "{\"sha256\":\"${staged_sha}\","*) ;;
    *)
      harbor_die 2 ssh.stage_changed "the contents of ${tmp} changed between being staged and being journaled, so what is there is no longer the key read from ${source} and nothing else about it can be trusted either; ${target} is unchanged"
      ;;
  esac
  harbor_journal_create "${root}" authorized-key "${target}" created prepared "${pre}" "${post}"
  entry="${HARBOR_JOURNAL_ENTRY}"
  harbor_step ssh-key-prepared
  harbor_journal_sync_path "${tmp}"
  staged_id="$(harbor_ssh_path_id "${tmp}")"
  # The rename runs from inside ~/.ssh, onto a relative name, rather than onto the full
  # path. rename(2) resolves the directories above its destination at the instant it runs,
  # and ~ is the operator's, so between the checks above and this line the operator can
  # replace ~/.ssh with a symlink and have root write the key through it into a directory
  # of the operator's choosing. A working directory is a held handle to a directory rather
  # than a name for one: once this subshell is inside ~/.ssh, the operator can re-point the
  # name ~/.ssh wherever it likes and '.' still refers to the directory that was entered.
  #
  # So the whole proof is made here, about '.', and nothing is brought in from a reading
  # taken by path outside this subshell. Three facts, in this order:
  #   the name ${ssh_dir} is not a symlink;
  #   the name ${ssh_dir} reaches the very directory this subshell entered;
  #   that directory is owned by ${operator} and is mode 0700.
  # If a name that is not a symlink reaches the pinned directory, then the pinned directory
  # is ~/.ssh at that moment, and the key goes into the held handle, so nothing done to the
  # name afterwards can redirect it. An operator that pinned a decoy and then put the real
  # directory back under the name fails the identity comparison, because the name and '.'
  # then disagree. An operator that made its decoy genuinely be ~/.ssh, by moving it there
  # rather than by pointing a link at it, has an ~/.ssh that is the decoy, and a key written
  # into it is a key written into the operator's own ~/.ssh, which is what was asked for.
  #
  # Identity, not only owner and mode. The operator owns its home and may own other 0700
  # directories under it, so a name pointed at one of those satisfies both of those checks
  # while the key lands somewhere the operator picked: the operator would then have no key
  # where sshd looks for one, and the row below would take password authentication away
  # from it anyway. Two names are the same directory exactly when their device and inode
  # agree, which is what harbor_ssh_path_id answers and what no unprivileged user can forge.
  rename_rc=0
  (
    cd "${ssh_dir}" 2>/dev/null || exit 1
    [ ! -L "${ssh_dir}" ] || exit 4
    [ "$(harbor_ssh_path_id "${ssh_dir}")" = "$(harbor_ssh_path_id .)" ] || exit 4
    [ "$(harbor_stat_owner .)" = "${operator}" ] || exit 2
    [ "$(harbor_stat_mode .)" = 0700 ] || exit 2
    mv -f "${tmp}" ./authorized_keys || exit 3
  ) || rename_rc="$?"
  if [ "${rename_rc}" != 0 ]; then
    rm -rf "${key_stage}"
    case "${rename_rc}" in
      2)
        harbor_die 2 ssh.ssh_dir_swapped "the directory ${ssh_dir} reached when the authorized key was about to be written is not a 0700 directory owned by ${operator}, though the directory of that name was one a moment ago, so the key was not written: something replaced it while ${operator} was being set up. Nothing was written, $(basename "${entry}") stays prepared, and this node should be inspected before rerunning"
        ;;
      4)
        harbor_die 2 ssh.ssh_dir_swapped "${ssh_dir} is no longer the same directory that was checked a moment ago: the name is a symlink now, or it reaches $(harbor_ssh_path_id "${ssh_dir}") rather than the directory this rename had entered and was holding open. The authorized key was not written, $(basename "${entry}") stays prepared, and this node should be inspected before rerunning"
        ;;
      1)
        harbor_die 2 ssh.rename "${ssh_dir} could not be entered, so the authorized key was not renamed into it; ${target} holds what it held before and $(basename "${entry}") stays prepared, rerun after fixing the cause"
        ;;
      *)
        harbor_die 2 ssh.rename "renaming ${tmp} onto ${target} failed; ${target} holds what it held before and $(basename "${entry}") stays prepared, rerun after fixing the cause"
        ;;
    esac
  fi
  # The rename emptied the staging directory, so nothing of this transaction is left in the
  # state root for a later run to find and reason about.
  rm -rf "${key_stage}"
  harbor_journal_sync_path "${ssh_dir}"
  harbor_step ssh-key-copied
  # What has to be proved now is about the file sshd will read at ${target}, and ${target}
  # is a path: resolved afresh at every check, through a ~/.ssh the operator can re-point
  # again now that the rename has returned. So the reading is pinned exactly as the write
  # was, and for the same reason, and the checks are made through '.' rather than through a
  # name that is resolved once per check.
  #
  # Identity before content, and both of them read through the pin, because neither settles
  # anything alone. Bytes, mode, and owner are all things the operator can produce for
  # itself: ~/.ssh is the operator's, so it may write whatever it likes at
  # ./authorized_keys, copy the key it was given, and mode it 0600, and a check of content
  # and mode and owner would pass on that file as readily as on the one root staged. What
  # it cannot produce is that file's device and inode, which no unprivileged user can
  # forge; and it cannot carry the staged file's own identity to a name of its choosing
  # either, a hard link needing a path to the file it links and the staging directory
  # granting the operator none. rename(2) keeps device and inode, so the file in the pinned
  # directory is the staged file exactly when they agree. An empty staged_id fails here
  # too, an unreadable staging file being no proof. Content is still compared after
  # identity, because identity says which file this is and post_state is what the journal
  # promised about it. The directory's own mode and owner are read again at the end because
  # the operator owns it and may widen it after the key has landed in it.
  verify_rc=0
  (
    cd "${ssh_dir}" 2>/dev/null || exit 1
    [ ! -L "${ssh_dir}" ] || exit 1
    [ "$(harbor_ssh_path_id "${ssh_dir}")" = "$(harbor_ssh_path_id .)" ] || exit 1
    [ -n "${staged_id}" ] || exit 2
    [ "$(harbor_ssh_path_id ./authorized_keys)" = "${staged_id}" ] || exit 2
    [ "$(harbor_observe_file ./authorized_keys)" = "${post}" ] || exit 3
    [ "$(harbor_stat_mode ./authorized_keys)" = 0600 ] || exit 4
    [ "$(harbor_stat_owner ./authorized_keys)" = "${operator}" ] || exit 5
    [ "$(harbor_stat_mode .)" = 0700 ] || exit 6
    [ "$(harbor_stat_owner .)" = "${operator}" ] || exit 6
  ) || verify_rc="$?"
  case "${verify_rc}" in
    0) ;;
    1)
      harbor_die 2 ssh.verify_swapped "the authorized key was renamed into the directory ${ssh_dir} named at that moment, but the name no longer reaches it: it is a symlink now, or it reaches $(harbor_ssh_path_id "${ssh_dir}") instead, so what sshd would read at ${target} cannot be proved to be the key that was written. $(basename "${entry}") stays prepared and this node should be inspected before rerunning"
      ;;
    2)
      harbor_die 2 ssh.verify_identity "${target} is not the file that was staged for it: the staged key has device and inode ${staged_id:-unreadable} and the file that name reaches has $(harbor_ssh_path_id "${target}"), so the rename did not put it where these checks are reading. $(basename "${entry}") stays prepared and this node should be inspected before rerunning"
      ;;
    3)
      harbor_die 2 ssh.verify "${target} is not what was staged for it after the copy; $(basename "${entry}") stays prepared"
      ;;
    4)
      harbor_die 2 ssh.verify_mode "${target} is mode $(harbor_stat_mode "${target}") after the copy, not 0600; $(basename "${entry}") stays prepared"
      ;;
    5)
      harbor_die 2 ssh.verify_owner "${target} is owned by $(harbor_stat_owner "${target}") after the copy, not by ${operator}; $(basename "${entry}") stays prepared"
      ;;
    *)
      harbor_die 2 ssh.verify_dir "${ssh_dir} is mode $(harbor_stat_mode "${ssh_dir}") owned by $(harbor_stat_owner "${ssh_dir}") after the copy, not 0700 owned by ${operator}; $(basename "${entry}") stays prepared"
      ;;
  esac
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
# 3.5 acceptance. sshd itself is asked what it would do for that account, and every value
# harbor_ssh_operator_render writes must be the value it wrote; anything else means the
# drop-in did not take effect and is exit 2 with the node's state, before any reload.
#
# All three of them, not only the two the row turns off. OpenSSH keeps the first value it obtains
# for a keyword, Ubuntu's /etc/ssh/sshd_config begins with Include
# /etc/ssh/sshd_config.d/*.conf, and those files are read in lexical order, so a drop-in
# sorting before Harbor's, or a global PubkeyAuthentication no obtained ahead of this
# Match block, leaves the block's own value ignored. sshd -T -C user=OPERATOR then
# reports pubkey, password, and keyboard-interactive all no: asserting only the two no
# values would pass on exactly the node where the operator has been left with no way in
# at all, on an account whose drop-in says public-key-only authentication. The expected
# value therefore travels with each directive rather than being assumed to be no, and the
# refusal quotes what sshd actually reported for the directive that failed.
#
# StrictModes is the fourth asserted directive and the one Harbor does not write. sshd
# ignores an authorized_keys owned by neither root nor the account logging in, and that is
# what keeps a key file which reached a path it was not meant to reach from being a key
# file that works there: it is the backstop behind the directory the key is renamed into.
# Harbor asserts it rather than setting it, because it is sshd's own default and an
# administrator who turned it off did so on purpose. The honest answer to finding it off
# is a refusal naming the reason, not a drop-in that quietly turns it back on.
harbor_ssh_assert_operator() {
  local operator="${1}" situation="${2}" effective pair directive expected reported
  effective="$(harbor_sshd_effective "${operator}" "${situation}")" || exit "$?"
  for pair in pubkeyauthentication=yes passwordauthentication=no kbdinteractiveauthentication=no strictmodes=yes; do
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
# harbor_ssh_assert_admin_pubkey ADMIN SITUATION: the --harden-sshd half of the same
# acceptance. sshd itself is asked what it would do for the installation user, and it must
# report that public-key authentication is on for that account; anything else is exit 2
# with the node's state, before any reload.
#
# The syntax check alone does not stand between --harden-sshd and an unreachable node.
# sshd -t proves the configuration parses, and nothing more: it says nothing about which
# value any keyword ends up with. OpenSSH keeps the first value it obtains for a keyword,
# Ubuntu's /etc/ssh/sshd_config begins with Include /etc/ssh/sshd_config.d/*.conf, and
# those files are read in lexical order, so a drop-in sorting before 51-harbor-global.conf,
# or a PubkeyAuthentication no obtained ahead of it, is the value sshd uses and Harbor's
# file changes nothing. A node like that parses perfectly, and the reload it is about to be
# given carries PasswordAuthentication no and PermitRootLogin no for every account. The
# administrator running the command over SSH at that moment then has no password, no root
# login, and no key authentication either: the file harbor_ssh_admin_authorized_keys proved
# was there and readable by sshd is a file sshd is never going to be asked for.
#
# One directive, and only this one. What has to be proved before the reload is that the
# administrator keeps a way in, and public-key authentication being on for that account is
# that way; the flag's own two values are what the reload exists to establish, so demanding
# them here would be demanding that the row have already happened. StrictModes is not asked
# for either: with it off sshd reads more key files rather than fewer, so it cannot be what
# strands this account, and the owner and mode of the administrator's own file are settled
# by the refusal above instead.
harbor_ssh_assert_admin_pubkey() {
  local admin="${1}" situation="${2}" effective reported
  effective="$(harbor_sshd_effective "${admin}" "${situation}")" || exit "$?"
  if printf '%s\n' "${effective}" | grep -qxF -- 'pubkeyauthentication yes'; then
    return 0
  fi
  reported="$(printf '%s\n' "${effective}" | grep -- '^pubkeyauthentication ' | sed -n 1p || true)"
  [ -n "${reported}" ] || reported="no pubkeyauthentication line at all"
  harbor_die 2 ssh.harden_admin_no_pubkey "sshd -T -C user=${admin} does not report 'pubkeyauthentication yes', it reports '${reported}', so public-key authentication is already off for ${admin} on this node whatever this drop-in says: OpenSSH keeps the first value it obtains for a keyword, and a drop-in sorting before Harbor's, or a global PubkeyAuthentication no, is obtained ahead of it. --harden-sshd takes password authentication and root login away from every account, so reloading now would leave ${admin} no way in at all. Nothing was reloaded, so the running sshd still has the configuration it had before; ${situation}; turn public-key authentication back on for ${admin}, or remove the drop-in named above and rerun without --harden-sshd"
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
#
# And content is not the whole of it here either, for exactly the reason it is not at the
# operator's own target: StrictModes makes sshd ignore an authorized_keys owned by neither
# root nor the account logging in, and ignore one that is group- or world-writable,
# whatever key is in it. The gate above judged this file by its bytes alone, so a file
# sshd will never read satisfied the one check standing between --harden-sshd and a node
# nobody can reach. It is a sharper lockout than the operator's, because this drop-in sets
# PermitRootLogin no and PasswordAuthentication no for every account at once: the
# administrator whose own key file sshd ignores loses password login, root login, and key
# login in the same reload, from the session they are running the command in.
#
# The rule is the one harbor_ssh_authorize applies to ${target}, applied here to ${path}
# for ${admin}, and the mode test is group- and world-writability rather than equality
# with 0600 for the same reason: 0644 and 0640 are modes sshd reads happily and are the
# administrator's own choice, and refusing them would deny a flag that was safe to give.
# harbor_stat_mode prints four octal digits, so the last is the world's and the one before
# it the group's, and a digit of 2, 3, 6, or 7 carries the write bit.
#
# Refusal only, never a chmod or a chown: this file belongs to the administrator, Harbor
# did not create it, and the honest answer is to say which property failed and what sshd
# does about it. The reason is its own token rather than ssh.harden_no_key, because a key
# that is there and unread is a different thing to fix than a key that is not there. Every
# refusal here goes to stderr through harbor_die, as the ones above it do, so the path
# this function prints on stdout is never polluted by a message.
harbor_ssh_admin_authorized_keys() {
  local admin="${1}" home path owner mode dir
  [ "${admin}" != root ] \
    || harbor_die 3 ssh.harden_no_key "--harden-sshd sets PermitRootLogin no, so root is not the installation user it can be given to; rerun through sudo from your own account, or drop --harden-sshd; nothing was written"
  home="$(harbor_ssh_user_home "${admin}")" || exit "$?"
  path="${home}/.ssh/authorized_keys"
  { [ -f "${path}" ] && [ -r "${path}" ] && harbor_ssh_has_usable_key "${path}"; } \
    || harbor_die 3 ssh.harden_no_key "--harden-sshd sets PermitRootLogin no and PasswordAuthentication no for every account, and ${path} is missing, unreadable, or holds no usable authorized-key line (it is empty, or every line in it is blank or a comment), so ${admin} would have no way left to log in to this node; add ${admin}'s own public key to that file and rerun, or rerun without --harden-sshd; nothing was written"
  owner="$(harbor_stat_owner "${path}")"
  { [ "${owner}" = "${admin}" ] || [ "${owner}" = root ]; } \
    || harbor_die 3 ssh.harden_key_unusable "${path} holds a key but is owned by ${owner}, which is neither ${admin} nor root, so sshd ignores it: StrictModes reads an authorized_keys only when it belongs to root or to the account logging in. --harden-sshd sets PermitRootLogin no and PasswordAuthentication no for every account, so it would leave ${admin} no way in at all: no password, no root login, and no key sshd will read. Harbor changes nothing it did not create: give ${path} to ${admin} by hand and rerun, or rerun without --harden-sshd; nothing was written"
  mode="$(harbor_stat_mode "${path}")"
  case "${mode}" in
    *[2367])
      harbor_die 3 ssh.harden_key_unusable "${path} holds a key but is mode ${mode}, which is world-writable, so sshd ignores it: StrictModes refuses an authorized_keys any account on this node could add a key to. --harden-sshd sets PermitRootLogin no and PasswordAuthentication no for every account, so it would leave ${admin} no way in at all: no password, no root login, and no key sshd will read. Harbor changes nothing it did not create: narrow the mode of ${path} by hand and rerun, or rerun without --harden-sshd; nothing was written"
      ;;
    *[2367][0-7])
      harbor_die 3 ssh.harden_key_unusable "${path} holds a key but is mode ${mode}, which is group-writable, so sshd ignores it: StrictModes refuses an authorized_keys every member of its group could add a key to. --harden-sshd sets PermitRootLogin no and PasswordAuthentication no for every account, so it would leave ${admin} no way in at all: no password, no root login, and no key sshd will read. Harbor changes nothing it did not create: narrow the mode of ${path} by hand and rerun, or rerun without --harden-sshd; nothing was written"
      ;;
  esac
  # And the key file is not the whole of what StrictModes judges. sshd does not stop at
  # authorized_keys: it walks from that file up through every directory above it as far as
  # the account's home, and refuses the key if any one of them is owned by someone other
  # than root or that account, or is group- or world-writable. So a file that is itself
  # perfectly owned and perfectly moded, sitting under a 0777 home, is still a key sshd
  # will never read, and the checks above would have passed it. The two directories on
  # that walk are ${home}/.ssh and ${home}, and both of them exist, ${path} having been
  # proved a readable regular file a moment ago.
  #
  # Each is read from inside itself rather than by its name from outside. sshd resolves the
  # path before it judges the components, so a home reached through a symlink is judged as
  # what it resolves to; reading the name from outside would read the link instead, and a
  # symlink is mode 0777 on Linux, which this very test would then refuse as world-writable
  # when sshd has no objection to it at all. Entering the directory and reading '.' is the
  # resolution, and needs no readlink -f, which this file's bash 3.2 subset does not have.
  for dir in "${home}/.ssh" "${home}"; do
    owner="$(cd "${dir}" 2>/dev/null && harbor_stat_owner .)" \
      || harbor_die 3 ssh.harden_key_unusable "${dir}, which sshd reads ${path} through, cannot be entered to be judged, so whether sshd would read the key under it cannot be established. --harden-sshd sets PermitRootLogin no and PasswordAuthentication no for every account, and Harbor will not take ${admin}'s password and root login away on a node it cannot prove that account can still log in to; nothing was written"
    { [ "${owner}" = "${admin}" ] || [ "${owner}" = root ]; } \
      || harbor_die 3 ssh.harden_key_unusable "${path} holds a key sshd will not read: ${dir}, one of the directories above it, is owned by ${owner}, which is neither ${admin} nor root, and StrictModes refuses a key file reached through a directory belonging to anyone else. --harden-sshd sets PermitRootLogin no and PasswordAuthentication no for every account, so it would leave ${admin} no way in at all: no password, no root login, and no key sshd will read. Harbor changes nothing it did not create: give ${dir} to ${admin} by hand and rerun, or rerun without --harden-sshd; nothing was written"
    mode="$(cd "${dir}" 2>/dev/null && harbor_stat_mode .)" \
      || harbor_die 3 ssh.harden_key_unusable "${dir}, which sshd reads ${path} through, cannot be entered to be judged, so whether sshd would read the key under it cannot be established. --harden-sshd sets PermitRootLogin no and PasswordAuthentication no for every account, and Harbor will not take ${admin}'s password and root login away on a node it cannot prove that account can still log in to; nothing was written"
    case "${mode}" in
      *[2367])
        harbor_die 3 ssh.harden_key_unusable "${path} holds a key sshd will not read: ${dir}, one of the directories above it, is mode ${mode}, which is world-writable, and StrictModes refuses a key file reached through a directory any account on this node could put a key file into. --harden-sshd sets PermitRootLogin no and PasswordAuthentication no for every account, so it would leave ${admin} no way in at all: no password, no root login, and no key sshd will read. Harbor changes nothing it did not create: narrow the mode of ${dir} by hand and rerun, or rerun without --harden-sshd; nothing was written"
        ;;
      *[2367][0-7])
        harbor_die 3 ssh.harden_key_unusable "${path} holds a key sshd will not read: ${dir}, one of the directories above it, is mode ${mode}, which is group-writable, and StrictModes refuses a key file reached through a directory every member of its group could put a key file into. --harden-sshd sets PermitRootLogin no and PasswordAuthentication no for every account, so it would leave ${admin} no way in at all: no password, no root login, and no key sshd will read. Harbor changes nothing it did not create: narrow the mode of ${dir} by hand and rerun, or rerun without --harden-sshd; nothing was written"
        ;;
    esac
  done
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
  # Between sshd's syntax check and the reload, and never after it: what this proves is
  # that the administrator still has a way in on the node as it is about to be reloaded,
  # and the only useful moment for that is while the running sshd still holds the
  # configuration it had. sshd -T reads the configuration files rather than the running
  # daemon, so the drop-in on disk is already in the answer; the reload is what makes the
  # running sshd adopt it, and a refusal here leaves it holding the old one. That is the
  # same placement harbor_ssh_configure gives harbor_ssh_assert_operator, and the same
  # guarantee: exit 2, nothing reloaded, the entry left prepared for recovery.
  harbor_ssh_assert_admin_pubkey "${admin}" "${situation}"
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
