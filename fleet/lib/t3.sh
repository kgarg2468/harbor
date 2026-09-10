#!/bin/bash
# T3's npm CLI (design section 2), installed into the same operator-owned prefix
# as the agents. HOME is explicit throughout: inspection and installation must name
# the operator's home even when the calling process has a different ambient HOME.
# lib/runtime.sh and lib/agents.sh must be sourced before this library, because they
# own the reader registry and the shared prefix and recovery home respectively.
# harbor_t3_bin HOME: npm's executable path, without creating the prefix. Inspection
# must not be what brings an install into existence.
harbor_t3_bin() {
  printf '%s/bin/t3' "$(harbor_agents_prefix "${1}")"
}
# harbor_t3_installed_version HOME: absent, the bare version, or exit 2 when the
# executable cannot answer. The pinned CLI prints "t3 v0.0.38"; both decorations
# belong to T3, so neither an undecorated number nor another vendor's spelling is a
# version this reader can vouch for. Recovery needs an answer, never a guess.
harbor_t3_installed_version() {
  local bin out version="" rest field shaped
  bin="$(harbor_t3_bin "${1}")"
  if [ ! -f "${bin}" ] || [ ! -x "${bin}" ]; then
    printf 'absent'
    return 0
  fi
  out="$("${bin}" --version 2>/dev/null)" || harbor_die 2 t3.unreadable "${bin} --version failed; remove ${bin} by hand and rerun harbor provision so t3 is reinstalled"
  case "${out}" in
    't3 v'*) version="${out#t3 v}" ;;
  esac
  # Split the three numeric fields: a glob alone also accepts empty or extra fields.
  # Enumerate digits so the fence does not depend on locale collation.
  rest="${version#*.}"
  case "${version}" in
    *.*.*.*) shaped=no ;;
    *.*.*) shaped=three ;;
    *) shaped=no ;;
  esac
  for field in "${version%%.*}" "${rest%%.*}" "${rest#*.}"; do
    case "${field}" in
      "" | *[!0123456789]*) shaped=no ;;
    esac
  done
  [ "${shaped}" = three ] || version=""
  [ -n "${version}" ] || harbor_die 2 t3.unreadable "${bin} --version printed '${out}', not a t3 version; remove ${bin} by hand and rerun harbor provision so t3 is reinstalled"
  printf '%s' "${version}"
}
# harbor_t3_package_dir HOME: the installed npm package, not a T3 service home.
# Like the bin path, asking for it creates nothing.
harbor_t3_package_dir() {
  printf '%s/node_modules/t3' "$(harbor_agents_prefix "${1}")"
}
# harbor_t3_package_engines HOME: the installed package's own engines.node range.
# The pinned package is pretty-printed JSON. Anchor both keys to line starts, since
# a string cannot contain a raw newline, and read node only inside engines: a volta
# block elsewhere in the package must never become the runtime requirement. No jq
# is needed in lib/, which also runs on macOS before any bootstrap dependencies.
# A missing or unreadable field is exit 2 naming the package, never an empty range.
harbor_t3_package_engines() {
  local package range
  package="$(harbor_t3_package_dir "${1}")/package.json"
  [ -f "${package}" ] && [ -r "${package}" ] || harbor_die 2 t3.engines_unreadable "${package} is absent or unreadable; rerun harbor provision to install the locked t3 package"
  range="$(sed -n '/^[[:space:]]*"engines"[[:space:]]*:[[:space:]]*{[[:space:]]*$/,/^[[:space:]]*}/ {
    s/^[[:space:]]*"node"[[:space:]]*:[[:space:]]*"\([^"]*\)"[[:space:]]*,\{0,1\}[[:space:]]*$/\1/p
  }' "${package}")" || harbor_die 2 t3.engines_unreadable "${package} could not be read; rerun harbor provision to install the locked t3 package"
  [ -n "${range}" ] || harbor_die 2 t3.engines_unreadable "${package} carries no engines.node range; rerun harbor provision to install the locked t3 package"
  printf '%s' "${range}"
}
# harbor_t3_reader: recovery has no home argument, so use the same explicit home
# the agent readers use. An unset HARBOR_AGENTS_HOME keeps harbor_agents_home's exit
# 2; falling back to HOME could confidently observe an entirely different install.
harbor_t3_reader() {
  local home
  home="$(harbor_agents_home)" || exit "$?"
  harbor_t3_installed_version "${home}"
}
# harbor_t3_install STATE_ROOT HOME: inspect, prepare one runtime-install entry,
# install, then mark applied only after the executable reports the locked version.
# A matching version is a no-op. The package and version passed to npm stay together
# in t3_install; t3_version supplies the comparison and the journal's post_state,
# as in harbor_agents_install. Lock consistency belongs to the repository lint.
harbor_t3_install() {
  local root="${1}" home="${2}"
  local locked method spec prefix bin
  local pre pre_json ownership entry post out
  locked="$(harbor_version_require t3_version)" || exit "$?"
  method="$(harbor_version_require t3_install)" || exit "$?"
  case "${method}" in
    npm:?*@?*) spec="${method#npm:}" ;;
    *) harbor_die 3 t3.install_method "t3_install is '${method}' in ${HARBOR_VERSIONS_FILE}, which is not the npm:<package>@<version> form design section 2 records an install method in; nothing was installed" ;;
  esac
  prefix="$(harbor_agents_prefix "${home}")"
  bin="$(harbor_t3_bin "${home}")" || exit "$?"
  # Set before the first thing that can fail, so that every exit below this line
  # leaves the readers above able to observe the entry this run may have written.
  # Read by harbor_agents_home in lib/agents.sh through harbor_t3_reader.
  # shellcheck disable=SC2034
  HARBOR_AGENTS_HOME="${home}"
  pre="$(harbor_t3_installed_version "${home}")" || exit "$?"
  if [ "${pre}" = "${locked}" ]; then
    harbor_log t3 "t3 ${locked} at ${bin} equals the lock; nothing to do"
    return 0
  fi
  if [ "${pre}" = absent ]; then
    ownership=created
    pre_json='"absent"'
  else
    ownership=modified
    pre_json="\"${pre}\""
  fi
  harbor_journal_create "${root}" runtime-install "t3" "${ownership}" prepared "${pre_json}" "\"${locked}\""
  entry="${HARBOR_JOURNAL_ENTRY}"
  harbor_step "t3-prepared"
  # The prefix is this install's to create, which is why nothing above it creates one:
  # inspection reports on the prefix and must not be what brings it into existence.
  mkdir -p "${prefix}"
  chmod 0755 "${prefix}"
  harbor_log_vendor npm install --global --prefix "${prefix}" "${spec}"
  # The vendor's own output is captured rather than passed through, so the failure
  # below can name it: an npm that fails says why in its output and nowhere else, and
  # an operator reading a prepared entry needs that text beside the entry's name. It
  # is folded onto one line for the same reason harbor_node_operator_probe folds its
  # probe output, and it reaches the terminal only, never the log, since harbor_die
  # logs the id and the exit code and not the message.
  if ! out="$(npm install --global --prefix "${prefix}" "${spec}" 2>&1)"; then
    out="$(printf '%s' "${out}" | tr '\n\r' '  ')"
    harbor_die 2 t3.install_failed "npm install --global --prefix ${prefix} ${spec} failed: ${out}; $(basename "${entry}") stays prepared, rerun after fixing the cause"
  fi
  harbor_step "t3-installed"
  post="$(harbor_t3_installed_version "${home}")" || exit "$?"
  if [ "${post}" != "${locked}" ]; then
    harbor_die 2 t3.verify "${bin} --version reports ${post} after installing ${spec}; $(basename "${entry}") stays prepared and recovery will decide it from what is at ${bin}"
  fi
  harbor_journal_set_phase "${entry}" applied
  harbor_step "t3-applied"
  harbor_msg "installed t3 ${locked} at ${bin}"
}
# harbor_t3_run HOME ARGS...: the single invocation seam for callers driving T3.
# Check the installed executable before passing it any operation, so a missing or
# different version cannot act on a service or a T3 home. The vendor owns stdout,
# stderr, and the exit status once the pinned executable is allowed to run.
harbor_t3_run() {
  local home="${1}" bin locked installed
  shift
  bin="$(harbor_t3_bin "${home}")"
  locked="$(harbor_version_require t3_version)" || exit "$?"
  installed="$(harbor_t3_installed_version "${home}")" || exit "$?"
  [ "${installed}" = "${locked}" ] || harbor_die 3 t3.version_mismatch "${bin} reports ${installed}, but the lock requires ${locked}; run harbor provision before invoking t3"
  harbor_log_vendor "${bin}" ${1+"$@"}
  "${bin}" ${1+"$@"}
}
# harbor_t3_service_status HOME: the pinned formatter has no JSON mode and exits
# zero in every state. Only its whole status lines decide the answer; an empty or
# unfamiliar body is unknown, never evidence that a service is installed.
harbor_t3_service_status() {
  local home="${1}" locked body rc=0 word=unknown newline xt=0
  newline='
'
  locked="$(harbor_version_require t3_version)" || exit "$?"
  # As with agent auth status, keep the vendor body out of inherited xtrace.
  case "$-" in *x*) xt=1 ;; esac
  [ "${xt}" = 0 ] || set +x
  body="$(harbor_t3_run "${home}" service status 2>&1)" || rc="$?"
  # Surround the body with newlines so a neighbouring path cannot supply a phrase.
  case "${newline}${body}${newline}" in
    # service-status/installed-current: the CLI version must agree with the lock.
    *"${newline}  Status: installed · t3@${locked}${newline}"*) word="installed-current" ;;
    # service-status/update-pending
    *"${newline}  Status: needs an update or repair${newline}"*) word="update-pending" ;;
    # service-status/not-installed
    *"${newline}  Status: not installed${newline}"*) word="not-installed" ;;
    # service-status/unsupported
    *"${newline}  Status: unavailable on this machine${newline}"*) word=unsupported ;;
  esac
  unset body
  [ "${xt}" = 0 ] || set -x
  harbor_log t3 "service status is ${word}; t3 exited ${rc}"
  printf '%s' "${word}"
}
# harbor_t3_service_healthy HOME: both the vendor and systemd must agree. Reading
# health does not install or repair a unit, and the vendor log need not exist.
harbor_t3_service_healthy() {
  local active
  [ "$(harbor_t3_service_status "${1}")" = installed-current ] || return 1
  active="$(HOME="${1}" systemctl --user is-active t3code.service 2>/dev/null)" || return 1
  [ "${active}" = active ]
}
# The t3-service op has its own observer; recovery supplies the explicit operator
# home through the same context as the CLI readers, never the ambient HOME.
harbor_observe_op_t3_service() {
  local home state
  home="$(harbor_agents_home)" || exit "$?"
  state="$(harbor_t3_service_status "${home}")" || exit "$?"
  printf '"%s"' "$(harbor_json_escape "${state}")"
}
# harbor_t3_service_install STATE_ROOT HOME: the vendor owns the unit lifecycle.
# Prepare before invoking it and attest applied only when both readings agree.
harbor_t3_service_install() {
  local root="${1}" home="${2}" pre ownership entry out post active active_rc=0
  # shellcheck disable=SC2034
  HARBOR_AGENTS_HOME="${home}"
  pre="$(harbor_t3_service_status "${home}")" || exit "$?"
  # An unreadable state is a refusal rather than an install, because the entry this
  # would write names a transition out of a state Harbor never read. Installing over
  # it would leave the journal vouching for a before that was a guess.
  [ "${pre}" != unknown ] || harbor_die 3 t3.service_unknown "t3 service status did not answer with a state this pinned build recognizes, so Harbor will not install over it: the entry would record a transition out of a state it never read; ask t3 itself with 'harbor service status' and rerun harbor provision once it answers; nothing was installed or journaled"
  if [ "${pre}" = installed-current ] && harbor_t3_service_healthy "${home}"; then
    return 0
  fi
  ownership=modified
  [ "${pre}" != not-installed ] || ownership=created
  harbor_journal_create "${root}" t3-service t3code.service "${ownership}" prepared "\"$(harbor_json_escape "${pre}")\"" '"installed-current"' || exit "$?"
  entry="${HARBOR_JOURNAL_ENTRY}"
  harbor_step "t3-service-prepared"
  if ! out="$(harbor_t3_run "${home}" service install 2>&1)"; then
    out="$(printf '%s' "${out}" | tr '\n\r' '  ')"
    harbor_die 2 t3.service_install_failed "t3 service install failed: ${out}; $(basename "${entry}") stays prepared, rerun after fixing the cause"
  fi
  harbor_step "t3-service-installed"
  post="$(harbor_t3_service_status "${home}")" || exit "$?"
  active="$(HOME="${home}" systemctl --user is-active t3code.service 2>/dev/null)" || active_rc="$?"
  if [ "${post}" != installed-current ] || [ "${active}" != active ] || [ "${active_rc}" != 0 ]; then
    harbor_die 2 t3.service_verify "after t3 service install: service status=${post}, is-active=${active} (exit ${active_rc}); $(basename "${entry}") stays prepared"
  fi
  harbor_journal_set_phase "${entry}" applied || exit "$?"
  harbor_step "t3-service-applied"
  harbor_msg "installed t3 service"
}
# Register beside the definition so every process sourcing this library can observe
# a prepared t3 runtime-install entry, including recovery without an install.
harbor_runtime_reader_register t3 harbor_t3_reader
