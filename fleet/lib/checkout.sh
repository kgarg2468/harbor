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
