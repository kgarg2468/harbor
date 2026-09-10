#!/usr/bin/env bats
load '../test_helper'

setup() {
  # lib/runtime.sh depends on lib/log.sh for harbor_json_escape and harbor_die, and
  # the dispatch it owns is reached through lib/journal.sh, so this file sources
  # those three rather than harbor_load_libs.
  # shellcheck source=lib/log.sh
  . "${HARBOR_ROOT}/lib/log.sh"
  # shellcheck source=lib/journal.sh
  . "${HARBOR_ROOT}/lib/journal.sh"
  # shellcheck source=lib/runtime.sh
  . "${HARBOR_ROOT}/lib/runtime.sh"
  # A reader that records every call, so a test can prove a refused target was
  # refused before any lookup rather than after one that happened to miss.
  WITNESS="${BATS_TEST_TMPDIR}/witness"
}

reader_witness() {
  # A reader that records the target it was asked about before answering
  printf '%s\n' "${1}" >>"${WITNESS}"
  printf '9.9.9'
}

reader_claude() {
  printf 'claude:%s' "${1}"
}

reader_unreadable() {
  harbor_die 2 fake.unreadable "${1} cannot answer"
}

@test "the registry records a name and its function, reports an unregistered name as a miss, and takes the same registration twice" {
  run harbor_runtime_reader_for prefix
  assert_equal "${status}" 1
  assert_equal "${output}" ""
  harbor_runtime_reader_register prefix reader_witness
  harbor_runtime_reader_register claude reader_claude
  assert_equal "$(harbor_runtime_reader_for prefix)" reader_witness
  assert_equal "$(harbor_runtime_reader_for claude)" reader_claude
  run harbor_runtime_reader_for codex
  assert_equal "${status}" 1
  # Sourcing a library twice registers its readers twice and changes nothing.
  harbor_runtime_reader_register prefix reader_witness
  assert_equal "$(harbor_runtime_reader_for prefix)" reader_witness
}

@test "an absolute-path target is read by the prefix reader and a bare name by the reader registered for that name" {
  harbor_runtime_reader_register prefix reader_witness
  harbor_runtime_reader_register claude reader_claude
  assert_equal "$(harbor_observe_op_runtime_install /opt/harbor/node)" '"9.9.9"'
  assert_equal "$(cat "${WITNESS}")" /opt/harbor/node
  assert_equal "$(harbor_observe_op_runtime_install claude)" '"claude:claude"'
  # The op reached through harbor_journal_observe, which is how recovery calls it.
  assert_equal "$(harbor_journal_observe runtime-install claude)" '"claude:claude"'
}

@test "a bare name with no registered reader renders unobservable rather than guessing" {
  harbor_runtime_reader_register prefix reader_witness
  assert_equal "$(harbor_observe_op_runtime_install codex)" '"unobservable:runtime-install:codex"'
  assert_equal "$(harbor_journal_observe runtime-install t3)" '"unobservable:runtime-install:t3"'
  assert [ ! -e "${WITNESS}" ]
}

@test "a target outside the [a-z0-9-] vocabulary is unobservable without any lookup, escaped as it was written" {
  harbor_runtime_reader_register prefix reader_witness
  harbor_runtime_reader_register claude reader_claude
  # Shadow the lookup so the assertion is about lookups and not about invocations: the
  # witness reader only records that a reader ran, which a dispatcher that looked every
  # target up and merely missed would also satisfy.
  LOOKUPS="${BATS_TEST_TMPDIR}/lookups"
  harbor_runtime_reader_for() {
    printf '%s\n' "${1}" >>"${LOOKUPS}"
    return 1
  }
  assert_equal "$(harbor_observe_op_runtime_install "")" '"unobservable:runtime-install:"'
  assert_equal "$(harbor_observe_op_runtime_install Claude)" '"unobservable:runtime-install:Claude"'
  assert_equal "$(harbor_observe_op_runtime_install 'claude code')" '"unobservable:runtime-install:claude code"'
  assert_equal "$(harbor_observe_op_runtime_install 't3;rm -rf /')" '"unobservable:runtime-install:t3;rm -rf /"'
  assert_equal "$(harbor_observe_op_runtime_install 'a"b')" '"unobservable:runtime-install:a\"b"'
  assert [ ! -e "${WITNESS}" ]
  assert [ ! -e "${LOOKUPS}" ]
}

@test "a reader that exits 2 propagates exit 2 and renders nothing" {
  harbor_runtime_reader_register prefix reader_unreadable
  run --separate-stderr harbor_observe_op_runtime_install /opt/harbor/node
  assert_equal "${status}" 2
  assert_equal "${output}" ""
  assert_regex "${stderr}" 'fake.unreadable: /opt/harbor/node cannot answer'
  run --separate-stderr harbor_journal_observe runtime-install /opt/harbor/node
  assert_equal "${status}" 2
  assert_equal "${output}" ""
}

@test "exactly one library defines the runtime-install observer, and a claude target reads the agent reader beside the node one" {
  # The collision this task exists to prevent: two libraries defining
  # harbor_observe_op_runtime_install means whichever is sourced last silently wins
  # and recovery reads one runtime's entry with another runtime's reader.
  run grep -l '^harbor_observe_op_runtime_install()' "${HARBOR_ROOT}"/lib/*.sh
  assert_success
  assert_equal "${#lines[@]}" 1
  assert_equal "${lines[0]}" "${HARBOR_ROOT}/lib/runtime.sh"
  # lib/node.sh registers the prefix reader at source time; lib/agents.sh (Task 6)
  # registers claude and codex the same way, stood in for here by a local reader so
  # this file depends on no library a later task creates.
  # shellcheck source=lib/versions.sh
  . "${HARBOR_ROOT}/lib/versions.sh"
  # shellcheck source=lib/node.sh
  . "${HARBOR_ROOT}/lib/node.sh"
  harbor_runtime_reader_register claude reader_claude
  assert_equal "$(harbor_runtime_reader_for prefix)" harbor_node_prefix_version
  assert_equal "$(harbor_journal_observe runtime-install claude)" '"claude:claude"'
  assert_equal "$(harbor_journal_observe runtime-install "${BATS_TEST_TMPDIR}/prefix")" '"absent"'
}

@test "registering a name twice with the same reader is a no-op, and with a different one is refused" {
  # Double-sourcing is deliberate in node/bootstrap.sh, so the idempotent case has to
  # stay silent. A genuine collision is the defect this whole file exists to fix, one
  # level down, so it is a refusal rather than a first-match win nobody sees.
  harbor_runtime_reader_register widget reader_witness
  run harbor_runtime_reader_register widget reader_witness
  assert_success
  assert_output ''
  run harbor_runtime_reader_for widget
  assert_output reader_witness
  run harbor_runtime_reader_register widget some_other_reader
  assert_failure 2
  assert_output --partial 'runtime.reader_conflict'
  assert_output --partial 'already read by reader_witness'
  assert_output --partial 'some_other_reader claims it too'
  # The refusal leaves the registry as it was, so the owning library still answers.
  run harbor_runtime_reader_for widget
  assert_output reader_witness
}

@test "a reader that is not a function this process defined is unobservable: undefined, a builtin, or a command on PATH" {
  # A library that registered and then failed to finish sourcing would otherwise take
  # recovery down with a command-not-found instead of an answer it can act on. The
  # builtin and PATH cases are the reason the test is declare -F and not command -v:
  # the registry survives a re-source, so it can arrive from the environment, and the
  # operator account that would export it is the same untrusted account the agents run
  # as. Under command -v each of these would have run and its output would have become
  # what the journal entry says the runtime's version is.
  harbor_runtime_reader_register ghost harbor_reader_that_was_never_defined
  run harbor_journal_observe runtime-install ghost
  assert_success
  assert_output '"unobservable:runtime-install:ghost"'
  harbor_runtime_reader_register builtin printf
  run harbor_journal_observe runtime-install builtin
  assert_success
  assert_output '"unobservable:runtime-install:builtin"'
  harbor_runtime_reader_register onpath echo
  run harbor_journal_observe runtime-install onpath
  assert_success
  assert_output '"unobservable:runtime-install:onpath"'
}

@test "a registry from the environment is dropped, so it decides nothing and blocks nothing" {
  # The registry is kept across a re-source inside one process, which also makes it
  # inheritable, and the account that would export one is the operator the agents run
  # as. Two things must not follow from that. It must not get to say what a
  # runtime-install entry records. And a conflicting pair in it must not turn a
  # library's source-time registration into a runtime.reader_conflict, which for
  # lib/node.sh would abort harbor bootstrap before preflight.
  HARBOR_RUNTIME_READERS=" claude:printf" \
    run bash -c '. "${HARBOR_ROOT}/lib/log.sh"; . "${HARBOR_ROOT}/lib/journal.sh"; . "${HARBOR_ROOT}/lib/runtime.sh"; harbor_journal_observe runtime-install claude'
  assert_success
  assert_output '"unobservable:runtime-install:claude"'
  HARBOR_RUNTIME_READERS=" prefix:some_other_reader" \
    run bash -c '. "${HARBOR_ROOT}/lib/log.sh"; . "${HARBOR_ROOT}/lib/journal.sh"; . "${HARBOR_ROOT}/lib/versions.sh"; . "${HARBOR_ROOT}/lib/runtime.sh"; . "${HARBOR_ROOT}/lib/node.sh"; harbor_runtime_reader_for prefix'
  assert_success
  assert_output harbor_node_prefix_version
}

@test "the target vocabulary means the same thing in a locale whose collation folds case" {
  # A bracket range is resolved by the locale's collating order, so [a-z] covers the
  # uppercase letters under en_US.UTF-8 — the locale the macOS runners set. This fence
  # stands between a journal file's contents and a function call, so it has to be the
  # same fence everywhere.
  harbor_runtime_reader_register prefix reader_witness
  local out
  out="$(LC_ALL=en_US.UTF-8 bash -c '. "${HARBOR_ROOT}/lib/log.sh"; . "${HARBOR_ROOT}/lib/journal.sh"; . "${HARBOR_ROOT}/lib/runtime.sh"; harbor_observe_op_runtime_install Claude')"
  assert_equal "${out}" '"unobservable:runtime-install:Claude"'
}

@test "re-sourcing lib/runtime.sh keeps the registry, so readers registered above it survive" {
  # bin/harbor sources lib/ and then sources node/bootstrap.sh into the same process,
  # which sources much of lib/ again. A registry that emptied on that second pass would
  # lose every reader whose library is not sourced again below it, and each of those
  # runtimes' prepared entries would read as unobservable — a manual journal resolution
  # for the operator, caused by nothing but the order of two source lines.
  harbor_runtime_reader_register prefix reader_witness
  harbor_runtime_reader_register claude reader_claude
  # shellcheck source=lib/runtime.sh
  . "${HARBOR_ROOT}/lib/runtime.sh"
  assert_equal "$(harbor_runtime_reader_for prefix)" reader_witness
  assert_equal "$(harbor_runtime_reader_for claude)" reader_claude
  assert_equal "$(harbor_journal_observe runtime-install claude)" '"claude:claude"'
}
