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
  fixture_state_root
  HARBOR_PID="$$"
  HOME="${FIX_HOME}"
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

@test "tailnet exits 3 naming PR 5's command" {
  seed_config tailnet
  run harbor_config_access_mode "${FIX_HOME}"
  assert_equal "${status}" 3
  assert_output --partial 'harbor pair'
  assert_output --partial "${CONFIG}"
  run harbor_config_create "${FIX_ROOT}" "${FIX_HOME}" tailnet
  assert_equal "${status}" 3
  assert_output --partial 'harbor pair'
  # "configuration was not accepted" is a claim about the node, not just an exit
  # code: the refusal precedes every write, so the journal stays empty and the
  # file on disk is the one that was already there.
  set -- "${FIX_ROOT}/journal/"*.json
  assert_equal "$*" "${FIX_ROOT}/journal/*.json"
  assert_equal "$(cat "${CONFIG}")" 'access_mode=tailnet'
}

@test "an unknown mode exits 3" {
  seed_config unknown
  run harbor_config_access_mode "${FIX_HOME}"
  assert_equal "${status}" 3
  assert_output --partial "${CONFIG}"
  assert_output --partial unknown
  assert_output --partial connect
  assert_output --partial tailnet
  # Naming tailnet without this would send a typo to a value the same function
  # refuses, and the operator would learn that only on the next run.
  assert_output --partial 'only connect can be provisioned by this release'
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
