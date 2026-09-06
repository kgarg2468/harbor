#!/bin/bash
# Build the lane's local file:// apt repository and point this machine's apt at
# it, so the Tailscale install row of design section 5.2 runs its real apt-get
# against a locally built package at the version fleet/versions.lock pins and
# never reaches pkgs.tailscale.com (design section 7: "locally built packages for
# every third-party component, so ordinary PRs never depend on ... the Tailscale
# repository").
#
# apt is redirected rather than wrapped. An /etc/apt/apt.conf.d fragment moves
# Dir::Etc::sourcelist and Dir::Etc::sourceparts to a lane-owned directory that
# holds a copy of this machine's real Ubuntu sources plus one file:// entry for
# the repository built here. Harbor's own apt-get is the genuine binary doing
# genuine work; the vendor host is simply not in any source it can see. The
# tailscale.list Harbor writes into the real /etc/apt/sources.list.d is therefore
# created, journaled and asserted for real, and never consulted.
#
# Usage: sudo bash build_apt_repo.sh <tailscale-version> <integration-dir>
# Runs as root. Standalone: it takes everything it needs as arguments so nothing
# has to be inherited through sudo.
set -euo pipefail

version="${1:?usage: build_apt_repo.sh <tailscale-version> <integration-dir>}"
integration="${2:?usage: build_apt_repo.sh <tailscale-version> <integration-dir>}"

root=/opt/harbor-it
repo="${root}/aptrepo"
aptdir="${root}/apt"
build="${root}/build"
deb="tailscale_${version}_amd64.deb"

[ "$(id -u)" = 0 ] || {
  printf 'build_apt_repo.sh must run as root\n' >&2
  exit 1
}

rm -rf "${build}" "${repo}"
mkdir -p "${repo}" "${aptdir}/sources.list.d"

# ---------------------------------------------------------------------------
# The package. It carries exactly the three files a Tailscale package needs to
# put on this node for the bootstrap rows to be real: the CLI on PATH where
# runuser can find it, a daemon binary, and a unit. It has no maintainer script,
# so installing it starts nothing; the status probe starts the daemon itself.
# ---------------------------------------------------------------------------
pkg="${build}/tailscale"
mkdir -p "${pkg}/DEBIAN" "${pkg}/usr/bin" "${pkg}/usr/lib/systemd/system" \
  "${pkg}/usr/share/harbor-integration"

install -m 0755 "${integration}/stub/tailscale" "${pkg}/usr/bin/tailscale"
printf '%s\n' "${version}" >"${pkg}/usr/share/harbor-integration/tailscale-version"
chmod 0644 "${pkg}/usr/share/harbor-integration/tailscale-version"

cat >"${pkg}/usr/bin/tailscaled" <<'EOF'
#!/bin/bash
# Integration-lane stand-in for tailscaled. It holds the unit up and answers
# nothing: the CLI stub does not talk to it. Starting it proves the unit runs,
# not that a real daemon behaves; see tailscale_status_probe.sh.
set -euo pipefail
exec sleep infinity
EOF
chmod 0755 "${pkg}/usr/bin/tailscaled"

cat >"${pkg}/usr/lib/systemd/system/tailscaled.service" <<'EOF'
[Unit]
Description=Harbor integration-lane stand-in for the Tailscale node agent

[Service]
ExecStart=/usr/bin/tailscaled
Restart=no

[Install]
WantedBy=multi-user.target
EOF
chmod 0644 "${pkg}/usr/lib/systemd/system/tailscaled.service"

cat >"${pkg}/DEBIAN/control" <<EOF
Package: tailscale
Version: ${version}
Architecture: amd64
Section: net
Priority: optional
Installed-Size: 16
Maintainer: Harbor integration lane <harbor@example.com>
Description: Harbor integration-lane stand-in for the pinned tailscale package
 Built by fleet/tests/integration/build_apt_repo.sh at the version
 fleet/versions.lock pins, so the bootstrap Tailscale install row runs a real
 apt-get against a real package without reaching a vendor host. It carries the
 CLI surface Harbor calls and a trivial daemon, and nothing else.
EOF
chmod 0644 "${pkg}/DEBIAN/control"

dpkg-deb --build --root-owner-group "${pkg}" "${repo}/${deb}" >/dev/null

# ---------------------------------------------------------------------------
# The flat repository index. Written by hand rather than with dpkg-scanpackages
# and apt-ftparchive, because dpkg-dev and apt-utils are not guaranteed to be on
# the runner and every field here is known exactly.
# ---------------------------------------------------------------------------
size="$(stat -c '%s' "${repo}/${deb}")"
sha="$(sha256sum "${repo}/${deb}" | cut -d ' ' -f 1)"

cat >"${repo}/Packages" <<EOF
Package: tailscale
Version: ${version}
Architecture: amd64
Section: net
Priority: optional
Installed-Size: 16
Maintainer: Harbor integration lane <harbor@example.com>
Filename: ./${deb}
Size: ${size}
SHA256: ${sha}
Description: Harbor integration-lane stand-in for the pinned tailscale package
 Built by fleet/tests/integration/build_apt_repo.sh at the version
 fleet/versions.lock pins.
EOF

rm -f "${repo}/Packages.gz"
gzip -9 -k -n "${repo}/Packages"

{
  printf 'Origin: harbor-integration\n'
  printf 'Label: harbor-integration\n'
  printf 'Suite: harbor-integration\n'
  printf 'Codename: harbor-integration\n'
  printf 'Architectures: amd64\n'
  printf 'Date: %s\n' "$(date -u '+%a, %d %b %Y %H:%M:%S UTC')"
  printf 'SHA256:\n'
  printf ' %s %s Packages\n' \
    "$(sha256sum "${repo}/Packages" | cut -d ' ' -f 1)" "$(stat -c '%s' "${repo}/Packages")"
  printf ' %s %s Packages.gz\n' \
    "$(sha256sum "${repo}/Packages.gz" | cut -d ' ' -f 1)" "$(stat -c '%s' "${repo}/Packages.gz")"
} >"${repo}/Release"

chmod 0755 "${repo}"
chmod 0644 "${repo}/${deb}" "${repo}/Packages" "${repo}/Packages.gz" "${repo}/Release"

# ---------------------------------------------------------------------------
# The redirected sources: this machine's real Ubuntu sources, copied once, plus
# the local repository. Copied once and never refreshed, so the tailscale.list
# Harbor writes later into the real /etc/apt/sources.list.d cannot leak in.
# ---------------------------------------------------------------------------
rm -rf "${aptdir}/sources.list.d"
mkdir -p "${aptdir}/sources.list.d"
if [ -d /etc/apt/sources.list.d ]; then
  find /etc/apt/sources.list.d -maxdepth 1 -type f \
    \( -name '*.list' -o -name '*.sources' \) -exec cp -p {} "${aptdir}/sources.list.d/" \;
fi
if [ -f /etc/apt/sources.list ]; then
  cp -p /etc/apt/sources.list "${aptdir}/sources.list"
else
  : >"${aptdir}/sources.list"
fi

printf 'deb [trusted=yes] file:%s ./\n' "${repo}" >"${aptdir}/sources.list.d/harbor-local.list"
chmod 0644 "${aptdir}/sources.list" "${aptdir}/sources.list.d/harbor-local.list"

cat >/etc/apt/apt.conf.d/99-harbor-integration <<EOF
Dir::Etc::sourcelist "${aptdir}/sources.list";
Dir::Etc::sourceparts "${aptdir}/sources.list.d";
EOF
chmod 0644 /etc/apt/apt.conf.d/99-harbor-integration

# ---------------------------------------------------------------------------
# Prove the redirection took, before any bootstrap runs. A silent failure here
# would send Harbor's apt-get at the vendor host, which is the one thing this
# file exists to prevent.
# ---------------------------------------------------------------------------
if grep -R -l 'pkgs\.tailscale\.com' "${aptdir}" >/dev/null 2>&1; then
  printf 'build_apt_repo.sh: a redirected apt source names the vendor host\n' >&2
  exit 1
fi

DEBIAN_FRONTEND=noninteractive /usr/bin/apt-get update

policy="$(/usr/bin/apt-cache policy tailscale)"
printf '%s\n' "${policy}"
case "${policy}" in
  *"file:${repo}"*) ;;
  *)
    printf 'build_apt_repo.sh: apt does not see the local repository %s\n' "${repo}" >&2
    exit 1
    ;;
esac
case "${policy}" in
  *"${version}"*) ;;
  *)
    printf 'build_apt_repo.sh: apt does not offer tailscale %s from the local repository\n' "${version}" >&2
    exit 1
    ;;
esac
case "${policy}" in
  *pkgs.tailscale.com*)
    printf 'build_apt_repo.sh: apt can still see the vendor host\n' >&2
    exit 1
    ;;
esac

printf 'build_apt_repo.sh: tailscale %s served from file:%s\n' "${version}" "${repo}"
