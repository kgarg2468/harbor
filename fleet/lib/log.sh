#!/bin/bash
# Harbor logging (design section 3.9): messages, the per-principal log file, JSON
# escaping, harbor_die, and vendor argv redaction. Step boundaries, test hooks, and
# traps are added below these functions.
harbor_utc_now() {
  date -u +%Y%m%dT%H%M%SZ
}
harbor_msg() {
  printf 'harbor: %s\n' "${*}" >&2
}
harbor_log() {
  local level="${1}"
  shift
  if [ -n "${HARBOR_LOG_FILE:-}" ]; then
    printf '%s %s %s\n' "$(harbor_utc_now)" "${level}" "${*}" >>"${HARBOR_LOG_FILE}"
  fi
  if [ "${HARBOR_VERBOSE:-0}" = "1" ]; then
    printf 'harbor: %s: %s\n' "${level}" "${*}" >&2
  fi
}
harbor_log_open() {
  HARBOR_LOG_FILE="${1}"
  : >>"${HARBOR_LOG_FILE}"
  chmod "${2}" "${HARBOR_LOG_FILE}"
}
harbor_redact_argv() {
  local out="" arg drop_next=0 sep="" scheme rest authority
  for arg in ${1+"$@"}; do
    if [ "${drop_next}" = 1 ]; then
      drop_next=0
      continue
    fi
    case "${arg}" in
      --auth-key | --authkey | --token | --password | --secret | --api-key | --key)
        drop_next=1
        ;;
      --auth-key=* | --authkey=* | --token=* | --password=* | --secret=* | --api-key=* | --key=*)
        arg="${arg%%=*}"
        ;;
      *://*)
        arg="${arg%%\?*}"
        arg="${arg%%#*}"
        scheme="${arg%%://*}"
        rest="${arg#*://}"
        authority="${rest%%/*}"
        case "${authority}" in
          *@*)
            arg="${scheme}://${authority##*@}"
            case "${rest}" in
              */*)
                arg="${arg}/${rest#*/}"
                ;;
            esac
            ;;
        esac
        ;;
    esac
    out="${out}${sep}${arg}"
    sep=" "
  done
  printf '%s' "${out}"
}
harbor_log_vendor() {
  harbor_log vendor "$(harbor_redact_argv ${1+"$@"})"
}
harbor_json_escape() {
  local tab escaped
  tab="$(printf '\t')"
  escaped="$(printf '%s.' "${1}" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e "s/${tab}/\\\\t/g" \
    | awk 'BEGIN { ORS = "" } { if (NR > 1) printf "\\n"; print }')"
  printf '%s' "${escaped%.}"
}
harbor_die() {
  local code="${1}" id="${2}"
  shift 2
  harbor_msg "${id}: ${*}"
  harbor_log error "${id} exit=${code}" || :
  if [ "${HARBOR_JSON:-0}" = "1" ]; then
    printf '{"error":"%s"}\n' "$(harbor_json_escape "${id}")"
  fi
  exit "${code}"
}
harbor_step() {
  HARBOR_CURRENT_STEP="${1}"
  harbor_log step "${1}"
  harbor_test_hook "${1}"
}
# The pause sentinel (design section 7, "a test-controlled file"): derived from the
# top-level PID and the step so a test can create it after reading the holder record.
harbor_test_pause_sentinel() {
  local dir="${TMPDIR:-/tmp}"
  printf '%s/harbor-pause.%s.%s' "${dir%/}" "${HARBOR_PID:-$$}" "${1}"
}
# The only test hook in Harbor (design section 7). Inert unless HARBOR_TEST_HOOKS=1.
# It can only kill or pause the process at a step boundary; it skips no check,
# alters no path, and mutates nothing.
harbor_test_hook() {
  local sentinel i
  [ "${HARBOR_TEST_HOOKS:-0}" = "1" ] || return 0
  case "${HARBOR_PID:-$$}" in
    "" | *[!0-9]*) harbor_die 3 hook.bad_pid "HARBOR_PID must be a decimal PID, got ${HARBOR_PID:-}" ;;
  esac
  if [ "${HARBOR_FAIL_AFTER:-}" = "${1}" ]; then
    kill -KILL "${HARBOR_PID:-$$}"
    exit 4
  fi
  if [ "${HARBOR_PAUSE_AFTER:-}" = "${1}" ]; then
    sentinel="$(harbor_test_pause_sentinel "${1}")"
    i=0
    while [ ! -e "${sentinel}" ]; do
      i=$((i + 1))
      if [ "${i}" -gt 600 ]; then
        harbor_die 4 hook.pause_timeout "paused at ${1} for 120s without ${sentinel}"
      fi
      sleep 0.2
    done
    rm -f "${sentinel}" 2>/dev/null || true
  fi
}
harbor_on_err() {
  local rc=$?
  [ "${BASH_SUBSHELL:-0}" = 0 ] || return 0
  harbor_msg "failed at step ${HARBOR_CURRENT_STEP:-startup} (exit ${rc}) running: ${BASH_COMMAND}"
  harbor_msg "next: ${HARBOR_NEXT_COMMAND:-rerun the same command after fixing the cause}"
}
harbor_on_interrupt() {
  HARBOR_INTERRUPTED=1
  exit 4
}
harbor_on_exit() {
  local rc=$?
  if [ -n "${HARBOR_LOCK_ROOT:-}" ]; then
    harbor_lock_release "${HARBOR_LOCK_ROOT}" || :
  fi
  if [ "${HARBOR_INTERRUPTED:-0}" = "1" ]; then
    if [ "${HARBOR_JSON:-0}" = "1" ]; then
      printf '{"error":"interrupted"}\n'
    fi
    harbor_log exit 4 || :
    exit 4
  fi
  if [ "${rc}" = 0 ] && [ "${HARBOR_COMPLETED:-0}" != "1" ]; then
    harbor_msg "terminated before completion (exit 2)"
    harbor_log exit 2 incomplete || :
    exit 2
  fi
  harbor_log exit "${rc}" || :
  exit "${rc}"
}
harbor_install_traps() {
  set -E
  trap harbor_on_err ERR
  trap harbor_on_interrupt INT TERM HUP
  trap harbor_on_exit EXIT
}
