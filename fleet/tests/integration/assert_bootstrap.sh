#!/bin/bash
# Assert what the first real bootstrap did, at the real paths, on the ephemeral
# runner. One check per line of the design section 5.2 row table plus the design
# section 7 test map, every one of them explicit: this lane cannot be run locally,
# so it is written to fail loudly rather than to pass quietly. Failures are
# collected and the script exits 1 at the end with the count, so one run reports
# every problem rather than only the first.
#
# Runs as root (sudo bash assert_bootstrap.sh), because it reads /var/lib/harbor,
# runs sshd -T, busctl, and runuser, and asks the operator's own user manager
# whether it is up. It passes no test hook and needs none.
set -euo pipefail

# shellcheck source=lib/common.sh
. "$(cd "$(dirname "${0}")" && pwd -P)/lib/common.sh"

[ "$(id -u)" = 0 ] || {
  printf 'assert_bootstrap.sh must run as root\n' >&2
  exit 1
}

scenario="$(cat "${IT_SCENARIO_FILE}")"
tag="$(it_release_tag)"
release="${IT_INSTALL_ROOT}/${tag}"
tailscale_version="$(it_lock tailscale_version)"
nodejs_version="$(it_lock nodejs_version)"
channel="$(it_lock tailscale_apt_channel)"
track="${channel%/*}"
codename="${channel##*/}"

section() {
  printf '\n-- %s\n' "${*}"
}

# ---------------------------------------------------------------------------
section 'install: the release, its modes, and the entrypoint symlink'
# ---------------------------------------------------------------------------
it_dir 'release directory' 0755 root root "${release}"
it_file 'installed entrypoint' 0755 root root "${release}/bin/harbor"
it_file 'a library in the release' 0644 root root "${release}/lib/log.sh"
it_file 'the release marker' 0644 root root "${release}/RELEASE"
it_contains 'RELEASE names the tag' "tag=${tag}" "$(cat "${release}/RELEASE")"
it_eq 'the release carries the lock under test' \
  "$(sha256sum "${IT_FLEET}/versions.lock" | cut -d ' ' -f 1)" \
  "$(sha256sum "${release}/versions.lock" | cut -d ' ' -f 1)"
it_symlink 'entrypoint symlink' "${release}/bin/harbor" "${IT_LINK}"

# Nothing in the installed tree may be group- or other-writable, whatever modes
# the archived tag carried.
loose="$(find "${release}" -perm /0022 -print)"
it_eq 'no group- or other-writable path in the release' '' "${loose}"

# ---------------------------------------------------------------------------
section 're-exec: the rows ran from the installed copy, not from the checkout'
# ---------------------------------------------------------------------------
log="$(cat "${IT_HARBOR_LOG}")"
it_file 'the bootstrap log' 0600 root root "${IT_HARBOR_LOG}"
it_contains 're-exec of the installed entrypoint' \
  "exec ${IT_LINK} bootstrap" "${log}"
it_contains 'the checkout rules approved the tag' \
  "the checkout rules approved " "${log}"
it_contains 'the approved tree was the tag' " at ${tag} in " "${log}"

# ---------------------------------------------------------------------------
section 'operator user'
# ---------------------------------------------------------------------------
passwd_line="$(getent passwd "${IT_OPERATOR}")"
it_eq 'operator login shell' /bin/bash "$(printf '%s' "${passwd_line}" | cut -d: -f7)"
operator_home="$(printf '%s' "${passwd_line}" | cut -d: -f6)"
operator_uid="$(printf '%s' "${passwd_line}" | cut -d: -f3)"
it_eq 'operator home path' "/home/${IT_OPERATOR}" "${operator_home}"
if [ -d "${operator_home}" ]; then
  it_eq 'operator home owner' "${IT_OPERATOR}" "$(stat -c '%U' "${operator_home}")"
else
  it_fail "operator home ${operator_home} is not a directory"
fi
it_lacks 'the operator is in no sudo group' ' sudo ' " $(id -nG "${IT_OPERATOR}") "

# ---------------------------------------------------------------------------
section 'authorized key: copied from the installation user, never generated'
# ---------------------------------------------------------------------------
it_dir 'operator .ssh' 0700 "${IT_OPERATOR}" "${IT_OPERATOR}" "${operator_home}/.ssh"
it_file 'operator authorized_keys' 0600 "${IT_OPERATOR}" "${IT_OPERATOR}" \
  "${operator_home}/.ssh/authorized_keys"
it_eq 'the operator key is byte for byte the copied administrator key' \
  "$(cat "${IT_STATE}/authorized-key.sha256")" \
  "$(sha256sum "${operator_home}/.ssh/authorized_keys" | cut -d ' ' -f 1)"

# ---------------------------------------------------------------------------
section 'sshd drop-in, its syntax check, and both sshd -T assertions'
# ---------------------------------------------------------------------------
dropin=/etc/ssh/sshd_config.d/50-harbor-operator.conf
it_file 'operator drop-in' 0644 root root "${dropin}"
expected_dropin="$(
  printf '# Managed by Harbor: public-key-only authentication for one account.\n'
  printf '# It is scoped to that account and adds no keyword that decides who may log in.\n'
  printf '# Remove this file and reload ssh.service to restore the system default for it.\n'
  printf 'Match User %s\n' "${IT_OPERATOR}"
  printf '  PubkeyAuthentication yes\n'
  printf '  PasswordAuthentication no\n'
  printf '  KbdInteractiveAuthentication no\n'
)"
it_eq 'operator drop-in content' "${expected_dropin}" "$(cat "${dropin}")"
it_file_absent 'no global hardening drop-in without --harden-sshd' \
  /etc/ssh/sshd_config.d/51-harbor-global.conf

rc=0
sshd_t="$(/usr/sbin/sshd -t 2>&1)" || rc="$?"
it_eq 'sshd -t accepts the configuration' 0 "${rc}"
[ "${rc}" = 0 ] || printf 'sshd -t said: %s\n' "${sshd_t}" >&2

# Assertion one: sshd itself says the operator is public-key only.
operator_effective="$(/usr/sbin/sshd -T -C "user=${IT_OPERATOR}" | LC_ALL=C sort)"
for pair in pubkeyauthentication=yes passwordauthentication=no \
  kbdinteractiveauthentication=no strictmodes=yes; do
  directive="${pair%%=*}"
  expected="${pair#*=}"
  if grep -qxF -- "${directive} ${expected}" <<<"${operator_effective}"; then
    it_pass "sshd -T -C user=${IT_OPERATOR} reports ${directive} ${expected}"
  else
    it_fail "sshd -T -C user=${IT_OPERATOR} does not report ${directive} ${expected}"
  fi
done

# Assertion two: sshd itself says the installation user is untouched, directive
# for directive, which is the design section 7 "Operator-scoped SSH" row.
admin_effective="$(/usr/sbin/sshd -T -C "user=${IT_ADMIN}" | LC_ALL=C sort)"
if [ "${admin_effective}" = "$(cat "${IT_BASELINE}/sshd-admin.txt")" ]; then
  it_pass "sshd -T -C user=${IT_ADMIN} is unchanged by bootstrap"
else
  it_fail "sshd -T -C user=${IT_ADMIN} changed after bootstrap"
  printf '%s\n' "${admin_effective}" >"${IT_STATE}/sshd-admin-after.txt"
  rc=0
  admin_diff="$(diff -u "${IT_BASELINE}/sshd-admin.txt" "${IT_STATE}/sshd-admin-after.txt")" || rc="$?"
  printf 'sshd -T diff (rc %s):\n%s\n' "${rc}" "${admin_diff}" >&2
fi

# ---------------------------------------------------------------------------
section 'power: the logind drop-in, what logind is running, and the four masks'
# ---------------------------------------------------------------------------
logind=/etc/systemd/logind.conf.d/harbor.conf
it_file 'logind drop-in' 0644 root root "${logind}"
expected_logind="$(
  printf '# Managed by Harbor: keep this node awake with the lid closed.\n'
  printf '# Remove this file and restart systemd-logind.service to restore the system default.\n'
  printf '[Login]\n'
  printf 'HandleLidSwitch=ignore\n'
  printf 'HandleLidSwitchExternalPower=ignore\n'
  printf 'HandleLidSwitchDocked=ignore\n'
)"
it_eq 'logind drop-in content' "${expected_logind}" "$(cat "${logind}")"

for property in HandleLidSwitch HandleLidSwitchExternalPower HandleLidSwitchDocked; do
  value="$(busctl get-property org.freedesktop.login1 /org/freedesktop/login1 \
    org.freedesktop.login1.Manager "${property}")"
  it_eq "the running logind reports ${property}" 's "ignore"' "${value}"
done

for unit in sleep.target suspend.target hibernate.target hybrid-sleep.target; do
  rc=0
  out="$(/usr/bin/systemctl is-enabled "${unit}" 2>&1)" || rc="$?"
  it_eq "${unit} is masked" masked "$(sed -n 1p <<<"${out}")"
done

# ---------------------------------------------------------------------------
section "firewall: the rendered rule set for the ${scenario} pre-state"
# ---------------------------------------------------------------------------
harbor_rule="allow in on tailscale0 to any port 22 proto tcp comment harbor"
rules="$(cat "${IT_STATE}/ufw.rules")"
case "${scenario}" in
  ufw-inactive)
    it_eq 'rendered rule set' "${harbor_rule}" "${rules}"
    it_eq 'ufw is now active' yes "$(cat "${IT_STATE}/ufw.active")"
    it_eq 'default incoming' deny "$(cat "${IT_STATE}/ufw.default.incoming")"
    it_eq 'default outgoing' allow "$(cat "${IT_STATE}/ufw.default.outgoing")"
    it_ne 'Harbor set the defaults on an inactive firewall' 0 "$(it_mutations ufw)"
    ;;
  ufw-active)
    it_eq 'rendered rule set' \
      "allow 22/tcp comment pre-existing
${harbor_rule}" "${rules}"
    it_eq 'ufw was already active and stayed active' yes "$(cat "${IT_STATE}/ufw.active")"
    it_eq 'the administrator default incoming is preserved' allow \
      "$(cat "${IT_STATE}/ufw.default.incoming")"
    it_eq 'the administrator default outgoing is preserved' allow \
      "$(cat "${IT_STATE}/ufw.default.outgoing")"
    mutating_ufw="$(awk -F '\t' '$3 == "ufw" { print $4 }' "${IT_MUT_LOG}" | LC_ALL=C sort -u)"
    it_eq 'the only mutating ufw verb on a running firewall is the rule' allow "${mutating_ufw}"
    ;;
esac
# Design section 7, "No public exposure": no rule Harbor rendered names a
# physical interface. tailscale0 is the only interface any of them may name.
if grep -v ' on tailscale0 ' <<<"${rules}" | grep -q ' on '; then
  it_fail "a rendered rule names a physical interface: ${rules}"
else
  it_pass 'no rendered rule names a physical interface'
fi

# The real firewall was never touched: the wrapper is a fake precisely so that a
# hosted runner does not lose its own connectivity.
rc=0
real_ufw_out="$(/usr/sbin/ufw status 2>&1)" || rc="$?"
it_eq 'the real ufw answered' 0 "${rc}"
it_contains 'the real ufw is still inactive' 'Status: inactive' "${real_ufw_out}"

# ---------------------------------------------------------------------------
section 'linger and a real systemctl --user through runuser'
# ---------------------------------------------------------------------------
it_eq 'linger is enabled for the operator' yes \
  "$(/usr/bin/loginctl show-user "${IT_OPERATOR}" --property=Linger --value)"

runtime_dir="/run/user/${operator_uid}"
waited=0
while [ ! -d "${runtime_dir}" ] && [ "${waited}" -lt 30 ]; do
  sleep 1
  waited=$((waited + 1))
done
if [ -d "${runtime_dir}" ]; then
  it_pass "${runtime_dir} exists after ${waited}s of linger"
else
  it_fail "${runtime_dir} does not exist 30s after linger was enabled"
fi

user_state=""
waited=0
while [ "${waited}" -lt 30 ]; do
  rc=0
  user_state="$(runuser -u "${IT_OPERATOR}" -- \
    env "XDG_RUNTIME_DIR=${runtime_dir}" systemctl --user is-system-running 2>&1)" || rc="$?"
  case "${user_state}" in
    running | degraded) break ;;
  esac
  sleep 1
  waited=$((waited + 1))
done
case "${user_state}" in
  running | degraded)
    it_pass "the operator's user manager is ${user_state} after ${waited}s"
    ;;
  *)
    it_fail "the operator's user manager never came up: systemctl --user is-system-running says '${user_state}'"
    ;;
esac
rc=0
units="$(runuser -u "${IT_OPERATOR}" -- \
  env "XDG_RUNTIME_DIR=${runtime_dir}" systemctl --user list-units --no-legend 2>&1)" || rc="$?"
it_eq 'the operator can list its own user units' 0 "${rc}"
[ "${rc}" = 0 ] || printf 'systemctl --user list-units said: %s\n' "${units}" >&2

# ---------------------------------------------------------------------------
section 'the shimmed installs and their --version assertions'
# ---------------------------------------------------------------------------
it_eq 'dpkg reports the locked tailscale' "${tailscale_version}" \
  "$(dpkg-query -W -f '${Version}' tailscale)"
it_eq 'tailscale version' "${tailscale_version}" "$(/usr/bin/tailscale version)"

for name in node npm npx corepack; do
  it_symlink "${name} link" "${IT_NODE_PREFIX}/bin/${name}" "/usr/local/bin/${name}"
  it_eq "/usr/local/bin/${name} --version" "v${nodejs_version}" \
    "$(/usr/local/bin/${name} --version)"
done
it_eq "the operator's own sh -lc 'node --version'" "v${nodejs_version}" \
  "$(runuser -u "${IT_OPERATOR}" -- sh -lc 'node --version')"

# ---------------------------------------------------------------------------
section 'the Tailscale vendor source, written for real and never reached'
# ---------------------------------------------------------------------------
it_file 'vendor keyring' 0644 root root "${IT_KEYRING}"
it_eq 'the keyring is what the lane served' "$(cat "${IT_STATE}/keyring.sha256")" \
  "$(sha256sum "${IT_KEYRING}" | cut -d ' ' -f 1)"
it_file 'vendor source list' 0644 root root "${IT_TAILSCALE_LIST}"
it_eq 'vendor source line' \
  "deb [signed-by=${IT_KEYRING}] https://pkgs.tailscale.com/${track} ${codename} main" \
  "$(cat "${IT_TAILSCALE_LIST}")"
it_eq 'Harbor fetched the keyring exactly once' 1 "$(it_shim_calls curl)"
# apt never saw the vendor host: its sources are the redirected ones, so the list
# Harbor just wrote at the real vendor path is not one apt reads.
apt_policy="$(/usr/bin/apt-cache policy)"
if grep -q 'pkgs\.tailscale\.com' <<<"${apt_policy}"; then
  it_fail 'apt can see the vendor host, so the local repository redirection did not hold'
else
  it_pass 'apt cannot see the vendor host'
fi
if grep -q "file:${IT_APTREPO}" <<<"${apt_policy}"; then
  it_pass 'apt served tailscale from the local file:// repository'
else
  it_fail "apt does not list file:${IT_APTREPO} among its sources"
fi

# ---------------------------------------------------------------------------
section 'the state record'
# ---------------------------------------------------------------------------
it_file 'bootstrap.json' 0644 root root "${IT_HARBOR_RECORD}"
record="$(cat "${IT_HARBOR_RECORD}")"
it_contains 'record names the release tag' "\"release_tag\": \"${tag}\"" "${record}"
it_contains 'record names the entrypoint' "\"entrypoint\": \"${IT_LINK}\"" "${record}"
it_contains 'record names the operator' "\"operator\": \"${IT_OPERATOR}\"" "${record}"
it_contains 'record names the Node.js version' "\"nodejs_version\": \"${nodejs_version}\"" "${record}"
it_contains 'record says Harbor installed Tailscale' \
  '"tailscale_ownership": "harbor-installed"' "${record}"

# ---------------------------------------------------------------------------
section 'the journal'
# ---------------------------------------------------------------------------
it_eq 'every entry is applied' applied "$(it_journal_phases | tr '\n' ' ' | sed 's/ *$//')"
created="$(it_journal_count created)"
observed="$(it_journal_count observed)"
if [ "${created}" -gt 0 ]; then
  it_pass "the first run journalled ${created} created entries (${observed} observed)"
else
  it_fail 'the first run journalled no created entry at all'
fi

# ---------------------------------------------------------------------------
section 'no secret in any command line, log line, or journal entry'
# ---------------------------------------------------------------------------
# The throwaway key's own base64 body is the one key-shaped string this machine
# has, so its absence from everything Harbor and the lane wrote is the check.
key_body="$(awk 'NR == 1 { print $2 }' "${operator_home}/.ssh/authorized_keys")"
if [ -z "${key_body}" ]; then
  it_fail 'the authorized key has no body to look for, so this check proves nothing'
else
  for file in "${IT_HARBOR_LOG}" "${IT_SHIM_LOG}" "${IT_MUT_LOG}"; do
    if grep -qF -- "${key_body}" "${file}"; then
      it_fail "${file} carries the authorized key body"
    else
      it_pass "${file} carries no key material"
    fi
  done
  if grep -rqF -- "${key_body}" "${IT_HARBOR_JOURNAL}"; then
    it_fail 'a journal entry carries the authorized key body'
  else
    it_pass 'no journal entry carries key material'
  fi
fi
if grep -rqE 'tskey[-][A-Za-z0-9-]+' "${IT_HARBOR_STATE}" "${IT_STATE}"; then
  it_fail 'a Tailscale auth key appears somewhere this lane wrote'
else
  it_pass 'no Tailscale auth key anywhere: the lane never logs in'
fi

it_done "assert_bootstrap (${scenario})"
