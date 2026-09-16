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

# harbor_serve_header_port HEADER: the port a listener header announces. The host
# carries it as a suffix, and no suffix means 443 -- which is the vendor's own
# default and the only port this adapter reports on.
harbor_serve_header_port() {
  local hostpart="${1#https://}"
  hostpart="${hostpart%% *}"
  case "${hostpart}" in
    *:*) printf '%s' "${hostpart##*:}" ;;
    *) printf '443' ;;
  esac
}

# harbor_serve_mapping: the normalized HTTPS 443 mapping, "absent", or
# "unnormalizable". Requires harbor_serve_status to have run.
#
# This walks the body listener by listener rather than reading the first line and
# then grepping the whole document for a proxy target. The short version was wrong
# in a way that mattered: `tailscale serve status` lists one header per listener
# with that listener's handlers indented beneath it, so a node with an 8443
# listener above its 443 one made the first-line read announce "not 443" while the
# global grep would happily have returned the 443 listener's target. The two
# halves disagreed, and the half that won returned `absent` -- which
# harbor_pair_precheck treats as permission to create a mapping. A parse bug that
# ends in Harbor mutating Serve on a node that already had a 443 listener defeats
# the one invariant this whole file exists to hold.
#
# Two root handlers inside the same 443 listener is not a mapping either. It is a
# configuration this adapter cannot reduce to one comparable string, and guessing
# which of them is the real one is exactly the guess `unnormalizable` exists to
# refuse. Likewise a 443 listener with handlers but no root handler: something is
# at 443, so the answer is not `absent`, and Harbor cannot describe it, so the
# answer is not a mapping.
harbor_serve_mapping() {
  local line target='' host port seen443=0 in443=0 ambiguous=0
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
  while IFS= read -r line; do
    case "${line}" in
      '')
        continue
        ;;
      'https://'*' ('*')')
        if [ "$(harbor_serve_header_port "${line}")" = 443 ]; then
          in443=1
          seen443=1
        else
          in443=0
        fi
        ;;
      '|-- / proxy http://'*)
        if [ "${in443}" = 1 ]; then
          if [ -n "${target}" ]; then
            ambiguous=1
          fi
          target="${line#'|-- / proxy '}"
        fi
        ;;
      '|--'*)
        # A handler on some other path, or a handler whose target is not an http
        # proxy. It belongs to a listener but it is not the root mapping, so it
        # neither supplies a target nor makes the body unreadable.
        continue
        ;;
      *)
        # A line this adapter has no reading for. Refusing here is what keeps a
        # future vendor format from being silently parsed as the old one.
        printf 'unnormalizable'
        return 0
        ;;
    esac
  done <<EOF
${HARBOR_SERVE_RAW}
EOF
  if [ "${seen443}" = 0 ]; then
    printf 'absent'
    return 0
  fi
  if [ "${ambiguous}" = 1 ] || [ -z "${target}" ]; then
    printf 'unnormalizable'
    return 0
  fi
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
