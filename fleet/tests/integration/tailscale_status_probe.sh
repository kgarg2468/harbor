#!/bin/bash
# Issue #63: harbor_tailscale_status (fleet/lib/tailscale.sh) turns a non-zero
# "tailscale status --json" into a FATAL exit 2, and the operator row stands on
# that read. If a real, never-logged-in tailscaled answers --json with a non-zero
# status, every fresh bootstrap dies at the Tailscale operator row on a daemon
# Harbor has only just installed and cannot yet log in.
#
# This script MEASURES that, on a real daemon, and records the exit code and the
# output rather than assuming either. It changes nothing in fleet/lib.
#
# Usage: fleet/tests/integration/tailscale_status_probe.sh <archive|vendor|stub>
#
#   archive  install tailscale from the Ubuntu archive this runner already has,
#            if the archive carries it. This is the ordinary-PR path, because it
#            reaches no vendor host (design section 7). If the archive does not
#            carry tailscale the measurement is reported NOT MADE, loudly, and no
#            result is asserted: a number nobody measured is worse than none.
#
#   vendor   install the pinned tailscale from the vendor repository and measure
#            the genuine daemon. This is the definitive answer to issue #63. It
#            reaches pkgs.tailscale.com, so it is opt-in through a
#            workflow_dispatch input and never runs on an ordinary pull request.
#            It still logs nothing in and holds no auth key.
#
#   stub     what the integration lane's own locally built stub answers. Recorded
#            for completeness and explicitly NOT evidence: the stub's exit code is
#            whatever the lane programmed, so it cannot settle issue #63 and this
#            script says so in as many words.
#
# Four readings are taken in each mode, because all four are states a fresh node
# really passes through:
#   1. daemon running, never logged in, as root, tailscale status --json
#   2. the same, without --json, for contrast
#   3. daemon running, never logged in, as an unprivileged user (Harbor's own
#      read-access probe before the operator grant)
#   4. daemon stopped, as root (the state a package whose postinst does not start
#      the daemon leaves behind)
set -euo pipefail

# shellcheck source=lib/common.sh
. "$(cd "$(dirname "${0}")" && pwd -P)/lib/common.sh"

mode="${1:?usage: tailscale_status_probe.sh <archive|vendor|stub>}"
tailscale_version="$(it_lock tailscale_version)"
channel="$(it_lock tailscale_apt_channel)"
track="${channel%/*}"
codename="${channel##*/}"

banner() {
  printf '\n========================================================================\n'
  printf '%s\n' "${*}"
  printf '========================================================================\n'
}

summary() {
  printf '%s\n' "${*}"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf '%s\n' "${*}" >>"${GITHUB_STEP_SUMMARY}"
  fi
}

# ---------------------------------------------------------------------------
# Install the daemon this mode measures. Prints the word "measured" on stdout
# when a daemon is installed and startable, "unavailable" when it is not.
# ---------------------------------------------------------------------------
install_daemon() {
  case "${1}" in
    archive)
      sudo env DEBIAN_FRONTEND=noninteractive apt-get update
      if ! apt-cache policy tailscale | grep -q 'Candidate: [0-9]'; then
        printf 'unavailable'
        return 0
      fi
      sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y tailscale
      ;;
    vendor)
      sudo install -d -m 0755 /etc/apt/keyrings
      curl -fsSL --proto '=https' --tlsv1.2 \
        "https://pkgs.tailscale.com/${track}/${codename}.noarmor.gpg" \
        | sudo tee /etc/apt/keyrings/tailscale-archive-keyring.gpg >/dev/null
      sudo chmod 0644 /etc/apt/keyrings/tailscale-archive-keyring.gpg
      printf 'deb [signed-by=/etc/apt/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/%s %s main\n' \
        "${track}" "${codename}" | sudo tee /etc/apt/sources.list.d/tailscale.list >/dev/null
      sudo env DEBIAN_FRONTEND=noninteractive apt-get update
      sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y "tailscale=${tailscale_version}"
      ;;
    stub)
      sudo bash "${IT_INTEGRATION}/build_apt_repo.sh" "${tailscale_version}" "${IT_INTEGRATION}"
      sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y "tailscale=${tailscale_version}"
      ;;
    *)
      printf 'tailscale_status_probe.sh: unknown mode %s\n' "${1}" >&2
      exit 1
      ;;
  esac
  printf 'measured'
}

record() {
  # record LABEL COMMAND... -- run it, print the exit code and the output.
  local label="${1}" rc=0 out
  shift
  out="$("$@" 2>&1)" || rc="$?"
  printf '\n### %s\n' "${label}"
  printf 'command : %s\n' "${*}"
  printf 'exit    : %s\n' "${rc}"
  printf 'output  :\n'
  printf '%s\n' "${out}" | sed -n '1,40p'
  printf '%s' "${rc}" >"${probe_dir}/${label}.exit"
  printf '%s' "${out}" >"${probe_dir}/${label}.out"
}

probe_dir="$(mktemp -d)"

banner "issue #63 measurement, mode: ${mode}"
printf 'Harbor treats a non-zero "tailscale status --json" as fatal (exit 2).\n'
printf 'What follows is what a real never-logged-in daemon actually answers.\n'

state="$(install_daemon "${mode}")"
if [ "${state}" = unavailable ]; then
  banner 'MEASUREMENT NOT MADE'
  summary '### Issue #63: measurement NOT made'
  summary ''
  summary 'The Ubuntu archive on this runner carries no `tailscale` package, so this job'
  summary 'could not install a real daemon without reaching a vendor host, which design'
  summary 'section 7 forbids on an ordinary pull request. **Nothing about issue #63 is'
  summary 'asserted here.** Run this workflow through `workflow_dispatch` with'
  summary '`measure_vendor_tailscale: true` to install the pinned vendor package in this'
  summary 'isolated job and get the definitive exit code.'
  exit 0
fi

# The daemon. The vendor package starts it from its own postinst; the archive
# package may or may not; the lane's stub package has no maintainer script at
# all, which is itself one of the states worth measuring.
sudo systemctl daemon-reload
rc=0
sudo systemctl start tailscaled || rc="$?"
printf '\nsystemctl start tailscaled exit: %s\n' "${rc}"
waited=0
while [ "${waited}" -lt 30 ] && [ ! -S /var/run/tailscale/tailscaled.sock ]; do
  sleep 1
  waited=$((waited + 1))
done
printf 'tailscaled.sock after %ss: %s\n' "${waited}" \
  "$([ -S /var/run/tailscale/tailscaled.sock ] && printf present || printf absent)"
sudo systemctl is-active tailscaled || printf '(tailscaled is not active)\n'

banner 'reading 1..3: daemon running, never logged in'
record root-json sudo tailscale status --json
record root-plain sudo tailscale status
record operator-json tailscale status --json

banner 'reading 4: daemon stopped'
sudo systemctl stop tailscaled || printf '(tailscaled was not running)\n'
sleep 1
record root-json-stopped sudo tailscale status --json

# ---------------------------------------------------------------------------
banner 'verdict'
# ---------------------------------------------------------------------------
running_rc="$(cat "${probe_dir}/root-json.exit")"
stopped_rc="$(cat "${probe_dir}/root-json-stopped.exit")"
probe_rc="$(cat "${probe_dir}/operator-json.exit")"
backend="$(sed -n 's/.*"BackendState"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
  "${probe_dir}/root-json.out" | sed -n 1p)"

summary "### Issue #63 measurement (mode: ${mode})"
summary ''
summary '| reading | exit |'
summary '| --- | --- |'
summary "| \`tailscale status --json\` as root, daemon up, never logged in | ${running_rc} |"
summary "| \`tailscale status\` as root, daemon up, never logged in | $(cat "${probe_dir}/root-plain.exit") |"
summary "| \`tailscale status --json\` as an unprivileged user, before any operator grant | ${probe_rc} |"
summary "| \`tailscale status --json\` as root, daemon stopped | ${stopped_rc} |"
summary ''
summary "BackendState reported: \`${backend:-none}\`"
summary ''

if [ "${mode}" = stub ]; then
  summary '**This is the lane'"'"'s own stub.** Its exit code is whatever the lane programmed,'
  summary 'so it is recorded for completeness and settles nothing about issue #63.'
  banner 'the stub settles nothing: its exit code is the lane speaking, not a daemon'
  exit 0
fi

status=0
if [ "${running_rc}" = 0 ]; then
  summary "harbor_tailscale_status' assumption HOLDS for a running, never-logged-in daemon:"
  summary '`tailscale status --json` exits 0, so a fresh bootstrap survives the operator row.'
else
  summary '**harbor_tailscale_status'"'"' assumption is WRONG.** A running, never-logged-in'
  summary "daemon answers \`tailscale status --json\` with exit ${running_rc}, and"
  summary 'fleet/lib/tailscale.sh turns that into a fatal exit 2, so every fresh bootstrap'
  summary 'dies at the Tailscale operator row. Issue #63 is real.'
  status=1
fi
if [ "${stopped_rc}" != 0 ]; then
  summary ''
  summary "With the daemon stopped the same read exits ${stopped_rc}, so a node whose"
  summary 'tailscaled is installed but not running also fails that row. Whatever is decided'
  summary 'for issue #63 has to cover that state too.'
fi
if [ "${probe_rc}" = 0 ]; then
  summary ''
  summary 'Note: the unprivileged read already succeeds before any operator grant, so the'
  summary 'read-access probe of design section 5.2 cannot distinguish a granted operator'
  summary 'from an ungranted one on this build.'
fi

banner "root, daemon up, never logged in: tailscale status --json exited ${running_rc}"
exit "${status}"
