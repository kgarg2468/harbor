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
# This is a text reader standing in for a JSON reader, so its contract is the narrow
# one that keeps that honest: it recognizes the pinned package's canonical block and
# nothing else. The node line must be the line *immediately* inside the engines line,
# at the pin's measured two- and four-space depths, because a range match anywhere
# within an enclosing block accepts `.engines.metadata.node` as though it were
# `.engines.node` — indentation carries no structure in JSON, so adjacency is what
# distinguishes them here. ASCII space and tab are spelled out rather than using
# [[:space:]], which is locale-dependent and admits U+00A0 as whitespace. Formatting
# drift therefore fails closed rather than supplying some other object's range. No jq
# is needed in lib/, which also runs on macOS before any bootstrap dependencies.
# A missing or unreadable field is exit 2 naming the package, never an empty range.
harbor_t3_package_engines() {
  local package out range
  package="$(harbor_t3_package_dir "${1}")/package.json"
  # Refuse links before any reader can follow one into a credential store.
  [ ! -L "${package}" ] || harbor_die 2 t3.engines_unreadable "${package} is a symlink; rerun harbor provision to install the locked t3 package"
  [ -f "${package}" ] && [ -r "${package}" ] || harbor_die 2 t3.engines_unreadable "${package} is absent or unreadable; rerun harbor provision to install the locked t3 package"
  # One structural pass rather than a line match, so the block's shape is what is
  # judged: the header must appear exactly once, the block must be explicitly closed
  # at its own depth, and the node line must be the block's first line. Matching a
  # line at a time cannot see either end of a block, so a duplicate node key inside
  # one block reads as the first of the two while JSON's last-wins makes the second
  # the package's actual requirement, and a header left dangling at end of file
  # simply never yields a line. Both are refusals here. The token on stdout keeps
  # awk's own exit status free to mean only that the file could not be read.
  out="$(awk '
    /^  "engines"[ 	]*:[ 	]*[{][ 	]*$/ { headers++; inblock = 1; depth = 0; next }
    inblock {
      depth++
      if ($0 ~ /^  [}][ 	]*,?[ 	]*$/) { inblock = 0; closed++; next }
      if ($0 ~ /^    "node"[ 	]*:[ 	]*"[^"]*"[ 	]*,?[ 	]*$/) {
        nodes++
        if (depth == 1) { adjacent++ }
        range = $0
        sub(/^    "node"[ 	]*:[ 	]*"/, "", range)
        sub(/"[ 	]*,?[ 	]*$/, "", range)
      }
      next
    }
    END {
      if (headers > 1 || nodes > 1) { print "dup"; exit 0 }
      if (headers != 1 || closed != 1 || nodes != 1 || adjacent != 1) { print "none"; exit 0 }
      print "ok " range
    }
  ' "${package}")" || harbor_die 2 t3.engines_unreadable "${package} could not be read; rerun harbor provision to install the locked t3 package"
  # Two declarations disagree by construction, and neither one can be called the
  # package's requirement, so the count is refused before the value is looked at.
  case "${out}" in
    dup) harbor_die 2 t3.engines_unreadable "${package} declares more than one engines.node range; rerun harbor provision to install the locked t3 package" ;;
  esac
  range=""
  case "${out}" in
    'ok '*) range="${out#ok }" ;;
  esac
  [ -n "${range}" ] || harbor_die 2 t3.engines_unreadable "${package} carries no engines.node range; rerun harbor provision to install the locked t3 package"
  printf '%s' "${range}"
}
# harbor_t3_require_engines HOME: the provision-time twin of the lint's range check
# (design section 2), run against the package that is actually installed. Both halves
# of the comparison belong to lib/versions.sh, which refuses an empty range, a range
# that has drifted from the lock, and an unsatisfying Node each with its own message;
# this function only supplies the two values, so those refusals keep one wording.
harbor_t3_require_engines() {
  local home="${1}" range out version rest field shaped
  range="$(harbor_t3_package_engines "${home}")" || exit "$?"
  # The launcher has no interactive profile, so probe the operator's login shell
  # instead of trusting the Node inherited by this provisioning process. A node the
  # login shell cannot resolve, or a shadowed one, is the failure this check is for,
  # so the probe must go through the same resolution the launcher will.
  out="$(HOME="${home}" sh -lc 'node --version' 2>/dev/null)" || out=""
  version=""
  case "${out}" in
    v*) version="${out#v}" ;;
  esac
  # The same three-field fence harbor_t3_installed_version applies, enumerated for
  # the same reason: a bracket range would resolve by the ambient locale's collation.
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
  [ "${shaped}" = three ] || harbor_die 3 t3.node_shell "the operator's login shell could not resolve a node reporting a v-prefixed three-field numeric version; fix the operator's shell profile / PATH, including any shadowed node: T3's service launcher runs without an interactive profile"
  harbor_versions_require_installed_engines "${version}" "${range}"
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
  local pre pre_json ownership entry post out xt=0 rc=0
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
  # Vendor output may contain private bytes; keep every expansion off xtrace.
  case "$-" in *x*) xt=1 ;; esac
  [ "${xt}" = 0 ] || set +x
  if ! out="$(npm install --global --prefix "${prefix}" "${spec}" 2>&1)"; then
    out="$(printf '%s' "${out}" | tr '\n\r' '  ')"
    # Isolate the fatal diagnostic so cleanup can restore the caller's trace.
    (harbor_die 2 t3.install_failed "npm install --global --prefix ${prefix} ${spec} failed: ${out}; $(basename "${entry}") stays prepared, rerun after fixing the cause") || rc="$?"
    unset out
    [ "${xt}" = 0 ] || set -x
    exit "${rc}"
  fi
  unset out
  [ "${xt}" = 0 ] || set -x
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
# harbor_service_cmd: labelled pass-through; no lock is needed because this command
# holds no Harbor state and writes no journal (none of these verbs has an inverse).
harbor_service_cmd() {
  local verb="${1:-}" bin
  case "${verb}" in
    start | stop | restart | status | logs) ;;
    *) harbor_die 3 usage 'harbor service <start|stop|restart|status|logs>' ;;
  esac
  [ "$#" -eq 1 ] || harbor_die 3 usage 'harbor service <start|stop|restart|status|logs>'
  harbor_versions_load "$(harbor_versions_lock_path)"
  bin="$(harbor_t3_bin "${HOME}")"
  # Shell quoting keeps the displayed argv exact even when HOME contains spaces.
  # The label precedes harbor_t3_run's version guard, so a mismatched install prints
  # this line and then the refusal naming harbor provision. That ordering is kept on
  # purpose: the label cannot move inside the seam, because harbor_t3_service_status
  # and harbor_t3_service_install capture that seam's output and classify on the body,
  # and duplicating the guard here to print later would give it two places to drift.
  printf 'harbor: running %q service %q\n' "${bin}" "${verb}" >&2
  harbor_t3_run "${HOME}" service "${verb}"
}
# harbor_t3_connect_login HOME: the attended login belongs to the vendor. Over SSH
# its out-of-band URL-and-code flow must reach the operator unchanged: Harbor never
# captures, filters, or pre-answers it. The second status reading, not the login's
# exit code, decides whether there is a transition Harbor can record.
harbor_t3_connect_login() {
  local home="${1}" rc=0
  # No label of its own, unlike harbor_agents_auth_login and harbor_service_cmd.
  # Those two have a reason to log before the seam: the agents invoke their vendor
  # directly, and the service verbs are captured and classified by their callers.
  # Neither holds here. harbor_t3_run already emits this exact line, and it emits it
  # after the version guard, so a mismatched install logs no vendor line at all --
  # which is the truth, because no vendor ran. A label out here would claim an
  # invocation that the guard refused, and would double the line when it did not.
  harbor_t3_run "${home}" connect login || rc="$?"
  harbor_log t3 "connect login exited ${rc}"
  return "${rc}"
}
# harbor_t3_connect STATE_ROOT HOME: recovery precedes the attended login for the
# same reason it does for the agents: this operator journal can contain a crashed
# provision. Only a false-to-true authenticated pair is recorded, already applied,
# because Harbor has no inverse for the vendor's login and must read both ends.
# Nothing here inspects credentials; the status adapter's words are all we know.
harbor_t3_connect() {
  local root="${1}" home="${2}" bin pre_auth pre_linked post_auth entry rc=0
  harbor_auth_refuse_root
  bin="$(harbor_t3_bin "${home}")"
  # An absent executable is an install to request, not an unverifiable login to run.
  [ -f "${bin}" ] && [ -x "${bin}" ] \
    || harbor_die 3 t3.not_installed "${bin} is not an installed executable, so there is no t3 on this node to log in; install the pinned tool first, as the operator, with: harbor provision; nothing was changed"
  harbor_state_root_create "${root}" operator
  harbor_log_open "${root}/harbor.log" 0600
  harbor_log command "auth connect"
  harbor_lock_acquire "${root}" operator
  harbor_journal_init "${root}"
  # The home the readers answer out of, set before recovery runs: a crashed provision
  # can leave runtime-install entries prepared in this same operator journal, and
  # the registered readers can only decide them when told which home holds the tools.
  # shellcheck disable=SC2034
  HARBOR_AGENTS_HOME="${home}"
  # Before recovery, not after it: the crashed provision this scan exists to decide
  # can have left a prepared t3-service entry in this same operator journal, and that
  # entry's reader goes through harbor_t3_service_status, which requires t3_version.
  # Loading afterwards leaves recovery to die with versions.unset naming an empty
  # lock path -- a refusal about Harbor's own startup order, raised against the one
  # journal state the scan is here to resolve.
  harbor_versions_load "$(harbor_versions_lock_path)"
  harbor_journal_recover "${root}"
  harbor_step recovery-scan
  harbor_t3_connect_status "${home}"
  pre_auth="${HARBOR_T3_CONNECT_AUTHENTICATED}"
  pre_linked="${HARBOR_T3_CONNECT_LINKED}"
  case "${pre_auth}:${pre_linked}" in
    true:true)
      harbor_msg "auth.connect: T3 Connect is already authorized and linked on this node (its own status command says so); nothing to do, and Harbor ran no login"
      return 0
      ;;
    true:false)
      # The link step and its t3-connect-link entry belong to spec section 8 row 5;
      # PR 4 ships only login, so this gap must not become an implicit link attempt.
      harbor_die 1 t3.needs_connect_link "needs_connect_link: T3 Connect is authorized but not linked; the link step is not in this release; harbor auth connect in a later release performs it; nothing was journaled"
      ;;
    false:*) ;;
    *)
      harbor_die 1 t3.auth_unverified "T3 Connect reports authenticated=${pre_auth} and linked=${pre_linked}; Harbor journals a transition only when it read both ends of it, so no login ran and nothing was written; rerun harbor auth connect once t3 answers its own status command"
      ;;
  esac
  harbor_msg "auth.connect: T3 Connect reports authenticated=${pre_auth}; running its own login below — follow what it prints, on your Mac if it asks for a browser"
  harbor_t3_connect_login "${home}" || rc="$?"
  harbor_step "auth-connect-login"
  harbor_t3_connect_status "${home}"
  post_auth="${HARBOR_T3_CONNECT_AUTHENTICATED}"
  harbor_log t3 "connect auth ${pre_auth} to ${post_auth} (login exited ${rc})"
  case "${post_auth}" in
    true) ;;
    false)
      harbor_die 1 t3.auth_incomplete "T3 Connect still reports authenticated=false after its own login exited ${rc}, so the login was not completed and there is no transition to record; the vendor's output above says what it asked for, and rerunning is safe: harbor auth connect; nothing was journaled"
      ;;
    *)
      harbor_die 1 t3.auth_unverified "T3 Connect reported authenticated=${pre_auth} before its login and ${post_auth} after it (the login exited ${rc}), and Harbor journals a transition only when it read both ends of it, so nothing was written; rerun harbor auth connect once t3 answers its own status command"
      ;;
  esac
  harbor_journal_create "${root}" auth connect created applied "\"${pre_auth}\"" "\"${post_auth}\""
  entry="${HARBOR_JOURNAL_ENTRY}"
  harbor_step "auth-connect-recorded"
  harbor_msg "T3 Connect is authorized on this node; recorded the ${pre_auth} to ${post_auth} transition as $(basename "${entry}")"
}
# harbor_t3_connect_status HOME: only the pin's four measured fields are answers.
# Other vendor fields may carry private bytes, so neither stdout nor inherited
# xtrace may receive the body. SQLite warnings live on stderr, outside the JSON.
harbor_t3_connect_status() {
  local home="${1}" body key value xt=0
  case "$-" in *x*) xt=1 ;; esac
  [ "${xt}" = 0 ] || set +x
  # stdout alone: the pinned CLI opens a SQLite database, so Node writes an
  # ExperimentalWarning to stderr on every invocation and 2>&1 would hand it to
  # the readers below. This is why the service adapter's capture rule does not
  # carry over — it classifies human text, where the vendor's diagnostics are
  # part of the answer, while this command's contract is JSON on stdout alone.
  # Dropping stderr also drops harbor_t3_run's refusal when the installed version
  # has drifted from the lock. That is deliberate and is the answer the service
  # adapter already gives there: four unknowns, and unknown is an answer.
  body="$(harbor_t3_run "${home}" connect status --json 2>/dev/null)" || :
  for key in desired authenticated linked; do
    value="$(printf '%s\n' "${body}" | sed -En "s/^  \"${key}\": (true|false),?$/\1/p")"
    case "${value}" in
      true | false) ;;
      *) value=unknown ;;
    esac
    # Assigned by name rather than indirectly: every other reader in lib/ spells
    # its targets out, and two declarations of a key print two lines, which the
    # fence above has already turned into unknown.
    # shellcheck disable=SC2034
    case "${key}" in
      desired) HARBOR_T3_CONNECT_DESIRED="${value}" ;;
      authenticated) HARBOR_T3_CONNECT_AUTHENTICATED="${value}" ;;
      linked) HARBOR_T3_CONNECT_LINKED="${value}" ;;
    esac
  done
  # Depth alone cannot distinguish another object's status: it must immediately
  # follow relayClient's header, as it does in all three pinned schema variants.
  value="$(printf '%s\n' "${body}" | sed -En '/^  "relayClient": [{]$/ {
    n
    s/^    "status": "(available|missing|unsupported)",?$/\1/p
  }')"
  case "${value}" in
    available | missing | unsupported) ;;
    *) value=unknown ;;
  esac
  # Consumed by the connect callers after this reader returns.
  # shellcheck disable=SC2034
  HARBOR_T3_CONNECT_RELAY="${value}"
  unset body
  [ "${xt}" = 0 ] || set -x
  return 0
}
# harbor_t3_service_status HOME: the pinned formatter has no JSON mode and exits
# zero in every state. Only its whole status lines decide the answer; an empty or
# unfamiliar body is unknown, never evidence that a service is installed.
harbor_t3_service_status() {
  local home="${1}" locked installed bin body rc=0 word=unknown matches=0 newline xt=0
  newline='
'
  locked="$(harbor_version_require t3_version)" || exit "$?"
  # Finish the pin assertion before capturing: Harbor's version diagnostic can
  # quote status-shaped bytes that were never a service status answer.
  installed="$(harbor_t3_installed_version "${home}" 2>/dev/null)" || {
    printf unknown
    return 0
  }
  [ "${installed}" = "${locked}" ] || {
    printf unknown
    return 0
  }
  # The one caller that does not go through harbor_t3_run, because that seam can
  # still speak before it execs the vendor: its mismatch diagnostic quotes what the
  # executable printed, and a t3 that answers --version correctly once and prints a
  # status-shaped line the next time would have its own words classified below as
  # the vendor's answer. Nothing is skipped by going direct — the assertion the seam
  # exists to make was just made above, against this same executable. The vendor
  # label is logged outside the capture for the same reason: under HARBOR_VERBOSE it
  # would otherwise put the operator-controlled bin path inside the classified body.
  bin="$(harbor_t3_bin "${home}")"
  harbor_log_vendor "${bin}" service status
  # As with agent auth status, keep the vendor body out of inherited xtrace.
  case "$-" in *x*) xt=1 ;; esac
  [ "${xt}" = 0 ] || set +x
  body="$("${bin}" service status 2>&1)" || rc="$?"
  # Surround the body with newlines so a neighbouring path cannot supply a phrase.
  case "${newline}${body}${newline}" in
    # service-status/installed-current: the CLI version must agree with the lock.
    *"${newline}  Status: installed · t3@${locked}${newline}"*)
      word="installed-current"
      matches=$((matches + 1))
      ;;
  esac
  case "${newline}${body}${newline}" in
    # service-status/update-pending
    *"${newline}  Status: needs an update or repair${newline}"*)
      word="update-pending"
      matches=$((matches + 1))
      ;;
  esac
  case "${newline}${body}${newline}" in
    # service-status/not-installed
    *"${newline}  Status: not installed${newline}"*)
      word="not-installed"
      matches=$((matches + 1))
      ;;
  esac
  case "${newline}${body}${newline}" in
    # service-status/unsupported
    *"${newline}  Status: unavailable on this machine${newline}"*)
      word=unsupported
      matches=$((matches + 1))
      ;;
  esac
  # Contradictory declarations cannot attest either state.
  [ "${matches}" = 1 ] || word=unknown
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
  active="$(HOME="${1}" systemctl --user is-active t3code.service 2>/dev/null)" || :
  [ "${active}" = active ]
}
# The t3-service op has its own observer; recovery supplies the explicit operator
# home through the same context as the CLI readers, never the ambient HOME.
harbor_observe_op_t3_service() {
  local home state active
  home="$(harbor_agents_home)" || exit "$?"
  state="$(harbor_t3_service_status "${home}")" || exit "$?"
  active="$(HOME="${home}" systemctl --user is-active t3code.service 2>/dev/null)" || :
  [ -n "${active}" ] || harbor_die 3 t3.service_activity "systemctl could not answer the t3 service activity; recovery cannot observe the state"
  printf '"%s"' "$(harbor_json_escape "${state}/${active}")"
}
# harbor_t3_service_install STATE_ROOT HOME: the vendor owns the unit lifecycle.
# Prepare before invoking it and attest applied only when both readings agree.
harbor_t3_service_install() {
  local root="${1}" home="${2}" pre ownership entry out post active active_rc=0 xt=0 rc=0
  # shellcheck disable=SC2034
  HARBOR_AGENTS_HOME="${home}"
  pre="$(harbor_t3_service_status "${home}")" || exit "$?"
  # An unreadable state is a refusal rather than an install, because the entry this
  # would write names a transition out of a state Harbor never read. Installing over
  # it would leave the journal vouching for a before that was a guess.
  [ "${pre}" != unknown ] || harbor_die 3 t3.service_unknown "t3 service status did not answer with a state this pinned build recognizes, so Harbor will not install over it: the entry would record a transition out of a state it never read; ask t3 itself with 'harbor service status' and rerun harbor provision once it answers; nothing was installed or journaled"
  [ "${pre}" != unsupported ] || harbor_die 3 t3.service_unsupported "t3 service is unavailable on this platform; nothing was installed or journaled"
  # Nonzero exits still answer inactive or failed; no output means we could not
  # ask, and must not invent an activity that recovery could later match.
  active="$(HOME="${home}" systemctl --user is-active t3code.service 2>/dev/null)" || :
  [ -n "${active}" ] || harbor_die 3 t3.service_activity "systemctl could not answer the t3 service activity; nothing was installed or journaled"
  # Returning early for installed-current/active makes pre_state differ from
  # post_state by construction whenever an entry is written, including repairs.
  if [ "${pre}/${active}" = installed-current/active ]; then
    return 0
  fi
  ownership=modified
  [ "${pre}" != not-installed ] || ownership=created
  harbor_journal_create "${root}" t3-service t3code.service "${ownership}" prepared "\"$(harbor_json_escape "${pre}/${active}")\"" '"installed-current/active"' || exit "$?"
  entry="${HARBOR_JOURNAL_ENTRY}"
  harbor_step "t3-service-prepared"
  # Vendor output may contain private bytes; keep every expansion off xtrace.
  case "$-" in *x*) xt=1 ;; esac
  [ "${xt}" = 0 ] || set +x
  if ! out="$(harbor_t3_run "${home}" service install 2>&1)"; then
    out="$(printf '%s' "${out}" | tr '\n\r' '  ')"
    # Isolate the fatal diagnostic so cleanup can restore the caller's trace.
    (harbor_die 2 t3.service_install_failed "t3 service install failed: ${out}; $(basename "${entry}") stays prepared, rerun after fixing the cause") || rc="$?"
    unset out
    [ "${xt}" = 0 ] || set -x
    exit "${rc}"
  fi
  unset out
  [ "${xt}" = 0 ] || set -x
  harbor_step "t3-service-installed"
  post="$(harbor_t3_service_status "${home}")" || exit "$?"
  active="$(HOME="${home}" systemctl --user is-active t3code.service 2>/dev/null)" || active_rc="$?"
  if [ "${post}" != installed-current ] || [ "${active}" != active ]; then
    harbor_die 2 t3.service_verify "after t3 service install: service status=${post}, is-active=${active} (exit ${active_rc}); $(basename "${entry}") stays prepared"
  fi
  harbor_journal_set_phase "${entry}" applied || exit "$?"
  harbor_step "t3-service-applied"
  harbor_msg "installed t3 service"
}
# Register beside the definition so every process sourcing this library can observe
# a prepared t3 runtime-install entry, including recovery without an install.
harbor_runtime_reader_register t3 harbor_t3_reader
