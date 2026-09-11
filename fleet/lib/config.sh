#!/bin/bash
# Operator access configuration (design sections 3.3 and 5.4).
harbor_config_path() {
  printf '%s/.config/harbor/config' "${1}"
}
harbor_config_validate_mode() {
  local file="${1}" mode="${2}"
  case "${mode}" in
    connect) ;;
    tailnet)
      # Refuse rather than silently downgrade to connect: provisioning the wrong
      # access mode is worse than not provisioning.
      harbor_die 3 config.tailnet "${file}: access_mode=tailnet cannot be provisioned by this release because harbor pair does not exist yet; configuration was not accepted"
      ;;
    # Both words, because both are the vocabulary and a reader of this message is
    # entitled to know the mode exists -- but with what the tailnet arm above would
    # say, so that a typo is not answered by naming a value this release also
    # refuses, one round trip later.
    *) harbor_die 3 config.access_mode "${file}: access_mode '${mode}' is unknown; the modes are connect and tailnet, and only connect can be provisioned by this release; configuration was not accepted" ;;
  esac
}
harbor_config_create() {
  # harbor_config_create STATE_ROOT HOME MODE: one journaled 0600 file.
  local root="${1}" home="${2}" mode="${3:-connect}" file dir tmp pre post ownership entry
  file="$(harbor_config_path "${home}")"
  harbor_config_validate_mode "${file}" "${mode}"
  dir="$(dirname "${file}")"
  mkdir -p "${dir}" || harbor_die 2 config.directory "cannot create ${dir}; configuration was not written"
  # Refused before the observation, because harbor_observe_file follows a link and
  # would record the target's hash while the rename below replaces the link itself:
  # the journal would then describe a file this entry never touched. lib/t3.sh
  # refuses a linked package for the same reason, and lib/ssh.sh a linked .ssh.
  [ ! -L "${file}" ] \
    || harbor_die 3 config.foreign "${file} is a symlink; Harbor writes its configuration at that path itself; configuration was not written"
  pre="$(harbor_observe_file "${file}")"
  case "${pre}" in
    '"unobservable:'*) harbor_die 3 config.foreign "${file} is not a regular file; configuration was not written" ;;
  esac
  tmp="${dir}/.tmp.config.${HARBOR_LOCK_ID_PID}"
  rm -f "${tmp}"
  # Created 0600 by umask rather than widened-then-narrowed: a chmod after the write
  # leaves the file at the ambient umask until it lands, and if the chmod is what
  # fails there is nothing left to narrow. The subshell keeps the umask off every
  # later redirection in this process.
  (
    umask 077
    # noclobber, because the unlink above and this redirection are two instants, and
    # the agents run as this operator: a process that wins the gap by putting a
    # symlink at the staged name would otherwise have this write follow it. With -C
    # the redirection fails on anything already at that path, link or not.
    set -C
    printf 'access_mode=%s\n' "${mode}" >"${tmp}"
  ) || {
    rm -f "${tmp}"
    harbor_die 2 config.stage "cannot stage ${tmp}; ${file} was not changed"
  }
  # Asserted, not set: umask cannot widen an existing file, so a mode other than 0600
  # here means something else owns that path, and staging onto it is refused.
  [ "$(harbor_stat_mode "${tmp}")" = 0600 ] || {
    rm -f "${tmp}"
    harbor_die 2 config.stage "${tmp} is not mode 0600; ${file} was not changed"
  }
  post="$(harbor_observe_file "${tmp}")"
  if [ "${post}" = "${pre}" ]; then
    rm -f "${tmp}"
    harbor_journal_create "${root}" file "${file}" observed applied "${pre}" "${post}"
    return 0
  fi
  ownership=modified
  [ "${pre}" != '"absent"' ] || ownership=created
  harbor_journal_create "${root}" file "${file}" "${ownership}" prepared "${pre}" "${post}"
  entry="${HARBOR_JOURNAL_ENTRY}"
  harbor_journal_sync_path "${tmp}"
  if ! mv -f "${tmp}" "${file}"; then
    rm -f "${tmp}"
    harbor_die 2 config.rename "cannot rename ${tmp} onto ${file}; configuration was not applied and $(basename "${entry}") stays prepared"
  fi
  harbor_journal_sync_path "${dir}"
  harbor_step config-file
  harbor_journal_set_phase "${entry}" applied
}
harbor_config_access_mode() {
  local file permissions line key value mode="" seen=0
  file="$(harbor_config_path "${1}")"
  # Before -f, which follows a link, as do stat and the read below. A link accepted
  # here would let a file outside this path decide the access mode, and let it change
  # without the journaled artifact at this path changing with it.
  [ ! -L "${file}" ] \
    || harbor_die 3 config.foreign "${file} is a symlink; Harbor reads its configuration at that path itself; configuration was not read"
  [ -f "${file}" ] \
    || harbor_die 3 config.missing "${file} is missing; run harbor provision; configuration was not read"
  # GNU stat uses -c; BSD stat on macOS needs -f instead. Check permission
  # bits before opening the file, including when its contents would be valid.
  permissions="$(stat -c '%a' "${file}" 2>/dev/null)" \
    || permissions="$(stat -f '%Lp' "${file}" 2>/dev/null)" \
    || harbor_die 3 config.permissions "cannot inspect permissions of ${file}; configuration was not read"
  case "${permissions}" in
    600) ;;
    *) harbor_die 3 config.permissions "${file} must have mode 0600, found ${permissions}; configuration was not read" ;;
  esac
  [ -r "${file}" ] || harbor_die 3 config.unreadable "cannot read ${file}; configuration was not accepted"
  while IFS= read -r line || [ -n "${line}" ]; do
    case "${line}" in
      '' | '#'*) continue ;;
      *=*) ;;
      *) harbor_die 3 config.syntax "${file}: line '${line}' is not key=value; configuration was not accepted" ;;
    esac
    key="${line%%=*}"
    value="${line#*=}"
    case "${key}" in
      access_mode) ;;
      *) harbor_die 3 config.unknown_key "${file}: unknown key '${key}'; configuration was not accepted" ;;
    esac
    [ "${seen}" = 0 ] || harbor_die 3 config.duplicate_key "${file}: duplicate access_mode; configuration was not accepted"
    seen=1
    mode="${value}"
  done <"${file}"
  [ "${seen}" = 1 ] || harbor_die 3 config.missing_key "${file}: missing access_mode; configuration was not accepted"
  harbor_config_validate_mode "${file}" "${mode}"
  printf '%s' "${mode}"
}
