#!/bin/bash
# Installed entrypoint preflight (design section 5.2, "Installed entrypoint"): the
# check every command's preflight applies to the path the Harbor script is really
# executing from, and the two forms that defer its record equality clause alone.
# Every function here is read-only: none mutates anything, none takes a lock, and
# none resolves /usr/local/bin/harbor, whose own integrity is judged elsewhere (the
# harbor.release check of design section 5.6 and the preflight of the root commands
# that write it), which is what lets the integration lane's logging wrapper sit at
# that path without weakening any production check. The install root and the trusted
# owner are overridable, and only for a caller that is not root, exactly as
# lib/checkout.sh overrides its trusted identities: root, the only principal that
# installs a release, always judges against /usr/local/lib/harbor and root, and a
# caller that is not root can already skip this check outright with HARBOR_DEV=1, so
# the override grants a non-root caller nothing it did not already have. Depends on
# lib/log.sh (harbor_die, harbor_log) and lib/lock.sh (harbor_os).
# harbor_entrypoint_resolve ARGV0: the canonical absolute path of the script ARGV0
# names, symlinks followed, so the path judged below is the file bash is really
# executing however the wrapper or the entrypoint symlink spelled it. macOS has no
# readlink -f, so the chain is followed by hand: the directory is canonicalized with
# cd -P and pwd -P, and while the leaf is a symlink it is replaced by its target read
# relative to that directory.
harbor_entrypoint_resolve() {
  local argv0="${1:-}" dir base target hops=0
  case "${argv0}" in
    "" | */) harbor_die 3 entrypoint.argv0 "'${argv0}' does not name a script" ;;
    */*) dir="${argv0%/*}" ;;
    *) dir="." ;;
  esac
  base="${argv0##*/}"
  while :; do
    if ! dir="$(cd -P -- "${dir}" 2>/dev/null && pwd -P)"; then
      harbor_die 3 entrypoint.argv0 "${argv0} does not resolve to an existing path"
    fi
    [ -L "${dir}/${base}" ] || break
    hops=$((hops + 1))
    if [ "${hops}" -gt 40 ]; then
      harbor_die 3 entrypoint.argv0 "${argv0} resolves through more than 40 symlinks"
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
    harbor_die 3 entrypoint.argv0 "${dir}/${base} is not an ordinary file"
  fi
  case "${dir}" in
    /) printf '/%s\n' "${base}" ;;
    *) printf '%s/%s\n' "${dir}" "${base}" ;;
  esac
}
# harbor_entrypoint_record_tag RECORD: the release tag bootstrap.json records, or a
# non-zero status when the record names none. The record is flat, non-secret JSON
# written by the last step of bootstrap; it is read with sed rather than jq because
# every function under lib/ runs before the packages step could have installed one.
harbor_entrypoint_record_tag() {
  local record="${1}" key value
  for key in release_tag tag; do
    value="$(sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" \
      "${record}" 2>/dev/null | sed -n '1p')"
    if [ -n "${value}" ]; then
      printf '%s' "${value}"
      return 0
    fi
  done
  return 1
}
# harbor_entrypoint_check ARGV0 RECORD [COMMAND]: exits 3 unless ARGV0 resolves to
# bin/harbor inside an installed release directory <install root>/<tag>/ whose
# RELEASE marker names that directory's own tag, whose every directory, the release
# directory itself included, is root-owned and 0755, whose every ordinary file is
# root-owned and 0644 with only the release's own bin/harbor 0755 instead, and whose
# tag equals the one RECORD records. COMMAND names the command whose preflight is
# running and is empty for all but the two that may defer. Deferral is fail-closed:
# only bootstrap and root journal resolve defer, and they defer the record equality
# check alone, in the record-less form when RECORD is absent and in the mismatch form
# when it names another tag; every path, ownership, and mode rule above still runs in
# both, and the harbor-install proof those two forms additionally owe is checked by
# the caller once it holds the root lock and recovery has run, not here. Every other
# command exits 3 naming sudo harbor bootstrap when the record is absent while the
# state root exists.
harbor_entrypoint_check() {
  local argv0 record cmd install_root want_owner os
  local resolved bindir base release parent tag canon
  local listing p shown meta owner mode want kind
  local marker marker_tag state_root recorded
  if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
    harbor_die 3 usage "usage: harbor_entrypoint_check <argv0> <record> [command]"
  fi
  argv0="${1}"
  record="${2}"
  cmd="${3:-}"
  install_root="/usr/local/lib/harbor"
  want_owner="root"
  # HARBOR_DEV=1 (design section 5.2) exists only so operator commands can be run
  # from a checkout as a non-root user for local development and the unit lane: for
  # those it relaxes this check and nothing else. It, and the fixture overrides
  # below, are read under one not-root gate, so a command run as root never sees
  # either and bootstrap, upgrade --system, teardown --level node, and journal
  # resolve, all of which are root, apply the rules below regardless of the
  # environment they were handed.
  if [ "$(id -u)" != 0 ]; then
    if [ "${HARBOR_DEV:-0}" = "1" ]; then
      harbor_log entrypoint "HARBOR_DEV=1: the installed entrypoint check is relaxed for this non-root command"
      return 0
    fi
    install_root="${HARBOR_ENTRYPOINT_INSTALL_ROOT:-${install_root}}"
    want_owner="${HARBOR_ENTRYPOINT_TRUSTED_OWNER:-${want_owner}}"
  fi
  # The resolved path is canonical, so the install root it is compared against is
  # canonicalized too; a spelling through a symlinked ancestor is the same root. An
  # install root that does not exist stays as written and fails the comparison below,
  # which is what a command run from a checkout on an unbootstrapped node should hit.
  if canon="$(cd -P -- "${install_root}" 2>/dev/null && pwd -P)"; then
    install_root="${canon}"
  fi
  resolved="$(harbor_entrypoint_resolve "${argv0}")" || exit "$?"
  bindir="${resolved%/*}"
  base="${resolved##*/}"
  release="${bindir%/*}"
  [ -n "${release}" ] || release="/"
  parent="${release%/*}"
  [ -n "${parent}" ] || parent="/"
  tag="${release##*/}"
  if [ "${base}" != harbor ] || [ "${bindir##*/}" != bin ]; then
    harbor_die 3 entrypoint.layout \
      "${resolved} is not bin/harbor: the installed entrypoint is <tag>/bin/harbor under ${install_root}"
  fi
  if [ "${parent}" != "${install_root}" ] || [ -z "${tag}" ]; then
    harbor_die 3 entrypoint.location \
      "${resolved} is not <tag>/bin/harbor under ${install_root}, so it is not an installed release: after bootstrap every command runs the installed entrypoint /usr/local/bin/harbor, never a checkout"
  fi
  os="$(harbor_os)"
  # The walk is collected before it is judged, because a find that gives up partway
  # (an unreadable directory, a symlink loop) would otherwise present a short list
  # the loop would happily approve. Its failure is the release's failure.
  if ! listing="$(find -L "${release}" -print)"; then
    harbor_die 3 entrypoint.walk \
      "${release} cannot be walked in full, so Harbor cannot judge the release it is executing"
  fi
  while IFS= read -r p; do
    [ -n "${p}" ] || continue
    shown="${p}"
    if [ -L "${p}" ]; then
      shown="${p} (a symlink to $(readlink "${p}"))"
      # A link with no target has no metadata to judge, and stat -L reports the link
      # itself rather than failing on one platform of the two, so it is caught here.
      if [ ! -e "${p}" ]; then
        harbor_die 3 entrypoint.unresolved "${shown} does not resolve to a path Harbor can read"
      fi
    fi
    # -L: the rule judges the target of a symlink, never the link's own mode, which
    # carries no meaning. find -L enumerates the tree the same way.
    case "${os}" in
      Linux) meta="$(stat -L -c '%U %a' -- "${p}" 2>/dev/null)" || meta="" ;;
      Darwin) meta="$(stat -L -f '%Su %Lp' -- "${p}" 2>/dev/null)" || meta="" ;;
      *) harbor_die 3 entrypoint.platform "unsupported platform ${os}" ;;
    esac
    if [ -z "${meta}" ]; then
      harbor_die 3 entrypoint.unresolved "${shown} does not resolve to a path Harbor can read"
    fi
    owner="${meta%% *}"
    mode="$(printf '%04d' "$((10#${meta##* }))")"
    if [ "${owner}" != "${want_owner}" ]; then
      harbor_die 3 entrypoint.owner \
        "${shown} is owned by ${owner}, not by ${want_owner}: an installed release and everything in it is owned by root"
    fi
    if [ -d "${p}" ]; then
      kind="a directory"
      want=0755
    elif [ -f "${p}" ]; then
      if [ "${p}" = "${resolved}" ]; then
        kind="the release entrypoint"
        want=0755
      else
        kind="an ordinary file"
        want=0644
      fi
    else
      harbor_die 3 entrypoint.kind \
        "${shown} is neither a directory nor an ordinary file, so it is not part of an installed release"
    fi
    if [ "${mode}" != "${want}" ]; then
      harbor_die 3 entrypoint.mode \
        "${shown} is ${kind} with mode ${mode}, not the installed ${want}: an installed release is never group- or world-writable, its lib/*.sh files are sourced rather than executed, and only bin/harbor is executable"
    fi
  done <<EOF
${listing}
EOF
  marker="${release}/RELEASE"
  if [ ! -f "${marker}" ]; then
    harbor_die 3 entrypoint.release_marker \
      "${marker} is missing, so ${release} is not a release Harbor staged: reinstall with sudo ./bin/harbor bootstrap from a clean trusted checkout at an exact release tag"
  fi
  marker_tag="$(sed -n 's/^tag=//p' "${marker}" | sed -n '1p')"
  if [ "${marker_tag}" != "${tag}" ]; then
    harbor_die 3 entrypoint.release_tag \
      "${marker} names tag '${marker_tag}' but its own directory is ${tag}, so this release is not what its path claims: reinstall with sudo ./bin/harbor bootstrap from a clean trusted checkout at an exact release tag"
  fi
  state_root="${record%/*}"
  [ -n "${state_root}" ] || state_root="/"
  if [ ! -e "${record}" ] && [ ! -L "${record}" ]; then
    case "${cmd}" in
      bootstrap | journal-resolve)
        harbor_log entrypoint "${record} is absent: ${cmd} defers the record equality check for ${tag}"
        return 0
        ;;
    esac
    if [ -d "${state_root}" ]; then
      harbor_die 3 entrypoint.record_absent \
        "${record} is absent while ${state_root} exists, so this node has no completed bootstrap to run against: run sudo harbor bootstrap"
    fi
    harbor_die 3 entrypoint.record_absent \
      "${record} is absent and ${state_root} does not exist, so there is no bootstrapped node here: run sudo ./bin/harbor bootstrap from a clean trusted checkout at an exact release tag"
  fi
  if ! recorded="$(harbor_entrypoint_record_tag "${record}")"; then
    harbor_die 3 entrypoint.record_unreadable \
      "${record} exists but records no release tag, so Harbor cannot tell whether ${tag} is the recorded release: inspect it by hand"
  fi
  [ "${recorded}" != "${tag}" ] || return 0
  case "${cmd}" in
    bootstrap | journal-resolve)
      harbor_log entrypoint "${record} records ${recorded}: ${cmd} defers the record equality check for ${tag}"
      return 0
      ;;
  esac
  harbor_die 3 entrypoint.record_mismatch \
    "the executing release is ${tag} but ${record} records ${recorded}: either a system upgrade was interrupted after switching the entrypoint and before rewriting the record, or a node-level teardown was interrupted while its reverse walk had restored the entrypoint symlink to an earlier release, which is the case whose reverted symlink entry stands in the root journal; tell them apart with sudo harbor journal list, then resume the upgrade with sudo harbor upgrade --system --from <checkout> from a checkout at ${tag}, which fails closed naming the missing proof when an upgrade is not what was interrupted, or finish the teardown with sudo harbor teardown --level node; sudo harbor bootstrap ends either one by rewriting the record to ${tag}"
}
# The flag binding (design section 5.2, "Flag binding") and the harbor-install proof
# the two deferral forms above owe. Unlike the check above, the functions below read
# and write the root journal, so they additionally depend on lib/journal.sh and, through
# it, on the lock ownership assertion of lib/lock.sh: the caller has already resolved
# the executing release with harbor_entrypoint_check, created the state root, acquired
# the root lock, and run journal recovery before it calls any of them, which is the
# earliest point at which the journal is decided and therefore the earliest point at
# which either can be judged. Both run before any mutation of the node.
# harbor_bootstrap_flags_key_path PATH: PATH spelled canonically, so two spellings of
# one key source render one flag set. The directory is canonicalized with cd -P and
# pwd -P, which settles . and .., a repeated or trailing slash, a relative spelling, and
# a symlinked ancestor; the leaf is kept as spelled and a leaf symlink is not followed,
# because what the set records is the path the administrator named, and the Authorized
# key step of design section 5.2 judges what it finds there by the journaled hash rather
# than by the path alone. The directory must exist, since the path is canonicalized
# through it; a source whose directory is absent is refused rather than recorded as
# written, because a path Harbor cannot resolve is a path it cannot compare.
harbor_bootstrap_flags_key_path() {
  local path="${1}" dir base canon
  case "${path}" in
    "" | */)
      harbor_die 3 flags.key_source "'${path}' does not name an authorized-key file"
      ;;
    */*)
      dir="${path%/*}"
      base="${path##*/}"
      ;;
    *)
      dir="."
      base="${path}"
      ;;
  esac
  [ -n "${dir}" ] || dir="/"
  case "${base}" in
    . | ..) harbor_die 3 flags.key_source "'${path}' names a directory, not an authorized-key file" ;;
  esac
  if ! canon="$(cd -P -- "${dir}" 2>/dev/null && pwd -P)"; then
    harbor_die 3 flags.key_source \
      "the directory of the authorized-key source '${path}' does not exist, so Harbor cannot resolve which file this run's intent names"
  fi
  case "${canon}" in
    /) printf '/%s' "${base}" ;;
    *) printf '%s/%s' "${canon}" "${base}" ;;
  esac
}
# harbor_bootstrap_flags_word VALUE LABEL: VALUE must be one non-empty word. The
# normalized set is one line of space-separated fields, so a value carrying a space, a
# tab, or a newline could not be read back out of it field by field; Harbor refuses to
# record an intent it could not later print back beside another run's rather than record
# an ambiguous one. No Ubuntu account name can carry whitespace either.
harbor_bootstrap_flags_word() {
  case "${1}" in
    "") harbor_die 3 flags.empty "${2} is empty, and the flag set records it" ;;
    *[[:space:]]*)
      harbor_die 3 flags.whitespace \
        "${2} '${1}' carries whitespace, which the one-line flag set cannot record unambiguously"
      ;;
  esac
}
# harbor_bootstrap_flags_normalize OPERATOR KEY_SOURCE [FLAG...]: the security-relevant
# intent of a bootstrap run as one canonical line: the operator name, the resolved
# authorized-key source path, and whether each of --tailscale-ssh, --allow-lan-ssh,
# --harden-sshd, --adopt-firewall, and --adopt-tailscale was given. Canonical means one
# rendering per intent. The fields are printed in one fixed order that owes nothing to
# the order the flags were given in, and each flag contributes exactly yes or no whether
# it was given once, twice, or not at all, so no reordering and no repetition can change
# the line; the key path is canonicalized, so no respelling of one path can either; and
# every field is printed whether or not it was given, so no two intents share a
# rendering. A flag outside the five is refused rather than ignored, because a set
# silently missing a flag would bind every later run to a posture no run asked for.
harbor_bootstrap_flags_normalize() {
  local operator key flag
  local tailscale_ssh=no allow_lan_ssh=no harden_sshd=no adopt_firewall=no adopt_tailscale=no
  if [ "$#" -lt 2 ]; then
    harbor_die 3 usage "usage: harbor_bootstrap_flags_normalize <operator> <authorized-key-source> [flag...]"
  fi
  operator="${1}"
  key="${2}"
  shift 2
  harbor_bootstrap_flags_word "${operator}" "the operator name"
  for flag in ${1+"$@"}; do
    case "${flag}" in
      --tailscale-ssh) tailscale_ssh=yes ;;
      --allow-lan-ssh) allow_lan_ssh=yes ;;
      --harden-sshd) harden_sshd=yes ;;
      --adopt-firewall) adopt_firewall=yes ;;
      --adopt-tailscale) adopt_tailscale=yes ;;
      *)
        harbor_die 3 flags.unknown \
          "'${flag}' is not one of the flags the bootstrap flag set records (--tailscale-ssh, --allow-lan-ssh, --harden-sshd, --adopt-firewall, --adopt-tailscale), and an unrecorded flag would leave the recorded intent silently short of what was asked for"
        ;;
    esac
  done
  key="$(harbor_bootstrap_flags_key_path "${key}")" || exit "$?"
  harbor_bootstrap_flags_word "${key}" "the authorized-key source path"
  printf 'operator=%s authorized-key-source=%s adopt-firewall=%s adopt-tailscale=%s allow-lan-ssh=%s harden-sshd=%s tailscale-ssh=%s\n' \
    "${operator}" "${key}" "${adopt_firewall}" "${adopt_tailscale}" "${allow_lan_ssh}" \
    "${harden_sshd}" "${tailscale_ssh}"
}
# harbor_bootstrap_flags_field SET NAME: the value of the NAME field of SET, so a run's
# own set and the recorded one can be printed field beside field. No field value carries
# whitespace, so the fields of the line are its words.
harbor_bootstrap_flags_field() {
  printf '%s\n' "${1}" | awk -v k="${2}=" '{ for (i = 1; i <= NF; i++) if (index($i, k) == 1) { print substr($i, length(k) + 1); exit } }'
}
# harbor_observe_op_bootstrap_flags TARGET: the observer harbor_journal_observe
# dispatches to for a bootstrap-flags entry, defined here because the library that emits
# an op owns its observer and an op with none is unrecoverable (design section 3.7). A
# bootstrap-flags entry records the intent a run was given, not an artifact: there is
# nothing on disk whose observation could equal its pre_state or its post_state, and the
# entry itself is not evidence about itself. So the truthful answer is that intent is
# unobservable, and it is a different answer from the "unobservable:<op>" of an op whose
# library is simply not loaded in this process. Harbor writes this entry directly
# applied, so recovery, which scans prepared entries only, never asks; an entry of this
# op found prepared can only come from a forged or hand-edited journal, and this answer
# makes it undecidable, so recovery refuses to continue and prints it rather than guess a
# phase for an intent no observation can settle. Inspection only.
harbor_observe_op_bootstrap_flags() {
  printf '"unobservable:intent"'
}
# harbor_bootstrap_flags_recorded STATE_ROOT: the flag set the newest applied
# bootstrap-flags entry records, empty when the journal holds none. That set is the
# entry's target, the intent being what such an entry is about.
harbor_bootstrap_flags_recorded() {
  local root="${1}" entry flags=""
  for entry in "${root}"/journal/[0-9][0-9][0-9][0-9]-bootstrap-flags.json; do
    [ -e "${entry}" ] || continue
    [ "$(harbor_journal_string "${entry}" phase)" = "applied" ] || continue
    flags="$(harbor_journal_string "${entry}" target)"
  done
  printf '%s' "${flags}"
}
# harbor_bootstrap_flags_bind STATE_ROOT SET: bind this run to the intent of the first
# one (design section 5.2). With no applied bootstrap-flags entry in the journal this is
# the first run: SET is journaled as one, ownership observed because it mutates nothing,
# created directly applied with no prepared window, as design section 3.7 requires of an
# entry that mutates nothing and as recovery, which can never decide an intent, needs.
# The caller calls this before it journals or mutates anything else, so the entry is the
# journal's first and the intent is recorded before the first mutation and long before
# bootstrap.json exists. With one recorded, this run's set must equal it: an equal set
# proceeds and writes nothing new, and a differing one exits 3 having mutated nothing,
# printing the recorded value beside this run's for each field that differs, which for a
# recovery run by another administrator is the recorded key path it must be rerun with.
harbor_bootstrap_flags_bind() {
  local root flags recorded field label mine theirs state recorded_key
  if [ "$#" -ne 2 ]; then
    harbor_die 3 usage "usage: harbor_bootstrap_flags_bind <state-root> <normalized-flag-set>"
  fi
  root="${1}"
  flags="${2}"
  recorded="$(harbor_bootstrap_flags_recorded "${root}")"
  if [ -z "${recorded}" ]; then
    state="{\"flags\":\"$(harbor_json_escape "${flags}")\"}"
    harbor_journal_create "${root}" bootstrap-flags "${flags}" observed applied "${state}" "${state}"
    harbor_step bootstrap-flags
    harbor_log bootstrap "recorded the flag set of this run: ${flags}"
    return 0
  fi
  if [ "${recorded}" = "${flags}" ]; then
    harbor_log bootstrap "this run's flag set equals the recorded one: ${flags}"
    return 0
  fi
  harbor_msg "this run's flag set differs from the one the first bootstrap of this node recorded, so nothing was mutated:"
  for field in operator authorized-key-source adopt-firewall adopt-tailscale allow-lan-ssh harden-sshd tailscale-ssh; do
    mine="$(harbor_bootstrap_flags_field "${flags}" "${field}")"
    theirs="$(harbor_bootstrap_flags_field "${recorded}" "${field}")"
    [ "${mine}" != "${theirs}" ] || continue
    case "${field}" in
      operator | authorized-key-source) label="${field}" ;;
      *) label="--${field}" ;;
    esac
    harbor_msg "  ${label}: this run ${mine}, recorded ${theirs}"
  done
  recorded_key="$(harbor_bootstrap_flags_field "${recorded}" authorized-key-source)"
  harbor_die 3 flags.mismatch \
    "every later bootstrap run must carry the intent the first one recorded, so this run finished no posture it did not intend and applied none it did not either: rerun with the recorded values, which for a recovery run by another administrator, whose own account resolves another key path, means --authorized-key-file ${recorded_key}; changing the flag set of a bootstrapped node is not a rerun, so run sudo harbor teardown --level node and bootstrap again with the new flags"
}
# harbor_entrypoint_install_proof STATE_ROOT RELEASE: the proof the record-less and the
# mismatch deferral forms of harbor_entrypoint_check additionally owe (design section
# 5.2). Both forms let a run proceed against a release bootstrap.json does not vouch for,
# so the root journal has to: RELEASE must be the target of an applied harbor-install
# entry, which only Harbor writes, into a root-only journal, about a root-owned tree with
# the installed modes, so the code such a run executes is code Harbor installed and no
# operator can forge the proof. A journal holding none, or holding one that a teardown's
# reverse walk has already marked reverted, exits 3 naming the reinstall and, since that
# reinstall meets the release directory as an orphan under the section 5.2 rule and
# removes nothing it cannot prove it created, what the administrator must clear by hand
# first. Read-only: it takes no lock, writes nothing, and touches no artifact.
harbor_entrypoint_install_proof() {
  local root release entry phase proven="" newest=""
  if [ "$#" -ne 2 ]; then
    harbor_die 3 usage "usage: harbor_entrypoint_install_proof <state-root> <release>"
  fi
  root="${1}"
  release="${2}"
  for entry in "${root}"/journal/[0-9][0-9][0-9][0-9]-harbor-install.json; do
    [ -e "${entry}" ] || continue
    [ "$(harbor_journal_string "${entry}" target)" = "${release}" ] || continue
    phase="$(harbor_journal_string "${entry}" phase)"
    newest="${phase}"
    [ "${phase}" != "applied" ] || proven=yes
  done
  if [ -n "${proven}" ]; then
    harbor_log entrypoint "${release} is proven by an applied harbor-install entry in ${root}/journal"
    return 0
  fi
  if [ "${newest}" = "reverted" ]; then
    harbor_die 3 entrypoint.install_reverted \
      "the harbor-install entry for ${release} in ${root}/journal is reverted, so the root journal records that release as unwound rather than installed, which is what a node-level teardown leaves behind: finish that teardown with sudo harbor teardown --level node, or reinstall with sudo ./bin/harbor bootstrap from a clean trusted checkout at an exact release tag, which meets ${release} as an orphan and removes nothing, so confirm nothing of yours is inside it and remove it, and any /usr/local/bin/harbor pointing into it, by hand first"
  fi
  harbor_die 3 entrypoint.install_proof \
    "${root}/journal holds no applied harbor-install entry for ${release}, so Harbor cannot prove it installed the release it is executing and will not defer bootstrap.json's judgement to code it cannot vouch for: reinstall with sudo ./bin/harbor bootstrap from a clean trusted checkout at an exact release tag, which meets ${release} as an orphan and removes nothing, so confirm nothing of yours is inside it and remove it, and any /usr/local/bin/harbor pointing into it, by hand first"
}
