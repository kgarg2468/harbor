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

# harbor_serve_header_port HEADER: the port a listener header announces, or the
# word "unreadable". No port suffix means 443, the vendor's own default and the
# only port this adapter reports on.
#
# Three answers rather than two, because the short version could only ever return
# a port, and so had to invent one for a header it could not read. It took the
# text after the last colon, which is not where a port lives in either direction:
#
#   https://[2001:db8::1] (tailnet only)        -> "1]",  so a real 443 listener
#                                                  read as non-443, the whole body
#                                                  read as absent, and absent is
#                                                  what lets harbor pair create a
#                                                  mapping on a node that already
#                                                  had one.
#   https://node:8443/path:443 (tailnet only)   -> "443", so an 8443 listener was
#                                                  mistaken for the 443 one and
#                                                  its target reported as the
#                                                  mapping Harbor would compare.
#
# So this parses the authority: everything between the scheme and the
# parenthesized suffix, with a bracketed IPv6 host's port taken only from a colon
# that follows the closing bracket, and a path rejected outright rather than
# scanned for colons. A header that does not reduce to a host and a numeric port
# answers "unreadable", and the walker turns that into unnormalizable. Guessing a
# port is how a misread header becomes a licence to write.
harbor_serve_header_port() {
  local header="${1:-}" authority host rest port=443
  case "${header}" in
    'https://'*' ('*')') ;;
    *)
      printf 'unreadable'
      return 0
      ;;
  esac
  authority="${header#https://}"
  authority="${authority%% (*}"
  case "${authority}" in
    '' | *[[:space:]]* | */*)
      printf 'unreadable'
      return 0
      ;;
    '['*)
      rest="${authority#'['}"
      case "${rest}" in
        *']'*) ;;
        *)
          printf 'unreadable'
          return 0
          ;;
      esac
      host="${rest%%']'*}"
      rest="${rest#*']'}"
      case "${rest}" in
        '') ;;
        :*) port="${rest#:}" ;;
        *)
          printf 'unreadable'
          return 0
          ;;
      esac
      ;;
    *)
      host="${authority}"
      case "${authority}" in
        *:*)
          host="${authority%:*}"
          port="${authority##*:}"
          ;;
      esac
      ;;
  esac
  if [ -z "${host}" ]; then
    printf 'unreadable'
    return 0
  fi
  case "${port}" in
    '' | *[!0123456789]*) printf 'unreadable' ;;
    *) printf '%s' "${port}" ;;
  esac
}

# harbor_serve_parse: walk the body ONCE and set both HARBOR_SERVE_MAPPING and
# HARBOR_SERVE_FUNNEL. Prints nothing. Requires harbor_serve_status to have run.
#
# One walker for both readings, because two independent readings of the same
# document can disagree, and when they disagreed here the fail-open half won. The
# mapping reader walked listener by listener while the Funnel reader pattern
# matched the whole body, so a body the walker called unnormalizable could still
# answer "no Funnel" -- a body Harbor could not read reported as evidence that
# nothing is exposed -- and the marker text appearing inside a handler path
# answered "Funnel" on a node that had none. Both readings now come from the same
# pass over the same lines, so they cannot contradict each other.
#
# The fail-closed words are the initial values, not a final else. Every arm below
# that cannot explain what it read simply returns, and returning leaves
# unnormalizable/unknown standing. This inverts the earlier shape, where each
# refusal had to remember to print the right word and a missed arm fell through to
# absent. There is now exactly one assignment of absent and one of a mapping, both
# at the end, both reached only after the whole document parsed.
#
# That matters because absent is not a neutral word. It is the ONLY word that
# later lets harbor pair create a Serve mapping, so every path to it has to have
# established that nothing is at 443 -- not merely have failed to notice
# something. A parser that can be confused into absent is a way to authorize a
# mutation by feeding Harbor a body it does not understand.
harbor_serve_parse() {
  HARBOR_SERVE_MAPPING=unnormalizable
  HARBOR_SERVE_FUNNEL=unknown
  local line target='' host port suffix path handler
  local seen443=0 in443=0 in_listener=0 roots=0 lines=0 funnel=none
  [ -n "${HARBOR_SERVE_RAW:-}" ] || return 0
  if [ "${HARBOR_SERVE_RAW:-}" = 'No serve config' ]; then
    HARBOR_SERVE_MAPPING=absent
    HARBOR_SERVE_FUNNEL=none
    return 0
  fi
  # Two guards on the walk itself, because the walk not happening must not read as
  # a walk that found nothing. Bash implements this here-document with a temporary
  # file, so on a filesystem that refuses the create -- a read-only or exhausted
  # /tmp -- the redirection fails, the body never runs, and a node with a perfectly
  # good 443 mapping would otherwise fall through to absent with status 0.
  #
  # The `|| return 0` catches that failure, and the trailing `:` below is what
  # makes it mean only that: a while loop's status is the status of the last
  # command its body ran, so without a deterministic final command the guard would
  # fire or not depending on which arm the last line happened to take, and a later
  # edit that ended an arm with a non-zero test would silently turn the parser into
  # one that refuses every body. `lines` is the independent check on the same
  # question, kept because this is the one failure whose signature is indistinguish
  # able from success.
  while IFS= read -r line; do
    lines=$((lines + 1))
    case "${line}" in
      '') continue ;;
      'https://'*' ('*')')
        port="$(harbor_serve_header_port "${line}")"
        [ "${port}" != unreadable ] || return 0
        in_listener=1
        in443=0
        if [ "${port}" = 443 ]; then
          # A second 443 listener header is not a second chance to find the
          # mapping, it is a document describing 443 twice. Harbor cannot say
          # which one the vendor would act on, and a reader that quietly kept the
          # first would also let a later empty 443 listener inherit the earlier
          # one's target and report a mapping nothing is serving.
          [ "${seen443}" = 0 ] || return 0
          in443=1
          seen443=1
        fi
        suffix="${line#* (}"
        suffix="${suffix%)}"
        case "${suffix}" in
          *'Funnel on'*) funnel=present ;;
        esac
        ;;
      '|--'*)
        # A handler with no listener header above it is a body Harbor cannot
        # account for. Skipping it and falling through to "no 443 header was
        # seen" would report a malformed body as an empty one.
        [ "${in_listener}" = 1 ] || return 0
        # Only `PATH proxy TARGET` is a shape this adapter has measured. Serve
        # has other handler kinds -- static text, a filesystem path -- whose
        # printed form Harbor has never seen, so they are refused rather than
        # guessed at, and refused under every listener rather than only under
        # 443. The earlier reader treated any line beginning `|--` that it did
        # not recognize as a handler it simply had no use for, which meant a
        # document it could not read was walked to the end and answered absent.
        # Being conservative here can only ever cause a refusal; being permissive
        # here is how an unreadable body becomes permission to write.
        case "${line}" in
          '|-- '*' proxy '*) ;;
          *) return 0 ;;
        esac
        handler="${line#'|-- '}"
        path="${handler%%' proxy '*}"
        [ -n "${path}" ] || return 0
        handler="${handler#*' proxy '}"
        case "${handler}" in
          '' | *[[:space:]]*) return 0 ;;
        esac
        if [ "${in443}" = 1 ] && [ "${path}" = / ]; then
          # Every root handler counts, whatever its target, because the question
          # is how many things claim / at 443 -- not how many of them Harbor can
          # describe. Counting only the http ones let a second root handler with
          # another scheme sit beside the first and be reported as if the first
          # were alone.
          roots=$((roots + 1))
          [ "${roots}" = 1 ] || return 0
          case "${handler}" in
            http://*) target="${handler}" ;;
            # Something is at / on 443 and Harbor's mapping vocabulary cannot
            # express it, so the answer is neither absent nor a mapping.
            *) return 0 ;;
          esac
        fi
        ;;
      *) return 0 ;;
    esac
    # Deterministic body status; see the guard note above the loop.
    :
  done <<EOF || return 0
${HARBOR_SERVE_RAW:-}
EOF
  [ "${lines}" -gt 0 ] || return 0
  if [ "${seen443}" = 0 ]; then
    HARBOR_SERVE_MAPPING=absent
    HARBOR_SERVE_FUNNEL="${funnel}"
    return 0
  fi
  # A 443 listener whose handlers never named a root. Something is at 443, so the
  # answer is not absent; Harbor cannot describe it, so it is not a mapping.
  [ -n "${target}" ] || return 0
  host="${target#http://}"
  case "${host}" in
    *:*) ;;
    *) return 0 ;;
  esac
  port="${host##*:}"
  host="${host%:*}"
  case "${port}" in
    '' | *[!0123456789]*) return 0 ;;
  esac
  # The host is spelled out as an allowed set rather than checked for the one or
  # two characters that would obviously break something. This string is about to
  # become a JSON value in the journal, and a target carrying a carriage return
  # or a quote would otherwise be written into an entry that no longer parses --
  # recovery reads those entries, so a body Harbor merely disliked would become a
  # journal Harbor cannot use. Refusing the host here keeps that from being
  # harbor_json_escape's problem to solve.
  case "${host}" in
    '' | *[!abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:\[\]-]*) return 0 ;;
  esac
  # A colon survived the port split, so this is an IPv6 literal and the only
  # spelling Harbor will read is the bracketed one. Unbracketed, there is no
  # answer to which colon was the port, and http://::1:3773 would normalize to
  # the same loopback mapping a well-formed target produces -- agreeing, by
  # accident, with the thing it was supposed to be checked against.
  case "${host}" in
    *:*)
      case "${host}" in
        '['*']') ;;
        *) return 0 ;;
      esac
      ;;
  esac
  host="$(harbor_serve_loopback_host "${host}")"
  HARBOR_SERVE_MAPPING="https:443 -> http://${host}:${port}"
  HARBOR_SERVE_FUNNEL="${funnel}"
}

# harbor_serve_mapping: the normalized HTTPS 443 mapping, "absent", or
# "unnormalizable". harbor_serve_funnel: "none", "present", or "unknown". Both
# require harbor_serve_status to have run.
#
# Each runs the walk itself rather than reading globals a caller was supposed to
# have filled. These are called from inside $( ), which forks, so a walk done by
# the caller would set its globals in the parent and a walk done here would set
# them in a subshell that exits immediately -- either way the reader would be
# printing whatever the last unrelated walk happened to leave behind. Walking
# per call costs one pass over a body that is a handful of lines.
harbor_serve_mapping() {
  harbor_serve_parse
  printf '%s' "${HARBOR_SERVE_MAPPING:-}"
}

harbor_serve_funnel() {
  harbor_serve_parse
  printf '%s' "${HARBOR_SERVE_FUNNEL:-}"
}

# harbor_observe_op_tailscale_serve TARGET: the tailscale-serve op's observer, found
# by harbor_journal_observe under this exact name. It re-reads Serve on every call
# rather than trusting HARBOR_SERVE_RAW: recovery runs long after the write that
# left the entry prepared, and answering from a stale capture would compare the
# entry against the world as it was when Harbor last looked, which is the one
# reading that cannot decide anything.
harbor_observe_op_tailscale_serve() {
  harbor_serve_status
  local escaped
  escaped="$(harbor_json_escape "$(harbor_serve_mapping)")" || return "$?"
  printf '"%s"' "${escaped}"
}
