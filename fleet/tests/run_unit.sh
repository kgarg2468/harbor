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
# so the assertion still runs.
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

# Before any rewriting, and with the caller's arguments exactly as they were given: a
# caller who asks for jobs on a machine without parallel is told so by Bats, which
# owns that dependency, rather than being quietly given a serial lane that answers a
# question they did not ask.
if ! command -v parallel >/dev/null 2>&1; then
  exec /bin/bash "${bats}" --print-output-on-failure "$@"
fi

# A job count the caller named belongs to the concurrent phase, not to a single
# unfiltered run: passing it straight through would put the needs-signals test back
# under parallel, where its INT assertion cannot pass, which is the whole reason the
# serial phase exists. So the flag is lifted out here and reapplied to phase one only.
# Bats takes -j and --jobs with the value as a separate argument and accepts no
# --jobs=N or -jN form, so those two spellings are the whole vocabulary.
# The loop rotates the positional parameters, shifting from the front and appending
# what it keeps, which rewrites the list without an array.
argc="$#"
i=0
want_value=0
caller_gave_jobs=0
caller_jobs=""
while [ "${i}" -lt "${argc}" ]; do
  arg="${1}"
  shift
  i=$((i + 1))
  if [ "${want_value}" = 1 ]; then
    want_value=0
    caller_jobs="${arg}"
    continue
  fi
  case "${arg}" in
    -j | --jobs)
      want_value=1
      caller_gave_jobs=1
      continue
      ;;
  esac
  set -- "$@" "${arg}"
done

# Refused rather than defaulted. The flag has been lifted out of the list by now, so
# falling through to HARBOR_JOBS or the CPU count would run a lane at a concurrency
# nobody asked for and report nothing about it -- and the one reason to name -j by
# hand is to control concurrency while reproducing a failure, which is exactly when a
# silently substituted count makes the result a lie. Enumerated digits rather than
# [0-9], because a bracket range resolves by the locale's collating order.
if [ "${caller_gave_jobs}" = 1 ]; then
  case "${caller_jobs}" in
    '' | 0 | *[!0123456789]*)
      printf '%s: -j takes a positive whole number of jobs, got %s\n' \
        "${0}" "${caller_jobs:-no value}" >&2
      exit 3
      ;;
  esac
fi
jobs="${caller_jobs}"
if [ -z "${jobs}" ]; then
  jobs="${HARBOR_JOBS:-}"
fi
if [ -z "${jobs}" ]; then
  # hw.ncpu on Darwin, nproc on Linux, and one job if neither answers.
  jobs="$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || printf 1)"
fi
case "${jobs}" in
  '' | 0 | *[!0123456789]*) jobs=1 ;;
esac

# One job is not concurrency, so it takes the serial lane whole rather than a
# concurrent phase of one and an empty tag-filtered second pass.
if [ "${jobs}" = 1 ]; then
  exec /bin/bash "${bats}" --print-output-on-failure "$@"
fi

# Both phases run even when the first one fails, because a red concurrent phase is the
# moment the serial result is most worth having, and the exit code is the first
# failure rather than the last phase to finish.
concurrent=0
serial=0
/bin/bash "${bats}" --print-output-on-failure -j "${jobs}" --filter-tags '!needs-signals' "$@" || concurrent="$?"
/bin/bash "${bats}" --print-output-on-failure --filter-tags needs-signals "$@" || serial="$?"
[ "${concurrent}" = 0 ] || exit "${concurrent}"
exit "${serial}"
