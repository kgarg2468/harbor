#!/bin/bash
# Kill a real bootstrap at one row boundary and prove the next run converges
# (design sections 3.7 and 6.1). One boundary per invocation, one job per
# boundary, each on its own ephemeral runner, because this release ships no
# teardown command and a node cannot be put back to a pre-bootstrap state once a
# row has run.
#
# Usage: fleet/tests/integration/converge.sh <step>
#   step   a harbor_step boundary name, for example user-created or
#          tailscale-operator-set. The step names are Harbor's own; the workflow
#          matrix names one per row of the design section 5.2 table.
#
# The sequence is:
#   1. sudo env ... HARBOR_TEST_HOOKS=1 HARBOR_FAIL_AFTER=<step> ... bootstrap
#      which SIGKILLs itself at that boundary, leaving whatever the crash left.
#   2. a plain rerun, no hook variable in the environment at all, which must
#      exit 0.
#   3. the whole first-run assertion set, so convergence means the node really is
#      the node a clean bootstrap produces and not merely a zero exit.
#   4. the idempotency assertion, so a node that converged after a crash also
#      stays converged.
#
# Runs as the unprivileged workflow user.
set -euo pipefail

# shellcheck source=lib/common.sh
. "$(cd "$(dirname "${0}")" && pwd -P)/lib/common.sh"

step="${1:?usage: converge.sh <harbor step name>}"

[ "$(id -u)" != 0 ] || {
  printf 'converge.sh runs as the workflow user, not as root\n' >&2
  exit 1
}

section() {
  printf '\n-- %s\n' "${*}"
}

# ---------------------------------------------------------------------------
section "kill the first bootstrap at ${step}"
# ---------------------------------------------------------------------------
rc=0
"${IT_INTEGRATION}/run_root.sh" --fail-after "${step}" --from checkout || rc="$?"
case "${rc}" in
  137) it_pass "the run was SIGKILLed at ${step} (exit 137)" ;;
  4) it_pass "the run stopped at ${step} with the hook's own exit 4" ;;
  0) it_fail "the run finished normally, so ${step} is not a boundary this bootstrap reaches" ;;
  *) it_fail "the run exited ${rc} at ${step}, which is neither the SIGKILL 137 nor the hook's 4" ;;
esac

# ---------------------------------------------------------------------------
section 'what the crash left behind'
# ---------------------------------------------------------------------------
if sudo test -d "${IT_HARBOR_JOURNAL}"; then
  rc=0
  phase_lines="$(sudo grep -rh '"phase"' "${IT_HARBOR_JOURNAL}")" || rc="$?"
  if [ "${rc}" = 0 ]; then
    printf 'journal phases after the crash:\n'
    printf '%s\n' "${phase_lines}" | sed 's/.*: *"//; s/".*//' | LC_ALL=C sort | uniq -c
  else
    printf 'the journal directory exists and holds no entry yet\n'
  fi
else
  printf 'no journal yet: the crash came before the state root was populated\n'
fi
if sudo test -d "${IT_HARBOR_STATE}/lock.d"; then
  printf 'the root lock is still held by the killed process, as a SIGKILL leaves it\n'
fi

# ---------------------------------------------------------------------------
section 'the rerun, with no hook variable passed to root at all'
# ---------------------------------------------------------------------------
rc=0
"${IT_INTEGRATION}/run_root.sh" --from auto || rc="$?"
it_eq "the rerun after a crash at ${step} exits 0" 0 "${rc}"

if sudo test -d "${IT_HARBOR_STATE}/lock.d"; then
  it_fail 'the root lock is still held after the rerun; the stale holder was not reclaimed'
else
  it_pass 'the stale root lock was reclaimed and released'
fi

it_done "converge (${step}), before the full assertions"

# ---------------------------------------------------------------------------
section 'the converged node is the node a clean bootstrap produces'
# ---------------------------------------------------------------------------
sudo bash "${IT_INTEGRATION}/assert_bootstrap.sh" --after-recovery
"${IT_INTEGRATION}/assert_rerun.sh"
