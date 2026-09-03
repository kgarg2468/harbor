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
harbor_journal_next_seq() {
  local f last="" n
  for f in "${1}"/[0-9][0-9][0-9][0-9]-*.json; do
    [ -e "${f}" ] || continue
    last="$(basename "${f}")"
    last="${last%%-*}"
  done
  n=$((10#${last:-0} + 1))
  [ "${n}" -le 9999 ] || harbor_die 2 journal.full "${1} has reached entry 9999"
  HARBOR_JOURNAL_SEQ="$(printf '%04d' "${n}")"
}
harbor_journal_create() {
  local root="${1}" dir final tmp
  dir="${root}/journal"
  harbor_lock_assert_owner "${root}"
  harbor_journal_next_seq "${dir}"
  final="${dir}/${HARBOR_JOURNAL_SEQ}-${2}.json"
  tmp="${dir}/.tmp.${HARBOR_JOURNAL_SEQ}.${HARBOR_LOCK_ID_PID}"
  harbor_journal_render "${2}" "${3}" "${4}" "${5}" "${6}" "${7}" >"${tmp}"
  harbor_journal_sync_path "${tmp}"
  if ! ln "${tmp}" "${final}" 2>/dev/null; then
    rm -f "${tmp}"
    harbor_die 2 journal.collision "entry ${final} already exists; refusing to overwrite it with ${tmp}"
  fi
  rm -f "${tmp}"
  harbor_journal_sync_path "${dir}"
  harbor_log journal "created $(basename "${final}") ${4} ${5}"
  HARBOR_JOURNAL_ENTRY="${final}"
}
harbor_journal_malformed() {
  harbor_die 2 journal.malformed "${1} is not a canonical journal entry: ${2}"
}
# Fail-closed shape check: the entry must be, line for line, what
# harbor_journal_render writes. The positional parameters hold the keys still
# expected, in canonical order, so a key that is missing, repeated, unknown, or
# out of place fails on the first line that does not match.
harbor_journal_validate() {
  local entry="${1}" total n=0 line value phase=""
  [ -f "${entry}" ] || harbor_journal_malformed "${entry}" "not a regular file"
  total="$(awk 'END { print NR }' "${entry}")"
  case "${total}" in
    8) set -- op target ownership phase pre_state post_state ;;
    10) set -- op target ownership phase pre_state post_state resolved_by resolved_at ;;
    *) harbor_journal_malformed "${entry}" "expected 8 or 10 lines, found ${total}" ;;
  esac
  [ -z "$(tail -c 1 "${entry}")" ] || harbor_journal_malformed "${entry}" "line ${total} is not terminated by a newline"
  while IFS= read -r line || [ -n "${line}" ]; do
    n=$((n + 1))
    if [ "${n}" -eq 1 ]; then
      [ "${line}" = "{" ] || harbor_journal_malformed "${entry}" "line 1 must be {"
      continue
    fi
    if [ "${n}" -eq "${total}" ]; then
      [ "${line}" = "}" ] || harbor_journal_malformed "${entry}" "line ${n} must be }"
      continue
    fi
    case "${line}" in
      "  \"${1}\": "?*) ;;
      *) harbor_journal_malformed "${entry}" "line ${n} must be the ${1} field: keys in canonical order, one per line, two-space indent, one space after the colon" ;;
    esac
    value="${line#*: }"
    if [ "${n}" -lt "$((total - 1))" ]; then
      case "${value}" in
        *,) value="${value%,}" ;;
        *) harbor_journal_malformed "${entry}" "line ${n} (${1}) must end with a comma" ;;
      esac
    else
      case "${value}" in
        *,) harbor_journal_malformed "${entry}" "line ${n} (${1}) must not end with a comma" ;;
      esac
    fi
    [ -n "${value}" ] || harbor_journal_malformed "${entry}" "${1} is empty"
    case "${1}" in
      op | target | resolved_by | resolved_at)
        case "${value}" in
          \"?*\") ;;
          *) harbor_journal_malformed "${entry}" "${1} must be a non-empty quoted string" ;;
        esac
        ;;
      ownership)
        case "${value}" in
          '"created"' | '"modified"' | '"observed"') ;;
          *) harbor_journal_malformed "${entry}" "ownership must be created, modified, or observed" ;;
        esac
        ;;
      phase)
        case "${value}" in
          '"prepared"' | '"applied"' | '"reverted"') phase="${value}" ;;
          *) harbor_journal_malformed "${entry}" "phase must be prepared, applied, or reverted" ;;
        esac
        ;;
    esac
    shift
  done <"${entry}"
  if [ "${total}" -eq 10 ] && [ "${phase}" != '"reverted"' ]; then
    harbor_journal_malformed "${entry}" "resolved_by and resolved_at are valid only with phase reverted"
  fi
}
harbor_journal_set_phase() {
  local entry="${1}" phase="${2}" resolved_by="${3:-}"
  local dir root tmp op target ownership pre post at=""
  dir="$(dirname "${entry}")"
  root="$(dirname "${dir}")"
  case "${phase}" in
    prepared | applied | reverted) ;;
    *) harbor_die 3 journal.phase "unknown phase ${phase}" ;;
  esac
  harbor_lock_assert_owner "${root}"
  harbor_journal_validate "${entry}"
  op="$(harbor_journal_string "${entry}" op)"
  target="$(harbor_journal_string "${entry}" target)"
  ownership="$(harbor_journal_string "${entry}" ownership)"
  pre="$(harbor_journal_raw "${entry}" pre_state)"
  post="$(harbor_journal_raw "${entry}" post_state)"
  [ -z "${resolved_by}" ] || at="$(harbor_utc_now)"
  tmp="${dir}/.tmp.$(basename "${entry}").${HARBOR_LOCK_ID_PID}"
  harbor_journal_render "${op}" "${target}" "${ownership}" "${phase}" "${pre}" "${post}" "${resolved_by}" "${at}" >"${tmp}"
  harbor_journal_sync_path "${tmp}"
  mv -f "${tmp}" "${entry}"
  harbor_journal_sync_path "${dir}"
  harbor_log journal "$(basename "${entry}") ${phase}${resolved_by:+ resolved_by=${resolved_by}}"
}
harbor_journal_recover() {
  local root="${1}" except="${2:-}" dir entry base seq phase op target pre post observed
  dir="${root}/journal"
  HARBOR_JOURNAL_UNDECIDABLE=""
  [ -d "${dir}" ] || return 0
  # Fail closed on any malformed entry before touching any entry.
  for entry in "${dir}"/[0-9][0-9][0-9][0-9]-*.json; do
    [ -e "${entry}" ] || continue
    harbor_journal_validate "${entry}"
  done
  for entry in "${dir}"/[0-9][0-9][0-9][0-9]-*.json; do
    [ -e "${entry}" ] || continue
    base="$(basename "${entry}")"
    seq="${base%%-*}"
    phase="$(harbor_journal_string "${entry}" phase)"
    [ "${phase}" = "prepared" ] || continue
    [ "${seq}" != "${except}" ] || continue
    op="$(harbor_journal_string "${entry}" op)"
    target="$(harbor_journal_string "${entry}" target)"
    pre="$(harbor_journal_raw "${entry}" pre_state)"
    post="$(harbor_journal_raw "${entry}" post_state)"
    observed="$(harbor_journal_observe "${op}" "${target}")"
    if [ "${observed}" = "${pre}" ]; then
      harbor_journal_set_phase "${entry}" reverted
      harbor_log recovery "${base} reverted (state equals pre_state)"
    elif [ "${observed}" = "${post}" ]; then
      harbor_journal_set_phase "${entry}" applied
      harbor_log recovery "${base} applied (state equals post_state)"
    else
      harbor_journal_print_entry "${entry}" "${observed}"
      HARBOR_JOURNAL_UNDECIDABLE="${HARBOR_JOURNAL_UNDECIDABLE} ${seq}"
    fi
  done
  HARBOR_JOURNAL_UNDECIDABLE="${HARBOR_JOURNAL_UNDECIDABLE# }"
  if [ -n "${HARBOR_JOURNAL_UNDECIDABLE}" ] && [ -z "${except}" ]; then
    harbor_die 2 journal.undecidable "prepared entries ${HARBOR_JOURNAL_UNDECIDABLE} cannot be decided; follow docs/runbook.md for each op and rerun, or run: harbor journal resolve <NNNN> --reverted"
  fi
  return 0
}
