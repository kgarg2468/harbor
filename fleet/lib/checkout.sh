#!/bin/bash
# Checkout trust rules (design section 5.1): the canonical checkout root derived from
# the script root is really executing, and the ownership and mode rules root applies to
# a checkout it does not own before it runs any code from it. Both functions are
# read-only: neither mutates anything and neither invokes git. The hardened Git
# invocation and the clean exact tag check are added below these functions.
# harbor_checkout_root_from_argv0 ARGV0: the canonical absolute checkout root of the
# script ARGV0 names, resolved with symlinks followed, so the relative, the
# parent-relative, and the absolute spelling of one entrypoint all give one root.
# macOS has no readlink -f, so the chain is followed by hand: the directory is
# canonicalized with cd -P and pwd -P, and while the leaf is a symlink it is replaced
# by its target read relative to that directory. The parent must be named bin and the
# grandparent is the root; anything else exits 3.
harbor_checkout_root_from_argv0() {
  local argv0="${1:-}" dir base target root hops=0
  case "${argv0}" in
    "" | */) harbor_die 3 checkout.argv0 "'${argv0}' does not name a script" ;;
    */*) dir="${argv0%/*}" ;;
    *) dir="." ;;
  esac
  base="${argv0##*/}"
  while :; do
    if ! dir="$(cd -P -- "${dir}" 2>/dev/null && pwd -P)"; then
      harbor_die 3 checkout.argv0 "${argv0} does not resolve to an existing path"
    fi
    [ -L "${dir}/${base}" ] || break
    hops=$((hops + 1))
    if [ "${hops}" -gt 40 ]; then
      harbor_die 3 checkout.argv0 "${argv0} resolves through more than 40 symlinks"
    fi
    target="$(readlink "${dir}/${base}")"
    case "${target}" in
      /*/*)
        dir="${target%/*}"
        base="${target##*/}"
        ;;
      /*)
        dir="/"
        base="${target#/}"
        ;;
      */*)
        dir="${dir}/${target%/*}"
        base="${target##*/}"
        ;;
      *) base="${target}" ;;
    esac
  done
  if [ ! -f "${dir}/${base}" ]; then
    harbor_die 3 checkout.argv0 "${dir}/${base} is not an ordinary file"
  fi
  if [ "${dir##*/}" != bin ]; then
    harbor_die 3 checkout.layout \
      "${dir} is not named bin: a checkout entrypoint is <checkout>/bin/harbor"
  fi
  root="${dir%/*}"
  [ -n "${root}" ] || root="/"
  printf '%s\n' "${root}"
}
# harbor_checkout_trusted PATH [OPERATOR]: exits 3 unless every component of PATH's
# canonical path, from / to the checkout root, and every directory and ordinary file
# inside the checkout, is owned by a trusted identity and is writable by neither group
# nor other, symlinks followed and their targets held to the same rule. The trusted
# identities are root and the invoking SUDO_USER. When OPERATOR is given, anything
# owned by that user or by that user's group is rejected outright, before the mode
# rule, so the operator, who runs untrusted agent code, can never place code root
# executes; "or writable by either" needs no arm of its own, because a group-writable
# or other-writable path is already rejected whoever owns it and an owner-writable one
# is already rejected by the ownership arm. Any failure names the offending path and
# mutates nothing.
harbor_checkout_trusted() {
  local path="${1:-}" operator="${2:-}" root trusted opgroup os
  local ancestors listing rest part prefix p shown meta owner group mode
  if ! root="$(cd -P -- "${path}" 2>/dev/null && pwd -P)"; then
    harbor_die 3 checkout.absent "${path} is not a directory Harbor can read"
  fi
  trusted="root${SUDO_USER:+ ${SUDO_USER}}"
  opgroup=""
  if [ -n "${operator}" ] && ! opgroup="$(id -gn "${operator}" 2>/dev/null)"; then
    # No such account yet: the group Harbor would create with it carries its name, and
    # holding a path in it against the operator is the conservative reading.
    opgroup="${operator}"
  fi
  # The identities are read from the environment only when the caller is not root, so
  # that a unit test can stand in for identities it cannot create. Root, the only
  # principal that applies these rules, always judges against root and SUDO_USER.
  if [ "$(id -u)" != 0 ]; then
    trusted="${HARBOR_CHECKOUT_TRUSTED_USERS:-${trusted}}"
  fi
  # Every component from / to the root. The root is canonical, so no component of it
  # is a symlink and each prefix of it is canonical too.
  ancestors="/"
  prefix=""
  rest="${root#/}"
  while [ -n "${rest}" ]; do
    part="${rest%%/*}"
    prefix="${prefix}/${part}"
    ancestors="${ancestors}
${prefix}"
    case "${rest}" in
      */*) rest="${rest#*/}" ;;
      *) rest="" ;;
    esac
  done
  os="$(harbor_os)"
  # The walk is collected before it is judged, because a find that gives up partway
  # (an unreadable directory, a symlink loop) would otherwise present a short list the
  # loop would happily approve. Its failure is the checkout's failure.
  if ! listing="$(find -L "${root}" -mindepth 1 -print)"; then
    harbor_die 3 checkout.walk "${root} cannot be walked in full, so Harbor cannot judge what is inside it"
  fi
  while IFS= read -r p; do
    [ -n "${p}" ] || continue
    shown="${p}"
    if [ -L "${p}" ]; then
      shown="${p} (a symlink to $(readlink "${p}"))"
      # A link with no target has no metadata to judge, and stat -L reports the link
      # itself rather than failing on one platform of the two, so it is caught here.
      if [ ! -e "${p}" ]; then
        harbor_die 3 checkout.unresolved "${shown} does not resolve to a path Harbor can read"
      fi
    fi
    # -L: the rule judges the target of a symlink, never the link's own mode, which
    # carries no meaning. find -L enumerates the tree the same way.
    case "${os}" in
      Linux) meta="$(stat -L -c '%U %G %a' -- "${p}" 2>/dev/null)" || meta="" ;;
      Darwin) meta="$(stat -L -f '%Su %Sg %Lp' -- "${p}" 2>/dev/null)" || meta="" ;;
      *) harbor_die 3 checkout.platform "unsupported platform ${os}" ;;
    esac
    if [ -z "${meta}" ]; then
      harbor_die 3 checkout.unresolved "${shown} does not resolve to a path Harbor can read"
    fi
    owner="${meta%% *}"
    group="${meta#* }"
    group="${group%% *}"
    mode="${meta##* }"
    case " ${trusted} " in
      *" ${owner} "*) ;;
      *) harbor_die 3 checkout.owner "${shown} is owned by ${owner}, not by ${trusted}" ;;
    esac
    if [ -n "${operator}" ]; then
      if [ "${owner}" = "${operator}" ]; then
        harbor_die 3 checkout.operator "${shown} is owned by the operator ${operator}"
      fi
      if [ "${group}" = "${opgroup}" ]; then
        harbor_die 3 checkout.operator_group \
          "${shown} is in the operator group ${opgroup}"
      fi
    fi
    if [ "$((8#${mode} & 0022))" != 0 ]; then
      harbor_die 3 checkout.mode \
        "${shown} has mode ${mode}: a checkout may not be writable by group or other"
    fi
  done <<EOF
${ancestors}
${listing}
EOF
}
# harbor_git CHECKOUT ARG...: every Git command Harbor runs against a checkout, in
# exactly the hardened form of design section 5.1:
#
#   GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git -C <checkout> \
#     -c safe.directory=<checkout> -c core.fsmonitor=false -c core.hooksPath=/dev/null <args>
#
# which disables system and global configuration, hooks, and the filesystem monitor for
# the invocation, and writes nothing to any Git configuration anywhere. Repository-local
# configuration under .git/ is still read, and is trusted only because it sits inside
# the administrator-owned boundary harbor_checkout_trusted has just judged. Git's
# stdout, stderr, and exit status are the caller's own, so a caller can read rev-parse
# or pipe git archive through this function and see nothing Harbor added.
harbor_git() {
  local checkout="${1:-}"
  [ "$#" -ge 2 ] || harbor_die 3 usage "usage: harbor_git <checkout> <argument>..."
  shift
  harbor_log_vendor git -C "${checkout}" "$@"
  GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git -C "${checkout}" \
    -c "safe.directory=${checkout}" -c core.fsmonitor=false -c core.hooksPath=/dev/null "$@"
}
# harbor_checkout_tag CHECKOUT: the tag CHECKOUT sits at, printed on stdout, when its
# work tree is clean and HEAD is exactly at a tag. Root installs only git archive of a
# verified clean exact tag and never the work tree (design section 5.1), so every other
# state exits 3 naming which of the four it found, since each has its own fix: tracked
# changes are a dirty work tree, an untracked file is content git archive would silently
# leave out of the installed tree, a HEAD that no tag names or follows is untagged, and
# a HEAD past a tag is between tags. HARBOR_DEV=1 is not read here, or anywhere else in
# this file, so the check is unconditional and no command run as root can stage or
# execute dirty or untracked work. Inspection only: nothing here mutates the checkout.
harbor_checkout_tag() {
  local checkout="${1:-}" rc=0 head dirty untracked tag near
  [ -n "${checkout}" ] || harbor_die 3 usage "usage: harbor_checkout_tag <checkout>"
  head="$(harbor_git "${checkout}" rev-parse --verify HEAD 2>/dev/null)" || rc="$?"
  if [ "${rc}" != 0 ] || [ -z "${head}" ]; then
    harbor_die 3 checkout.no_head "${checkout} is not a Git checkout with a commit at HEAD"
  fi
  rc=0
  dirty="$(harbor_git "${checkout}" status --porcelain --untracked-files=no)" || rc="$?"
  [ "${rc}" = 0 ] || harbor_die 2 checkout.git "git status failed in ${checkout} (exit ${rc})"
  if [ -n "${dirty}" ]; then
    harbor_die 3 checkout.dirty \
      "${checkout} has uncommitted changes to tracked files ($(printf '%s' "${dirty}" | tr '\n' ' ')): commit or stash them, then rerun"
  fi
  rc=0
  untracked="$(harbor_git "${checkout}" ls-files --others --exclude-standard)" || rc="$?"
  [ "${rc}" = 0 ] || harbor_die 2 checkout.git "git ls-files failed in ${checkout} (exit ${rc})"
  if [ -n "${untracked}" ]; then
    harbor_die 3 checkout.untracked \
      "${checkout} holds untracked files ($(printf '%s' "${untracked}" | tr '\n' ' ')): git archive would leave them out of the installed tree; commit or remove them, then rerun"
  fi
  rc=0
  tag="$(harbor_git "${checkout}" describe --tags --exact-match HEAD 2>/dev/null)" || rc="$?"
  if [ "${rc}" = 0 ] && [ -n "${tag}" ]; then
    printf '%s\n' "${tag}"
    return 0
  fi
  # git describe --tags names the nearest tag HEAD follows and suffixes the distance and
  # the abbreviated commit, so stripping the last two dash-separated fields leaves the
  # tag itself, dashes in the tag's own name included. Its failure means no tag is an
  # ancestor of HEAD at all, which is the untagged state rather than the between-tags one.
  rc=0
  near="$(harbor_git "${checkout}" describe --tags HEAD 2>/dev/null)" || rc="$?"
  if [ "${rc}" = 0 ] && [ -n "${near}" ]; then
    near="${near%-*}"
    near="${near%-*}"
    harbor_die 3 checkout.between_tags \
      "${checkout} is at ${head}, a commit past the tag ${near} rather than at a tag: check out an exact release tag, then rerun"
  fi
  harbor_die 3 checkout.no_tag \
    "${checkout} is at ${head}, which no tag names or follows: check out an exact release tag, then rerun"
}
