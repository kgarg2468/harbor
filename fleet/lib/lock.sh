#!/bin/bash
# Command lock (design section 3.7): per-principal state roots, holder identity and
# records, holder classification, the reclaim.d acquisition gate, the ownership
# re-check, and release. Globals set here are read by lib/journal.sh and bin/harbor.
# shellcheck disable=SC2034
harbor_os() {
  if [ -z "${HARBOR_OS:-}" ]; then
    HARBOR_OS="$(uname -s)"
  fi
  printf '%s' "${HARBOR_OS}"
}
harbor_state_root_for_principal() {
  if [ "$(id -u)" = "0" ]; then
    HARBOR_STATE_ROOT="/var/lib/harbor"
    HARBOR_LOCK_KIND="root"
  else
    HARBOR_STATE_ROOT="${HOME}/.local/state/harbor"
    HARBOR_LOCK_KIND="operator"
  fi
}
harbor_state_root_create() {
  local root="${1}" kind="${2}" mode
  case "${kind}" in
    root) mode=0755 ;;
    operator) mode=0700 ;;
    *) harbor_die 3 lock.kind "unknown lock kind ${kind}" ;;
  esac
  if [ ! -d "${root}" ]; then
    mkdir -p "$(dirname "${root}")"
    mkdir "${root}"
    chmod "${mode}" "${root}"
  fi
}
harbor_lock_boot_id() {
  case "$(harbor_os)" in
    Linux) cat /proc/sys/kernel/random/boot_id ;;
    Darwin) sysctl -n kern.boottime | sed 's/[^0-9]*\([0-9]*\).*/\1/' ;;
    *) printf '' ;;
  esac
}
harbor_lock_pid_alive() {
  local out
  out="$(ps -p "${1}" -o pid= 2>/dev/null || true)"
  [ -n "$(printf '%s' "${out}" | tr -d ' ')" ]
}
harbor_lock_start_time() {
  case "$(harbor_os)" in
    Linux)
      if [ -r "/proc/${1}/stat" ]; then
        sed 's/^.*) //' "/proc/${1}/stat" | awk '{ print $20 }'
      fi
      ;;
    Darwin)
      TZ=UTC LC_ALL=C ps -o lstart= -p "${1}" 2>/dev/null | sed 's/^ *//; s/ *$//' || true
      ;;
  esac
}
harbor_lock_identity() {
  [ -z "${HARBOR_LOCK_ID_PID:-}" ] || return 0
  HARBOR_LOCK_ID_HOSTNAME="$(uname -n)"
  HARBOR_LOCK_ID_BOOT_ID="$(harbor_lock_boot_id)"
  HARBOR_LOCK_ID_PID="${HARBOR_PID:-$$}"
  HARBOR_LOCK_ID_START_TIME="$(harbor_lock_start_time "${HARBOR_LOCK_ID_PID}")"
  HARBOR_LOCK_ID_CMDLINE="$(printf '%s' "${HARBOR_CMDLINE:-${0}}" | tr '\n\r' '  ')"
  [ -n "${HARBOR_LOCK_ID_BOOT_ID}" ] || harbor_die 3 lock.identity "cannot read the boot id"
  [ -n "${HARBOR_LOCK_ID_START_TIME}" ] || harbor_die 3 lock.identity "cannot read the start time of pid ${HARBOR_LOCK_ID_PID}"
}
harbor_lock_write_holder() {
  local dir="${1}" fmode="${2}" tmp
  harbor_lock_identity
  tmp="${dir}/holder.tmp.${HARBOR_LOCK_ID_PID}"
  {
    printf 'hostname=%s\n' "${HARBOR_LOCK_ID_HOSTNAME}"
    printf 'boot_id=%s\n' "${HARBOR_LOCK_ID_BOOT_ID}"
    printf 'pid=%s\n' "${HARBOR_LOCK_ID_PID}"
    printf 'start_time=%s\n' "${HARBOR_LOCK_ID_START_TIME}"
    printf 'cmdline=%s\n' "${HARBOR_LOCK_ID_CMDLINE}"
  } >"${tmp}"
  chmod "${fmode}" "${tmp}"
  mv -f "${tmp}" "${dir}/holder"
}
harbor_lock_parse_holder() {
  local file="${1}" line key value seen=""
  HARBOR_HOLDER_HOSTNAME=""
  HARBOR_HOLDER_BOOT_ID=""
  HARBOR_HOLDER_PID=""
  HARBOR_HOLDER_START_TIME=""
  HARBOR_HOLDER_CMDLINE=""
  [ -f "${file}" ] || return 1
  while IFS= read -r line || [ -n "${line}" ]; do
    case "${line}" in
      *=*) ;;
      *) return 1 ;;
    esac
    key="${line%%=*}"
    value="${line#*=}"
    case " ${seen} " in
      *" ${key} "*) return 1 ;;
    esac
    case "${key}" in
      hostname) HARBOR_HOLDER_HOSTNAME="${value}" ;;
      boot_id) HARBOR_HOLDER_BOOT_ID="${value}" ;;
      pid) HARBOR_HOLDER_PID="${value}" ;;
      start_time) HARBOR_HOLDER_START_TIME="${value}" ;;
      cmdline) HARBOR_HOLDER_CMDLINE="${value}" ;;
      *) return 1 ;;
    esac
    seen="${seen} ${key}"
  done <"${file}"
  for key in hostname boot_id pid start_time cmdline; do
    case " ${seen} " in
      *" ${key} "*) ;;
      *) return 1 ;;
    esac
  done
  [ -n "${HARBOR_HOLDER_HOSTNAME}" ] || return 1
  [ -n "${HARBOR_HOLDER_BOOT_ID}" ] || return 1
  [ -n "${HARBOR_HOLDER_START_TIME}" ] || return 1
  [ -n "${HARBOR_HOLDER_CMDLINE}" ] || return 1
  case "${HARBOR_HOLDER_PID}" in
    '' | *[!0-9]*) return 1 ;;
  esac
  return 0
}
harbor_lock_classify() {
  local start
  harbor_lock_identity
  HARBOR_LOCK_CLASS=unknown
  harbor_lock_parse_holder "${1}/holder" || return 0
  [ "${HARBOR_HOLDER_HOSTNAME}" = "${HARBOR_LOCK_ID_HOSTNAME}" ] || return 0
  if [ "${HARBOR_HOLDER_BOOT_ID}" != "${HARBOR_LOCK_ID_BOOT_ID}" ]; then
    HARBOR_LOCK_CLASS=stale
    return 0
  fi
  if ! harbor_lock_pid_alive "${HARBOR_HOLDER_PID}"; then
    HARBOR_LOCK_CLASS=stale
    return 0
  fi
  start="$(harbor_lock_start_time "${HARBOR_HOLDER_PID}")"
  [ -n "${start}" ] || return 0
  if [ "${start}" != "${HARBOR_HOLDER_START_TIME}" ]; then
    HARBOR_LOCK_CLASS=stale
    return 0
  fi
  HARBOR_LOCK_CLASS=live
}
