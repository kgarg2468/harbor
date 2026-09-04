#!/usr/bin/env bats
load '../test_helper'

# node/bootstrap.sh at fixture paths (design section 7). Nothing here touches
# /etc, /var/lib, /usr/local, /opt, the real operator state root, or sudo: the
# script reads every production path, the machine architecture, whether the caller
# is root, and the exec itself from HARBOR_BOOTSTRAP_FIXTURE_* variables it consults
# only when id -u is not 0, exactly as lib/checkout.sh, lib/entrypoint.sh, and
# lib/ssh.sh consult their own stand-ins, so no root code path can ever see one.
#
# Every vendor command the design section 5.2 rows reach (apt-get, dpkg-query,
# getent, useradd, loginctl, systemctl, sshd, ufw, ip, runuser) is the PR 2 shim
# under a link in this test's own fixture base, first on PATH, and no real package
# manager, account database, unit manager, daemon, or firewall is ever asked
# anything. The subject here is a subprocess rather than a sourced function, so the
# state a real command leaves behind is modeled by a wrapper script beside the shim
# rather than by a shell function overriding it, exactly as tests/unit/lib/apt.bats,
# power.bats, ssh.bats, and firewall.bats model it in-process: the shim is still
# what answers and what logs, and the wrapper only rewrites the fixture the next
# call reads.

setup() {
  # The tree hash of a fixture release is needed to seed a harbor-install entry, and
  # that hash must be the one the journal observer computes, so this file sources the
  # libraries lib/release.sh needs rather than harbor_load_libs.
  # shellcheck source=../../../lib/log.sh
  . "${HARBOR_ROOT}/lib/log.sh"
  # shellcheck source=../../../lib/lock.sh
  . "${HARBOR_ROOT}/lib/lock.sh"
  # shellcheck source=../../../lib/journal.sh
  . "${HARBOR_ROOT}/lib/journal.sh"
  # shellcheck source=../../../lib/release.sh
  . "${HARBOR_ROOT}/lib/release.sh"
  # The state record's first reader in production is lib/entrypoint.sh, so the record the
  # last row writes is asserted with that reader rather than with a second one of this
  # file's own.
  # shellcheck source=../../../lib/entrypoint.sh
  . "${HARBOR_ROOT}/lib/entrypoint.sh"
  TEST_USER="$(id -un)"
  # The checkout trust rules judge every component from / to the checkout root, so the
  # checkout fixture cannot live under BATS_TEST_TMPDIR: on Linux that sits under
  # /tmp, whose 1777 mode the rules reject, correctly. Every component of ${HOME} is
  # owned by root or by the test user and none is group- or world-writable on either
  # platform, so a disposable directory there is the one fixture base whose ancestors
  # pass, as tests/unit/lib/checkout.bats already found. The whole fixture node lives
  # under it so that one teardown removes all of it.
  FIX_BASE="$(cd "$(mktemp -d "${HOME}/.harbor-bootstrap-test.XXXXXX")" && pwd -P)"
  chmod 0755 "${FIX_BASE}"
  TAG=v0.3.0
  OTHER_TAG=v0.2.0
  OPERATOR=harbor
  ADMIN=ubuntu
  STATE="${FIX_BASE}/var/lib/harbor"
  INSTALL="${FIX_BASE}/usr/local/lib/harbor"
  LINK="${FIX_BASE}/usr/local/bin/harbor"
  CHECKOUT="${FIX_BASE}/checkout"
  OSREL="${FIX_BASE}/os-release"
  EXECLOG="${FIX_BASE}/exec.argv"
  HOMES="${FIX_BASE}/home"
  ARCH=amd64
  ASSUME_ROOT=1
  # The remaining rows of the design section 5.2 table reach three more production
  # paths, each of which becomes a fixture path here: the Node.js prefix, the
  # configuration root both drop-ins are written under, and the bin directory
  # beside the entrypoint link, which the script derives from the link itself.
  NODE_PREFIX="${FIX_BASE}/opt/harbor/node"
  ETC="${FIX_BASE}/etc"
  BINDIR="${FIX_BASE}/usr/local/bin"
  DROPIN="${ETC}/ssh/sshd_config.d/50-harbor-operator.conf"
  GLOBAL_DROPIN="${ETC}/ssh/sshd_config.d/51-harbor-global.conf"
  LOGIND="${ETC}/systemd/logind.conf.d/harbor.conf"
  TARGETS="sleep.target suspend.target hibernate.target hybrid-sleep.target"
  # The three lid properties the Power row promises, under the names the running logind
  # publishes them on its D-Bus interface, which is what the row reads to decide whether
  # a restart is owed.
  PROPERTIES="HandleLidSwitch HandleLidSwitchExternalPower HandleLidSwitchDocked"
  PACKAGES="git curl ufw jq openssh-server ca-certificates"
  RULE="allow in on tailscale0 to any port 22 proto tcp comment harbor"
  LAN_RULE="allow in from 192.168.1.0/24 to any port 22 proto tcp comment harbor-lan"
  # The account the rows act on. lib/ssh.sh chowns the operator's authorized key to
  # it and lib/node.sh runs a login shell as it, so it has to be an account that
  # really exists, and the only account an unprivileged test may chown to is the one
  # it already runs as, exactly as tests/unit/lib/ssh.bats resolves the same
  # problem. It is deliberately not the script's own default operator, so every
  # journal entry and every drop-in naming it is proof that --operator reached that
  # row rather than proof of a default.
  OPUSER="${TEST_USER}"
  NODE_LOCKED="$(sed -n 's/^nodejs_version=//p' "${HARBOR_ROOT}/versions.lock")"
  mkdir -p "${FIX_BASE}/var/lib" "${INSTALL}" "${BINDIR}" \
    "${HOMES}/${ADMIN}/.ssh"
  KEYSRC="${HOMES}/${ADMIN}/.ssh/authorized_keys"
  printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5 fixture\n' >"${KEYSRC}"
  os_release ubuntu 24.04
  # getent resolves to the PR 2 shim through a link in the fixture base, so the
  # operator clash refusal consults no real account or group on either platform.
  BIN="${FIX_BASE}/bin"
  FX="${FIX_BASE}/fx"
  mkdir -p "${BIN}" "${FX}/getent/healthy"
  ln -s "${HARBOR_ROOT}/tests/shims/bin/harbor-shim" "${BIN}/getent"
  absent_account "${OPERATOR}"
  absent_account "${OPUSER}"
  group_entry sudo 27 "${ADMIN}"
  no_group_entry admin
  vendor_init
  build_checkout
  ARGV0="${CHECKOUT}/bin/harbor"
}

teardown() {
  case "${FIX_BASE:-}" in
    /*/.harbor-bootstrap-test.??????) rm -rf "${FIX_BASE}" ;;
  esac
}

os_release() {
  # os_release ID VERSION_ID: /etc/os-release as Ubuntu writes it, quoted values
  # included, at the fixture path the script reads instead.
  printf 'PRETTY_NAME="Ubuntu %s LTS"\nNAME="Ubuntu"\nID=%s\nVERSION_ID="%s"\n' \
    "${2}" "${1}" "${2}" >"${OSREL}"
}

gitc() {
  git -C "${CHECKOUT}" -c user.name=Harbor -c user.email=harbor@example.com \
    -c commit.gpgsign=false -c init.defaultBranch=main -c core.hooksPath=/dev/null "$@"
}

build_checkout() {
  # A checkout as a clone at a release tag leaves one: trusted ownership, no
  # group- or other-writable path, a clean work tree, and HEAD exactly at a tag.
  mkdir -p "${CHECKOUT}/bin" "${CHECKOUT}/lib" "${CHECKOUT}/node"
  printf '#!/bin/bash\nexit 0\n' >"${CHECKOUT}/bin/harbor"
  printf '# lib\n' >"${CHECKOUT}/lib/log.sh"
  printf '# node\n' >"${CHECKOUT}/node/bootstrap.sh"
  # The modes are set before the commit, because Git tracks the executable bit and a
  # chmod afterwards would leave the work tree dirty rather than clean.
  chmod 0755 "${CHECKOUT}/bin/harbor"
  chmod 0644 "${CHECKOUT}/lib/log.sh" "${CHECKOUT}/node/bootstrap.sh"
  gitc init -q
  gitc add -A
  gitc commit -q -m 'fixture release'
  gitc tag "${TAG}"
  chmod -R go-w "${CHECKOUT}"
  chmod 0755 "${CHECKOUT}" "${CHECKOUT}/bin" "${CHECKOUT}/lib" "${CHECKOUT}/node"
}

build_release() {
  # build_release TAG: an installed release directory with the installed modes of
  # design section 5.2, as harbor_release_stage leaves one, and its argv0.
  local rel="${INSTALL}/${1}"
  mkdir -p "${rel}/bin" "${rel}/lib" "${rel}/node"
  printf '#!/bin/bash\nexit 0\n' >"${rel}/bin/harbor"
  printf '# lib\n' >"${rel}/lib/log.sh"
  printf '# node\n' >"${rel}/node/bootstrap.sh"
  printf 'tag=%s\ncommit=%s\n' "${1}" 0123456789abcdef0123456789abcdef01234567 >"${rel}/RELEASE"
  chmod 0755 "${rel}" "${rel}/bin" "${rel}/lib" "${rel}/node" "${rel}/bin/harbor"
  chmod 0644 "${rel}/RELEASE" "${rel}/lib/log.sh" "${rel}/node/bootstrap.sh"
  RELEASE_DIR="${rel}"
  ARGV0="${rel}/bin/harbor"
}

write_record() {
  # write_record TAG: a bootstrap.json an earlier run left, in the state root with the
  # modes bootstrap creates it with. It carries the two keys the preflight reads and not
  # the whole contract, which is the last row's to write.
  mkdir -p "${STATE}"
  chmod 0755 "${STATE}"
  printf '{\n  "release_tag": "%s",\n  "entrypoint": "%s"\n}\n' "${1}" "${LINK}" \
    >"${STATE}/bootstrap.json"
  chmod 0644 "${STATE}/bootstrap.json"
}

passwd_entry() {
  # passwd_entry USER SHELL UID GID: what getent passwd USER answers
  printf '%s:x:%s:%s:Harbor:/home/%s:%s\n' "${1}" "${3}" "${4}" "${1}" "${2}" \
    >"${FX}/getent/healthy/passwd_${1}.out"
  rm -f "${FX}/getent/healthy/passwd_${1}.exit"
}

absent_account() {
  # getent exits 2 for a key it cannot find.
  : >"${FX}/getent/healthy/passwd_${1}.out"
  printf '2\n' >"${FX}/getent/healthy/passwd_${1}.exit"
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

vkey() {
  # vkey WORD...: the fixture key the PR 2 shim derives from an argv
  printf '%s' "${*}" | tr ' /' '_%'
}

vendor_shim() {
  # vendor_shim NAME: the shim under NAME in a directory that is not on PATH, so a
  # wrapper can be NAME on PATH, model the state the real command leaves, and still
  # let the shim be what answers and what logs.
  ln -s "${HARBOR_ROOT}/tests/shims/bin/harbor-shim" "${SHIM}/${1}"
}

vendor_direct() {
  # vendor_direct NAME: a command with no state to model, straight to the shim.
  ln -s "${HARBOR_ROOT}/tests/shims/bin/harbor-shim" "${BIN}/${1}"
}

vendor_wrapper() {
  # vendor_wrapper NAME: BIN/NAME, whose body is this function's stdin and whose
  # paths come from the one file every wrapper sources, so the body can be written
  # with its own quoting intact.
  vendor_shim "${1}"
  {
    printf '#!/bin/bash\nset -euo pipefail\n'
    printf '. "${HARBOR_TEST_VENDOR}"\n'
    cat
  } >"${BIN}/${1}"
  chmod 0755 "${BIN}/${1}"
}

vendor_init() {
  # Every vendor command of the design section 5.2 rows, answering from this test's
  # own fixture tree, with the state a real command would leave modeled beside it.
  local unit
  REPO_FX="${HARBOR_ROOT}/tests/fixtures/shims"
  SHIM="${FIX_BASE}/shim"
  VST="${FIX_BASE}/vendor-state"
  SHIMLOG="${FIX_BASE}/shim.log"
  VENDOR_ENV="${FIX_BASE}/vendor.env"
  mkdir -p "${SHIM}" "${VST}" "${FX}/apt-get" "${FX}/dpkg-query" \
    "${FX}/useradd/healthy" "${FX}/loginctl/healthy" "${FX}/systemctl/healthy" \
    "${FX}/busctl/healthy" \
    "${FX}/sshd/healthy" "${FX}/ufw/healthy" "${FX}/ip/healthy" "${FX}/runuser/healthy"
  {
    printf 'FX="%s"\n' "${FX}"
    printf 'SHIM="%s"\n' "${SHIM}"
    printf 'VST="%s"\n' "${VST}"
    printf 'REPO_FX="%s"\n' "${REPO_FX}"
    printf 'HOMES="%s"\n' "${HOMES}"
    printf 'DROPIN="%s"\n' "${DROPIN}"
    printf 'GLOBAL_DROPIN="%s"\n' "${GLOBAL_DROPIN}"
    printf 'LOGIND="%s"\n' "${LOGIND}"
    printf 'PROPERTIES="%s"\n' "${PROPERTIES}"
    printf 'OPUSER="%s"\n' "${OPUSER}"
  } >"${VENDOR_ENV}"
  # Packages: the repository's own dpkg-query and apt-get fixture sets, a node on
  # which none of the six is installed, and the installed set the mutating call
  # switches to, exactly as tests/unit/lib/apt.bats composes them.
  ln -s "${REPO_FX}/dpkg-query/none" "${FX}/dpkg-query/healthy"
  ln -s "${REPO_FX}/apt-get/none" "${FX}/apt-get/healthy"
  vendor_direct dpkg-query
  vendor_wrapper apt-get <<'WRAPPER'
rc=0
"${SHIM}/apt-get" "$@" || rc="$?"
if [ "${rc}" = 0 ] && [ "${1}" = install ]; then
  rm -f "${FX}/dpkg-query/healthy"
  ln -s "${REPO_FX}/dpkg-query/installed" "${FX}/dpkg-query/healthy"
fi
exit "${rc}"
WRAPPER
  # The operator account: useradd creates the home and makes the name service
  # answer, which is what the row's own verification then reads back.
  : >"${FX}/useradd/healthy/$(vkey --create-home --shell /bin/bash "${OPUSER}").out"
  vendor_wrapper useradd <<'WRAPPER'
rc=0
op=""
for arg in "$@"; do op="${arg}"; done
"${SHIM}/useradd" "$@" || rc="$?"
if [ "${rc}" = 0 ]; then
  mkdir -p "${HOMES}/${op}"
  printf '%s:x:4242:4242:Harbor:%s/%s:/bin/bash\n' "${op}" "${HOMES}" "${op}" \
    >"${FX}/getent/healthy/passwd_${op}.out"
  rm -f "${FX}/getent/healthy/passwd_${op}.exit"
fi
exit "${rc}"
WRAPPER
  # Linger: logind answers no until enable-linger has run, and yes afterwards.
  linger_state no
  : >"${FX}/loginctl/healthy/$(vkey enable-linger "${OPUSER}").out"
  vendor_wrapper loginctl <<'WRAPPER'
rc=0
"${SHIM}/loginctl" "$@" || rc="$?"
if [ "${rc}" = 0 ] && [ "${1}" = enable-linger ]; then
  printf 'yes\n' \
    >"${FX}/loginctl/healthy/show-user_${2}_--property=Linger_--value.out"
fi
exit "${rc}"
WRAPPER
  # Power and the sshd reload: the four sleep targets ship static, and a mask makes
  # systemctl report the unit masked, which is what the row verifies.
  for unit in ${TARGETS}; do
    unit_state "${unit}" static
    : >"${FX}/systemctl/healthy/mask_${unit}.out"
  done
  : >"${FX}/systemctl/healthy/restart_systemd-logind.service.out"
  : >"${FX}/systemctl/healthy/reload_ssh.service.out"
  printf 'active\n' >"${FX}/systemctl/healthy/is-active_ssh.service.out"
  # The running logind: it still suspends on a closed lid, as a node that has never seen
  # the Power row does, until a restart makes it read the drop-in. busctl is how the row
  # asks it, and it has no state of its own to model.
  local property
  for property in ${PROPERTIES}; do
    lid_handler "${property}" suspend
  done
  vendor_direct busctl
  vendor_wrapper systemctl <<'WRAPPER'
rc=0
"${SHIM}/systemctl" "$@" || rc="$?"
if [ "${rc}" = 0 ] && [ "${1}" = restart ] && [ "${2}" = systemd-logind.service ]; then
  # What restarting logind does: it reads the lid drop-in and runs what it finds there,
  # and goes on suspending on a lid it is told nothing about.
  for property in ${PROPERTIES}; do
    value=""
    [ ! -f "${LOGIND}" ] || value="$(sed -n "s/^${property}=//p" "${LOGIND}" | sed -n 1p)"
    key="$(printf '%s' "get-property org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager ${property}" | tr ' /' '_%')"
    printf 's "%s"\n' "${value:-suspend}" >"${FX}/busctl/healthy/${key}.out"
  done
fi
if [ "${rc}" = 0 ] && [ "${1}" = mask ]; then
  printf 'masked\n' >"${FX}/systemctl/healthy/is-enabled_${2}.out"
  printf '1\n' >"${FX}/systemctl/healthy/is-enabled_${2}.exit"
fi
exit "${rc}"
WRAPPER
  # sshd: what it reports for a user is computed from the drop-ins on disk at the
  # instant it is asked, which is what makes the row's before-and-after proof a real
  # one rather than a canned answer.
  : >"${FX}/sshd/healthy/-t.out"
  vendor_wrapper sshd <<'WRAPPER'
who=""
for arg in "$@"; do
  case "${arg}" in user=*) who="${arg#user=}" ;; esac
done
if [ -n "${who}" ]; then
  lines='port 22
permitrootlogin prohibit-password
pubkeyauthentication yes
passwordauthentication yes
kbdinteractiveauthentication yes
usepam yes
x11forwarding yes'
  if [ "${who}" = "${OPUSER}" ] && [ -f "${DROPIN}" ]; then
    lines="$(printf '%s\n' "${lines}" \
      | sed -e 's/^passwordauthentication .*/passwordauthentication no/' \
        -e 's/^kbdinteractiveauthentication .*/kbdinteractiveauthentication no/')"
  fi
  if [ "${who}" != "${OPUSER}" ] && [ -f "${GLOBAL_DROPIN}" ]; then
    lines="$(printf '%s\n' "${lines}" \
      | sed -e 's/^permitrootlogin .*/permitrootlogin no/' \
        -e 's/^passwordauthentication .*/passwordauthentication no/')"
  fi
  printf '%s\n' "${lines}" >"${FX}/sshd/healthy/-T_-C_user=${who}.out"
fi
exec "${SHIM}/sshd" "$@"
WRAPPER
  # The firewall, as ufw itself reports it: a state machine in files, because every
  # ufw call the library makes runs in a command substitution of its own.
  printf 'inactive\n' >"${VST}/status"
  printf 'deny\n' >"${VST}/in"
  printf 'allow\n' >"${VST}/out"
  : >"${VST}/added"
  vendor_wrapper ufw <<'WRAPPER'
{
  printf 'Status: %s\n' "$(cat "${VST}/status")"
  if [ "$(cat "${VST}/status")" = active ]; then
    printf 'Logging: on (low)\n'
    printf 'Default: %s (incoming), %s (outgoing), disabled (routed)\n' \
      "$(cat "${VST}/in")" "$(cat "${VST}/out")"
    printf 'New profiles: skip\n'
  fi
} >"${FX}/ufw/healthy/status_verbose.out"
{
  printf "Added user rules (see 'ufw status' for running firewall):\n"
  cat "${VST}/added"
} >"${FX}/ufw/healthy/show_added.out"
key="$(printf '%s' "${*}" | tr ' /' '_%')"
case "${*}" in
  'status verbose' | 'show added') ;;
  'default '*' incoming' | 'default '*' outgoing' | '--force enable' | 'allow '*)
    : >"${FX}/ufw/healthy/${key}.out"
    ;;
esac
rc=0
"${SHIM}/ufw" "$@" || rc="$?"
if [ "${rc}" = 0 ]; then
  case "${*}" in
    'default '*' incoming') printf '%s\n' "${2}" >"${VST}/in" ;;
    'default '*' outgoing') printf '%s\n' "${2}" >"${VST}/out" ;;
    '--force enable') printf 'active\n' >"${VST}/status" ;;
    'allow '*)
      rule="${*}"
      case "${rule}" in
        *' comment '*) rule="${rule% comment *} comment '${rule##* comment }'" ;;
      esac
      printf 'ufw %s\n' "${rule}" >>"${VST}/added"
      ;;
  esac
fi
exit "${rc}"
WRAPPER
  # The node's own routing table and interface, for --allow-lan-ssh.
  printf 'default via 192.168.1.1 dev eth0 proto dhcp src 192.168.1.23 metric 100 \n' \
    >"${FX}/ip/healthy/$(vkey -o -4 route show to default).out"
  printf '2: eth0    inet 192.168.1.23/24 brd 192.168.1.255 scope global dynamic eth0\n' \
    >"${FX}/ip/healthy/$(vkey -o -4 addr show dev eth0).out"
  vendor_direct ip
  # The report-only Node.js probe of the operator's own login shell.
  operator_sees_node "v${NODE_LOCKED}" 0
  vendor_direct runuser
  seed_node_prefix
}

linger_state() {
  # linger_state yes|no: what loginctl reports for the operator
  printf '%s\n' "${1}" \
    >"${FX}/loginctl/healthy/$(vkey show-user "${OPUSER}" --property=Linger --value).out"
}

lid_handler() {
  # lid_handler PROPERTY VALUE: what the running logind answers when busctl asks it for
  # PROPERTY, in the signature-and-value shape busctl prints a string property in.
  printf 's "%s"\n' "${2}" \
    >"${FX}/busctl/healthy/$(vkey get-property org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager "${1}").out"
}

unit_state() {
  # unit_state UNIT WORD: what systemctl is-enabled UNIT answers. A masked unit
  # exits 1, as the real systemctl does.
  printf '%s\n' "${2}" >"${FX}/systemctl/healthy/is-enabled_${1}.out"
  if [ "${2}" = masked ]; then
    printf '1\n' >"${FX}/systemctl/healthy/is-enabled_${1}.exit"
  else
    rm -f "${FX}/systemctl/healthy/is-enabled_${1}.exit"
  fi
}

operator_sees_node() {
  # operator_sees_node OUTPUT EXIT: what sh -lc 'node --version' prints for the
  # operator, which the Node.js row reports and never acts on
  local key
  key="$(vkey -u "${OPUSER}" -- sh -lc node --version)"
  printf '%s\n' "${1}" >"${FX}/runuser/healthy/${key}.out"
  printf '%s\n' "${2}" >"${FX}/runuser/healthy/${key}.exit"
}

seed_node_prefix() {
  # A runtime already at the prefix answering with the locked version, so the
  # Node.js row's install is the no-op its own inspection makes it and the row is
  # its four journaled symlinks. The install itself is proved against a fixture
  # tarball in tests/unit/lib/node.bats, which owns the pinned download.
  local n
  mkdir -p "${NODE_PREFIX}/bin"
  printf '#!/bin/sh\necho v%s\n' "${NODE_LOCKED}" >"${NODE_PREFIX}/bin/node"
  chmod 0755 "${NODE_PREFIX}/bin/node"
  for n in npm npx corepack; do
    printf '#!/bin/sh\nexit 0\n' >"${NODE_PREFIX}/bin/${n}"
    chmod 0755 "${NODE_PREFIX}/bin/${n}"
  done
}

install_form() {
  # An installed release this run is executing, with the applied harbor-install
  # entry the mismatch form requires, which is the form every row below runs in:
  # the rows run from the installed copy, never from a checkout.
  build_release "${TAG}"
  write_record "${OTHER_TAG}"
  mkdir -p "${STATE}/journal"
  chmod 0700 "${STATE}/journal"
  fixture_entry "${STATE}" 0001 harbor-install "${RELEASE_DIR}" created applied '"absent"' \
    "{\"tree_sha256\":\"$(harbor_release_tree_hash "${RELEASE_DIR}")\"}"
}

rows() {
  # The sequence, run from the installed copy with the operator this test can act
  # as. --operator is passed on every call, so an entry naming OPUSER is an entry
  # the flag reached.
  bootstrap --operator "${OPUSER}" ${1+"$@"}
}

journal_ops() {
  # Every journal entry in the order the sequence wrote them, "op target".
  local f
  for f in "${STATE}"/journal/*.json; do
    printf '%s %s\n' "$(harbor_journal_string "${f}" op)" \
      "$(harbor_journal_string "${f}" target)"
  done
}

entry_file() {
  # entry_file OP TARGET: the journal entry for that op and target, or nothing
  local f
  for f in "${STATE}"/journal/*-"${1}".json; do
    [ -e "${f}" ] || continue
    if [ "$(harbor_journal_string "${f}" target)" = "${2}" ]; then
      printf '%s' "${f}"
      return 0
    fi
  done
}

phase_of() {
  # phase_of OP TARGET: the phase of that entry, or "none" when there is none
  local f
  f="$(entry_file "${1}" "${2}")"
  if [ -z "${f}" ]; then
    printf 'none'
    return 0
  fi
  harbor_journal_string "${f}" phase
}

ownership_of() {
  local f
  f="$(entry_file "${1}" "${2}")"
  if [ -z "${f}" ]; then
    printf 'none'
    return 0
  fi
  harbor_journal_string "${f}" ownership
}

seq_of() {
  # seq_of OP TARGET: the journal sequence number of that entry
  local f
  f="$(entry_file "${1}" "${2}")"
  [ -n "${f}" ] || return 0
  f="${f##*/}"
  printf '%s' "${f%%-*}"
}

entries_owned() {
  # entries_owned OWNERSHIP: how many entries the journal holds with it
  grep -l "^  \"ownership\": \"${1}\",\$" "${STATE}"/journal/*.json 2>/dev/null \
    | wc -l | tr -d ' '
}

ufw_pre_state() {
  # ufw_pre_state STATUS DEFAULT_IN DEFAULT_OUT: the firewall this node already has
  printf '%s\n' "${1}" >"${VST}/status"
  printf '%s\n' "${2}" >"${VST}/in"
  printf '%s\n' "${3}" >"${VST}/out"
}

vendor_calls() {
  # Every vendor argv this run made, one per line, tabs turned into spaces.
  [ -e "${SHIMLOG}" ] || return 0
  tr '\t' ' ' <"${SHIMLOG}"
}

call_index() {
  # call_index ARGV: how many vendor calls preceded that exact one, so the order
  # two rows ran in can be asserted rather than assumed
  vendor_calls | grep -nxF -- "${1}" | sed -n 1p | cut -d: -f1
}

mutating_calls() {
  # Every vendor call that changes the node rather than inspecting it. The
  # inspections are named, so a call this list does not know about counts as
  # mutating: a rerun that made one would fail rather than be quietly excused.
  vendor_calls | grep -v '^dpkg-query -s ' \
    | grep -v '^getent ' \
    | grep -v '^apt-get -s install ' \
    | grep -v '^loginctl show-user ' \
    | grep -v '^systemctl is-enabled ' \
    | grep -v '^systemctl is-active ' \
    | grep -v '^busctl get-property ' \
    | grep -v '^sshd -t$' \
    | grep -v '^sshd -T -C user=' \
    | grep -v '^ufw status verbose$' \
    | grep -v '^ufw show added$' \
    | grep -v '^ip -o -4 ' \
    | grep -v '^runuser -u ' || true
}

expected_flags() {
  # expected_flags [KEY_SOURCE] [OPERATOR]: the normalized flag set of a default
  # run, in the one canonical field order lib/entrypoint.sh prints.
  printf 'operator=%s authorized-key-source=%s adopt-firewall=no adopt-tailscale=no allow-lan-ssh=no harden-sshd=no tailscale-ssh=no' \
    "${2:-${OPERATOR}}" "${1:-${KEYSRC}}"
}

bootstrap() {
  # The script under test, run as a subprocess exactly as the dispatcher sources it,
  # against fixture paths only.
  run env -u HARBOR_DEV -u HARBOR_TEST_HOOKS -u HARBOR_FAIL_AFTER \
    HARBOR_ROOT="${HARBOR_ROOT}" \
    PATH="${BIN}:${PATH}" \
    SUDO_USER="${ADMIN}" \
    HARBOR_SHIM_FIXTURES="${FX}" \
    HARBOR_SHIM_LOG="${SHIMLOG}" \
    HARBOR_TEST_VENDOR="${VENDOR_ENV}" \
    HARBOR_BOOTSTRAP_FIXTURE_ROOT="${ASSUME_ROOT}" \
    HARBOR_BOOTSTRAP_FIXTURE_OS_RELEASE="${OSREL}" \
    HARBOR_BOOTSTRAP_FIXTURE_ARCH="${ARCH}" \
    HARBOR_BOOTSTRAP_FIXTURE_STATE_ROOT="${STATE}" \
    HARBOR_BOOTSTRAP_FIXTURE_INSTALL_ROOT="${INSTALL}" \
    HARBOR_BOOTSTRAP_FIXTURE_LINK="${LINK}" \
    HARBOR_BOOTSTRAP_FIXTURE_ARGV0="${ARGV0}" \
    HARBOR_BOOTSTRAP_FIXTURE_EXEC="${EXECLOG}" \
    HARBOR_BOOTSTRAP_FIXTURE_NODE_PREFIX="${NODE_PREFIX}" \
    HARBOR_BOOTSTRAP_FIXTURE_ETC="${ETC}" \
    HARBOR_CHECKOUT_TRUSTED_USERS="root ${TEST_USER}" \
    HARBOR_ENTRYPOINT_INSTALL_ROOT="${INSTALL}" \
    HARBOR_ENTRYPOINT_TRUSTED_OWNER="${TEST_USER}" \
    HARBOR_SSH_HOME_ROOT="${HOMES}" \
    ${HOOKS:+HARBOR_TEST_HOOKS=1} ${HOOKS:+HARBOR_FAIL_AFTER="${HOOKS}"} \
    bash "${HARBOR_ROOT}/node/bootstrap.sh" ${1+"$@"}
}

# 1. /etc/os-release reports the locked release and amd64

@test "the os-release check runs first, before the root check" {
  os_release ubuntu 22.04
  ASSUME_ROOT=0
  bootstrap
  assert_equal "${status}" 3
  assert_output --partial 'bootstrap.os_release'
  assert_output --partial '22.04'
  assert_output --partial '24.04'
  assert [ ! -e "${STATE}" ]
}

@test "an os-release naming another distribution exits 3 naming it" {
  os_release debian 24.04
  bootstrap
  assert_equal "${status}" 3
  assert_output --partial 'bootstrap.os_release'
  assert_output --partial 'debian'
  assert [ ! -e "${STATE}" ]
}

@test "a missing os-release exits 3 naming the file" {
  rm "${OSREL}"
  bootstrap
  assert_equal "${status}" 3
  assert_output --partial 'bootstrap.os_release'
  assert_output --partial "${OSREL}"
}

@test "an architecture other than amd64 exits 3 naming it" {
  ARCH=arm64
  bootstrap
  assert_equal "${status}" 3
  assert_output --partial 'bootstrap.architecture'
  assert_output --partial 'arm64'
  assert [ ! -e "${STATE}" ]
}

# 2. root with a valid SUDO_USER or --authorized-key-file

@test "a caller that is not root exits 3 and creates no state root" {
  ASSUME_ROOT=0
  bootstrap
  assert_equal "${status}" 3
  assert_output --partial 'bootstrap.not_root'
  assert [ ! -e "${STATE}" ]
  assert [ ! -e "${EXECLOG}" ]
}

@test "root with neither SUDO_USER nor --authorized-key-file exits 3 naming both ways out" {
  ADMIN=""
  bootstrap
  assert_equal "${status}" 3
  assert_output --partial 'bootstrap.no_sudo_user'
  assert_output --partial '--authorized-key-file'
  assert [ ! -e "${STATE}" ]
}

@test "SUDO_USER root without --authorized-key-file exits 3" {
  ADMIN=root
  bootstrap
  assert_equal "${status}" 3
  assert_output --partial 'bootstrap.sudo_user_root'
  assert [ ! -e "${STATE}" ]
}

@test "--authorized-key-file stands in for SUDO_USER and is what the flag set records" {
  ADMIN=""
  bootstrap --authorized-key-file "${KEYSRC}"
  assert_success
  assert_equal "$(entry_raw "${STATE}" 0001 target)" "\"$(expected_flags)\""
}

# 3. the operator-name clash refusal

@test "--operator root exits 3 naming the clash" {
  bootstrap --operator root
  assert_equal "${status}" 3
  assert_output --partial 'user.operator_root'
  assert [ ! -e "${STATE}" ]
}

@test "--operator naming the invoking administrator exits 3" {
  bootstrap --operator "${ADMIN}"
  assert_equal "${status}" 3
  assert_output --partial 'user.operator_administrator'
  assert [ ! -e "${STATE}" ]
}

@test "--operator naming a sudo group member exits 3 naming the group" {
  passwd_entry sudoer /bin/bash 1005 1005
  group_entry sudo 27 "${ADMIN},sudoer"
  bootstrap --operator sudoer
  assert_equal "${status}" 3
  assert_output --partial 'user.operator_sudo_capable'
  assert_output --partial 'sudo'
  assert [ ! -e "${STATE}" ]
}

@test "the operator clash is refused before any checkout rule, so a dirty checkout is not what is named" {
  printf 'dirty\n' >>"${CHECKOUT}/lib/log.sh"
  bootstrap --operator root
  assert_equal "${status}" 3
  assert_output --partial 'user.operator_root'
  refute_output --partial 'checkout.dirty'
}

# 4. the checkout or entrypoint rules of slice 3b

@test "a checkout with uncommitted changes exits 3 and creates no state root" {
  printf 'dirty\n' >>"${CHECKOUT}/lib/log.sh"
  bootstrap
  assert_equal "${status}" 3
  assert_output --partial 'checkout.dirty'
  assert [ ! -e "${STATE}" ]
  assert [ ! -e "${INSTALL}/${TAG}" ]
}

@test "an untracked file in the checkout exits 3 naming it" {
  printf 'stray\n' >"${CHECKOUT}/lib/stray.sh"
  bootstrap
  assert_equal "${status}" 3
  assert_output --partial 'checkout.untracked'
  assert_output --partial 'stray.sh'
}

@test "a checkout that is not at a tag exits 3" {
  gitc tag -d "${TAG}"
  bootstrap
  assert_equal "${status}" 3
  assert_output --partial 'checkout.no_tag'
  assert [ ! -e "${STATE}" ]
}

@test "a group-writable path in the checkout exits 3 naming it" {
  chmod 0775 "${CHECKOUT}/lib"
  bootstrap
  assert_equal "${status}" 3
  assert_output --partial 'checkout.mode'
  assert_output --partial "${CHECKOUT}/lib"
  assert [ ! -e "${STATE}" ]
}

@test "the installed-entrypoint form applies the release rules to the executing path" {
  build_release "${TAG}"
  chmod 0775 "${RELEASE_DIR}/lib"
  bootstrap
  assert_equal "${status}" 3
  assert_output --partial 'entrypoint.mode'
  assert_output --partial "${RELEASE_DIR}/lib"
  assert [ ! -e "${STATE}" ]
}

@test "the record-less form defers only the record equality check and then owes the harbor-install proof" {
  build_release "${TAG}"
  bootstrap
  assert_equal "${status}" 3
  assert_output --partial 'entrypoint.install_proof'
  assert_output --partial "${RELEASE_DIR}"
  assert [ ! -e "${EXECLOG}" ]
}

@test "the installed-entrypoint form with the proof continues without staging or exec'ing" {
  install_form
  rows
  assert_success
  assert [ ! -e "${EXECLOG}" ]
  assert_equal "$(readlink "${LINK}")" "${RELEASE_DIR}/bin/harbor"
  assert_equal "$(entry_phase "${STATE}" 0002)" applied
}

# 5 and 6. the state root, then the lock

@test "the state root is created 0755 when absent and the lock is released before the exec" {
  bootstrap
  assert_success
  run ls -ld "${STATE}"
  assert_output --regexp '^drwxr-xr-x'
  assert [ ! -e "${STATE}/lock.d" ]
  assert [ ! -e "${STATE}/reclaim.d" ]
  assert [ -f "${EXECLOG}" ]
}

@test "a lock.d whose holder record does not parse exits 3 and installs nothing" {
  mkdir -p "${STATE}/lock.d"
  printf 'not a holder record\n' >"${STATE}/lock.d/holder"
  bootstrap
  assert_equal "${status}" 3
  assert_output --partial 'lock.unreadable'
  assert [ ! -e "${INSTALL}/${TAG}" ]
  assert [ ! -e "${STATE}/journal" ]
}

# 7. journal/ exists or bootstrap.json is absent too

@test "a state root holding bootstrap.json but no journal exits 3 naming the lost journal" {
  write_record "${TAG}"
  bootstrap
  assert_equal "${status}" 3
  assert_output --partial 'bootstrap.lost_journal'
  assert_output --partial "${STATE}/journal"
  assert [ ! -e "${INSTALL}/${TAG}" ]
}

# 8. recovery clean

@test "an undecidable prepared entry exits 2 before anything is installed" {
  mkdir -p "${STATE}/journal"
  chmod 0700 "${STATE}/journal"
  fixture_undecidable_file_entry "${STATE}" 0001
  bootstrap
  assert_equal "${status}" 2
  assert_output --partial 'journal.undecidable'
  assert [ ! -e "${INSTALL}/${TAG}" ]
  assert [ ! -e "${EXECLOG}" ]
}

# 9. the flag binding

@test "the first run records the flag set as an applied bootstrap-flags entry before any mutation" {
  bootstrap
  assert_success
  assert_equal "$(entry_phase "${STATE}" 0001)" applied
  assert_equal "$(entry_raw "${STATE}" 0001 target)" "\"$(expected_flags)\""
  assert_equal "$(entry_raw "${STATE}" 0001 ownership)" '"observed"'
  assert [ -f "${STATE}/journal/0001-bootstrap-flags.json" ]
}

@test "a later run with another flag set exits 3 printing the recorded value beside this run's" {
  bootstrap
  assert_success
  rm -f "${EXECLOG}"
  bootstrap --harden-sshd
  assert_equal "${status}" 3
  assert_output --partial 'flags.mismatch'
  assert_output --partial '--harden-sshd: this run yes, recorded no'
  assert [ ! -e "${EXECLOG}" ]
}

@test "a later run with the equal flag set writes no second bootstrap-flags entry and restages nothing" {
  bootstrap
  assert_success
  local hash
  hash="$(harbor_release_tree_hash "${INSTALL}/${TAG}")"
  bootstrap
  assert_success
  assert [ ! -e "${STATE}/journal/0004-bootstrap-flags.json" ]
  assert_equal "$(harbor_release_tree_hash "${INSTALL}/${TAG}")" "${hash}"
  assert_equal "$(entry_raw "${STATE}" 0002 target)" "\"${INSTALL}/${TAG}\""
}

# 10. the entrypoint symlink

@test "a foreign file at the entrypoint link exits 3 naming it for manual removal" {
  printf 'not harbor\n' >"${LINK}"
  bootstrap
  assert_equal "${status}" 3
  assert_output --partial 'bootstrap.link_foreign'
  assert_output --partial "${LINK}"
  assert [ ! -e "${INSTALL}/${TAG}" ]
}

@test "a symlink at the entrypoint link pointing outside the install root exits 3 naming it" {
  ln -s "${CHECKOUT}/bin/harbor" "${LINK}"
  bootstrap
  assert_equal "${status}" 3
  assert_output --partial 'bootstrap.link_foreign'
  assert_output --partial "${CHECKOUT}/bin/harbor"
  assert [ ! -e "${INSTALL}/${TAG}" ]
}

# The install step, the release of the lock, and the exec

@test "the install step stages the tag, journals it applied, and points the link at it" {
  bootstrap
  assert_success
  assert [ -f "${INSTALL}/${TAG}/bin/harbor" ]
  assert [ -f "${INSTALL}/${TAG}/RELEASE" ]
  assert_equal "$(sed -n 's/^tag=//p' "${INSTALL}/${TAG}/RELEASE")" "${TAG}"
  assert_equal "$(entry_phase "${STATE}" 0002)" applied
  assert_equal "$(entry_raw "${STATE}" 0002 target)" "\"${INSTALL}/${TAG}\""
  assert_equal "$(entry_phase "${STATE}" 0003)" applied
  assert_equal "$(readlink "${LINK}")" "${INSTALL}/${TAG}/bin/harbor"
}

@test "the exec passes the original arguments through unchanged after the lock is released" {
  bootstrap --operator "${OPERATOR}" --tailscale-ssh --authorized-key-file "${KEYSRC}"
  assert_success
  run cat "${EXECLOG}"
  assert_line --index 0 "${LINK}"
  assert_line --index 1 'bootstrap'
  assert_line --index 2 '--operator'
  assert_line --index 3 "${OPERATOR}"
  assert_line --index 4 '--tailscale-ssh'
  assert_line --index 5 '--authorized-key-file'
  assert_line --index 6 "${KEYSRC}"
  assert [ ! -e "${STATE}/lock.d" ]
}

@test "an authorized-key path carrying a space is refused rather than recorded ambiguously" {
  mkdir -p "${HOMES}/${ADMIN}/keys dir"
  cp "${KEYSRC}" "${HOMES}/${ADMIN}/keys dir/authorized_keys"
  bootstrap --authorized-key-file "${HOMES}/${ADMIN}/keys dir/authorized_keys"
  assert_equal "${status}" 3
  assert_output --partial 'flags.whitespace'
}

# Step boundaries

@test "HARBOR_FAIL_AFTER cuts between the intent entry and the install step" {
  HOOKS=bootstrap-flags
  bootstrap
  assert [ "${status}" -ne 0 ]
  assert_equal "$(entry_phase "${STATE}" 0001)" applied
  assert [ ! -e "${INSTALL}/${TAG}" ]
  assert [ ! -e "${EXECLOG}" ]
}

# Usage

@test "an unknown flag exits 3 with the usage line" {
  bootstrap --nope
  assert_equal "${status}" 3
  assert_output --partial 'bootstrap.usage'
  assert_output --partial '--nope'
  assert [ ! -e "${STATE}" ]
}

@test "a flag whose value is missing exits 3 naming it" {
  bootstrap --operator
  assert_equal "${status}" 3
  assert_output --partial 'bootstrap.usage'
  assert_output --partial '--operator'
  assert [ ! -e "${STATE}" ]
}

# The remaining rows of the design section 5.2 table, in the table's order

expected_rows() {
  # Every journal entry a first run of the sequence writes, in the order the table
  # puts the rows in and the order each library journals within its row. The list
  # is written out here rather than derived, so a reordering of the sequence is a
  # failure and never a silently different node.
  local pkg unit name
  printf '%s\n' "harbor-install ${RELEASE_DIR}"
  printf '%s\n' "bootstrap-flags $(expected_flags "${KEYSRC}" "${OPUSER}")"
  printf '%s\n' "file ${LINK}"
  for pkg in ${PACKAGES}; do
    printf '%s\n' "package ${pkg}"
  done
  printf '%s\n' "user ${OPUSER}"
  for name in node npm npx corepack; do
    printf '%s\n' "file ${BINDIR}/${name}"
  done
  printf '%s\n' "authorized-key-source ${KEYSRC}"
  printf '%s\n' "authorized-key ${HOMES}/${OPUSER}/.ssh/authorized_keys"
  printf '%s\n' "file ${DROPIN}"
  printf '%s\n' "ufw-rule ${RULE}"
  printf '%s\n' 'ufw-default incoming'
  printf '%s\n' 'ufw-default outgoing'
  printf '%s\n' "file ${LOGIND}"
  for unit in ${TARGETS}; do
    printf '%s\n' "systemd-mask ${unit}"
  done
  printf '%s\n' "linger ${OPUSER}"
  printf '%s\n' "file ${STATE}/bootstrap.json"
}

@test "the rows run in the table's order, each as its own journaled transaction" {
  install_form
  rows
  assert_success
  run journal_ops
  assert_output "$(expected_rows)"
}

@test "every row of a first run reaches applied" {
  install_form
  rows
  assert_success
  local line
  while IFS= read -r line; do
    assert_equal "$(phase_of "${line%% *}" "${line#* }")" applied
  done <<<"$(expected_rows)"
}

@test "the packages row installs the six packages of the table in one apt-get invocation" {
  install_form
  rows
  assert_success
  run vendor_calls
  assert_line "apt-get -s install ${PACKAGES}"
  assert_line "apt-get install -y ${PACKAGES}"
  assert_equal "$(ownership_of package git)" created
}

@test "the operator user row creates exactly the account --operator names, with no extra group" {
  install_form
  rows
  assert_success
  run vendor_calls
  assert_line "useradd --create-home --shell /bin/bash ${OPUSER}"
  refute_output --partial 'usermod'
  refute_output --partial '--groups'
  assert_equal "$(ownership_of user "${OPUSER}")" created
}

@test "the Node.js row links the runtime into the bin directory beside the entrypoint" {
  install_form
  rows
  assert_success
  local name
  for name in node npm npx corepack; do
    assert_equal "$(readlink "${BINDIR}/${name}")" "${NODE_PREFIX}/bin/${name}"
    assert_equal "$(phase_of file "${BINDIR}/${name}")" applied
  done
  assert_output --partial "sh -lc 'node --version' as ${OPUSER} prints v${NODE_LOCKED}"
}

@test "the authorized key row copies the key by path and records it by hash, never printing it" {
  install_form
  rows
  assert_success
  # No key material reaches a message, a log line, or any command line.
  refute_output --partial 'AAAAC3NzaC1lZDI1NTE5'
  local target
  target="${HOMES}/${OPUSER}/.ssh/authorized_keys"
  assert_equal "$(cat "${target}")" "$(cat "${KEYSRC}")"
  assert_equal "$(harbor_stat_mode "${target}")" 0600
  run cat "$(entry_file authorized-key "${target}")"
  assert_output --partial "$(harbor_sha256 "${KEYSRC}")"
  refute_output --partial 'AAAAC3NzaC1lZDI1NTE5'
  run cat "${STATE}/bootstrap.log"
  refute_output --partial 'AAAAC3NzaC1lZDI1NTE5'
  run vendor_calls
  refute_output --partial 'AAAAC3NzaC1lZDI1NTE5'
}

@test "the sshd row writes the operator drop-in under the configuration root and reloads" {
  install_form
  rows
  assert_success
  assert [ -f "${DROPIN}" ]
  run cat "${DROPIN}"
  assert_line "Match User ${OPUSER}"
  assert_line '  PasswordAuthentication no'
  assert [ ! -e "${GLOBAL_DROPIN}" ]
  run vendor_calls
  assert_line 'sshd -t'
  assert_line "sshd -T -C user=${OPUSER}"
  assert_line "sshd -T -C user=${ADMIN}"
  assert_line 'systemctl reload ssh.service'
}

@test "the firewall row runs after the sshd assertions and adds only the tailscale0 rule" {
  install_form
  rows
  assert_success
  run vendor_calls
  assert_line "ufw ${RULE}"
  assert_line 'ufw default deny incoming'
  assert_line 'ufw --force enable'
  # Design section 6.2: the rule that keeps the node reachable is in place before
  # anything starts filtering, and the drop-in is proved before either.
  local rule_at enable_at sshd_at
  rule_at="$(call_index "ufw ${RULE}")"
  enable_at="$(call_index 'ufw --force enable')"
  sshd_at="$(call_index 'sshd -t')"
  assert [ "${sshd_at}" -lt "${rule_at}" ]
  assert [ "${rule_at}" -lt "${enable_at}" ]
  # No rule names a physical interface (design section 3.4).
  refute_output --partial 'on eth0'
}

@test "the power row writes the lid drop-in and masks the four sleep targets" {
  install_form
  rows
  assert_success
  run cat "${LOGIND}"
  assert_line 'HandleLidSwitch=ignore'
  assert_line 'HandleLidSwitchDocked=ignore'
  local unit
  run vendor_calls
  for unit in ${TARGETS}; do
    assert_line "systemctl mask ${unit}"
  done
  assert_line 'systemctl restart systemd-logind.service'
}

@test "the linger row is the last row before the state record" {
  install_form
  rows
  assert_success
  run vendor_calls
  assert_line "loginctl enable-linger ${OPUSER}"
  assert_equal "$(ownership_of linger "${OPUSER}")" created
}

@test "the Tailscale rows are not applied by this release, and the record says so" {
  install_form
  rows
  assert_success
  # No entry of a tailscale-install, tailscale-operator, or tailscale-serve op, and
  # no tailscale command at all: the flag set names the two Tailscale flags because
  # it records the run's whole intent, and that is the only tailscale text here.
  run journal_ops
  refute_line --regexp '^tailscale'
  run vendor_calls
  refute_line --regexp '^tailscale '
  # This release installs no Tailscale and adopts none, so the ownership the record can
  # honestly name is pre-existing and there is no version to name beside it. Slice 3d is
  # what makes harbor-installed and adopted reachable and what adds the version key.
  run cat "${STATE}/bootstrap.json"
  assert_line '  "tailscale_ownership": "pre-existing",'
  refute_output --partial 'tailscale_version'
}

# The state record, the last row of the design section 5.2 table

@test "the state record is written last, mode 0644, carrying what the rows above proved" {
  install_form
  rows
  assert_success
  local record lock_sha flags rec_seq linger_seq
  record="${STATE}/bootstrap.json"
  lock_sha="$(harbor_sha256 "${HARBOR_ROOT}/versions.lock")"
  flags="$(expected_flags "${KEYSRC}" "${OPUSER}")"
  assert_equal "$(harbor_stat_mode "${record}")" 0644
  # Written last: its entry is the journal's newest, after the linger row's.
  rec_seq="$(seq_of file "${record}")"
  linger_seq="$(seq_of linger "${OPUSER}")"
  assert [ "$((10#${rec_seq}))" -gt "$((10#${linger_seq}))" ]
  assert_equal "$(phase_of file "${record}")" applied
  # Every value is the one the row that owns it proved: the tag of the executing release,
  # the absolute entrypoint, the hash of the lock the preflight loaded, the intent the
  # flag binding recorded, the locked Node.js version, and the account the operator-user
  # row created, uid, gid, and home as the name service now lists them.
  run cat "${record}"
  assert_line --index 0 '{'
  assert_line --index 1 "  \"release_tag\": \"${TAG}\","
  assert_line --index 2 "  \"entrypoint\": \"${LINK}\","
  assert_line --index 3 "  \"lock_sha256\": \"${lock_sha}\","
  assert_line --index 4 "  \"flags\": \"${flags}\","
  assert_line --index 5 "  \"nodejs_version\": \"${NODE_LOCKED}\","
  assert_line --index 6 '  "tailscale_ownership": "pre-existing",'
  assert_line --index 7 "  \"operator\": \"${OPUSER}\","
  assert_line --index 8 '  "operator_uid": 4242,'
  assert_line --index 9 '  "operator_gid": 4242,'
  assert_line --index 10 "  \"operator_home\": \"${HOMES}/${OPUSER}\","
  assert_line --index 11 --regexp '^  "timestamp": "[0-9]{8}T[0-9]{6}Z"$'
  assert_line --index 12 '}'
  assert_equal "${#lines[@]}" 13
  # Non-secret: no key material and no holder identity reach it.
  refute_output --partial 'AAAAC3NzaC1lZDI1NTE5'
}

@test "the record the run writes ends the mismatch form and is read back by the entrypoint check" {
  # install_form seeds a record naming another tag, which is the mismatch form of design
  # section 5.2; the last row is what ends it by rewriting the record to the executing
  # release, and lib/entrypoint.sh's own reader is what has to be able to read it.
  install_form
  assert_equal "$(harbor_entrypoint_record_tag "${STATE}/bootstrap.json")" "${OTHER_TAG}"
  rows
  assert_success
  assert_equal "$(harbor_entrypoint_record_tag "${STATE}/bootstrap.json")" "${TAG}"
  assert_equal "$(ownership_of file "${STATE}/bootstrap.json")" modified
}

@test "the state root, its journal, and the log keep the modes of the design section 5.2 contract" {
  install_form
  rows
  assert_success
  # 0755 with a 0644 record, so the operator can stat the lock, read its holder, and read
  # the record; the journal and the log stay root-only.
  assert_equal "$(harbor_stat_mode "${STATE}")" 0755
  assert_equal "$(harbor_stat_mode "${STATE}/bootstrap.json")" 0644
  assert_equal "$(harbor_stat_mode "${STATE}/journal")" 0700
  assert_equal "$(harbor_stat_mode "${STATE}/bootstrap.log")" 0600
  # The lock and its gate are released, so neither is left behind for the next command.
  assert [ ! -e "${STATE}/lock.d" ]
  assert [ ! -e "${STATE}/reclaim.d" ]
}

@test "bootstrap prints the operator's next command and switches no user to do it" {
  install_form
  rows
  assert_success
  assert_output --partial "next, as ${OPUSER} over SSH: harbor provision"
  local switches
  # The one runuser of the whole sequence is the report-only Node.js probe of the design
  # section 5.2 Node.js row. Bootstrap starts no shell as the operator and no login of any
  # kind: it prints the command and exits (design section 5.2).
  switches="$(vendor_calls | grep -c '^runuser ' || true)"
  assert_equal "${switches}" 1
  run vendor_calls
  assert_line "runuser -u ${OPUSER} -- sh -lc node --version"
  refute_line --regexp '^(su|login|sudo|machinectl) '
}

@test "HARBOR_FAIL_AFTER cuts the record row between the rename and the applied write" {
  install_form
  HOOKS=state-record
  rows
  assert [ "${status}" -ne 0 ]
  # The rename is atomic, so what the cut leaves is the whole new record and an entry the
  # next run's recovery can decide against it, never half a record.
  assert_equal "$(phase_of file "${STATE}/bootstrap.json")" prepared
  assert_equal "$(harbor_entrypoint_record_tag "${STATE}/bootstrap.json")" "${TAG}"
  run cat "${STATE}/bootstrap.json"
  assert_equal "${#lines[@]}" 13
  assert_equal "$(harbor_stat_mode "${STATE}/bootstrap.json")" 0644
  # And the rerun decides that entry and converges without rewriting the record.
  local before
  before="$(harbor_sha256 "${STATE}/bootstrap.json")"
  HOOKS=""
  rows
  assert_success
  assert_equal "$(phase_of file "${STATE}/bootstrap.json")" applied
  assert_equal "$(harbor_sha256 "${STATE}/bootstrap.json")" "${before}"
}

# Every flag of the bound set reaches the row it belongs to

@test "--operator reaches the user, Node.js probe, authorized key, sshd, and linger rows" {
  install_form
  rows
  assert_success
  assert_equal "$(phase_of user "${OPUSER}")" applied
  assert_equal "$(phase_of authorized-key "${HOMES}/${OPUSER}/.ssh/authorized_keys")" applied
  assert_equal "$(phase_of linger "${OPUSER}")" applied
  run cat "${DROPIN}"
  assert_line "Match User ${OPUSER}"
  # The script's own default operator was reached by no row at all.
  assert [ ! -e "${HOMES}/${OPERATOR}" ]
  assert_equal "$(phase_of user "${OPERATOR}")" none
}

@test "--authorized-key-file reaches the authorized key row as the source it records" {
  install_form
  local alt="${FIX_BASE}/given-authorized-keys"
  printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5 given\n' >"${alt}"
  rows --authorized-key-file "${alt}"
  assert_success
  assert_equal "$(phase_of authorized-key-source "${alt}")" applied
  assert_equal "$(phase_of authorized-key-source "${KEYSRC}")" none
  assert_equal "$(cat "${HOMES}/${OPUSER}/.ssh/authorized_keys")" "$(cat "${alt}")"
}

@test "--harden-sshd reaches the sshd row as a drop-in and a journal entry of its own" {
  install_form
  rows --harden-sshd
  assert_success
  assert [ -f "${GLOBAL_DROPIN}" ]
  assert_equal "$(phase_of file "${GLOBAL_DROPIN}")" applied
  run cat "${GLOBAL_DROPIN}"
  assert_line 'PermitRootLogin no'
}

@test "--harden-sshd refuses when the installation user has no key of their own" {
  install_form
  rm "${KEYSRC}"
  rows --harden-sshd --authorized-key-file "${CHECKOUT}/bin/harbor"
  assert_equal "${status}" 3
  assert_output --partial 'ssh.harden_no_key'
  assert [ ! -e "${GLOBAL_DROPIN}" ]
}

@test "--adopt-firewall reaches the firewall row and journals the prior default" {
  install_form
  ufw_pre_state active allow allow
  rows --adopt-firewall
  assert_success
  assert_equal "$(ownership_of ufw-default incoming)" modified
  assert_equal "$(entry_raw "${STATE}" "$(seq_of ufw-default incoming)" pre_state)" '"allow"'
  run vendor_calls
  assert_line 'ufw default deny incoming'
}

@test "an already active firewall without --adopt-firewall is journaled observed and left alone" {
  install_form
  ufw_pre_state active allow allow
  rows
  assert_success
  assert_equal "$(ownership_of ufw-default incoming)" observed
  run vendor_calls
  refute_output --partial 'ufw default deny incoming'
  refute_output --partial 'ufw --force enable'
}

@test "--allow-lan-ssh reaches the firewall row and is a degraded status warning" {
  install_form
  rows --allow-lan-ssh
  assert_equal "${status}" 1
  assert_output --partial 'firewall.lan_ssh'
  assert_output --partial '192.168.1.0/24'
  assert_equal "$(phase_of ufw-rule "${LAN_RULE}")" applied
  # Degraded, so every row after the firewall still ran and the record was written before
  # the exit 1 (design section 6.2): a degraded node is a bootstrapped one.
  assert_equal "$(phase_of linger "${OPUSER}")" applied
  assert_equal "$(phase_of file "${STATE}/bootstrap.json")" applied
  assert_output --partial "next, as ${OPUSER} over SSH: harbor provision"
}

@test "--tailscale-ssh and --adopt-tailscale are bound and consume no row here" {
  install_form
  rows --tailscale-ssh --adopt-tailscale
  assert_success
  assert_equal "$(entry_raw "${STATE}" 0002 target)" \
    "\"$(printf 'operator=%s authorized-key-source=%s adopt-firewall=no adopt-tailscale=yes allow-lan-ssh=no harden-sshd=no tailscale-ssh=yes' "${OPUSER}" "${KEYSRC}")\""
  run journal_ops
  refute_line --regexp '^tailscale'
  run vendor_calls
  refute_line --regexp '^tailscale '
}

# Step boundaries: HARBOR_FAIL_AFTER cuts each row between its mutation and its
# applied write, and every row after it is untouched

@test "HARBOR_FAIL_AFTER cuts the packages row between apt-get and the applied write" {
  install_form
  HOOKS=apt-install
  rows
  assert [ "${status}" -ne 0 ]
  assert_equal "$(phase_of package git)" prepared
  assert_equal "$(phase_of user "${OPUSER}")" none
}

@test "HARBOR_FAIL_AFTER cuts the operator user row between useradd and the applied write" {
  install_form
  HOOKS=user-created
  rows
  assert [ "${status}" -ne 0 ]
  assert_equal "$(phase_of package git)" applied
  assert_equal "$(phase_of user "${OPUSER}")" prepared
  assert [ ! -e "${BINDIR}/node" ]
}

@test "HARBOR_FAIL_AFTER cuts the Node.js row before the link it prepared" {
  install_form
  HOOKS=node-link-node
  rows
  assert [ "${status}" -ne 0 ]
  assert_equal "$(phase_of user "${OPUSER}")" applied
  assert_equal "$(phase_of file "${BINDIR}/node")" prepared
  assert [ ! -e "${HOMES}/${OPUSER}/.ssh/authorized_keys" ]
}

@test "HARBOR_FAIL_AFTER cuts the authorized key row between the copy and the applied write" {
  install_form
  HOOKS=ssh-key-copied
  rows
  assert [ "${status}" -ne 0 ]
  assert_equal "$(phase_of authorized-key "${HOMES}/${OPUSER}/.ssh/authorized_keys")" prepared
  assert [ -f "${HOMES}/${OPUSER}/.ssh/authorized_keys" ]
  assert [ ! -e "${DROPIN}" ]
}

@test "HARBOR_FAIL_AFTER cuts the sshd row between the drop-in and the applied write" {
  install_form
  HOOKS=ssh-dropin-operator
  rows
  assert [ "${status}" -ne 0 ]
  assert_equal "$(phase_of file "${DROPIN}")" prepared
  assert [ -f "${DROPIN}" ]
  run vendor_calls
  refute_output --partial 'ufw --force enable'
}

@test "HARBOR_FAIL_AFTER cuts the firewall row between the enable and the applied write" {
  install_form
  HOOKS=firewall-enable
  rows
  assert [ "${status}" -ne 0 ]
  assert_equal "$(phase_of ufw-rule "${RULE}")" prepared
  assert_equal "$(phase_of ufw-default incoming)" prepared
  assert [ ! -e "${LOGIND}" ]
}

@test "HARBOR_FAIL_AFTER cuts the power row between the drop-in and the applied write" {
  install_form
  HOOKS=power-lid
  rows
  assert [ "${status}" -ne 0 ]
  assert_equal "$(phase_of file "${LOGIND}")" prepared
  assert [ -f "${LOGIND}" ]
  run vendor_calls
  refute_output --partial 'systemctl mask'
  refute_output --partial 'loginctl enable-linger'
}

@test "HARBOR_FAIL_AFTER cuts the linger row between loginctl and the applied write" {
  install_form
  HOOKS=linger-enabled
  rows
  assert [ "${status}" -ne 0 ]
  assert_equal "$(phase_of file "${LOGIND}")" applied
  assert_equal "$(phase_of linger "${OPUSER}")" prepared
  # A cut before the record row leaves the record whole as it was, still naming the tag
  # the mismatch form found there, and journals nothing for it.
  assert_equal "$(harbor_entrypoint_record_tag "${STATE}/bootstrap.json")" "${OTHER_TAG}"
  assert_equal "$(phase_of file "${STATE}/bootstrap.json")" none
}

# A rerun of a fully bootstrapped node

@test "a rerun of a fully bootstrapped node makes no mutating vendor call at all" {
  install_form
  rows
  assert_success
  local created modified
  created="$(entries_owned created)"
  modified="$(entries_owned modified)"
  : >"${SHIMLOG}"
  rows
  assert_success
  run mutating_calls
  assert_output ''
  assert_equal "$(entries_owned created)" "${created}"
  assert_equal "$(entries_owned modified)" "${modified}"
}

@test "a rerun leaves every artifact the first run wrote byte for byte" {
  install_form
  rows
  assert_success
  local before
  before="$(harbor_sha256 "${DROPIN}")$(harbor_sha256 "${LOGIND}")$(harbor_sha256 "${STATE}/bootstrap.json")"
  rows
  assert_success
  # The record's timestamp is what a rerun would most easily churn, and it does not: a
  # record that is already what would be written is journaled observed and left alone.
  assert_equal "$(harbor_sha256 "${DROPIN}")$(harbor_sha256 "${LOGIND}")$(harbor_sha256 "${STATE}/bootstrap.json")" "${before}"
}

# Degraded rows do not stop the rows after them (design sections 5.2 and 6.2)

@test "a Node.js the operator's shell does not see is degraded and stops nothing" {
  install_form
  operator_sees_node 'v18.0.0' 0
  rows
  assert_equal "${status}" 1
  assert_output --partial 'node.operator_probe'
  assert_output --partial 'root will not reinstall'
  assert_equal "$(phase_of linger "${OPUSER}")" applied
  # Root reinstalls nothing and alters nothing: the runtime is still the locked one.
  assert_equal "$("${NODE_PREFIX}/bin/node" --version)" "v${NODE_LOCKED}"
}

@test "a broken row is fatal and leaves its entry prepared with every later row untouched" {
  install_form
  printf 'ERROR: fixture failure\n' >"${FX}/loginctl/healthy/$(vkey enable-linger "${OPUSER}").out"
  printf '1\n' >"${FX}/loginctl/healthy/$(vkey enable-linger "${OPUSER}").exit"
  rows
  assert_equal "${status}" 2
  assert_output --partial 'user.linger'
  assert_output --partial 'stays prepared'
  assert_equal "$(phase_of linger "${OPUSER}")" prepared
}
