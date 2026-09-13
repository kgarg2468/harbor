#!/bin/bash
# Run the Harbor unit lane exactly as test.yml does. On macOS, Bats runs under the
# system /bin/bash 3.2 by putting /bin and /usr/bin first on PATH, which is what the
# pinned macos-14 runner enforces. Usage: tests/run_unit.sh [bats arguments]
# With no arguments, runs every test under tests/unit recursively.
#
# The lane runs in two phases where GNU parallel is installed, because Bats implements
# --jobs by shelling out to it and refuses the flag without it. Phase one runs every
# test that does not need a signal disposition of its own, concurrently. Phase two
# runs the needs-signals tests serially: parallel starts each job with SIGINT ignored
# so a Ctrl-C at the terminal cannot kill the fleet, an ignored signal cannot be
# trapped or reset by the shell that inherits it, and a test that asserts Harbor's INT
# handling therefore cannot run under parallel at all. Two phases rather than a skip,
# so the assertion still runs somewhere.
#
# Where parallel is absent there is a single serial phase, byte for byte the lane that
# ran before this script learned about jobs. That is the case CI runners must survive
# without anyone checking what their images ship, and it is also what HARBOR_JOBS=1
# selects for anyone reproducing a failure without concurrency in the way.
set -euo pipefail
root="$(cd "$(dirname "${0}")/.." && pwd -P)"
case "$(uname -s)" in
  Darwin)
    PATH="/bin:/usr/bin:${PATH}"
    export PATH
    ;;
esac
bats="${root}/tests/vendor/bats-core/bin/bats"
if [ "$#" -eq 0 ]; then
  set -- -r "${root}/tests/unit"
fi

# A caller who named a job count is answered with it, phases and all: passing --jobs
# through to the parallel phase and leaving the serial one alone would silently ignore
# half of what was asked for.
caller_chose_jobs=0
for arg in "$@"; do
  case "${arg}" in
    --jobs | -j | -j?*) caller_chose_jobs=1 ;;
  esac
done

jobs="${HARBOR_JOBS:-}"
if [ -z "${jobs}" ]; then
  # hw.ncpu on Darwin, nproc on Linux, and one job if neither answers. Enumerated
  # digits rather than [0-9], because a bracket range resolves by the locale's
  # collating order and this value goes on to a command line.
  jobs="$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || printf 1)"
fi
case "${jobs}" in
  '' | 0 | *[!0123456789]*) jobs=1 ;;
esac

if [ "${caller_chose_jobs}" = 1 ] || [ "${jobs}" = 1 ] || ! command -v parallel >/dev/null 2>&1; then
  exec /bin/bash "${bats}" --print-output-on-failure "$@"
fi

# Both phases run even when the first one fails, because a red parallel phase is the
# moment the serial result is most worth having, and the exit code is the first
# failure rather than the last phase to finish.
concurrent=0
serial=0
/bin/bash "${bats}" --print-output-on-failure -j "${jobs}" --filter-tags '!needs-signals' "$@" || concurrent="$?"
/bin/bash "${bats}" --print-output-on-failure --filter-tags needs-signals "$@" || serial="$?"
[ "${concurrent}" = 0 ] || exit "${concurrent}"
exit "${serial}"
