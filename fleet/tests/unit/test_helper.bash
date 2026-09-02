#!/bin/bash
# Shared Bats setup for Harbor unit tests: repository paths, bats-support and
# bats-assert, library loading, and disposable fixture roots and journal entries.
bats_require_minimum_version 1.5.0

HARBOR_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
export HARBOR_ROOT
HARBOR="${HARBOR_ROOT}/bin/harbor"

load "${HARBOR_ROOT}/tests/vendor/bats-support/load"
load "${HARBOR_ROOT}/tests/vendor/bats-assert/load"

harbor_load_libs() {
  # shellcheck source=lib/log.sh
  . "${HARBOR_ROOT}/lib/log.sh"
  # shellcheck source=lib/checks.sh
  . "${HARBOR_ROOT}/lib/checks.sh"
  # shellcheck source=lib/versions.sh
  . "${HARBOR_ROOT}/lib/versions.sh"
  # shellcheck source=lib/lock.sh
  . "${HARBOR_ROOT}/lib/lock.sh"
  # shellcheck source=lib/journal.sh
  . "${HARBOR_ROOT}/lib/journal.sh"
}

fixture_home() {
  # A disposable HOME whose operator state root is FIX_ROOT (not created yet).
  FIX_HOME="${BATS_TEST_TMPDIR}/home"
  FIX_ROOT="${FIX_HOME}/.local/state/harbor"
  mkdir -p "${FIX_HOME}"
}

fixture_state_root() {
  # FIX_ROOT with an empty journal, as a command would leave it.
  fixture_home
  mkdir -p "${FIX_ROOT}/journal"
  chmod 0700 "${FIX_ROOT}" "${FIX_ROOT}/journal"
}

fixture_entry() {
  # fixture_entry ROOT SEQ OP TARGET OWNERSHIP PHASE PRE_JSON POST_JSON
  mkdir -p "${1}/journal"
  printf '{\n  "op": "%s",\n  "target": "%s",\n  "ownership": "%s",\n  "phase": "%s",\n  "pre_state": %s,\n  "post_state": %s\n}\n' \
    "${3}" "${4}" "${5}" "${6}" "${7}" "${8}" >"${1}/journal/${2}-${3}.json"
}

fixture_undecidable_file_entry() {
  # fixture_undecidable_file_entry ROOT SEQ: a prepared file entry whose target
  # matches neither "absent" nor its recorded post_state. Sets FIX_ARTIFACT_<SEQ>.
  # Requires harbor_load_libs (uses harbor_observe_file).
  local artifact post
  artifact="${BATS_TEST_TMPDIR}/artifact-${2}"
  printf 'one\n' >"${artifact}"
  post="$(harbor_observe_file "${artifact}")"
  printf 'two\n' >"${artifact}"
  fixture_entry "${1}" "${2}" file "${artifact}" created prepared '"absent"' "${post}"
  eval "FIX_ARTIFACT_${2}=\"\${artifact}\""
}

entry_phase() {
  # entry_phase ROOT SEQ
  sed -n 's/^  "phase": "\(.*\)",*$/\1/p' "${1}/journal/${2}"-*.json
}

entry_raw() {
  # entry_raw ROOT SEQ KEY: the raw JSON value on the KEY line
  sed -n "s/^  \"${3}\": \(.*\),*\$/\1/p" "${1}/journal/${2}"-*.json | sed 's/,$//'
}

resolve_cmd() {
  # resolve_cmd TYPED SEQ [ENV=VALUE...]: the public command with TYPED on stdin.
  # A here-string rather than a pipe, so no pipeline subshell sits between the
  # caller and bin/harbor. Callers must not assume "resolve_cmd ... &" gives $!
  # of the harbor process: backgrounding a function forks a subshell first, and
  # $! is that subshell, not the env-exec'd harbor. Every planned call runs under
  # Bats "run". Background pause tests launch "env ... ${HARBOR}" directly (env
  # execs it, so $! is harbor) or read the PID from the holder record (holder_pid).
  local typed="${1}" seq="${2}"
  shift 2
  env HOME="${FIX_HOME}" HARBOR_DEV=1 ${1+"$@"} "${HARBOR}" journal resolve "${seq}" --reverted <<<"${typed}"
}

pause_sentinel() {
  # pause_sentinel PID STEP: the file harbor_test_hook (Task 4) waits for when the
  # process with top-level PID is paused at STEP. Same derivation as lib/log.sh.
  local dir="${TMPDIR:-/tmp}"
  printf '%s/harbor-pause.%s.%s' "${dir%/}" "${1}" "${2}"
}

holder_pid() {
  # holder_pid ROOT: the pid recorded in ROOT/lock.d/holder
  sed -n 's/^pid=//p' "${1}/lock.d/holder"
}

resume_holder() {
  # resume_holder ROOT STEP: create the sentinel that resumes ROOT's current holder,
  # discovering its PID from the holder record as an integration fixture would
  touch "$(pause_sentinel "$(holder_pid "${1}")" "${2}")"
}

wait_for_log_step() {
  # wait_for_log_step ROOT STEP: poll the command log until a step line appears
  local i=0
  until grep -q "step ${2}\$" "${1}/harbor.log" 2>/dev/null; do
    i=$((i + 1))
    [ "${i}" -le 100 ] || return 1
    sleep 0.1
  done
}

wait_for_one_exit() {
  # wait_for_one_exit PID PID: return once either process has exited
  local i=0
  while kill -0 "${1}" 2>/dev/null && kill -0 "${2}" 2>/dev/null; do
    i=$((i + 1))
    [ "${i}" -le 100 ] || return 1
    sleep 0.1
  done
}

holder_record() {
  # holder_record PID START_TIME [CMDLINE]: a holder file body for another process.
  # Requires harbor_load_libs (uses harbor_lock_boot_id).
  printf 'hostname=%s\nboot_id=%s\npid=%s\nstart_time=%s\ncmdline=%s\n' \
    "$(uname -n)" "$(harbor_lock_boot_id)" "${1}" "${2}" "${3:-fixture}"
}
