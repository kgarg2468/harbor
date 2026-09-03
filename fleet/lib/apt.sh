#!/bin/bash
# Packages (design section 5.2, the Packages and Tailscale install rows): package
# presence inspection, journaled installs, and the vendor keyring and apt source.
# Every mutation here is one journaled transaction of design section 3.7 and every
# step is decided by inspection first (section 6.1). The bootstrap package list and
# the destination root of the vendor source belong to the caller; this library names
# no package and no absolute path of its own. HARBOR_APT_* globals are set by the
# inspection helper and read by its callers.
# shellcheck disable=SC2034
harbor_apt_state() {
  # The package state of design section 3.7: version and install method.
  printf '{"version":"%s","method":"apt"}' "$(harbor_json_escape "${1}")"
}
harbor_apt_query() {
  # harbor_apt_query PKG: inspection only, never a mutation. Sets
  # HARBOR_APT_VERSION and returns 0 when dpkg reports PKG installed; returns 1
  # when PKG is absent or only its configuration files remain; returns 2 with
  # HARBOR_APT_QUERY_OUT holding dpkg-query's output on any other failure.
  local rc=0
  HARBOR_APT_VERSION=""
  HARBOR_APT_QUERY_OUT="$(dpkg-query -s "${1}" 2>&1)" || rc="$?"
  case "${rc}" in
    0) ;;
    1) return 1 ;;
    *) return 2 ;;
  esac
  case "${HARBOR_APT_QUERY_OUT}" in
    *"Status: install ok installed"*) ;;
    *) return 1 ;;
  esac
  HARBOR_APT_VERSION="$(printf '%s\n' "${HARBOR_APT_QUERY_OUT}" | sed -n 's/^Version: //p')"
  [ -n "${HARBOR_APT_VERSION}" ] || return 2
}
harbor_apt_installed() {
  # harbor_apt_installed PKG: 0 when the package is installed, 1 when it is not.
  # A dpkg-query failure that is not "not installed" is fail-closed, exit 2.
  local rc=0
  harbor_apt_query "${1}" || rc="$?"
  case "${rc}" in
    0) return 0 ;;
    1) return 1 ;;
  esac
  harbor_die 2 apt.inspect "dpkg-query -s ${1} failed: ${HARBOR_APT_QUERY_OUT}"
}
harbor_apt_candidate() {
  # harbor_apt_candidate SIMULATION PKG: the version the simulation says would be
  # installed, so a prepared entry can carry its post_state before the mutation.
  printf '%s\n' "${1}" | sed -n "s/^Inst ${2} (\([^ ]*\).*/\1/p" | sed -n 1p
}
harbor_apt_install() {
  # harbor_apt_install STATE_ROOT PKG...: install only the packages inspection
  # reports missing, in one apt-get invocation. An installed package is journaled
  # observed and never reinstalled; a missing one is prepared, installed, verified,
  # and marked applied. A failed install leaves its entry prepared for recovery.
  local root pkg version sim out rc=0 n
  local missing=() entries=()
  [ "$#" -ge 2 ] || harbor_die 3 usage "usage: harbor_apt_install <state-root> <package>..."
  root="${1}"
  shift
  for pkg in "$@"; do
    if harbor_apt_installed "${pkg}"; then
      version="$(harbor_apt_state "${HARBOR_APT_VERSION}")"
      harbor_journal_create "${root}" package "${pkg}" observed applied "${version}" "${version}"
    else
      missing[${#missing[@]}]="${pkg}"
    fi
  done
  [ "${#missing[@]}" -gt 0 ] || return 0
  harbor_log_vendor apt-get -s install "${missing[@]}"
  sim="$(DEBIAN_FRONTEND=noninteractive apt-get -s install "${missing[@]}" 2>&1)" || rc="$?"
  [ "${rc}" = 0 ] || harbor_die 2 apt.simulate "apt-get -s install ${missing[*]} failed (exit ${rc}): ${sim}"
  for pkg in "${missing[@]}"; do
    version="$(harbor_apt_candidate "${sim}" "${pkg}")"
    [ -n "${version}" ] || harbor_die 2 apt.simulate "apt-get -s install named no candidate version for ${pkg}"
    harbor_journal_create "${root}" package "${pkg}" created prepared '"absent"' "$(harbor_apt_state "${version}")"
    entries[${#entries[@]}]="${HARBOR_JOURNAL_ENTRY}"
  done
  harbor_log_vendor apt-get install -y "${missing[@]}"
  out="$(DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}" 2>&1)" || rc="$?"
  [ "${rc}" = 0 ] || harbor_die 2 apt.install "apt-get install -y ${missing[*]} failed (exit ${rc}): ${out}"
  harbor_step apt-install
  # Section 6.1: the check runs again after the apply, and a second failure aborts
  # naming the package, leaving its entry prepared.
  n=0
  while [ "${n}" -lt "${#missing[@]}" ]; do
    pkg="${missing[${n}]}"
    version=""
    if harbor_apt_installed "${pkg}"; then
      version="$(harbor_apt_state "${HARBOR_APT_VERSION}")"
    fi
    [ "${version}" = "$(harbor_journal_raw "${entries[${n}]}" post_state)" ] \
      || harbor_die 2 apt.verify "apt-get install -y reported success but ${pkg} is not installed at the prepared version"
    harbor_journal_set_phase "${entries[${n}]}" applied
    n=$((n + 1))
  done
}
harbor_apt_write_file() {
  # harbor_apt_write_file STATE_ROOT DEST KIND SOURCE: write one 0644 file at DEST,
  # journaled as one file entry. KIND copy copies the file SOURCE, KIND line writes
  # SOURCE as a single line. A DEST that is already what would be written is
  # journaled observed and left alone; anything at DEST that is not a regular file
  # is foreign and exits 3 untouched.
  local root="${1}" dest="${2}" kind="${3}" source="${4}" pre post ownership tmp entry
  pre="$(harbor_observe_file "${dest}")"
  case "${pre}" in
    '"unobservable:'*)
      harbor_die 3 apt.foreign "${dest} exists and is not a regular file; inspect it and remove it by hand, then rerun"
      ;;
  esac
  tmp="$(dirname "${dest}")/.tmp.$(basename "${dest}").${HARBOR_LOCK_ID_PID}"
  rm -f "${tmp}"
  case "${kind}" in
    copy) cp "${source}" "${tmp}" || harbor_die 2 apt.write "copying ${source} to ${tmp} failed" ;;
    line) printf '%s\n' "${source}" >"${tmp}" ;;
  esac
  chmod 0644 "${tmp}"
  post="$(harbor_observe_file "${tmp}")"
  if [ "${post}" = "${pre}" ]; then
    rm -f "${tmp}"
    harbor_journal_create "${root}" file "${dest}" observed applied "${pre}" "${post}"
    return 0
  fi
  ownership=modified
  [ "${pre}" != '"absent"' ] || ownership=created
  harbor_journal_create "${root}" file "${dest}" "${ownership}" "prepared" "${pre}" "${post}"
  entry="${HARBOR_JOURNAL_ENTRY}"
  harbor_journal_sync_path "${tmp}"
  mv -f "${tmp}" "${dest}"
  harbor_journal_sync_path "$(dirname "${dest}")"
  harbor_step apt-vendor-file
  harbor_journal_set_phase "${entry}" applied
}
harbor_apt_add_vendor_source() {
  # harbor_apt_add_vendor_source STATE_ROOT NAME KEYRING_SOURCE SOURCE_LINE ROOT:
  # install NAME's keyring and apt source list under the configuration root ROOT,
  # each journaled as one file entry, both 0644 and, since only root runs this
  # step, root-owned. ROOT is a parameter so nothing writes outside a test's own
  # fixture root; production passes the system configuration root.
  local root name keyring_source line dest keyring list dir
  [ "$#" -eq 5 ] || harbor_die 3 usage "usage: harbor_apt_add_vendor_source <state-root> <name> <keyring-source> <source-line> <destination-root>"
  root="${1}"
  name="${2}"
  keyring_source="${3}"
  line="${4}"
  dest="${5}"
  [ -f "${keyring_source}" ] && [ -r "${keyring_source}" ] \
    || harbor_die 3 apt.keyring_source "${keyring_source} is not a readable regular file; nothing was written"
  keyring="${dest}/apt/keyrings/${name}-archive-keyring.gpg"
  list="${dest}/apt/sources.list.d/${name}.list"
  for dir in "$(dirname "${keyring}")" "$(dirname "${list}")"; do
    if [ ! -d "${dir}" ]; then
      mkdir -p "${dir}"
      chmod 0755 "${dir}"
    fi
  done
  harbor_apt_write_file "${root}" "${keyring}" copy "${keyring_source}"
  harbor_apt_write_file "${root}" "${list}" line "${line}"
}
