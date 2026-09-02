#!/bin/bash
# Check results (design section 5.6): an accumulator of id, state, reason, and detail
# records, the exit-code rule, and JSON and text rendering. PR 7 adds the checks.
# shellcheck disable=SC2034
HARBOR_CHECKS=""
harbor_check_reset() {
  HARBOR_CHECKS=""
}
harbor_check_add() {
  local id="${1}" state="${2}" reason="${3:-}" detail="${4:-}" tab
  case "${state}" in
    pass | degraded | broken | unknown) ;;
    *) harbor_die 3 checks.state "unknown check state '${state}' for ${id}" ;;
  esac
  tab="$(printf '\t')"
  id="$(printf '%s' "${id}" | tr '\t\n\r' '   ')"
  reason="$(printf '%s' "${reason}" | tr '\t\n\r' '   ')"
  detail="$(printf '%s' "${detail}" | tr '\t\n\r' '   ')"
  HARBOR_CHECKS="${HARBOR_CHECKS}${id}${tab}${state}${tab}${reason}${tab}${detail}
"
}
harbor_check_exit_code() {
  local worst=0 line state reason
  while IFS= read -r line; do
    [ -n "${line}" ] || continue
    state="$(printf '%s' "${line}" | cut -f2)"
    reason="$(printf '%s' "${line}" | cut -f3)"
    case "${state}" in
      broken) worst=2 ;;
      degraded) [ "${worst}" -ge 1 ] || worst=1 ;;
      unknown)
        case "${reason}" in
          requires_root | busy | requires_operator) ;;
          *) [ "${worst}" -ge 1 ] || worst=1 ;;
        esac
        ;;
    esac
  done <<EOF
${HARBOR_CHECKS}
EOF
  printf '%s' "${worst}"
}
harbor_checks_json() {
  local line sep="" id state reason detail
  printf '{"checks":['
  while IFS= read -r line; do
    [ -n "${line}" ] || continue
    id="$(printf '%s' "${line}" | cut -f1)"
    state="$(printf '%s' "${line}" | cut -f2)"
    reason="$(printf '%s' "${line}" | cut -f3)"
    detail="$(printf '%s' "${line}" | cut -f4)"
    printf '%s{"id":"%s","state":"%s","reason":"%s","detail":"%s"}' "${sep}" \
      "$(harbor_json_escape "${id}")" "${state}" "$(harbor_json_escape "${reason}")" "$(harbor_json_escape "${detail}")"
    sep=","
  done <<EOF
${HARBOR_CHECKS}
EOF
  printf ']}\n'
}
harbor_checks_text() {
  local line
  while IFS= read -r line; do
    [ -n "${line}" ] || continue
    printf '%s\n' "${line}" | tr '\t' ' '
  done <<EOF
${HARBOR_CHECKS}
EOF
}
