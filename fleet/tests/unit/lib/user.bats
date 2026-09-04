#!/usr/bin/env bats
load '../test_helper'

TAB="$(printf '\t')"

setup() {
  # lib/user.sh depends on lib/log.sh, lib/lock.sh, and lib/journal.sh.
  # shellcheck source=lib/log.sh
  . "${HARBOR_ROOT}/lib/log.sh"
  # shellcheck source=lib/lock.sh
  . "${HARBOR_ROOT}/lib/lock.sh"
  # shellcheck source=lib/journal.sh
  . "${HARBOR_ROOT}/lib/journal.sh"
  # shellcheck source=lib/user.sh
  . "${HARBOR_ROOT}/lib/user.sh"
  fixture_state_root
  HARBOR_PID="$$"
  # The operator-user row promises a home directory belonging to the operator, and the
  # only account an unprivileged test may own a directory as is the one it already runs
  # as, exactly as tests/unit/node/bootstrap.bats and tests/unit/lib/ssh.bats resolve the
  # same problem. Every fixture home lives under the test's own temporary directory.
  TEST_USER="$(id -un)"
  OPERATOR="${TEST_USER}"
  HOMES="${BATS_TEST_TMPDIR}/homes"
  mkdir -p "${HOMES}"
  # The invoking administrator of design section 5.1, an account that is deliberately
  # not the operator. Tests that need the clash set SUDO_USER themselves.
  SUDO_USER="${TEST_USER}-admin"
  # getent, useradd, and loginctl resolve to the PR 2 shim through a link the test
  # makes in its own temporary directory, so no real account, group, or user
  # manager is ever consulted and nothing outside BATS_TEST_TMPDIR is written.
  BIN="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "${BIN}"
  for tool in getent useradd loginctl; do
    ln -s "${HARBOR_ROOT}/tests/shims/bin/harbor-shim" "${BIN}/${tool}"
  done
  PATH="${BIN}:${PATH}"
  export PATH
  HARBOR_SHIM_LOG="${BATS_TEST_TMPDIR}/shim.log"
  export HARBOR_SHIM_LOG
  FX="${BATS_TEST_TMPDIR}/fx"
  mkdir -p "${FX}/getent/healthy" "${FX}/useradd/healthy" "${FX}/loginctl/healthy"
  HARBOR_SHIM_FIXTURES="${FX}"
  export HARBOR_SHIM_FIXTURES
  USERADD_LINE="useradd${TAB}--create-home${TAB}--shell${TAB}/bin/bash${TAB}${OPERATOR}"
  USERADD_KEY="--create-home_--shell_%bin%bash_${OPERATOR}"
  LINGER_KEY="show-user_${OPERATOR}_--property=Linger_--value"
  # The node this fixture describes: no operator account, an ordinary sudo group
  # the administrator is in, and no admin group at all.
  absent_account "${OPERATOR}"
  group_entry sudo 27 "${SUDO_USER}"
  no_group_entry admin
  useradd_succeeds /bin/bash
  harbor_lock_acquire "${FIX_ROOT}" operator
}

teardown() {
  harbor_lock_release "${FIX_ROOT}"
}

passwd_entry() {
  # passwd_entry USER SHELL [HOME] [UID] [GID]: what getent passwd USER answers. The
  # name service only: whether the home directory it names is really there is the
  # separate fact the row inspects, so make_home is what puts one there.
  local user="${1}" shell="${2}" home="${3:-${HOMES}/${1}}" uid="${4:-1001}" gid="${5:-1001}"
  printf '%s:x:%s:%s:Harbor operator:%s:%s\n' "${user}" "${uid}" "${gid}" "${home}" "${shell}" \
    >"${FX}/getent/healthy/passwd_${user}.out"
  rm -f "${FX}/getent/healthy/passwd_${user}.exit"
}

make_home() {
  # make_home USER: the home directory of USER, created and belonging to it, which is
  # what useradd --create-home leaves behind when it gets that far. Prints the path.
  mkdir -p "${HOMES}/${1}"
  printf '%s' "${HOMES}/${1}"
}

absent_account() {
  # getent exits 2 for a key it cannot find.
  : >"${FX}/getent/healthy/passwd_${1}.out"
  printf '2\n' >"${FX}/getent/healthy/passwd_${1}.exit"
}

broken_getent() {
  # A name service that is neither answering nor reporting "not found".
  printf 'getent: cannot open passwd database\n' >"${FX}/getent/healthy/passwd_${1}.out"
  printf '3\n' >"${FX}/getent/healthy/passwd_${1}.exit"
}

group_entry() {
  # group_entry GROUP GID MEMBERS
  printf '%s:x:%s:%s\n' "${1}" "${2}" "${3}" >"${FX}/getent/healthy/group_${1}.out"
  rm -f "${FX}/getent/healthy/group_${1}.exit"
}

no_group_entry() {
  : >"${FX}/getent/healthy/group_${1}.out"
  printf '2\n' >"${FX}/getent/healthy/group_${1}.exit"
}

useradd_succeeds() {
  # useradd_succeeds SHELL: the shim exits 0 and the account exists afterwards with
  # SHELL and with its home directory, which is the effect the real
  # useradd --create-home has on the node.
  : >"${FX}/useradd/healthy/${USERADD_KEY}.out"
  rm -f "${FX}/useradd/healthy/${USERADD_KEY}.exit"
  USERADD_AFTER_SHELL="${1}"
  USERADD_AFTER_HOME=1
}

useradd_fails() {
  # A useradd that got nowhere: nothing is committed and the account stays absent.
  printf 'useradd: failure while writing changes to /etc/passwd\n' \
    >"${FX}/useradd/healthy/${USERADD_KEY}.out"
  printf '1\n' >"${FX}/useradd/healthy/${USERADD_KEY}.exit"
  USERADD_AFTER_SHELL=""
  USERADD_AFTER_HOME=0
}

useradd_leaves_no_home() {
  # The half of useradd --create-home that the design section 3.7 crash window does not
  # cover, because it is not a crash: useradd commits the passwd and group databases
  # before it creates the home directory, so a /home that is full, read-only, or not
  # mounted leaves the account listed, its home directory absent, and useradd exiting 12.
  printf 'useradd: cannot create directory %s/%s\n' "${HOMES}" "${OPERATOR}" \
    >"${FX}/useradd/healthy/${USERADD_KEY}.out"
  printf '12\n' >"${FX}/useradd/healthy/${USERADD_KEY}.exit"
  USERADD_AFTER_SHELL=/bin/bash
  USERADD_AFTER_HOME=0
}

useradd() {
  # The shim is stateless, so the effect a real useradd has on the node is modeled here:
  # the shim is still what runs and logs, and what it leaves behind, the passwd line and
  # the home directory, is set independently of the exit code, because the real command
  # leaves the first without the second when it fails at exit 12.
  local rc=0
  command useradd ${1+"$@"} || rc="$?"
  if [ -n "${USERADD_AFTER_SHELL}" ]; then
    [ "${USERADD_AFTER_HOME}" = 0 ] || make_home "${OPERATOR}" >/dev/null
    passwd_entry "${OPERATOR}" "${USERADD_AFTER_SHELL}"
  fi
  return "${rc}"
}

linger_state() {
  # linger_state yes|no: what loginctl show-user reports for the operator
  printf '%s\n' "${1}" >"${FX}/loginctl/healthy/${LINGER_KEY}.out"
  rm -f "${FX}/loginctl/healthy/${LINGER_KEY}.exit"
}

enable_linger_succeeds() {
  : >"${FX}/loginctl/healthy/enable-linger_${OPERATOR}.out"
  rm -f "${FX}/loginctl/healthy/enable-linger_${OPERATOR}.exit"
  ENABLE_LINGER_WORKS=1
}

enable_linger_fails() {
  printf 'Failed to enable linger: Access denied\n' \
    >"${FX}/loginctl/healthy/enable-linger_${OPERATOR}.out"
  printf '1\n' >"${FX}/loginctl/healthy/enable-linger_${OPERATOR}.exit"
  ENABLE_LINGER_WORKS=0
}

loginctl() {
  # Same modelling as useradd above: a successful enable-linger is what makes the
  # next show-user report yes.
  command loginctl ${1+"$@"} || return "$?"
  if [ "${1}" = enable-linger ] && [ "${ENABLE_LINGER_WORKS:-0}" = 1 ]; then
    linger_state yes
  fi
}

shim_calls() {
  # shim_calls [PATTERN]: how many shim calls the log holds, all of them by default
  [ -e "${HARBOR_SHIM_LOG}" ] || {
    printf '0\n'
    return 0
  }
  grep -c "${1:-.}" "${HARBOR_SHIM_LOG}" || true
}

entries_owned() {
  # entries_owned OWNERSHIP: how many journal entries carry that ownership
  grep -l "^  \"ownership\": \"${1}\",\$" "${FIX_ROOT}"/journal/*.json 2>/dev/null | wc -l | tr -d ' '
}

assert_entry() {
  # assert_entry SEQ OP TARGET OWNERSHIP PHASE PRE POST
  assert [ -f "${FIX_ROOT}/journal/${1}-${2}.json" ]
  assert_equal "$(entry_raw "${FIX_ROOT}" "${1}" target)" "\"${3}\""
  assert_equal "$(entry_raw "${FIX_ROOT}" "${1}" ownership)" "\"${4}\""
  assert_equal "$(entry_phase "${FIX_ROOT}" "${1}")" "${5}"
  assert_equal "$(entry_raw "${FIX_ROOT}" "${1}" pre_state)" "${6}"
  assert_equal "$(entry_raw "${FIX_ROOT}" "${1}" post_state)" "${7}"
}

user_state() {
  # user_state SHELL [HOME_STATE]: the account state a user entry records, which is the
  # pair the row promises and not the shell alone.
  printf '{"shell":"%s","home":"%s"}' "${1}" "${2:-present}"
}

@test "inspection reports the account, its shell, and its home, and never calls useradd" {
  passwd_entry "${OPERATOR}" /bin/bash "${HOMES}/${OPERATOR}" 1001 1002
  run harbor_user_query "${OPERATOR}"
  assert_success
  harbor_user_query "${OPERATOR}"
  assert_equal "${HARBOR_USER_UID}" 1001
  assert_equal "${HARBOR_USER_GID}" 1002
  assert_equal "${HARBOR_USER_HOME}" "${HOMES}/${OPERATOR}"
  assert_equal "${HARBOR_USER_SHELL}" /bin/bash
  absent_account "${OPERATOR}"
  run harbor_user_query "${OPERATOR}"
  assert_equal "${status}" 1
  run grep -v "^getent${TAB}passwd${TAB}${OPERATOR}\$" "${HARBOR_SHIM_LOG}"
  assert_output ''
  run ls -A "${FIX_ROOT}/journal"
  assert_output ''
}

@test "a name service failure that is not not-found is fail-closed, exit 2, and prepares nothing" {
  broken_getent "${OPERATOR}"
  run harbor_user_query "${OPERATOR}"
  assert_equal "${status}" 2
  assert_output --partial 'user.inspect'
  run harbor_user_ensure "${FIX_ROOT}" "${OPERATOR}"
  assert_equal "${status}" 2
  assert_output --partial 'user.inspect'
  assert_equal "$(shim_calls "^useradd${TAB}")" 0
  run ls -A "${FIX_ROOT}/journal"
  assert_output ''
}

@test "an absent account is created by exactly one useradd argument vector and journaled created" {
  run harbor_user_ensure "${FIX_ROOT}" "${OPERATOR}"
  assert_success
  assert_output --partial "${OPERATOR}"
  # The shim log holds the exact useradd argument vector and nothing that is not
  # an inspection of the account.
  run grep -v "^getent${TAB}passwd${TAB}${OPERATOR}\$" "${HARBOR_SHIM_LOG}"
  assert_output "${USERADD_LINE}"
  assert_equal "$(shim_calls "^useradd${TAB}")" 1
  assert_entry 0001 user "${OPERATOR}" created applied '"absent"' "$(user_state /bin/bash)"
  run ls -A "${FIX_ROOT}/journal"
  assert_equal "${#lines[@]}" 1
}

@test "an existing account with the right shell and home is journaled observed and useradd is never called" {
  passwd_entry "${OPERATOR}" /bin/bash "$(make_home "${OPERATOR}")"
  run harbor_user_ensure "${FIX_ROOT}" "${OPERATOR}"
  assert_success
  assert_equal "$(shim_calls "^useradd${TAB}")" 0
  assert_entry 0001 user "${OPERATOR}" observed applied "$(user_state /bin/bash)" "$(user_state /bin/bash)"
  assert_equal "$(entries_owned created)" 0
  # The caller of design section 5.2's state-record step reads uid, gid, and home
  # from the inspection, which the observed path leaves set.
  harbor_user_ensure "${FIX_ROOT}" "${OPERATOR}"
  assert_equal "${HARBOR_USER_HOME}" "${HOMES}/${OPERATOR}"
  assert_equal "${HARBOR_USER_UID}" 1001
}

@test "a second run makes no mutating shim call and writes no created entry" {
  run harbor_user_ensure "${FIX_ROOT}" "${OPERATOR}"
  assert_success
  : >"${HARBOR_SHIM_LOG}"
  run harbor_user_ensure "${FIX_ROOT}" "${OPERATOR}"
  assert_success
  assert_equal "$(shim_calls "^useradd${TAB}")" 0
  assert_entry 0002 user "${OPERATOR}" observed applied "$(user_state /bin/bash)" "$(user_state /bin/bash)"
  assert_equal "$(entries_owned created)" 1
  assert_equal "$(entries_owned observed)" 1
  assert_equal "$(entries_owned modified)" 0
}

@test "an existing account with another shell is reported, exits 3, and mutates nothing" {
  passwd_entry "${OPERATOR}" /usr/sbin/nologin
  run harbor_user_ensure "${FIX_ROOT}" "${OPERATOR}"
  assert_equal "${status}" 3
  assert_output --partial 'user.shell'
  assert_output --partial /usr/sbin/nologin
  assert_output --partial /bin/bash
  assert_output --partial "chsh -s /bin/bash ${OPERATOR}"
  assert_equal "$(shim_calls "^useradd${TAB}")" 0
  run ls -A "${FIX_ROOT}/journal"
  assert_output ''
}

@test "a failing useradd exits 2 and leaves the entry prepared for recovery" {
  useradd_fails
  run harbor_user_ensure "${FIX_ROOT}" "${OPERATOR}"
  assert_equal "${status}" 2
  assert_output --partial 'user.create'
  assert_equal "$(shim_calls "^useradd${TAB}")" 1
  assert_entry 0001 user "${OPERATOR}" created prepared '"absent"' "$(user_state /bin/bash)"
  # The crash window of design section 3.7: useradd ran or did not, and the applied
  # write never happened. Recovery observes the account and decides without asking.
  run harbor_journal_recover "${FIX_ROOT}"
  assert_success
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" reverted
}

@test "an account useradd committed without its home does not read as done on the rerun" {
  # The convergence defect this asserts against is the failure and the rerun as one
  # sequence, which is the only order it appears in: each half on its own passes.
  # Run 1: useradd commits the passwd database, fails to create the home, and exits 12,
  # so the entry stays prepared and the account exists as only half of what it promised.
  useradd_leaves_no_home
  run harbor_user_ensure "${FIX_ROOT}" "${OPERATOR}"
  assert_equal "${status}" 2
  assert_output --partial 'user.create'
  assert_entry 0001 user "${OPERATOR}" created prepared '"absent"' "$(user_state /bin/bash)"
  assert [ ! -d "${HOMES}/${OPERATOR}" ]
  # Run 2: the name service lists the account and its shell is the one the row fixes,
  # which is everything the passwd line can say. It is not enough to call the row done:
  # the home the account names is not there, so the account is reported, by the cause
  # rather than by the .ssh directory that would fail three rows later.
  : >"${HARBOR_SHIM_LOG}"
  run harbor_user_ensure "${FIX_ROOT}" "${OPERATOR}"
  assert_equal "${status}" 3
  assert_output --partial 'user.home'
  assert_output --partial "${HOMES}/${OPERATOR}"
  assert_output --partial "mkhomedir_helper ${OPERATOR}"
  assert_equal "$(shim_calls "^useradd${TAB}")" 0
  run ls -A "${FIX_ROOT}/journal"
  assert_equal "${#lines[@]}" 1
  # And recovery does not resolve the entry run 1 left prepared: the account it observes
  # is neither the absent one the entry names nor the whole one it promised.
  run --separate-stderr harbor_journal_recover "${FIX_ROOT}"
  assert_equal "${status}" 2
  assert_regex "${stderr}" 'journal entry 0001-user.json is undecidable:'
  assert_regex "${stderr}" 'observed:   \{"shell":"/bin/bash","home":"absent"\}'
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" prepared
  # Run 3, with the cause fixed: the row observes a whole account, journals it observed,
  # calls no useradd, and recovery now decides the entry the interrupted run left.
  make_home "${OPERATOR}"
  run harbor_user_ensure "${FIX_ROOT}" "${OPERATOR}"
  assert_success
  assert_equal "$(shim_calls "^useradd${TAB}")" 0
  assert_entry 0002 user "${OPERATOR}" observed applied "$(user_state /bin/bash)" "$(user_state /bin/bash)"
  run harbor_journal_recover "${FIX_ROOT}"
  assert_success
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" applied
}

@test "a useradd that reports success without the home it was asked for leaves the entry prepared" {
  # The other side of the same fact: exit 0 is not proof either, and section 6.1's
  # check after the apply is what catches it.
  useradd_succeeds /bin/bash
  USERADD_AFTER_HOME=0
  run harbor_user_ensure "${FIX_ROOT}" "${OPERATOR}"
  assert_equal "${status}" 2
  assert_output --partial 'user.verify_home'
  assert_output --partial "${HOMES}/${OPERATOR}"
  assert_entry 0001 user "${OPERATOR}" created prepared '"absent"' "$(user_state /bin/bash)"
}

@test "an existing account whose home belongs to somebody else is reported and mutates nothing" {
  # A home directory that is not the operator's is not a home Harbor may write an
  # authorized key into. The root directory is the one directory an unprivileged test
  # can count on existing and belonging to another account, and it is only ever stat'd.
  passwd_entry "${OPERATOR}" /bin/bash /
  run harbor_user_ensure "${FIX_ROOT}" "${OPERATOR}"
  assert_equal "${status}" 3
  assert_output --partial 'user.home'
  assert_output --partial "chown -R ${OPERATOR} /"
  assert_equal "$(shim_calls "^useradd${TAB}")" 0
  run ls -A "${FIX_ROOT}/journal"
  assert_output ''
}

@test "recovery decides a prepared user entry: absent is reverted, the created account is applied, another shell is undecidable" {
  fixture_entry "${FIX_ROOT}" 0001 user "${OPERATOR}" created prepared '"absent"' "$(user_state /bin/bash)"
  run harbor_journal_recover "${FIX_ROOT}"
  assert_success
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" reverted
  passwd_entry "${OPERATOR}" /bin/bash "$(make_home "${OPERATOR}")"
  fixture_entry "${FIX_ROOT}" 0002 user "${OPERATOR}" created prepared '"absent"' "$(user_state /bin/bash)"
  run harbor_journal_recover "${FIX_ROOT}"
  assert_success
  assert_equal "$(entry_phase "${FIX_ROOT}" 0002)" applied
  passwd_entry "${OPERATOR}" /bin/sh
  fixture_entry "${FIX_ROOT}" 0003 user "${OPERATOR}" created prepared '"absent"' "$(user_state /bin/bash)"
  run --separate-stderr harbor_journal_recover "${FIX_ROOT}"
  assert_equal "${status}" 2
  assert_regex "${stderr}" 'journal entry 0003-user.json is undecidable:'
  assert_regex "${stderr}" 'observed:   \{"shell":"/bin/sh","home":"present"\}'
  assert_equal "$(entry_phase "${FIX_ROOT}" 0003)" prepared
  assert_equal "$(shim_calls "^useradd${TAB}")" 0
}

@test "recovery of a prepared user entry is fail-closed when the name service fails" {
  broken_getent "${OPERATOR}"
  fixture_entry "${FIX_ROOT}" 0001 user "${OPERATOR}" created prepared '"absent"' "$(user_state /bin/bash)"
  run harbor_journal_recover "${FIX_ROOT}"
  assert_equal "${status}" 2
  assert_output --partial 'user.inspect'
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" prepared
}

@test "the refusal exits 3 for root and for the invoking administrator without any shim call" {
  run harbor_user_refuse_sudo_capable root
  assert_equal "${status}" 3
  assert_output --partial 'user.operator_root'
  assert_output --partial root
  assert_equal "$(shim_calls)" 0
  run harbor_user_refuse_sudo_capable "${SUDO_USER}"
  assert_equal "${status}" 3
  assert_output --partial 'user.operator_administrator'
  assert_output --partial "${SUDO_USER}"
  assert_equal "$(shim_calls)" 0
  run ls -A "${FIX_ROOT}/journal"
  assert_output ''
}

@test "the refusal exits 3 for an account that is uid 0 under another name" {
  # root is a uid, not a name, so refusing only the name would be spelled around by
  # any account the node happens to carry at uid 0.
  passwd_entry toor /bin/bash /root 0 0
  run harbor_user_refuse_sudo_capable toor
  assert_equal "${status}" 3
  assert_output --partial 'user.operator_root'
  assert_output --partial toor
  run ls -A "${FIX_ROOT}/journal"
  assert_output ''
}

@test "the refusal exits 3 for a sudo group member and for an admin group member" {
  group_entry sudo 27 "someone,${OPERATOR},else"
  run harbor_user_refuse_sudo_capable "${OPERATOR}"
  assert_equal "${status}" 3
  assert_output --partial 'user.operator_sudo_capable'
  assert_output --partial "${OPERATOR}"
  assert_output --partial 'sudo group'
  group_entry sudo 27 "${SUDO_USER}"
  group_entry admin 118 "${OPERATOR}"
  run harbor_user_refuse_sudo_capable "${OPERATOR}"
  assert_equal "${status}" 3
  assert_output --partial 'user.operator_sudo_capable'
  assert_output --partial 'admin group'
  # Deciding membership reads the name service and nothing else: no useradd, no
  # loginctl, and no journal entry.
  assert_equal "$(shim_calls "^useradd${TAB}")" 0
  assert_equal "$(shim_calls "^loginctl${TAB}")" 0
  run ls -A "${FIX_ROOT}/journal"
  assert_output ''
}

@test "the refusal exits 3 when the sudo group is the operator's primary group" {
  passwd_entry "${OPERATOR}" /bin/bash /home/harbor 1001 27
  group_entry sudo 27 ""
  run harbor_user_refuse_sudo_capable "${OPERATOR}"
  assert_equal "${status}" 3
  assert_output --partial 'user.operator_sudo_capable'
  assert_output --partial 'sudo group'
}

@test "the refusal accepts an operator that clashes with nothing, with or without SUDO_USER" {
  run harbor_user_refuse_sudo_capable "${OPERATOR}"
  assert_success
  assert_output ''
  passwd_entry "${OPERATOR}" /bin/bash
  run harbor_user_refuse_sudo_capable "${OPERATOR}"
  assert_success
  SUDO_USER=""
  run harbor_user_refuse_sudo_capable "${OPERATOR}"
  assert_success
  run harbor_user_refuse_sudo_capable
  assert_equal "${status}" 3
  assert_output --partial 'usage'
  assert_equal "$(shim_calls "^useradd${TAB}")" 0
}

@test "the refusal needs no lock, no journal, and no state root at all" {
  # The caller runs it in preflight before any Git invocation, so it must decide
  # from the operator name, SUDO_USER, and the name service alone.
  harbor_lock_release "${FIX_ROOT}"
  rm -rf "${FIX_ROOT}"
  group_entry sudo 27 "${OPERATOR}"
  run harbor_user_refuse_sudo_capable "${OPERATOR}"
  assert_equal "${status}" 3
  assert_output --partial 'user.operator_sudo_capable'
  assert [ ! -e "${FIX_ROOT}" ]
  fixture_state_root
  harbor_lock_acquire "${FIX_ROOT}" operator
}

@test "linger off: the pre-state is journaled, linger is enabled, and the entry is applied" {
  linger_state no
  enable_linger_succeeds
  run harbor_user_linger "${FIX_ROOT}" "${OPERATOR}"
  assert_success
  run grep "^loginctl${TAB}" "${HARBOR_SHIM_LOG}"
  assert_line --index 0 "loginctl${TAB}show-user${TAB}${OPERATOR}${TAB}--property=Linger${TAB}--value"
  assert_line --index 1 "loginctl${TAB}enable-linger${TAB}${OPERATOR}"
  assert_line --index 2 "loginctl${TAB}show-user${TAB}${OPERATOR}${TAB}--property=Linger${TAB}--value"
  assert_equal "${#lines[@]}" 3
  assert_entry 0001 linger "${OPERATOR}" created applied '"no"' '"yes"'
}

@test "linger already on: the entry is observed and enable-linger is never called" {
  linger_state yes
  enable_linger_succeeds
  run harbor_user_linger "${FIX_ROOT}" "${OPERATOR}"
  assert_success
  assert_equal "$(shim_calls "enable-linger")" 0
  assert_entry 0001 linger "${OPERATOR}" observed applied '"yes"' '"yes"'
  assert_equal "$(entries_owned created)" 0
  # A second run on a node Harbor enabled linger on observes it the same way.
  linger_state no
  enable_linger_succeeds
  run harbor_user_linger "${FIX_ROOT}" "${OPERATOR}"
  assert_success
  : >"${HARBOR_SHIM_LOG}"
  run harbor_user_linger "${FIX_ROOT}" "${OPERATOR}"
  assert_success
  assert_equal "$(shim_calls "enable-linger")" 0
  assert_entry 0003 linger "${OPERATOR}" observed applied '"yes"' '"yes"'
}

@test "a failing enable-linger exits 2, leaves the entry prepared, and recovery decides it" {
  linger_state no
  enable_linger_fails
  run harbor_user_linger "${FIX_ROOT}" "${OPERATOR}"
  assert_equal "${status}" 2
  assert_output --partial 'user.linger'
  assert_entry 0001 linger "${OPERATOR}" created prepared '"no"' '"yes"'
  run harbor_journal_recover "${FIX_ROOT}"
  assert_success
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" reverted
  # The other side of the crash window: enable-linger had taken effect.
  linger_state yes
  fixture_entry "${FIX_ROOT}" 0002 linger "${OPERATOR}" created prepared '"no"' '"yes"'
  run harbor_journal_recover "${FIX_ROOT}"
  assert_success
  assert_equal "$(entry_phase "${FIX_ROOT}" 0002)" applied
}

@test "an unreadable or unparseable linger state is fail-closed, exit 2, and journals nothing" {
  printf 'Failed to get user: No such process\n' >"${FX}/loginctl/healthy/${LINGER_KEY}.out"
  printf '1\n' >"${FX}/loginctl/healthy/${LINGER_KEY}.exit"
  run harbor_user_linger "${FIX_ROOT}" "${OPERATOR}"
  assert_equal "${status}" 2
  assert_output --partial 'user.linger_inspect'
  linger_state maybe
  run harbor_user_linger "${FIX_ROOT}" "${OPERATOR}"
  assert_equal "${status}" 2
  assert_output --partial 'user.linger_inspect'
  assert_equal "$(shim_calls "enable-linger")" 0
  run ls -A "${FIX_ROOT}/journal"
  assert_output ''
  run harbor_user_linger "${FIX_ROOT}"
  assert_equal "${status}" 3
  assert_output --partial 'usage'
}

@test "lib/user.sh names no state root and no system configuration path" {
  run grep -n '/var/lib\|/etc/\|/usr/local' "${HARBOR_ROOT}/lib/user.sh"
  assert_failure
  assert_output ''
}
