#!/bin/bash
# Prepare an ephemeral ubuntu-24.04 runner for the Harbor integration lane
# (design section 7). Everything here happens BEFORE any bootstrap runs, and
# nothing here is Harbor: the lane owns /opt/harbor-it, the wrappers, the local
# apt repository, the throwaway SSH key, and the release tag on the checkout
# under test. Harbor's own paths (/etc, /var/lib/harbor, /usr/local, /opt/harbor)
# are left for Harbor to create at their real locations, which is the whole point
# of running on a machine that is thrown away afterwards.
#
# Usage: fleet/tests/integration/setup.sh <scenario>
#   scenario   ufw-inactive or ufw-active, the firewall pre-state this job runs
#              against. Both are exercised, in separate jobs, because Harbor
#              takes a different path through the firewall row for each and a
#              node cannot be put back to the other pre-state without a teardown
#              command this release does not ship.
#
# Runs as the unprivileged workflow user and reaches for sudo one action at a
# time. It never uses sudo -E and never adds a sudoers env_keep.
set -euo pipefail

# shellcheck source=lib/common.sh
. "$(cd "$(dirname "${0}")" && pwd -P)/lib/common.sh"

scenario="${1:?usage: setup.sh <ufw-inactive|ufw-active>}"
case "${scenario}" in
  ufw-inactive | ufw-active) ;;
  *)
    printf 'setup.sh: unknown scenario %s\n' "${scenario}" >&2
    exit 1
    ;;
esac

step() {
  printf '\n== %s\n' "${*}"
}

# ---------------------------------------------------------------------------
step 'preconditions'
# ---------------------------------------------------------------------------
[ "$(id -u)" != 0 ] || {
  printf 'setup.sh runs as the workflow user, not as root\n' >&2
  exit 1
}
sudo -n true
os_version="$(sed -n 's/^VERSION_ID="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' /etc/os-release | sed -n 1p)"
[ "${os_version}" = "$(it_lock ubuntu_release)" ] || {
  printf 'setup.sh: this runner is Ubuntu %s, and versions.lock pins %s\n' \
    "${os_version}" "$(it_lock ubuntu_release)" >&2
  exit 1
}
[ "$(uname -m)" = x86_64 ] || {
  printf 'setup.sh: this runner is %s, and the lane pins an amd64 package\n' "$(uname -m)" >&2
  exit 1
}
[ "$(ps -o comm= -p 1)" = systemd ] || {
  printf 'setup.sh: PID 1 is not systemd, so the linger and unit rows cannot be real\n' >&2
  exit 1
}

tailscale_version="$(it_lock tailscale_version)"
nodejs_version="$(it_lock nodejs_version)"
printf 'admin user      %s\n' "${IT_ADMIN}"
printf 'scenario        %s\n' "${scenario}"
printf 'tailscale pin   %s\n' "${tailscale_version}"
printf 'nodejs pin      %s\n' "${nodejs_version}"

# ---------------------------------------------------------------------------
step 'lane directories and logs'
# ---------------------------------------------------------------------------
sudo rm -rf "${IT_ROOT}"
sudo install -d -m 0755 -o root -g root \
  "${IT_ROOT}" "${IT_BIN}" "${IT_STATE}" "${IT_FIXTURES}" "${IT_BASELINE}"
# The two logs are world-writable on purpose: the operator account runs the
# tailscale stub through runuser during the read-access probe and has to be able
# to record that it did. Nothing secret is ever written to them.
sudo install -m 0666 -o root -g root /dev/null "${IT_SHIM_LOG}"
sudo install -m 0666 -o root -g root /dev/null "${IT_MUT_LOG}"
# The stand-in daemon's BackendState, seeded at the not-logged-in pre-state every
# bootstrap in this lane measures. It is world-writable for the same reason the two
# logs above are: harbor auth tailscale is the operator's command, so the stub's "up"
# runs unprivileged and has to be able to record the transition to Running. Nothing
# secret is ever written to it, and the login URL never is.
printf 'NeedsLogin\n' | sudo tee "${IT_TS_BACKEND}" >/dev/null
sudo chmod 0666 "${IT_TS_BACKEND}"

# ---------------------------------------------------------------------------
step 'wrappers'
# ---------------------------------------------------------------------------
sudo install -m 0755 -o root -g root "${IT_INTEGRATION}/bin/ufw" "${IT_BIN}/ufw"
sudo install -m 0755 -o root -g root "${IT_INTEGRATION}/bin/curl" "${IT_BIN}/curl"
sudo install -m 0755 -o root -g root "${IT_INTEGRATION}/bin/passthrough" "${IT_BIN}/passthrough"
for name in systemctl loginctl apt-get; do
  sudo ln -sfn passthrough "${IT_BIN}/${name}"
done
printf 'installed wrappers: ufw (fake), curl (local fixture), systemctl, loginctl, apt-get (logging pass-throughs)\n'

# ---------------------------------------------------------------------------
step 'firewall pre-state'
# ---------------------------------------------------------------------------
printf '%s\n' "${scenario}" | sudo tee "${IT_SCENARIO_FILE}" >/dev/null
case "${scenario}" in
  ufw-inactive)
    printf 'no\n' | sudo tee "${IT_STATE}/ufw.active" >/dev/null
    printf 'deny\n' | sudo tee "${IT_STATE}/ufw.default.incoming" >/dev/null
    printf 'allow\n' | sudo tee "${IT_STATE}/ufw.default.outgoing" >/dev/null
    sudo install -m 0644 -o root -g root /dev/null "${IT_STATE}/ufw.rules"
    ;;
  ufw-active)
    # An administrator's firewall that is already running, already allowing
    # incoming by default, and already carrying a rule of their own. Harbor must
    # add exactly its own tagged rule and change nothing else.
    printf 'yes\n' | sudo tee "${IT_STATE}/ufw.active" >/dev/null
    printf 'allow\n' | sudo tee "${IT_STATE}/ufw.default.incoming" >/dev/null
    printf 'allow\n' | sudo tee "${IT_STATE}/ufw.default.outgoing" >/dev/null
    printf 'allow 22/tcp comment pre-existing\n' | sudo tee "${IT_STATE}/ufw.rules" >/dev/null
    ;;
esac
sudo chmod 0644 "${IT_SCENARIO_FILE}" "${IT_STATE}/ufw.active" \
  "${IT_STATE}/ufw.default.incoming" "${IT_STATE}/ufw.default.outgoing" "${IT_STATE}/ufw.rules"

# ---------------------------------------------------------------------------
step 'Tailscale keyring fixture'
# ---------------------------------------------------------------------------
# Deterministic bytes standing in for the vendor keyring the curl wrapper serves.
# apt never reads it: the local repository is the only source that carries a
# tailscale package and it is trusted=yes. What the lane asserts about it is that
# Harbor fetched it, wrote it at the vendor path, and journaled its sha256.
printf 'harbor integration lane keyring fixture v1\n' \
  | sudo tee "${IT_FIXTURES}/tailscale-keyring.gpg" >/dev/null
sudo chmod 0644 "${IT_FIXTURES}/tailscale-keyring.gpg"
sha256sum "${IT_FIXTURES}/tailscale-keyring.gpg" | cut -d ' ' -f 1 \
  | sudo tee "${IT_STATE}/keyring.sha256" >/dev/null
sudo chmod 0644 "${IT_STATE}/keyring.sha256"

# ---------------------------------------------------------------------------
step 'make the packages row do real work'
# ---------------------------------------------------------------------------
# ufw is purged so that at least one of the six packages Harbor installs is
# genuinely absent; without that the row would journal six observed entries, the
# apt-install step boundary would never fire, and the convergence case for it
# would test nothing. The real ufw binary is never invoked by Harbor either way:
# the lane's wrapper is ahead of it on the PATH root runs with.
sudo env DEBIAN_FRONTEND=noninteractive /usr/bin/apt-get purge -y ufw
if dpkg-query -W -f '${Status}' ufw 2>/dev/null | grep -q ' installed'; then
  printf 'setup.sh: ufw is still installed after purge, so the packages row would journal nothing\n' >&2
  exit 1
fi

# ---------------------------------------------------------------------------
step 'local file:// apt repository'
# ---------------------------------------------------------------------------
sudo bash "${IT_INTEGRATION}/build_apt_repo.sh" "${tailscale_version}" "${IT_INTEGRATION}"

# ---------------------------------------------------------------------------
step 'Node.js runtime stand-in'
# ---------------------------------------------------------------------------
# Harbor verifies the Node.js tarball against nodejs_sha256, which pins the real
# upstream artefact, and design section 7 forbids the lane from depending on a
# vendor download host. A locally built tarball can never satisfy that hash, so
# the lane seeds the prefix with a stand-in runtime at the locked version instead
# and the download-and-checksum half of the Node.js row is left to the unit lane,
# which drives it through the curl shim. What the integration lane does prove for
# real here is the rest of the row: the four journaled symlinks in /usr/local/bin
# and the operator's own sh -lc 'node --version' probe.
sudo install -d -m 0755 -o root -g root /opt/harbor "${IT_NODE_PREFIX}" "${IT_NODE_PREFIX}/bin"
for name in node npm npx corepack; do
  sudo tee "${IT_NODE_PREFIX}/bin/${name}" >/dev/null <<EOF
#!/bin/bash
# Harbor integration-lane stand-in for ${name}, seeded by tests/integration/setup.sh.
set -euo pipefail
case "\${1:-}" in
  --version | -v | version) printf 'v${nodejs_version}\n' ;;
  *)
    printf 'integration ${name} stand-in: unsupported invocation: %s\n' "\${*}" >&2
    exit 64
    ;;
esac
EOF
  sudo chmod 0755 "${IT_NODE_PREFIX}/bin/${name}"
done
[ "$("${IT_NODE_PREFIX}/bin/node" --version)" = "v${nodejs_version}" ] || {
  printf 'setup.sh: the Node.js stand-in does not report v%s\n' "${nodejs_version}" >&2
  exit 1
}

# The runner image ships its own Node.js. Harbor refuses to replace anything at a
# link path that is not a symlink (node.link_foreign, exit 3), which is the right
# refusal on a real node and only an artefact of the runner image here, so those
# paths are cleared and the clearing is reported rather than hidden.
for name in node npm npx corepack; do
  link="/usr/local/bin/${name}"
  if [ -e "${link}" ] && [ ! -L "${link}" ]; then
    printf 'clearing %s, a regular file from the runner image\n' "${link}"
    sudo rm -f "${link}"
  elif [ -L "${link}" ]; then
    printf 'leaving %s, a symlink to %s, for Harbor to journal as modified\n' "${link}" "$(readlink "${link}")"
  fi
done

# ---------------------------------------------------------------------------
step 'throwaway administrator key'
# ---------------------------------------------------------------------------
# Harbor copies the invoking user's authorized_keys to the operator. The key pair
# is generated here, on this machine, and the private half is destroyed
# immediately: nothing secret exists to leak into a command line, a log line, or
# a journal entry, and the lane holds no Tailscale auth key at all.
keydir="$(mktemp -d)"
ssh-keygen -q -t ed25519 -N '' -C harbor-integration -f "${keydir}/id" </dev/null
install -d -m 0700 "${HOME}/.ssh"
cat "${keydir}/id.pub" >>"${HOME}/.ssh/authorized_keys"
chmod 0600 "${HOME}/.ssh/authorized_keys"
rm -rf "${keydir}"
sha256sum "${HOME}/.ssh/authorized_keys" | cut -d ' ' -f 1 \
  | sudo tee "${IT_STATE}/authorized-key.sha256" >/dev/null
sudo chmod 0644 "${IT_STATE}/authorized-key.sha256"
printf 'wrote %s/.ssh/authorized_keys (sha256 recorded, private half destroyed)\n' "${HOME}"

# ---------------------------------------------------------------------------
step 'sshd baseline for the installation user'
# ---------------------------------------------------------------------------
# The design section 7 test map asks that sshd -T -C user=<runner user> be
# unchanged by bootstrap. The baseline has to be taken while sshd exists, so
# openssh-server is installed here if the image lacks it; on the runner image it
# is already there and this changes nothing.
if [ ! -x /usr/sbin/sshd ]; then
  printf 'openssh-server is absent from this image; installing it before the baseline\n'
  sudo env DEBIAN_FRONTEND=noninteractive /usr/bin/apt-get install -y openssh-server
fi
# sshd refuses every invocation, -T and -t alike, when its privilege separation
# directory is missing, and /run is a tmpfs the runner image boots empty without ever
# having started sshd. Created here rather than in the assertions, because the -t of
# bootstrap's own ssh row needs it just as much as this baseline does.
sudo install -d -m 0755 -o root -g root /run/sshd
sudo /usr/sbin/sshd -T -C "user=${IT_ADMIN}" | LC_ALL=C sort \
  | sudo tee "${IT_BASELINE}/sshd-admin.txt" >/dev/null
sudo chmod 0644 "${IT_BASELINE}/sshd-admin.txt"
printf 'captured %s lines of sshd -T -C user=%s\n' \
  "$(wc -l <"${IT_BASELINE}/sshd-admin.txt")" "${IT_ADMIN}"

# ---------------------------------------------------------------------------
step 'exact release tag on the checkout under test'
# ---------------------------------------------------------------------------
# Contract point 1: a local exact tag, so harbor_checkout_tag takes the real
# path (clean work tree, no untracked file, HEAD exactly at a tag) and the
# release staged into /usr/local/lib/harbor is git archive of that tag.
tag="v0.0.0-integration.${GITHUB_RUN_ID:-local}.${GITHUB_RUN_ATTEMPT:-1}.${scenario}"
git -C "${IT_REPO}" tag -f "${tag}"
[ "$(git -C "${IT_REPO}" describe --tags --exact-match HEAD)" = "${tag}" ] || {
  printf 'setup.sh: HEAD does not describe as %s\n' "${tag}" >&2
  exit 1
}
printf '%s\n' "${tag}" | sudo tee "${IT_STATE}/release-tag" >/dev/null
printf '%s\n' "${IT_ADMIN}" | sudo tee "${IT_STATE}/admin" >/dev/null
sudo chmod 0644 "${IT_STATE}/release-tag" "${IT_STATE}/admin"

dirty="$(git -C "${IT_REPO}" status --porcelain --untracked-files=no)"
untracked="$(git -C "${IT_REPO}" ls-files --others --exclude-standard)"
if [ -n "${dirty}" ] || [ -n "${untracked}" ]; then
  printf 'setup.sh: the checkout is not clean, so the checkout rules would refuse it\n' >&2
  printf 'dirty: %s\nuntracked: %s\n' "${dirty}" "${untracked}" >&2
  exit 1
fi
printf 'tagged %s at %s\n' "${tag}" "$(git -C "${IT_REPO}" rev-parse --short HEAD)"

# ---------------------------------------------------------------------------
step 'baseline: Harbor has touched nothing yet'
# ---------------------------------------------------------------------------
for path in "${IT_HARBOR_STATE}" "${IT_INSTALL_ROOT}" "${IT_LINK}" "${IT_KEYRING}" "${IT_TAILSCALE_LIST}"; do
  if [ -e "${path}" ] || [ -L "${path}" ]; then
    printf 'setup.sh: %s exists before bootstrap; this runner is not clean\n' "${path}" >&2
    exit 1
  fi
done
printf 'setup complete\n'
