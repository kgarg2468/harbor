#!/usr/bin/env bats
load '../test_helper'

# lib/auth.sh: harbor auth tailscale, the attended login of design sections 3.6 and 5.3,
# and the --ssh feature gate. The state root is the fixture operator root under this
# test's disposable HOME, the state record and the probe record are fixture files
# written inline, and every tailscale call is the PR 2 shim behind a wrapper that
# models what a real up does to a real daemon: a successful up rewrites the status
# fixture the next read answers from. Nothing here reads or writes /var/lib, /etc,
# /usr/local, /opt, or the real operator state root, and nothing runs sudo.
TAB="$(printf '\t')"

setup() {
  # shellcheck source=lib/log.sh
  . "${HARBOR_ROOT}/lib/log.sh"
  # shellcheck source=lib/lock.sh
  . "${HARBOR_ROOT}/lib/lock.sh"
  # shellcheck source=lib/versions.sh
  . "${HARBOR_ROOT}/lib/versions.sh"
  # shellcheck source=lib/journal.sh
  . "${HARBOR_ROOT}/lib/journal.sh"
  # shellcheck source=lib/entrypoint.sh
  . "${HARBOR_ROOT}/lib/entrypoint.sh"
  # lib/state.sh is sourced for its renderer alone, so the record this test reads is
  # byte for byte what the State record row of design section 5.2 writes.
  # shellcheck source=lib/state.sh
  . "${HARBOR_ROOT}/lib/state.sh"
  # shellcheck source=lib/auth.sh
  . "${HARBOR_ROOT}/lib/auth.sh"
  # The operator state root is not created here: creating it is the command's own job
  # (design section 3.7), and one test asserts exactly that.
  fixture_home
  HARBOR_PID="$$"
  HARBOR_CMDLINE="harbor auth tailscale"
  FX="${BATS_TEST_TMPDIR}/fx"
  HARBOR_SHIM_FIXTURES="${FX}"
  export HARBOR_SHIM_FIXTURES
  HARBOR_SHIM_LOG="${BATS_TEST_TMPDIR}/shim.log"
  export HARBOR_SHIM_LOG
  # The shim answers and logs from behind a wrapper of this test's own: a successful
  # tailscale up copies the after-up fixture over the status fixture, which is the
  # one effect a real login has that this library goes on to read.
  BIN="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "${BIN}/shim"
  ln -s "${HARBOR_ROOT}/tests/shims/bin/harbor-shim" "${BIN}/shim/tailscale"
  cat >"${BIN}/tailscale" <<EOF
#!/bin/bash
"${BIN}/shim/tailscale" "\$@" || exit "\$?"
if [ "\${1:-}" = up ] && [ -f "${FX}/after-up.out" ]; then
  cp "${FX}/after-up.out" "${FX}/tailscale/healthy/status_--json.out"
  cp "${FX}/after-up.exit" "${FX}/tailscale/healthy/status_--json.exit"
fi
EOF
  chmod 0755 "${BIN}/tailscale"
  PATH="${BIN}:${PATH}"
  export PATH
  # The locked value comes from the real lock file, never from this test.
  harbor_versions_load "$(harbor_versions_lock_path)"
  LOCKED="$(harbor_version_require tailscale_version)"
  RECORD="${BATS_TEST_TMPDIR}/var-lib-harbor/bootstrap.json"
  PROBE="${BATS_TEST_TMPDIR}/tailscale-ssh.probe"
  SHIPPED="${HARBOR_ROOT}/vendor-smoke/tailscale-ssh.probe"
  OP=harbor
  UP="tailscale up --hostname=harbor-node"
  # What the vendor prints for an attended login. The URL is a fixture and the only
  # place it may ever appear is the terminal the vendor printed it to.
  URL="https://login.tailscale.com/a/fixture0000"
}

teardown() {
  # A function under test that took the lock inside a run subshell never reached the
  # EXIT trap that releases it; the holder names this process, so it is released here.
  harbor_lock_release "${FIX_ROOT}" 2>/dev/null || true
}

# ---- fixture writers ------------------------------------------------------------

key() {
  # key ARG...: the shim's fixture key for an argv (see tests/shims/bin/harbor-shim)
  printf '%s' "$*" | tr ' /' '_%'
}

fx() {
  # fx NAME KEY [EXIT]: the healthy reply of shim NAME to KEY, body from stdin
  mkdir -p "${FX}/${1}/healthy"
  cat >"${FX}/${1}/healthy/${2}.out"
  printf '%s\n' "${3:-0}" >"${FX}/${1}/healthy/${2}.exit"
}

record() {
  # record OWNERSHIP SSH: the state record of design section 5.2 as lib/state.sh
  # renders it, with the Tailscale ownership and the recorded tailscale-ssh flag.
  local flags
  flags="operator=${OP} authorized-key-source=/home/ubuntu/.ssh/authorized_keys adopt-firewall=no adopt-tailscale=no allow-lan-ssh=no harden-sshd=no tailscale-ssh=${2}"
  mkdir -p "$(dirname "${RECORD}")"
  harbor_state_record_render v0.3.0 "${BATS_TEST_TMPDIR}/usr/local/bin/harbor" \
    3b1f9e2c4d5a6b7c8d9e0f1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e "${flags}" \
    24.20.0 "${1}" "${LOCKED}" "${OP}" 4242 4243 /home/harbor 20260906T000000Z >"${RECORD}"
}

probe() {
  # probe RESULT [VERSION]: a vendor-smoke record with RESULT for VERSION (the lock's
  # by default)
  cat >"${PROBE}" <<EOF
# fixture probe record
date=2026-09-06
tailscale_version=${2:-${LOCKED}}
result=${1}
note=fixture
EOF
}

backend_json() {
  # backend_json STATE: the status --json body carrying BackendState STATE
  printf '{\n  "Version": "%s-fixture",\n  "BackendState": "%s",\n  "Self": {"HostName": "harbor-node"}\n}\n' "${LOCKED}" "${1}"
}

backend() {
  # backend STATE: the operator's tailscale status --json carries BackendState STATE
  backend_json "${1}" | fx tailscale "$(key status --json)"
}

status_fails() {
  fx tailscale "$(key status --json)" 1 <<EOF
Access denied: watch IPN bus access denied, must set --operator or be root
EOF
}

after_up() {
  # after_up STATE: what status --json answers once up has succeeded
  backend_json "${1}" >"${FX}/after-up.out"
  printf '0\n' >"${FX}/after-up.exit"
}

after_up_fails() {
  printf 'failed to connect to local tailscaled\n' >"${FX}/after-up.out"
  printf '1\n' >"${FX}/after-up.exit"
}

up_ok() {
  # up_ok [--ssh]: the vendor prints the login URL and, once approved, exits 0
  fx tailscale "$(key up --hostname=harbor-node ${1+"$@"})" <<EOF

To authenticate, visit:

	${URL}

Success.
EOF
}

up_refused() {
  # up_refused [--ssh]: the daemon refuses the operator's write for lack of authority
  fx tailscale "$(key up --hostname=harbor-node ${1+"$@"})" 1 <<EOF
Access denied: tailscale up: access denied: not the operator or root
EOF
}

auth() {
  # auth [flag...]: the command in this process, then the lock released for the next
  run harbor_auth_tailscale "${FIX_ROOT}" "${RECORD}" "${PROBE}" "${LOCKED}" ${1+"$@"}
  harbor_lock_release "${FIX_ROOT}" 2>/dev/null || true
}

harbor_cmd() {
  # harbor_cmd ARG...: the public command against the fixture home, the fixture record,
  # and the fixture probe, from this checkout under HARBOR_DEV=1 (design section 5.2)
  run env HOME="${FIX_HOME}" HARBOR_DEV=1 HARBOR_AUTH_FIXTURE_RECORD="${RECORD}" \
    HARBOR_AUTH_FIXTURE_PROBE="${PROBE}" "${HARBOR}" auth ${1+"$@"}
}

# ---- assertions -------------------------------------------------------------------

calls_of() {
  # calls_of NAME [ARG]: how many times shim NAME ran, optionally with first ARG
  [ -e "${HARBOR_SHIM_LOG}" ] || {
    printf '0\n'
    return 0
  }
  if [ -n "${2:-}" ]; then
    grep -c "^${1}${TAB}${2}" "${HARBOR_SHIM_LOG}" || true
  else
    grep -c "^${1}${TAB}" "${HARBOR_SHIM_LOG}" || true
  fi
}

shim_lines() {
  # shim_lines: the shim log with tabs as spaces, one call per line
  sed -n 's/\t/ /gp' "${HARBOR_SHIM_LOG}"
}

assert_nothing_journaled() {
  # Tailscale authentication is never journaled: the operator journal holds no entry
  # and the log records no entry creation.
  if [ -d "${FIX_ROOT}/journal" ]; then
    run find "${FIX_ROOT}/journal" -name '[0-9][0-9][0-9][0-9]-*.json'
    assert_output ""
  fi
  if [ -f "${FIX_ROOT}/harbor.log" ]; then
    run grep -c ' journal ' "${FIX_ROOT}/harbor.log"
    assert_output 0
  fi
}

assert_url_only_on_terminal() {
  # The login URL reached the terminal and nothing else: not the log, not the shim
  # log (which would mean it was passed as an argument), not a journal. The command's
  # own output and status are put back afterwards, so a caller can go on asserting
  # on them.
  local saved_output="${output}" saved_status="${status}"
  assert_output --partial "${URL}"
  if [ -f "${FIX_ROOT}/harbor.log" ]; then
    run grep -c 'login.tailscale.com' "${FIX_ROOT}/harbor.log"
    assert_output 0
  fi
  run grep -c 'login.tailscale.com' "${HARBOR_SHIM_LOG}"
  assert_output 0
  output="${saved_output}"
  status="${saved_status}"
}

# ---- the shipped gate -------------------------------------------------------------

@test "gate: the shipped probe record ships the gate closed on a measurement that was made" {
  assert [ -f "${SHIPPED}" ]
  run sed -n 's/^result=//p' "${SHIPPED}"
  # accepted-not-adopted rather than accepted, refused, or not-run. The vendor-smoke
  # lane has run and the daemon did not refuse, so not-run and refused would both tell
  # a reviewer something false; accepted would open the gate, and whether Harbor passes
  # --ssh on every operator login is adopted deliberately rather than by a probe whose
  # bound ran out at the login step. The gate is closed on everything but accepted, so
  # the word carries the reason without changing the behaviour.
  assert_output accepted-not-adopted
  run sed -n 's/^tailscale_version=//p' "${SHIPPED}"
  assert_output "${LOCKED}"
  run sed -n 's/^date=//p' "${SHIPPED}"
  assert_output --regexp '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
  # The record names the run it came from, so a reader can go and check it rather than
  # take this file's word for the measurement.
  run sed -n 's/^measured_by=//p' "${SHIPPED}"
  assert_output --partial 'vendor-smoke'
  run sed -n 's/^note=//p' "${SHIPPED}"
  assert_output --partial "has been run"
  assert_output --partial "did not refuse"
  run sed -n 's/^note_gate=//p' "${SHIPPED}"
  assert_output --partial "held closed on purpose"
  harbor_auth_ssh_gate "${SHIPPED}" "${LOCKED}"
  assert_equal "${HARBOR_AUTH_SSH_GATE}" closed
  assert_regex "${HARBOR_AUTH_SSH_GATE_WHY}" "records result=accepted-not-adopted, and this gate opens only on result=accepted"
}

@test "gate: opens only on result=accepted for the pinned version, and is closed on every other reading" {
  probe accepted
  harbor_auth_ssh_gate "${PROBE}" "${LOCKED}"
  assert_equal "${HARBOR_AUTH_SSH_GATE}" open
  probe accepted 1.0.0
  harbor_auth_ssh_gate "${PROBE}" "${LOCKED}"
  assert_equal "${HARBOR_AUTH_SSH_GATE}" closed
  assert_regex "${HARBOR_AUTH_SSH_GATE_WHY}" "records acceptance for tailscale 1.0.0, not the ${LOCKED}"
  probe refused
  harbor_auth_ssh_gate "${PROBE}" "${LOCKED}"
  assert_equal "${HARBOR_AUTH_SSH_GATE}" closed
  probe Accepted
  harbor_auth_ssh_gate "${PROBE}" "${LOCKED}"
  assert_equal "${HARBOR_AUTH_SSH_GATE}" closed
  # No result key, no version key, an empty file, and no file at all.
  printf 'date=2026-09-06\ntailscale_version=%s\n' "${LOCKED}" >"${PROBE}"
  harbor_auth_ssh_gate "${PROBE}" "${LOCKED}"
  assert_equal "${HARBOR_AUTH_SSH_GATE}" closed
  assert_regex "${HARBOR_AUTH_SSH_GATE_WHY}" "records result=nothing, and this gate opens only on result=accepted"
  printf 'result=accepted\n' >"${PROBE}"
  harbor_auth_ssh_gate "${PROBE}" "${LOCKED}"
  assert_equal "${HARBOR_AUTH_SSH_GATE}" closed
  : >"${PROBE}"
  harbor_auth_ssh_gate "${PROBE}" "${LOCKED}"
  assert_equal "${HARBOR_AUTH_SSH_GATE}" closed
  rm -f "${PROBE}"
  harbor_auth_ssh_gate "${PROBE}" "${LOCKED}"
  assert_equal "${HARBOR_AUTH_SSH_GATE}" closed
  assert_regex "${HARBOR_AUTH_SSH_GATE_WHY}" "is absent or unreadable"
  # A key given twice keeps its first value, so a second result line cannot open it.
  printf 'result=refused\nresult=accepted\ntailscale_version=%s\n' "${LOCKED}" >"${PROBE}"
  harbor_auth_ssh_gate "${PROBE}" "${LOCKED}"
  assert_equal "${HARBOR_AUTH_SSH_GATE}" closed
}

# ---- the record reader ------------------------------------------------------------

@test "record: the narrow reader returns the string under a key, unescaped, and nothing for a missing key or file" {
  record harbor-installed yes
  assert_equal "$(harbor_auth_record_value "${RECORD}" tailscale_ownership)" harbor-installed
  assert_equal "$(harbor_auth_record_value "${RECORD}" operator)" "${OP}"
  assert_equal "$(harbor_bootstrap_flags_field "$(harbor_auth_record_value "${RECORD}" flags)" tailscale-ssh)" yes
  assert_equal "$(harbor_auth_record_value "${RECORD}" no_such_key)" ""
  # A number is not a string and is not read as one.
  assert_equal "$(harbor_auth_record_value "${RECORD}" operator_uid)" ""
  assert_equal "$(harbor_auth_record_value "${BATS_TEST_TMPDIR}/absent.json" operator)" ""
  # An escaped character in a value reads back as the character lib/state.sh escaped.
  printf '{\n  "operator": "a\\"b",\n  "flags": "x"\n}\n' >"${RECORD}"
  assert_equal "$(harbor_auth_record_value "${RECORD}" operator)" 'a"b'
}

# ---- preconditions ----------------------------------------------------------------

@test "auth tailscale: root is refused before anything is read or created" {
  record harbor-installed no
  probe refused
  backend NeedsLogin
  up_ok
  id() {
    if [ "${1:-}" = -u ]; then
      printf '0\n'
    else
      command id ${1+"$@"}
    fi
  }
  auth
  assert_failure 3
  assert_output --partial "auth.root:"
  assert_output --partial "without sudo"
  assert [ ! -e "${HARBOR_SHIM_LOG}" ]
  assert [ ! -e "${FIX_ROOT}" ]
  # The dispatcher's entry refuses root the same way, before the entrypoint check.
  run harbor_auth_cmd tailscale
  assert_failure 3
  assert_output --partial "auth.root:"
  assert [ ! -e "${HARBOR_SHIM_LOG}" ]
  unset -f id
}

@test "auth tailscale: a Tailscale Harbor did not install is refused naming what was found, mutating nothing" {
  probe refused
  backend NeedsLogin
  up_ok
  record pre-existing no
  auth
  assert_failure 3
  assert_output --partial "auth.ownership:"
  assert_output --partial "records the Tailscale on this node as pre-existing, not harbor-installed"
  assert_output --partial "bring it up yourself"
  record adopted no
  auth
  assert_failure 3
  assert_output --partial "as adopted, not harbor-installed"
  record foreign-word no
  auth
  assert_failure 3
  assert_output --partial "as foreign-word, not harbor-installed"
  # Nothing was asked of the vendor and the operator state root was never created.
  assert [ ! -e "${HARBOR_SHIM_LOG}" ]
  assert [ ! -e "${FIX_ROOT}" ]
}

@test "auth tailscale: an absent record, or one naming no ownership, is refused naming sudo harbor bootstrap" {
  probe refused
  backend NeedsLogin
  auth
  assert_failure 3
  assert_output --partial "auth.record:"
  assert_output --partial "sudo harbor bootstrap"
  mkdir -p "$(dirname "${RECORD}")"
  printf '{\n  "release_tag": "v0.3.0"\n}\n' >"${RECORD}"
  auth
  assert_failure 3
  assert_output --partial "auth.record:"
  assert [ ! -e "${HARBOR_SHIM_LOG}" ]
  assert [ ! -e "${FIX_ROOT}" ]
}

@test "auth tailscale: an unknown flag is a usage error before anything is read" {
  record harbor-installed no
  auth --ssh
  assert_failure 3
  assert_output --partial "usage: harbor auth tailscale [--tailscale-ssh]"
  auth --tailscale-ssh extra
  assert_failure 3
  assert [ ! -e "${HARBOR_SHIM_LOG}" ]
  assert [ ! -e "${FIX_ROOT}" ]
}

@test "auth tailscale: the operator's status read failing is the missing grant, exit 3 naming sudo tailscale set --operator" {
  record harbor-installed no
  probe refused
  status_fails
  up_ok
  auth
  assert_failure 3
  assert_output --partial "auth.status: tailscale status --json failed as $(id -un) without sudo (exit 1)"
  assert_output --partial "Access denied: watch IPN bus access denied"
  assert_output --partial "sudo tailscale set --operator=${OP}"
  assert_equal "$(calls_of tailscale up)" 0
  assert_nothing_journaled
  # A status without a BackendState is not one this command can decide on either.
  printf '{"Version": "%s-fixture"}\n' "${LOCKED}" | fx tailscale "$(key status --json)"
  auth
  assert_failure 3
  assert_output --partial "auth.status:"
  assert_equal "$(calls_of tailscale up)" 0
}

# ---- the login --------------------------------------------------------------------

@test "auth tailscale: Running is already logged in, exit 0 with no up" {
  record harbor-installed no
  probe refused
  backend Running
  up_ok
  auth
  assert_success
  assert_output --partial "already logged in (BackendState Running); nothing to do"
  run shim_lines
  assert_output "tailscale status --json"
  assert_equal "$(calls_of tailscale up)" 0
  assert_nothing_journaled
}

@test "auth tailscale: not running runs the exact up form, passes the vendor's output through, waits for Running, journals nothing" {
  record harbor-installed no
  probe refused
  backend NeedsLogin
  up_ok
  after_up Running
  auth
  assert_success
  assert_output --partial "logging this node in with: ${UP};"
  assert_output --partial "To authenticate, visit:"
  assert_url_only_on_terminal
  assert_output --partial "this node is logged in to its tailnet (BackendState Running)"
  # The read, the one up, then the read that saw Running; the exact form and no --ssh.
  run shim_lines
  assert_line --index 0 "tailscale status --json"
  assert_line --index 1 "${UP}"
  assert_line --index 2 "tailscale status --json"
  assert_equal "$(calls_of tailscale up)" 1
  refute_output --partial "--ssh"
  refute_output --partial "sudo"
  assert_nothing_journaled
  # The command log records the argv and the steps, never the URL.
  run cat "${FIX_ROOT}/harbor.log"
  assert_output --partial "command auth tailscale"
  assert_output --partial "vendor ${UP}"
  assert_output --partial "step recovery-scan"
  assert_output --partial "step tailscale-up"
  refute_output --partial "login.tailscale.com"
  # No state record was written under the operator root.
  assert [ ! -e "${FIX_ROOT}/bootstrap.json" ]
  # Nothing about --ssh was said: bootstrap did not ask for it.
  refute_output --partial "tailscale set --ssh"
}

@test "auth tailscale: a refused up is exit 3 with the vendor's output, nothing mutated, and the sudo form to run outside Harbor" {
  record harbor-installed no
  probe refused
  backend NeedsLogin
  up_refused
  after_up Running
  auth
  assert_failure 3
  assert_output --partial "Access denied: tailscale up: access denied"
  assert_output --partial "auth.up: ${UP} exited 1"
  assert_output --partial "sudo ${UP};"
  assert_output --partial "nothing was changed and nothing was journaled"
  # The wait never started: the read before the up is the only read.
  run shim_lines
  assert_line --index 0 "tailscale status --json"
  assert_line --index 1 "${UP}"
  assert_equal "$(calls_of tailscale status)" 1
  assert_nothing_journaled
  assert [ ! -e "${FIX_ROOT}/bootstrap.json" ]
}

@test "auth tailscale: an up that exits 0 without Running times out with exit 3 and a rerun" {
  record harbor-installed no
  probe refused
  backend NeedsLogin
  up_ok
  HARBOR_AUTH_POLL_SECONDS=0
  HARBOR_AUTH_TIMEOUT_SECONDS=0
  auth
  assert_failure 3
  assert_output --partial "auth.timeout: ${UP} exited 0 but BackendState is still NeedsLogin after 0s"
  assert_output --partial "rerun harbor auth tailscale"
  assert_url_only_on_terminal
  assert_nothing_journaled
}

@test "auth tailscale: a daemon that stops answering after the up is exit 2" {
  record harbor-installed no
  probe refused
  backend NeedsLogin
  up_ok
  after_up_fails
  auth
  assert_failure 2
  assert_output --partial "auth.status: ${UP} exited 0 but tailscale status --json now fails (exit 1)"
  assert_nothing_journaled
}

# ---- the --ssh gate ---------------------------------------------------------------

@test "gate closed: bootstrap recorded --tailscale-ssh, so the up runs without --ssh and the root-owned alternative is printed" {
  record harbor-installed yes
  probe refused
  backend NeedsLogin
  up_ok
  after_up Running
  auth
  assert_success
  assert_output --partial "auth.ssh_gate: bootstrap recorded --tailscale-ssh for this node, but the vendor-smoke probe record ${PROBE}"
  assert_output --partial "records result=refused, and this gate opens only on result=accepted"
  assert_output --partial "so the login runs without --ssh"
  assert_output --partial "sudo tailscale set --ssh"
  run shim_lines
  assert_line --index 1 "${UP}"
  refute_output --partial "--ssh"
  assert_nothing_journaled
}

@test "gate closed: an explicit --tailscale-ssh is refused, exit 3, before any vendor call" {
  record harbor-installed yes
  probe refused
  backend NeedsLogin
  up_ok --ssh
  up_ok
  auth --tailscale-ssh
  assert_failure 3
  assert_output --partial "auth.ssh_gate: --tailscale-ssh is not a supported flag of this release"
  assert_output --partial "records result=refused, and this gate opens only on result=accepted"
  assert_output --partial "sudo tailscale set --ssh"
  assert [ ! -e "${HARBOR_SHIM_LOG}" ]
  assert [ ! -e "${FIX_ROOT}" ]
  # The same with no probe record at all, and with the shipped one.
  rm -f "${PROBE}"
  auth --tailscale-ssh
  assert_failure 3
  assert_output --partial "is absent or unreadable"
  PROBE="${SHIPPED}"
  auth --tailscale-ssh
  assert_failure 3
  # The shipped record says accepted-not-adopted, not refused: the two synthetic probes
  # above model a daemon that refused, and this one is the release's own record of a
  # daemon that did not. Both close the gate, and the refusal names whichever it read.
  assert_output --partial "records result=accepted-not-adopted, and this gate opens only on result=accepted"
  assert [ ! -e "${HARBOR_SHIM_LOG}" ]
}

@test "gate open: bootstrap recorded --tailscale-ssh, so the up carries --ssh and no alternative is printed" {
  record harbor-installed yes
  probe accepted
  backend NeedsLogin
  up_ok --ssh
  after_up Running
  auth
  assert_success
  assert_output --partial "logging this node in with: ${UP} --ssh;"
  run shim_lines
  assert_line --index 1 "${UP} --ssh"
  assert_equal "$(calls_of tailscale up)" 1
  refute_output --partial "tailscale set --ssh"
  refute_output --partial "auth.ssh_gate"
  assert_nothing_journaled
  # An explicit --tailscale-ssh asks for what the record already carries.
  backend NeedsLogin
  auth --tailscale-ssh
  assert_success
  run shim_lines
  assert_line --index 4 "${UP} --ssh"
}

@test "gate open: without --tailscale-ssh recorded by bootstrap the up runs without --ssh, and asking for it explicitly is refused" {
  record harbor-installed no
  probe accepted
  backend NeedsLogin
  up_ok
  after_up Running
  auth
  assert_success
  run shim_lines
  assert_line --index 1 "${UP}"
  refute_output --partial "--ssh"
  backend NeedsLogin
  auth --tailscale-ssh
  assert_failure 3
  assert_output --partial "auth.ssh_unrecorded: bootstrap did not record --tailscale-ssh for this node (its flag set records tailscale-ssh=no)"
  assert_output --partial "sudo tailscale set --ssh"
  assert_equal "$(calls_of tailscale up)" 1
}

@test "gate: an acceptance recorded for another Tailscale version keeps the gate closed" {
  record harbor-installed yes
  probe accepted 1.0.0
  backend NeedsLogin
  up_ok
  after_up Running
  auth
  assert_success
  assert_output --partial "records acceptance for tailscale 1.0.0, not the ${LOCKED} that ${HARBOR_ROOT}/versions.lock pins"
  assert_output --partial "sudo tailscale set --ssh"
  run shim_lines
  assert_line --index 1 "${UP}"
  refute_output --partial "--ssh"
}

# ---- the lock and recovery ----------------------------------------------------------

@test "auth tailscale: recovery runs under the lock first, and an undecidable entry stops the command before any vendor call" {
  record harbor-installed no
  probe refused
  backend NeedsLogin
  up_ok
  fixture_state_root
  fixture_undecidable_file_entry "${FIX_ROOT}" 0001
  auth
  assert_failure 2
  assert_output --partial "journal.undecidable: prepared entries 0001"
  assert [ ! -e "${HARBOR_SHIM_LOG}" ]
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" prepared
  assert [ ! -e "${FIX_ROOT}/lock.d" ]
}

@test "auth tailscale: a gate another command left behind is refused before any vendor call" {
  record harbor-installed no
  probe refused
  backend NeedsLogin
  up_ok
  fixture_state_root
  mkdir "${FIX_ROOT}/reclaim.d"
  auth
  assert_failure 3
  assert_output --partial "lock.gate_busy:"
  assert [ ! -e "${HARBOR_SHIM_LOG}" ]
  assert [ ! -e "${FIX_ROOT}/lock.d" ]
}

# ---- the public command -------------------------------------------------------------

@test "harbor auth tailscale: creates the operator state root with its modes before the lock, logs in, and releases the lock" {
  record harbor-installed no
  probe refused
  backend NeedsLogin
  up_ok
  after_up Running
  assert [ ! -e "${FIX_ROOT}" ]
  harbor_cmd tailscale
  assert_success
  assert_output --partial "To authenticate, visit:"
  assert_url_only_on_terminal
  assert_output --partial "this node is logged in to its tailnet"
  refute_output --partial "failed at step"
  run ls -ld "${FIX_ROOT}" "${FIX_ROOT}/journal"
  assert_line --index 0 --regexp '^drwx------'
  assert_line --index 1 --regexp '^drwx------'
  run ls -l "${FIX_ROOT}/harbor.log"
  assert_output --regexp '^-rw-------'
  assert [ ! -e "${FIX_ROOT}/lock.d" ]
  assert [ ! -e "${FIX_ROOT}/reclaim.d" ]
  assert_nothing_journaled
  run cat "${FIX_ROOT}/harbor.log"
  assert_output --partial "command auth tailscale"
  assert_output --partial "step lock-acquired"
  assert_output --partial "step recovery-scan"
  assert_output --partial "vendor ${UP}"
  assert_output --regexp ' exit 0$'
  refute_output --partial "login.tailscale.com"
  run shim_lines
  assert_line --index 0 "tailscale status --json"
  assert_line --index 1 "${UP}"
  assert_line --index 2 "tailscale status --json"
}

@test "harbor auth tailscale: reads the shipped probe record by default, so the release runs the up without --ssh" {
  record harbor-installed yes
  backend NeedsLogin
  up_ok
  after_up Running
  run env HOME="${FIX_HOME}" HARBOR_DEV=1 HARBOR_AUTH_FIXTURE_RECORD="${RECORD}" "${HARBOR}" auth tailscale
  assert_success
  assert_output --partial "but the vendor-smoke probe record ${SHIPPED}"
  assert_output --partial "sudo tailscale set --ssh"
  run shim_lines
  assert_line --index 1 "${UP}"
  refute_output --partial "--ssh"
  run env HOME="${FIX_HOME}" HARBOR_DEV=1 HARBOR_AUTH_FIXTURE_RECORD="${RECORD}" "${HARBOR}" auth tailscale --tailscale-ssh
  assert_failure 3
  assert_output --partial "auth.ssh_gate: --tailscale-ssh is not a supported flag of this release"
}

@test "harbor auth tailscale: refusals through the dispatcher exit 3 having created nothing" {
  probe refused
  backend NeedsLogin
  up_ok
  record pre-existing no
  harbor_cmd tailscale
  assert_failure 3
  assert_output --partial "auth.ownership:"
  assert [ ! -e "${FIX_ROOT}" ]
  assert [ ! -e "${HARBOR_SHIM_LOG}" ]
  record harbor-installed no
  harbor_cmd tailscale --tailscale-ssh
  assert_failure 3
  assert_output --partial "auth.ssh_gate:"
  assert [ ! -e "${FIX_ROOT}" ]
  assert [ ! -e "${HARBOR_SHIM_LOG}" ]
}

@test "harbor auth tailscale: without HARBOR_DEV the installed-entrypoint check refuses a checkout before the record is read" {
  record harbor-installed no
  probe refused
  backend NeedsLogin
  up_ok
  run env -u HARBOR_DEV HOME="${FIX_HOME}" HARBOR_AUTH_FIXTURE_RECORD="${RECORD}" \
    HARBOR_AUTH_FIXTURE_PROBE="${PROBE}" "${HARBOR}" auth tailscale
  assert_failure 3
  assert_output --partial "entrypoint.location:"
  assert [ ! -e "${FIX_ROOT}" ]
  assert [ ! -e "${HARBOR_SHIM_LOG}" ]
}

@test "harbor auth: usage, the tools of a later release, and help name the command" {
  run env HOME="${FIX_HOME}" "${HARBOR}" auth
  assert_failure 3
  assert_output --partial "usage: harbor auth tailscale [--tailscale-ssh]"
  run env HOME="${FIX_HOME}" "${HARBOR}" auth claude
  assert_failure 3
  assert_output --partial "harbor auth claude is not part of this release"
  run env HOME="${FIX_HOME}" "${HARBOR}" auth github
  assert_failure 3
  assert_output --partial "usage: harbor auth tailscale"
  assert [ ! -e "${FIX_ROOT}" ]
  run "${HARBOR}" help
  assert_success
  assert_output --partial "auth tailscale [--tailscale-ssh]"
}
