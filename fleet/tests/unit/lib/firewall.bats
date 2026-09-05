#!/usr/bin/env bats
load '../test_helper'

TAB="$(printf '\t')"
RULE="allow in on tailscale0 to any port 22 proto tcp comment harbor"
LAN_RULE="allow in from 192.168.1.0/24 to any port 22 proto tcp comment harbor-lan"

setup() {
  # lib/firewall.sh depends on lib/log.sh, lib/lock.sh, and lib/journal.sh.
  # shellcheck source=lib/log.sh
  . "${HARBOR_ROOT}/lib/log.sh"
  # shellcheck source=lib/lock.sh
  . "${HARBOR_ROOT}/lib/lock.sh"
  # shellcheck source=lib/journal.sh
  . "${HARBOR_ROOT}/lib/journal.sh"
  # shellcheck source=lib/firewall.sh
  . "${HARBOR_ROOT}/lib/firewall.sh"
  fixture_state_root
  HARBOR_PID="$$"
  # ufw and ip are system binaries this lane never has and never runs: both are the
  # PR 2 shim under the test's own temporary directory, first on PATH, answering from
  # fixtures this file writes. Nothing here touches a real firewall.
  BIN="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "${BIN}"
  ln -s "${HARBOR_ROOT}/tests/shims/bin/harbor-shim" "${BIN}/ufw"
  ln -s "${HARBOR_ROOT}/tests/shims/bin/harbor-shim" "${BIN}/ip"
  PATH="${BIN}:${PATH}"
  export PATH
  FX="${BATS_TEST_TMPDIR}/fx"
  ST="${FX}/ufw-state"
  mkdir -p "${FX}/ufw/healthy" "${FX}/ip/healthy" "${ST}"
  HARBOR_SHIM_FIXTURES="${FX}"
  export HARBOR_SHIM_FIXTURES
  HARBOR_SHIM_LOG="${BATS_TEST_TMPDIR}/shim.log"
  export HARBOR_SHIM_LOG
  UFW_FAIL=""
  # The fake's state lives in files, as a real firewall's does, because Harbor runs
  # every ufw call in a command substitution and a shell variable set there would not
  # outlive it.
  : >"${ST}/added"
  # ufw ships deny incoming, allow outgoing, and starts disabled.
  ufw_state inactive deny allow
  net_fixture eth0 192.168.1.23/24
  harbor_lock_acquire "${FIX_ROOT}" operator
}

teardown() {
  harbor_lock_release "${FIX_ROOT}"
}

ufw_state() {
  # ufw_state STATUS DEFAULT_IN DEFAULT_OUT: the firewall's pre-state, its rule set
  # left as it stands
  printf '%s\n' "${1}" >"${ST}/status"
  printf '%s\n' "${2}" >"${ST}/in"
  printf '%s\n' "${3}" >"${ST}/out"
  ufw_render
}

ufw_render() {
  # What ufw answers next. An inactive ufw reports its status and nothing else: it
  # prints no Default line and no rule table, which is exactly why the two
  # inspection commands answer as they do.
  {
    printf 'Status: %s\n' "$(cat "${ST}/status")"
    if [ "$(cat "${ST}/status")" = active ]; then
      printf 'Logging: on (low)\n'
      printf 'Default: %s (incoming), %s (outgoing), disabled (routed)\n' \
        "$(cat "${ST}/in")" "$(cat "${ST}/out")"
      printf 'New profiles: skip\n'
    fi
  } >"${FX}/ufw/healthy/status_verbose.out"
  {
    printf "Added user rules (see 'ufw status' for running firewall):\n"
    cat "${ST}/added"
  } >"${FX}/ufw/healthy/show_added.out"
}

ufw_add_rule() {
  # The rule set ufw show added prints back: its own "ufw " prefix and its own
  # quotes around the comment.
  local rule="${1}" head tag
  case "${rule}" in
    *" comment "*)
      head="${rule% comment *}"
      tag="${rule##* comment }"
      rule="${head} comment '${tag}'"
      ;;
  esac
  printf 'ufw %s\n' "${rule}" >>"${ST}/added"
}

ufw_key() {
  printf '%s' "${*}" | tr ' /' '_%'
}

ufw() {
  # The ufw state machine. The shim is still what runs and logs; this models the
  # effect each command has on what ufw answers next, and writes the reply fixture
  # only for a command the fake models, so an unmodeled ufw invocation (a delete, a
  # reset, a disable) finds no fixture and fails loudly.
  local rc=0 key
  key="$(ufw_key "${@}")"
  case "${*}" in
    "status verbose" | "show added") ;;
    "default "*" incoming" | "default "*" outgoing" | "--force enable" | "allow "*)
      : >"${FX}/ufw/healthy/${key}.out"
      if [ "${*}" = "${UFW_FAIL}" ]; then
        printf 'ERROR: fixture failure\n' >"${FX}/ufw/healthy/${key}.out"
        printf '1\n' >"${FX}/ufw/healthy/${key}.exit"
      fi
      ;;
  esac
  command ufw ${1+"$@"} || rc="$?"
  if [ "${rc}" = 0 ]; then
    case "${*}" in
      "default "*" incoming") printf '%s\n' "${2}" >"${ST}/in" ;;
      "default "*" outgoing") printf '%s\n' "${2}" >"${ST}/out" ;;
      "--force enable") printf 'active\n' >"${ST}/status" ;;
      "allow "*) ufw_add_rule "${*}" ;;
    esac
    ufw_render
  fi
  return "${rc}"
}

net_fixture() {
  # net_fixture DEV CIDR: what the node's own routing table and interface report,
  # in the oneline form lib/firewall.sh asks for
  printf 'default via 192.168.1.1 dev %s proto dhcp src %s metric 100 \n' "${1}" "${2%%/*}" \
    >"${FX}/ip/healthy/$(ufw_key -o -4 route show to default).out"
  printf '2: %s    inet %s brd 192.168.1.255 scope global dynamic %s\\       valid_lft 3000sec preferred_lft 3000sec\n' \
    "${1}" "${2}" "${1}" >"${FX}/ip/healthy/$(ufw_key -o -4 addr show dev "${1}").out"
}

ufw_calls() {
  [ -e "${HARBOR_SHIM_LOG}" ] || {
    printf '0\n'
    return 0
  }
  grep -c "^ufw${TAB}" "${HARBOR_SHIM_LOG}" || true
}

mutating_ufw() {
  # Every ufw invocation that is not one of the two inspection queries.
  [ -e "${HARBOR_SHIM_LOG}" ] || return 0
  grep "^ufw${TAB}" "${HARBOR_SHIM_LOG}" \
    | grep -v "^ufw${TAB}status${TAB}verbose\$" \
    | grep -v "^ufw${TAB}show${TAB}added\$" || true
}

mutating_count() {
  mutating_ufw | grep -c . || true
}

interfaces_named() {
  # Every interface any ufw rule Harbor issued names, over the whole shim log.
  awk -F"${TAB}" '$1 == "ufw" { for (i = 2; i < NF; i++) if ($i == "on") print $(i + 1) }' \
    "${HARBOR_SHIM_LOG}"
}

entries_owned() {
  grep -l "^  \"ownership\": \"${1}\",\$" "${FIX_ROOT}"/journal/*.json 2>/dev/null | wc -l | tr -d ' '
}

assert_entry() {
  # assert_entry SEQ OP TARGET OWNERSHIP PHASE PRE POST
  assert [ -f "${FIX_ROOT}/journal/${1}-${2}.json" ]
  assert_equal "$(entry_raw "${FIX_ROOT}" "${1}" target)" "\"${3}\""
  assert_equal "$(entry_raw "${FIX_ROOT}" "${1}" ownership)" "\"${4}\""
  assert_equal "$(entry_phase "${FIX_ROOT}" "${1}")" "${5}"
  assert_equal "$(entry_raw "${FIX_ROOT}" "${1}" pre_state)" "\"${6}\""
  assert_equal "$(entry_raw "${FIX_ROOT}" "${1}" post_state)" "\"${7}\""
}

entry_count() {
  ls -A "${FIX_ROOT}/journal" | grep -c . || true
}

@test "an inactive ufw is set deny in, allow out, given the tagged rule, and enabled, in that order and nothing else" {
  run harbor_firewall_apply "${FIX_ROOT}"
  assert_success
  run mutating_ufw
  assert_line --index 0 "ufw${TAB}default${TAB}deny${TAB}incoming"
  assert_line --index 1 "ufw${TAB}default${TAB}allow${TAB}outgoing"
  assert_line --index 2 "ufw${TAB}allow${TAB}in${TAB}on${TAB}tailscale0${TAB}to${TAB}any${TAB}port${TAB}22${TAB}proto${TAB}tcp${TAB}comment${TAB}harbor"
  assert_line --index 3 "ufw${TAB}--force${TAB}enable"
  assert_equal "${#lines[@]}" 4
  # The rule entry is first so the reverse walk disables the firewall Harbor
  # enabled before it deletes the rule that keeps the node reachable.
  assert_entry 0001 ufw-rule "${RULE}" created applied absent present
  assert_entry 0002 ufw-default incoming created applied inactive deny
  assert_entry 0003 ufw-default outgoing created applied inactive allow
  assert_equal "$(entry_count)" 3
}

@test "an already active ufw gets only the tagged rule: no default command, no enable, and the defaults it found are journaled" {
  ufw_state active deny allow
  run harbor_firewall_apply "${FIX_ROOT}"
  assert_success
  run mutating_ufw
  assert_line --index 0 "ufw${TAB}allow${TAB}in${TAB}on${TAB}tailscale0${TAB}to${TAB}any${TAB}port${TAB}22${TAB}proto${TAB}tcp${TAB}comment${TAB}harbor"
  assert_equal "${#lines[@]}" 1
  run grep "^ufw${TAB}" "${HARBOR_SHIM_LOG}"
  refute_output --partial "${TAB}default${TAB}"
  refute_output --partial "${TAB}enable"
  assert_entry 0001 ufw-rule "${RULE}" created applied absent present
  assert_entry 0002 ufw-default incoming observed applied deny deny
  assert_entry 0003 ufw-default outgoing observed applied allow allow
  assert_equal "$(entries_owned observed)" 2
  assert_equal "$(entry_count)" 3
}

@test "an active firewall whose defaults differ is left alone without --adopt-firewall, journaled observed, and reported as a note" {
  ufw_state active allow allow
  run harbor_firewall_apply "${FIX_ROOT}"
  assert_success
  assert_output --partial 'firewall.default_incoming'
  assert_output --partial 'allow'
  assert_output --partial '--adopt-firewall'
  run mutating_ufw
  assert_equal "${#lines[@]}" 1
  assert_line --index 0 --partial "${TAB}allow${TAB}in${TAB}on${TAB}tailscale0"
  assert_entry 0001 ufw-rule "${RULE}" created applied absent present
  assert_entry 0002 ufw-default incoming observed applied allow allow
  assert_entry 0003 ufw-default outgoing observed applied allow allow
  assert_equal "$(entries_owned modified)" 0
}

@test "--adopt-firewall changes only the default that differs and journals the prior default it replaced" {
  ufw_state active allow allow
  run harbor_firewall_apply "${FIX_ROOT}" --adopt-firewall
  assert_success
  run mutating_ufw
  assert_line --index 0 --partial "${TAB}allow${TAB}in${TAB}on${TAB}tailscale0"
  assert_line --index 1 "ufw${TAB}default${TAB}deny${TAB}incoming"
  assert_equal "${#lines[@]}" 2
  assert_entry 0001 ufw-rule "${RULE}" created applied absent present
  assert_entry 0002 ufw-default incoming modified applied allow deny
  assert_entry 0003 ufw-default outgoing observed applied allow allow
  assert_equal "$(entries_owned modified)" 1
}

@test "no ufw rule Harbor writes names any interface but tailscale0" {
  net_fixture eth0 192.168.1.23/24
  run harbor_firewall_apply "${FIX_ROOT}" --allow-lan-ssh
  assert_success
  run interfaces_named
  assert_line --index 0 tailscale0
  assert_equal "${#lines[@]}" 1
  run grep "^ufw${TAB}" "${HARBOR_SHIM_LOG}"
  refute_output --partial eth0
  refute_output --partial ens5
  refute_output --partial wlan0
  # The LAN rule names a network, never the interface that network is on.
  assert_output --partial "${TAB}from${TAB}192.168.1.0/24${TAB}"
}

@test "a rerun that finds the tagged rule adds nothing and makes no mutating call" {
  run harbor_firewall_apply "${FIX_ROOT}"
  assert_success
  assert_equal "$(entries_owned created)" 3
  : >"${HARBOR_SHIM_LOG}"
  run harbor_firewall_apply "${FIX_ROOT}"
  assert_success
  assert_equal "$(mutating_count)" 0
  assert [ "$(ufw_calls)" -gt 0 ]
  assert_entry 0004 ufw-rule "${RULE}" observed applied present present
  assert_entry 0005 ufw-default incoming observed applied deny deny
  assert_entry 0006 ufw-default outgoing observed applied allow allow
  assert_equal "$(entries_owned created)" 3
  assert_equal "$(entries_owned modified)" 0
  assert_equal "$(entry_count)" 6
}

@test "--allow-lan-ssh journals a rule for the node's own RFC 1918 network and warns rather than passing silently" {
  ufw_state active deny allow
  run harbor_firewall_apply "${FIX_ROOT}" --allow-lan-ssh
  assert_success
  assert_output --partial 'firewall.lan_ssh'
  assert_output --partial 'warning'
  assert_output --partial '192.168.1.0/24'
  assert_entry 0001 ufw-rule "${RULE}" created applied absent present
  assert_entry 0002 ufw-rule "${LAN_RULE}" created applied absent present
  run mutating_ufw
  assert_equal "${#lines[@]}" 2
}

@test "the LAN network is the node's own address masked by its own prefix" {
  ufw_state active deny allow
  net_fixture ens5 10.1.2.3/22
  run harbor_firewall_apply "${FIX_ROOT}" --allow-lan-ssh
  assert_success
  assert_output --partial '10.1.0.0/22'
  assert_entry 0002 ufw-rule "allow in from 10.1.0.0/22 to any port 22 proto tcp comment harbor-lan" created applied absent present
  net_fixture eth0 172.20.30.40/16
  : >"${HARBOR_SHIM_LOG}"
  run harbor_firewall_apply "${FIX_ROOT}" --allow-lan-ssh
  assert_success
  assert_entry 0005 ufw-rule "${RULE}" observed applied present present
  assert_entry 0006 ufw-rule "allow in from 172.20.0.0/16 to any port 22 proto tcp comment harbor-lan" created applied absent present
}

@test "--allow-lan-ssh with no determinable RFC 1918 network exits 3 before any mutation" {
  : >"${FX}/ip/healthy/$(ufw_key -o -4 route show to default).out"
  run harbor_firewall_apply "${FIX_ROOT}" --allow-lan-ssh
  assert_equal "${status}" 3
  assert_output --partial 'firewall.lan_network'
  assert_equal "$(mutating_count)" 0
  assert_equal "$(entry_count)" 0
  # A routable, non-RFC 1918 address is not a LAN and is never opened to.
  net_fixture eth0 203.0.113.9/24
  run harbor_firewall_apply "${FIX_ROOT}" --allow-lan-ssh
  assert_equal "${status}" 3
  assert_output --partial 'firewall.lan_network'
  assert_output --partial '203.0.113.9'
  assert_equal "$(mutating_count)" 0
  assert_equal "$(entry_count)" 0
}

@test "a crash between the mutation and the applied write leaves entries recovery decides without touching the firewall" {
  # The enable fails after the defaults and the rule have landed: the exact window
  # of design section 3.7, with every entry still prepared.
  UFW_FAIL="--force enable"
  run harbor_firewall_apply "${FIX_ROOT}"
  assert_equal "${status}" 2
  assert_output --partial 'firewall.apply'
  assert_entry 0001 ufw-rule "${RULE}" created prepared absent present
  assert_entry 0002 ufw-default incoming created prepared inactive deny
  assert_entry 0003 ufw-default outgoing created prepared inactive allow
  UFW_FAIL=""
  : >"${HARBOR_SHIM_LOG}"
  # The rule landed, the firewall is still off: the rule is applied, and a default
  # that is not yet in force is exactly the pre_state, so it is reverted.
  run harbor_journal_recover "${FIX_ROOT}"
  assert_success
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" applied
  assert_equal "$(entry_phase "${FIX_ROOT}" 0002)" reverted
  assert_equal "$(entry_phase "${FIX_ROOT}" 0003)" reverted
  assert_equal "$(mutating_count)" 0
  assert_equal "$(entry_count)" 3
  # And once the firewall is up with those defaults, the same entries are applied.
  ufw_state active deny allow
  fixture_entry "${FIX_ROOT}" 0004 ufw-default incoming created prepared '"inactive"' '"deny"'
  fixture_entry "${FIX_ROOT}" 0005 ufw-rule "${RULE}" created prepared '"absent"' '"present"'
  run harbor_journal_recover "${FIX_ROOT}"
  assert_success
  assert_equal "$(entry_phase "${FIX_ROOT}" 0004)" applied
  assert_equal "$(entry_phase "${FIX_ROOT}" 0005)" applied
}

@test "a prepared entry whose observed state matches neither recorded state is undecidable, never guessed" {
  ufw_state active reject allow
  fixture_entry "${FIX_ROOT}" 0001 ufw-default incoming created prepared '"inactive"' '"deny"'
  run --separate-stderr harbor_journal_recover "${FIX_ROOT}"
  assert_equal "${status}" 2
  assert_regex "${stderr}" 'journal entry 0001-ufw-default.json is undecidable:'
  assert_regex "${stderr}" 'observed:   "reject"'
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" prepared
  assert_equal "$(mutating_count)" 0
}

@test "every op lib/firewall.sh emits has an observer, and each answers by asking ufw" {
  ufw_state active deny allow
  run harbor_firewall_apply "${FIX_ROOT}" --allow-lan-ssh
  assert_success
  : >"${HARBOR_SHIM_LOG}"
  assert_equal "$(harbor_journal_observe ufw-rule "${RULE}")" '"present"'
  assert_equal "$(harbor_journal_observe ufw-rule "${LAN_RULE}")" '"present"'
  assert_equal "$(harbor_journal_observe ufw-rule "allow in on tailscale0 to any port 2222 proto tcp comment harbor")" '"absent"'
  assert_equal "$(harbor_journal_observe ufw-default incoming)" '"deny"'
  assert_equal "$(harbor_journal_observe ufw-default outgoing)" '"allow"'
  ufw_state inactive deny allow
  assert_equal "$(harbor_journal_observe ufw-default incoming)" '"inactive"'
  # Observing is asking ufw, not reading a file, and it never mutates.
  assert [ "$(ufw_calls)" -gt 0 ]
  assert_equal "$(mutating_count)" 0
}

@test "a ufw that cannot answer is fail-closed and journals nothing" {
  printf 'Status: baffled\n' >"${FX}/ufw/healthy/status_verbose.out"
  run harbor_firewall_apply "${FIX_ROOT}"
  assert_equal "${status}" 2
  assert_output --partial 'firewall.inspect'
  assert_equal "$(entry_count)" 0
  rm "${FX}/ufw/healthy/status_verbose.out"
  run harbor_firewall_apply "${FIX_ROOT}"
  assert_equal "${status}" 2
  assert_output --partial 'firewall.inspect'
  assert_equal "$(entry_count)" 0
}

@test "harbor_firewall_apply refuses a flag it does not know and a call with no state root" {
  run harbor_firewall_apply
  assert_equal "${status}" 3
  assert_output --partial usage
  run harbor_firewall_apply "${FIX_ROOT}" --adopt-everything
  assert_equal "${status}" 3
  assert_output --partial usage
  assert_equal "$(ufw_calls)" 0
  assert_equal "$(entry_count)" 0
}

@test "lib/firewall.sh removes no rule and disables no firewall" {
  run grep -nE 'ufw[^|]*(delete|reset|disable)' "${HARBOR_ROOT}/lib/firewall.sh"
  assert_failure
  # The one interface the library can name is the tailnet's.
  run grep -nE 'eth[0-9]|en[ps][0-9]|wlan[0-9]|enx[0-9a-f]' "${HARBOR_ROOT}/lib/firewall.sh"
  assert_failure
  run grep -c 'HARBOR_FIREWALL_INTERFACE="tailscale0"' "${HARBOR_ROOT}/lib/firewall.sh"
  assert_output 1
}
