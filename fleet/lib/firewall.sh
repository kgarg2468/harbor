#!/bin/bash
# Firewall (design section 3.4): pre-state-aware ufw inspection and the journaled
# rules. Every mutation here is one journaled transaction of design section 3.7 and
# every branch is decided by inspection first (section 6.1). Harbor adds only rules
# carrying its own comment tag and issues no removal of any kind: what a reverse walk
# may later undo is only what these entries record. The state root is the caller's;
# this library names no absolute path and reads no configuration file.
# HARBOR_UFW_* and HARBOR_FIREWALL_* globals are set here and read by callers.
# shellcheck disable=SC2034
HARBOR_FIREWALL_INTERFACE="tailscale0"
HARBOR_FIREWALL_TAG="harbor"
HARBOR_FIREWALL_LAN_TAG="harbor-lan"
HARBOR_FIREWALL_SSH_PORT="22"
# harbor_ufw_status: inspection only, never a mutation. Sets HARBOR_UFW_ACTIVE to 1
# or 0 and, when active, HARBOR_UFW_DEFAULT_INCOMING and HARBOR_UFW_DEFAULT_OUTGOING
# to the policy words ufw reports. An inactive ufw prints its status line and nothing
# else: no default is in force, so there is none to read, and the caller must treat
# that as the pre-state it is. Any other output is fail-closed, exit 2.
harbor_ufw_status() {
  local out rc=0 line
  HARBOR_UFW_ACTIVE=""
  HARBOR_UFW_DEFAULT_INCOMING=""
  HARBOR_UFW_DEFAULT_OUTGOING=""
  harbor_log_vendor ufw status verbose
  out="$(ufw status verbose 2>&1)" || rc="$?"
  [ "${rc}" = 0 ] || harbor_die 2 firewall.inspect "ufw status verbose failed (exit ${rc}): ${out}"
  case "${out}" in
    *"Status: active"*) HARBOR_UFW_ACTIVE=1 ;;
    *"Status: inactive"*) HARBOR_UFW_ACTIVE=0 ;;
    *) harbor_die 2 firewall.inspect "ufw status verbose reported no status line: ${out}" ;;
  esac
  [ "${HARBOR_UFW_ACTIVE}" = 1 ] || return 0
  line="$(printf '%s\n' "${out}" | sed -n 's/^Default: //p' | sed -n 1p)"
  [ -n "${line}" ] || harbor_die 2 firewall.inspect "ufw status verbose reported an active firewall with no Default line: ${out}"
  HARBOR_UFW_DEFAULT_INCOMING="$(harbor_ufw_default_word "${line}" incoming)"
  HARBOR_UFW_DEFAULT_OUTGOING="$(harbor_ufw_default_word "${line}" outgoing)"
}
# harbor_ufw_default_word LINE DIRECTION: the policy word DIRECTION carries in ufw's
# "deny (incoming), allow (outgoing), disabled (routed)" line. Only a policy ufw
# itself can set is accepted; anything else is fail-closed, exit 2.
harbor_ufw_default_word() {
  local head
  case "${1}" in
    *" (${2})"*) ;;
    *) harbor_die 2 firewall.inspect "ufw status verbose named no ${2} default in 'Default: ${1}'" ;;
  esac
  head="${1%% (${2})*}"
  head="${head##*[ ,]}"
  case "${head}" in
    allow | deny | reject) ;;
    *) harbor_die 2 firewall.inspect "ufw status verbose reported an unknown ${2} default '${head}'" ;;
  esac
  printf '%s' "${head}"
}
# harbor_ufw_added: ufw's own user rule set, one rule per line in the exact command
# form ufw prints it back in, with the leading "ufw " and the quotes ufw puts around
# a comment removed. Inspection only.
harbor_ufw_added() {
  local out rc=0
  harbor_log_vendor ufw show added
  out="$(ufw show added 2>&1)" || rc="$?"
  [ "${rc}" = 0 ] || harbor_die 2 firewall.inspect "ufw show added failed (exit ${rc}): ${out}"
  printf '%s\n' "${out}" | sed -n 's/^ufw //p' | tr -d "'"
}
# harbor_ufw_rule_present RULE: 0 when ufw's own rule set already holds exactly RULE.
# A rule is identified by its full text, comment tag included, so Harbor recognizes
# only the rule it wrote and never claims another administrator's.
harbor_ufw_rule_present() {
  local added
  added="$(harbor_ufw_added)" || exit "$?"
  printf '%s\n' "${added}" | grep -qxF -- "${1}"
}
# harbor_observe_op_ufw_rule RULE: the observer harbor_journal_observe dispatches to
# for a ufw-rule entry, so an entry left prepared by a crash between the ufw call and
# the applied write is decidable by recovery (design section 3.7). The target is the
# exact rule text, so the state is its presence: "present" or "absent", asked of ufw
# itself through show added, which is the rule set ufw will enforce whether or not it
# is running at this instant. Inspection only; a ufw that cannot answer stays the
# exit 2 of harbor_ufw_added. Called only through harbor_journal_observe.
harbor_observe_op_ufw_rule() {
  if harbor_ufw_rule_present "${1}"; then
    printf '"present"'
  else
    printf '"absent"'
  fi
}
# harbor_observe_op_ufw_default DIRECTION: the observer for a ufw-default entry. The
# answer is the policy ufw reports for that direction, or "inactive" when the
# firewall is off, because a disabled ufw enforces no default at all: that is a
# truthful observation rather than an absence of one, and it is what makes an entry
# written while the firewall was still off decidable either way. It is also the
# record that Harbor, not the administrator, enabled the firewall, which is what
# section 3.7 requires before teardown may ever disable it. Inspection only; called
# only through harbor_journal_observe.
harbor_observe_op_ufw_default() {
  harbor_ufw_status
  if [ "${HARBOR_UFW_ACTIVE}" = 0 ]; then
    printf '"inactive"'
    return 0
  fi
  case "${1}" in
    incoming) printf '"%s"' "${HARBOR_UFW_DEFAULT_INCOMING}" ;;
    outgoing) printf '"%s"' "${HARBOR_UFW_DEFAULT_OUTGOING}" ;;
    *) harbor_die 2 firewall.observe "a ufw-default entry's target must be incoming or outgoing, got '${1}'" ;;
  esac
}
# harbor_ufw_run WORD...: one mutating ufw invocation, whose argv is the whole rule.
# A failure is exit 2 with ufw's own output, leaving every prepared entry for
# recovery.
harbor_ufw_run() {
  local out rc=0
  harbor_log_vendor ufw ${1+"$@"}
  out="$(ufw ${1+"$@"} 2>&1)" || rc="$?"
  [ "${rc}" = 0 ] || harbor_die 2 firewall.apply "ufw ${*} failed (exit ${rc}): ${out}"
}
# harbor_ufw_add RULE: add one rule. A ufw rule is its own argv, and RULE is Harbor's
# own text, built here from the constants above and, for the LAN rule, an address
# harbor_firewall_lan_network has already validated, so the split is deliberate.
harbor_ufw_add() {
  # shellcheck disable=SC2086
  harbor_ufw_run ${1}
}
# harbor_firewall_confirm ENTRY: the section 6.1 check after the apply. Re-observe
# the entry's own target through its own observer and mark it applied only when real
# state is what the entry predicted; otherwise exit 2 leaving it prepared.
harbor_firewall_confirm() {
  local entry="${1}" op target post observed
  [ -n "${entry}" ] || return 0
  op="$(harbor_journal_string "${entry}" op)"
  target="$(harbor_journal_string "${entry}" target)"
  post="$(harbor_journal_raw "${entry}" post_state)"
  observed="$(harbor_journal_observe "${op}" "${target}")" || exit "$?"
  [ "${observed}" = "${post}" ] \
    || harbor_die 2 firewall.verify "ufw reported success but ${op} ${target} observes ${observed}, not ${post}; the entry stays prepared for recovery"
  harbor_journal_set_phase "${entry}" applied
}
# harbor_firewall_prepare_rule STATE_ROOT RULE: the ufw-rule entry for RULE. A rule
# ufw already lists is the tagged rule an earlier run added, so it is journaled
# observed and never added twice. Sets HARBOR_FIREWALL_RULE_ENTRY to the prepared
# entry, or to the empty string when there is nothing to add.
harbor_firewall_prepare_rule() {
  HARBOR_FIREWALL_RULE_ENTRY=""
  if harbor_ufw_rule_present "${2}"; then
    harbor_journal_create "${1}" ufw-rule "${2}" observed applied '"present"' '"present"'
    return 0
  fi
  harbor_journal_create "${1}" ufw-rule "${2}" created prepared '"absent"' '"present"'
  HARBOR_FIREWALL_RULE_ENTRY="${HARBOR_JOURNAL_ENTRY}"
}
# harbor_firewall_default STATE_ROOT DIRECTION WANT FOUND ADOPT: one ufw-default
# entry on an already active firewall. Without --adopt-firewall the default ufw was
# already running is journaled observed and left exactly as it was, and one that
# differs from Harbor's posture is an informational note, never a failure (design
# section 3.4). With the flag, a differing default is journaled modified with the
# prior policy as pre_state, so the reverse walk restores it exactly, and only then
# changed.
harbor_firewall_default() {
  local root="${1}" dir="${2}" want="${3}" found="${4}" adopt="${5}" entry
  if [ "${found}" = "${want}" ] || [ "${adopt}" != 1 ]; then
    harbor_journal_create "${root}" ufw-default "${dir}" observed applied "\"${found}\"" "\"${found}\""
    [ "${found}" = "${want}" ] \
      || harbor_msg "firewall.default_${dir}: note: ufw was already active with default ${found} ${dir}; Harbor preserved it and added only its tagged rule (--adopt-firewall would set ${want} ${dir})"
    return 0
  fi
  harbor_journal_create "${root}" ufw-default "${dir}" modified prepared "\"${found}\"" "\"${want}\""
  entry="${HARBOR_JOURNAL_ENTRY}"
  harbor_ufw_run default "${want}" "${dir}"
  harbor_step "firewall-default-${dir}"
  harbor_firewall_confirm "${entry}"
}
# harbor_firewall_enable STATE_ROOT RULE LAN_RULE: the pre-state where ufw is not
# running. Harbor sets both defaults, adds its tagged rule, and enables, in that
# order, so the rule that keeps the node reachable is in place before anything starts
# filtering (design section 6.2). Nothing ufw does before the enable is in force, so
# the three entries are one group: each is prepared before its own command and all
# are confirmed after the enable, the point at which their post_states become
# observable.
harbor_firewall_enable() {
  local root="${1}" rule="${2}" lan_rule="${3}" e_rule e_lan="" e_in e_out
  harbor_firewall_prepare_rule "${root}" "${rule}"
  e_rule="${HARBOR_FIREWALL_RULE_ENTRY}"
  if [ -n "${lan_rule}" ]; then
    harbor_firewall_prepare_rule "${root}" "${lan_rule}"
    e_lan="${HARBOR_FIREWALL_RULE_ENTRY}"
  fi
  harbor_journal_create "${root}" ufw-default incoming created prepared '"inactive"' '"deny"'
  e_in="${HARBOR_JOURNAL_ENTRY}"
  harbor_journal_create "${root}" ufw-default outgoing created prepared '"inactive"' '"allow"'
  e_out="${HARBOR_JOURNAL_ENTRY}"
  harbor_ufw_run default deny incoming
  harbor_ufw_run default allow outgoing
  [ -z "${e_rule}" ] || harbor_ufw_add "${rule}"
  [ -z "${e_lan}" ] || harbor_ufw_add "${lan_rule}"
  harbor_ufw_run --force enable
  harbor_step firewall-enable
  harbor_firewall_confirm "${e_rule}"
  harbor_firewall_confirm "${e_lan}"
  harbor_firewall_confirm "${e_in}"
  harbor_firewall_confirm "${e_out}"
}
# harbor_firewall_extend STATE_ROOT RULE LAN_RULE ADOPT IN OUT: the pre-state where
# ufw is already running. Harbor adds its tagged rule and nothing else; the defaults
# it found are journaled, and changed only under --adopt-firewall. The rule is added
# before any default is touched, because on a running firewall every command is in
# force the moment it lands.
harbor_firewall_extend() {
  local root="${1}" rule="${2}" lan_rule="${3}" adopt="${4}"
  harbor_firewall_add_rule "${root}" "${rule}" firewall-rule
  [ -z "${lan_rule}" ] || harbor_firewall_add_rule "${root}" "${lan_rule}" firewall-lan-rule
  harbor_firewall_default "${root}" incoming deny "${5}" "${adopt}"
  harbor_firewall_default "${root}" outgoing allow "${6}" "${adopt}"
}
# harbor_firewall_add_rule STATE_ROOT RULE STEP: one tagged rule on a running
# firewall, as its own transaction with STEP as the boundary between the mutation and
# the applied write.
harbor_firewall_add_rule() {
  local entry
  harbor_firewall_prepare_rule "${1}" "${2}"
  entry="${HARBOR_FIREWALL_RULE_ENTRY}"
  [ -n "${entry}" ] || return 0
  harbor_ufw_add "${2}"
  harbor_step "${3}"
  harbor_firewall_confirm "${entry}"
}
# harbor_firewall_octet WORD: WORD as a decimal 0 to 255, or exit 3. Read with an
# explicit radix so a zero-padded octet is never taken as octal.
harbor_firewall_octet() {
  case "${1}" in
    "" | *[!0-9]*) harbor_die 3 firewall.lan_network "${2} is not an IPv4 address" ;;
  esac
  [ "$((10#${1}))" -le 255 ] || harbor_die 3 firewall.lan_network "${2} is not an IPv4 address"
  printf '%s' "$((10#${1}))"
}
# harbor_firewall_network ADDR PREFIX: the network ADDR belongs to, in CIDR form,
# for an ADDR this node holds on an RFC 1918 network. An address outside 10/8,
# 172.16/12, and 192.168/16 is not a LAN and exits 3 rather than being opened to.
harbor_firewall_network() {
  local addr="${1}" prefix="${2}" rest a b c d int mask net
  case "${prefix}" in
    "" | *[!0-9]*) harbor_die 3 firewall.lan_network "${addr}/${prefix} carries no prefix length" ;;
  esac
  prefix="$((10#${prefix}))"
  { [ "${prefix}" -ge 8 ] && [ "${prefix}" -le 32 ]; } \
    || harbor_die 3 firewall.lan_network "${addr}/${prefix} is not a prefix length Harbor will open a rule for"
  rest="${addr}"
  a="$(harbor_firewall_octet "${rest%%.*}" "${addr}")" || exit "$?"
  rest="${rest#*.}"
  b="$(harbor_firewall_octet "${rest%%.*}" "${addr}")" || exit "$?"
  rest="${rest#*.}"
  c="$(harbor_firewall_octet "${rest%%.*}" "${addr}")" || exit "$?"
  rest="${rest#*.}"
  case "${rest}" in
    *.*) harbor_die 3 firewall.lan_network "${addr} is not an IPv4 address" ;;
  esac
  d="$(harbor_firewall_octet "${rest}" "${addr}")" || exit "$?"
  if [ "${a}" -eq 10 ] \
    || { [ "${a}" -eq 172 ] && [ "${b}" -ge 16 ] && [ "${b}" -le 31 ]; } \
    || { [ "${a}" -eq 192 ] && [ "${b}" -eq 168 ]; }; then
    :
  else
    harbor_die 3 firewall.lan_network "this node's address ${addr} is not on an RFC 1918 network; --allow-lan-ssh opens port 22 to a private network only"
  fi
  int="$(((a << 24) + (b << 16) + (c << 8) + d))"
  mask="$((0xFFFFFFFF ^ ((1 << (32 - prefix)) - 1)))"
  net="$((int & mask))"
  printf '%s.%s.%s.%s/%s' \
    "$(((net >> 24) & 255))" "$(((net >> 16) & 255))" "$(((net >> 8) & 255))" "$((net & 255))" "${prefix}"
}
# harbor_firewall_word LINE KEY: the word LINE carries after KEY, or empty.
harbor_firewall_word() {
  local rest=" ${1}"
  case "${rest} " in
    *" ${2} "*) ;;
    *) return 0 ;;
  esac
  rest="${rest#*" ${2} "}"
  printf '%s' "${rest%% *}"
}
# harbor_firewall_lan_network: the RFC 1918 network this node is on, asked of the
# node's own routing table and interface rather than assumed: the interface the
# default route leaves by, then that interface's own address and prefix. A node with
# no default route, no address on it, or an address outside RFC 1918 has no LAN
# Harbor can name, and --allow-lan-ssh then exits 3 rather than opening a rule that
# is not the one the administrator asked for.
harbor_firewall_lan_network() {
  local out rc=0 dev cidr
  harbor_log_vendor ip -o -4 route show to default
  out="$(ip -o -4 route show to default 2>&1)" || rc="$?"
  [ "${rc}" = 0 ] \
    || harbor_die 3 firewall.lan_network "ip -o -4 route show to default failed (exit ${rc}): ${out}"
  dev="$(harbor_firewall_word "$(printf '%s\n' "${out}" | sed -n 1p)" dev)"
  [ -n "${dev}" ] \
    || harbor_die 3 firewall.lan_network "this node has no IPv4 default route, so --allow-lan-ssh cannot name its LAN; drop the flag or add the rule by hand"
  harbor_log_vendor ip -o -4 addr show dev "${dev}"
  out="$(ip -o -4 addr show dev "${dev}" 2>&1)" || rc="$?"
  [ "${rc}" = 0 ] \
    || harbor_die 3 firewall.lan_network "ip -o -4 addr show dev ${dev} failed (exit ${rc}): ${out}"
  cidr="$(harbor_firewall_word "$(printf '%s\n' "${out}" | sed -n 1p)" inet)"
  [ -n "${cidr}" ] \
    || harbor_die 3 firewall.lan_network "${dev} carries the default route but no IPv4 address, so --allow-lan-ssh cannot name this node's LAN"
  case "${cidr}" in
    */*) ;;
    *) harbor_die 3 firewall.lan_network "ip reported ${cidr} on ${dev} with no prefix length" ;;
  esac
  harbor_firewall_network "${cidr%%/*}" "${cidr#*/}" || exit "$?"
}
# harbor_firewall_apply STATE_ROOT [--adopt-firewall] [--allow-lan-ssh]: the firewall
# step of design section 3.4, decided by ufw's pre-state. Inactive: Harbor sets the
# defaults, adds its tagged rule, and enables. Already active: Harbor adds its tagged
# rule, journals the defaults it found, and changes nothing else unless
# --adopt-firewall. Every rule Harbor writes carries its own comment tag, and the
# only interface any of them names is tailscale0. Sets HARBOR_FIREWALL_LAN_WARNING.
harbor_firewall_apply() {
  local root adopt=0 lan=0 lan_net="" lan_rule="" rule def_in def_out
  [ "$#" -ge 1 ] || harbor_die 3 usage "usage: harbor_firewall_apply <state-root> [--adopt-firewall] [--allow-lan-ssh]"
  root="${1}"
  shift
  while [ "$#" -gt 0 ]; do
    case "${1}" in
      --adopt-firewall) adopt=1 ;;
      --allow-lan-ssh) lan=1 ;;
      *) harbor_die 3 usage "usage: harbor_firewall_apply <state-root> [--adopt-firewall] [--allow-lan-ssh]" ;;
    esac
    shift
  done
  HARBOR_FIREWALL_LAN_WARNING=""
  rule="allow in on ${HARBOR_FIREWALL_INTERFACE} to any port ${HARBOR_FIREWALL_SSH_PORT} proto tcp comment ${HARBOR_FIREWALL_TAG}"
  # The LAN network is resolved before any mutation, so a node whose LAN cannot be
  # named leaves the firewall exactly as it was.
  if [ "${lan}" = 1 ]; then
    lan_net="$(harbor_firewall_lan_network)" || exit "$?"
    lan_rule="allow in from ${lan_net} to any port ${HARBOR_FIREWALL_SSH_PORT} proto tcp comment ${HARBOR_FIREWALL_LAN_TAG}"
  fi
  harbor_ufw_status
  def_in="${HARBOR_UFW_DEFAULT_INCOMING}"
  def_out="${HARBOR_UFW_DEFAULT_OUTGOING}"
  if [ "${HARBOR_UFW_ACTIVE}" = 0 ]; then
    harbor_firewall_enable "${root}" "${rule}" "${lan_rule}"
  else
    harbor_firewall_extend "${root}" "${rule}" "${lan_rule}" "${adopt}" "${def_in}" "${def_out}"
  fi
  if [ -n "${lan_rule}" ]; then
    HARBOR_FIREWALL_LAN_WARNING="--allow-lan-ssh opened port 22 to ${lan_net}, so this node's SSH is reachable from every host on that network and not from the tailnet alone"
    harbor_msg "firewall.lan_ssh: warning: ${HARBOR_FIREWALL_LAN_WARNING}"
  fi
}
