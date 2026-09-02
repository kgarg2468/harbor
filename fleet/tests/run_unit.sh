#!/bin/bash
# Run the Harbor unit lane exactly as test.yml does. On macOS, Bats runs under the
# system /bin/bash 3.2 by putting /bin and /usr/bin first on PATH, which is what the
# pinned macos-14 runner enforces. Usage: tests/run_unit.sh [bats arguments]
# With no arguments, runs every test under tests/unit recursively.
set -euo pipefail
root="$(cd "$(dirname "${0}")/.." && pwd -P)"
case "$(uname -s)" in
  Darwin)
    PATH="/bin:/usr/bin:${PATH}"
    export PATH
    ;;
esac
if [ "$#" -eq 0 ]; then
  set -- -r "${root}/tests/unit"
fi
exec /bin/bash "${root}/tests/vendor/bats-core/bin/bats" --print-output-on-failure "$@"
