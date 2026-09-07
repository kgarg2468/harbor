#!/bin/bash
# Shared constants and assertion helpers for the Harbor integration lane
# (design section 7, "The integration lane"). Sourced by the driver scripts that
# run on the ephemeral runner as the unprivileged workflow user; the wrappers
# under bin/ deliberately do NOT source this file, because they are installed as
# standalone root-owned programs and must not depend on the checkout being
# readable at the paths they were built from. The lane paths below are therefore
# repeated as literals in each wrapper; keep them in sync.
#
# Nothing here mutates the machine. setup.sh does the mutating.

# ---------------------------------------------------------------------------
# Lane paths. Everything the lane owns lives outside the checkout, because
# harbor_checkout_trusted refuses a working tree that carries untracked files.
# Each constant is read by one or more of the driver scripts that source this
# file, so ShellCheck cannot see a use for any of them from here.
# shellcheck disable=SC2034
# ---------------------------------------------------------------------------
IT_ROOT=/opt/harbor-it
IT_BIN="${IT_ROOT}/bin"
IT_STATE="${IT_ROOT}/state"
IT_APT="${IT_ROOT}/apt"
IT_APTREPO="${IT_ROOT}/aptrepo"
IT_FIXTURES="${IT_ROOT}/fixtures"
IT_BASELINE="${IT_ROOT}/baseline"
IT_SHIM_LOG="${IT_STATE}/shim.log"
IT_MUT_LOG="${IT_STATE}/mutations.log"
IT_SCENARIO_FILE="${IT_STATE}/scenario"

# The PATH root runs with. The wrapper directory is first so that Harbor's ufw,
# curl, apt-get, systemctl and loginctl calls are observable; everything after it
# is the ordinary root PATH.
IT_PATH="${IT_BIN}:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# Harbor's own real paths. The lane runs at these, not under a fixture home.
IT_OPERATOR=harbor
IT_HARBOR_STATE=/var/lib/harbor
IT_HARBOR_JOURNAL="${IT_HARBOR_STATE}/journal"
IT_HARBOR_LOG="${IT_HARBOR_STATE}/bootstrap.log"
IT_HARBOR_RECORD="${IT_HARBOR_STATE}/bootstrap.json"
IT_INSTALL_ROOT=/usr/local/lib/harbor
IT_LINK=/usr/local/bin/harbor
IT_NODE_PREFIX=/opt/harbor/node
IT_KEYRING=/etc/apt/keyrings/tailscale-archive-keyring.gpg
IT_TAILSCALE_LIST=/etc/apt/sources.list.d/tailscale.list

# The repository under test. lib/ sits three levels below fleet/, four below the
# repository root.
IT_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd -P)"
IT_FLEET="${IT_REPO}/fleet"
IT_INTEGRATION="${IT_FLEET}/tests/integration"

# The user that invokes sudo. Harbor reads it from SUDO_USER and treats it as the
# administrator whose authorized key is copied to the operator. setup.sh records
# it, because the assertion scripts themselves run as root and id would then
# answer root rather than the installation user.
if [ -r "${IT_STATE}/admin" ]; then
  IT_ADMIN="$(cat "${IT_STATE}/admin")"
else
  IT_ADMIN="$(id -un)"
fi

# ---------------------------------------------------------------------------
# versions.lock
# ---------------------------------------------------------------------------

# it_lock KEY -- print the single locked value for KEY, or die.
it_lock() {
  local key value
  key="${1}"
  value="$(sed -n "s/^${key}=//p" "${IT_FLEET}/versions.lock" | sed -n 1p)"
  if [ -z "${value}" ]; then
    printf 'integration: versions.lock has no value for %s\n' "${key}" >&2
    exit 1
  fi
  printf '%s' "${value}"
}

# ---------------------------------------------------------------------------
# Assertions. Failures accumulate so that one run reports every problem, and the
# script exits non-zero from it_done. Nothing here swallows a status.
# ---------------------------------------------------------------------------
IT_FAILURES=0
IT_CHECKS=0

it_note() {
  printf 'note   %s\n' "${*}"
}

it_pass() {
  IT_CHECKS=$((IT_CHECKS + 1))
  printf 'ok     %s\n' "${*}"
}

it_fail() {
  IT_CHECKS=$((IT_CHECKS + 1))
  IT_FAILURES=$((IT_FAILURES + 1))
  printf 'FAIL   %s\n' "${*}" >&2
}

# it_eq LABEL EXPECTED ACTUAL
it_eq() {
  if [ "${2}" = "${3}" ]; then
    it_pass "${1} = ${2}"
  else
    it_fail "${1}: expected [${2}] got [${3}]"
  fi
}

# it_ne LABEL UNEXPECTED ACTUAL
it_ne() {
  if [ "${2}" != "${3}" ]; then
    it_pass "${1} != ${2}"
  else
    it_fail "${1}: expected anything but [${2}]"
  fi
}

# it_contains LABEL NEEDLE HAYSTACK
it_contains() {
  case "${3}" in
    *"${2}"*) it_pass "${1} contains [${2}]" ;;
    *) it_fail "${1}: [${2}] missing from [${3}]" ;;
  esac
}

# it_lacks LABEL NEEDLE HAYSTACK
it_lacks() {
  case "${3}" in
    *"${2}"*) it_fail "${1}: [${2}] unexpectedly present" ;;
    *) it_pass "${1} lacks [${2}]" ;;
  esac
}

# it_file_absent LABEL PATH
it_file_absent() {
  if [ -e "${2}" ] || [ -L "${2}" ]; then
    it_fail "${1}: ${2} exists and should not"
  else
    it_pass "${1}: ${2} absent"
  fi
}

# it_mode_owner PATH -- "MODE OWNER GROUP", with the mode in the four octal digits
# the design writes modes in. stat prints %a without a leading zero, so a 0755
# directory reads as 755 and every mode assertion in this lane compared a padded
# expectation against an unpadded reading and failed on all of them. Padded here,
# once, in the same shape lib/checks.sh reads a mode in.
it_mode_owner() {
  local raw
  raw="$(stat -c '%a %U %G' "${1}")"
  printf '%04d %s' "${raw%% *}" "${raw#* }"
}

# it_file LABEL MODE OWNER GROUP PATH -- exists as a regular file with the given
# mode and ownership.
it_file() {
  local label mode owner group path stat
  label="${1}"
  mode="${2}"
  owner="${3}"
  group="${4}"
  path="${5}"
  if [ ! -f "${path}" ]; then
    it_fail "${label}: ${path} is not a regular file"
    return 0
  fi
  stat="$(it_mode_owner "${path}")"
  it_eq "${label} mode/owner (${path})" "${mode} ${owner} ${group}" "${stat}"
}

# it_dir LABEL MODE OWNER GROUP PATH
it_dir() {
  local label mode owner group path stat
  label="${1}"
  mode="${2}"
  owner="${3}"
  group="${4}"
  path="${5}"
  if [ ! -d "${path}" ]; then
    it_fail "${label}: ${path} is not a directory"
    return 0
  fi
  stat="$(it_mode_owner "${path}")"
  it_eq "${label} mode/owner (${path})" "${mode} ${owner} ${group}" "${stat}"
}

# it_symlink LABEL TARGET PATH
it_symlink() {
  if [ ! -L "${3}" ]; then
    it_fail "${1}: ${3} is not a symbolic link"
    return 0
  fi
  it_eq "${1} target" "${2}" "$(readlink "${3}")"
}

it_done() {
  printf '\n%s: %s checks, %s failures\n' "${1:-integration}" "${IT_CHECKS}" "${IT_FAILURES}"
  if [ "${IT_FAILURES}" -ne 0 ]; then
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Log helpers. The wrappers append one tab-separated line per call:
#   <epoch>\t<kind>\t<program>\t<argv...>
# where kind is "mutate" or "inspect". mutations.log carries only the mutating
# lines, so an idempotent rerun must leave it byte-identical.
# ---------------------------------------------------------------------------

# it_shim_calls PROGRAM -- count of logged calls to PROGRAM in the shim log.
it_shim_calls() {
  if [ ! -f "${IT_SHIM_LOG}" ]; then
    printf '0'
    return 0
  fi
  awk -F '\t' -v prog="${1}" '$3 == prog { n++ } END { printf "%d", n + 0 }' "${IT_SHIM_LOG}"
}

# it_mutations PROGRAM -- count of logged mutating calls to PROGRAM.
it_mutations() {
  if [ ! -f "${IT_MUT_LOG}" ]; then
    printf '0'
    return 0
  fi
  awk -F '\t' -v prog="${1}" '$3 == prog { n++ } END { printf "%d", n + 0 }' "${IT_MUT_LOG}"
}

# it_journal_field FILE FIELD -- pull a top-level string field out of a journal
# entry without depending on jq being installed.
it_journal_field() {
  sed -n "s/.*\"${2}\": *\"\\([^\"]*\\)\".*/\\1/p" "${1}" | sed -n 1p
}

# it_journal_count OWNERSHIP -- number of journal entries with that ownership.
it_journal_count() {
  local file count ownership
  ownership="${1}"
  count=0
  for file in "${IT_HARBOR_JOURNAL}"/*.json; do
    [ -f "${file}" ] || continue
    if [ "$(it_journal_field "${file}" ownership)" = "${ownership}" ]; then
      count=$((count + 1))
    fi
  done
  printf '%d' "${count}"
}

# it_journal_phases -- every distinct phase present, one per line, sorted.
it_journal_phases() {
  local file
  for file in "${IT_HARBOR_JOURNAL}"/*.json; do
    [ -f "${file}" ] || continue
    it_journal_field "${file}" phase
  done | LC_ALL=C sort -u
}

# it_release_tag -- the tag the lane created on the checkout under test.
it_release_tag() {
  cat "${IT_STATE}/release-tag"
}
