#!/bin/bash
# Constructed command-boundary shims; no real vendor or system state is used.
pair_test_setup() {
  harbor_load_libs
  local lib
  for lib in entrypoint runtime agents serve t3 config auth; do
    # shellcheck source=/dev/null
    . "${HARBOR_ROOT}/lib/${lib}.sh"
  done
  if [ -f "${HARBOR_ROOT}/lib/pair.sh" ]; then
    # shellcheck source=/dev/null
    . "${HARBOR_ROOT}/lib/pair.sh"
  fi
  fixture_state_root
  export HOME="${FIX_HOME}"
  export FIX_PAIR_DIR="${BATS_TEST_TMPDIR}"
  export FIX_SHIM_LOG="${BATS_TEST_TMPDIR}/calls"
  export FIX_LOOPBACK=unreachable FIX_MAGICDNS=unreachable
  export MAGICDNS=harbor-node.TAILNET.ts.net
  export FIX_DNS="${MAGICDNS}"
  export FIX_PAIR_MODE=success FIX_AFTER=vendor-443
  : >"${FIX_SHIM_LOG}"
  mkdir -p "${BATS_TEST_TMPDIR}/bin" "${FIX_HOME}/.local/harbor/npm/bin"
  cat >"${BATS_TEST_TMPDIR}/bin/tailscale" <<'SH'
#!/bin/bash
set -euo pipefail
printf 'tailscale %s\n' "$*" >>"${FIX_SHIM_LOG}"
if [ "$#" = 2 ] && [ "$1" = serve ] && [ "$2" = status ]; then
  cat "${FIX_PAIR_DIR}/serve"
elif [ "$#" = 2 ] && [ "$1" = status ] && [ "$2" = --json ]; then
  printf '{"Self":{"DNSName":"%s."}}\n' "${FIX_DNS}"
else
  exit 97
fi
SH
  cat >"${BATS_TEST_TMPDIR}/bin/curl" <<'SH'
#!/bin/bash
set -euo pipefail
printf 'curl %s\n' "$*" >>"${FIX_SHIM_LOG}"
for arg in "$@"; do url="${arg}"; done
case "${url}" in
  http://*) fixture="${FIX_LOOPBACK}" ;;
  https://*) fixture="${FIX_MAGICDNS}" ;;
  *) exit 97 ;;
esac
[ "${fixture}" != unreachable ] || exit 7
cat "${HARBOR_ROOT}/tests/fixtures/t3/environment/${fixture}"
printf '\nHARBOR_HTTP_CODE:200'
SH
  cat >"${FIX_HOME}/.local/harbor/npm/bin/t3" <<'SH'
#!/bin/bash
set -euo pipefail
if [ "$#" = 1 ] && [ "$1" = --version ]; then
  printf 't3 v%s\n' "${FIX_T3_VERSION}"
  exit 0
fi
[ "$#" = 2 ] && [ "$1" = pair ] && [ "$2" = --tailscale ] || exit 97
printf 't3 pair --tailscale\n' >>"${FIX_SHIM_LOG}"
grep -q '"phase": "prepared"' "${HOME}/.local/state/harbor/journal/"*.json || exit 96
printf 'vendor pairing URL and QR\n'
printf 'vendor stderr\n' >&2
if [ "${FIX_PAIR_MODE}" = stdin ]; then
  IFS= read -r answer
  printf '%s\n' "${answer}" >"${FIX_PAIR_DIR}/answer"
fi
[ "${FIX_PAIR_MODE}" != failure ] || exit 7
cp "${HARBOR_ROOT}/tests/fixtures/tailscale/serve-status/${FIX_AFTER}" "${FIX_PAIR_DIR}/serve"
if [ "${FIX_PAIR_MODE}" = hang ]; then
  printf '%s\n' "$$" >"${FIX_PAIR_DIR}/vendor.pid"
  trap '' TERM
  while :; do sleep 0.1; done
fi
# Same log as refusal tests; a simulated vendor mutation, never real Serve.
printf 'tailscale serve --bg --https=443 http://127.0.0.1:3773\n' >>"${FIX_SHIM_LOG}"
# failure-after is the order the pinned t3 actually uses: Serve is applied first
# and the pairing token is minted after it, so a vendor can fail having already
# published the node. "failure" above is the opposite order and keeps its
# callers' meaning: exited nonzero having published nothing.
[ "${FIX_PAIR_MODE}" != failure-after ] || exit 7
SH
  chmod +x "${BATS_TEST_TMPDIR}/bin/"* "${FIX_HOME}/.local/harbor/npm/bin/t3"
  export PATH="${BATS_TEST_TMPDIR}/bin:${PATH}"
  harbor_versions_load "${HARBOR_ROOT}/versions.lock"
  FIX_T3_VERSION="$(harbor_version_require t3_version)"
  export FIX_T3_VERSION
  # Fixed process identity avoids sandbox-only sysctl/ps restrictions. Each of
  # these is read by a sourced lib rather than by this file, so shellcheck cannot
  # see the use from here.
  # shellcheck disable=SC2034
  HARBOR_LOCK_ID_PID=$$
  # shellcheck disable=SC2034
  HARBOR_LOCK_ID_HOSTNAME=fixture
  # shellcheck disable=SC2034
  HARBOR_LOCK_ID_BOOT_ID=fixture
  # shellcheck disable=SC2034
  HARBOR_LOCK_ID_START_TIME=fixture
  # shellcheck disable=SC2034
  HARBOR_LOCK_ID_CMDLINE=pair-test
  harbor_lock_acquire "${FIX_ROOT}" operator
  harbor_journal_init "${FIX_ROOT}"
  # shellcheck disable=SC2034
  HARBOR_AGENTS_HOME="${FIX_HOME}"
  # Model the crash boundary without sending a signal to the Bats runner's $$.
  harbor_step() {
    harbor_log step "$1"
    if [ "${HARBOR_TEST_HOOKS:-}" = 1 ] && [ "${HARBOR_FAIL_AFTER:-}" = "$1" ]; then
      exit 4
    fi
    return 0
  }
  set -euo pipefail
}
serve_fixture() {
  cp "${HARBOR_ROOT}/tests/fixtures/tailscale/serve-status/$1" "${FIX_PAIR_DIR}/serve"
}
runtime_fixture() {
  mkdir -p "${FIX_HOME}/.t3/userdata"
  cp "${HARBOR_ROOT}/tests/fixtures/t3/server-runtime/$1" "${FIX_HOME}/.t3/userdata/server-runtime.json"
}
descriptor_shim_for() {
  case "$1" in
    loopback) export FIX_LOOPBACK="$2" ;;
    magicdns) export FIX_MAGICDNS="$2" ;;
  esac
}
pair_shim() { export FIX_PAIR_MODE="$1"; }
serve_fixture_after_pair() { export FIX_AFTER="$1"; }
config_fixture() {
  mkdir -p "${FIX_HOME}/.config/harbor"
  printf 'access_mode=%s\n' "$1" >"${FIX_HOME}/.config/harbor/config"
  chmod 600 "${FIX_HOME}/.config/harbor/config"
}
tailscale_status_fixture() { export FIX_DNS="$2"; }
