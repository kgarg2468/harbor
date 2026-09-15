#!/bin/bash
# The state record (design section 5.2, the State record row): bootstrap.json, the flat,
# non-secret JSON the last row of bootstrap writes into the root state root. It is mode
# 0644 and root-owned, so the operator can read the release tag, the entrypoint, and the
# account Harbor made for them, and only root can write it. Every value it carries is a
# value an earlier row already proved and is taken as a parameter: this library inspects no
# package, no account, and no runtime of its own, so nothing here can disagree with the row
# that owns the value. The state root is a parameter too; production passes /var/lib/harbor.
#
# The write is one journaled transaction of design section 3.7 in the shape every other file
# this release writes uses: a prepared entry, a temporary file, a rename over the record, the
# step boundary, then the applied write. The op is the file op, whose observer
# harbor_observe_op_file lib/journal.sh already defines, so a crash between the rename and the
# applied write leaves an entry recovery can decide against a record that is either the whole
# new one or the whole old one and never half of either. Depends on lib/log.sh
# (harbor_json_escape, harbor_die, harbor_step), lib/lock.sh (HARBOR_LOCK_ID_PID) and
# lib/journal.sh (the entry, the observation, and the platform sync).
# The three ownerships design section 5.2 lets the record name for Tailscale. The word is a
# parameter because the Tailscale rows of that table are the rows that learn it; this library
# only refuses one outside the vocabulary, fail-closed, since a record naming an ownership
# teardown cannot read is a record it would have to refuse to act on later.
HARBOR_STATE_TAILSCALE_OWNERSHIPS="harbor-installed adopted pre-existing"
# harbor_state_record_path STATE_ROOT: the record inside the state root, the one path this
# library names and the path design section 5.2 calls /var/lib/harbor/bootstrap.json.
harbor_state_record_path() {
  printf '%s/bootstrap.json' "${1}"
}
# harbor_state_record_number VALUE LABEL: VALUE must be a decimal number, because the record
# writes it unquoted. An empty or non-numeric uid or gid is refused rather than written: the
# name service answered something Harbor cannot record as the number it is, and a record that
# is not JSON is a record no later command could read at all.
harbor_state_record_number() {
  case "${1}" in
    "") harbor_die 3 state.number "${2} is empty, and the record carries it as a number" ;;
    *[!0-9]*) harbor_die 3 state.number "${2} '${1}' is not a decimal number, and the record carries it as one" ;;
  esac
}
# harbor_state_record_render TAG ENTRYPOINT LOCK_SHA256 FLAGS NODEJS_VERSION
# TAILSCALE_OWNERSHIP TAILSCALE_VERSION OPERATOR UID GID HOME TIMESTAMP: the record itself,
# built with printf and harbor_json_escape rather than with jq, because every function under
# lib/ runs before the Packages row could have installed one. One key per line in a fixed
# order, so a reader as small as the sed of harbor_entrypoint_record_tag can find a value and
# so two records built from equal values are equal byte for byte, which is what makes the
# rerun below rewrite nothing. The uid and the gid are numbers; every other value is a string.
#
# Tailscale carries its ownership and, beside the two ownerships Harbor holds, the version of
# the daemon that ownership covers. A harbor-installed or an adopted Tailscale is one Harbor
# itself moved to the lock, so the record names the version it moved it to and section 6.4's
# harbor upgrade has a pin to compare the installed daemon against. A pre-existing Tailscale
# is one Harbor neither installed nor adopted, and so is not Harbor's to pin: the version is
# rendered empty beside it whatever the caller passes, because naming one there would claim a
# pin Harbor never made and leave a later command comparing against it as though it had.
harbor_state_record_render() {
  local version="${7}"
  [ "${6}" != pre-existing ] || version=""
  printf '{\n'
  printf '  "release_tag": "%s",\n' "$(harbor_json_escape "${1}")"
  printf '  "entrypoint": "%s",\n' "$(harbor_json_escape "${2}")"
  printf '  "lock_sha256": "%s",\n' "$(harbor_json_escape "${3}")"
  printf '  "flags": "%s",\n' "$(harbor_json_escape "${4}")"
  printf '  "nodejs_version": "%s",\n' "$(harbor_json_escape "${5}")"
  printf '  "tailscale_ownership": "%s",\n' "$(harbor_json_escape "${6}")"
  printf '  "tailscale_version": "%s",\n' "$(harbor_json_escape "${version}")"
  printf '  "operator": "%s",\n' "$(harbor_json_escape "${8}")"
  printf '  "operator_uid": %s,\n' "${9}"
  printf '  "operator_gid": %s,\n' "${10}"
  printf '  "operator_home": "%s",\n' "$(harbor_json_escape "${11}")"
  printf '  "timestamp": "%s"\n' "$(harbor_json_escape "${12}")"
  printf '}\n'
}
# harbor_state_record_timestamp RECORD: the timestamp RECORD carries, or nothing when there
# is no record or it carries none. Read with sed for the same reason the record is built with
# printf: no jq is available to lib/. It is read rather than replaced on a rerun so that the
# timestamp keeps meaning what design section 5.7 compares against, the moment this node's
# record was established, and so a rerun that changes nothing else leaves the record byte for
# byte as it was rather than rewriting it once a second.
harbor_state_record_timestamp() {
  local record="${1}"
  [ -f "${record}" ] || return 0
  sed -n 's/^  "timestamp": "\([^"]*\)"$/\1/p' "${record}" | sed -n 1p
}
# harbor_state_record STATE_ROOT TAG ENTRYPOINT LOCK_SHA256 FLAGS NODEJS_VERSION
# TAILSCALE_OWNERSHIP TAILSCALE_VERSION OPERATOR UID GID HOME: the State record row of design
# section 5.2, written last and journaled as one file transaction. A record that is already,
# byte for byte, what would be written is journaled observed and left alone, which is what
# makes a rerun on a healthy node rewrite nothing; a record whose content, mode, or owner
# differs is rewritten with a fresh timestamp and journaled modified with the prior state; an
# absent one is journaled created. Anything at the path that is not a regular file is foreign
# and exits 3 untouched, because Harbor overwrites nothing it cannot prove it wrote.
harbor_state_record() {
  local root tag entrypoint lock flags nodejs tailscale version operator uid gid home
  local record pre post stamp tmp ownership entry known=0 word
  [ "$#" -eq 12 ] \
    || harbor_die 3 usage "usage: harbor_state_record <state-root> <release-tag> <entrypoint> <lock-sha256> <flag-set> <nodejs-version> <tailscale-ownership> <tailscale-version> <operator> <uid> <gid> <home>"
  root="${1}"
  tag="${2}"
  entrypoint="${3}"
  lock="${4}"
  flags="${5}"
  nodejs="${6}"
  tailscale="${7}"
  version="${8}"
  operator="${9}"
  uid="${10}"
  gid="${11}"
  home="${12}"
  for word in ${HARBOR_STATE_TAILSCALE_OWNERSHIPS}; do
    [ "${word}" != "${tailscale}" ] || known=1
  done
  [ "${known}" = 1 ] \
    || harbor_die 3 state.tailscale_ownership "'${tailscale}' is not one of the Tailscale ownerships design section 5.2 records (${HARBOR_STATE_TAILSCALE_OWNERSHIPS}); nothing was written"
  [ -n "${version}" ] || [ "${tailscale}" = pre-existing ] \
    || harbor_die 3 state.tailscale_version "the Tailscale ownership is '${tailscale}' and no version came with it, and design section 5.2 has the record name the version of an installation Harbor holds; nothing was written"
  harbor_state_record_number "${uid}" "the operator uid"
  harbor_state_record_number "${gid}" "the operator gid"
  record="$(harbor_state_record_path "${root}")"
  pre="$(harbor_observe_file "${record}")"
  case "${pre}" in
    '"unobservable:'*)
      harbor_die 3 state.foreign "${record} exists and is not a regular file; inspect it and remove it by hand, then rerun"
      ;;
    '{"symlink"'*)
      # A symlink is named separately because harbor_observe_file reports one as a symlink
      # rather than as unobservable, so the arm above never sees it. Harbor writes the record
      # as an ordinary file, so a symlink here is something else's, and replacing it would
      # remove whatever an administrator pointed at from under them.
      harbor_die 3 state.foreign "${record} is a symlink to $(readlink "${record}"), and Harbor writes the record as an ordinary file; inspect it and remove it by hand, then rerun"
      ;;
  esac
  tmp="${root}/.tmp.$(basename "${record}").${HARBOR_LOCK_ID_PID}"
  rm -f "${tmp}"
  # The comparison is made against the timestamp the record already carries, so a record that
  # is otherwise unchanged compares equal and is left exactly as it is. Only once the record
  # is going to be rewritten anyway does the timestamp become this moment.
  stamp="$(harbor_state_record_timestamp "${record}")"
  if [ -n "${stamp}" ]; then
    harbor_state_record_render "${tag}" "${entrypoint}" "${lock}" "${flags}" "${nodejs}" \
      "${tailscale}" "${version}" "${operator}" "${uid}" "${gid}" "${home}" "${stamp}" >"${tmp}"
    chmod 0644 "${tmp}"
    post="$(harbor_observe_file "${tmp}")"
    if [ "${post}" = "${pre}" ]; then
      rm -f "${tmp}"
      harbor_journal_create "${root}" file "${record}" observed applied "${pre}" "${post}"
      harbor_log state "${record} already records this node; nothing to do"
      return 0
    fi
  fi
  harbor_state_record_render "${tag}" "${entrypoint}" "${lock}" "${flags}" "${nodejs}" \
    "${tailscale}" "${version}" "${operator}" "${uid}" "${gid}" "${home}" "$(harbor_utc_now)" >"${tmp}"
  chmod 0644 "${tmp}"
  post="$(harbor_observe_file "${tmp}")"
  ownership=modified
  [ "${pre}" != '"absent"' ] || ownership=created
  harbor_journal_create "${root}" file "${record}" "${ownership}" prepared "${pre}" "${post}"
  entry="${HARBOR_JOURNAL_ENTRY}"
  harbor_journal_sync_path "${tmp}"
  if ! mv -f "${tmp}" "${record}"; then
    rm -f "${tmp}"
    harbor_die 2 state.rename "renaming ${tmp} onto ${record} failed; ${record} holds what it held before and $(basename "${entry}") stays prepared, rerun after fixing the cause"
  fi
  harbor_journal_sync_path "${root}"
  harbor_step state-record
  # Section 6.1: the check runs again after the apply, and a second failure aborts naming the
  # record, leaving its entry prepared for the next run to decide.
  [ "$(harbor_observe_file "${record}")" = "${post}" ] \
    || harbor_die 2 state.verify "${record} is not what was just written to it; $(basename "${entry}") stays prepared"
  harbor_journal_set_phase "${entry}" applied
}

# harbor_state_bare_version VALUE: true when VALUE is exactly three dot-separated
# runs of digits, the shape tests/unit/lib/versions.bats anchors the locked versions
# to with ^[0-9]+\.[0-9]+\.[0-9]+$. Spelled as case fences because lib/ is bash 3.2
# and has no =~, and with the digits enumerated because a bracket range resolves by
# the locale's collating order. The dot count is taken by peeling one separator at a
# time: the first fence has already excluded every character that is not a digit or a
# dot, so an empty part can only show up as a leading dot, a trailing dot, or a pair.
harbor_state_bare_version() {
  local rest
  case "${1}" in
    '' | *[!0123456789.]* | .* | *. | *..*) return 1 ;;
  esac
  rest="${1#*.}"
  [ "${rest}" != "${1}" ] || return 1
  case "${rest}" in
    *.*) ;;
    *) return 1 ;;
  esac
  rest="${rest#*.}"
  case "${rest}" in
    *.*) return 1 ;;
  esac
  return 0
}
# The operator snapshot observes versions, even when they disagree with the desired
# lock. Only installation methods come from that lock. Buffer the whole snapshot so
# a failed reader cannot emit a partial lock. Dependencies: versions, agents, t3,
# apt; the caller has loaded versions.lock and selected the operator HOME.
#
# HARBOR_STATE_OS_RELEASE is the one host path this library takes from the
# environment rather than from a parameter, which is not how lib/ssh.sh and
# lib/apt.sh make their host paths testable -- those take an etc prefix from their
# caller. The difference is that those write and this only reads, and the render
# takes no arguments by contract. It is ungated rather than behind HARBOR_DEV
# because gating it would buy nothing: this runs as the operator, and the file it
# feeds is installed.lock in the operator's own 0700 state root at 0600, which that
# same operator can edit directly. The override changes who has to type more, not
# who can claim a different ubuntu_release. A root command must not grow a habit of
# reading it on trust; nothing root runs reads this path today.
harbor_state_installed_lock_render() {
  local key value reading snapshot="" os_release
  os_release="${HARBOR_STATE_OS_RELEASE:-/etc/os-release}"
  for key in ubuntu_release tailscale_apt_channel tailscale_version nodejs_version nodejs_install nodejs_sha256 claude_code_version claude_code_install codex_version codex_install t3_version t3_install t3_engines_node; do
    value=""
    case "${key}" in
      claude_code_version | codex_version)
        reading="harbor_agents_installed_version (${key}) --version"
        case "${key}" in
          claude_code_version) value="$(harbor_agents_installed_version claude "${HOME}")" ;;
          codex_version) value="$(harbor_agents_installed_version codex "${HOME}")" ;;
        esac || harbor_die 2 state.observe "${key}: ${reading} failed; no state snapshot was written"
        ;;
      t3_version)
        reading='harbor_t3_installed_version --version'
        value="$(harbor_t3_installed_version "${HOME}")" \
          || harbor_die 2 state.observe "${key}: ${reading} failed; no state snapshot was written"
        ;;
      t3_engines_node)
        reading='harbor_t3_package_engines installed package engines.node'
        value="$(harbor_t3_package_engines "${HOME}")" \
          || harbor_die 2 state.observe "${key}: ${reading} failed; no state snapshot was written"
        ;;
      nodejs_version)
        reading="sh -lc 'node --version'"
        value="$(sh -lc 'node --version' 2>/dev/null)" \
          || harbor_die 2 state.observe "${key}: ${reading} failed; no state snapshot was written"
        # The v is stripped and then the rest must be bare. v[0-9]*.[0-9]*.[0-9]*
        # alone is not that test: the globs are unanchored on the right, so
        # v24.20.0-nightly and a two-line answer whose first line happens to look
        # like a version both satisfy it, and either would put a decorated string
        # into a file PR 7 compares against the lock -- where it reads as drift on
        # a node that has none. The fence below admits digits and dots only, which
        # rejects a suffix, an embedded newline, and a second line together.
        value="${value#v}"
        harbor_state_bare_version "${value}" \
          || harbor_die 2 state.observe "${key}: ${reading} returned '${value}', which is not a bare N.N.N version; no state snapshot was written"
        ;;
      tailscale_version)
        reading='harbor_apt_installed tailscale (dpkg-query -s tailscale, HARBOR_APT_VERSION)'
        # Keep the query and its output in the same subshell: the apt reader sets
        # HARBOR_APT_VERSION and may exit on an unreadable dpkg database. Catch that
        # exit here so the diagnostic also names the installed.lock key.
        value="$(harbor_apt_installed tailscale && printf '%s' "${HARBOR_APT_VERSION}")" \
          || harbor_die 2 state.observe "${key}: ${reading} failed; no state snapshot was written"
        ;;
      ubuntu_release)
        reading="${os_release} VERSION_ID"
        value="$(sed -n 's/^VERSION_ID=//p' "${os_release}")" \
          || harbor_die 2 state.observe "${key}: ${reading} failed; no state snapshot was written"
        value="${value%\"}"
        value="${value#\"}"
        value="${value%\'}"
        value="${value#\'}"
        ;;
      *)
        reading="versions.lock ${key} installation method"
        value="$(harbor_version_require "${key}")" \
          || harbor_die 2 state.observe "${key}: ${reading} failed; no state snapshot was written"
        ;;
    esac
    case "${value}" in
      '' | absent) harbor_die 2 state.observe "${key}: ${reading} returned '${value}', so the key cannot be observed; no state snapshot was written" ;;
    esac
    snapshot="${snapshot}${key}=${value}
"
  done
  printf '%s' "${snapshot}"
}

# Shared by the two new operator artifacts only; bootstrap's writer is unchanged.
# PATH's parent is the operator state root, already created and locked by preflight.
# harbor_state_provision_unchanged FILE CONTENT: true when writing CONTENT over FILE
# would change nothing the journal records, which is the question the timestamp
# decision is really asking -- preserve the stamp exactly when
# harbor_state_provision_write is going to journal observed rather than modified.
# It is asked the way that writer answers it, by staging a candidate as it stages one
# and comparing the two observations, rather than by testing the fields that seem to
# matter. Naming fields by hand is how this went wrong twice: content alone preserved
# the stamp across a repair from 0644 to 0600, and content with mode still preserves it
# across a repair of a record owned by another user, because harbor_observe_file
# compares owner too. A comparison built from harbor_observe_file cannot fall behind
# harbor_observe_file. A failure staging the candidate answers false, so the caller
# renders a fresh stamp and the writer fails on its own staging with its own message;
# the conservative direction, since a fresh stamp on an unchanged record costs a
# rewrite while a stale one on a changed record is the undecidability of section 5.7.
harbor_state_provision_unchanged() {
  local file="${1}" content="${2}" root tmp pre post
  root="$(dirname "${file}")" || return 1
  pre="$(harbor_observe_file "${file}")" || return 1
  tmp="$(mktemp "${root}/.tmp.state.XXXXXX")" || return 1
  if ! chmod 0600 "${tmp}" || ! printf '%s\n' "${content}" >"${tmp}"; then
    rm -f "${tmp}"
    return 1
  fi
  post="$(harbor_observe_file "${tmp}")" || {
    rm -f "${tmp}"
    return 1
  }
  rm -f "${tmp}" || return 1
  [ "${post}" = "${pre}" ]
}

harbor_state_provision_write() {
  local file="${1}" content="${2}" boundary="${3}" root tmp pre post ownership entry
  root="$(dirname "${file}")" || harbor_die 2 state.path "cannot derive the parent of ${file}; nothing was written"
  [ ! -L "${file}" ] || harbor_die 3 state.foreign "${file} is a symlink; nothing was written"
  pre="$(harbor_observe_file "${file}")" || harbor_die 2 state.inspect "cannot inspect ${file}; nothing was written"
  case "${pre}" in
    '"unobservable:'*) harbor_die 3 state.foreign "${file} is not a regular file; nothing was written" ;;
  esac
  tmp="$(mktemp "${root}/.tmp.state.XXXXXX")" \
    || harbor_die 2 state.stage "cannot create a temporary file in ${root}; ${file} is unchanged"
  if ! chmod 0600 "${tmp}" || ! printf '%s\n' "${content}" >"${tmp}"; then
    rm -f "${tmp}" || harbor_die 2 state.cleanup "cannot remove ${tmp}; ${file} is unchanged"
    harbor_die 2 state.stage "cannot stage ${file} at 0600; ${file} is unchanged"
  fi
  post="$(harbor_observe_file "${tmp}")" || harbor_die 2 state.inspect "cannot inspect ${tmp}; ${file} is unchanged"
  if [ "${post}" = "${pre}" ]; then
    rm -f "${tmp}" || harbor_die 2 state.cleanup "cannot remove ${tmp}; ${file} is unchanged"
    harbor_journal_create "${root}" file "${file}" observed applied "${pre}" "${post}" \
      || harbor_die 2 state.journal "cannot journal observed ${file}; ${file} is unchanged"
    return 0
  fi
  ownership=modified
  [ "${pre}" != '"absent"' ] || ownership=created
  harbor_journal_create "${root}" file "${file}" "${ownership}" prepared "${pre}" "${post}" \
    || harbor_die 2 state.journal "cannot prepare ${file}; ${file} is unchanged"
  entry="${HARBOR_JOURNAL_ENTRY}"
  harbor_journal_sync_path "${tmp}" || harbor_die 2 state.sync "cannot sync ${tmp}; ${entry} stays prepared"
  if ! mv -f "${tmp}" "${file}"; then
    rm -f "${tmp}" || harbor_die 2 state.cleanup "cannot remove ${tmp}; ${entry} stays prepared"
    harbor_die 2 state.rename "cannot rename ${tmp} onto ${file}; ${file} is unchanged and ${entry} stays prepared"
  fi
  harbor_journal_sync_path "${root}" || harbor_die 2 state.sync "cannot sync ${root}; ${entry} stays prepared"
  harbor_step "${boundary}"
  [ "$(harbor_observe_file "${file}")" = "${post}" ] \
    || harbor_die 2 state.verify "${file} differs from the staged snapshot; ${entry} stays prepared"
  harbor_journal_set_phase "${entry}" applied \
    || harbor_die 2 state.journal "cannot mark ${entry} applied; ${file} was written but its entry stays prepared"
}

# harbor_state_installed_lock_write PATH [SNAPSHOT]: SNAPSHOT is how the row gives
# both records one reading. installed.lock and provision.json are two views of a
# single provision, and the command lock excludes other Harbor commands but not the
# node's own package machinery -- unattended-upgrades can move the Tailscale package,
# and a vendor updater a CLI, between two renders. Two readings would then leave two
# durable records permanently disagreeing about the same run, with both writes having
# succeeded and nothing to say which is right. Rendering here is the fallback for a
# caller with one record to write; the row passes its own.
harbor_state_installed_lock_write() {
  local snapshot="${2:-}"
  if [ -z "${snapshot}" ]; then
    snapshot="$(harbor_state_installed_lock_render)" || exit "$?"
  fi
  harbor_state_provision_write "${1}" "${snapshot}" state-installed-lock
}

# A named function rather than the body of the caller's command substitution, and
# not only for readability: bash 3.2 -- the shell the macOS unit lane pins, and the
# floor lib/ is written to -- cannot parse a case statement lexically inside $( ).
# Its parser takes the ) that closes a case pattern as the ) that closes the
# substitution, for a single pattern as readily as for an alternation, and reports a
# syntax error pointing at the pattern line. Ubuntu's bash 5 parses it, so the form
# works everywhere Harbor is deployed and fails only on the lane that exists to catch
# exactly this. Writing the pattern as "(key | key)" balances the parens and is the
# other fix; a function is the one that also gives the render a name and one caller
# per timestamp below. The version keys are selected here rather than re-observed so
# both records are guaranteed to carry the same readings from the same moment.
harbor_state_provision_render() {
  local stamp="${1}" ownership="${2}" mode="${3}" access="${4}" service="${5}" claude="${6}" codex="${7}" snapshot="${8}"
  local key value
  printf '{\n'
  while IFS='=' read -r key value; do
    case "${key}" in
      ubuntu_release | tailscale_version | nodejs_version | claude_code_version | codex_version | t3_version | t3_engines_node)
        printf '  "%s": "%s",\n' "${key}" "$(harbor_json_escape "${value}")"
        ;;
    esac
  done <<LOCK
${snapshot}
LOCK
  printf '  "tailscale_ownership": "%s",\n' "$(harbor_json_escape "${ownership}")"
  printf '  "service_state": "%s",\n' "$(harbor_json_escape "${service}")"
  printf '  "access_mode": "%s",\n' "$(harbor_json_escape "${mode}")"
  printf '  "access_state": "%s",\n' "$(harbor_json_escape "${access}")"
  printf '  "claude_auth": "%s",\n' "$(harbor_json_escape "${claude}")"
  printf '  "codex_auth": "%s",\n' "$(harbor_json_escape "${codex}")"
  printf '  "timestamp": "%s"\n}\n' "$(harbor_json_escape "${stamp}")"
}

# The same observers supply both records. bootstrap.json supplies ownership alone:
# its intentionally blank pre-existing tailscale_version is not a version observer.
# TIMESTAMP is the stamp for a record that is going to be written, not the stamp the
# result necessarily carries: an unchanged record keeps its own.
harbor_state_provision_record() {
  local file="${1}" stamp="${2}" mode="${3}" access="${4}" service="${5}" claude="${6}" codex="${7}"
  local record ownership snapshot="${8:-}" content prior known word
  record="${HARBOR_AUTH_RECORD}"
  if [ "${HARBOR_DEV:-0}" = 1 ]; then
    record="${HARBOR_AUTH_FIXTURE_RECORD:-${record}}"
  fi
  [ -f "${record}" ] && [ -r "${record}" ] \
    || harbor_die 3 state.bootstrap "cannot read ${record}; run sudo harbor bootstrap before harbor provision"
  ownership="$(harbor_auth_record_value "${record}" tailscale_ownership)" \
    || harbor_die 2 state.observe "tailscale_ownership: reading ${record} failed; provision.json was not written"
  [ -n "${ownership}" ] \
    || harbor_die 2 state.observe "tailscale_ownership: ${record} has no ownership reading; provision.json was not written"
  # Against the vocabulary, not merely non-empty, and for the reason harbor_state_record
  # checks the same word above: provision.json is the file PR 7's drift row and PR 8's
  # upgrade read to learn whether the Tailscale version beside it is Harbor's to change.
  # A word outside the three is one those commands would have to refuse to act on, and
  # copying it through unchecked moves that refusal from here -- where nothing has been
  # written and the bootstrap record is named -- to them, where it lands on an operator
  # who did nothing wrong. Fail closed at the boundary that can still say why.
  known=0
  for word in ${HARBOR_STATE_TAILSCALE_OWNERSHIPS}; do
    [ "${word}" != "${ownership}" ] || known=1
  done
  [ "${known}" = 1 ] \
    || harbor_die 3 state.tailscale_ownership "${record} records tailscale_ownership '${ownership}', which is not one of the ownerships design section 5.2 names (${HARBOR_STATE_TAILSCALE_OWNERSHIPS}); provision.json was not written"
  # The row's reading when it passed one, so this record and installed.lock describe
  # the same instant; rendered here only for a caller writing this record alone.
  if [ -z "${snapshot}" ]; then
    snapshot="$(harbor_state_installed_lock_render)" || exit "$?"
  fi
  # harbor_state_record's rule for bootstrap.json, and for its reason: the comparison
  # is made against the stamp the record already carries, so a record that is
  # otherwise unchanged renders identically, is journaled observed, and is left
  # alone. Only once it is going to be rewritten anyway does the stamp become the
  # caller's. Carrying the old stamp forward onto changed content would be the real
  # defect: spec section 5.7's finalization decides between the record and the newest
  # <state-root>.journal.<timestamp>.done sibling by comparing them, so a record
  # rewritten after that journal activity but dated before it reads as the stale one,
  # which is the undecidability the field exists to prevent.
  prior="$(harbor_state_record_timestamp "${file}")"
  if [ -n "${prior}" ]; then
    content="$(harbor_state_provision_render "${prior}" "${ownership}" "${mode}" "${access}" "${service}" "${claude}" "${codex}" "${snapshot}")" \
      || harbor_die 2 state.render "cannot render provision.json; ${file} is unchanged"
    if harbor_state_provision_unchanged "${file}" "${content}"; then
      harbor_state_provision_write "${file}" "${content}" state-provision-json
      return 0
    fi
  fi
  content="$(harbor_state_provision_render "${stamp}" "${ownership}" "${mode}" "${access}" "${service}" "${claude}" "${codex}" "${snapshot}")" \
    || harbor_die 2 state.render "cannot render provision.json; ${file} is unchanged"
  harbor_state_provision_write "${file}" "${content}" state-provision-json
}
