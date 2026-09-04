#!/bin/bash
# Root bootstrap (design section 5.2): the preflight of that section's table, in the
# table's order, then the bootstrap-flags intent entry, the install-Harbor step, the
# release of the root lock, and the exec of the installed entrypoint with the original
# arguments. Every check refuses by naming the value or the path that is wrong and the
# command that fixes it, and none is skipped or reordered: the order is the order in
# which nothing is touched before whatever would touch it has been proved sound, so a
# refusal below the first mutation is a refusal that mutated nothing.
#
# The dispatcher sources this file with the bootstrap arguments, so bin/harbor keeps no
# logic of its own and an installed release never relies on node/bootstrap.sh being an
# executable file: it is 0644 there, like every other ordinary file of a release
# (design section 5.2, "Installed entrypoint"). Running it directly, which is what the
# unit lane does, behaves identically, so this file sources the libraries it uses
# rather than assuming the dispatcher's set, as bin/harbor sources neither
# lib/checkout.sh, lib/release.sh, lib/entrypoint.sh, lib/ssh.sh, nor lib/user.sh.
# Sourcing a library twice defines its functions twice and changes nothing else.
#
# This script runs on Ubuntu only and may use bash 5, but it is written in the same
# bash 3.2 subset every lib/ file uses, so the unit lane can run it on the pinned
# macOS runner under /bin/bash 3.2, which is where the fixture paths below are proved.
#
# Fixture injection (design section 7): the production paths, the machine
# architecture, the executing path, whether the caller is root, and the exec itself
# are read from HARBOR_BOOTSTRAP_FIXTURE_* only when id -u is not 0, exactly as
# lib/checkout.sh, lib/entrypoint.sh, and lib/ssh.sh read their own stand-ins. Root,
# the only principal that may run bootstrap, therefore never sees one; and a caller
# that is not root gains nothing from them, since every path it can name is a path it
# could already write and every library below still applies its own rules to whatever
# it finds there.
set -euo pipefail
LC_ALL=C
export LC_ALL
HARBOR_ROOT="${HARBOR_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)}"
export HARBOR_ROOT
# shellcheck source=../lib/log.sh
. "${HARBOR_ROOT}/lib/log.sh"
# shellcheck source=../lib/versions.sh
. "${HARBOR_ROOT}/lib/versions.sh"
# shellcheck source=../lib/lock.sh
. "${HARBOR_ROOT}/lib/lock.sh"
# shellcheck source=../lib/journal.sh
. "${HARBOR_ROOT}/lib/journal.sh"
# shellcheck source=../lib/checkout.sh
. "${HARBOR_ROOT}/lib/checkout.sh"
# shellcheck source=../lib/release.sh
. "${HARBOR_ROOT}/lib/release.sh"
# shellcheck source=../lib/entrypoint.sh
. "${HARBOR_ROOT}/lib/entrypoint.sh"
# shellcheck source=../lib/ssh.sh
. "${HARBOR_ROOT}/lib/ssh.sh"
# shellcheck source=../lib/user.sh
. "${HARBOR_ROOT}/lib/user.sh"
# shellcheck source=../lib/apt.sh
. "${HARBOR_ROOT}/lib/apt.sh"
# shellcheck source=../lib/node.sh
. "${HARBOR_ROOT}/lib/node.sh"
# shellcheck source=../lib/firewall.sh
. "${HARBOR_ROOT}/lib/firewall.sh"
# shellcheck source=../lib/power.sh
. "${HARBOR_ROOT}/lib/power.sh"
# The operator account of design section 5.2 when --operator names none.
HARBOR_BOOTSTRAP_DEFAULT_OPERATOR=harbor
# The Packages row of the design section 5.2 table, in the table's order. The list
# belongs here rather than in lib/apt.sh, which names no package of its own.
HARBOR_BOOTSTRAP_PACKAGES="git curl ufw jq openssh-server ca-certificates"
HARBOR_BOOTSTRAP_FLAGS=()
harbor_bootstrap_usage() {
  cat <<'USAGE'
usage: sudo harbor bootstrap [--operator NAME] [--authorized-key-file PATH]
                             [--tailscale-ssh] [--allow-lan-ssh] [--harden-sshd]
                             [--adopt-firewall] [--adopt-tailscale]

Run as root from a clean trusted checkout at an exact release tag
(sudo ./bin/harbor bootstrap) on a fresh node, or from the installed entrypoint
(sudo harbor bootstrap) afterwards.
USAGE
}
# harbor_bootstrap_machine_arch: the architecture in the name Ubuntu's package tools
# use, which is the name the refusal has to print. uname is the kernel's own answer
# and belongs to no vendor, so it needs no adapter of its own; lib/lock.sh reads
# uname -s and uname -n directly for the same reason. An architecture Harbor does not
# support is printed as the kernel spells it rather than translated, so the message
# names what this node really is.
harbor_bootstrap_machine_arch() {
  local machine
  machine="$(uname -m)" \
    || harbor_die 3 bootstrap.architecture "uname -m failed, so Harbor cannot tell which architecture this node is; Harbor bootstraps amd64 only"
  [ -n "${machine}" ] \
    || harbor_die 3 bootstrap.architecture "uname -m printed nothing, so Harbor cannot tell which architecture this node is; Harbor bootstraps amd64 only"
  case "${machine}" in
    x86_64 | amd64) printf 'amd64' ;;
    *) printf '%s' "${machine}" ;;
  esac
}
# harbor_bootstrap_bind ARGV0: the paths, the architecture, the principal, and the
# exec seam this run judges. Production values are assigned first and unconditionally;
# the fixture stand-ins are read afterwards under one gate, and only when the caller is
# not root, which is the gate lib/entrypoint.sh already applies to its own install root
# and trusted owner and lib/ssh.sh to its home root.
harbor_bootstrap_bind() {
  HARBOR_BOOTSTRAP_ARGV0="${1}"
  HARBOR_BOOTSTRAP_OS_RELEASE="/etc/os-release"
  HARBOR_BOOTSTRAP_STATE_ROOT="/var/lib/harbor"
  HARBOR_BOOTSTRAP_INSTALL_ROOT="/usr/local/lib/harbor"
  HARBOR_BOOTSTRAP_LINK="/usr/local/bin/harbor"
  # The Node.js prefix of design section 2 and the configuration root both the sshd
  # and the logind drop-ins are written under. lib/node.sh, lib/ssh.sh, and
  # lib/power.sh all take theirs as a parameter and name no absolute path of their
  # own, so these two are where the production paths of those rows are decided. The
  # bin directory of the four Node.js symlinks is not a value of its own: it is the
  # directory the entrypoint link already lives in, so the two can never disagree.
  HARBOR_BOOTSTRAP_NODE_PREFIX="/opt/harbor/node"
  HARBOR_BOOTSTRAP_ETC="/etc"
  HARBOR_BOOTSTRAP_ARCH="$(harbor_bootstrap_machine_arch)" || exit "$?"
  HARBOR_BOOTSTRAP_EXEC_LOG=""
  HARBOR_BOOTSTRAP_IS_ROOT=no
  if [ "$(id -u)" = 0 ]; then
    HARBOR_BOOTSTRAP_IS_ROOT=yes
    return 0
  fi
  HARBOR_BOOTSTRAP_ARGV0="${HARBOR_BOOTSTRAP_FIXTURE_ARGV0:-${HARBOR_BOOTSTRAP_ARGV0}}"
  HARBOR_BOOTSTRAP_OS_RELEASE="${HARBOR_BOOTSTRAP_FIXTURE_OS_RELEASE:-${HARBOR_BOOTSTRAP_OS_RELEASE}}"
  HARBOR_BOOTSTRAP_STATE_ROOT="${HARBOR_BOOTSTRAP_FIXTURE_STATE_ROOT:-${HARBOR_BOOTSTRAP_STATE_ROOT}}"
  HARBOR_BOOTSTRAP_INSTALL_ROOT="${HARBOR_BOOTSTRAP_FIXTURE_INSTALL_ROOT:-${HARBOR_BOOTSTRAP_INSTALL_ROOT}}"
  HARBOR_BOOTSTRAP_LINK="${HARBOR_BOOTSTRAP_FIXTURE_LINK:-${HARBOR_BOOTSTRAP_LINK}}"
  HARBOR_BOOTSTRAP_NODE_PREFIX="${HARBOR_BOOTSTRAP_FIXTURE_NODE_PREFIX:-${HARBOR_BOOTSTRAP_NODE_PREFIX}}"
  HARBOR_BOOTSTRAP_ETC="${HARBOR_BOOTSTRAP_FIXTURE_ETC:-${HARBOR_BOOTSTRAP_ETC}}"
  HARBOR_BOOTSTRAP_ARCH="${HARBOR_BOOTSTRAP_FIXTURE_ARCH:-${HARBOR_BOOTSTRAP_ARCH}}"
  HARBOR_BOOTSTRAP_EXEC_LOG="${HARBOR_BOOTSTRAP_FIXTURE_EXEC:-}"
  # The one stand-in that is not a path: a caller that is not root may run the ordered
  # preflight against its own fixture node. It grants nothing, because every path such
  # a run reaches is a fixture path it already owns, and it is invisible to root.
  [ "${HARBOR_BOOTSTRAP_FIXTURE_ROOT:-0}" != 1 ] || HARBOR_BOOTSTRAP_IS_ROOT=yes
}
harbor_bootstrap_parse() {
  local arg
  HARBOR_BOOTSTRAP_OPERATOR="${HARBOR_BOOTSTRAP_DEFAULT_OPERATOR}"
  HARBOR_BOOTSTRAP_KEY_FILE=""
  HARBOR_BOOTSTRAP_FLAGS=()
  while [ "$#" -gt 0 ]; do
    arg="${1}"
    case "${arg}" in
      --operator)
        [ "$#" -ge 2 ] \
          || harbor_die 3 bootstrap.usage "--operator names the unprivileged account Harbor creates for the agents and was given no value: rerun with --operator NAME, or omit it for ${HARBOR_BOOTSTRAP_DEFAULT_OPERATOR}"
        HARBOR_BOOTSTRAP_OPERATOR="${2}"
        shift 2
        ;;
      --authorized-key-file)
        [ "$#" -ge 2 ] \
          || harbor_die 3 bootstrap.usage "--authorized-key-file names the authorized_keys file the operator's key is copied from and was given no value: rerun with --authorized-key-file PATH, or omit it to use the invoking administrator's own"
        HARBOR_BOOTSTRAP_KEY_FILE="${2}"
        shift 2
        ;;
      --tailscale-ssh | --allow-lan-ssh | --harden-sshd | --adopt-firewall | --adopt-tailscale)
        HARBOR_BOOTSTRAP_FLAGS+=("${arg}")
        shift
        ;;
      *)
        harbor_bootstrap_usage >&2
        harbor_die 3 bootstrap.usage "'${arg}' is not one of the bootstrap flags above"
        ;;
    esac
  done
}
# harbor_bootstrap_os_release_field FILE KEY: the value os-release records for KEY,
# the shell quoting Ubuntu writes around it stripped. A read that fails refuses rather
# than answering empty: an /etc/os-release Harbor cannot read is not a node whose
# release it may guess.
harbor_bootstrap_os_release_field() {
  local file="${1}" key="${2}" value
  value="$(sed -n "s/^${key}=//p" "${file}" | sed -n 1p)" \
    || harbor_die 3 bootstrap.os_release "${file} cannot be read, so Harbor cannot tell which release this node is; Harbor bootstraps Ubuntu only"
  value="${value%\"}"
  value="${value#\"}"
  value="${value%\'}"
  value="${value#\'}"
  printf '%s' "${value}"
}
# Preflight 1 (design section 5.2): /etc/os-release reports the locked release, and the
# node is amd64. First, because every later check and every message below is written
# for that one platform, and because it is the one refusal an operator can act on
# without Harbor having read anything else.
harbor_bootstrap_check_os_release() {
  local file="${1}" want="${2}" arch="${3}" id version
  [ -e "${file}" ] \
    || harbor_die 3 bootstrap.os_release "${file} does not exist, so Harbor cannot tell which distribution this node runs; Harbor bootstraps Ubuntu ${want} amd64 only"
  [ -f "${file}" ] \
    || harbor_die 3 bootstrap.os_release "${file} is not an ordinary file, so Harbor cannot tell which distribution this node runs; Harbor bootstraps Ubuntu ${want} amd64 only"
  [ -r "${file}" ] \
    || harbor_die 3 bootstrap.os_release "${file} cannot be read, so Harbor cannot tell which distribution this node runs; Harbor bootstraps Ubuntu ${want} amd64 only"
  id="$(harbor_bootstrap_os_release_field "${file}" ID)" || exit "$?"
  version="$(harbor_bootstrap_os_release_field "${file}" VERSION_ID)" || exit "$?"
  [ "${id}" = ubuntu ] \
    || harbor_die 3 bootstrap.os_release "${file} reports ID '${id}', not ubuntu; Harbor bootstraps Ubuntu ${want} amd64 only, so install that release on this node or bootstrap another node"
  [ "${version}" = "${want}" ] \
    || harbor_die 3 bootstrap.os_release "${file} reports VERSION_ID '${version}', not the ${want} that ${HARBOR_VERSIONS_FILE} locks; Harbor bootstraps Ubuntu ${want} amd64 only, so install that release on this node or bootstrap another node"
  [ "${arch}" = amd64 ] \
    || harbor_die 3 bootstrap.architecture "this node is ${arch}, not amd64; the pinned Node.js and Tailscale builds of ${HARBOR_VERSIONS_FILE} are amd64, so Harbor bootstraps amd64 only"
}
# Preflight 2 (design section 5.2): root, with a valid SUDO_USER or an explicit
# --authorized-key-file. Before this returns, nothing has been read that is not
# world-readable and nothing at all has been written, which is what "refuse anything
# but root before it touches state" means.
harbor_bootstrap_check_principal() {
  local key_file="${1}"
  [ "${HARBOR_BOOTSTRAP_IS_ROOT}" = yes ] \
    || harbor_die 3 bootstrap.not_root "harbor bootstrap creates the root-owned state of design section 5.2 and must run as root: rerun it as sudo ./bin/harbor bootstrap from a clean trusted checkout at an exact release tag, or as sudo harbor bootstrap once this node is installed"
  # With --authorized-key-file the administrator has named the key source outright, so
  # no SUDO_USER is needed; without it the only source Harbor will ever take a key from
  # is the account that invoked sudo (design section 3.5), and it must be a real
  # non-root account, so a run that has neither is refused here rather than at the
  # authorized-key step, after the node has been mutated.
  [ -z "${key_file}" ] || return 0
  [ -n "${SUDO_USER:-}" ] \
    || harbor_die 3 bootstrap.no_sudo_user "there is no SUDO_USER, so Harbor has no administrator account to copy the operator's authorized key from and never guesses one: rerun through sudo from your own account, or pass --authorized-key-file PATH"
  [ "${SUDO_USER}" != root ] \
    || harbor_die 3 bootstrap.sudo_user_root "SUDO_USER is root, which is not the non-root local account design section 3.5 takes the operator's authorized key from: rerun through sudo from your own account, or pass --authorized-key-file PATH"
}
# Preflight 4 (design section 5.2): the checkout rules of design section 5.1 for a run
# from a checkout, the installed-entrypoint check for a run from an installed release.
# Which one applies is decided by where the executing path really is, never by what the
# caller spelled: the canonical path of the script bash is running sits directly under
# the install root as <tag>/bin/harbor, or it does not. Sets the form, the release
# directory, the tag, and, for a checkout, the checkout root and the commit its tag
# resolved to at the moment the rules approved it.
harbor_bootstrap_check_source() {
  local argv0="${1}" operator="${2}" record="${3}"
  local resolved bindir release parent canon recorded
  HARBOR_BOOTSTRAP_CHECKOUT=""
  HARBOR_BOOTSTRAP_COMMIT=""
  HARBOR_BOOTSTRAP_DEFERRED=no
  # The install root is canonicalized once, here, so the comparison below and every
  # path derived from it afterwards are in the same spelling as the resolved path. An
  # install root that does not exist yet stays as written and matches nothing, which is
  # what a first run from a checkout should find.
  if canon="$(cd -P -- "${HARBOR_BOOTSTRAP_INSTALL_ROOT}" 2>/dev/null && pwd -P)"; then
    HARBOR_BOOTSTRAP_INSTALL_ROOT="${canon}"
  fi
  resolved="$(harbor_entrypoint_resolve "${argv0}")" || exit "$?"
  bindir="${resolved%/*}"
  release="${bindir%/*}"
  [ -n "${release}" ] || release="/"
  parent="${release%/*}"
  [ -n "${parent}" ] || parent="/"
  if [ "${parent}" = "${HARBOR_BOOTSTRAP_INSTALL_ROOT}" ] && [ "${bindir##*/}" = bin ]; then
    HARBOR_BOOTSTRAP_FORM=entrypoint
    HARBOR_BOOTSTRAP_RELEASE="${release}"
    HARBOR_BOOTSTRAP_TAG="${release##*/}"
    # Every path, ownership, and mode rule in full; only the record equality clause is
    # deferred, and only in the two forms bootstrap owns. Whether it deferred is what
    # decides below whether this run additionally owes the harbor-install proof, which
    # can be judged no earlier than under the lock with recovery run.
    harbor_entrypoint_check "${argv0}" "${record}" bootstrap
    if [ ! -e "${record}" ] && [ ! -L "${record}" ]; then
      HARBOR_BOOTSTRAP_DEFERRED=yes
      harbor_log bootstrap "the record-less form: ${record} is absent, so this run owes the harbor-install proof for ${release}"
    elif recorded="$(harbor_entrypoint_record_tag "${record}")" \
      && [ "${recorded}" != "${HARBOR_BOOTSTRAP_TAG}" ]; then
      HARBOR_BOOTSTRAP_DEFERRED=yes
      harbor_log bootstrap "the mismatch form: ${record} records ${recorded}, so this run owes the harbor-install proof for ${release}"
    fi
    return 0
  fi
  HARBOR_BOOTSTRAP_FORM=checkout
  HARBOR_BOOTSTRAP_CHECKOUT="$(harbor_checkout_root_from_argv0 "${argv0}")" || exit "$?"
  harbor_checkout_trusted "${HARBOR_BOOTSTRAP_CHECKOUT}" "${operator}"
  HARBOR_BOOTSTRAP_TAG="$(harbor_checkout_tag "${HARBOR_BOOTSTRAP_CHECKOUT}")" || exit "$?"
  # The rules above proved the work tree clean and HEAD exactly at that tag. HEAD is
  # resolved to an object here, while that proof is fresh, so what the install step
  # stages further down is the commit this preflight approved rather than whatever two
  # mutable refs resolve to by then.
  HARBOR_BOOTSTRAP_COMMIT="$(harbor_git "${HARBOR_BOOTSTRAP_CHECKOUT}" rev-parse "HEAD^{commit}")" \
    || harbor_die 3 bootstrap.checkout_commit "HEAD of ${HARBOR_BOOTSTRAP_CHECKOUT} does not resolve to a commit, so Harbor cannot tell which object the tag ${HARBOR_BOOTSTRAP_TAG} it just verified names; nothing was written, check the checkout with git -C ${HARBOR_BOOTSTRAP_CHECKOUT} status and rerun"
  harbor_log bootstrap "the checkout rules approved ${HARBOR_BOOTSTRAP_COMMIT} at ${HARBOR_BOOTSTRAP_TAG} in ${HARBOR_BOOTSTRAP_CHECKOUT}"
  HARBOR_BOOTSTRAP_RELEASE="${HARBOR_BOOTSTRAP_INSTALL_ROOT}/${HARBOR_BOOTSTRAP_TAG}"
}
# Preflight 7 (design section 5.2): the journal exists, or the record is absent too. A
# state root holding bootstrap.json without a journal is the lost-journal state of
# design section 5.7, in which Harbor can prove nothing about what it installed, so it
# refuses rather than starting a fresh journal beside a record of work it cannot see.
harbor_bootstrap_check_journal_present() {
  local root="${1}"
  [ ! -d "${root}/journal" ] || return 0
  [ -e "${root}/bootstrap.json" ] || [ -L "${root}/bootstrap.json" ] || return 0
  harbor_die 3 bootstrap.lost_journal "${root}/bootstrap.json records a bootstrapped node but ${root}/journal is gone, so Harbor cannot tell what it owns here and will neither invert nor overwrite work it cannot see: this is the lost-journal state of design section 5.7, so follow docs/runbook.md for it, which has you confirm what Harbor installed and remove ${root} by hand before bootstrapping again"
}
# Preflight 10 (design section 5.2): /usr/local/bin/harbor is absent, or is a symlink
# resolving to an existing release bin/harbor under the install root. Anything else is
# foreign and is named for manual inspection and removal, because Harbor removes
# nothing it cannot prove it created. The link's own integrity is judged nowhere else
# in a bootstrap run: the install step below writes it, and this is the check that
# says it may.
harbor_bootstrap_check_link() {
  local link="${1}" libroot="${2}" target
  if [ ! -e "${link}" ] && [ ! -L "${link}" ]; then
    return 0
  fi
  [ -L "${link}" ] \
    || harbor_die 3 bootstrap.link_foreign "${link} is already there and is not a symlink, so it is not the entrypoint Harbor installs and Harbor removes nothing it cannot prove it created: inspect it, remove it by hand if it is not needed, and rerun"
  target="$(readlink "${link}")" \
    || harbor_die 3 bootstrap.link_foreign "${link} is a symlink whose target Harbor cannot read, so it cannot tell whether it points into ${libroot}: inspect it, remove it by hand if it is not needed, and rerun"
  harbor_release_link_owned "${target}" "${libroot}" \
    || harbor_die 3 bootstrap.link_foreign "${link} points at ${target}, which is not a path under ${libroot}/, so it is not a Harbor release entrypoint: inspect it, remove it by hand if it is not needed, and rerun"
  case "${target}" in
    */bin/harbor) ;;
    *) harbor_die 3 bootstrap.link_foreign "${link} points at ${target}, which is not the bin/harbor of a release: inspect it, remove it by hand if it is not needed, and rerun" ;;
  esac
  [ -f "${target}" ] \
    || harbor_die 3 bootstrap.link_foreign "${link} points at ${target}, which does not exist, so the release it names is gone: confirm nothing of yours is left under ${libroot}, remove ${link} by hand, and rerun"
}
# The ordered preflight of the design section 5.2 table, and with it the state root,
# the lock, journal recovery, and the bootstrap-flags entry, which are where that
# order says they are. Nothing before the state root writes anything at all.
harbor_bootstrap_preflight() {
  local record flags release
  # 1. /etc/os-release reports the locked release, and the node is amd64. The locked
  # release is read into a variable of its own rather than substituted into the call,
  # because an unpinned key exits 3 from harbor_version_require, and a substitution
  # would swallow that exit inside its own subshell and hand the check an empty value.
  harbor_versions_load "$(harbor_versions_lock_path)"
  release="$(harbor_version_require ubuntu_release)" || exit "$?"
  harbor_bootstrap_check_os_release "${HARBOR_BOOTSTRAP_OS_RELEASE}" \
    "${release}" "${HARBOR_BOOTSTRAP_ARCH}"
  # 2. root, with a valid SUDO_USER or --authorized-key-file.
  harbor_bootstrap_check_principal "${HARBOR_BOOTSTRAP_KEY_FILE}"
  # 3. The operator is none of root, the invoking SUDO_USER, or a sudo or admin group
  # member. It runs before any Git invocation, so a sudo-capable operator is refused
  # by name rather than by failing every checkout under the ownership rule.
  harbor_user_refuse_sudo_capable "${HARBOR_BOOTSTRAP_OPERATOR}"
  # 4. The checkout rules, or the installed-entrypoint check.
  record="${HARBOR_BOOTSTRAP_STATE_ROOT}/bootstrap.json"
  harbor_bootstrap_check_source "${HARBOR_BOOTSTRAP_ARGV0}" "${HARBOR_BOOTSTRAP_OPERATOR}" "${record}"
  # 5. The state root, created if absent, since the root lock lives in it. This is the
  # first thing a bootstrap run writes, and everything above it refused without
  # writing. The check runs again after the apply (design section 6.1).
  harbor_state_root_create "${HARBOR_BOOTSTRAP_STATE_ROOT}" root
  [ -d "${HARBOR_BOOTSTRAP_STATE_ROOT}" ] \
    || harbor_die 2 bootstrap.state_root "${HARBOR_BOOTSTRAP_STATE_ROOT} is still not a directory after Harbor created it, so the root lock has nowhere to live and nothing further was attempted; check the filesystem it sits on and rerun"
  harbor_log_open "${HARBOR_BOOTSTRAP_STATE_ROOT}/bootstrap.log" 0600
  harbor_log command "bootstrap ${HARBOR_BOOTSTRAP_REDACTED}"
  # 6. The lock parses and is held. harbor_lock_acquire refuses a live holder, a
  # holder record it cannot parse, and a gate a crash left behind, each with the
  # inspection command, and reclaims a provably stale one under that gate.
  harbor_lock_acquire "${HARBOR_BOOTSTRAP_STATE_ROOT}" root
  # 7. journal/ exists, or bootstrap.json is absent too.
  harbor_bootstrap_check_journal_present "${HARBOR_BOOTSTRAP_STATE_ROOT}"
  harbor_journal_init "${HARBOR_BOOTSTRAP_STATE_ROOT}"
  [ -d "${HARBOR_BOOTSTRAP_STATE_ROOT}/journal" ] \
    || harbor_die 2 bootstrap.journal_root "${HARBOR_BOOTSTRAP_STATE_ROOT}/journal is still not a directory after Harbor created it, so no transaction could be recorded and nothing was mutated; check the filesystem it sits on and rerun"
  # 8. Recovery is clean: every prepared entry is decided, or the run refuses with
  # exit 2 and the entry printed beside what it observed.
  harbor_journal_recover "${HARBOR_BOOTSTRAP_STATE_ROOT}"
  harbor_step recovery-scan
  # 8b. The proof the two deferral forms owe, which needs the lock and a recovered
  # journal and so can be judged no earlier than here.
  if [ "${HARBOR_BOOTSTRAP_DEFERRED}" = yes ]; then
    harbor_entrypoint_install_proof "${HARBOR_BOOTSTRAP_STATE_ROOT}" "${HARBOR_BOOTSTRAP_RELEASE}"
  fi
  # 9. The flag binding, and with it the bootstrap-flags entry: this run's normalized
  # set must equal the newest applied one, and on a journal holding none the set is
  # written as that entry, observed and directly applied, before any other entry and
  # before the first mutation of the node.
  # The source resolved here is the one the flag set binds this run to, so the
  # Authorized key row below copies from exactly the path the binding recorded and
  # never resolves a second, possibly different, one of its own.
  HARBOR_BOOTSTRAP_KEY_SOURCE="$(harbor_ssh_source "${HARBOR_BOOTSTRAP_KEY_FILE}")" || exit "$?"
  flags="$(harbor_bootstrap_flags_normalize "${HARBOR_BOOTSTRAP_OPERATOR}" "${HARBOR_BOOTSTRAP_KEY_SOURCE}" \
    ${HARBOR_BOOTSTRAP_FLAGS[@]+"${HARBOR_BOOTSTRAP_FLAGS[@]}"})" || exit "$?"
  harbor_bootstrap_flags_bind "${HARBOR_BOOTSTRAP_STATE_ROOT}" "${flags}"
  # 10. The entrypoint symlink is absent or Harbor's own.
  harbor_bootstrap_check_link "${HARBOR_BOOTSTRAP_LINK}" "${HARBOR_BOOTSTRAP_INSTALL_ROOT}"
}
# The install-Harbor step (design section 5.2), the first controlled operation. From a
# checkout it stages git archive of the verified tag into the release directory and
# points the entrypoint symlink at it, both as journaled transactions of design section
# 3.7. From the installed entrypoint there is no checkout to stage from, so the step is
# the inspection that decides it satisfied: the release must still observe as the tree
# hash its own applied harbor-install entry records, and the symlink must point into it.
harbor_bootstrap_install() {
  local observed recorded
  if [ "${HARBOR_BOOTSTRAP_FORM}" = checkout ]; then
    # What is staged is git archive of the tag the checkout rules verified, never the
    # work tree. Both HEAD and the tag are mutable refs and staging resolves them once
    # more, so the commit those rules approved is passed as the expected commit and
    # staging installs that object or nothing: refs moved together after the preflight
    # would otherwise still agree, on a tree nothing checked.
    harbor_release_stage "${HARBOR_BOOTSTRAP_STATE_ROOT}" "${HARBOR_BOOTSTRAP_CHECKOUT}" \
      "${HARBOR_BOOTSTRAP_TAG}" "${HARBOR_BOOTSTRAP_RELEASE}" "${HARBOR_BOOTSTRAP_COMMIT}"
  else
    observed="$(harbor_observe_op_harbor_install "${HARBOR_BOOTSTRAP_RELEASE}")" || exit "$?"
    recorded="$(harbor_release_applied_state "${HARBOR_BOOTSTRAP_STATE_ROOT}" "${HARBOR_BOOTSTRAP_RELEASE}")"
    [ -n "${recorded}" ] \
      || harbor_die 3 bootstrap.release_unproven "${HARBOR_BOOTSTRAP_RELEASE} is the release this command is executing, but ${HARBOR_BOOTSTRAP_STATE_ROOT}/journal holds no applied harbor-install entry for it, so Harbor cannot prove it installed it and will remove nothing: confirm nothing of yours is inside it, remove it and any ${HARBOR_BOOTSTRAP_LINK} pointing into it by hand, then reinstall with sudo ./bin/harbor bootstrap from a clean trusted checkout at an exact release tag"
    [ "${recorded}" = "${observed}" ] \
      || harbor_die 3 bootstrap.release_changed "${HARBOR_BOOTSTRAP_RELEASE} observes as ${observed}, not the ${recorded} its applied harbor-install entry records, so the release this command is executing has changed since Harbor installed it: confirm nothing of yours is inside it, remove it and any ${HARBOR_BOOTSTRAP_LINK} pointing into it by hand, then reinstall with sudo ./bin/harbor bootstrap from a clean trusted checkout at an exact release tag"
    harbor_log bootstrap "${HARBOR_BOOTSTRAP_RELEASE} is installed and matches its applied harbor-install entry; nothing to stage"
  fi
  harbor_release_link "${HARBOR_BOOTSTRAP_STATE_ROOT}" "${HARBOR_BOOTSTRAP_RELEASE}" \
    "${HARBOR_BOOTSTRAP_LINK}" "${HARBOR_BOOTSTRAP_INSTALL_ROOT}"
}
# The re-exec (design section 5.2): the installed image reruns this command from the
# release Harbor has just installed, so every later mutation runs from the installed
# copy and never from a checkout. It happens only after the root lock is released, so
# the re-exec'd run can acquire it, and the arguments are the ones this run was given,
# passed through unchanged.
harbor_bootstrap_reexec() {
  local link="${1}" arg
  shift
  harbor_step reexec
  harbor_log bootstrap "exec ${link} bootstrap $(harbor_redact_argv ${1+"$@"})"
  if [ -n "${HARBOR_BOOTSTRAP_EXEC_LOG}" ]; then
    # The unit lane's seam, bound above only for a caller that is not root: the argv
    # is recorded one field per line instead of replacing this process, so a test can
    # read exactly the vector production would have exec'd.
    {
      printf '%s\n' "${link}"
      printf '%s\n' bootstrap
      for arg in ${1+"$@"}; do
        printf '%s\n' "${arg}"
      done
    } >"${HARBOR_BOOTSTRAP_EXEC_LOG}" \
      || harbor_die 2 bootstrap.exec_log "cannot write ${HARBOR_BOOTSTRAP_EXEC_LOG}"
    return 0
  fi
  [ -x "${link}" ] \
    || harbor_die 2 bootstrap.exec "${link} is not executable, so the installed image of this command cannot be run; the release is installed and the root lock is released, so fix the mode and rerun sudo harbor bootstrap"
  exec "${link}" bootstrap ${1+"$@"}
}
# harbor_bootstrap_has_flag FLAG: 0 when this run was given FLAG. The parse above
# keeps the flag set exactly as it was given, so this is the one place a row asks
# whether the flag it belongs to is in it.
harbor_bootstrap_has_flag() {
  local want="${1}" flag
  for flag in ${HARBOR_BOOTSTRAP_FLAGS[@]+"${HARBOR_BOOTSTRAP_FLAGS[@]}"}; do
    [ "${flag}" != "${want}" ] || return 0
  done
  return 1
}
# harbor_bootstrap_degraded ID NOTE: one row that reported a precondition rather
# than a failure (exit 1 of design section 6.2). The node is usable and every row
# after it still runs; the run ends with exit 1 and the notes rather than with 0, so
# a caller is never told a degraded node is a finished one. The row has already
# printed the note itself, and it is kept here only to be repeated at the end, where
# it is not buried under the rows that ran after it.
harbor_bootstrap_degraded() {
  HARBOR_BOOTSTRAP_DEGRADED=1
  HARBOR_BOOTSTRAP_NOTES="${HARBOR_BOOTSTRAP_NOTES}  ${1}: ${2}
"
  harbor_log bootstrap "degraded: ${1}: ${2}"
}
# harbor_bootstrap_row NAME STATE: the row about to run and the state this node is
# in while it runs. It emits no step boundary of its own, because every row's
# boundary between its mutation and its applied write is the one its own library
# emits and a second one there would name the same instant twice. What it does set
# is what the ERR trap of lib/log.sh prints when anything inside the row fails: the
# row's name as the failing step, and a next command that says what is already
# applied, what has not been touched, and how to resume.
harbor_bootstrap_row() {
  # Both are read by the ERR trap of lib/log.sh, never in this file.
  # shellcheck disable=SC2034
  HARBOR_CURRENT_STEP="${1}"
  # shellcheck disable=SC2034
  HARBOR_NEXT_COMMAND="${2}; no row after ${1} was attempted, so rerun sudo harbor bootstrap ${HARBOR_BOOTSTRAP_REDACTED} with the same flags once the cause is fixed and it will resume at the first check that still fails"
  harbor_log bootstrap "row ${1}"
}
# The remaining rows of the design section 5.2 table, in the table's order, run from
# the installed copy and under the root lock this run holds. The order is the order
# in which nothing is touched before whatever would touch it is proved sound: the
# packages before the account that needs openssh-server, the account before the
# runtime that is probed as it, the authorized key before the drop-in that takes
# password authentication away from that account, the sshd assertions before the
# firewall that starts filtering, and the firewall before the power policy that
# keeps a lid-closed node up (design section 6.2).
#
# Each row is one journaled transaction of design section 3.7, and each is decided
# by inspection first (section 6.1), so a rerun on a healthy node makes no mutating
# vendor call at all. Every failure inside a row is that row's library's own: it
# exits 2 or 3 naming the artifact, the vendor output, and the entry it left
# prepared, and this function adds the row and the node's state around it rather
# than a second message of its own.
harbor_bootstrap_steps() {
  local root operator admin etc bindir prefix home probe=0
  local firewall_args=()
  root="${HARBOR_BOOTSTRAP_STATE_ROOT}"
  operator="${HARBOR_BOOTSTRAP_OPERATOR}"
  etc="${HARBOR_BOOTSTRAP_ETC}"
  prefix="${HARBOR_BOOTSTRAP_NODE_PREFIX}"
  bindir="$(dirname "${HARBOR_BOOTSTRAP_LINK}")"
  # The installation user of design section 3.5, whose effective sshd configuration
  # the operator drop-in must leave untouched and whom --harden-sshd could lock out.
  # A run with --authorized-key-file needs no SUDO_USER (the principal check above),
  # and the only account left to judge those two things against is then root, which
  # is also the account --harden-sshd refuses to be given.
  admin="${SUDO_USER:-root}"
  # Packages.
  harbor_bootstrap_row packages "the release is installed and this node's packages are being brought to the six of the design section 5.2 Packages row; each package is its own entry and any that failed stays prepared"
  # The list is a word list, and each word is one package name, so the split is
  # deliberate.
  # shellcheck disable=SC2086
  harbor_apt_install "${root}" ${HARBOR_BOOTSTRAP_PACKAGES}
  # Operator user. It comes after the packages because the account is worth nothing
  # on a node without openssh-server, and before every row that acts as it.
  harbor_bootstrap_row operator-user "the packages are installed and the operator account ${operator} is being created; no runtime, key, drop-in, rule, or linger has been touched"
  harbor_user_ensure "${root}" "${operator}"
  [ -n "${HARBOR_USER_HOME:-}" ] \
    || harbor_die 2 bootstrap.operator_home "the name service lists ${operator} without a home directory, so Harbor has nowhere to place the operator's authorized key; the packages and the account are applied and nothing after them was attempted, so fix the account with getent passwd ${operator} and rerun"
  # Taken here rather than read at the authorized key row below, so the directory the
  # key is written under is the one this row proved, and no row added between the two
  # can move it by looking the operator up again for a reason of its own.
  home="${HARBOR_USER_HOME}"
  # Node.js: the pinned runtime at the root-owned prefix, its four /usr/local/bin
  # symlinks, and then the report-only probe of what the operator's own login shell
  # sees. The probe never makes root reinstall or alter anything, so a probe that
  # fails is a precondition for the operator, exit 1, and not a reason to stop.
  harbor_bootstrap_row nodejs "the operator account exists and the pinned Node.js runtime is being installed at ${prefix} with its symlinks in ${bindir}; nothing after it has been touched"
  harbor_node_install "${root}" "${prefix}"
  harbor_node_link "${root}" "${prefix}" "${bindir}"
  harbor_node_operator_probe "${operator}" || probe="$?"
  [ "${probe}" = 0 ] \
    || harbor_bootstrap_degraded node.operator_probe "sh -lc 'node --version' as ${operator} does not print the locked version; the runtime root installed at ${prefix} is the locked one and was not altered, so this is the operator's own shell profile to fix"
  # Authorized key: before the drop-in below takes password authentication away from
  # that account, never after, so no ordering of these two can leave the operator
  # with no way in. The source is the path the flag binding recorded, copied by path
  # and journaled by hash; no key ever reaches a command line or a message.
  harbor_bootstrap_row authorized-key "Node.js is installed and the operator's authorized key is being copied from ${HARBOR_BOOTSTRAP_KEY_SOURCE}; the sshd drop-in that would need it has not been written, so password authentication for ${operator} is still whatever this node had"
  harbor_ssh_authorize "${root}" "${operator}" "${home}" "${HARBOR_BOOTSTRAP_KEY_SOURCE}"
  # SSH: the operator-scoped drop-in, sshd's own syntax check, the two sshd
  # assertions, and only then the reload. --harden-sshd is a second file with a
  # journal entry of its own, refused unless the installation user has a key.
  harbor_bootstrap_row sshd "the operator has an authorized key and the sshd drop-in under ${etc}/ssh/sshd_config.d/ is being written and proved; the firewall, the power policy, and linger are untouched"
  harbor_ssh_configure "${root}" "${operator}" "${admin}" "${etc}"
  if harbor_bootstrap_has_flag --harden-sshd; then
    harbor_ssh_harden "${root}" "${admin}" "${etc}"
  fi
  # Firewall, after the sshd assertions passed and never before them (design section
  # 6.2). --allow-lan-ssh opens port 22 to this node's own RFC 1918 network, which is
  # a wider posture than the tailnet alone and so is a status warning: exit 1.
  harbor_bootstrap_row firewall "sshd accepts the drop-in and the firewall rules of design section 3.4 are being applied; the tagged tailscale0 rule is added before anything starts filtering, and the power policy and linger are untouched"
  ! harbor_bootstrap_has_flag --adopt-firewall \
    || firewall_args[${#firewall_args[@]}]=--adopt-firewall
  ! harbor_bootstrap_has_flag --allow-lan-ssh \
    || firewall_args[${#firewall_args[@]}]=--allow-lan-ssh
  harbor_firewall_apply "${root}" ${firewall_args[@]+"${firewall_args[@]}"}
  [ -z "${HARBOR_FIREWALL_LAN_WARNING}" ] \
    || harbor_bootstrap_degraded firewall.lan_ssh "${HARBOR_FIREWALL_LAN_WARNING}"
  # Power: the lid drop-in and the four masked sleep targets, so a laptop node stays
  # up with its lid closed.
  harbor_bootstrap_row power "the firewall is applied and the logind lid policy under ${etc}/systemd/logind.conf.d/ and the four masked sleep targets are being written; linger is untouched"
  harbor_power_configure "${root}" "${etc}"
  # The Tailscale install row of the design section 5.2 table sits here, between
  # Power and Linger. It is slice 3d and belongs to lib/tailscale.sh and its own
  # commits, so this release applies nothing for it and journals nothing for it.
  #
  # Linger, so the operator's user manager runs without a login session.
  harbor_bootstrap_row linger "the power policy is applied and linger is being enabled for ${operator}"
  harbor_user_linger "${root}" "${operator}"
  # The Tailscale operator row of the design section 5.2 table sits here, between
  # Linger and the state record, and belongs to slice 3d with the row above it.
  #
  # The state record row, /var/lib/harbor/bootstrap.json and the operator's next
  # command, is the last row of the table and belongs to its own commit; this
  # release writes no record and leaves any record already there exactly as it is.
  #
  # Every row is applied, so a failure after this point is no longer one row's.
  # Read by the ERR trap of lib/log.sh, never in this file.
  # shellcheck disable=SC2034
  HARBOR_NEXT_COMMAND="rerun the same bootstrap command with the same flags once the cause is fixed"
}
harbor_bootstrap_main() {
  HARBOR_PID="${HARBOR_PID:-$$}"
  HARBOR_BOOTSTRAP_REDACTED="$(harbor_redact_argv ${1+"$@"})"
  HARBOR_CMDLINE="${HARBOR_CMDLINE:-harbor bootstrap ${HARBOR_BOOTSTRAP_REDACTED}}"
  # Read by the ERR and EXIT traps of lib/log.sh, never in this file.
  # shellcheck disable=SC2034
  HARBOR_NEXT_COMMAND="rerun the same bootstrap command with the same flags once the cause is fixed"
  HARBOR_BOOTSTRAP_DEGRADED=0
  HARBOR_BOOTSTRAP_NOTES=""
  harbor_bootstrap_bind "${0}"
  harbor_bootstrap_parse ${1+"$@"}
  harbor_bootstrap_preflight
  harbor_bootstrap_install
  if [ "${HARBOR_BOOTSTRAP_FORM}" = checkout ]; then
    harbor_lock_release "${HARBOR_BOOTSTRAP_STATE_ROOT}"
    [ ! -d "${HARBOR_BOOTSTRAP_STATE_ROOT}/lock.d" ] \
      || harbor_die 2 bootstrap.lock_release "${HARBOR_BOOTSTRAP_STATE_ROOT}/lock.d is still there after this run released it, so the installed image would refuse with lock.busy; the release is installed, so inspect the lock with ls -la ${HARBOR_BOOTSTRAP_STATE_ROOT}/lock.d and rerun sudo harbor bootstrap"
    HARBOR_COMPLETED=1
    harbor_bootstrap_reexec "${HARBOR_BOOTSTRAP_LINK}" ${1+"$@"}
    return 0
  fi
  # The remaining rows of the design section 5.2 table run here, from the installed
  # copy and under the lock this run still holds.
  harbor_msg "installed ${HARBOR_BOOTSTRAP_TAG} at ${HARBOR_BOOTSTRAP_RELEASE} and pointed ${HARBOR_BOOTSTRAP_LINK} at it"
  harbor_bootstrap_steps
  # Read by the EXIT trap of lib/log.sh, which turns a zero exit without it into the
  # exit 2 of a command that stopped before it finished.
  # shellcheck disable=SC2034
  HARBOR_COMPLETED=1
  [ "${HARBOR_BOOTSTRAP_DEGRADED}" = 1 ] || return 0
  # Exit 1 of design section 6.2: every row applied, the node is usable, and one or
  # more of them reported a precondition somebody has to act on. The notes are
  # repeated here so they are not buried under the rows that ran after them.
  harbor_msg "bootstrap.degraded: this node is bootstrapped and every row above applied, and these need attention:"
  printf '%s' "${HARBOR_BOOTSTRAP_NOTES}" >&2
  exit 1
}
harbor_install_traps
harbor_bootstrap_main ${1+"$@"}
