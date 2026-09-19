#!/usr/bin/env bats
load '../test_helper'

setup() {
  # shellcheck source=lib/log.sh
  . "${HARBOR_ROOT}/lib/log.sh"
  # shellcheck source=lib/lock.sh
  . "${HARBOR_ROOT}/lib/lock.sh"
  # shellcheck source=lib/journal.sh
  . "${HARBOR_ROOT}/lib/journal.sh"
  # shellcheck source=lib/config.sh
  . "${HARBOR_ROOT}/lib/config.sh"
  # shellcheck source=lib/access.sh
  . "${HARBOR_ROOT}/lib/access.sh"
  fixture_state_root
  HARBOR_PID="$$"
  HOME="${FIX_HOME}"
  HARBOR_LOCK_ID_PID=$$
  HARBOR_LOCK_ID_HOSTNAME=fixture
  HARBOR_LOCK_ID_BOOT_ID=fixture
  HARBOR_LOCK_ID_START_TIME=fixture
  HARBOR_LOCK_ID_CMDLINE=config-test
  FIX_PROBE="${BATS_TEST_TMPDIR}/probe"
  harbor_access_probe_path() { printf '%s' "${FIX_PROBE}"; }
  CONFIG="${FIX_HOME}/.config/harbor/config"
}

seed_config() {
  mkdir -p "$(dirname "${CONFIG}")"
  printf 'access_mode=%s\n' "${1}" >"${CONFIG}"
  chmod 0600 "${CONFIG}"
}

@test "creation writes 0600 and one created entry" {
  harbor_lock_acquire "${FIX_ROOT}" operator
  harbor_config_create "${FIX_ROOT}" "${FIX_HOME}" connect
  assert_equal "$(harbor_config_path "${FIX_HOME}")" "${CONFIG}"
  assert_equal "$(cat "${CONFIG}")" 'access_mode=connect'
  assert_equal "$(harbor_stat_mode "${CONFIG}")" 0600
  set -- "${FIX_ROOT}/journal/"*.json
  assert_equal "$#" 1
  assert_equal "$(entry_raw "${FIX_ROOT}" 0001 ownership)" '"created"'
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" applied
  assert_equal "$(entry_raw "${FIX_ROOT}" 0001 pre_state)" '"absent"'
  assert_equal "$(entry_raw "${FIX_ROOT}" 0001 post_state)" "$(harbor_observe_file "${CONFIG}")"
  run harbor_config_access_mode "${FIX_HOME}"
  assert_success
  assert_output connect
}

@test "a rerun with the same mode writes an observed entry and does not rewrite the file" {
  harbor_lock_acquire "${FIX_ROOT}" operator
  harbor_config_create "${FIX_ROOT}" "${FIX_HOME}" connect
  # A hard link detects rename-over, and an old mtime detects in-place rewriting.
  ln "${CONFIG}" "${BATS_TEST_TMPDIR}/original"
  touch -t 200001010000 "${CONFIG}"
  touch -r "${CONFIG}" "${BATS_TEST_TMPDIR}/timestamp"
  harbor_config_create "${FIX_ROOT}" "${FIX_HOME}" connect
  [ "${CONFIG}" -ef "${BATS_TEST_TMPDIR}/original" ]
  [ ! "${CONFIG}" -nt "${BATS_TEST_TMPDIR}/timestamp" ]
  assert_equal "$(entry_raw "${FIX_ROOT}" 0002 ownership)" '"observed"'
  assert_equal "$(entry_phase "${FIX_ROOT}" 0002)" applied
  set -- "${FIX_ROOT}/journal/"*.json
  assert_equal "$#" 2
}

@test "a rerun with a different mode writes a modified entry" {
  seed_config tailnet
  local pre
  pre="$(harbor_observe_file "${CONFIG}")"
  harbor_lock_acquire "${FIX_ROOT}" operator
  harbor_config_create "${FIX_ROOT}" "${FIX_HOME}" connect
  assert_equal "$(entry_raw "${FIX_ROOT}" 0001 ownership)" '"modified"'
  assert_equal "$(entry_raw "${FIX_ROOT}" 0001 pre_state)" "${pre}"
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" applied
  assert_equal "$(cat "${CONFIG}")" 'access_mode=connect'
}

@test "an unknown mode exits 3" {
  seed_config unknown
  run harbor_config_access_mode "${FIX_HOME}"
  assert_equal "${status}" 3
  assert_output --partial "${CONFIG}"
  assert_output --partial unknown
  assert_output --partial connect
  assert_output --partial tailnet
  assert_output --partial ssh
}

@test "a 0644 file exits 3 before its otherwise valid contents are read" {
  seed_config connect
  chmod 0644 "${CONFIG}"
  # Record any call to the reader builtin: valid contents alone cannot prove that
  # the permission refusal preceded parsing.
  monitored_access_mode() {
    read() {
      printf 'read\n' >>"${BATS_TEST_TMPDIR}/reads"
      builtin read "${@}"
    }
    harbor_config_access_mode "${FIX_HOME}"
  }
  run monitored_access_mode
  assert_equal "${status}" 3
  assert_output --partial config.permissions
  assert_output --partial "${CONFIG}"
  assert_output --partial 0600
  [ ! -e "${BATS_TEST_TMPDIR}/reads" ]
}

@test "a symlink at the config path is refused by both the reader and the writer" {
  # A link would let a file outside this path decide the access mode, and would let
  # the journal record the target's hash while the rename replaces the link itself.
  local target="${BATS_TEST_TMPDIR}/elsewhere"
  printf 'access_mode=connect\n' >"${target}"
  chmod 0600 "${target}"
  mkdir -p "$(dirname "${CONFIG}")"
  ln -s "${target}" "${CONFIG}"
  run harbor_config_access_mode "${FIX_HOME}"
  assert_equal "${status}" 3
  assert_output --partial config.foreign
  assert_output --partial symlink
  harbor_lock_acquire "${FIX_ROOT}" operator
  run harbor_config_create "${FIX_ROOT}" "${FIX_HOME}" connect
  assert_equal "${status}" 3
  assert_output --partial config.foreign
  # Nothing followed the link and nothing was journaled.
  assert_equal "$(cat "${target}")" 'access_mode=connect'
  [ -L "${CONFIG}" ]
  set -- "${FIX_ROOT}/journal/"*.json
  assert_equal "$*" "${FIX_ROOT}/journal/*.json"
}

@test "the staged file is never readable by anyone else, whatever the umask" {
  # chmod after the write would leave it at the ambient umask until it lands, and
  # would leave the staged file behind if the chmod were what failed.
  harbor_lock_acquire "${FIX_ROOT}" operator
  umask 000
  harbor_config_create "${FIX_ROOT}" "${FIX_HOME}" connect
  assert_equal "$(harbor_stat_mode "${CONFIG}")" 0600
  set -- "$(dirname "${CONFIG}")"/.tmp.config.*
  assert_equal "$*" "$(dirname "${CONFIG}")/.tmp.config.*"
}

@test "a symlink planted at the staged name is not followed" {
  # The agents run as this operator, so the gap between the unlink and the write is
  # reachable. noclobber makes the redirection fail rather than follow the link.
  local victim="${BATS_TEST_TMPDIR}/victim"
  printf 'original\n' >"${victim}"
  mkdir -p "$(dirname "${CONFIG}")"
  harbor_lock_acquire "${FIX_ROOT}" operator
  # Planting the link before the call would only prove that the unlink removes it.
  # The window is the instant *after* that unlink, so the unlink is neutralized and
  # the link planted in its place: the state the race produces, without the timing.
  rm() {
    case "${*}" in
      *.tmp.config.*) ln -s "${victim}" "$(dirname "${CONFIG}")/.tmp.config.${HARBOR_LOCK_ID_PID}" 2>/dev/null || true ;;
      *) command rm "${@}" ;;
    esac
  }
  run harbor_config_create "${FIX_ROOT}" "${FIX_HOME}" connect
  unset -f rm
  assert_equal "${status}" 2
  assert_output --partial config.stage
  assert_equal "$(cat "${victim}")" original
  [ ! -e "${CONFIG}" ]
}

@test "a missing file exits 3 naming harbor provision" {
  run harbor_config_access_mode "${FIX_HOME}"
  assert_equal "${status}" 3
  assert_output --partial "${CONFIG}"
  assert_output --partial 'harbor provision'
}

probe_fixture() {
  # The gate reads the two measured_ pins as well as the result, so a fixture that
  # writes only a result is a fixture that can never say supported. Taking the
  # values from the lock the code will compare against keeps the fixture honest
  # about what it is asserting: the result word, not a stale pin.
  printf 'result=%s\nmeasured_tailscale_version=%s\nmeasured_t3_version=%s\n' "${1}" \
    "$(sed -n 's/^tailscale_version=//p' "${HARBOR_ROOT}/versions.lock")" \
    "$(sed -n 's/^t3_version=//p' "${HARBOR_ROOT}/versions.lock")" >"${FIX_PROBE}"
}
@test "ssh is an accepted access mode" {
  run harbor_config_validate_mode "${CONFIG}" ssh
  assert_success
}

@test "connect is accepted and an unknown mode names all three" {
  run harbor_config_validate_mode "${CONFIG}" connect
  assert_success
  run harbor_config_validate_mode "${CONFIG}" wireguard
  assert_equal "${status}" 3
  assert_output --partial 'connect'
  assert_output --partial 'tailnet'
  assert_output --partial 'ssh'
}

@test "tailnet parses, and the gate is what refuses it" {
  # The distinction matters: tailnet is a real mode this release implements, and
  # the refusal is about a measurement, not about a missing command. A parse-time
  # rejection would make the message unfixable by measuring anything.
  run harbor_config_validate_mode "${CONFIG}" tailnet
  assert_success
}

@test "the recorded probe decides whether tailnet is supported" {
  probe_fixture unsupported
  run harbor_access_require_tailnet_supported
  assert_equal "${status}" 3
  assert_output --partial 'has not been verified on the pinned tailscale and t3 versions'
  assert_output --partial 'tailnet-environment.probe'
  probe_fixture supported
  run harbor_access_require_tailnet_supported
  assert_success
}

@test "a probe file that is missing or unreadable is unsupported, never supported" {
  rm -f "${FIX_PROBE}"
  run harbor_access_require_tailnet_supported
  assert_equal "${status}" 3
}

@test "a result measured on other pins does not carry across a version bump" {
  # The whole point of the two measured_ fields. A supported recorded against an
  # older tailscale or t3 is an answer about software this node is no longer
  # running, and reading only result= would let it keep tailnet open through
  # exactly the bump the measurement was supposed to be redone for.
  local locked_ts locked_t3
  locked_ts="$(sed -n 's/^tailscale_version=//p' "${HARBOR_ROOT}/versions.lock")"
  locked_t3="$(sed -n 's/^t3_version=//p' "${HARBOR_ROOT}/versions.lock")"
  printf 'result=supported\nmeasured_tailscale_version=0.0.0\nmeasured_t3_version=%s\n' \
    "${locked_t3}" >"${FIX_PROBE}"
  run harbor_access_require_tailnet_supported
  assert_equal "${status}" 3
  printf 'result=supported\nmeasured_tailscale_version=%s\nmeasured_t3_version=0.0.0\n' \
    "${locked_ts}" >"${FIX_PROBE}"
  run harbor_access_require_tailnet_supported
  assert_equal "${status}" 3
  # Both matching is the only spelling that opens the gate.
  probe_fixture supported
  run harbor_access_require_tailnet_supported
  assert_success
}

@test "a result with no measured pins at all is refused" {
  # The spelling the probe ships with, edited to say supported and nothing else.
  # An empty field can never equal a pin, so this fails closed without needing a
  # rule of its own -- and the test is here because that is a property of the
  # comparison rather than something the code says out loud.
  printf 'result=supported\nmeasured_tailscale_version=\nmeasured_t3_version=\n' >"${FIX_PROBE}"
  run harbor_access_require_tailnet_supported
  assert_equal "${status}" 3
  printf 'result=supported\n' >"${FIX_PROBE}"
  run harbor_access_require_tailnet_supported
  assert_equal "${status}" 3
}
