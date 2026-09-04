#!/bin/bash
# versions.lock loading (design section 2): the thirteen-key schema, strict parsing,
# and lookups. Values stay empty until the PR that installs each component.
# shellcheck disable=SC2034
HARBOR_VERSION_KEYS="ubuntu_release tailscale_apt_channel tailscale_version nodejs_version nodejs_install nodejs_sha256 claude_code_version claude_code_install codex_version codex_install t3_version t3_install t3_engines_node"
harbor_versions_lock_path() {
  printf '%s/versions.lock' "${HARBOR_ROOT}"
}
harbor_versions_load() {
  local file="${1}" line key value seen="" k
  [ -r "${file}" ] || harbor_die 3 versions.missing "cannot read ${file}"
  HARBOR_VERSIONS=""
  HARBOR_VERSIONS_FILE="${file}"
  while IFS= read -r line || [ -n "${line}" ]; do
    case "${line}" in
      '' | '#'*) continue ;;
      *=*) ;;
      *) harbor_die 3 versions.syntax "${file}: line '${line}' is not key=value" ;;
    esac
    key="${line%%=*}"
    value="${line#*=}"
    case " ${HARBOR_VERSION_KEYS} " in
      *" ${key} "*) ;;
      *) harbor_die 3 versions.unknown_key "${file}: unknown key ${key}" ;;
    esac
    case " ${seen} " in
      *" ${key} "*) harbor_die 3 versions.duplicate_key "${file}: duplicate key ${key}" ;;
    esac
    case "${key}" in
      t3_engines_node)
        # The one exception: this range is copied verbatim from the pinned package
        # and a semver AND range ('>=22.16 <23') is a different range without its
        # space, so an internal space is legal here. Nothing else is: a tab, a
        # carriage return, and leading or trailing whitespace still fail.
        case "${value// /}" in
          *[[:space:]]*) harbor_die 3 versions.syntax "${file}: value of ${key} contains whitespace other than a space" ;;
        esac
        case "${value}" in
          [[:space:]]* | *[[:space:]]) harbor_die 3 versions.syntax "${file}: value of ${key} has leading or trailing whitespace" ;;
        esac
        ;;
      *)
        case "${value}" in
          *[[:space:]]*) harbor_die 3 versions.syntax "${file}: value of ${key} contains whitespace" ;;
        esac
        ;;
    esac
    seen="${seen} ${key}"
    HARBOR_VERSIONS="${HARBOR_VERSIONS}${key}=${value}
"
  done <"${file}"
  for k in ${HARBOR_VERSION_KEYS}; do
    case " ${seen} " in
      *" ${k} "*) ;;
      *) harbor_die 3 versions.missing_key "${file}: missing key ${k}" ;;
    esac
  done
}
harbor_version_get() {
  local key="${1}" line
  case " ${HARBOR_VERSION_KEYS} " in
    *" ${key} "*) ;;
    *) harbor_die 3 versions.unknown_key "no such versions.lock key ${key}" ;;
  esac
  line="$(printf '%s' "${HARBOR_VERSIONS}" | grep "^${key}=" || true)"
  printf '%s' "${line#*=}"
}
harbor_version_require() {
  local value
  value="$(harbor_version_get "${1}")"
  [ -n "${value}" ] || harbor_die 3 versions.unset "${HARBOR_VERSIONS_FILE}: ${1} is not pinned yet"
  printf '%s' "${value}"
}
# Semver range satisfaction (design section 2, "Node.js"): the range forms the
# pinned T3 releases actually use, in the bash 3.2 subset. Every comparison is
# numeric per component, never lexical. Fail-closed: an input outside the grammar
# below exits 3 rather than guessing, and never returns a silent true.
harbor_semver_parse() {
  # harbor_semver_parse <string> <die_id>: prints "MAJOR MINOR PATCH COUNT" for a
  # one- to three-component numeric version, zero-filling the omitted components.
  # COUNT is how many the string spelled out, which the caret bound needs.
  local raw="${1}" id="${2}" rest="${1}" part="" last=0 count=0 major=0 minor=0 patch=0
  while [ "${last}" = 0 ]; do
    case "${rest}" in
      *.*)
        part="${rest%%.*}"
        rest="${rest#*.}"
        ;;
      *)
        part="${rest}"
        last=1
        ;;
    esac
    case "${part}" in
      0 | [1-9] | [1-9][0-9]*) ;;
      *) harbor_die 3 "${id}" "'${raw}' is not a dot-separated numeric version" ;;
    esac
    case "${part}" in
      *[!0-9]*) harbor_die 3 "${id}" "'${raw}' is not a dot-separated numeric version" ;;
    esac
    count=$((count + 1))
    case "${count}" in
      1) major="${part}" ;;
      2) minor="${part}" ;;
      3) patch="${part}" ;;
      *) harbor_die 3 "${id}" "'${raw}' has more than three components" ;;
    esac
  done
  printf '%s %s %s %s' "${major}" "${minor}" "${patch}" "${count}"
}
harbor_semver_cmp() {
  # harbor_semver_cmp M1 N1 P1 M2 N2 P2: prints -1, 0, or 1 comparing the two
  # triples component by component with integer tests, so 24.20.0 is above
  # 24.9.0 where a string comparison would put it below.
  if [ "${1}" -gt "${4}" ]; then
    printf '%s' 1
  elif [ "${1}" -lt "${4}" ]; then
    printf '%s' -1
  elif [ "${2}" -gt "${5}" ]; then
    printf '%s' 1
  elif [ "${2}" -lt "${5}" ]; then
    printf '%s' -1
  elif [ "${3}" -gt "${6}" ]; then
    printf '%s' 1
  elif [ "${3}" -lt "${6}" ]; then
    printf '%s' -1
  else
    printf '%s' 0
  fi
}
harbor_semver_term() {
  # harbor_semver_term <comparator> MAJOR MINOR PATCH: 0 when the version triple
  # satisfies the single comparator, 1 when it does not. The supported
  # comparators are >=, >, <=, < and ^ on a one- to three-component numeric
  # version; anything else exits 3.
  local term="${1}" vmaj="${2}" vmin="${3}" vpat="${4}"
  local op operand parsed omaj omin opat ocount umaj=0 umin=0 upat=0 cmp
  case "${term}" in
    '>='*)
      op='>='
      operand="${term#>=}"
      ;;
    '<='*)
      op='<='
      operand="${term#<=}"
      ;;
    '>'*)
      op='>'
      operand="${term#>}"
      ;;
    '<'*)
      op='<'
      operand="${term#<}"
      ;;
    '^'*)
      op='^'
      operand="${term#^}"
      ;;
    *)
      harbor_die 3 versions.semver_range "unsupported range comparator '${term}'"
      ;;
  esac
  parsed="$(harbor_semver_parse "${operand}" versions.semver_range)" || exit 3
  omaj="${parsed%% *}"
  parsed="${parsed#* }"
  omin="${parsed%% *}"
  parsed="${parsed#* }"
  opat="${parsed%% *}"
  ocount="${parsed##* }"
  if [ "${op}" = '^' ]; then
    # Caret: at or above the operand and below the next release that may break
    # it, which is the leftmost non-zero component incremented, or the component
    # after the last one the range spelled out when every one of them is zero.
    if [ "${omaj}" -ne 0 ]; then
      umaj=$((omaj + 1))
    elif [ "${ocount}" -eq 1 ]; then
      umaj=1
    elif [ "${omin}" -ne 0 ]; then
      umin=$((omin + 1))
    elif [ "${ocount}" -eq 2 ]; then
      umin=1
    else
      upat=$((opat + 1))
    fi
    cmp="$(harbor_semver_cmp "${vmaj}" "${vmin}" "${vpat}" "${omaj}" "${omin}" "${opat}")"
    [ "${cmp}" != '-1' ] || return 1
    cmp="$(harbor_semver_cmp "${vmaj}" "${vmin}" "${vpat}" "${umaj}" "${umin}" "${upat}")"
    [ "${cmp}" = '-1' ] || return 1
    return 0
  fi
  cmp="$(harbor_semver_cmp "${vmaj}" "${vmin}" "${vpat}" "${omaj}" "${omin}" "${opat}")"
  case "${op}" in
    '>=') [ "${cmp}" != '-1' ] ;;
    '>') [ "${cmp}" = '1' ] ;;
    '<=') [ "${cmp}" != '1' ] ;;
    *) [ "${cmp}" = '-1' ] ;;
  esac
}
harbor_semver_satisfies() {
  # harbor_semver_satisfies <version> <range>: 0 when the exact major.minor.patch
  # version satisfies the range, 1 when it does not. The grammar is one or more
  # alternatives separated by '||', each alternative one comparator or two
  # comparators separated by a space, which are ANDed. Every alternative is
  # parsed even once one has matched, so a malformed tail still fails closed.
  local version="${1}" range="${2}"
  local parsed vmaj vmin vpat vcount
  local rest alt tail term last=0 result=1 ok
  parsed="$(harbor_semver_parse "${version}" versions.semver_version)" || exit 3
  vmaj="${parsed%% *}"
  parsed="${parsed#* }"
  vmin="${parsed%% *}"
  parsed="${parsed#* }"
  vpat="${parsed%% *}"
  vcount="${parsed##* }"
  [ "${vcount}" = 3 ] \
    || harbor_die 3 versions.semver_version "'${version}' is not an exact major.minor.patch version"
  rest="${range}"
  while [ "${last}" = 0 ]; do
    case "${rest}" in
      *'||'*)
        alt="${rest%%||*}"
        rest="${rest#*||}"
        ;;
      *)
        alt="${rest}"
        last=1
        ;;
    esac
    while :; do
      case "${alt}" in
        ' '*) alt="${alt# }" ;;
        *' ') alt="${alt% }" ;;
        *) break ;;
      esac
    done
    case "${alt}" in
      *' '*)
        term="${alt%% *}"
        tail="${alt#* }"
        while :; do
          case "${tail}" in
            ' '*) tail="${tail# }" ;;
            *) break ;;
          esac
        done
        ;;
      *)
        term="${alt}"
        tail=""
        ;;
    esac
    ok=1
    harbor_semver_term "${term}" "${vmaj}" "${vmin}" "${vpat}" || ok=0
    if [ -n "${tail}" ]; then
      case "${tail}" in
        *' '*) harbor_die 3 versions.semver_range "'${alt}' is not one comparator or two separated by a space" ;;
      esac
      harbor_semver_term "${tail}" "${vmaj}" "${vmin}" "${vpat}" || ok=0
    fi
    if [ "${ok}" = 1 ]; then
      result=0
    fi
  done
  return "${result}"
}
harbor_versions_require_node_range() {
  # harbor_versions_require_node_range <lockfile>: the design section 2 gate. The
  # locked nodejs_version must satisfy the locked t3_engines_node, which is T3's
  # own engines.node range, so Harbor never hard-codes that range in code.
  local file="${1}" version range
  harbor_versions_load "${file}"
  version="$(harbor_version_require nodejs_version)" || exit 3
  range="$(harbor_version_require t3_engines_node)" || exit 3
  if ! harbor_semver_satisfies "${version}" "${range}"; then
    harbor_die 3 versions.node_range "${file}: nodejs_version ${version} does not satisfy t3_engines_node ${range}"
  fi
}
