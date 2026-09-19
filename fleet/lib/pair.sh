#!/bin/bash
# harbor pair (design sections 3.6 and 5.5). The shape of this file is the point:
# Harbor inspects, decides, and journals a prediction, and only then does the
# vendor run. The vendor's own guard exists and is documented, and Harbor does not
# rely on it -- section 5.5 calls Harbor's pre-check authoritative. A wrapper that
# delegated the decision would be a wrapper that mutates a stranger's Serve
# mapping whenever the vendor's guard changed.

# harbor_pair_precheck STATE_ROOT HOME MAGICDNS: "create", "reuse", or exit 2.
# Nothing here calls the vendor and nothing here touches Serve.
harbor_pair_precheck() {
  local root="${1}" home="${2}" magicdns="${3}" mapping funnel verdict
  harbor_serve_status
  # Funnel first, and in every arm. Section 3.3 makes any public exposure exit 2
  # whoever created it, so it is not a question about this mapping and must not be
  # reachable only through one branch.
  funnel="$(harbor_serve_funnel)"
  case "${funnel}" in
    present)
      harbor_die 2 pair.funnel "this node has a Funnel exposure, which publishes it beyond the tailnet; Harbor's v1 invariant is no public inbound exposure and it never creates or removes a Funnel; inspect it with: tailscale serve status, and remove it yourself with the vendor command it names; nothing was changed"
      ;;
    unknown)
      harbor_die 2 pair.serve_unreadable "Harbor could not read this node's Serve configuration, so it cannot tell whether a Funnel exposure or a foreign mapping exists; inspect it with: tailscale serve status; nothing was changed and t3 pair was not run"
      ;;
  esac
  mapping="$(harbor_serve_mapping)"
  case "${mapping}" in
    absent)
      printf 'create'
      return 0
      ;;
    unnormalizable)
      harbor_die 2 pair.serve_unreadable "this node has a Serve configuration Harbor could not reduce to a comparable HTTPS 443 mapping, so it cannot tell whether the route already fronts this node's T3 server; inspect it with: tailscale serve status; nothing was changed and t3 pair was not run"
      ;;
  esac
  # A mapping exists. Section 5.5: an existing mapping is never a pairing need;
  # the environment check judges it, and it judges it before the vendor runs.
  harbor_pair_environment "${home}" "${magicdns}"
  verdict="${HARBOR_PAIR_VERDICT:-unknown}"
  case "${verdict}" in
    pass) ;;
    broken)
      harbor_die 2 pair.foreign_mapping "this node already has an HTTPS 443 Serve mapping (${mapping}), and it fronts something other than this node's T3 server: ${HARBOR_PAIR_ENVIRONMENT_WHY:-}; Harbor never mutates a Serve mapping it did not create, and minting another pairing token would not change the route; inspect it with: tailscale serve status, remove it with the vendor command that lists it if it is yours; nothing was changed and t3 pair was not run"
      ;;
    *)
      harbor_die 2 pair.environment_unknown "this node already has an HTTPS 443 Serve mapping (${mapping}), and Harbor could not verify what it fronts: ${HARBOR_PAIR_ENVIRONMENT_WHY:-}; an unverified route is not a route Harbor will pair through; inspect with: tailscale serve status; nothing was changed and t3 pair was not run"
      ;;
  esac
  # It fronts this node's own T3 server. Journal it observed, which is the word
  # section 3.7 reserves for state Harbor found correct and did not create. An
  # observed mapping is never converted to created and never removed by teardown.
  harbor_journal_create "${root}" tailscale-serve https-443 observed applied \
    "\"$(harbor_json_escape "${mapping}")\"" "\"$(harbor_json_escape "${mapping}")\"" || exit "$?"
  printf 'reuse'
}

# Capture only the adapter verdict and its non-secret reason in the same
# subshell: capturing the verdict alone loses the reader's reason global.
harbor_pair_environment() {
  local result
  result="$(
    harbor_t3_environment "${1}" "${2}" || exit "$?"
    printf '\n%s' "${HARBOR_T3_ENVIRONMENT_WHY:-}"
  )" || exit "$?"
  # A pass carries no reason, so the separator is the last byte and command
  # substitution strips it. Without this arm the "${result#*\n}" below finds
  # nothing to cut and hands back the whole string, making the reason the word
  # "pass" -- which no caller reads today and every later one would.
  case "${result}" in
    *'
'*)
      HARBOR_PAIR_VERDICT="${result%%'
'*}"
      HARBOR_PAIR_ENVIRONMENT_WHY="${result#*'
'}"
      ;;
    *)
      HARBOR_PAIR_VERDICT="${result}"
      HARBOR_PAIR_ENVIRONMENT_WHY=""
      ;;
  esac
}

# harbor_pair_prediction HOME: the exact normalized mapping the pinned vendor will
# create. Measured, not guessed: the pinned t3 runs
#   tailscale serve --bg --https=443 http://127.0.0.1:<port>
# with servePort defaulting to 443 and localHost to 127.0.0.1, and <port> is the
# port from server-runtime.json. Harbor journals this string as post_state before
# the vendor runs, which is what lets recovery recognize a mapping created just
# before a crash -- there is no other record that the vendor got that far.
harbor_pair_prediction() {
  local port
  harbor_t3_runtime_port "${1}" >/dev/null
  port="${HARBOR_T3_RUNTIME_PORT:-}"
  [ -n "${port}" ] \
    || harbor_die 2 pair.no_server "this node's T3 server could not be located (${HARBOR_T3_RUNTIME_WHY:-}), so Harbor cannot predict the Serve mapping the vendor would create and will not run t3 pair blind; check the service with: harbor service status; nothing was changed"
  printf 'https:443 -> http://loopback:%s' "${port}"
}

# harbor_pair STATE_ROOT HOME MAGICDNS: the whole attended command.
harbor_pair() {
  local root="${1}" home="${2}" magicdns="${3}" decision prediction entry after verdict why rc=0
  decision="$(harbor_pair_precheck "${root}" "${home}" "${magicdns}")" || exit "$?"
  if [ "${decision}" = reuse ]; then
    harbor_msg "pair: this node already publishes its own T3 server over HTTPS 443 on the tailnet, and the environment check confirms the route reaches it; no pairing token was minted and Serve was not touched — open the environment in T3 Code, or mint a fresh token yourself with: t3 pair --tailscale"
    return 0
  fi
  prediction="$(harbor_pair_prediction "${home}")" || exit "$?"
  harbor_journal_create "${root}" tailscale-serve https-443 created prepared \
    '"absent"' "\"$(harbor_json_escape "${prediction}")\"" || exit "$?"
  entry="${HARBOR_JOURNAL_ENTRY}"
  harbor_step "pair-prepared"
  harbor_msg "pair: running t3 pair --tailscale below; its pairing URL and QR code go straight to your terminal and Harbor neither captures nor stores them"
  # Streams untouched: section 3.6 requires the vendor's output to pass straight to
  # the terminal "without capturing or delaying it", and a one-time pairing token
  # that reached a Harbor variable would be a token in a place section 3.8 forbids.
  harbor_pair_vendor "${home}" || rc="$?"
  [ "${HARBOR_PAIR_VENDOR_STOPPED:-}" = yes ] \
    || harbor_die 2 pair.vendor_running "the vendor could not be stopped; $(basename "${entry}") stays prepared; inspect with: tailscale serve status"
  harbor_step "pair-vendor"
  harbor_serve_status
  after="$(harbor_serve_mapping)"
  if [ "${after}" = absent ]; then
    # A timeout is the one arm where "nothing is there" is not yet a conclusion.
    # The vendor's surviving child is what hangs, and it can still apply the
    # mapping after this read. Reverting here would be a claim that nothing
    # happened, and recovery skips reverted entries -- so a mapping this command
    # caused would be met by a later run, found to front this node, and journaled
    # observed, which teardown never removes. Harbor would have created a mapping
    # and recorded it as a stranger's.
    #
    # Leaving it prepared says the true thing: Harbor does not know yet. Recovery
    # decides it against the world on the next run -- the prediction appeared, so
    # applied and owned created; or it did not, so reverted -- and that is the
    # question recovery exists to answer.
    if [ "${rc}" = 124 ]; then
      harbor_pair_check_funnel
      harbor_die 2 pair.vendor_timeout "t3 pair --tailscale did not finish within the time Harbor allows it and was stopped, and no HTTPS 443 mapping is there yet; the vendor's own Tailscale child may still be working, so Harbor will not claim nothing happened; $(basename "${entry}") stays prepared and the next Harbor run decides it against what is actually there; inspect with: tailscale serve status"
    fi
    harbor_journal_set_phase "${entry}" reverted || exit "$?"
    harbor_pair_check_funnel
    # Exit 2, not the vendor's own code. The plan wrote harbor_die "${rc}" here,
    # which is wrong in both directions: a vendor that exits 0 having created
    # nothing would make Harbor exit 0 and call a failed pair a success, and the
    # timeout path would exit 124, which is not one of Harbor's five codes at all.
    # Serve was meant to be mutated and was not, which is exactly what 2 means.
    # The vendor's own status stays in the message, where it is diagnostic.
    case "${rc}" in
      0) why="reported success but left no HTTPS 443 mapping" ;;
      *) why="exited ${rc} and left no HTTPS 443 mapping" ;;
    esac
    harbor_die 2 pair.vendor_failed "the vendor could not publish this node over Tailscale Serve: t3 pair --tailscale ${why}; its own output above says why; $(basename "${entry}") is reverted and rerunning is safe: harbor pair"
  fi
  if [ "${after}" != "${prediction}" ]; then
    # Section 3.7's undecidable case: something is at 443 and it is not what Harbor
    # said would be. Print both sides and stop; reconciliation is the runbook's.
    harbor_msg "pair: Harbor predicted ${prediction}"
    harbor_msg "pair: the node now has ${after}"
    harbor_die 2 pair.undecidable "the HTTPS 443 mapping after t3 pair --tailscale is not the one Harbor predicted, so Harbor cannot tell whether the vendor created it or something else did, and it will not claim ownership of a mapping it cannot account for; $(basename "${entry}") stays prepared; inspect with: tailscale serve status, and when you have decided, resolve the entry with: harbor journal resolve $(basename "${entry}" .json | sed 's/-.*//') --reverted; Harbor made no further changes"
  fi
  harbor_journal_set_phase "${entry}" applied || exit "$?"
  harbor_pair_check_funnel
  harbor_pair_environment "${home}" "${magicdns}"
  verdict="${HARBOR_PAIR_VERDICT:-unknown}"
  case "${verdict}" in
    pass)
      harbor_msg "pair: this node now publishes its own T3 server over HTTPS 443 on the tailnet, and the environment check confirms the route reaches it; recorded as $(basename "${entry}")"
      return 0
      ;;
    unknown)
      harbor_die 1 pair.environment_unknown "the mapping Harbor predicted was created and recorded as $(basename "${entry}"), but the route could not be checked: ${HARBOR_PAIR_ENVIRONMENT_WHY:-}; this is not a verified pass, and it may simply be a tailnet that has not settled — retry the check with: harbor status"
      ;;
  esac
  harbor_die 2 pair.environment_broken "the mapping Harbor predicted was created and recorded as $(basename "${entry}"), but the route does not reach this node's T3 server: ${HARBOR_PAIR_ENVIRONMENT_WHY:-}; inspect with: tailscale serve status"
}

# Recheck exposure after the vendor too, including exposure on a different port.
# The mapping's journal transition precedes this refusal so ownership is retained.
harbor_pair_check_funnel() {
  case "$(harbor_serve_funnel)" in
    none) return 0 ;;
    present) harbor_die 2 pair.funnel "this node has a Funnel exposure; inspect with: tailscale serve status; Harbor made no further changes" ;;
    *) harbor_die 2 pair.serve_unreadable "Harbor could not rule out public exposure after pairing; inspect with: tailscale serve status" ;;
  esac
}

# The same pinned-version guard as harbor_t3_run, followed by exec in the child:
# $! must identify the vendor itself, not a shell waiting for it. A five-minute
# ceiling is far beyond the vendor's 10s Serve and 2500ms probe deadlines.
# Only tests may shorten it. A fixed short sleep keeps fast exits responsive;
# both the deadline loop and termination grace are bounded independently.
#
# The signal reaches the vendor, not its descendants, and the thing measured
# hanging was `tailscale serve --bg` -- which the vendor spawns. So an expiry can
# leave that child alive and able to mutate Serve after Harbor has already read
# the world and decided. Putting the vendor in its own process group would let
# one signal reach the whole tree, and is rejected: a background process group
# takes SIGTTIN the moment it reads the terminal, and section 3.6 requires the
# vendor's pairing prompt to reach the operator. The residue is bounded instead
# of eliminated -- a late mutation leaves the entry prepared with the prediction
# in it, which is exactly the state recovery exists to decide.
harbor_pair_vendor() {
  local home="${1}" bin locked installed pid deadline ceiling=300 rc=0 i=0
  HARBOR_PAIR_VENDOR_STOPPED=yes
  bin="$(harbor_t3_bin "${home}")"
  locked="$(harbor_version_require t3_version)" || return "$?"
  installed="$(harbor_t3_installed_version "${home}")" || return "$?"
  [ "${installed}" = "${locked}" ] \
    || harbor_die 3 t3.version_mismatch "${bin} reports ${installed}, but the lock requires ${locked}; run harbor provision before invoking t3"
  if [ "${HARBOR_TEST_HOOKS:-}" = 1 ]; then
    ceiling="${HARBOR_PAIR_TIMEOUT_SECONDS:-300}"
  fi
  harbor_log_vendor "${bin}" pair --tailscale
  # <&0 preserves the caller's existing stdin: without this explicit inheritance,
  # bash silently attaches /dev/null to an asynchronous command. No input is
  # supplied by Harbor, and neither output stream is redirected or captured.
  (exec "${bin}" pair --tailscale) <&0 &
  pid=$!
  HARBOR_PAIR_VENDOR_STOPPED=no
  deadline=$((SECONDS + ceiling))
  while kill -0 "${pid}" 2>/dev/null; do
    if [ "${SECONDS}" -ge "${deadline}" ]; then
      rc=124
      kill -TERM "${pid}" 2>/dev/null || :
      break
    fi
    sleep 0.05
  done
  if [ "${rc}" = 124 ]; then
    while kill -0 "${pid}" 2>/dev/null && [ "${i}" -lt 20 ]; do
      sleep 0.05
      i=$((i + 1))
    done
    kill -KILL "${pid}" 2>/dev/null || :
    i=0
    while kill -0 "${pid}" 2>/dev/null && [ "${i}" -lt 20 ]; do
      sleep 0.05
      i=$((i + 1))
    done
    # Never wait for a process still alive after the bounded grace.
    kill -0 "${pid}" 2>/dev/null && return 124
    wait "${pid}" 2>/dev/null || :
  else
    wait "${pid}" || rc="$?"
  fi
  HARBOR_PAIR_VENDOR_STOPPED=yes
  return "${rc}"
}

# Kept in this slice's library because lib/tailscale.sh is outside its allowlist.
# Slice 5e can move this reader without changing its interface.
harbor_tailscale_magicdns() {
  local body name
  body="$(tailscale status --json 2>/dev/null)" || return 1
  name="$(printf '%s\n' "${body}" | tr -d '\n' \
    | sed -n 's/.*"Self"[ ]*:[ ]*{[^}]*"DNSName"[ ]*:[ ]*"\([^"]*\)".*/\1/p')"
  name="${name%.}"
  [ -n "${name}" ] || return 1
  printf '%s' "${name}"
}

harbor_pair_cmd() {
  local root home mode magicdns
  [ "$#" -eq 0 ] || harbor_die 3 usage "usage: harbor pair"
  harbor_auth_refuse_root
  home="${HOME}"
  mode="$(harbor_config_access_mode "${home}")" || exit "$?"
  [ "${mode}" = tailnet ] \
    || harbor_die 3 pair.wrong_mode "this node's access_mode=${mode}; switch modes with: harbor access set tailnet; nothing was changed"
  # The actual gate belongs to slice 5e; its absence cannot open tailnet access.
  command -v harbor_access_require_tailnet_supported >/dev/null 2>&1 \
    || harbor_die 3 pair.unsupported "tailnet access is unsupported by this release until the tailnet support gate is available; nothing was changed"
  harbor_access_require_tailnet_supported || exit "$?"
  root="${home}/.local/state/harbor"
  harbor_state_root_create "${root}" operator
  harbor_log_open "${root}/harbor.log" 0600
  harbor_log command pair
  harbor_lock_acquire "${root}" operator
  harbor_journal_init "${root}"
  # shellcheck disable=SC2034
  HARBOR_AGENTS_HOME="${home}"
  harbor_versions_load "$(harbor_versions_lock_path)"
  harbor_journal_recover "${root}"
  harbor_step recovery-scan
  magicdns="$(harbor_tailscale_magicdns)" \
    || harbor_die 3 pair.no_magicdns "this node has no MagicDNS name; log in with: harbor auth tailscale, and confirm MagicDNS is enabled; nothing was changed"
  harbor_pair "${root}" "${home}" "${magicdns}"
}
