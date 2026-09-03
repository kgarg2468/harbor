#!/bin/bash
# Ownership journal (design section 3.7): observation helpers, the platform sync
# helper, canonical entry rendering and parsing, ln-based creation, rename-over phase
# rewrites, recovery, and harbor journal resolve. HARBOR_JOURNAL_* globals are read
# by callers.
# shellcheck disable=SC2034
harbor_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "${1}" | cut -d' ' -f1
  else
    shasum -a 256 "${1}" | cut -d' ' -f1
  fi
}
harbor_stat_mode() {
  local raw
  case "$(harbor_os)" in
    Linux) raw="$(stat -c '%a' "${1}")" ;;
    Darwin) raw="$(stat -f '%Lp' "${1}")" ;;
  esac
  printf '%04d' "$((10#${raw}))"
}
harbor_stat_owner() {
  case "$(harbor_os)" in
    Linux) stat -c '%U' "${1}" ;;
    Darwin) stat -f '%Su' "${1}" ;;
  esac
}
harbor_journal_sync_path() {
  if [ -z "${HARBOR_SYNC_MODE:-}" ]; then
    case "$(harbor_os)" in
      Linux) HARBOR_SYNC_MODE="file" ;;
      Darwin) HARBOR_SYNC_MODE="fs" ;;
      *) harbor_die 3 journal.platform "unsupported platform $(harbor_os)" ;;
    esac
  fi
  case "${HARBOR_SYNC_MODE}" in
    file) sync -- "${1}" || harbor_die 2 journal.sync "sync of ${1} failed" ;;
    fs) sync ;;
  esac
}
harbor_journal_dir() {
  printf '%s/journal' "${1}"
}
harbor_journal_init() {
  local dir="${1}/journal"
  if [ ! -d "${dir}" ]; then
    mkdir "${dir}"
    chmod 0700 "${dir}"
  fi
}
harbor_journal_render() {
  local op="${1}" target="${2}" ownership="${3}" phase="${4}" pre="${5}" post="${6}"
  local resolved_by="${7:-}" resolved_at="${8:-}"
  printf '{\n'
  printf '  "op": "%s",\n' "$(harbor_json_escape "${op}")"
  printf '  "target": "%s",\n' "$(harbor_json_escape "${target}")"
  printf '  "ownership": "%s",\n' "${ownership}"
  printf '  "phase": "%s",\n' "${phase}"
  printf '  "pre_state": %s,\n' "${pre}"
  if [ -n "${resolved_by}" ]; then
    printf '  "post_state": %s,\n' "${post}"
    printf '  "resolved_by": "%s",\n' "${resolved_by}"
    printf '  "resolved_at": "%s"\n' "${resolved_at}"
  else
    printf '  "post_state": %s\n' "${post}"
  fi
  printf '}\n'
}
harbor_journal_field() {
  local line
  line="$(grep -m 1 "^  \"${2}\": " "${1}" || true)"
  [ -n "${line}" ] || return 1
  line="${line#*: }"
  line="${line%,}"
  printf '%s' "${line}"
}
harbor_journal_raw() {
  harbor_journal_field "${1}" "${2}" || true
}
harbor_json_unquote() {
  local v="${1}"
  case "${v}" in
    \"*\")
      v="${v#\"}"
      v="${v%\"}"
      ;;
  esac
  printf '%s' "${v}" | sed -e 's/\\"/"/g' -e 's/\\\\/\\/g'
}
harbor_journal_string() {
  harbor_json_unquote "$(harbor_journal_raw "${1}" "${2}")"
}
harbor_observe_file() {
  local path="${1}"
  if [ ! -e "${path}" ] && [ ! -L "${path}" ]; then
    printf '"absent"'
    return 0
  fi
  if [ ! -f "${path}" ] || [ -L "${path}" ]; then
    printf '"unobservable:not-a-regular-file"'
    return 0
  fi
  printf '{"sha256":"%s","mode":"%s","owner":"%s"}' \
    "$(harbor_sha256 "${path}")" "$(harbor_stat_mode "${path}")" "$(harbor_json_escape "$(harbor_stat_owner "${path}")")"
}
harbor_journal_observe() {
  case "${1}" in
    file) harbor_observe_file "${2}" ;;
    *) printf '"unobservable:%s"' "$(harbor_json_escape "${1}")" ;;
  esac
}
harbor_journal_print_entry() {
  {
    printf 'journal entry %s is undecidable:\n' "$(basename "${1}")"
    printf '  op:         %s\n' "$(harbor_journal_string "${1}" op)"
    printf '  target:     %s\n' "$(harbor_journal_string "${1}" target)"
    printf '  pre_state:  %s\n' "$(harbor_journal_raw "${1}" pre_state)"
    printf '  post_state: %s\n' "$(harbor_journal_raw "${1}" post_state)"
    printf '  observed:   %s\n' "${2}"
  } >&2
}
