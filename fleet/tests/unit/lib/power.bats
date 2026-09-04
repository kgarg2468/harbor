#!/usr/bin/env bats
load '../test_helper'

# The four sleep targets of the design section 5.2 Power row, in the order
# lib/power.sh masks them. The list belongs to the library; the test names it
# again so a reordering is a failure rather than a silent change.
TARGETS="sleep.target suspend.target hibernate.target hybrid-sleep.target"
# The three lid properties of the design section 5.2 Power row and where the running
# logind publishes them, named again here so a change in the library is a failure rather
# than a silent change, exactly as the target list above is.
PROPERTIES="HandleLidSwitch HandleLidSwitchExternalPower HandleLidSwitchDocked"
BUS_NAME="org.freedesktop.login1"
OBJECT="/org/freedesktop/login1"
INTERFACE="org.freedesktop.login1.Manager"
TAB="$(printf '\t')"

setup() {
  # lib/power.sh depends on lib/log.sh, lib/lock.sh, and lib/journal.sh.
  # shellcheck source=lib/log.sh
  . "${HARBOR_ROOT}/lib/log.sh"
  # shellcheck source=lib/lock.sh
  . "${HARBOR_ROOT}/lib/lock.sh"
  # shellcheck source=lib/journal.sh
  . "${HARBOR_ROOT}/lib/journal.sh"
  # shellcheck source=lib/power.sh
  . "${HARBOR_ROOT}/lib/power.sh"
  fixture_state_root
  HARBOR_PID="$$"
  # The systemctl shim is this test's own symlink to the generic shim, in its own
  # disposable bin directory: no test writes into the repository's shim directory.
  BIN="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "${BIN}"
  ln -s "${HARBOR_ROOT}/tests/shims/bin/harbor-shim" "${BIN}/systemctl"
  # busctl is how the row asks the running logind what it is doing with the lid. It has
  # no state to model, so it goes straight to the shim.
  ln -s "${HARBOR_ROOT}/tests/shims/bin/harbor-shim" "${BIN}/busctl"
  PATH="${BIN}:${PATH}"
  export PATH
  HARBOR_SHIM_LOG="${BATS_TEST_TMPDIR}/shim.log"
  export HARBOR_SHIM_LOG
  WITNESS="${BATS_TEST_TMPDIR}/witness.log"
  FX="${BATS_TEST_TMPDIR}/fx"
  HARBOR_SHIM_FIXTURES="${FX}"
  export HARBOR_SHIM_FIXTURES
  # The logind drop-in lands under a fixture configuration root, never the real
  # system one: the destination root is a parameter of the function under test.
  ETC="${BATS_TEST_TMPDIR}/etc"
  DROPIN="${ETC}/systemd/logind.conf.d/harbor.conf"
  fixtures_init
  harbor_lock_acquire "${FIX_ROOT}" operator
}

teardown() {
  harbor_lock_release "${FIX_ROOT}"
}

fixtures_init() {
  # A fixture set where every sleep target is static (what Ubuntu ships), the running
  # logind still suspends on a closed lid, which is what a node that has never seen this
  # row does, and both mutating calls succeed.
  local unit property
  rm -rf "${FX}"
  mkdir -p "${FX}/systemctl/healthy" "${FX}/busctl/healthy"
  : >"${FX}/systemctl/healthy/restart_systemd-logind.service.out"
  for unit in ${TARGETS}; do
    : >"${FX}/systemctl/healthy/mask_${unit}.out"
    unit_state "${unit}" static
  done
  for property in ${PROPERTIES}; do
    lid_handler "${property}" suspend
  done
}

lid_handler() {
  # lid_handler PROPERTY VALUE: what the running logind answers when it is asked for
  # PROPERTY, in the signature-and-value shape busctl prints a string property in.
  local key
  key="$(printf '%s' "get-property ${BUS_NAME} ${OBJECT} ${INTERFACE} ${1}" | tr ' /' '_%')"
  printf 's "%s"\n' "${2}" >"${FX}/busctl/healthy/${key}.out"
  rm -f "${FX}/busctl/healthy/${key}.exit"
}

lid_unreadable() {
  # lid_unreadable [OUTPUT]: a logind whose lid policy cannot be read, either because
  # busctl fails or because it answers something that is not the property.
  local key
  key="$(printf '%s' "get-property ${BUS_NAME} ${OBJECT} ${INTERFACE} HandleLidSwitch" | tr ' /' '_%')"
  printf '%s\n' "${1:-Failed to get property HandleLidSwitch: Connection refused}" \
    >"${FX}/busctl/healthy/${key}.out"
  if [ "$#" -eq 0 ]; then
    printf '1\n' >"${FX}/busctl/healthy/${key}.exit"
  else
    rm -f "${FX}/busctl/healthy/${key}.exit"
  fi
}

logind_reload() {
  # What restarting logind does: it reads the drop-in and runs what it finds there, and
  # goes on suspending on a lid it is told nothing about. This is what makes the query
  # in the library a real question about the daemon rather than a canned answer.
  local property value
  for property in ${PROPERTIES}; do
    value=""
    [ ! -f "${DROPIN}" ] || value="$(sed -n "s/^${property}=//p" "${DROPIN}" | sed -n 1p)"
    lid_handler "${property}" "${value:-suspend}"
  done
}

restart_fails() {
  # The restart of a logind that will not come back: the drop-in is in place and the
  # policy the node is running is still the previous one.
  printf '1\n' >"${FX}/systemctl/healthy/restart_systemd-logind.service.exit"
  printf 'Job for systemd-logind.service failed\n' \
    >"${FX}/systemctl/healthy/restart_systemd-logind.service.out"
}

restart_succeeds() {
  rm -f "${FX}/systemctl/healthy/restart_systemd-logind.service.exit"
  : >"${FX}/systemctl/healthy/restart_systemd-logind.service.out"
}

unit_state() {
  # unit_state UNIT WORD: what systemctl is-enabled UNIT answers. A masked unit
  # exits 1, as the real systemctl does, so the library is proven to decide on the
  # word it prints and not on the exit code.
  printf '%s\n' "${2}" >"${FX}/systemctl/healthy/is-enabled_${1}.out"
  if [ "${2}" = masked ]; then
    printf '1\n' >"${FX}/systemctl/healthy/is-enabled_${1}.exit"
  else
    rm -f "${FX}/systemctl/healthy/is-enabled_${1}.exit"
  fi
}

systemctl() {
  # The shim is stateless, so the effect a real mask has on systemd is modeled
  # here: the shim is still what runs and logs, and after a successful mask the
  # is-enabled answer for that unit becomes masked. The witness records, for every
  # call, whether the drop-in was already in place when the call was made, which is
  # how "restarted after the drop-in is in place" is asserted.
  if [ -f "${DROPIN}" ]; then
    printf 'present'
  else
    printf 'absent'
  fi >>"${WITNESS}"
  printf '\t%s\n' "${*}" >>"${WITNESS}"
  command systemctl ${1+"$@"} || return "$?"
  if [ "${1}" = mask ] && [ "${MASK_TAKES:-1}" = 1 ]; then
    unit_state "${2}" masked
  fi
  if [ "${1}" = restart ] && [ "${RESTART_TAKES:-1}" = 1 ]; then
    logind_reload
  fi
}

shim_lines() {
  # Every shim call, in order. A shim log that was never created is no calls.
  [ -e "${HARBOR_SHIM_LOG}" ] || return 0
  cat "${HARBOR_SHIM_LOG}"
}

call_index() {
  # call_index LINE: how many shim calls preceded that exact one, so the order two
  # steps ran in can be asserted rather than assumed
  grep -nxF -- "${1}" "${HARBOR_SHIM_LOG}" | sed -n 1p | cut -d: -f1
}

mask_calls() {
  [ -e "${HARBOR_SHIM_LOG}" ] || {
    printf '0\n'
    return 0
  }
  grep -c "^systemctl${TAB}mask${TAB}" "${HARBOR_SHIM_LOG}" || true
}

restart_calls() {
  [ -e "${HARBOR_SHIM_LOG}" ] || {
    printf '0\n'
    return 0
  }
  grep -c "^systemctl${TAB}restart${TAB}" "${HARBOR_SHIM_LOG}" || true
}

mutating_calls() {
  [ -e "${HARBOR_SHIM_LOG}" ] || {
    printf '0\n'
    return 0
  }
  grep -cE "^systemctl${TAB}(mask|unmask|restart|reload|set-property)${TAB}" "${HARBOR_SHIM_LOG}" || true
}

dropin_settings() {
  # The drop-in without its comment header and blank lines.
  grep -v -e '^#' -e '^[[:space:]]*$' "${DROPIN}"
}

mask_state() {
  printf '{"unit_file_state":"%s"}' "${1}"
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

@test "the drop-in holds exactly the three lid settings at mode 0644 under the destination root it is given" {
  run harbor_power_configure "${FIX_ROOT}" "${ETC}"
  assert_success
  run dropin_settings
  assert_line --index 0 '[Login]'
  assert_line --index 1 'HandleLidSwitch=ignore'
  assert_line --index 2 'HandleLidSwitchExternalPower=ignore'
  assert_line --index 3 'HandleLidSwitchDocked=ignore'
  assert_equal "${#lines[@]}" 4
  assert_equal "$(harbor_stat_mode "${DROPIN}")" 0644
  assert_equal "$(harbor_stat_mode "$(dirname "${DROPIN}")")" 0755
  assert_entry 0001 file "${DROPIN}" created applied '"absent"' "$(harbor_observe_file "${DROPIN}")"
  run ls -A "$(dirname "${DROPIN}")"
  refute_output --partial '.tmp'
  assert_output harbor.conf
}

@test "the production destination root is the design section 5.2 path and is only a default" {
  assert_equal "$(harbor_power_dropin_path)" /etc/systemd/logind.conf.d/harbor.conf
  assert_equal "$(harbor_power_dropin_path "${ETC}")" "${DROPIN}"
  run harbor_power_configure "${FIX_ROOT}" "${ETC}"
  assert_success
  # Nothing outside the fixture root was written.
  run find "${BATS_TEST_TMPDIR}" -name harbor.conf
  assert_output "${DROPIN}"
}

@test "each of the four sleep targets is masked exactly once, in order, with its pre-state journaled" {
  run harbor_power_configure "${FIX_ROOT}" "${ETC}"
  assert_success
  assert_equal "$(mask_calls)" 4
  run shim_lines
  assert_line --index 0 "systemctl${TAB}is-enabled${TAB}sleep.target"
  assert_line --index 1 "systemctl${TAB}mask${TAB}sleep.target"
  assert_line --index 2 "systemctl${TAB}is-enabled${TAB}sleep.target"
  assert_line --index 3 "systemctl${TAB}is-enabled${TAB}suspend.target"
  assert_line --index 4 "systemctl${TAB}mask${TAB}suspend.target"
  assert_line --index 6 "systemctl${TAB}is-enabled${TAB}hibernate.target"
  assert_line --index 7 "systemctl${TAB}mask${TAB}hibernate.target"
  assert_line --index 9 "systemctl${TAB}is-enabled${TAB}hybrid-sleep.target"
  assert_line --index 10 "systemctl${TAB}mask${TAB}hybrid-sleep.target"
  assert_entry 0002 systemd-mask sleep.target created applied "$(mask_state static)" "$(mask_state masked)"
  assert_entry 0003 systemd-mask suspend.target created applied "$(mask_state static)" "$(mask_state masked)"
  assert_entry 0004 systemd-mask hibernate.target created applied "$(mask_state static)" "$(mask_state masked)"
  assert_entry 0005 systemd-mask hybrid-sleep.target created applied "$(mask_state static)" "$(mask_state masked)"
  run ls -A "${FIX_ROOT}/journal"
  assert_equal "${#lines[@]}" 5
}

@test "an already-masked target is journaled observed with no systemctl mask call and is never unmasked" {
  unit_state suspend.target masked
  # A runtime mask lives in /run and is gone after a reboot, so it is not the
  # persistent mask this step is about: hibernate is masked properly, not skipped.
  unit_state hibernate.target masked-runtime
  run harbor_power_configure "${FIX_ROOT}" "${ETC}"
  assert_success
  assert_equal "$(mask_calls)" 3
  run shim_lines
  refute_line --partial "mask${TAB}suspend.target"
  refute_line --partial unmask
  assert_entry 0003 systemd-mask suspend.target observed applied "$(mask_state masked)" "$(mask_state masked)"
  assert_entry 0004 systemd-mask hibernate.target created applied "$(mask_state masked-runtime)" "$(mask_state masked)"
  assert_equal "$(entries_owned observed)" 1
  assert_equal "$(entries_owned created)" 4
}

@test "systemd-logind is restarted once, after the drop-in is in place" {
  run harbor_power_configure "${FIX_ROOT}" "${ETC}"
  assert_success
  assert_equal "$(restart_calls)" 1
  # The restart is the last thing this row changes, and what follows it is section 6.1's
  # check running again after the apply: the three properties read back from the logind
  # the restart produced. So the restart is the last mutating call rather than the last
  # call, and the reads after it are reads.
  run shim_lines
  assert_line --index "$((${#lines[@]} - 4))" "systemctl${TAB}restart${TAB}systemd-logind.service"
  local tail_calls
  tail_calls="$(printf '%s\n' "${lines[@]}" | sed -n "$((${#lines[@]} - 2)),\$p" | cut -f1 | sort -u)"
  assert_equal "${tail_calls}" busctl
  # Every call the library made, with what the destination root held at the time:
  # the drop-in is in place before the first systemctl call and still in place when
  # the restart is made.
  run cat "${WITNESS}"
  assert_line --index 0 "present${TAB}is-enabled sleep.target"
  assert_line --index "$((${#lines[@]} - 1))" "present${TAB}restart systemd-logind.service"
  refute_line --partial "absent${TAB}"
}

@test "a rerun that finds the drop-in identical journals observed, rewrites nothing, and makes no mutating call" {
  run harbor_power_configure "${FIX_ROOT}" "${ETC}"
  assert_success
  before="$(harbor_observe_file "${DROPIN}")"
  : >"${HARBOR_SHIM_LOG}"
  run harbor_power_configure "${FIX_ROOT}" "${ETC}"
  assert_success
  assert_equal "$(mutating_calls)" 0
  assert_equal "$(harbor_observe_file "${DROPIN}")" "${before}"
  assert_entry 0006 file "${DROPIN}" observed applied "${before}" "${before}"
  assert_entry 0007 systemd-mask sleep.target observed applied "$(mask_state masked)" "$(mask_state masked)"
  assert_entry 0010 systemd-mask hybrid-sleep.target observed applied "$(mask_state masked)" "$(mask_state masked)"
  assert_equal "$(entries_owned created)" 5
  assert_equal "$(entries_owned modified)" 0
  assert_equal "$(entries_owned observed)" 5
  run ls -A "${FIX_ROOT}/journal"
  assert_equal "${#lines[@]}" 10
}

@test "a drop-in with different content is rewritten and journaled modified with the prior content's state" {
  mkdir -p "$(dirname "${DROPIN}")"
  printf '[Login]\nHandleLidSwitch=suspend\n' >"${DROPIN}"
  chmod 0600 "${DROPIN}"
  pre="$(harbor_observe_file "${DROPIN}")"
  run harbor_power_configure "${FIX_ROOT}" "${ETC}"
  assert_success
  run dropin_settings
  assert_line --index 1 'HandleLidSwitch=ignore'
  assert_equal "${#lines[@]}" 4
  assert_equal "$(harbor_stat_mode "${DROPIN}")" 0644
  assert_entry 0001 file "${DROPIN}" modified applied "${pre}" "$(harbor_observe_file "${DROPIN}")"
  assert_equal "$(restart_calls)" 1
}

@test "a foreign non-regular file at the drop-in path exits 3 untouched with nothing journaled" {
  mkdir -p "${DROPIN}"
  run harbor_power_configure "${FIX_ROOT}" "${ETC}"
  assert_equal "${status}" 3
  assert_output --partial 'power.foreign'
  assert_output --partial "${DROPIN}"
  assert [ -d "${DROPIN}" ]
  assert_equal "$(mutating_calls)" 0
  run ls -A "${FIX_ROOT}/journal"
  assert_output ''
}

@test "recovery decides a prepared systemd-mask entry: unmasked is reverted, masked is applied, a third state is undecidable" {
  # The crash window of design section 3.7: systemctl mask ran or did not, and the
  # applied write never happened. Recovery asks systemctl and decides without asking
  # the operator.
  fixture_entry "${FIX_ROOT}" 0001 systemd-mask sleep.target created prepared "$(mask_state static)" "$(mask_state masked)"
  run harbor_journal_recover "${FIX_ROOT}"
  assert_success
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" reverted
  unit_state sleep.target masked
  fixture_entry "${FIX_ROOT}" 0002 systemd-mask sleep.target created prepared "$(mask_state static)" "$(mask_state masked)"
  run harbor_journal_recover "${FIX_ROOT}"
  assert_success
  assert_equal "$(entry_phase "${FIX_ROOT}" 0002)" applied
  unit_state sleep.target disabled
  fixture_entry "${FIX_ROOT}" 0003 systemd-mask sleep.target created prepared "$(mask_state static)" "$(mask_state masked)"
  run --separate-stderr harbor_journal_recover "${FIX_ROOT}"
  assert_equal "${status}" 2
  assert_regex "${stderr}" 'journal entry 0003-systemd-mask.json is undecidable:'
  assert_regex "${stderr}" 'observed:   \{"unit_file_state":"disabled"\}'
  assert_regex "${stderr}" 'journal.undecidable: prepared entries 0003 cannot be decided'
  assert_equal "$(entry_phase "${FIX_ROOT}" 0003)" prepared
  # Deciding an entry inspects only.
  assert_equal "$(mutating_calls)" 0
}

@test "recovery decides a prepared drop-in file entry from the states harbor_observe_file renders" {
  harbor_power_lid "${FIX_ROOT}" "${ETC}"
  post="$(harbor_observe_file "${DROPIN}")"
  rm -f "${DROPIN}"
  fixture_entry "${FIX_ROOT}" 0002 file "${DROPIN}" created prepared '"absent"' "${post}"
  run harbor_journal_recover "${FIX_ROOT}"
  assert_success
  assert_equal "$(entry_phase "${FIX_ROOT}" 0002)" reverted
  harbor_power_lid "${FIX_ROOT}" "${ETC}"
  fixture_entry "${FIX_ROOT}" 0004 file "${DROPIN}" created prepared '"absent"' "${post}"
  run harbor_journal_recover "${FIX_ROOT}"
  assert_success
  assert_equal "$(entry_phase "${FIX_ROOT}" 0004)" applied
}

@test "a failing systemctl mask leaves the entry prepared for recovery and exits 2" {
  printf '1\n' >"${FX}/systemctl/healthy/mask_sleep.target.exit"
  printf 'Failed to mask unit: Access denied\n' >"${FX}/systemctl/healthy/mask_sleep.target.out"
  run harbor_power_configure "${FIX_ROOT}" "${ETC}"
  assert_equal "${status}" 2
  assert_output --partial 'power.mask'
  assert_output --partial 'sleep.target'
  assert_entry 0002 systemd-mask sleep.target created prepared "$(mask_state static)" "$(mask_state masked)"
  assert_equal "$(restart_calls)" 0
  run ls -A "${FIX_ROOT}/journal"
  assert_equal "${#lines[@]}" 2
}

@test "a mask that reports success without taking effect exits 2 and leaves the entry prepared" {
  MASK_TAKES=0
  run harbor_power_configure "${FIX_ROOT}" "${ETC}"
  assert_equal "${status}" 2
  assert_output --partial 'power.mask_verify'
  assert_entry 0002 systemd-mask sleep.target created prepared "$(mask_state static)" "$(mask_state masked)"
  assert_equal "$(restart_calls)" 0
}

@test "an unrecognized systemctl is-enabled answer is fail-closed: exit 2, nothing journaled, nothing masked" {
  printf 'Failed to get unit file state for sleep.target: No such file or directory\n' \
    >"${FX}/systemctl/healthy/is-enabled_sleep.target.out"
  printf '1\n' >"${FX}/systemctl/healthy/is-enabled_sleep.target.exit"
  run harbor_power_mask_sleep "${FIX_ROOT}"
  assert_equal "${status}" 2
  assert_output --partial 'power.unit_state'
  assert_output --partial 'sleep.target'
  assert_equal "$(mutating_calls)" 0
  run ls -A "${FIX_ROOT}/journal"
  assert_output ''
}

@test "a failing systemctl restart exits 2 after the drop-in is applied" {
  restart_fails
  run harbor_power_configure "${FIX_ROOT}" "${ETC}"
  assert_equal "${status}" 2
  assert_output --partial 'power.logind_restart'
  assert_entry 0001 file "${DROPIN}" created applied '"absent"' "$(harbor_observe_file "${DROPIN}")"
  assert_equal "$(entries_owned created)" 5
}

@test "a restart that failed is still owed on the rerun that finds the drop-in identical" {
  # The convergence defect this asserts against is the failure and the rerun as one
  # sequence, which is the only order it appears in: each half on its own passes.
  # Run 1 writes the drop-in, masks the four targets, and then cannot restart logind,
  # so the node is left running the previous lid policy.
  restart_fails
  run harbor_power_configure "${FIX_ROOT}" "${ETC}"
  assert_equal "${status}" 2
  assert_output --partial 'power.logind_restart'
  assert_equal "$(restart_calls)" 1
  # Run 2, with the cause fixed, finds the drop-in byte for byte what it would write
  # and every target already masked, so it rewrites nothing and masks nothing. The
  # restart is owed all the same, because logind has still never read this drop-in,
  # and a run that reported success without making it would leave a laptop node
  # suspending on a closed lid while Harbor called the row applied.
  restart_succeeds
  : >"${HARBOR_SHIM_LOG}"
  run harbor_power_configure "${FIX_ROOT}" "${ETC}"
  assert_success
  assert_equal "$(restart_calls)" 1
  assert_equal "$(mask_calls)" 0
  assert_entry 0006 file "${DROPIN}" observed applied \
    "$(harbor_observe_file "${DROPIN}")" "$(harbor_observe_file "${DROPIN}")"
  # The restart is owed once, not on every run: run 3 finds the node in the state run 2
  # left it in and makes no mutating call at all.
  : >"${HARBOR_SHIM_LOG}"
  run harbor_power_configure "${FIX_ROOT}" "${ETC}"
  assert_success
  assert_equal "$(mutating_calls)" 0
  run cat "${WITNESS}"
  refute_line --partial "absent${TAB}"
}

@test "a logind running another lid policy is restarted even though the drop-in is identical" {
  run harbor_power_configure "${FIX_ROOT}" "${ETC}"
  assert_success
  assert_equal "$(restart_calls)" 1
  # Somebody edits the drop-in by hand and restarts logind for their edit, and then puts
  # the file back. Nothing on disk records that, and nothing Harbor did records it
  # either: the file is byte for byte what this row writes and the run that restarted
  # logind for that content really happened. The only thing that knows is logind, and
  # asking it is what makes this row converge instead of reporting a policy the node is
  # not running.
  lid_handler HandleLidSwitchDocked suspend
  : >"${HARBOR_SHIM_LOG}"
  run harbor_power_configure "${FIX_ROOT}" "${ETC}"
  assert_success
  assert_equal "$(restart_calls)" 1
  assert_equal "$(mask_calls)" 0
  assert_entry 0006 file "${DROPIN}" observed applied \
    "$(harbor_observe_file "${DROPIN}")" "$(harbor_observe_file "${DROPIN}")"
  run dropin_settings
  assert_line --index 3 'HandleLidSwitchDocked=ignore'
}

@test "the three lid properties are read from the running logind, each by one busctl call" {
  run harbor_power_configure "${FIX_ROOT}" "${ETC}"
  assert_success
  local property
  # On a node that has never seen this row the first property already differs, which is
  # the whole answer, so that is where the reading stops and the restart is owed.
  run shim_lines
  assert_line "busctl${TAB}get-property${TAB}${BUS_NAME}${TAB}${OBJECT}${TAB}${INTERFACE}${TAB}HandleLidSwitch"
  assert [ "$(call_index "busctl${TAB}get-property${TAB}${BUS_NAME}${TAB}${OBJECT}${TAB}${INTERFACE}${TAB}HandleLidSwitch")" \
    -lt "$(call_index "systemctl${TAB}restart${TAB}${HARBOR_POWER_LOGIND_UNIT}")" ]
  # Calling the row applied takes all three, each asked once: a node that ignores the
  # lid on battery and suspends on it docked is not the node this row promises.
  : >"${HARBOR_SHIM_LOG}"
  run harbor_power_configure "${FIX_ROOT}" "${ETC}"
  assert_success
  assert_equal "$(mutating_calls)" 0
  run shim_lines
  for property in ${PROPERTIES}; do
    assert_line "busctl${TAB}get-property${TAB}${BUS_NAME}${TAB}${OBJECT}${TAB}${INTERFACE}${TAB}${property}"
  done
  assert_equal "${#lines[@]}" 7
}

@test "a restart that reports success without taking effect exits 2 rather than reporting the row applied" {
  # Section 6.1: the check runs again after the apply. systemctl exits 0 and logind comes
  # back running what it was running before — a unit that failed to re-read its
  # configuration, or a drop-in directory it does not look in. Without the read-back this
  # is the one failure the row would report as applied, and the node would go on
  # suspending on a closed lid with Harbor saying the power policy is in place.
  RESTART_TAKES=0
  run harbor_power_configure "${FIX_ROOT}" "${ETC}"
  assert_equal "${status}" 2
  assert_output --partial 'power.logind_verify'
  assert_output --partial "${DROPIN}"
  assert_equal "$(restart_calls)" 1
}

@test "a logind whose lid policy cannot be read is fail-closed: exit 2 and nothing is restarted" {
  # An unreadable answer must never be read as "the policy is already applied": that is
  # the one failure that would skip the restart on every run forever.
  lid_unreadable
  run harbor_power_configure "${FIX_ROOT}" "${ETC}"
  assert_equal "${status}" 2
  assert_output --partial 'power.lid_policy'
  assert_output --partial 'Connection refused'
  assert_equal "$(restart_calls)" 0
  # The same when busctl exits 0 and answers something that is not the property.
  fixtures_init
  lid_unreadable 'not a property at all'
  run harbor_power_configure "${FIX_ROOT}" "${ETC}"
  assert_equal "${status}" 2
  assert_output --partial 'power.lid_policy'
  assert_output --partial 'HandleLidSwitch'
  assert_equal "$(restart_calls)" 0
}
