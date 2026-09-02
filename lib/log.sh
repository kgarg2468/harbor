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
