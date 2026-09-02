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
    case "${value}" in
      *[[:space:]]*) harbor_die 3 versions.syntax "${file}: value of ${key} contains whitespace" ;;
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
