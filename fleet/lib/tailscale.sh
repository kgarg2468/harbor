#!/bin/bash
# Tailscale (design sections 3.6 and 5.2, the Tailscale install and Tailscale operator
# rows): the pinned install and its guarded adoption, and the operator grant with its
# read-access probe. Every mutation here is one journaled transaction of design section
# 3.7 and every branch is decided by inspection first (section 6.1), so a second run
# makes no mutating call. Nothing here ever runs tailscale up: login is attended and
# belongs to harbor auth tailscale (section 5.3), and a pre-existing installation is
# never logged in, logged out, or reconfigured beyond the operator rule of section 5.2.
# The state root and the apt configuration root are parameters, exactly as lib/apt.sh
# takes them, so this library names no absolute path of its own and a unit test writes
# inside its own fixture root. The two locked values, tailscale_version and
# tailscale_apt_channel, are read from versions.lock through lib/versions.sh and never
# spelled here. Depends on lib/log.sh, lib/lock.sh, lib/versions.sh, lib/journal.sh,
# and lib/apt.sh (harbor_apt_installed, harbor_apt_state, harbor_apt_add_vendor_source).
# HARBOR_TAILSCALE_* globals are set here and read by callers.
# shellcheck disable=SC2034
HARBOR_TAILSCALE_PACKAGE="tailscale"
HARBOR_TAILSCALE_VENDOR="tailscale"
HARBOR_TAILSCALE_PKGS_URL="https://pkgs.tailscale.com"
# harbor_tailscale_check_operator_name NAME: refuse a name that could not be one word
# on a tailscale command line. The operator name reaches tailscale set --operator=NAME
# and a runuser -u NAME argument, and it is the target of every tailscale-operator
# journal entry, so a name carrying whitespace, an equals sign, or a leading hyphen is
# refused before any vendor command runs rather than parsed by the vendor as a second
# option. The same portable-name rule lib/ssh.sh applies before writing a name into an
# sshd configuration file.
harbor_tailscale_check_operator_name() {
  case "${1}" in
    "" | -* | *[!A-Za-z0-9._-]*)
      harbor_die 3 tailscale.operator_name "the operator name '${1}' is not a portable account name (letters, digits, dot, underscore, and hyphen, not leading with a hyphen); Harbor will not pass it to tailscale; nothing was changed"
      ;;
  esac
}
# harbor_tailscale_channel_parts CHANNEL: the vendor repository track and the release
# codename that tailscale_apt_channel names, as HARBOR_TAILSCALE_TRACK and
# HARBOR_TAILSCALE_CODENAME. The lock spells the channel the way the vendor's own
# instructions do, <track>/<os>/<codename> (stable/ubuntu/noble), and the vendor
# publishes the keyring at <track>/<os>/<codename>.noarmor.gpg and the packages under
# the apt suite <codename> of <track>/<os>. A value in any other shape cannot be turned
# into either of those and is refused naming the lock file, before anything is
# downloaded or written.
harbor_tailscale_channel_parts() {
  local channel="${1}"
  case "${channel}" in
    */*/*/* | "" | */ | /* | *[!A-Za-z0-9./_-]*)
      harbor_die 3 tailscale.channel "${HARBOR_VERSIONS_FILE}: tailscale_apt_channel '${channel}' is not <track>/<os>/<codename> (for example stable/ubuntu/noble), so the vendor keyring and apt source cannot be named from it; nothing was written"
      ;;
    */*/*) ;;
    *)
      harbor_die 3 tailscale.channel "${HARBOR_VERSIONS_FILE}: tailscale_apt_channel '${channel}' is not <track>/<os>/<codename> (for example stable/ubuntu/noble), so the vendor keyring and apt source cannot be named from it; nothing was written"
      ;;
  esac
  HARBOR_TAILSCALE_TRACK="${channel%/*}"
  HARBOR_TAILSCALE_CODENAME="${channel##*/}"
}
# harbor_tailscale_keyring_path DEST_ROOT: where lib/apt.sh puts the vendor keyring
# under the apt configuration root DEST_ROOT, spelled the same way
# harbor_apt_add_vendor_source spells it, because the apt source line written beside it
# has to name that exact path in its signed-by option.
harbor_tailscale_keyring_path() {
  printf '%s/apt/keyrings/%s-archive-keyring.gpg' "${1}" "${HARBOR_TAILSCALE_VENDOR}"
}
# harbor_tailscale_ownership STATE_ROOT: harbor-installed, adopted, or pre-existing,
# printed on stdout, read from the root journal alone. The package database cannot
# answer this: a tailscale that dpkg lists at the locked version is the one Harbor
# installed on an earlier run, the one Harbor adopted, or one the owner installed
# before Harbor ever ran, and the three differ in exactly what Harbor may do to them
# (design sections 5.2, 5.7, and 6.4). An applied tailscale-install entry Harbor wrote
# as created is the record that Harbor installed it, and it stays the record across a
# later modified entry that moved its version; an applied modified entry with no
# created one is an adoption. Anything else is pre-existing, which is also what a
# fresh node with no entry at all is. Entries that are prepared or reverted are not
# counted: recovery has run before this row, and a reverted entry is an installation
# that is no longer Harbor's.
harbor_tailscale_ownership() {
  local dir="${1}/journal" entry created=0 modified=0
  for entry in "${dir}"/[0-9][0-9][0-9][0-9]-tailscale-install.json; do
    [ -e "${entry}" ] || continue
    [ "$(harbor_journal_string "${entry}" phase)" = applied ] || continue
    case "$(harbor_journal_string "${entry}" ownership)" in
      created) created=1 ;;
      modified) modified=1 ;;
    esac
  done
  if [ "${created}" = 1 ]; then
    printf 'harbor-installed'
  elif [ "${modified}" = 1 ]; then
    printf 'adopted'
  else
    printf 'pre-existing'
  fi
}
# harbor_observe_op_tailscale_install PKG: the observer harbor_journal_observe
# dispatches to for a tailscale-install entry, so a prepared entry left by a crash
# between apt-get and the applied write is decidable by recovery (design section 3.7).
# A tailscale-install entry records the package in the shape a package entry does,
# harbor_apt_state or "absent", so the observation is the same dpkg inspection
# lib/apt.sh makes for a package entry. Inspection only; a dpkg-query failure that is
# not "not installed" is fail-closed through harbor_apt_installed. Called only through
# harbor_journal_observe.
harbor_observe_op_tailscale_install() {
  if harbor_apt_installed "${1}"; then
    harbor_apt_state "${HARBOR_APT_VERSION}"
  else
    printf '"absent"'
  fi
}
# harbor_tailscale_apt ARG...: one apt-get invocation, noninteractive, logged as a
# vendor call before it runs. Sets HARBOR_TAILSCALE_APT_OUT and returns apt-get's own
# exit status, so each caller can say what state the node is in when it fails.
harbor_tailscale_apt() {
  local rc=0
  harbor_log_vendor apt-get ${1+"$@"}
  HARBOR_TAILSCALE_APT_OUT="$(DEBIAN_FRONTEND=noninteractive apt-get ${1+"$@"} 2>&1)" || rc="$?"
  return "${rc}"
}
# harbor_tailscale_candidate SIMULATION: the version apt-get -s install says it would
# install for the package, or nothing. lib/apt.sh reads only the fresh-install form,
# "Inst tailscale (1.2.3 ...)"; an install over a present version prints the version
# being replaced first, "Inst tailscale [1.2.0] (1.2.3 ...)", and the adoption path
# below is exactly that case, so the bracketed part is allowed and skipped here.
harbor_tailscale_candidate() {
  printf '%s\n' "${1}" \
    | sed -n "s/^Inst ${HARBOR_TAILSCALE_PACKAGE} \(\[[^]]*\] \)\{0,1\}(\([^ ]*\).*/\2/p" \
    | sed -n 1p
}
# harbor_tailscale_vendor_source STATE_ROOT DEST_ROOT: the vendor keyring and apt
# source of the design section 5.2 Tailscale install row, through lib/apt.sh, each one
# journaled file entry. The keyring is fetched from the vendor over TLS, through the
# same curl form lib/node.sh downloads with, into a temporary file under STATE_ROOT,
# which only root can write to, and handed to harbor_apt_add_vendor_source by path.
# There is no recorded checksum for it: versions.lock has no key for one (its schema
# is the thirteen keys of design section 2), so what is trusted here is the TLS
# connection to the vendor host that the vendor's own install instructions trust, and
# what is recorded is the sha256 of the keyring as written, in its file entry. A fetch
# that fails is exit 2 before anything is journaled or written.
harbor_tailscale_vendor_source() {
  local root="${1}" etc="${2}" url tmp keyring line rc=0
  url="${HARBOR_TAILSCALE_PKGS_URL}/${HARBOR_TAILSCALE_TRACK}/${HARBOR_TAILSCALE_CODENAME}.noarmor.gpg"
  keyring="$(harbor_tailscale_keyring_path "${etc}")"
  line="deb [signed-by=${keyring}] ${HARBOR_TAILSCALE_PKGS_URL}/${HARBOR_TAILSCALE_TRACK} ${HARBOR_TAILSCALE_CODENAME} main"
  tmp="${root}/.tmp.tailscale-keyring.${HARBOR_LOCK_ID_PID:-$$}"
  rm -f "${tmp}"
  harbor_log_vendor curl -fsSL --proto =https --tlsv1.2 "${url}"
  curl -fsSL --proto =https --tlsv1.2 "${url}" >"${tmp}" 2>/dev/null || rc="$?"
  if [ "${rc}" != 0 ] || [ ! -s "${tmp}" ]; then
    rm -f "${tmp}"
    harbor_die 2 tailscale.keyring "fetching the vendor keyring ${url} failed (curl exit ${rc}); nothing was written and nothing was journaled, rerun after fixing the cause"
  fi
  harbor_apt_add_vendor_source "${root}" "${HARBOR_TAILSCALE_VENDOR}" "${tmp}" "${line}" "${etc}"
  rm -f "${tmp}"
}
# harbor_tailscale_install STATE_ROOT DEST_ROOT [--adopt-tailscale]: the Tailscale
# install row of design section 5.2. Inspection first: dpkg is asked whether the
# package is installed and at which version, and the root journal is asked whose
# installation it is (harbor_tailscale_ownership).
#   Absent: the vendor keyring and apt source are written through lib/apt.sh, apt's
#   lists are refreshed so the new source is indexed, the pinned install is simulated,
#   and only then is one tailscale-install entry prepared, created, pre_state "absent",
#   post_state the locked version, followed by the install, the section 6.1 check that
#   dpkg now reports the locked version, and the applied write.
#   Present at the locked version: journaled observed and left alone, whoever
#   installed it.
#   Present at another version and Harbor's, installed or adopted on an earlier run:
#   moved to the locked version as an ordinary modified entry with the prior version
#   as pre_state, which is how a rerun from a release that moved the pin converges
#   (design section 5.2, the mismatch form). No flag is needed, because the
#   installation is Harbor's.
#   Present at another version and not Harbor's: journaled observed exactly as found
#   and reported as drift, degraded, return 1, with no mutating call and nothing
#   written under DEST_ROOT. With --adopt-tailscale it is instead adopted: the vendor
#   source and the lists as for a fresh install, then the locked version installed
#   over it, journaled modified with the prior version, so the reverse walk can name
#   what it replaced. Every install that runs over a version already present passes
#   --allow-downgrades to apt, whichever of those two paths reached it: a pre-existing
#   installation may be newer than the pin, and a lock that moved its pin backwards
#   asks Harbor to step its own installation down just the same, and apt refuses both
#   without the flag. Only the fresh install onto an absent package omits it, because
#   there is no version there for it to be a downgrade from.
# The simulation is what proves the pinned version is installable from the vendor
# repository this node can reach: a pin the repository no longer carries fails there,
# exit 3 naming the lock file, before any entry is prepared and before any mutating
# apt call. Sets HARBOR_TAILSCALE_OWNERSHIP (harbor-installed, adopted, or
# pre-existing) and HARBOR_TAILSCALE_VERSION (the version dpkg reports once the row is
# done) for the state record of design section 5.2. Returns 1 on preserved drift and
# 0 otherwise; every failure exits.
harbor_tailscale_install() {
  local root etc adopt=0 locked channel found="" ownership pre post entry rc=0 candidate
  local flag="" downgrade=""
  [ "$#" -ge 2 ] || harbor_die 3 usage "usage: harbor_tailscale_install <state-root> <destination-root> [--adopt-tailscale]"
  root="${1}"
  etc="${2}"
  shift 2
  while [ "$#" -gt 0 ]; do
    case "${1}" in
      --adopt-tailscale) adopt=1 ;;
      *) harbor_die 3 usage "usage: harbor_tailscale_install <state-root> <destination-root> [--adopt-tailscale]" ;;
    esac
    shift
  done
  HARBOR_TAILSCALE_OWNERSHIP=""
  HARBOR_TAILSCALE_VERSION=""
  # Both locked values are required before anything is inspected, so a lock that does
  # not pin Tailscale is refused naming the lock file and nothing else happens.
  locked="$(harbor_version_require tailscale_version)" || exit "$?"
  channel="$(harbor_version_require tailscale_apt_channel)" || exit "$?"
  harbor_tailscale_channel_parts "${channel}"
  ownership="$(harbor_tailscale_ownership "${root}")"
  post="$(harbor_apt_state "${locked}")"
  if harbor_apt_installed "${HARBOR_TAILSCALE_PACKAGE}"; then
    found="${HARBOR_APT_VERSION}"
    pre="$(harbor_apt_state "${found}")"
    if [ "${found}" = "${locked}" ]; then
      harbor_journal_create "${root}" tailscale-install "${HARBOR_TAILSCALE_PACKAGE}" observed applied "${pre}" "${pre}"
      harbor_log tailscale "${HARBOR_TAILSCALE_PACKAGE} ${found} is installed and equals the lock (${ownership}); nothing to do"
      HARBOR_TAILSCALE_OWNERSHIP="${ownership}"
      HARBOR_TAILSCALE_VERSION="${found}"
      return 0
    fi
    if [ "${ownership}" = pre-existing ] && [ "${adopt}" != 1 ]; then
      harbor_journal_create "${root}" tailscale-install "${HARBOR_TAILSCALE_PACKAGE}" observed applied "${pre}" "${pre}"
      harbor_msg "tailscale.drift: degraded: ${HARBOR_TAILSCALE_PACKAGE} ${found} is installed and Harbor did not install it, while ${HARBOR_VERSIONS_FILE} pins ${locked}; Harbor preserved it and changed nothing (--adopt-tailscale would install ${locked} over it and journal the prior version)"
      HARBOR_TAILSCALE_OWNERSHIP="${ownership}"
      HARBOR_TAILSCALE_VERSION="${found}"
      return 1
    fi
    downgrade="--allow-downgrades"
  else
    pre='"absent"'
  fi
  harbor_tailscale_vendor_source "${root}" "${etc}"
  harbor_tailscale_apt update \
    || harbor_die 2 tailscale.apt_update "apt-get update failed (exit $?): ${HARBOR_TAILSCALE_APT_OUT}; the vendor source is in place and ${HARBOR_TAILSCALE_PACKAGE} is unchanged, rerun after fixing the cause"
  # The simulation is the version check: apt refuses a pin its sources do not carry,
  # and answers with the version it would install when they do.
  # shellcheck disable=SC2086
  harbor_tailscale_apt -s install ${downgrade} "${HARBOR_TAILSCALE_PACKAGE}=${locked}" || rc="$?"
  [ "${rc}" = 0 ] \
    || harbor_die 3 tailscale.version_unavailable "apt-get -s install ${HARBOR_TAILSCALE_PACKAGE}=${locked} failed (exit ${rc}): ${HARBOR_TAILSCALE_APT_OUT}; tailscale_version ${locked} in ${HARBOR_VERSIONS_FILE} is not installable from the ${channel} channel this node's apt can see, so either the pin has to change in ${HARBOR_VERSIONS_FILE} or the node's access to ${HARBOR_TAILSCALE_PKGS_URL} has to be fixed; ${HARBOR_TAILSCALE_PACKAGE} is unchanged and nothing was journaled for it"
  candidate="$(harbor_tailscale_candidate "${HARBOR_TAILSCALE_APT_OUT}")"
  [ "${candidate}" = "${locked}" ] \
    || harbor_die 3 tailscale.version_unavailable "apt-get -s install ${HARBOR_TAILSCALE_PACKAGE}=${locked} would install '${candidate}', not tailscale_version ${locked} of ${HARBOR_VERSIONS_FILE}: ${HARBOR_TAILSCALE_APT_OUT}; ${HARBOR_TAILSCALE_PACKAGE} is unchanged and nothing was journaled for it"
  if [ -z "${found}" ]; then
    harbor_journal_create "${root}" tailscale-install "${HARBOR_TAILSCALE_PACKAGE}" created prepared "${pre}" "${post}"
  else
    harbor_journal_create "${root}" tailscale-install "${HARBOR_TAILSCALE_PACKAGE}" modified prepared "${pre}" "${post}"
  fi
  entry="${HARBOR_JOURNAL_ENTRY}"
  rc=0
  # shellcheck disable=SC2086
  harbor_tailscale_apt install -y ${downgrade} "${HARBOR_TAILSCALE_PACKAGE}=${locked}" || rc="$?"
  [ "${rc}" = 0 ] \
    || harbor_die 2 tailscale.install "apt-get install -y ${downgrade:+${downgrade} }${HARBOR_TAILSCALE_PACKAGE}=${locked} failed (exit ${rc}): ${HARBOR_TAILSCALE_APT_OUT}; $(basename "${entry}") stays prepared, rerun after fixing the cause"
  harbor_step tailscale-install
  # Section 6.1: the check runs again after the apply, through the same observation
  # recovery would make, and a second failure leaves the entry prepared.
  [ "$(harbor_observe_op_tailscale_install "${HARBOR_TAILSCALE_PACKAGE}")" = "${post}" ] \
    || harbor_die 2 tailscale.verify "apt-get install -y reported success but dpkg does not report ${HARBOR_TAILSCALE_PACKAGE} at ${locked}; $(basename "${entry}") stays prepared"
  harbor_journal_set_phase "${entry}" applied
  HARBOR_TAILSCALE_OWNERSHIP="$(harbor_tailscale_ownership "${root}")"
  HARBOR_TAILSCALE_VERSION="${locked}"
  if [ -z "${found}" ]; then
    harbor_msg "installed ${HARBOR_TAILSCALE_PACKAGE} ${locked} from the ${channel} channel"
  else
    harbor_msg "installed ${HARBOR_TAILSCALE_PACKAGE} ${locked} over ${found} (${HARBOR_TAILSCALE_OWNERSHIP})"
  fi
}
# harbor_tailscale_status: tailscale status --json as root, with
# HARBOR_TAILSCALE_BACKEND_STATE set to the BackendState it carries. This is the read
# every other read in the operator row stands on: a daemon that cannot answer root
# cannot be asked anything about its operator, so that is exit 2 and nothing is
# decided, and only once root has an answer does a refusal of the operator user mean
# what the row takes it to mean. Inspection only. The value is read with sed rather
# than jq, because no jq is available to lib/; BackendState is the one top-level key
# the CLI prints under that name, on its own line whether or not the output is
# indented, and an answer without it is not the status this row knows how to read.
# Nothing is printed: the readings are globals, because a caller that captured them
# through a command substitution would lose every one of them to the subshell.
harbor_tailscale_status() {
  local out rc=0 state
  harbor_log_vendor tailscale status --json
  out="$(tailscale status --json 2>&1)" || rc="$?"
  [ "${rc}" = 0 ] \
    || harbor_die 2 tailscale.status "tailscale status --json failed (exit ${rc}): ${out}; the node's Tailscale state cannot be read, so nothing about its operator was decided or changed"
  state="$(printf '%s\n' "${out}" | sed -n 's/.*"BackendState"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | sed -n 1p)"
  [ -n "${state}" ] \
    || harbor_die 2 tailscale.status "tailscale status --json exited 0 and printed no BackendState, so the node's Tailscale state cannot be read and nothing about its operator was decided or changed"
  HARBOR_TAILSCALE_BACKEND_STATE="${state}"
}
# harbor_tailscale_probe OPERATOR: the read-access probe of design section 5.2. The
# operator user runs tailscale status --json without sudo, through runuser from the
# root this row runs as, and success proves read access only: not authority to change
# a preference, which the daemon reveals only when a write is attempted, and Harbor
# runs no write to find out. Sets HARBOR_TAILSCALE_PROBE to granted or denied and
# HARBOR_TAILSCALE_PROBE_OUT to the vendor's output. Inspection only; it is called
# after harbor_tailscale_status has proved the daemon answers root, which is what
# makes a failure here the operator's refusal rather than the daemon's absence.
harbor_tailscale_probe() {
  local rc=0
  harbor_log_vendor runuser -u "${1}" -- tailscale status --json
  HARBOR_TAILSCALE_PROBE_OUT="$(runuser -u "${1}" -- tailscale status --json 2>&1)" || rc="$?"
  if [ "${rc}" = 0 ]; then
    HARBOR_TAILSCALE_PROBE=granted
  else
    HARBOR_TAILSCALE_PROBE=denied
  fi
}
# harbor_tailscale_get_operator: the operator preference as the pinned CLI's documented
# tailscale get operator prints it, the only way this library ever reads a prior value
# (design section 5.2). The current stable Tailscale may lack the command, so its
# absence is a state this function reports rather than an error: HARBOR_TAILSCALE_GET
# is unavailable when the command fails for any reason, absent when it exits 0 and
# prints nothing, exact when it prints exactly one portable account name, which is then
# in HARBOR_TAILSCALE_GET_VALUE, and unavailable again when it exits 0 with anything
# else, because a value Harbor cannot write back exactly is not an exact value.
harbor_tailscale_get_operator() {
  local out rc=0 lines
  HARBOR_TAILSCALE_GET=unavailable
  HARBOR_TAILSCALE_GET_VALUE=""
  harbor_log_vendor tailscale get operator
  out="$(tailscale get operator 2>&1)" || rc="$?"
  [ "${rc}" = 0 ] || return 0
  if [ -z "${out}" ]; then
    HARBOR_TAILSCALE_GET=absent
    return 0
  fi
  lines="$(printf '%s\n' "${out}" | awk 'END { print NR }')"
  [ "${lines}" = 1 ] || return 0
  case "${out}" in
    -* | *[!A-Za-z0-9._-]*) return 0 ;;
  esac
  HARBOR_TAILSCALE_GET=exact
  HARBOR_TAILSCALE_GET_VALUE="${out}"
}
# harbor_tailscale_operator_read OPERATOR: the operator state of design section 3.7,
# in HARBOR_TAILSCALE_STATE in the pre_state and post_state form of a
# tailscale-operator entry, from three reads in a fixed order: the root status read
# that gates the other two, the operator's probe, and the get. It is "absent" or the
# exact value when the pinned CLI's tailscale get operator answers, because that is
# the preference itself; otherwise it is the result of the unprivileged probe,
# {"probe":"granted"} or {"probe":"denied"}, which is the most the node can say about
# the grant on a release without that command. The three readings stay in
# HARBOR_TAILSCALE_BACKEND_STATE, HARBOR_TAILSCALE_PROBE, and HARBOR_TAILSCALE_GET for
# the row to decide on, which is why this sets globals and prints nothing.
# Inspection only.
harbor_tailscale_operator_read() {
  harbor_tailscale_status
  harbor_tailscale_probe "${1}"
  harbor_tailscale_get_operator
  case "${HARBOR_TAILSCALE_GET}" in
    exact) HARBOR_TAILSCALE_STATE="\"$(harbor_json_escape "${HARBOR_TAILSCALE_GET_VALUE}")\"" ;;
    absent) HARBOR_TAILSCALE_STATE='"absent"' ;;
    *) HARBOR_TAILSCALE_STATE="{\"probe\":\"${HARBOR_TAILSCALE_PROBE}\"}" ;;
  esac
}
# harbor_observe_op_tailscale_operator OPERATOR: the observer harbor_journal_observe
# dispatches to for a tailscale-operator entry, so an entry left prepared by a crash
# between tailscale set and the applied write is decidable by recovery (design section
# 3.7). It prints harbor_tailscale_operator_read's rendering, so recovery compares
# the same rendering the row recorded. Where the pinned CLI has tailscale get
# operator, both recorded states are exact values and the window is always
# decidable. Where it does not, the probe is all there is: an entry prepared with
# pre_state "absent" on such a release (the Harbor-installed grant below) is decided
# applied when the probe is granted, and, should the probe be denied, matches
# neither state and is left for harbor journal resolve, which is the fail-closed
# answer for a preference the node offers no documented way to read. Inspection
# only; a daemon that cannot answer root stays the exit 2 of harbor_tailscale_status.
# Called only through harbor_journal_observe.
harbor_observe_op_tailscale_operator() {
  harbor_tailscale_operator_read "${1}"
  printf '%s' "${HARBOR_TAILSCALE_STATE}"
}
# harbor_tailscale_operator_granted STATE_ROOT OPERATOR: 0 when the root journal
# holds an applied tailscale-operator entry Harbor wrote for OPERATOR as created or
# modified, the record that an earlier run made the grant. On a release without
# tailscale get operator that record is the only way a rerun can tell a grant it made
# from one it has yet to make, because the probe alone may pass for any local user.
harbor_tailscale_operator_granted() {
  local dir="${1}/journal" entry
  for entry in "${dir}"/[0-9][0-9][0-9][0-9]-tailscale-operator.json; do
    [ -e "${entry}" ] || continue
    [ "$(harbor_journal_string "${entry}" phase)" = applied ] || continue
    [ "$(harbor_journal_string "${entry}" target)" = "${2}" ] || continue
    case "$(harbor_journal_string "${entry}" ownership)" in
      created | modified) return 0 ;;
    esac
  done
  return 1
}
# harbor_tailscale_granted_state OPERATOR: the state a tailscale-operator entry
# records as post_state once OPERATOR holds the grant, in the form the observer will
# be able to render on this release: the exact value where tailscale get operator
# answers, the granted probe where it does not. It reads HARBOR_TAILSCALE_GET as the
# last harbor_tailscale_operator_read left it.
harbor_tailscale_granted_state() {
  case "${HARBOR_TAILSCALE_GET}" in
    exact | absent) printf '"%s"' "$(harbor_json_escape "${1}")" ;;
    *) printf '{"probe":"granted"}' ;;
  esac
}
# harbor_tailscale_set_operator STATE_ROOT OPERATOR OWNERSHIP PRE: one journaled
# tailscale set --operator=OPERATOR, the only preference this library ever writes.
# The entry is prepared with PRE and the granted state of this release as post_state,
# the set is made, and the section 6.1 check is the operator row's own idempotency
# check, the operator user's unprivileged read: the state is observed again through
# the observer and must equal what the entry promised, else exit 2 with the entry
# left prepared.
harbor_tailscale_set_operator() {
  local root="${1}" operator="${2}" ownership="${3}" pre="${4}" post entry out rc=0
  post="$(harbor_tailscale_granted_state "${operator}")"
  harbor_journal_create "${root}" tailscale-operator "${operator}" "${ownership}" prepared "${pre}" "${post}"
  entry="${HARBOR_JOURNAL_ENTRY}"
  harbor_log_vendor tailscale set "--operator=${operator}"
  out="$(tailscale set "--operator=${operator}" 2>&1)" || rc="$?"
  [ "${rc}" = 0 ] \
    || harbor_die 2 tailscale.operator_set "tailscale set --operator=${operator} failed (exit ${rc}): ${out}; $(basename "${entry}") stays prepared, rerun after fixing the cause"
  harbor_step tailscale-operator-set
  harbor_tailscale_operator_read "${operator}"
  [ "${HARBOR_TAILSCALE_STATE}" = "${post}" ] \
    || harbor_die 2 tailscale.operator_verify "tailscale set --operator=${operator} exited 0 but the node now observes ${HARBOR_TAILSCALE_STATE}, not ${post}: ${operator} still cannot read tailscaled's status without sudo, or the daemon reports another operator; $(basename "${entry}") stays prepared"
  harbor_journal_set_phase "${entry}" applied
  harbor_msg "granted ${operator} the Tailscale operator role (tailscale set --operator=${operator})"
}
# harbor_tailscale_report OPERATOR OWNERSHIP: the closing report of the design section
# 5.2 Tailscale operator row, decided by BackendState alone. Running: nothing. Not
# running on a Harbor-installed daemon: needs_tailscale_login, naming harbor auth
# tailscale, the attended command of section 5.3 that logs the node in. Not running on
# an installation Harbor did not create, adopted or not, whose identity and preferences
# are the owner's: the owner brings it up, because Harbor never runs tailscale up on
# it. Sets HARBOR_TAILSCALE_REPORT to needs_tailscale_login, owner_brings_up, or the
# empty string. Report only; nothing here mutates or exits.
harbor_tailscale_report() {
  local operator="${1}" ownership="${2}"
  HARBOR_TAILSCALE_REPORT=""
  [ "${HARBOR_TAILSCALE_BACKEND_STATE}" != Running ] || return 0
  if [ "${ownership}" = harbor-installed ]; then
    HARBOR_TAILSCALE_REPORT=needs_tailscale_login
    harbor_msg "tailscale.needs_tailscale_login: BackendState is ${HARBOR_TAILSCALE_BACKEND_STATE}; log this node in as ${operator} with: harbor auth tailscale"
  else
    HARBOR_TAILSCALE_REPORT=owner_brings_up
    harbor_msg "tailscale.not_running: BackendState is ${HARBOR_TAILSCALE_BACKEND_STATE} on a Tailscale installation Harbor did not create (${ownership}), so Harbor will not bring it up; bring it up yourself with your existing preferences, outside Harbor"
  fi
}
# harbor_tailscale_operator STATE_ROOT OPERATOR [--adopt-tailscale]: the Tailscale
# operator row of design section 5.2. Never tailscale up. One reading of the node
# through harbor_tailscale_operator_read, then a decision by whose installation this
# is (harbor_tailscale_ownership) and what the reading said:
#   Any installation whose reading already names OPERATOR: journaled observed.
#   Harbor-installed: the grant is Harbor's to make. It is made once, journaled
#   created with pre_state "absent", the state a daemon Harbor installed fresh has, or
#   modified with the exact prior value when tailscale get operator names another
#   account; the rerun that finds an applied grant entry and a passing probe journals
#   observed and makes no call. A release without tailscale get operator cannot show
#   the preference at all, so there the record of the earlier grant is what the rerun
#   decides on, and the probe passing is the check, exactly as the section 5.2 table
#   has it.
#   Pre-existing or adopted, probe passes: journaled observed with the reading.
#   Pre-existing or adopted, probe fails: the prior value is read only through
#   tailscale get operator, and only an exact value can be adopted, because only an
#   exact value can be restored by the reverse walk. With --adopt-tailscale and an
#   exact value, the grant is journaled modified with that value as pre_state and
#   made. With no exact value, an empty answer included, or without the flag, nothing
#   is mutated and nothing is journaled: the precondition is reported with the
#   sudo tailscale set --operator=OPERATOR command for the owner to run outside
#   Harbor, return 3, and the rerun after the owner has run it finds the probe passing
#   and journals observed.
# Then the closing report of harbor_tailscale_report, whichever way the row went.
# Returns 3 when the precondition was reported and 0 otherwise; every failure exits.
harbor_tailscale_operator() {
  local root operator adopt=0 ownership state result=0
  [ "$#" -ge 2 ] || harbor_die 3 usage "usage: harbor_tailscale_operator <state-root> <operator> [--adopt-tailscale]"
  root="${1}"
  operator="${2}"
  shift 2
  while [ "$#" -gt 0 ]; do
    case "${1}" in
      --adopt-tailscale) adopt=1 ;;
      *) harbor_die 3 usage "usage: harbor_tailscale_operator <state-root> <operator> [--adopt-tailscale]" ;;
    esac
    shift
  done
  harbor_tailscale_check_operator_name "${operator}"
  HARBOR_TAILSCALE_REPORT=""
  ownership="$(harbor_tailscale_ownership "${root}")"
  harbor_tailscale_operator_read "${operator}"
  state="${HARBOR_TAILSCALE_STATE}"
  if [ "${state}" = "\"${operator}\"" ]; then
    # The daemon names OPERATOR as its operator. The probe failing all the same would be
    # a daemon refusing the account it says it grants, which is nothing this row can
    # act on and nothing it may call done.
    [ "${HARBOR_TAILSCALE_PROBE}" = granted ] \
      || harbor_die 2 tailscale.operator_contradiction "tailscale get operator prints ${operator} but ${operator} cannot run tailscale status --json without sudo: ${HARBOR_TAILSCALE_PROBE_OUT}; inspect tailscaled on this node, nothing was changed"
    harbor_journal_create "${root}" tailscale-operator "${operator}" observed applied "${state}" "${state}"
    harbor_log tailscale "${operator} is already the Tailscale operator; nothing to do"
  elif [ "${ownership}" = harbor-installed ]; then
    if [ "${HARBOR_TAILSCALE_GET}" = exact ]; then
      harbor_tailscale_set_operator "${root}" "${operator}" modified "${state}"
    elif [ "${HARBOR_TAILSCALE_GET}" = unavailable ] && [ "${HARBOR_TAILSCALE_PROBE}" = granted ] \
      && harbor_tailscale_operator_granted "${root}" "${operator}"; then
      harbor_journal_create "${root}" tailscale-operator "${operator}" observed applied "${state}" "${state}"
      harbor_log tailscale "${operator} was granted the Tailscale operator role by an earlier run and reads tailscaled's status without sudo; nothing to do"
    else
      harbor_tailscale_set_operator "${root}" "${operator}" created '"absent"'
    fi
  elif [ "${HARBOR_TAILSCALE_PROBE}" = granted ]; then
    harbor_journal_create "${root}" tailscale-operator "${operator}" observed applied "${state}" "${state}"
    harbor_log tailscale "${operator} reads tailscaled's status without sudo on a ${ownership} installation; recorded and left alone"
  elif [ "${HARBOR_TAILSCALE_GET}" = exact ] && [ "${adopt}" = 1 ]; then
    harbor_tailscale_set_operator "${root}" "${operator}" modified "${state}"
  else
    if [ "${HARBOR_TAILSCALE_GET}" = exact ]; then
      harbor_msg "tailscale.operator: precondition: ${operator} cannot run tailscale status --json without sudo on this ${ownership} Tailscale installation, whose operator is ${HARBOR_TAILSCALE_GET_VALUE}; Harbor changes it only with --adopt-tailscale, so either grant it yourself outside Harbor with: sudo tailscale set --operator=${operator}, or rerun with --adopt-tailscale; nothing was changed"
    else
      harbor_msg "tailscale.operator: precondition: ${operator} cannot run tailscale status --json without sudo on this ${ownership} Tailscale installation, and the pinned tailscale prints no exact prior operator value for Harbor to record and restore, so Harbor will not change the preference; grant it yourself outside Harbor with: sudo tailscale set --operator=${operator}, then rerun; nothing was changed"
    fi
    result=3
  fi
  harbor_tailscale_report "${operator}" "${ownership}"
  return "${result}"
}
