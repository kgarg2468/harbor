#!/bin/bash
# Installed releases (design section 5.2, the Install Harbor row): the stable tree
# hash and its journal observer, mode normalization to the installed contract, and
# staging git archive of an already-verified tag into a release directory as one
# journaled harbor-install transaction of design section 3.7. Every Git invocation
# goes through harbor_git, the hardened form lib/checkout.sh defines, so nothing
# here reaches Git directly and nothing here reads the work tree. The state root and
# the destination are parameters; production passes /var/lib/harbor and
# /usr/local/lib/harbor/<tag>, unit tests pass fixture paths. Depends on lib/log.sh,
# lib/lock.sh, and lib/journal.sh.
# harbor_release_tree_manifest DIR: one line per entry of DIR, deepest detail first,
# in LC_ALL=C order of the path relative to DIR: the entry kind, its mode, its
# content digest (a symlink's target, "-" for a directory), and the path. Paths are
# relative, so the manifest of a staging directory equals the manifest of the same
# tree after it is moved into place; no timestamp, inode, owner, or absolute path is
# read, so the same tree hashes the same on any machine and in any staging
# directory. A symlink contributes its target rather than a mode, because the mode
# of a symlink is 0777 on Linux and 0755 on macOS and is never followed.
harbor_release_tree_manifest() {
  local dir="${1}" path
  (cd "${dir}" && find . -print) | LC_ALL=C sort | while IFS= read -r path; do
    if [ -L "${dir}/${path}" ]; then
      printf 'l\t-\t%s\t%s\n' "$(readlink "${dir}/${path}")" "${path}"
    elif [ -d "${dir}/${path}" ]; then
      printf 'd\t%s\t-\t%s\n' "$(harbor_stat_mode "${dir}/${path}")" "${path}"
    elif [ -f "${dir}/${path}" ]; then
      printf 'f\t%s\t%s\t%s\n' "$(harbor_stat_mode "${dir}/${path}")" \
        "$(harbor_sha256 "${dir}/${path}")" "${path}"
    else
      printf 'o\t-\t-\t%s\n' "${path}"
    fi
  done
}
# harbor_release_tree_hash DIR: the SHA-256 of that manifest, so the hash changes
# with any content, path, or mode change anywhere in DIR and with nothing else.
harbor_release_tree_hash() {
  [ -d "${1}" ] || harbor_die 3 release.tree_hash "${1} is not a directory"
  harbor_release_tree_manifest "${1}" | harbor_sha256 /dev/stdin
}
# harbor_observe_op_harbor_install DEST: the observer harbor_journal_observe
# dispatches to for a harbor-install entry, so a prepared entry left by a crash
# between the move into place and the applied write is decidable by recovery
# (design section 3.7). The tree hash at DEST in the shape a harbor-install entry's
# post_state carries, the same "absent" its pre_state carries when nothing is there,
# and the unobservable marker when what is there is not a directory. Inspection
# only. Called only through harbor_journal_observe.
harbor_observe_op_harbor_install() {
  local dest="${1}"
  if [ ! -e "${dest}" ] && [ ! -L "${dest}" ]; then
    printf '"absent"'
    return 0
  fi
  if [ ! -d "${dest}" ] || [ -L "${dest}" ]; then
    printf '"unobservable:not-a-directory"'
    return 0
  fi
  printf '{"tree_sha256":"%s"}' "$(harbor_release_tree_hash "${dest}")"
}
# harbor_release_applied_state STATE_ROOT DEST: the post_state of the newest applied
# harbor-install entry whose target is DEST, empty when the journal holds none. This
# is the proof that Harbor created that directory; without it the directory is an
# orphan and Harbor removes nothing.
harbor_release_applied_state() {
  local root="${1}" dest="${2}" entry state=""
  for entry in "${root}"/journal/[0-9][0-9][0-9][0-9]-harbor-install.json; do
    [ -e "${entry}" ] || continue
    [ "$(harbor_journal_string "${entry}" phase)" = "applied" ] || continue
    [ "$(harbor_journal_string "${entry}" target)" = "${dest}" ] || continue
    state="$(harbor_journal_raw "${entry}" post_state)"
  done
  printf '%s' "${state}"
}
# harbor_release_normalize_modes DIR: the installed modes of design section 5.2,
# whatever modes the archived tag carried: every directory 0755, every ordinary file
# 0644, and only the release's own bin/harbor also executable. Symlinks are neither
# matched nor followed by either find.
harbor_release_normalize_modes() {
  local dir="${1}"
  find "${dir}" -type d -exec chmod 0755 {} + \
    || harbor_die 2 release.modes "cannot normalize the directory modes under ${dir}"
  find "${dir}" -type f -exec chmod 0644 {} + \
    || harbor_die 2 release.modes "cannot normalize the file modes under ${dir}"
  if [ -f "${dir}/bin/harbor" ] && [ ! -L "${dir}/bin/harbor" ]; then
    chmod 0755 "${dir}/bin/harbor" \
      || harbor_die 2 release.modes "cannot make ${dir}/bin/harbor executable"
  fi
}
# harbor_release_stage STATE_ROOT CHECKOUT TAG DEST: install the tag preflight has
# already verified at DEST, from git archive of that tag rather than from the work
# tree, so what lands is the tagged tree and nothing a work tree could carry. The
# archive is extracted into a temporary directory beside DEST, owned by the caller's
# identity (root in production), normalized to the installed modes, and given a
# RELEASE marker naming the tag and the commit, all before anything of it is in
# place; then one harbor-install entry, created, is journaled prepared with the tree
# hash as post_state, the tree is moved into place, and the entry is marked applied
# once the release at DEST observes as that hash. A directory already at DEST whose
# hash equals its applied entry is kept rather than restaged and journals nothing
# new; one with no such entry, or with a differing hash, is an orphan: exit 3, and
# Harbor removes nothing it cannot prove it created.
harbor_release_stage() {
  local root checkout tag dest
  local observed recorded parent tmp work commit post entry
  [ "$#" -eq 4 ] || harbor_die 3 usage "usage: harbor_release_stage <state-root> <checkout> <tag> <destination>"
  root="${1}"
  checkout="${2}"
  tag="${3}"
  dest="${4}"
  if [ -e "${dest}" ] || [ -L "${dest}" ]; then
    observed="$(harbor_observe_op_harbor_install "${dest}")" || exit "$?"
    recorded="$(harbor_release_applied_state "${root}" "${dest}")"
    if [ -n "${recorded}" ] && [ "${recorded}" = "${observed}" ]; then
      harbor_log release "${dest} matches its applied harbor-install entry; keeping it"
      return 0
    fi
    if [ -z "${recorded}" ]; then
      harbor_die 3 release.orphan "${dest} is already there and the journal in ${root} holds no applied harbor-install entry for it, so Harbor cannot prove it installed it and will remove nothing: confirm nothing of yours is inside it, remove it and any /usr/local/bin/harbor pointing into it by hand, then rerun"
    fi
    harbor_die 3 release.orphan "${dest} is already there but observes as ${observed}, not the ${recorded} its applied harbor-install entry records, so Harbor cannot prove it installed what is there now and will remove nothing: confirm nothing of yours is inside it, remove it and any /usr/local/bin/harbor pointing into it by hand, then rerun"
  fi
  parent="$(dirname "${dest}")"
  mkdir -p "${parent}"
  tmp="$(mktemp -d "${parent}/.harbor-release.XXXXXX")" \
    || harbor_die 2 release.tmpdir "cannot create a temporary directory under ${parent}"
  work="${tmp}/tree"
  mkdir "${work}"
  chmod 0755 "${work}"
  if ! commit="$(harbor_git "${checkout}" rev-parse "${tag}^{commit}")"; then
    rm -rf "${tmp}"
    harbor_die 3 release.commit "cannot resolve ${tag} to a commit in ${checkout}; nothing was staged"
  fi
  if ! harbor_git "${checkout}" archive --format=tar "${tag}" >"${tmp}/release.tar"; then
    rm -rf "${tmp}"
    harbor_die 2 release.archive "git archive of ${tag} in ${checkout} failed; nothing was staged"
  fi
  if ! tar -xpf "${tmp}/release.tar" -C "${work}" --no-same-owner; then
    rm -rf "${tmp}"
    harbor_die 2 release.extract "extraction of the ${tag} archive failed; nothing was staged"
  fi
  rm -f "${tmp}/release.tar"
  harbor_release_normalize_modes "${work}"
  printf 'tag=%s\ncommit=%s\n' "${tag}" "${commit}" >"${work}/RELEASE"
  chmod 0644 "${work}/RELEASE"
  post="{\"tree_sha256\":\"$(harbor_release_tree_hash "${work}")\"}"
  harbor_journal_create "${root}" harbor-install "${dest}" created prepared '"absent"' "${post}"
  entry="${HARBOR_JOURNAL_ENTRY}"
  harbor_step release-prepared
  if ! mv "${work}" "${dest}"; then
    rm -rf "${tmp}"
    harbor_die 2 release.swap "moving the staged ${tag} tree into ${dest} failed; nothing is at ${dest}, so $(basename "${entry}") stays prepared and recovery reverts it, rerun after fixing the cause"
  fi
  rm -rf "${tmp}"
  harbor_journal_sync_path "${parent}"
  observed="$(harbor_observe_op_harbor_install "${dest}")" || exit "$?"
  [ "${observed}" = "${post}" ] \
    || harbor_die 2 release.verify "${dest} observes as ${observed} after staging ${tag}, not the ${post} that was prepared; $(basename "${entry}") stays prepared"
  harbor_journal_set_phase "${entry}" applied
  harbor_step release-applied
  harbor_msg "installed ${tag} at ${dest}"
}
# harbor_release_link_owned TARGET RELEASE_ROOT: whether TARGET, the recorded text of
# an existing symlink, names a path inside RELEASE_ROOT. The decision is made on that
# text alone and never on what the link resolves to, so a link cannot claim a release
# it does not name; a text carrying a .. component is refused rather than normalized,
# so no link reaches outside RELEASE_ROOT through one.
harbor_release_link_owned() {
  case "${1}" in
    "${2}"/*) ;;
    *) return 1 ;;
  esac
  case "/${1}/" in
    */../*) return 1 ;;
  esac
  return 0
}
# harbor_release_link STATE_ROOT RELEASE LINK [RELEASE_ROOT]: point LINK, Harbor's
# only entrypoint after bootstrap (design section 5.2), at RELEASE/bin/harbor by
# writing a temporary symlink beside LINK and renaming it into place, so the link
# never resolves to a partial target and never briefly disappears: the temporary link
# already names the whole target before the rename, and the rename replaces the link
# in one step rather than unlinking it first. One file entry: observed (directly
# applied, nothing touched) when the link already points there, created with pre_state
# "absent" when nothing is there, modified with the prior target when a symlink into
# RELEASE_ROOT is there, which is the reinstall after a mid-unwind teardown crash of
# design section 5.7, and the reverse walk restores that target from the entry.
# Anything else at the link path is foreign: exit 3 naming it for manual inspection,
# and Harbor removes nothing it cannot prove it created. Both states are rendered by
# harbor_observe_file, the observer recovery uses for a file entry, so an entry left
# prepared by a crash between the rename and the applied write is decidable.
# RELEASE_ROOT defaults to the production /usr/local/lib/harbor; unit tests pass a
# fixture path, as the destination of harbor_release_stage already is.
harbor_release_link() {
  local root release link libroot target pre post ownership prior tmp entry
  [ "$#" -ge 3 ] && [ "$#" -le 4 ] \
    || harbor_die 3 usage "usage: harbor_release_link <state-root> <release> <link> [release-root]"
  root="${1}"
  release="${2}"
  link="${3}"
  libroot="${4:-/usr/local/lib/harbor}"
  libroot="${libroot%/}"
  target="${release}/bin/harbor"
  [ -f "${target}" ] \
    || harbor_die 2 release.link_target "${target} does not exist, so ${link} would not resolve to a release entrypoint; the release at ${release} is incomplete, remove it by hand and rerun"
  pre="$(harbor_observe_file "${link}")"
  post="{\"symlink\":\"$(harbor_json_escape "${target}")\"}"
  if [ "${pre}" = "${post}" ]; then
    harbor_journal_create "${root}" file "${link}" observed applied "${pre}" "${post}"
    harbor_log release "${link} already points at ${target}; keeping it"
    return 0
  fi
  if [ "${pre}" = '"absent"' ]; then
    ownership=created
  else
    if [ ! -L "${link}" ]; then
      harbor_die 3 release.link_foreign "${link} is already there and is not a symlink; Harbor removes nothing it cannot prove it created: inspect it, remove it by hand if it is not needed, and rerun"
    fi
    if [ -d "${link}" ]; then
      harbor_die 3 release.link_foreign "${link} is a symlink to a directory, which a rename would write into rather than replace; inspect it, remove it by hand if it is not needed, and rerun"
    fi
    prior="$(readlink "${link}")"
    harbor_release_link_owned "${prior}" "${libroot}" \
      || harbor_die 3 release.link_foreign "${link} is a symlink to ${prior}, which is not a path under ${libroot}/, so it is not a Harbor release entrypoint; inspect it, remove it by hand if it is not needed, and rerun"
    ownership=modified
  fi
  harbor_journal_create "${root}" file "${link}" "${ownership}" prepared "${pre}" "${post}"
  entry="${HARBOR_JOURNAL_ENTRY}"
  harbor_step release-link-prepared
  tmp="$(dirname "${link}")/.$(basename "${link}").harbor.${HARBOR_LOCK_ID_PID:-$$}"
  rm -f "${tmp}"
  ln -s "${target}" "${tmp}" \
    || harbor_die 2 release.link_write "cannot write the temporary symlink ${tmp}; ${link} holds what it held before and $(basename "${entry}") stays prepared, rerun after fixing the cause"
  if ! mv -f "${tmp}" "${link}"; then
    rm -f "${tmp}"
    harbor_die 2 release.link_swap "renaming ${tmp} onto ${link} failed; ${link} holds what it held before and $(basename "${entry}") stays prepared, rerun after fixing the cause"
  fi
  harbor_journal_sync_path "$(dirname "${link}")"
  [ "$(harbor_observe_file "${link}")" = "${post}" ] \
    || harbor_die 2 release.link_verify "${link} does not point at ${target} after linking; $(basename "${entry}") stays prepared"
  harbor_journal_set_phase "${entry}" applied
  harbor_step release-link-applied
  harbor_msg "pointed ${link} at ${target}"
}
