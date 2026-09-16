#!/bin/bash
# The Tailscale Serve adapter (design sections 3.3 and 5.5). Harbor reads Serve, it
# predicts what the vendor will do to Serve, and it journals that prediction. It
# never calls `tailscale serve` to change anything and never calls `tailscale
# funnel` at all: the v1 invariant is no public inbound exposure, so Funnel is a
# thing this file detects and refuses, not a thing it operates.
#
# Every answer here is one of a fixed set of words. "absent" and "unnormalizable"
# are deliberately different words for deliberately different situations: absent
# means Harbor looked and there is no HTTPS 443 mapping, which is the state in
# which harbor pair may create one; unnormalizable means Harbor could not reduce
# what it read to a mapping it can compare, which is never a licence to act.

# harbor_serve_status: capture `tailscale serve status` into HARBOR_SERVE_RAW.
#
# Stdout only, and the reason is measured rather than reasoned. Folding stderr in
# looks like the careful choice -- a refusal is part of the reading -- but this
# vendor writes an unsolicited line to stderr whenever the CLI and the daemon
# disagree about their versions:
#
#   Warning: client version "1.96.4-..." != tailscaled server version "1.98.2-..."
#
# which is the ordinary state of a node whose tailscale package was upgraded
# under a tailscaled that is still running, i.e. every node that has ever taken
# an unattended apt upgrade. With 2>&1 that warning becomes the first line of
# HARBOR_SERVE_RAW, every prefix match below misses, and a healthy node with no
# Serve config reads as unnormalizable instead of absent -- which makes
# harbor pair exit 2 and the provision tailnet row go attended, on a node that is
# completely fine. Measured against a real tailscale 1.96.4 CLI talking to a
# 1.98.2 daemon, where "No serve config" is on stdout and the warning is not.
#
# A non-zero exit is not parsed at all. The exit code is the vendor saying it did
# not answer the question, and stdout in that case is not a Serve configuration
# however much it may look like one; the readers below turn the empty body into
# unnormalizable and unknown, which are the fail-closed words.
harbor_serve_status() {
  local out rc=0
  HARBOR_SERVE_RAW=""
  HARBOR_SERVE_WHY=""
  out="$(tailscale serve status 2>/dev/null)" || rc="$?"
  if [ "${rc}" != 0 ]; then
    # shellcheck disable=SC2034  # read by lib/pair.sh's refusal messages in slice
    # 5d, and by this slice's tests; set here because this is the only place that
    # knows the exit code, and a reason discarded at its source cannot be recovered.
    HARBOR_SERVE_WHY="tailscale serve status exited ${rc}"
    return 0
  fi
  HARBOR_SERVE_RAW="${out}"
  return 0
}

# harbor_serve_loopback_host HOST: the canonical loopback identity, per section
# 5.5. Four spellings, because tailscale prints the bracketed form for IPv6 inside
# a URL and the bare form elsewhere, and a spelling difference must never fail the
# prediction Harbor journals.
harbor_serve_loopback_host() {
  case "${1}" in
    localhost | 127.0.0.1 | '::1' | '[::1]') printf 'loopback' ;;
    *) printf '%s' "${1}" ;;
  esac
}

# harbor_serve_mapping: the normalized HTTPS 443 mapping, "absent", or
# "unnormalizable". Requires harbor_serve_status to have run.
harbor_serve_mapping() {
  local header target host port
  # An empty body is not an empty config: `tailscale serve status` says so in
  # words when there is nothing configured. Zero bytes means the command did not
  # answer, which is a reading Harbor cannot use.
  [ -n "${HARBOR_SERVE_RAW}" ] || {
    printf 'unnormalizable'
    return 0
  }
  case "${HARBOR_SERVE_RAW}" in
    'No serve config'*)
      printf 'absent'
      return 0
      ;;
  esac
  # The header line carries the port. No :port suffix on the host means 443, which
  # is the port this adapter reports on; an explicit other port is a mapping this
  # adapter does not describe, and at 443 there is nothing.
  header="$(printf '%s\n' "${HARBOR_SERVE_RAW}" | sed -n '1p')"
  case "${header}" in
    'https://'*' ('*')') ;;
    *)
      printf 'unnormalizable'
      return 0
      ;;
  esac
  case "${header}" in
    *.ts.net' '*) ;;
    *)
      printf 'absent'
      return 0
      ;;
  esac
  target="$(printf '%s\n' "${HARBOR_SERVE_RAW}" | sed -n 's#^|-- / proxy \(http://.*\)$#\1#p')"
  [ -n "${target}" ] || {
    printf 'unnormalizable'
    return 0
  }
  host="${target#http://}"
  port="${host##*:}"
  host="${host%:*}"
  case "${port}" in
    '' | *[!0123456789]*)
      printf 'unnormalizable'
      return 0
      ;;
  esac
  printf 'https:443 -> http://%s:%s' "$(harbor_serve_loopback_host "${host}")" "${port}"
}

# harbor_serve_funnel: whether any Funnel exposure exists. Section 3.3 makes this
# exit 2 wherever it is asked, whoever created the exposure, which is why the
# unknown arm exists: a body this adapter cannot read is not evidence of no Funnel.
harbor_serve_funnel() {
  [ -n "${HARBOR_SERVE_RAW}" ] || {
    printf 'unknown'
    return 0
  }
  case "${HARBOR_SERVE_RAW}" in
    'No serve config'*)
      printf 'none'
      return 0
      ;;
    *'(Funnel on)'*)
      printf 'present'
      return 0
      ;;
    'https://'*)
      printf 'none'
      return 0
      ;;
  esac
  printf 'unknown'
}

# harbor_observe_op_tailscale_serve TARGET: the tailscale-serve op's observer, found
# by harbor_journal_observe under this exact name. It re-reads Serve on every call
# rather than trusting HARBOR_SERVE_RAW: recovery runs long after the write that
# left the entry prepared, and answering from a stale capture would compare the
# entry against the world as it was when Harbor last looked, which is the one
# reading that cannot decide anything.
harbor_observe_op_tailscale_serve() {
  harbor_serve_status
  printf '"%s"' "$(harbor_json_escape "$(harbor_serve_mapping)")"
}
