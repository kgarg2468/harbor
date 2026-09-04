#!/bin/bash
# Operator account (design section 5.1's sudo-capable-operator refusal and design
# section 5.2's operator-user and linger rows): account inspection, the journaled
# creation, the refusal, and linger. Every mutation here is one journaled transaction
# of design section 3.7 and every step is decided by inspection first (section 6.1).
# The operator name and the state root belong to the caller; this library names no
# account and no absolute path of its own beyond the login shell the operator-user row
# fixes. HARBOR_USER_* globals are set by the inspection helper and read by its
# callers, which is how design section 5.2's state record learns the uid, gid, and
# home of the account as created.
# shellcheck disable=SC2034
HARBOR_USER_LOGIN_SHELL="/bin/bash"
harbor_user_field() {
  # harbor_user_field LINE N: field N of a colon-separated passwd or group line
  printf '%s\n' "${1}" | cut -d: -f"${2}"
}
harbor_user_state() {
  # The account state of design section 3.7. The login shell alone: it is the one
  # property the operator-user row fixes, so it is the one property both a prepared
  # entry can name before useradd runs and recovery can compare afterwards. The uid
  # and the home directory are allocated by useradd rather than requested, so no
  # honest post_state could carry them, and the state record reads them from
  # harbor_user_query instead.
  printf '{"shell":"%s"}' "$(harbor_json_escape "${1}")"
}
harbor_user_query() {
  # harbor_user_query OPERATOR: inspection only, never a mutation. Sets
  # HARBOR_USER_UID, HARBOR_USER_GID, HARBOR_USER_HOME, and HARBOR_USER_SHELL and
  # returns 0 when the name service lists OPERATOR; returns 1 when it reports the
  # account absent (getent exits 2 for a key it cannot find); any other failure is
  # fail-closed, exit 2, because an unanswered name service is not an absent account.
  local rc=0 line
  HARBOR_USER_UID=""
  HARBOR_USER_GID=""
  HARBOR_USER_HOME=""
  HARBOR_USER_SHELL=""
  HARBOR_USER_QUERY_OUT="$(getent passwd "${1}" 2>&1)" || rc="$?"
  case "${rc}" in
    0) ;;
    2) return 1 ;;
    *) harbor_die 2 user.inspect "getent passwd ${1} failed (exit ${rc}): ${HARBOR_USER_QUERY_OUT}" ;;
  esac
  line="$(printf '%s\n' "${HARBOR_USER_QUERY_OUT}" | sed -n 1p)"
  case "${line}" in
    "${1}":*) ;;
    *) harbor_die 2 user.inspect "getent passwd ${1} answered '${line}', which does not name ${1}" ;;
  esac
  HARBOR_USER_UID="$(harbor_user_field "${line}" 3)"
  HARBOR_USER_GID="$(harbor_user_field "${line}" 4)"
  HARBOR_USER_HOME="$(harbor_user_field "${line}" 6)"
  HARBOR_USER_SHELL="$(harbor_user_field "${line}" 7)"
  [ -n "${HARBOR_USER_UID}" ] && [ -n "${HARBOR_USER_HOME}" ] && [ -n "${HARBOR_USER_SHELL}" ] \
    || harbor_die 2 user.inspect "getent passwd ${1} answered '${line}', which is not a passwd line with a uid, a home, and a shell"
  return 0
}
harbor_observe_op_user() {
  # The observer harbor_journal_observe dispatches to for a user entry, so a prepared
  # entry left by a crash between useradd and the applied write is decidable by
  # recovery (design section 3.7): the account state in the shape harbor_user_state
  # renders, or the same "absent" a user entry's pre_state carries. useradd either
  # created the account with the login shell the entry names or it did not, so the two
  # recorded states are the two states that crash can leave, and anything else is an
  # account Harbor did not make, which recovery must refuse to decide. Inspection
  # only; a name service failure that is not "not found" is fail-closed through
  # harbor_user_query. Called only through harbor_journal_observe.
  if harbor_user_query "${1}"; then
    harbor_user_state "${HARBOR_USER_SHELL}"
  else
    printf '"absent"'
  fi
}
harbor_user_in_group() {
  # harbor_user_in_group OPERATOR GID GROUP: 0 when OPERATOR is a member of GROUP,
  # either by the group's member list or because GID, the operator's primary group id
  # when the account exists, is the group's own id; 1 when it is not a member and when
  # no such group exists (getent exits 2), since nobody is a member of a group the
  # node does not have. Any other failure is fail-closed, exit 2: an unanswered name
  # service must never read as "not sudo-capable".
  local operator="${1}" gid="${2}" group="${3}" out rc=0 line group_gid members
  out="$(getent group "${group}" 2>&1)" || rc="$?"
  case "${rc}" in
    0) ;;
    2) return 1 ;;
    *) harbor_die 2 user.group_inspect "getent group ${group} failed (exit ${rc}): ${out}" ;;
  esac
  line="$(printf '%s\n' "${out}" | sed -n 1p)"
  group_gid="$(harbor_user_field "${line}" 3)"
  members="$(harbor_user_field "${line}" 4)"
  case ",${members}," in
    *",${operator},"*) return 0 ;;
  esac
  [ -n "${gid}" ] && [ "${gid}" = "${group_gid}" ]
}
harbor_user_refuse_sudo_capable() {
  # harbor_user_refuse_sudo_capable OPERATOR: the refusal of design section 5.1. The
  # operator is never the administrator, so exit 3 naming the clash when OPERATOR is
  # root, is the invoking SUDO_USER, or is a member of the sudo or admin group.
  # Inspection only, and deliberately free of every other Harbor precondition: it
  # reads the operator name, SUDO_USER, and the name service, and touches no checkout,
  # no lock, and no journal, so the caller can run it in preflight before any Git
  # invocation, which is where a sudo-capable operator must be refused with a message
  # that says so rather than failing every checkout under the ownership rule.
  local operator gid="" group
  [ "$#" -eq 1 ] || harbor_die 3 usage "usage: harbor_user_refuse_sudo_capable <operator>"
  operator="${1}"
  [ "${operator}" != root ] \
    || harbor_die 3 user.operator_root "--operator names root, and the operator runs untrusted agent code; rerun with --operator naming a separate unprivileged account"
  [ -z "${SUDO_USER:-}" ] || [ "${operator}" != "${SUDO_USER}" ] \
    || harbor_die 3 user.operator_administrator "--operator names ${operator}, the account that invoked sudo; the administrator is never the operator, so rerun with --operator naming a separate unprivileged account"
  if harbor_user_query "${operator}"; then
    gid="${HARBOR_USER_GID}"
    # root is a uid, not a name: an account named anything at all with uid 0 has every
    # privilege the name root has, so refusing only the name would leave the refusal
    # trivially spelled around.
    [ "${HARBOR_USER_UID}" != 0 ] \
      || harbor_die 3 user.operator_root "--operator names ${operator}, which is uid 0 and so is root under another name; the operator runs untrusted agent code, so rerun with --operator naming a separate unprivileged account"
  fi
  for group in sudo admin; do
    if harbor_user_in_group "${operator}" "${gid}" "${group}"; then
      harbor_die 3 user.operator_sudo_capable "--operator names ${operator}, a member of the ${group} group; the operator must not be sudo-capable, so remove that membership with: gpasswd --delete ${operator} ${group}, or rerun with --operator naming another unprivileged account"
    fi
  done
  return 0
}
harbor_user_ensure() {
  # harbor_user_ensure STATE_ROOT OPERATOR: the operator-user row of design section
  # 5.2. An account the name service already lists is journaled observed and never
  # recreated; an absent one is prepared, created by exactly
  # useradd --create-home --shell /bin/bash OPERATOR, with no sudo and no extra
  # groups, verified, and marked applied. A failed useradd leaves the entry prepared
  # for recovery. Either way HARBOR_USER_UID, HARBOR_USER_GID, and HARBOR_USER_HOME
  # hold the account as it now is, for the state record to write.
  local root operator pre post entry out rc=0
  [ "$#" -eq 2 ] || harbor_die 3 usage "usage: harbor_user_ensure <state-root> <operator>"
  root="${1}"
  operator="${2}"
  post="$(harbor_user_state "${HARBOR_USER_LOGIN_SHELL}")"
  if harbor_user_query "${operator}"; then
    # An account that exists with another login shell is not the account this row
    # describes, and Harbor never alters one it did not create: report it and stop.
    [ "${HARBOR_USER_SHELL}" = "${HARBOR_USER_LOGIN_SHELL}" ] \
      || harbor_die 3 user.shell "${operator} already exists with login shell ${HARBOR_USER_SHELL}, not ${HARBOR_USER_LOGIN_SHELL}; Harbor does not change an account it did not create, so either set it by hand with: chsh -s ${HARBOR_USER_LOGIN_SHELL} ${operator}, or rerun with --operator naming another account; nothing was written"
    pre="$(harbor_user_state "${HARBOR_USER_SHELL}")"
    harbor_journal_create "${root}" user "${operator}" observed applied "${pre}" "${pre}"
    harbor_log user "${operator} exists with shell ${HARBOR_USER_SHELL} and home ${HARBOR_USER_HOME}; nothing to do"
    return 0
  fi
  harbor_journal_create "${root}" user "${operator}" created prepared '"absent"' "${post}"
  entry="${HARBOR_JOURNAL_ENTRY}"
  harbor_log_vendor useradd --create-home --shell "${HARBOR_USER_LOGIN_SHELL}" "${operator}"
  out="$(useradd --create-home --shell "${HARBOR_USER_LOGIN_SHELL}" "${operator}" 2>&1)" || rc="$?"
  [ "${rc}" = 0 ] \
    || harbor_die 2 user.create "useradd --create-home --shell ${HARBOR_USER_LOGIN_SHELL} ${operator} failed (exit ${rc}): ${out}; $(basename "${entry}") stays prepared, rerun after fixing the cause"
  harbor_step user-created
  # Section 6.1: the check runs again after the apply, and a second failure aborts
  # naming the account, leaving its entry prepared.
  harbor_user_query "${operator}" \
    || harbor_die 2 user.verify "useradd reported success but getent passwd ${operator} does not list the account; $(basename "${entry}") stays prepared"
  [ "$(harbor_user_state "${HARBOR_USER_SHELL}")" = "${post}" ] \
    || harbor_die 2 user.verify "useradd reported success but ${operator} has login shell ${HARBOR_USER_SHELL}, not ${HARBOR_USER_LOGIN_SHELL}; $(basename "${entry}") stays prepared"
  harbor_journal_set_phase "${entry}" applied
  harbor_msg "created the operator account ${operator} (uid ${HARBOR_USER_UID}, home ${HARBOR_USER_HOME})"
}
harbor_user_linger_state() {
  # harbor_user_linger_state OPERATOR: yes or no, read the way design section 5.6
  # reads it, loginctl show-user. Inspection only. A read that fails or answers
  # anything else is fail-closed, exit 2: linger that cannot be read is not linger
  # that is off, and enabling it on that guess would journal a pre-state Harbor
  # never observed.
  local out rc=0
  out="$(loginctl show-user "${1}" --property=Linger --value 2>&1)" || rc="$?"
  [ "${rc}" = 0 ] \
    || harbor_die 2 user.linger_inspect "loginctl show-user ${1} --property=Linger --value failed (exit ${rc}): ${out}"
  case "${out}" in
    yes | no) printf '%s' "${out}" ;;
    *) harbor_die 2 user.linger_inspect "loginctl show-user ${1} --property=Linger --value printed '${out}', not yes or no" ;;
  esac
}
harbor_observe_op_linger() {
  # The observer harbor_journal_observe dispatches to for a linger entry, so a
  # prepared entry left by a crash between loginctl enable-linger and the applied
  # write is decidable by recovery (design section 3.7): the same "yes" or "no" a
  # linger entry's pre_state and post_state carry, read from logind rather than
  # inferred. Inspection only; an unreadable state stays the exit 2 of
  # harbor_user_linger_state. Called only through harbor_journal_observe.
  local state
  state="$(harbor_user_linger_state "${1}")" || exit "$?"
  printf '"%s"' "${state}"
}
harbor_user_linger() {
  # harbor_user_linger STATE_ROOT OPERATOR: the linger row of design section 5.2.
  # The pre-state is journaled, so a node that was already lingering is left exactly
  # as it was, journaled observed, and teardown never disables linger somebody else
  # enabled; a node that was not is prepared, enabled, verified, and marked applied.
  local root operator pre post entry out rc=0
  [ "$#" -eq 2 ] || harbor_die 3 usage "usage: harbor_user_linger <state-root> <operator>"
  root="${1}"
  operator="${2}"
  pre="$(harbor_user_linger_state "${operator}")" || exit "$?"
  if [ "${pre}" = yes ]; then
    harbor_journal_create "${root}" linger "${operator}" observed applied '"yes"' '"yes"'
    harbor_log user "linger is already enabled for ${operator}; nothing to do"
    return 0
  fi
  harbor_journal_create "${root}" linger "${operator}" created prepared '"no"' '"yes"'
  entry="${HARBOR_JOURNAL_ENTRY}"
  harbor_log_vendor loginctl enable-linger "${operator}"
  out="$(loginctl enable-linger "${operator}" 2>&1)" || rc="$?"
  [ "${rc}" = 0 ] \
    || harbor_die 2 user.linger "loginctl enable-linger ${operator} failed (exit ${rc}): ${out}; $(basename "${entry}") stays prepared, rerun after fixing the cause"
  harbor_step linger-enabled
  post="$(harbor_user_linger_state "${operator}")" || exit "$?"
  [ "${post}" = yes ] \
    || harbor_die 2 user.linger_verify "loginctl enable-linger ${operator} reported success but Linger is ${post}; $(basename "${entry}") stays prepared"
  harbor_journal_set_phase "${entry}" applied
}
