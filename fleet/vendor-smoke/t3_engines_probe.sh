#!/bin/bash
# The T3 half of the vendor-smoke lane (design section 7): install the real pinned
# npm package, compare its own engines.node with the lock byte for byte, and ask
# Harbor's real adapter what the real CLI says before any service is installed.
#
# Usage: fleet/vendor-smoke/t3_engines_probe.sh <record-file>
#
# Nothing the vendor prints leaves the runner. Downloads, npm, package readers,
# and the adapter all write into a private working directory. Only comparisons
# against markers this file chose can contribute words to the record, summary,
# or job log. No capture is an artifact, and cleanup removes every capture.
#
# A fresh home and an empty vendor environment keep this lane free of credentials
# and pre-existing T3 state. No login or service install is performed. Failure to
# obtain the packages is inconclusive, never evidence of a vendor defect.
set +x
set -euo pipefail

record="${1:-t3-probe.record}"
work=""
published=0
record_body=""

fail() {
  printf '\nt3_engines_probe.sh: %s\n' "${1}" >&2
  exit 1
}

banner() {
  printf '\n========================================================================\n'
  printf '%s\n' "${1}"
  printf '========================================================================\n'
}

# emit KEY VALUE: only this file's words and repository lock values enter here.
# Keep the record in memory so even a failure to create the private directory has
# a record to publish. Vendor captures never share the record's storage.
emit() {
  record_body="${record_body}${1}=${2}
"
}

# Publish the same record to the artifact, job log, and step summary. Set the flag
# first so a failure during publication cannot produce a contradictory verdict.
publish() {
  published=1
  mkdir -p "$(dirname "${record}")"
  printf '%s' "${record_body}" >"${record}"
  banner record
  printf '%s' "${record_body}"
  [ -n "${GITHUB_STEP_SUMMARY:-}" ] || return 0
  {
    printf '### T3 vendor-smoke record\n\n```\n'
    printf '%s' "${record_body}"
    printf '```\n'
  } >>"${GITHUB_STEP_SUMMARY}"
}

cleanup() {
  local rc=$?
  # This also covers set -e deaths during setup, before an explicit abort could
  # run. A signal exits through this same trap; an unmade measurement is always
  # inconclusive. Publishing does not depend on a working capture directory.
  if [ "${published}" = 0 ]; then
    emit result inconclusive
    emit note measurement-not-completed
    publish || :
  fi
  [ -z "${work}" ] || rm -rf "${work}"
  return "${rc}"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

abort() {
  emit result inconclusive
  emit note "${1}"
  publish
  fail "${1}"
}

# The traps precede even argument checks and directory creation: setup failures
# belong in the uploaded record just as much as completed measurements do.
[ "$#" = 1 ] || abort usage-requires-record-file
umask 077
work="$(mktemp -d)"
chmod 0700 "${work}"
self_dir="$(cd "$(dirname "${0}")" && pwd -P)"
HARBOR_ROOT="$(cd "${self_dir}/.." && pwd -P)"
# shellcheck source=lib/log.sh
. "${HARBOR_ROOT}/lib/log.sh"
# shellcheck source=lib/versions.sh
. "${HARBOR_ROOT}/lib/versions.sh"
# Disable inherited Harbor logging: diagnostics belong only in private captures.
HARBOR_LOG_FILE=""
HARBOR_VERBOSE=0
harbor_versions_load "${HARBOR_ROOT}/versions.lock" >"${work}/lock.out" 2>&1
t3_version="$(harbor_version_require t3_version 2>"${work}/lock.err")"
t3_engines_node="$(harbor_version_require t3_engines_node 2>"${work}/lock.err")"
nodejs_version="$(harbor_version_require nodejs_version 2>"${work}/lock.err")"
nodejs_install="$(harbor_version_require nodejs_install 2>"${work}/lock.err")"
nodejs_sha256="$(harbor_version_require nodejs_sha256 2>"${work}/lock.err")"
emit date "$(date -u +%Y-%m-%d)"
emit t3_version "${t3_version}"
emit t3_engines_node "${t3_engines_node}"
emit nodejs_version "${nodejs_version}"

banner 'vendor-smoke: the pinned T3, with no service installed'
[ "$(id -u)" != 0 ] || abort requires-unprivileged-runner
[ "$(uname -s)" = Linux ] && [ "$(uname -m)" = x86_64 ] \
  || abort requires-linux-x64
# This is the platform of the workflow and of the node Harbor provisions.
if ! grep -qx 'VERSION_ID="24.04"' /etc/os-release; then
  abort requires-ubuntu-24.04
fi

# ---------------------------------------------------------------------------
banner 'the pinned Node runtime and real npm install'
# ---------------------------------------------------------------------------
# Download the locked runtime here so setup failures still reach this probe's
# EXIT trap. The checksum is the repository's pin, not a value from the download.
# curl gets no inherited credentials or config; all of its diagnostics stay private.
if ! env -i PATH=/usr/bin:/bin curl -q -fsSL --proto '=https' \
  --proto-redir '=https' --tlsv1.2 --connect-timeout 20 --max-time 180 \
  "${nodejs_install}" -o "${work}/node.tar.xz" >"${work}/download.out" 2>&1; then
  abort node-download-unavailable
fi
printf '%s  %s\n' "${nodejs_sha256}" "${work}/node.tar.xz" >"${work}/node.sha256"
if ! sha256sum -c "${work}/node.sha256" >"${work}/checksum.out" 2>&1; then
  abort node-download-checksum-mismatch
fi
mkdir -p "${work}/node" "${work}/home" "${work}/tmp"
if ! tar -xJf "${work}/node.tar.xz" --strip-components=1 -C "${work}/node" \
  >"${work}/extract.out" 2>&1; then
  abort node-extraction-failed
fi

# Match Harbor's executable prefix. The package path below is spelled out here
# rather than taken from harbor_t3_package_dir on purpose: a probe that asks Harbor
# where the package is can only ever confirm that Harbor agrees with itself. This
# file is where npm gets to answer instead.
probe_home="${work}/home"
prefix="${probe_home}/.local/harbor/npm"
vendor_env=(env -i "HOME=${probe_home}" "PATH=${work}/node/bin:/usr/bin:/bin"
  "TMPDIR=${work}/tmp" "XDG_CONFIG_HOME=${probe_home}/.config" LC_ALL=C NO_COLOR=1)
cd "${probe_home}"
# Two absent paths, not /dev/null twice: npm resolves each config file and refuses
# to load the same one under two names, exiting before it reads any of its own
# arguments with "double-loading config /dev/null as global, previously loaded as
# user". A path that does not exist is the isolation these flags were reaching for
# anyway -- there is no file, so there is no credential in one.
if ! timeout --kill-after=5s 300s "${vendor_env[@]}" npm install --global \
  --prefix "${prefix}" --registry=https://registry.npmjs.org \
  --userconfig="${work}/npmrc.user" --globalconfig="${work}/npmrc.global" \
  --cache "${work}/npm-cache" \
  --no-audit --no-fund "t3@${t3_version}" >"${work}/npm.out" 2>&1; then
  # The registry, the transport, the package, and this probe's own invocation all
  # land here, and the capture that would tell them apart is npm's untrusted
  # diagnostic. So the note says what is actually known -- the install did not
  # finish -- rather than naming a cause, and certainly rather than calling it drift.
  abort npm-install-did-not-complete
fi
emit npm_install completed

# ---------------------------------------------------------------------------
banner 'the installed package engines.node, byte for byte'
# ---------------------------------------------------------------------------
# Parse JSON as data, never require() vendor code. Write the decoded string with
# no newline and compare files: command substitution would discard trailing LF
# bytes and could falsely accept a different engines.node string.
package="${prefix}/lib/node_modules/t3/package.json"
if ! "${vendor_env[@]}" node -e '
  const fs = require("node:fs");
  const p = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  if (p.name !== "t3" || p.version !== process.argv[2]) process.exit(2);
  if (typeof p.engines?.node !== "string") process.exit(3);
  fs.writeFileSync(process.argv[3], p.engines.node, "utf8");
' "${package}" "${t3_version}" "${work}/engines.actual" >"${work}/package.out" 2>&1; then
  abort installed-package-unreadable-or-not-pinned
fi
printf '%s' "${t3_engines_node}" >"${work}/engines.expected"
verdict=pass
if cmp -s "${work}/engines.expected" "${work}/engines.actual"; then
  emit engines_node match
else
  emit engines_node mismatch
  verdict=fail
fi

# ---------------------------------------------------------------------------
banner "Harbor's own package readers, against the real installed package"
# ---------------------------------------------------------------------------
# The JSON read above is ground truth. These are the two readers provision actually
# stands on, and each one believes something about the vendor that no unit fixture
# can test: harbor_t3_package_engines is a structural awk pass that requires the
# pin's canonical block shape and two- and four-space depths, and
# harbor_t3_installed_version requires the CLI to print the decoration "t3 vN.N.N".
# Every fixture for both was written from Harbor's code rather than from npm, which
# is exactly how the prefix/lib/node_modules layout stayed wrong through 736 green
# tests. Captures stay private; only the fixed comparisons below reach the record.
if ! timeout --kill-after=5s 60s "${vendor_env[@]}" bash --noprofile --norc -c '
  set -euo pipefail
  HARBOR_ROOT="${1}"
  . "${HARBOR_ROOT}/lib/log.sh"
  . "${HARBOR_ROOT}/lib/versions.sh"
  . "${HARBOR_ROOT}/lib/runtime.sh"
  . "${HARBOR_ROOT}/lib/agents.sh"
  . "${HARBOR_ROOT}/lib/t3.sh"
  harbor_versions_load "${HARBOR_ROOT}/versions.lock"
  harbor_t3_package_engines "${2}" >"${3}"
  harbor_t3_installed_version "${2}" >"${4}"
' bash "${HARBOR_ROOT}" "${probe_home}" "${work}/engines.harbor" "${work}/version.harbor" \
  >"${work}/readers.out" 2>"${work}/readers.err"; then
  # Either reader exits 2 rather than answering when it cannot vouch for what it
  # read, so this arm is a finding, not an absence of one. Its diagnostic may quote
  # the package, so it stays in the private capture.
  emit harbor_readers did-not-complete
  verdict=fail
else
  if cmp -s "${work}/engines.expected" "${work}/engines.harbor"; then
    emit harbor_engines_node match
  else
    emit harbor_engines_node mismatch
    verdict=fail
  fi
  # "absent" is harbor_t3_installed_version's own word for no executable at
  # prefix/bin/t3, and it is worth its own record line: it would mean npm puts the
  # executables somewhere other than where harbor_t3_bin looks, which is the bin
  # twin of the package-path assumption this lane exists to measure.
  printf 'absent' >"${work}/version.absent"
  printf '%s' "${t3_version}" >"${work}/version.expected"
  if cmp -s "${work}/version.expected" "${work}/version.harbor"; then
    emit harbor_installed_version match
  elif cmp -s "${work}/version.absent" "${work}/version.harbor"; then
    emit harbor_installed_version absent
    verdict=fail
  else
    emit harbor_installed_version mismatch
    verdict=fail
  fi
fi

# ---------------------------------------------------------------------------
banner 'the real service status through Harbor'
# ---------------------------------------------------------------------------
# The fresh home contains only the npm install. No service install command has
# run, and the clean environment cannot select another T3 home or user bus.
# Source the real dependencies in a bounded, clean subprocess. The adapter itself
# invokes the installed t3 service status; this probe does not copy its classifier.
# Capture BOTH streams, including version-guard errors that may quote vendor text.
if ! timeout --kill-after=5s 60s "${vendor_env[@]}" bash --noprofile --norc -c '
  set -euo pipefail
  HARBOR_ROOT="${1}"
  . "${HARBOR_ROOT}/lib/log.sh"
  . "${HARBOR_ROOT}/lib/versions.sh"
  . "${HARBOR_ROOT}/lib/runtime.sh"
  . "${HARBOR_ROOT}/lib/agents.sh"
  . "${HARBOR_ROOT}/lib/t3.sh"
  harbor_versions_load "${HARBOR_ROOT}/versions.lock"
  harbor_t3_service_status "${2}"
' bash "${HARBOR_ROOT}" "${probe_home}" >"${work}/adapter.out" 2>"${work}/adapter.err"; then
  abort adapter-did-not-complete
fi
# Fixed expected bytes fence the publication boundary too: even unexpected adapter
# output is never interpolated into a message. Only words selected here are emitted.
printf 'not-installed' >"${work}/status.expected"
if cmp -s "${work}/status.expected" "${work}/adapter.out"; then
  emit service_status not-installed
else
  printf 'unknown' >"${work}/status.unknown"
  if cmp -s "${work}/status.unknown" "${work}/adapter.out"; then
    emit service_status unknown
  else
    emit service_status unexpected
  fi
  verdict=fail
fi
emit result "${verdict}"
publish
[ "${verdict}" = pass ] || fail assertion-failed
