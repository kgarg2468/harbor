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
