#!/usr/bin/env bats
load '../test_helper'

# The four sleep targets of the design section 5.2 Power row, in the order
# lib/power.sh masks them. The list belongs to the library; the test names it
# again so a reordering is a failure rather than a silent change.
TARGETS="sleep.target suspend.target hibernate.target hybrid-sleep.target"
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
  # A fixture set where every sleep target is static (what Ubuntu ships) and both
  # mutating calls succeed.
  local unit
  rm -rf "${FX}"
  mkdir -p "${FX}/systemctl/healthy"
  : >"${FX}/systemctl/healthy/restart_systemd-logind.service.out"
  for unit in ${TARGETS}; do
    : >"${FX}/systemctl/healthy/mask_${unit}.out"
    unit_state "${unit}" static
  done
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
}

shim_lines() {
  # Every shim call, in order. A shim log that was never created is no calls.
  [ -e "${HARBOR_SHIM_LOG}" ] || return 0
  cat "${HARBOR_SHIM_LOG}"
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
  run shim_lines
  assert_line --index "$((${#lines[@]} - 1))" "systemctl${TAB}restart${TAB}systemd-logind.service"
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
  printf '1\n' >"${FX}/systemctl/healthy/restart_systemd-logind.service.exit"
  printf 'Job for systemd-logind.service failed\n' >"${FX}/systemctl/healthy/restart_systemd-logind.service.out"
  run harbor_power_configure "${FIX_ROOT}" "${ETC}"
  assert_equal "${status}" 2
  assert_output --partial 'power.logind_restart'
  assert_entry 0001 file "${DROPIN}" created applied '"absent"' "$(harbor_observe_file "${DROPIN}")"
  assert_equal "$(entries_owned created)" 5
}
