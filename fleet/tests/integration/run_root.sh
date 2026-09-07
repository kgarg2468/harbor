#!/bin/bash
# The one place the integration lane becomes root. Every root-phase run in this
# lane goes through here, so there is a single call site to read when asking how
# a test hook reaches root.
#
# The rule of design section 7, kept exactly: root NEVER inherits the caller's
# environment. There is no sudo -E anywhere in this lane and no sudoers env_keep
# for HARBOR_TEST_HOOKS, HARBOR_FAIL_AFTER, HARBOR_PAUSE_AFTER, HARBOR_PID or
# TMPDIR. Each variable root is to see is named literally in the sudo env
# argument list below, and a run without --fail-after passes no hook variable at
# all, so HARBOR_TEST_HOOKS is not even set and harbor_test_hook returns at its
# first line.
#
# Usage:
#   run_root.sh [--fail-after STEP] [--from auto|checkout|installed] [-- ARG...]
# Prints the exact argument vector it runs, then runs it and exits with its
# status. A killed run exits 137 and that is the caller's to assert.
set -euo pipefail

# shellcheck source=lib/common.sh
. "$(cd "$(dirname "${0}")" && pwd -P)/lib/common.sh"

fail_after=""
from=auto
while [ "$#" -gt 0 ]; do
  case "${1}" in
    --fail-after)
      fail_after="${2:?--fail-after needs a step name}"
      shift 2
      ;;
    --from)
      from="${2:?--from needs auto, checkout or installed}"
      shift 2
      ;;
    --)
      shift
      break
      ;;
    *)
      printf 'run_root.sh: unknown option %s\n' "${1}" >&2
      exit 1
      ;;
  esac
done

case "${from}" in
  auto)
    if [ -x "${IT_LINK}" ]; then
      entrypoint="${IT_LINK}"
    else
      entrypoint="${IT_FLEET}/bin/harbor"
    fi
    ;;
  installed) entrypoint="${IT_LINK}" ;;
  checkout) entrypoint="${IT_FLEET}/bin/harbor" ;;
  *)
    printf 'run_root.sh: --from must be auto, checkout or installed\n' >&2
    exit 1
    ;;
esac
[ -x "${entrypoint}" ] || {
  printf 'run_root.sh: %s is not executable\n' "${entrypoint}" >&2
  exit 1
}

scenario="$(cat "${IT_SCENARIO_FILE}")"
# Through tee, as every other write into the lane's state directory is: that directory
# is root-owned and this script runs as the unprivileged workflow user, reaching for
# sudo one action at a time rather than holding it.
printf '%s\n' "${entrypoint}" | sudo tee "${IT_ENTRYPOINT_FILE}" >/dev/null

# The argument vector, built as an array so that every variable root is given is
# one literal element of the sudo env list and nothing is word-split into it.
argv=(sudo env
  "PATH=${IT_PATH}"
  "HARBOR_SHIM_LOG=${IT_SHIM_LOG}"
  "HARBOR_SHIM_SCENARIO=${scenario}")
if [ -n "${fail_after}" ]; then
  argv+=("HARBOR_TEST_HOOKS=1" "HARBOR_FAIL_AFTER=${fail_after}")
fi
argv+=("${entrypoint}" bootstrap)
if [ "$#" -gt 0 ]; then
  argv+=("$@")
fi

printf '\n+ %s\n' "${argv[*]}"
rc=0
"${argv[@]}" || rc="$?"
printf '+ exit %s\n' "${rc}"
exit "${rc}"
