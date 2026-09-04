# Harbor Foundation (PR 2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Implementation workers never commit, push, or open a pull request: every task ends in the handoff described under "Working conventions", and the orchestrator commits after review. Where a skill's own flow says to commit, this plan wins.

**Goal:** Ship PR 2 of Harbor: the public front door, the `bin/harbor` dispatcher, the five foundation libraries (`log`, `checks`, `versions`, `lock`, `journal`) with `harbor journal resolve`, the Bats harness and shim skeleton, and the `lint.yml` and `test.yml` workflows, all green on `ubuntu-24.04`, `macos-14`, and `macos-latest`.

**Architecture:** Plain bash 3.2 libraries under `lib/` sourced by a logic-free dispatcher in `bin/harbor`; per-principal state roots hold a `reclaim.d`-gated `lock.d` and a journal of one `NNNN-<op>.json` file per transaction, written crash-safe with `ln` and rename-over. Unit tests source the libraries against disposable roots under `BATS_TEST_TMPDIR` and drive the one public command PR 2 ships, `harbor journal resolve`, through fixture homes; two `HARBOR_TEST_HOOKS`-gated hooks in `lib/log.sh` crash or pause a process at named step boundaries so lock races are observable through filesystem state, the pause resuming on a sentinel file derived from the paused process's PID and the step.

**Tech Stack:** bash 3.2 (macOS system shell) and bash 5 (Ubuntu), coreutils/BSD userland, Bats (bats-core v1.11.0, bats-support v0.3.0, bats-assert v2.1.0 as git submodules), ShellCheck, shfmt v3.8.0, gitleaks v8.18.4, markdownlint-cli 0.41.0, GitHub Actions.

> **Layout (decided 2026-09-02):** all of Harbor's code lives under `fleet/` in the repository: `fleet/bin`, `fleet/lib`, `fleet/tests`, `fleet/versions.lock`. Documents (`README.md`, `SECURITY.md`, `CONTRIBUTING.md`, `LICENSE`, `docs/`) and `.github/workflows/` stay at the repository root. Every code path in this plan is relative to `fleet/` unless it starts with `docs/`, `.github/`, `.markdownlint.yml`, `.gitleaks.toml`, or is one of the four root documents; `HARBOR_ROOT` in the test helper is the `fleet/` directory. Workflows in Task 18 use `working-directory: fleet` for the unit lane and `fleet/`-prefixed paths for the static lane.

## Global Constraints

- Shell floor (spec section 2): "bash 3.2 subset for `client/` and `lib/`; bash 5 permitted in `node/`. Enforced by ShellCheck and the pinned `macos-14` runner". PR 2 ships no `node/` code, so every file in `bin/`, `lib/`, and `tests/` written in this plan is bash 3.2: no associative arrays, no `readlink -f`, no `mapfile`, no `${var,,}`, no `[[ =~ ]]` capture groups, `${1+"$@"}` for a possibly empty argument list under `set -u`.
- Failure handling (spec section 6.2): "Every script runs with `set -euo pipefail` and an `ERR` trap that prints the failing step, the command, and the operator's next command." Exit codes: "0 success or no change, 1 degraded or attended step needed, 2 broken or apply failed, 3 precondition or usage error, 4 interrupted." In PR 2 this applies to every executable shell script: `bin/harbor`, `tests/run_unit.sh`, `tests/shims/bin/harbor-shim`, and `tests/lint/placeholder_scan.sh` each begin with `set -euo pipefail`; sourced libraries and the Bats helper inherit the caller's options and set none. Every possibly empty argument list is expanded as `${1+"$@"}` (or `${1+"$*"}`) so the scripts stay correct under `set -u` on every bash the floor allows.
- Unknown subcommand (spec section 4): the dispatcher answers "before any preflight, lock, or journal access and whether or not `--json` was given, with exit 3 and exactly one JSON object on stdout, `{"error":"unknown_subcommand","subcommand":"<name>"}`, plus a one-line human message on stderr."
- Lock roots and modes (spec section 3.7): `/var/lib/harbor/` for root, `~/.local/state/harbor/` for the operator; "under the root state root, `lock.d/holder` and `reclaim.d/holder` are `0644` inside `0755` directories"; "under an operator state root, which is itself `0700`, the `lock.d` and `reclaim.d` directories are `0700` and their holder records `0600`". Every acquisition passes through `reclaim.d` "with no wait or retry at any step".
- Journal write protocol (spec section 3.7): prepared entry to a temporary file, `fsync`, `ln` to `NNNN-<op>.json` ("fails with `EEXIST` rather than overwriting"), unlink the temporary file, `fsync` the directory; phase rewrites are "renaming it over the existing entry"; "on macOS ... the client journal may fall back to a whole-filesystem `sync`. Ubuntu never uses the fallback."
- Recovery (spec section 3.7): equal to `pre_state` marks `reverted`, equal to `post_state` marks `applied`, "Neither: refuse to continue, exit 2, and print the entry (`op`, `target`, `pre_state`, `post_state`) beside the observed state, mutating nothing."
- Test hooks (spec section 7): `HARBOR_FAIL_AFTER=<step>` and `HARBOR_PAUSE_AFTER=<step>` live in "one function in `lib/log.sh` that every step boundary calls", and are "inert unless `HARBOR_TEST_HOOKS=1` is also present in the process environment". Both variables carry exactly a step name and there is no third hook variable. The "test-controlled file" a pause waits for is derived, never configured: `${TMPDIR:-/tmp}/harbor-pause.<pid>.<step>` with any trailing slash stripped from `TMPDIR`, where `<pid>` is the top-level Harbor PID (`HARBOR_PID`, the value the holder record carries). A test that knows the PID (`$!` of a directly launched `bin/harbor` or `bash -c`) or reads it from `lock.d/holder` or `reclaim.d/holder` can therefore create the sentinel for any paused process, including, in later PRs, a root process launched through `sudo env` whose PID only the holder record reveals. The hook removes the sentinel once seen, best effort, so a fixture that cannot rely on that (a sentinel owned by another user in sticky `/tmp`) removes it itself.
- Placeholders (spec section 3.8): documentation and tests use only `harbor-node`, `TAILNET.ts.net`, `TAILNET_IP`, `OPERATOR`, `operator@example.com`, `RELAY_HOSTNAME`. The repository contains no secrets, live IPs, private hostnames, or personal emails. This plan is itself a tracked file scanned by CI, so it uses only those identifiers.
- Static lane (spec section 7): "ShellCheck (`-s bash -x -S warning`, `require-variable-braces`, `check-sourced`); shfmt (`-i 2 -ci -bn -d`); gitleaks with the section 3.8 rules; a placeholder scan over every tracked file except `tests/fixtures` for work-in-progress markers and any identifier outside the placeholder list; markdownlint with line length disabled."
- Unit lane (spec section 7): "runs on `ubuntu-24.04`, `macos-14` (the pinned compatibility runner, system bash 3.2), and `macos-latest`". Unit tests "never stage into the real `/usr/local`, never touch `/var/lib`, and never invoke a root-mutating public command". Lock tests run on all three runners.
- Merge gate (spec section 8, PR 2 row): "lint and unit green on all runners, including the lock tests under macOS bash 3.2".
- Scope (spec section 8): PR 2 adds no bootstrap, networking, vendor adapter, `status`, `upgrade`, or `teardown` behavior. `versions.lock` is schema-only: all thirteen keys present with empty values.
- License (spec section 9, decision 8): "MIT, added in PR 2. This is a recommendation subject to owner review on this PR."
- Size guideline (spec section 8): "under 600 changed lines excluding fixtures and vendored test helpers". PR 2's mandated test list exceeds this; the PR description states the overrun and its cause.

---

## Working conventions for every task

- Work in the worktree `/Users/krishgarg/Documents/products/harbor/.worktrees/foundation` on branch `feat/foundation`. Run every code command from its `fleet/` directory; run markdownlint and git commands from the worktree root.
- Run unit tests only through `tests/run_unit.sh` (created in Task 2). On macOS it prepends `/bin:/usr/bin` to `PATH` so Bats runs under the system bash 3.2, which is what `macos-14` does in CI. On Ubuntu it runs bash 5. Before you hand any task off, run it under both if you have both; at minimum run it under whatever you have and rely on CI for the other.
- Every "Run" line in this plan gives the exact command. "Expected" states the exact outcome. If the outcome differs, stop and fix the current task; do not proceed.
- Shell style, enforced by Task 18's lint: two-space indentation, `case` arms indented one level, `;;` on its own line unless the arm is one command, redirections written without a space (`>"${file}"`), every variable braced (`"${var}"`), no line longer than needed but no wrapping rule. Every shell script (`bin/harbor`, `lib/*.sh`, `tests/run_unit.sh`, `tests/shims/bin/harbor-shim`, `tests/lint/placeholder_scan.sh`, `tests/unit/test_helper.bash`) starts with `#!/bin/bash`; Bats files start with `#!/usr/bin/env bats`; Markdown, YAML, TOML, text, and fixture files carry no shebang.
- Every library function is prefixed `harbor_`, every global `HARBOR_`. Libraries define functions only; the only top-level statements are `# shellcheck` directives and constant assignments named in this plan.
- Ownership of git operations. Fable writes each task's code; the orchestrator reviews it before anything is committed. Every task therefore ends with a handoff step instead of a commit: the implementation worker stops, reports the test commands it ran with their results, `git status --short`, and `git diff --stat` (the full diff when asked), and leaves the work uncommitted in the worktree. The orchestrator then requests the required Fable pre-commit review, reviews the change independently, and, after approval, stages the files listed in the handoff step and creates the commit with the message given there. A worker never runs `git commit`, `git push`, or `gh pr create`, and never amends, rebases, or resets. The orchestrator also owns the push and the pull request in Task 19; a worker's part of Task 19 ends with its verification report.
- A handoff with a failing test, a lint finding, or a diff outside the task's file list is not ready: say so in the report rather than working around it, and do not start the next task until the orchestrator has committed the current one.

## File map

| File | Responsibility |
| --- | --- |
| `README.md` | Front door: what Harbor is, honest status (design done, PR 2 foundation only, nothing installs anything yet), link to the design spec, pointer to the other three documents |
| `SECURITY.md` | How to report a vulnerability (GitHub private vulnerability reporting, no email), what is in scope, the no-secrets rule for reports |
| `CONTRIBUTING.md` | Local lint and unit commands, submodule checkout, PR size guideline, placeholder rule, bash 3.2 rule |
| `LICENSE` | MIT text, copyright Krish Garg, 2026, pending owner review (decision 8) |
| `.markdownlint.yml` | markdownlint configuration: `MD013` off, `MD024` siblings only |
| `.gitmodules` | The three Bats submodules under `tests/vendor/` |
| `.gitleaks.toml` | Default gitleaks rules extended with the six Harbor rules of spec section 3.8 |
| `versions.lock` | Schema-only version lock: thirteen keys, empty values |
| `bin/harbor` | Entry point: strict mode, `$$` capture, root discovery, library sourcing, traps, subcommand dispatch, unknown-subcommand reply; no other logic |
| `lib/log.sh` | Messages, log file, vendor argv redaction, JSON escaping, `harbor_die`, step boundaries with the hook function, traps |
| `lib/checks.sh` | Check-result accumulator (`id`, `state`, `reason`, `detail`), exit-code derivation, JSON and text rendering |
| `lib/versions.sh` | `versions.lock` loading and validation, per-key lookup, "pinned or die" lookup |
| `lib/lock.sh` | State-root discovery and creation, holder identity and record, holder parsing and classification, gated acquisition, ownership re-check, release |
| `lib/journal.sh` | Observation helpers (sha256, mode, owner), sync helper, canonical entry rendering and parsing, `ln` creation, rename-over phase rewrite, recovery, `harbor journal resolve` |
| `tests/run_unit.sh` | Runs the unit lane exactly as `test.yml` does, pinning macOS to `/bin/bash` 3.2 |
| `tests/unit/test_helper.bash` | Shared Bats setup: paths, bats-support and bats-assert, library loading, fixture homes, fixture journal entries, helpers for polling, holder forging, holder PID discovery, and pause sentinels |
| `tests/unit/lib/harness.bats` | Proves the harness itself: helper loads, fixtures land under `BATS_TEST_TMPDIR`, sentinel derivation, bash version assertion on macOS |
| `tests/unit/lib/log.bats` | Messages, `harbor_die`, JSON escaping, log file lines, argv redaction, step boundaries, both hooks, the exact pause sentinel, gating, traps |
| `tests/unit/lib/checks.bats` | Check accumulator states, exit-code rule, JSON and text output |
| `tests/unit/lib/versions.bats` | Lock parsing and every rejection, shipped `versions.lock` validity |
| `tests/unit/lib/lock.bats` | Identity, holder record (one-line command line) and strict parsing, state-root modes, acquisition, gate refusal, classification, reclaim with suffixed archives, refusal, release with the subshell guard, library-level double contenders and interrupted acquisitions, ownership re-check |
| `tests/unit/lib/journal.bats` | Observation, sync helper, rendering and field parsing, canonical-shape validation (every core key once in order, all-or-nothing resolution pair, no extra keys, lines, or trailing content), `ln` creation and collision, phase rewrite, owner refusal, three recovery outcomes, malformed refusal before any rewrite, lenient mode |
| `tests/unit/bin/dispatch.bats` | Dispatcher: unknown subcommand reply, `--json` indifference, no state touched, help and empty invocation, `journal` usage |
| `tests/unit/bin/resolve.bats` | `harbor journal resolve` through the public command (operator branch) and in-process with the root state root redirected (root branch): state-root creation or refusal, modes, refusals, typed confirmation, malformed entry, three-entry case, next ordinary recovery still failing |
| `tests/unit/bin/contention.bats` | Acceptance of every lock case of spec section 7 through the public command: held lock, nested command, both double contenders, both interrupted acquisitions, ownership re-check; each traces to a library-level red test in Task 8 or 9 |
| `tests/unit/lib/shim.bats` | Shim skeleton: symlink naming, fixture replies, exit files, missing fixtures, shim log |
| `tests/unit/lib/placeholder_scan.bats` | Placeholder scan against fixtures in a temporary git repository |
| `tests/shims/bin/harbor-shim` | Generic vendor shim; vendor shims are symlinks to it |
| `tests/shims/bin/fakevendor` | Symlink to `harbor-shim` used by the shim self-test |
| `tests/fixtures/shims/fakevendor/healthy/version.out` | Shim reply fixture |
| `tests/fixtures/shims/fakevendor/failing/version.out`, `.../version.exit` | Shim reply fixture with a non-zero exit |
| `tests/lint/placeholder-patterns.txt` | Extended regular expressions for the placeholder scan, written so the file passes its own scan |
| `tests/lint/placeholder_scan.sh` | The placeholder scan run by `lint.yml`: every tracked regular file except `tests/fixtures/` |
| `.github/workflows/lint.yml` | ShellCheck, shfmt, gitleaks, placeholder scan, markdownlint on `ubuntu-24.04` |
| `.github/workflows/test.yml` | Unit lane on `ubuntu-24.04`, `macos-14`, `macos-latest` |

Directories `tests/integration/` and `tests/smoke/` are not created in PR 2; they arrive with the lanes that use them.

---

### Task 1: Front door documents, LICENSE, markdownlint configuration

**Files:**

- Create: `README.md`
- Create: `SECURITY.md`
- Create: `CONTRIBUTING.md`
- Create: `LICENSE`
- Create: `.markdownlint.yml`

**Interfaces:**

- Consumes: nothing.
- Produces: `.markdownlint.yml` consumed by Task 19's `lint.yml`; `CONTRIBUTING.md` sections "Lint locally" and "Unit tests locally" that Task 19 fills with the final commands.

- [ ] **Step 1: Write the failing check**

The check for documents is markdownlint plus the placeholder rule. Run it before the files exist so you see it fail on the missing configuration:

Run: `npx --yes markdownlint-cli@0.41.0 --config .markdownlint.yml README.md SECURITY.md CONTRIBUTING.md`
Expected: FAIL, "ENOENT: no such file or directory, open '.markdownlint.yml'" (or equivalent) because none of the files exist yet.

- [ ] **Step 2: Write `.markdownlint.yml`**

```yaml
# markdownlint configuration (design section 7): line length disabled.
default: true
MD013: false
MD024:
  siblings_only: true
```

- [ ] **Step 3: Write `README.md`**

```markdown
# Harbor

Harbor provisions a single Ubuntu 24.04 node as a T3 Code agent host and pairs a macOS
controller with it, using only the vendors' own tools (Tailscale, Node.js, Claude Code, Codex,
`t3`), with every mutation journaled so it can be inspected and undone exactly.

## Status

Design complete, implementation in progress. This repository currently contains:

- the approved design specification, `docs/superpowers/specs/2026-09-01-harbor-design.md`;
- the foundation from PR 2: the `bin/harbor` dispatcher, the `lib/` libraries for logging,
  checks, version pinning, the command lock, and the ownership journal, the `harbor journal
  resolve` command, and the Bats test harness.

Nothing here installs, configures, or removes anything on a node yet. `harbor bootstrap`,
`harbor provision`, `harbor status`, `harbor upgrade`, `harbor teardown`, and the macOS client
arrive in later pull requests in the order given by section 8 of the design.

## Layout

- `bin/harbor`: the single entry point. It dispatches subcommands and contains no logic.
- `lib/`: `log.sh`, `checks.sh`, `versions.sh`, `lock.sh`, `journal.sh`.
- `versions.lock`: exact third-party versions, one per key. Empty until each component's PR.
- `tests/`: Bats unit tests, vendor shims, fixtures, and the placeholder scan.
- `docs/superpowers/specs/`: the design. `docs/superpowers/plans/`: per-PR implementation plans.

## Running the checks

See `CONTRIBUTING.md` for the exact lint and unit-test commands. They are the same commands
CI runs.

## Documents

- Design: `docs/superpowers/specs/2026-09-01-harbor-design.md`
- Security policy: `SECURITY.md`
- Contributing: `CONTRIBUTING.md`
- License: `LICENSE`
```

- [ ] **Step 4: Write `SECURITY.md`**

```markdown
# Security policy

## Reporting a vulnerability

Report vulnerabilities through GitHub's private vulnerability reporting on this repository
("Security" tab, "Report a vulnerability"). Do not open a public issue for a security problem.
There is no reporting email address.

Expect an acknowledgement within seven days. Fixes ship as ordinary pull requests once a
mitigation exists; the advisory is published when the fix is merged.

## Scope

In scope: anything Harbor itself does on the node or the Mac, including the command lock, the
ownership journal, file modes, firewall and SSH changes, and how Harbor invokes vendor tools.

Out of scope: vulnerabilities in Tailscale, Node.js, Claude Code, Codex, or T3 Code themselves.
Report those to their vendors.

## What not to include in a report

Harbor's design (section 3.8) keeps secrets, tailnet IPs, private hostnames, personal emails,
pairing URLs, and tokens out of this repository. The same applies to reports: describe the
problem with the placeholders the design uses (`harbor-node`, `TAILNET.ts.net`, `TAILNET_IP`,
`OPERATOR`, `operator@example.com`, `RELAY_HOSTNAME`) and never paste a token, key, auth URL, or
log file that might contain one.
```

- [ ] **Step 5: Write `CONTRIBUTING.md`**

Task 18 re-checks the two command blocks against the workflows; write them now exactly as below so the document is complete at every commit.

````markdown
# Contributing

## Ground rules

- Read `docs/superpowers/specs/2026-09-01-harbor-design.md` first. Pull requests follow the
  order and scope of its section 8 table; behavior outside the current PR's row is deferred,
  not squeezed in.
- `bin/`, `lib/`, `client/`, and `tests/` are bash 3.2: they must run under macOS's system
  `/bin/bash`. Only `node/` may use bash 5 features.
- No secrets, live tailnet IPs, private hostnames, or personal emails anywhere in the tree.
  Documentation and tests use only the placeholders from design section 3.8: `harbor-node`,
  `TAILNET.ts.net`, `TAILNET_IP`, `OPERATOR`, `operator@example.com`, `RELAY_HOSTNAME`.
- No work-in-progress markers in tracked files. The placeholder scan rejects them.
- Keep a pull request under about 600 changed lines excluding fixtures and vendored helpers.
  When a PR must exceed that, say why in its description.

## Checkout

The Bats libraries are git submodules:

```sh
git clone --recurse-submodules <repository-url>
# or, in an existing clone:
git submodule update --init --recursive
```

## Lint locally

```sh
shellcheck -s bash -x -a -S warning -P 'SCRIPTDIR/..:SCRIPTDIR/../..' --enable=require-variable-braces \
  bin/harbor lib/*.sh tests/run_unit.sh tests/shims/bin/harbor-shim \
  tests/lint/placeholder_scan.sh tests/unit/test_helper.bash
shfmt -i 2 -ci -bn -d bin/harbor lib tests/run_unit.sh tests/shims/bin/harbor-shim \
  tests/lint/placeholder_scan.sh tests/unit/test_helper.bash
tests/lint/placeholder_scan.sh
gitleaks detect --source . --config .gitleaks.toml --no-banner --redact
npx --yes markdownlint-cli@0.41.0 --config .markdownlint.yml '**/*.md' --ignore tests/vendor
```

Install: `shellcheck` from your package manager; `go install mvdan.cc/sh/v3/cmd/shfmt@v3.8.0`;
gitleaks 8.18.4 from its GitHub release; Node.js for `npx`.

## Unit tests locally

```sh
tests/run_unit.sh                       # everything, as CI runs it
tests/run_unit.sh tests/unit/lib/lock.bats
```

On macOS the runner pins `PATH` so Bats executes under `/bin/bash` 3.2, which is what the
`macos-14` job in CI does. Run the suite on both an Ubuntu machine and a Mac before opening a
PR when you touched `lib/` or `bin/`.

## Commit and PR conventions

- Conventional prefixes: `feat:`, `fix:`, `test:`, `docs:`, `ci:`, `chore:`.
- One PR per section 8 row. The PR description names the row, lists the section 7 tests it
  adds, and, when it cannot be automated, the runbook checks re-run by hand.
````

- [ ] **Step 6: Write `LICENSE`**

```text
MIT License

Copyright (c) 2026 Krish Garg

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

- [ ] **Step 7: Run the check to verify it passes**

Run: `npx --yes markdownlint-cli@0.41.0 --config .markdownlint.yml README.md SECURITY.md CONTRIBUTING.md docs/superpowers/specs/2026-09-01-harbor-design.md docs/superpowers/plans/2026-09-02-harbor-foundation.md`
Expected: no output, exit 0.

Run: `grep -nE 'T[O]DO|F[I]XME|X[X]X|T[B]D' README.md SECURITY.md CONTRIBUTING.md LICENSE; echo "rc=$?"`
Expected: `rc=1` (no matches).

- [ ] **Step 8: Hand off for review (no commit)**

Stop here and report as described under "Working conventions": the test commands run in this task with their results, `git status --short`, and `git diff --stat`. Do not run `git commit`. After the Fable pre-commit review and the orchestrator's own review, the orchestrator stages and commits:

- Files: `README.md`, `SECURITY.md`, `CONTRIBUTING.md`, `LICENSE`, `.markdownlint.yml`
- Message: `docs: add README, SECURITY, CONTRIBUTING, and MIT LICENSE`

---

### Task 2: Bats harness

**Files:**

- Create: `.gitmodules` (via `git submodule add`)
- Create: `tests/vendor/bats-core`, `tests/vendor/bats-support`, `tests/vendor/bats-assert` (submodules)
- Create: `tests/run_unit.sh`
- Create: `tests/unit/test_helper.bash`
- Test: `tests/unit/lib/harness.bats`

**Interfaces:**

- Consumes: nothing.
- Produces, for every later test file:
  - `HARBOR_ROOT` (repository root, exported), `HARBOR` (`${HARBOR_ROOT}/bin/harbor`).
  - `harbor_load_libs`: sources the five libraries into the test shell.
  - `fixture_home`: sets `FIX_HOME` (a fresh directory) and `FIX_ROOT="${FIX_HOME}/.local/state/harbor"` without creating `FIX_ROOT`.
  - `fixture_state_root`: `fixture_home` plus `FIX_ROOT/journal` created with mode `0700`.
  - `fixture_entry ROOT SEQ OP TARGET OWNERSHIP PHASE PRE_JSON POST_JSON`: writes a canonical entry `ROOT/journal/SEQ-OP.json`.
  - `fixture_undecidable_file_entry ROOT SEQ`: prepared `file` entry whose target matches neither state; sets `FIX_ARTIFACT_<SEQ>`.
  - `entry_phase ROOT SEQ`, `entry_raw ROOT SEQ KEY`: read a field back from an entry.
  - `resolve_cmd TYPED SEQ [ENV=VALUE...]`: runs `harbor journal resolve SEQ --reverted` under `HOME=FIX_HOME` with `TYPED` on stdin through a here-string (no pipeline subshell). Every planned call runs under Bats `run`. Callers must not assume a backgrounded call's `$!` is the `bin/harbor` process: backgrounding a function forks a subshell first, and `$!` is that subshell. Background pause tests launch `env ... bin/harbor` directly (env execs it, so `$!` is Harbor) or discover the PID from the holder record via `holder_pid`/`resume_holder`.
  - `wait_for_log_step ROOT STEP`, `wait_for_one_exit PID PID`, `holder_record PID START_TIME [CMDLINE]`.
  - `pause_sentinel PID STEP`: prints the Task 4 sentinel path for PID paused at STEP; `holder_pid ROOT`: prints the `pid` line of `ROOT/lock.d/holder`; `resume_holder ROOT STEP`: creates the sentinel for the current holder of ROOT.
  - `tests/run_unit.sh [bats-args]`: runs Bats under the correct shell.

- [ ] **Step 1: Add the submodules and the runner**

```bash
git submodule add https://github.com/bats-core/bats-core.git tests/vendor/bats-core
git -C tests/vendor/bats-core checkout v1.11.0
git submodule add https://github.com/bats-core/bats-support.git tests/vendor/bats-support
git -C tests/vendor/bats-support checkout v0.3.0
git submodule add https://github.com/bats-core/bats-assert.git tests/vendor/bats-assert
git -C tests/vendor/bats-assert checkout v2.1.0
git add .gitmodules tests/vendor
```

Write `tests/run_unit.sh`:

```bash
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
```

Run: `chmod +x tests/run_unit.sh`

- [ ] **Step 2: Write the failing harness test**

`tests/unit/lib/harness.bats`:

```bash
#!/usr/bin/env bats
load '../test_helper'

@test "helper exposes the repository root and the entry point path" {
  assert [ -d "${HARBOR_ROOT}/tests/unit" ]
  assert_equal "${HARBOR}" "${HARBOR_ROOT}/bin/harbor"
}

@test "fixture_home creates HOME but not the state root" {
  fixture_home
  assert [ -d "${FIX_HOME}" ]
  assert [ ! -e "${FIX_ROOT}" ]
  case "${FIX_HOME}" in
    "${BATS_TEST_TMPDIR}"/*) ;;
    *) fail "fixture home ${FIX_HOME} is outside BATS_TEST_TMPDIR" ;;
  esac
}

@test "fixture_state_root creates a 0700 root with a 0700 journal" {
  fixture_state_root
  assert [ -d "${FIX_ROOT}/journal" ]
  run ls -ld "${FIX_ROOT}" "${FIX_ROOT}/journal"
  assert_line --index 0 --regexp '^drwx------'
  assert_line --index 1 --regexp '^drwx------'
}

@test "fixture_entry writes a canonical entry that entry_phase and entry_raw read back" {
  fixture_state_root
  fixture_entry "${FIX_ROOT}" 0007 file /tmp/x created prepared '"absent"' '{"sha256":"ab","mode":"0644","owner":"me"}'
  assert [ -f "${FIX_ROOT}/journal/0007-file.json" ]
  assert_equal "$(entry_phase "${FIX_ROOT}" 0007)" prepared
  assert_equal "$(entry_raw "${FIX_ROOT}" 0007 post_state)" '{"sha256":"ab","mode":"0644","owner":"me"}'
  assert_equal "$(entry_raw "${FIX_ROOT}" 0007 pre_state)" '"absent"'
}

@test "pause_sentinel builds the Task 4 sentinel path under TMPDIR without a double slash" {
  assert_equal "$(TMPDIR=/x/ pause_sentinel 4242 lock-gate)" /x/harbor-pause.4242.lock-gate
  assert_equal "$(TMPDIR=/x pause_sentinel 4242 lock-gate)" /x/harbor-pause.4242.lock-gate
  assert_equal "$(unset TMPDIR; pause_sentinel 4242 resolve-confirmed)" /tmp/harbor-pause.4242.resolve-confirmed
}

@test "on macos-14 the suite runs under bash 3.2" {
  if [ "$(uname -s)" = "Darwin" ] && [ "${HARBOR_EXPECT_BASH32:-0}" = "1" ]; then
    case "${BASH_VERSION}" in
      3.2.*) ;;
      *) fail "expected bash 3.2 under macos-14, got ${BASH_VERSION}" ;;
    esac
  else
    skip "bash version pin is asserted only where HARBOR_EXPECT_BASH32=1"
  fi
}
```

- [ ] **Step 3: Run it to verify it fails**

Run: `tests/run_unit.sh tests/unit/lib/harness.bats`
Expected: FAIL. Bats reports the file cannot load `../test_helper` (the helper does not exist yet).

- [ ] **Step 4: Write `tests/unit/test_helper.bash`**

```bash
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
```

Note `HARBOR_DEV=1` in `resolve_cmd`: PR 3 adds the installed-entrypoint preflight that this variable bypasses for checkout runs; PR 2 sets it now so the helper does not change when that arrives. Nothing in PR 2 reads it.

- [ ] **Step 5: Run the harness test to verify it passes**

Run: `tests/run_unit.sh tests/unit/lib/harness.bats`
Expected: `1..6`, five `ok` lines and one `ok ... # skip` (the bash-version test skips outside CI), exit 0. On a Mac also run `HARBOR_EXPECT_BASH32=1 tests/run_unit.sh tests/unit/lib/harness.bats` and expect all six `ok`.

- [ ] **Step 6: Hand off for review (no commit)**

Stop here and report as described under "Working conventions": the test commands run in this task with their results, `git status --short`, and `git diff --stat`. Do not run `git commit`. After the Fable pre-commit review and the orchestrator's own review, the orchestrator stages and commits:

- Files: `.gitmodules`, `tests/vendor`, `tests/run_unit.sh`, `tests/unit/test_helper.bash`, `tests/unit/lib/harness.bats`
- Message: `test: add Bats harness with pinned submodules and unit runner`

---

### Task 3: `lib/log.sh` messages, log file, JSON escaping, `harbor_die`, argv redaction

**Files:**

- Create: `lib/log.sh`
- Test: `tests/unit/lib/log.bats`

**Interfaces:**

- Consumes: nothing.
- Produces (all in `lib/log.sh`):
  - `harbor_utc_now`: prints `YYYYMMDDTHHMMSSZ` in UTC, no newline.
  - `harbor_msg MSG...`: prints `harbor: MSG` to stderr.
  - `harbor_log LEVEL MSG...`: appends `<utc> <level> <msg>` to `${HARBOR_LOG_FILE}` when set; also to stderr as `harbor: <level>: <msg>` when `HARBOR_VERBOSE=1`.
  - `harbor_log_open PATH MODE`: sets `HARBOR_LOG_FILE=PATH`, creates it if absent, applies `chmod MODE`.
  - `harbor_json_escape STR`: prints STR with `\`, `"`, tab, and newline escaped for a JSON string, no surrounding quotes, no newline; trailing newlines in STR are preserved as `\n`.
  - `harbor_die CODE ERROR_ID MSG...`: stderr `harbor: ERROR_ID: MSG`, log line `error ERROR_ID exit=CODE`, stdout `{"error":"ERROR_ID"}` when `HARBOR_JSON=1`, then `exit CODE`.
  - `harbor_redact_argv ARGS...`: prints ARGS joined by spaces with the value after `--auth-key`, `--authkey`, `--token`, `--password`, `--secret`, `--api-key`, `--key` dropped, `--flag=value` forms of those reduced to the flag, and `?query`, `#fragment`, and the `userinfo@` component of the authority stripped from any argument containing `://`.
  - `harbor_log_vendor NAME ARGS...`: `harbor_log vendor` of the redacted argv.

- [ ] **Step 1: Write the failing tests**

`tests/unit/lib/log.bats`:

```bash
#!/usr/bin/env bats
load '../test_helper'

setup() {
  # lib/log.sh depends on nothing, so this file sources it alone rather than
  # through harbor_load_libs, which also loads the libraries later tasks create.
  # shellcheck source=lib/log.sh
  . "${HARBOR_ROOT}/lib/log.sh"
}

@test "harbor_utc_now prints a compact UTC timestamp" {
  run harbor_utc_now
  assert_success
  assert_output --regexp '^[0-9]{8}T[0-9]{6}Z$'
}

@test "harbor_msg writes one prefixed line to stderr and nothing to stdout" {
  run --separate-stderr harbor_msg hello world
  assert_success
  assert_equal "${output}" ""
  assert_equal "${stderr}" "harbor: hello world"
}

@test "harbor_log appends timestamped lines only when a log file is open" {
  run harbor_log step lock-gate
  assert_success
  assert_output ""
  harbor_log_open "${BATS_TEST_TMPDIR}/h.log" 0600
  harbor_log step lock-gate
  harbor_log exit 0
  run cat "${BATS_TEST_TMPDIR}/h.log"
  assert_line --index 0 --regexp '^[0-9]{8}T[0-9]{6}Z step lock-gate$'
  assert_line --index 1 --regexp '^[0-9]{8}T[0-9]{6}Z exit 0$'
  run ls -l "${BATS_TEST_TMPDIR}/h.log"
  assert_output --regexp '^-rw-------'
}

@test "harbor_log echoes to stderr under HARBOR_VERBOSE=1" {
  HARBOR_VERBOSE=1
  run --separate-stderr harbor_log step lock-gate
  assert_equal "${stderr}" "harbor: step: lock-gate"
}

@test "harbor_json_escape escapes backslash, quote, tab, and newline" {
  tab="$(printf '\t')"
  nl="$(printf '\n.')"
  nl="${nl%.}"
  run harbor_json_escape "a\"b\\c${tab}d${nl}e"
  assert_success
  assert_output 'a\"b\\c\td\ne'
  run harbor_json_escape "a${nl}${nl}"
  assert_output 'a\n\n'
  run harbor_json_escape "${nl}a"
  assert_output '\na'
}

@test "harbor_die prints the id and message, exits with the code, and emits JSON only under HARBOR_JSON=1" {
  run --separate-stderr harbor_die 3 lock.busy "held by pid 42"
  assert_equal "${status}" 3
  assert_equal "${output}" ""
  assert_equal "${stderr}" "harbor: lock.busy: held by pid 42"
  HARBOR_JSON=1
  run --separate-stderr harbor_die 2 journal.collision "entry exists"
  assert_equal "${status}" 2
  assert_equal "${output}" '{"error":"journal.collision"}'
  assert_equal "${stderr}" "harbor: journal.collision: entry exists"
}

@test "harbor_die logs the error id and exit code" {
  harbor_log_open "${BATS_TEST_TMPDIR}/h.log" 0600
  run harbor_die 4 hook.pause_timeout "waited"
  assert_equal "${status}" 4
  run cat "${BATS_TEST_TMPDIR}/h.log"
  assert_output --regexp ' error hook.pause_timeout exit=4$'
}

@test "harbor_die keeps its exit code when the log file cannot be written" {
  # A fresh shell under set -euo pipefail, as bin/harbor runs, so a failing log
  # append would abort the shell before exit CODE if harbor_die let it.
  run --separate-stderr /bin/bash -euo pipefail -c \
    '. "${1}"; HARBOR_LOG_FILE="${2}"; harbor_die 3 lock.busy "held"' \
    _ "${HARBOR_ROOT}/lib/log.sh" "${BATS_TEST_TMPDIR}/missing/h.log"
  assert_equal "${status}" 3
  assert_equal "${output}" ""
  assert_equal "${stderr_lines[0]}" "harbor: lock.busy: held"
}

@test "harbor_redact_argv drops secret values and strips URL queries and fragments" {
  run harbor_redact_argv tailscale up --auth-key SECRETVALUE --hostname harbor-node
  assert_output 'tailscale up --auth-key --hostname harbor-node'
  run harbor_redact_argv t3 connect --token=SECRETVALUE 'https://RELAY_HOSTNAME/pair?x=1#frag' --ssh
  assert_output 't3 connect --token https://RELAY_HOSTNAME/pair --ssh'
  run harbor_redact_argv codex --key SECRETVALUE --api-key SECRETVALUE --password SECRETVALUE --secret SECRETVALUE --authkey SECRETVALUE
  assert_output 'codex --key --api-key --password --secret --authkey'
  run harbor_redact_argv curl 'https://user:SECRETPW@RELAY_HOSTNAME/x?y#z'
  assert_output 'curl https://RELAY_HOSTNAME/x'
  refute_output --partial SECRETPW
  run harbor_redact_argv curl 'https://RELAY_HOSTNAME/p@th'
  assert_output 'curl https://RELAY_HOSTNAME/p@th'
  run harbor_redact_argv
  assert_output ''
}

@test "harbor_log_vendor writes the redacted argv at level vendor" {
  harbor_log_open "${BATS_TEST_TMPDIR}/h.log" 0600
  harbor_log_vendor tailscale up --auth-key SECRETVALUE
  run cat "${BATS_TEST_TMPDIR}/h.log"
  assert_output --regexp ' vendor tailscale up --auth-key$'
  refute_output --partial SECRETVALUE
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `tests/run_unit.sh tests/unit/lib/log.bats`
Expected: FAIL. `setup` fails with `lib/log.sh: No such file or directory` for every test.

- [ ] **Step 3: Write `lib/log.sh`**

```bash
#!/bin/bash
# Harbor logging (design section 3.9): messages, the per-principal log file, JSON
# escaping, harbor_die, and vendor argv redaction. Step boundaries, test hooks, and
# traps are added below these functions.
harbor_utc_now() {
  date -u +%Y%m%dT%H%M%SZ
}
harbor_msg() {
  printf 'harbor: %s\n' "${*}" >&2
}
harbor_log() {
  local level="${1}"
  shift
  if [ -n "${HARBOR_LOG_FILE:-}" ]; then
    printf '%s %s %s\n' "$(harbor_utc_now)" "${level}" "${*}" >>"${HARBOR_LOG_FILE}"
  fi
  if [ "${HARBOR_VERBOSE:-0}" = "1" ]; then
    printf 'harbor: %s: %s\n' "${level}" "${*}" >&2
  fi
}
harbor_log_open() {
  HARBOR_LOG_FILE="${1}"
  : >>"${HARBOR_LOG_FILE}"
  chmod "${2}" "${HARBOR_LOG_FILE}"
}
harbor_redact_argv() {
  local out="" arg drop_next=0 sep="" scheme rest authority
  for arg in ${1+"$@"}; do
    if [ "${drop_next}" = 1 ]; then
      drop_next=0
      continue
    fi
    case "${arg}" in
      --auth-key | --authkey | --token | --password | --secret | --api-key | --key)
        drop_next=1
        ;;
      --auth-key=* | --authkey=* | --token=* | --password=* | --secret=* | --api-key=* | --key=*)
        arg="${arg%%=*}"
        ;;
      *://*)
        arg="${arg%%\?*}"
        arg="${arg%%#*}"
        scheme="${arg%%://*}"
        rest="${arg#*://}"
        authority="${rest%%/*}"
        case "${authority}" in
          *@*)
            arg="${scheme}://${authority##*@}"
            case "${rest}" in
              */*)
                arg="${arg}/${rest#*/}"
                ;;
            esac
            ;;
        esac
        ;;
    esac
    out="${out}${sep}${arg}"
    sep=" "
  done
  printf '%s' "${out}"
}
harbor_log_vendor() {
  harbor_log vendor "$(harbor_redact_argv ${1+"$@"})"
}
harbor_json_escape() {
  local tab escaped
  tab="$(printf '\t')"
  escaped="$(printf '%s.' "${1}" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e "s/${tab}/\\\\t/g" \
    | awk 'BEGIN { ORS = "" } { if (NR > 1) printf "\\n"; print }')"
  printf '%s' "${escaped%.}"
}
harbor_die() {
  local code="${1}" id="${2}"
  shift 2
  harbor_msg "${id}: ${*}"
  harbor_log error "${id} exit=${code}" || :
  if [ "${HARBOR_JSON:-0}" = "1" ]; then
    printf '{"error":"%s"}\n' "$(harbor_json_escape "${id}")"
  fi
  exit "${code}"
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `tests/run_unit.sh tests/unit/lib/log.bats`
Expected: `1..10`, all `ok`, exit 0.

- [ ] **Step 5: Hand off for review (no commit)**

Stop here and report as described under "Working conventions": the test commands run in this task with their results, `git status --short`, and `git diff --stat`. Do not run `git commit`. After the Fable pre-commit review and the orchestrator's own review, the orchestrator stages and commits:

- Files: `lib/log.sh`, `tests/unit/lib/log.bats`
- Message: `feat(log): messages, log file, JSON escaping, harbor_die, argv redaction`

---

### Task 4: `lib/log.sh` step boundaries, test hooks, and traps

**Files:**

- Modify: `lib/log.sh` (append after `harbor_die`)
- Test: `tests/unit/lib/log.bats` (append)

**Interfaces:**

- Consumes: `harbor_msg`, `harbor_log`, `harbor_die` from Task 3.
- Produces:
  - `harbor_step NAME`: sets `HARBOR_CURRENT_STEP=NAME`, logs `step NAME`, calls `harbor_test_hook NAME`.
  - `harbor_test_pause_sentinel STEP`: prints `${TMPDIR:-/tmp}/harbor-pause.${HARBOR_PID:-$$}.STEP` with a trailing slash stripped from `TMPDIR`. Called only by the hook, and only once the hook is enabled, so production Harbor reads no hook file.
  - `harbor_test_hook NAME`: the one hook function. Returns immediately unless `HARBOR_TEST_HOOKS=1`. Once enabled, and before either action, it dies with exit 3 `hook.bad_pid` unless `${HARBOR_PID:-$$}` is a decimal PID, so a forged `HARBOR_PID` can never become `kill -KILL -1`. With `HARBOR_FAIL_AFTER=NAME`, sends `SIGKILL` to `${HARBOR_PID:-$$}`. With `HARBOR_PAUSE_AFTER=NAME`, polls every 0.2 s until the sentinel `harbor_test_pause_sentinel NAME` exists, removes it (best effort), and dies with exit 4 `hook.pause_timeout` after 600 polls. Both variables carry a bare step name.
  - `harbor_on_err`: `ERR` trap body printing the failing step, the command, and the next command (`HARBOR_NEXT_COMMAND` or a default). Returns silently inside a subshell (`BASH_SUBSHELL` non-zero), so a failure inside `$( )` is reported once, by the enclosing command in the parent.
  - `harbor_on_interrupt`: sets `HARBOR_INTERRUPTED=1` and exits 4. Installed for `INT`, `TERM`, and `HUP`.
  - `harbor_on_exit`: releases `${HARBOR_LOCK_ROOT}` via `harbor_lock_release` when set (Task 8), first and behind `|| :`, so an interrupt still releases and a failed release cannot replace the exit code; prints `{"error":"interrupted"}` under `HARBOR_JSON=1` after an interrupt and exits 4; maps a status of 0 without `HARBOR_COMPLETED=1` to `harbor_msg "terminated before completion (exit 2)"`, the log line `exit 2 incomplete`, and exit 2; otherwise logs `exit <rc>` and exits with the original code. Every log write in the trap is behind `|| :`.
  - `HARBOR_COMPLETED`: the completion flag. bash 3.2 presents `$?` as 0 inside the EXIT trap after a fatal `set -u` abort, so every normal-success path sets `HARBOR_COMPLETED=1` immediately before it exits 0 (`bin/harbor` does so after its dispatch `case`, Task 13); an exit 0 without it is reported as exit 2.
  - `harbor_install_traps`: `set -E`, installs the three traps: `ERR`, `INT TERM HUP`, `EXIT`.
  - Step names used by PR 2: `lock-gate`, `lock-mkdir`, `lock-acquired`, `recovery-scan`, `resolve-confirmed`.

- [ ] **Step 1: Append the failing tests**

Append to `tests/unit/lib/log.bats`:

```bash
@test "harbor_step records the current step and logs it" {
  harbor_log_open "${BATS_TEST_TMPDIR}/h.log" 0600
  harbor_step lock-gate
  assert_equal "${HARBOR_CURRENT_STEP}" lock-gate
  run cat "${BATS_TEST_TMPDIR}/h.log"
  assert_output --regexp ' step lock-gate$'
}

@test "hooks are inert without HARBOR_TEST_HOOKS=1" {
  run env HARBOR_FAIL_AFTER=lock-gate HARBOR_PAUSE_AFTER=lock-gate \
    bash -c '. "${HARBOR_ROOT}/lib/log.sh"; HARBOR_PID=$$; harbor_step lock-gate; echo survived'
  assert_success
  assert_output survived
  run env HARBOR_TEST_HOOKS=0 HARBOR_FAIL_AFTER=lock-gate HARBOR_PAUSE_AFTER=lock-gate \
    bash -c '. "${HARBOR_ROOT}/lib/log.sh"; HARBOR_PID=$$; harbor_step lock-gate; echo survived'
  assert_success
  assert_output survived
}

@test "the pause sentinel is derived from TMPDIR, HARBOR_PID, and the step, and matches the harness helper" {
  run env TMPDIR=/x/ bash -c '. "${HARBOR_ROOT}/lib/log.sh"; HARBOR_PID=4242; harbor_test_pause_sentinel lock-gate'
  assert_output '/x/harbor-pause.4242.lock-gate'
  run env -u TMPDIR bash -c '. "${HARBOR_ROOT}/lib/log.sh"; HARBOR_PID=4242; harbor_test_pause_sentinel lock-gate'
  assert_output '/tmp/harbor-pause.4242.lock-gate'
  run env TMPDIR=/x bash -c '. "${HARBOR_ROOT}/lib/log.sh"; harbor_test_pause_sentinel resolve-confirmed'
  assert_output --regexp '^/x/harbor-pause\.[0-9]+\.resolve-confirmed$'
  HARBOR_PID=4242
  assert_equal "$(harbor_test_pause_sentinel lock-gate)" "$(pause_sentinel 4242 lock-gate)"
}

@test "HARBOR_FAIL_AFTER kills the process at exactly that boundary" {
  run env HARBOR_TEST_HOOKS=1 HARBOR_FAIL_AFTER=lock-mkdir \
    bash -c '. "${HARBOR_ROOT}/lib/log.sh"; HARBOR_PID=$$; harbor_step lock-gate; echo passed-gate; harbor_step lock-mkdir; echo survived'
  assert_equal "${status}" 137
  assert_output passed-gate
}

@test "HARBOR_PAUSE_AFTER pauses at exactly that step until this process's sentinel appears, then consumes it" {
  env HARBOR_TEST_HOOKS=1 HARBOR_PAUSE_AFTER=lock-acquired \
    bash -c '. "${HARBOR_ROOT}/lib/log.sh"; HARBOR_PID=$$; harbor_step lock-gate; harbor_step lock-acquired; echo resumed' \
    >"${BATS_TEST_TMPDIR}/out" 3>&- &
  pid=$!
  sleep 1
  kill -0 "${pid}"
  assert_equal "$(cat "${BATS_TEST_TMPDIR}/out")" ""
  touch "$(pause_sentinel "$((pid + 1))" lock-acquired)" "$(pause_sentinel "${pid}" lock-gate)"
  sleep 0.5
  kill -0 "${pid}"
  assert_equal "$(cat "${BATS_TEST_TMPDIR}/out")" ""
  touch "$(pause_sentinel "${pid}" lock-acquired)"
  wait "${pid}"
  assert_equal "$(cat "${BATS_TEST_TMPDIR}/out")" resumed
  assert [ ! -e "$(pause_sentinel "${pid}" lock-acquired)" ]
  assert [ -e "$(pause_sentinel "$((pid + 1))" lock-acquired)" ]
  assert [ -e "$(pause_sentinel "${pid}" lock-gate)" ]
  rm -f "$(pause_sentinel "$((pid + 1))" lock-acquired)" "$(pause_sentinel "${pid}" lock-gate)"
}

@test "HARBOR_PAUSE_AFTER for a different step does not pause" {
  run env HARBOR_TEST_HOOKS=1 HARBOR_PAUSE_AFTER=lock-mkdir \
    bash -c '. "${HARBOR_ROOT}/lib/log.sh"; HARBOR_PID=$$; harbor_step lock-gate; echo survived'
  assert_success
  assert_output survived
}

@test "ERR trap names the step, the command, and the next command" {
  run --separate-stderr bash -c '. "${HARBOR_ROOT}/lib/log.sh"; set -euo pipefail; harbor_install_traps; harbor_step lock-gate; false'
  assert_equal "${status}" 1
  assert_regex "${stderr_lines[0]}" '^harbor: failed at step lock-gate \(exit 1\) running: false$'
  assert_equal "${stderr_lines[1]}" 'harbor: next: rerun the same command after fixing the cause'
  run --separate-stderr bash -c '. "${HARBOR_ROOT}/lib/log.sh"; set -euo pipefail; harbor_install_traps; HARBOR_NEXT_COMMAND="harbor journal resolve 0001 --reverted"; false'
  assert_equal "${stderr_lines[1]}" 'harbor: next: harbor journal resolve 0001 --reverted'
}

@test "INT and TERM exit 4 and print the interrupted JSON object under HARBOR_JSON=1" {
  run --separate-stderr bash -c '. "${HARBOR_ROOT}/lib/log.sh"; set -euo pipefail; harbor_install_traps; HARBOR_JSON=1; kill -TERM $$; sleep 5; echo survived'
  assert_equal "${status}" 4
  assert_equal "${output}" '{"error":"interrupted"}'
  run bash -c '. "${HARBOR_ROOT}/lib/log.sh"; set -euo pipefail; harbor_install_traps; kill -INT $$; sleep 5; echo survived'
  assert_equal "${status}" 4
  assert_output ''
}

@test "EXIT trap logs the exit code and preserves it" {
  run bash -c '. "${HARBOR_ROOT}/lib/log.sh"; set -euo pipefail; harbor_install_traps; harbor_log_open "'"${BATS_TEST_TMPDIR}"'/h.log" 0600; exit 3'
  assert_equal "${status}" 3
  run cat "${BATS_TEST_TMPDIR}/h.log"
  assert_output --regexp ' exit 3$'
}

@test "EXIT trap reports exit 2 when the process reaches status 0 without HARBOR_COMPLETED=1" {
  # bash 3.2 presents $? as 0 inside the EXIT trap after a fatal set -u abort, so
  # a crash would otherwise be logged and reported as success. First the exact
  # contract for a plain status 0 with no completion flag, which every bash gives;
  # then the abort itself: exit 2 wherever bash discards the status, never 0.
  run --separate-stderr bash -c '. "${HARBOR_ROOT}/lib/log.sh"; set -euo pipefail; harbor_install_traps; harbor_log_open "'"${BATS_TEST_TMPDIR}"'/h.log" 0600; true'
  assert_equal "${status}" 2
  assert_equal "${stderr}" 'harbor: terminated before completion (exit 2)'
  run tail -n 1 "${BATS_TEST_TMPDIR}/h.log"
  assert_output --regexp ' exit 2 incomplete$'
  probe="$(bash -c 'set -eu; trap "printf %s \$?" EXIT; echo "${NOPE}"' 2>/dev/null)"
  run --separate-stderr bash -c '. "${HARBOR_ROOT}/lib/log.sh"; set -euo pipefail; harbor_install_traps; harbor_log_open "'"${BATS_TEST_TMPDIR}"'/h.log" 0600; echo "${NOPE}"'
  assert_not_equal "${status}" 0
  assert_equal "${output}" ""
  run tail -n 1 "${BATS_TEST_TMPDIR}/h.log"
  if [ "${probe}" = 0 ]; then
    assert_output --regexp ' exit 2 incomplete$'
  else
    assert_output --regexp " exit ${probe}\$"
  fi
}

@test "EXIT trap keeps exit 0 once HARBOR_COMPLETED=1 is set" {
  run --separate-stderr bash -c '. "${HARBOR_ROOT}/lib/log.sh"; set -euo pipefail; harbor_install_traps; harbor_log_open "'"${BATS_TEST_TMPDIR}"'/h.log" 0600; HARBOR_COMPLETED=1; exit 0'
  assert_equal "${status}" 0
  assert_equal "${stderr}" ""
  run tail -n 1 "${BATS_TEST_TMPDIR}/h.log"
  assert_output --regexp ' exit 0$'
}

@test "EXIT trap keeps the exit code and the interrupt contract when the lock release fails" {
  # harbor_lock_release arrives in Task 8; here it is undefined, so the call fails.
  run bash -c '. "${HARBOR_ROOT}/lib/log.sh"; set -euo pipefail; harbor_install_traps; HARBOR_LOCK_ROOT=/tmp/x; exit 3'
  assert_equal "${status}" 3
  run --separate-stderr bash -c '. "${HARBOR_ROOT}/lib/log.sh"; set -euo pipefail; harbor_install_traps; HARBOR_JSON=1; HARBOR_LOCK_ROOT=/tmp/x; kill -TERM $$; sleep 5; echo survived'
  assert_equal "${status}" 4
  assert_equal "${output}" '{"error":"interrupted"}'
}

@test "HUP exits 4 and prints the interrupted JSON object under HARBOR_JSON=1" {
  run --separate-stderr bash -c '. "${HARBOR_ROOT}/lib/log.sh"; set -euo pipefail; harbor_install_traps; HARBOR_JSON=1; kill -HUP $$; sleep 5; echo survived'
  assert_equal "${status}" 4
  assert_equal "${output}" '{"error":"interrupted"}'
}

@test "ERR trap reports a failing command substitution once, naming the enclosing command" {
  run --separate-stderr bash -c '. "${HARBOR_ROOT}/lib/log.sh"; set -euo pipefail; harbor_install_traps; harbor_step lock-gate; v=$(false)'
  assert_equal "${status}" 1
  assert_equal "${#stderr_lines[@]}" 2
  assert_equal "${stderr_lines[0]}" 'harbor: failed at step lock-gate (exit 1) running: v=$(false)'
  assert_equal "${stderr_lines[1]}" 'harbor: next: rerun the same command after fixing the cause'
}

@test "harbor_test_hook refuses a non-numeric HARBOR_PID before signalling, and only once gated" {
  # A witness process proves the refusal happened before any kill: with
  # HARBOR_PID=-1 an unguarded kill -KILL would signal every process of this user.
  sleep 30 3>&- &
  witness=$!
  run --separate-stderr env HARBOR_TEST_HOOKS=1 HARBOR_FAIL_AFTER=lock-gate HARBOR_PID=-1 \
    bash -c '. "${HARBOR_ROOT}/lib/log.sh"; harbor_step lock-gate; echo survived'
  kill -0 "${witness}"
  kill "${witness}"
  assert_equal "${status}" 3
  assert_equal "${output}" ""
  assert_regex "${stderr}" 'hook\.bad_pid'
  run env HARBOR_FAIL_AFTER=lock-gate HARBOR_PID=-1 \
    bash -c '. "${HARBOR_ROOT}/lib/log.sh"; harbor_step lock-gate; echo survived'
  assert_success
  assert_output survived
}
```

`run --separate-stderr` fills `${stderr_lines[@]}` from stderr, which is where `harbor_msg` writes; `${lines[@]}` holds only stdout.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `tests/run_unit.sh tests/unit/lib/log.bats`
Expected: FAIL. The ten Task 3 tests pass; the fifteen new ones fail with `harbor_step: command not found`, `harbor_test_pause_sentinel: command not found`, or `harbor_install_traps: command not found`.

- [ ] **Step 3: Append to `lib/log.sh`**

```bash
harbor_step() {
  HARBOR_CURRENT_STEP="${1}"
  harbor_log step "${1}"
  harbor_test_hook "${1}"
}
# The pause sentinel (design section 7, "a test-controlled file"): derived from the
# top-level PID and the step so a test can create it after reading the holder record.
harbor_test_pause_sentinel() {
  local dir="${TMPDIR:-/tmp}"
  printf '%s/harbor-pause.%s.%s' "${dir%/}" "${HARBOR_PID:-$$}" "${1}"
}
# The only test hook in Harbor (design section 7). Inert unless HARBOR_TEST_HOOKS=1.
# It can only kill or pause the process at a step boundary; it skips no check,
# alters no path, and mutates nothing.
harbor_test_hook() {
  local sentinel i
  [ "${HARBOR_TEST_HOOKS:-0}" = "1" ] || return 0
  case "${HARBOR_PID:-$$}" in
    "" | *[!0-9]*) harbor_die 3 hook.bad_pid "HARBOR_PID must be a decimal PID, got ${HARBOR_PID:-}" ;;
  esac
  if [ "${HARBOR_FAIL_AFTER:-}" = "${1}" ]; then
    kill -KILL "${HARBOR_PID:-$$}"
    exit 4
  fi
  if [ "${HARBOR_PAUSE_AFTER:-}" = "${1}" ]; then
    sentinel="$(harbor_test_pause_sentinel "${1}")"
    i=0
    while [ ! -e "${sentinel}" ]; do
      i=$((i + 1))
      if [ "${i}" -gt 600 ]; then
        harbor_die 4 hook.pause_timeout "paused at ${1} for 120s without ${sentinel}"
      fi
      sleep 0.2
    done
    rm -f "${sentinel}" 2>/dev/null || true
  fi
}
harbor_on_err() {
  local rc=$?
  [ "${BASH_SUBSHELL:-0}" = 0 ] || return 0
  harbor_msg "failed at step ${HARBOR_CURRENT_STEP:-startup} (exit ${rc}) running: ${BASH_COMMAND}"
  harbor_msg "next: ${HARBOR_NEXT_COMMAND:-rerun the same command after fixing the cause}"
}
harbor_on_interrupt() {
  HARBOR_INTERRUPTED=1
  exit 4
}
harbor_on_exit() {
  local rc=$?
  if [ -n "${HARBOR_LOCK_ROOT:-}" ]; then
    harbor_lock_release "${HARBOR_LOCK_ROOT}" || :
  fi
  if [ "${HARBOR_INTERRUPTED:-0}" = "1" ]; then
    if [ "${HARBOR_JSON:-0}" = "1" ]; then
      printf '{"error":"interrupted"}\n'
    fi
    harbor_log exit 4 || :
    exit 4
  fi
  if [ "${rc}" = 0 ] && [ "${HARBOR_COMPLETED:-0}" != "1" ]; then
    harbor_msg "terminated before completion (exit 2)"
    harbor_log exit 2 incomplete || :
    exit 2
  fi
  harbor_log exit "${rc}" || :
  exit "${rc}"
}
harbor_install_traps() {
  set -E
  trap harbor_on_err ERR
  trap harbor_on_interrupt INT TERM HUP
  trap harbor_on_exit EXIT
}
```

`harbor_on_exit` calls `harbor_lock_release`, defined in Task 8, behind `|| :`; the release test above sets `HARBOR_LOCK_ROOT` with no such function defined to prove the guard keeps the exit code and the interrupt reply.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `tests/run_unit.sh tests/unit/lib/log.bats`
Expected: `1..25`, all `ok`, exit 0. The pause test takes about two seconds.

- [ ] **Step 5: Hand off for review (no commit)**

Stop here and report as described under "Working conventions": the test commands run in this task with their results, `git status --short`, and `git diff --stat`. Do not run `git commit`. After the Fable pre-commit review and the orchestrator's own review, the orchestrator stages and commits:

- Files: `lib/log.sh`, `tests/unit/lib/log.bats`
- Message: `feat(log): step boundaries, gated test hooks, and traps`

---

### Task 5: `lib/checks.sh` check accumulator

The design names `lib/checks.sh` as a PR 2 file but defines its behavior only through section 5.6 (check identifiers with a state, a reason, and a detail; `unknown` rows with reasons `requires_root`, `busy`, or `requires_operator` that do not affect the exit code). PR 2 ships the accumulator and the exit-code rule; PR 7 adds the checks themselves.

**Files:**

- Create: `lib/checks.sh`
- Test: `tests/unit/lib/checks.bats`

**Interfaces:**

- Consumes: `harbor_die`, `harbor_json_escape` (Task 3).
- Produces:
  - `HARBOR_CHECKS`: newline-separated records `id<TAB>state<TAB>reason<TAB>detail`.
  - `harbor_check_reset`: empties `HARBOR_CHECKS`.
  - `harbor_check_add ID STATE [REASON] [DETAIL]`: appends one record; STATE must be `pass`, `degraded`, `broken`, or `unknown`, else `harbor_die 3 checks.state`. Tabs in DETAIL become spaces.
  - `harbor_check_exit_code`: prints `2` if any record is `broken`, else `1` if any is `degraded` or is `unknown` with a reason other than `requires_root`, `busy`, `requires_operator`, else `0`.
  - `harbor_checks_json`: prints `{"checks":[{"id":"…","state":"…","reason":"…","detail":"…"},…]}` on one line.
  - `harbor_checks_text`: prints one `id state reason detail` line per record.

- [ ] **Step 1: Write the failing tests**

`tests/unit/lib/checks.bats`:

```bash
#!/usr/bin/env bats
load '../test_helper'

setup() {
  harbor_load_libs
  harbor_check_reset
}

@test "an empty check set exits 0 and renders an empty list" {
  assert_equal "$(harbor_check_exit_code)" 0
  assert_equal "$(harbor_checks_json)" '{"checks":[]}'
  assert_equal "$(harbor_checks_text)" ""
}

@test "pass and unknown with an allowed reason keep exit 0" {
  harbor_check_add tailscale.installed pass
  harbor_check_add ufw.default unknown requires_root "run sudo harbor status --system"
  harbor_check_add sshd.dropin unknown busy
  harbor_check_add t3.linked unknown requires_operator
  assert_equal "$(harbor_check_exit_code)" 0
}

@test "degraded and unknown with another reason give exit 1, broken gives exit 2" {
  harbor_check_add a degraded
  assert_equal "$(harbor_check_exit_code)" 1
  harbor_check_reset
  harbor_check_add root.lock unknown stale_lock "see design section 3.7"
  assert_equal "$(harbor_check_exit_code)" 1
  harbor_check_add b broken "unit not running"
  assert_equal "$(harbor_check_exit_code)" 2
}

@test "an unknown state name is a usage error" {
  run harbor_check_add x maybe
  assert_equal "${status}" 3
  assert_output --partial 'checks.state'
}

@test "JSON output escapes and orders records" {
  harbor_check_add node.version pass "" 'v22 "exact"'
  harbor_check_add ufw.default unknown requires_root
  assert_equal "$(harbor_checks_json)" '{"checks":[{"id":"node.version","state":"pass","reason":"","detail":"v22 \"exact\""},{"id":"ufw.default","state":"unknown","reason":"requires_root","detail":""}]}'
}

@test "text output is one line per record with tabs replaced" {
  tab="$(printf '\t')"
  harbor_check_add node.version pass "" "one${tab}two"
  harbor_check_add b degraded slow
  run harbor_checks_text
  assert_line --index 0 'node.version pass  one two'
  assert_line --index 1 'b degraded slow '
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `tests/run_unit.sh tests/unit/lib/checks.bats`
Expected: FAIL. `setup` fails with `lib/checks.sh: No such file or directory`.

- [ ] **Step 3: Write `lib/checks.sh`**

```bash
#!/bin/bash
# Check results (design section 5.6): an accumulator of id, state, reason, and detail
# records, the exit-code rule, and JSON and text rendering. PR 7 adds the checks.
# shellcheck disable=SC2034
HARBOR_CHECKS=""
harbor_check_reset() {
  HARBOR_CHECKS=""
}
harbor_check_add() {
  local id="${1}" state="${2}" reason="${3:-}" detail="${4:-}" tab
  case "${state}" in
    pass | degraded | broken | unknown) ;;
    *) harbor_die 3 checks.state "unknown check state '${state}' for ${id}" ;;
  esac
  tab="$(printf '\t')"
  detail="$(printf '%s' "${detail}" | tr '\t' ' ')"
  HARBOR_CHECKS="${HARBOR_CHECKS}${id}${tab}${state}${tab}${reason}${tab}${detail}
"
}
harbor_check_exit_code() {
  local worst=0 line state reason
  while IFS= read -r line; do
    [ -n "${line}" ] || continue
    state="$(printf '%s' "${line}" | cut -f2)"
    reason="$(printf '%s' "${line}" | cut -f3)"
    case "${state}" in
      broken) worst=2 ;;
      degraded) [ "${worst}" -ge 1 ] || worst=1 ;;
      unknown)
        case "${reason}" in
          requires_root | busy | requires_operator) ;;
          *) [ "${worst}" -ge 1 ] || worst=1 ;;
        esac
        ;;
    esac
  done <<EOF
${HARBOR_CHECKS}
EOF
  printf '%s' "${worst}"
}
harbor_checks_json() {
  local line sep="" id state reason detail
  printf '{"checks":['
  while IFS= read -r line; do
    [ -n "${line}" ] || continue
    id="$(printf '%s' "${line}" | cut -f1)"
    state="$(printf '%s' "${line}" | cut -f2)"
    reason="$(printf '%s' "${line}" | cut -f3)"
    detail="$(printf '%s' "${line}" | cut -f4)"
    printf '%s{"id":"%s","state":"%s","reason":"%s","detail":"%s"}' "${sep}" \
      "$(harbor_json_escape "${id}")" "${state}" "$(harbor_json_escape "${reason}")" "$(harbor_json_escape "${detail}")"
    sep=","
  done <<EOF
${HARBOR_CHECKS}
EOF
  printf ']}\n'
}
harbor_checks_text() {
  local line
  while IFS= read -r line; do
    [ -n "${line}" ] || continue
    printf '%s\n' "${line}" | tr '\t' ' '
  done <<EOF
${HARBOR_CHECKS}
EOF
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `tests/run_unit.sh tests/unit/lib/checks.bats`
Expected: `1..6`, all `ok`, exit 0.

- [ ] **Step 5: Hand off for review (no commit)**

Stop here and report as described under "Working conventions": the test commands run in this task with their results, `git status --short`, and `git diff --stat`. Do not run `git commit`. After the Fable pre-commit review and the orchestrator's own review, the orchestrator stages and commits:

- Files: `lib/checks.sh`, `tests/unit/lib/checks.bats`
- Message: `feat(checks): check-result accumulator with the section 5.6 exit-code rule`

---

### Task 6: `lib/versions.sh` and the schema-only `versions.lock`

**Files:**

- Create: `lib/versions.sh`
- Create: `versions.lock`
- Test: `tests/unit/lib/versions.bats`

**Interfaces:**

- Consumes: `harbor_die` (Task 3); `HARBOR_ROOT` exported by `bin/harbor` (Task 14) or the test helper.
- Produces:
  - `HARBOR_VERSION_KEYS`: the thirteen keys of spec section 2 in order, space-separated.
  - `harbor_versions_lock_path`: prints `${HARBOR_ROOT}/versions.lock`.
  - `harbor_versions_load FILE`: parses `key=value` lines (blank lines and `#` comments allowed) into `HARBOR_VERSIONS`; sets `HARBOR_VERSIONS_FILE`; dies 3 with `versions.missing`, `versions.syntax`, `versions.unknown_key`, `versions.duplicate_key`, or `versions.missing_key`.
  - `harbor_version_get KEY`: prints the value (possibly empty); dies 3 `versions.unknown_key` for a key outside the schema.
  - `harbor_version_require KEY`: prints the value; dies 3 `versions.unset` when empty.

- [ ] **Step 1: Write the failing tests**

`tests/unit/lib/versions.bats`:

```bash
#!/usr/bin/env bats
load '../test_helper'

setup() {
  harbor_load_libs
  LOCK="${BATS_TEST_TMPDIR}/versions.lock"
}

write_lock() {
  # write_lock [KEY=VALUE ...]: every schema key empty, then the given overrides appended
  local k
  : >"${LOCK}"
  for k in ${HARBOR_VERSION_KEYS}; do
    case " ${*} " in
      *" ${k}="*) ;;
      *) printf '%s=\n' "${k}" >>"${LOCK}" ;;
    esac
  done
  for k in ${1+"$@"}; do
    printf '%s\n' "${k}" >>"${LOCK}"
  done
}

@test "the schema lists the thirteen keys of design section 2 in order" {
  assert_equal "${HARBOR_VERSION_KEYS}" "ubuntu_release tailscale_apt_channel tailscale_version nodejs_version nodejs_install nodejs_sha256 claude_code_version claude_code_install codex_version codex_install t3_version t3_install t3_engines_node"
}

@test "the shipped versions.lock parses with every key present and empty" {
  harbor_versions_load "$(harbor_versions_lock_path)"
  assert_equal "$(harbor_versions_lock_path)" "${HARBOR_ROOT}/versions.lock"
  for k in ${HARBOR_VERSION_KEYS}; do
    assert_equal "$(harbor_version_get "${k}")" ""
  done
}

@test "values are returned exactly and comments and blank lines are ignored" {
  write_lock "t3_version=1.2.3" "t3_engines_node=>=22.0.0"
  printf '\n# trailing comment\n' >>"${LOCK}"
  harbor_versions_load "${LOCK}"
  assert_equal "$(harbor_version_get t3_version)" "1.2.3"
  assert_equal "$(harbor_version_get t3_engines_node)" ">=22.0.0"
  assert_equal "$(harbor_version_require t3_version)" "1.2.3"
}

@test "an unset key is a precondition failure for harbor_version_require" {
  write_lock
  harbor_versions_load "${LOCK}"
  run harbor_version_require nodejs_version
  assert_equal "${status}" 3
  assert_output --partial 'versions.unset'
  assert_output --partial 'nodejs_version'
}

@test "a missing file, a non key=value line, an unknown key, a duplicate, whitespace, and a missing key each exit 3 with their id" {
  run harbor_versions_load "${BATS_TEST_TMPDIR}/absent"
  assert_equal "${status}" 3
  assert_output --partial 'versions.missing'

  write_lock
  printf 'not a pair\n' >>"${LOCK}"
  run harbor_versions_load "${LOCK}"
  assert_equal "${status}" 3
  assert_output --partial 'versions.syntax'

  write_lock "bogus_key=1"
  run harbor_versions_load "${LOCK}"
  assert_equal "${status}" 3
  assert_output --partial 'versions.unknown_key'

  write_lock
  printf 't3_version=1\n' >>"${LOCK}"
  run harbor_versions_load "${LOCK}"
  assert_equal "${status}" 3
  assert_output --partial 'versions.duplicate_key'

  write_lock "t3_version=1 2"
  run harbor_versions_load "${LOCK}"
  assert_equal "${status}" 3
  assert_output --partial 'versions.syntax'

  write_lock
  grep -v '^codex_install=' "${LOCK}" >"${LOCK}.short"
  run harbor_versions_load "${LOCK}.short"
  assert_equal "${status}" 3
  assert_output --partial 'versions.missing_key'
  assert_output --partial 'codex_install'
}

@test "harbor_version_get rejects a key outside the schema" {
  write_lock
  harbor_versions_load "${LOCK}"
  run harbor_version_get bogus_key
  assert_equal "${status}" 3
  assert_output --partial 'versions.unknown_key'
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `tests/run_unit.sh tests/unit/lib/versions.bats`
Expected: FAIL. `setup` fails with `lib/versions.sh: No such file or directory`.

- [ ] **Step 3: Write `versions.lock` and `lib/versions.sh`**

`versions.lock`:

```text
# Harbor version lock (design section 2): one exact value per key.
# Each value is first set by the PR that installs the component; until then the key is empty.
ubuntu_release=
tailscale_apt_channel=
tailscale_version=
nodejs_version=
nodejs_install=
nodejs_sha256=
claude_code_version=
claude_code_install=
codex_version=
codex_install=
t3_version=
t3_install=
t3_engines_node=
```

`lib/versions.sh`:

```bash
#!/bin/bash
# versions.lock loading (design section 2): the thirteen-key schema, strict parsing,
# and lookups. Values stay empty until the PR that installs each component.
# shellcheck disable=SC2034
HARBOR_VERSION_KEYS="ubuntu_release tailscale_apt_channel tailscale_version nodejs_version nodejs_install nodejs_sha256 claude_code_version claude_code_install codex_version codex_install t3_version t3_install t3_engines_node"
harbor_versions_lock_path() {
  printf '%s/versions.lock' "${HARBOR_ROOT}"
}
harbor_versions_load() {
  local file="${1}" line key value seen="" k
  [ -r "${file}" ] || harbor_die 3 versions.missing "cannot read ${file}"
  HARBOR_VERSIONS=""
  HARBOR_VERSIONS_FILE="${file}"
  while IFS= read -r line || [ -n "${line}" ]; do
    case "${line}" in
      '' | '#'*) continue ;;
      *=*) ;;
      *) harbor_die 3 versions.syntax "${file}: line '${line}' is not key=value" ;;
    esac
    key="${line%%=*}"
    value="${line#*=}"
    case " ${HARBOR_VERSION_KEYS} " in
      *" ${key} "*) ;;
      *) harbor_die 3 versions.unknown_key "${file}: unknown key ${key}" ;;
    esac
    case " ${seen} " in
      *" ${key} "*) harbor_die 3 versions.duplicate_key "${file}: duplicate key ${key}" ;;
    esac
    case "${value}" in
      *[[:space:]]*) harbor_die 3 versions.syntax "${file}: value of ${key} contains whitespace" ;;
    esac
    seen="${seen} ${key}"
    HARBOR_VERSIONS="${HARBOR_VERSIONS}${key}=${value}
"
  done <"${file}"
  for k in ${HARBOR_VERSION_KEYS}; do
    case " ${seen} " in
      *" ${k} "*) ;;
      *) harbor_die 3 versions.missing_key "${file}: missing key ${k}" ;;
    esac
  done
}
harbor_version_get() {
  local key="${1}" line
  case " ${HARBOR_VERSION_KEYS} " in
    *" ${key} "*) ;;
    *) harbor_die 3 versions.unknown_key "no such versions.lock key ${key}" ;;
  esac
  line="$(printf '%s' "${HARBOR_VERSIONS}" | grep "^${key}=" || true)"
  printf '%s' "${line#*=}"
}
harbor_version_require() {
  local value
  value="$(harbor_version_get "${1}")"
  [ -n "${value}" ] || harbor_die 3 versions.unset "${HARBOR_VERSIONS_FILE}: ${1} is not pinned yet"
  printf '%s' "${value}"
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `tests/run_unit.sh tests/unit/lib/versions.bats`
Expected: `1..6`, all `ok`, exit 0.

- [ ] **Step 5: Hand off for review (no commit)**

Stop here and report as described under "Working conventions": the test commands run in this task with their results, `git status --short`, and `git diff --stat`. Do not run `git commit`. After the Fable pre-commit review and the orchestrator's own review, the orchestrator stages and commits:

- Files: `lib/versions.sh`, `versions.lock`, `tests/unit/lib/versions.bats`
- Message: `feat(versions): schema-only versions.lock and strict loader`

---

### Task 7: `lib/lock.sh` state roots, holder identity, holder parsing, classification

**Files:**

- Create: `lib/lock.sh`
- Test: `tests/unit/lib/lock.bats`

**Interfaces:**

- Consumes: `harbor_die`, `harbor_msg`, `harbor_utc_now`, `harbor_step` (Tasks 3 and 4).
- Produces:
  - `harbor_os`: prints `uname -s`, cached in `HARBOR_OS`.
  - `harbor_state_root_for_principal`: sets `HARBOR_STATE_ROOT` (`/var/lib/harbor` for uid 0, else `${HOME}/.local/state/harbor`) and `HARBOR_LOCK_KIND` (`root` or `operator`).
  - `harbor_state_root_create ROOT KIND`: creates ROOT if absent with mode `0755` for `root`, `0700` for `operator`; leaves an existing root untouched.
  - `harbor_lock_boot_id`: prints the boot id (`/proc/sys/kernel/random/boot_id` on Linux; the seconds field of `sysctl -n kern.boottime` on macOS).
  - `harbor_lock_pid_alive PID`: true when `ps -p PID` lists it.
  - `harbor_lock_start_time PID`: prints the start ticks field of `/proc/PID/stat` on Linux, `ps -o lstart=` trimmed on macOS; empty when unreadable.
  - `harbor_lock_identity`: computes once and caches `HARBOR_LOCK_ID_HOSTNAME`, `HARBOR_LOCK_ID_BOOT_ID`, `HARBOR_LOCK_ID_PID` (`${HARBOR_PID:-$$}`), `HARBOR_LOCK_ID_START_TIME`, `HARBOR_LOCK_ID_CMDLINE` (`${HARBOR_CMDLINE:-${0}}` with every line feed and carriage return replaced by a space, so the record stays one line per key); dies 3 `lock.identity` when the boot id or own start time is unreadable.
  - `harbor_lock_write_holder DIR FMODE`: writes the five-line `key=value` holder record to `DIR/holder.tmp.<pid>`, `chmod FMODE`, renames to `DIR/holder`.
  - `harbor_lock_parse_holder FILE`: sets `HARBOR_HOLDER_HOSTNAME`, `HARBOR_HOLDER_BOOT_ID`, `HARBOR_HOLDER_PID`, `HARBOR_HOLDER_START_TIME`, `HARBOR_HOLDER_CMDLINE`; returns 1 (fail closed) when the file is missing, any line lacks `=`, a key is unknown, a key appears twice, any of the five keys is absent, the hostname, boot id, start time, or command line is empty, or the pid is not all digits. Every field is required, `cmdline` included: a holder that cannot say what command took the lock is not a holder Harbor wrote. A record with an embedded line break therefore never parses: the extra line is either a duplicate key, an unknown key, or a line without `=`.
  - `harbor_lock_classify LOCKDIR`: sets `HARBOR_LOCK_CLASS` to `live`, `stale`, or `unknown` per spec section 3.7 step 2.

- [ ] **Step 1: Write the failing tests**

`tests/unit/lib/lock.bats`:

```bash
#!/usr/bin/env bats
load '../test_helper'

setup() {
  harbor_load_libs
  fixture_state_root
  KEEP_PID=""
  PAUSED_PIDS=""
}

teardown() {
  # Resume and reap any process a test left paused (Task 8 contenders), then
  # remove its sentinels, so a failed assertion never leaks a paused process.
  local p s
  for p in ${PAUSED_PIDS}; do
    for s in lock-acquired resolve-confirmed; do
      touch "$(pause_sentinel "${p}" "${s}")"
    done
    wait "${p}" 2>/dev/null || true
    for s in lock-acquired resolve-confirmed; do
      rm -f "$(pause_sentinel "${p}" "${s}")"
    done
  done
  if [ -n "${KEEP_PID}" ]; then
    kill "${KEEP_PID}" 2>/dev/null || true
  fi
}

start_sleeper() {
  # start_sleeper: a live process the test owns; KEEP_PID and KEEP_START are set
  sleep 30 3>&- &
  KEEP_PID=$!
  KEEP_START="$(harbor_lock_start_time "${KEEP_PID}")"
}

gone_pid() {
  # gone_pid: prints the pid of a process that has already exited
  sleep 0.01 3>&- &
  local p=$!
  wait "${p}"
  printf '%s' "${p}"
}

@test "the operator state root lives under HOME and the root one under /var/lib" {
  HOME="${FIX_HOME}" harbor_state_root_for_principal
  if [ "$(id -u)" = "0" ]; then
    assert_equal "${HARBOR_STATE_ROOT}" /var/lib/harbor
    assert_equal "${HARBOR_LOCK_KIND}" root
  else
    assert_equal "${HARBOR_STATE_ROOT}" "${FIX_HOME}/.local/state/harbor"
    assert_equal "${HARBOR_LOCK_KIND}" operator
  fi
}

@test "harbor_state_root_create makes a 0700 operator root or a 0755 root root and leaves an existing one alone" {
  harbor_state_root_create "${BATS_TEST_TMPDIR}/op" operator
  harbor_state_root_create "${BATS_TEST_TMPDIR}/rt" root
  run ls -ld "${BATS_TEST_TMPDIR}/op" "${BATS_TEST_TMPDIR}/rt"
  assert_line --index 0 --regexp '^drwx------'
  assert_line --index 1 --regexp '^drwxr-xr-x'
  chmod 0750 "${BATS_TEST_TMPDIR}/op"
  harbor_state_root_create "${BATS_TEST_TMPDIR}/op" operator
  run ls -ld "${BATS_TEST_TMPDIR}/op"
  assert_output --regexp '^drwxr-x---'
  run harbor_state_root_create "${BATS_TEST_TMPDIR}/x" other
  assert_equal "${status}" 3
  assert_output --partial 'lock.kind'
}

@test "boot id and own start time are readable on this platform" {
  run harbor_lock_boot_id
  assert_success
  refute_output ''
  run harbor_lock_start_time "$$"
  assert_success
  refute_output ''
}

@test "harbor_lock_pid_alive distinguishes a live pid from a gone one without tripping the ERR trap" {
  start_sleeper
  harbor_lock_pid_alive "${KEEP_PID}"
  gone="$(gone_pid)"
  run --separate-stderr harbor_lock_pid_alive "${gone}"
  assert_failure
  assert_equal "${stderr}" ""
  run --separate-stderr harbor_lock_start_time "${gone}"
  assert_output ''
  assert_equal "${stderr}" ""
}

@test "identity is computed once from HARBOR_PID and HARBOR_CMDLINE" {
  HARBOR_PID="$$"
  HARBOR_CMDLINE="harbor journal resolve 0001 --reverted"
  harbor_lock_identity
  assert_equal "${HARBOR_LOCK_ID_HOSTNAME}" "$(uname -n)"
  assert_equal "${HARBOR_LOCK_ID_BOOT_ID}" "$(harbor_lock_boot_id)"
  assert_equal "${HARBOR_LOCK_ID_PID}" "$$"
  assert_equal "${HARBOR_LOCK_ID_START_TIME}" "$(harbor_lock_start_time "$$")"
  assert_equal "${HARBOR_LOCK_ID_CMDLINE}" "harbor journal resolve 0001 --reverted"
  HARBOR_CMDLINE="changed"
  harbor_lock_identity
  assert_equal "${HARBOR_LOCK_ID_CMDLINE}" "harbor journal resolve 0001 --reverted"
}

@test "holder record is written by rename with the requested mode and parses back" {
  mkdir "${BATS_TEST_TMPDIR}/d"
  HARBOR_PID="$$"
  HARBOR_CMDLINE="harbor test"
  harbor_lock_write_holder "${BATS_TEST_TMPDIR}/d" 0600
  run ls -A "${BATS_TEST_TMPDIR}/d"
  assert_output holder
  run ls -l "${BATS_TEST_TMPDIR}/d/holder"
  assert_output --regexp '^-rw-------'
  run cat "${BATS_TEST_TMPDIR}/d/holder"
  assert_line --index 0 "hostname=$(uname -n)"
  assert_line --index 1 "boot_id=$(harbor_lock_boot_id)"
  assert_line --index 2 "pid=$$"
  assert_line --index 3 "start_time=$(harbor_lock_start_time "$$")"
  assert_line --index 4 "cmdline=harbor test"
  harbor_lock_parse_holder "${BATS_TEST_TMPDIR}/d/holder"
  assert_equal "${HARBOR_HOLDER_PID}" "$$"
  assert_equal "${HARBOR_HOLDER_CMDLINE}" "harbor test"
}

@test "a command line with embedded line breaks is normalized to one line before the holder is written" {
  mkdir "${BATS_TEST_TMPDIR}/d"
  HARBOR_PID="$$"
  HARBOR_CMDLINE="$(printf 'harbor a\nb\rc')"
  harbor_lock_write_holder "${BATS_TEST_TMPDIR}/d" 0600
  assert_equal "$(wc -l <"${BATS_TEST_TMPDIR}/d/holder" | tr -d ' ')" 5
  assert_equal "$(sed -n 's/^cmdline=//p' "${BATS_TEST_TMPDIR}/d/holder")" 'harbor a b c'
  harbor_lock_parse_holder "${BATS_TEST_TMPDIR}/d/holder"
  assert_equal "${HARBOR_HOLDER_CMDLINE}" 'harbor a b c'
}

@test "holder parsing rejects a missing file, an unknown key, a duplicate key, a missing key, a line without =, an empty field, and a non-numeric pid" {
  run harbor_lock_parse_holder "${BATS_TEST_TMPDIR}/absent"
  assert_failure
  printf 'hostname=h\nboot_id=b\npid=1\nstart_time=s\ncmdline=c\nextra=x\n' >"${BATS_TEST_TMPDIR}/h1"
  run harbor_lock_parse_holder "${BATS_TEST_TMPDIR}/h1"
  assert_failure
  printf 'hostname=h\nboot_id=b\npid=1\nstart_time=s\ncmdline=c\npid=2\n' >"${BATS_TEST_TMPDIR}/h5"
  run harbor_lock_parse_holder "${BATS_TEST_TMPDIR}/h5"
  assert_failure
  printf 'hostname=h\nboot_id=b\npid=1\nstart_time=s\n' >"${BATS_TEST_TMPDIR}/h6"
  run harbor_lock_parse_holder "${BATS_TEST_TMPDIR}/h6"
  assert_failure
  printf 'hostname=h\nboot_id=b\npid=1\nstart_time=s\ncmdline=c\nsecond line of a command line\n' >"${BATS_TEST_TMPDIR}/h7"
  run harbor_lock_parse_holder "${BATS_TEST_TMPDIR}/h7"
  assert_failure
  printf 'hostname=h\nboot_id=\npid=1\nstart_time=s\ncmdline=c\n' >"${BATS_TEST_TMPDIR}/h2"
  run harbor_lock_parse_holder "${BATS_TEST_TMPDIR}/h2"
  assert_failure
  printf 'hostname=h\nboot_id=b\npid=12a\nstart_time=s\ncmdline=c\n' >"${BATS_TEST_TMPDIR}/h3"
  run harbor_lock_parse_holder "${BATS_TEST_TMPDIR}/h3"
  assert_failure
}

@test "holder parsing rejects an empty cmdline and leaves no field set" {
  printf 'hostname=h\nboot_id=b\npid=12\nstart_time=s\ncmdline=\n' >"${BATS_TEST_TMPDIR}/h4"
  run harbor_lock_parse_holder "${BATS_TEST_TMPDIR}/h4"
  assert_failure
  printf 'hostname=h\nboot_id=b\npid=12\nstart_time=s\ncmdline=harbor test\n' >"${BATS_TEST_TMPDIR}/h8"
  harbor_lock_parse_holder "${BATS_TEST_TMPDIR}/h8"
  assert_equal "${HARBOR_HOLDER_CMDLINE}" "harbor test"
  harbor_lock_parse_holder "${BATS_TEST_TMPDIR}/h4" || true
  assert_equal "${HARBOR_HOLDER_CMDLINE}" ""
}

@test "classification: live holder" {
  start_sleeper
  mkdir "${FIX_ROOT}/lock.d"
  holder_record "${KEEP_PID}" "${KEEP_START}" >"${FIX_ROOT}/lock.d/holder"
  harbor_lock_classify "${FIX_ROOT}/lock.d"
  assert_equal "${HARBOR_LOCK_CLASS}" live
}

@test "classification: stale when the pid is gone, the start time differs, or the boot id differs" {
  mkdir "${FIX_ROOT}/lock.d"
  holder_record "$(gone_pid)" "whatever" >"${FIX_ROOT}/lock.d/holder"
  harbor_lock_classify "${FIX_ROOT}/lock.d"
  assert_equal "${HARBOR_LOCK_CLASS}" stale
  start_sleeper
  holder_record "${KEEP_PID}" "not-${KEEP_START}" >"${FIX_ROOT}/lock.d/holder"
  harbor_lock_classify "${FIX_ROOT}/lock.d"
  assert_equal "${HARBOR_LOCK_CLASS}" stale
  holder_record "${KEEP_PID}" "${KEEP_START}" | sed 's/^boot_id=.*/boot_id=other-boot/' >"${FIX_ROOT}/lock.d/holder"
  harbor_lock_classify "${FIX_ROOT}/lock.d"
  assert_equal "${HARBOR_LOCK_CLASS}" stale
}

@test "classification: unknown for a different hostname, no holder, an unparseable record, or an unreadable start time" {
  mkdir "${FIX_ROOT}/lock.d"
  harbor_lock_classify "${FIX_ROOT}/lock.d"
  assert_equal "${HARBOR_LOCK_CLASS}" unknown
  printf 'garbage\n' >"${FIX_ROOT}/lock.d/holder"
  harbor_lock_classify "${FIX_ROOT}/lock.d"
  assert_equal "${HARBOR_LOCK_CLASS}" unknown
  start_sleeper
  holder_record "${KEEP_PID}" "${KEEP_START}" | sed 's/^hostname=.*/hostname=harbor-node-other/' >"${FIX_ROOT}/lock.d/holder"
  harbor_lock_classify "${FIX_ROOT}/lock.d"
  assert_equal "${HARBOR_LOCK_CLASS}" unknown
  holder_record "${KEEP_PID}" "${KEEP_START}" >"${FIX_ROOT}/lock.d/holder"
  harbor_lock_identity
  harbor_lock_start_time() { printf ''; }
  harbor_lock_classify "${FIX_ROOT}/lock.d"
  assert_equal "${HARBOR_LOCK_CLASS}" unknown
}
```

The last test redefines `harbor_lock_start_time` inside the test shell after identity is cached; that is the only way to make a live pid's start time unreadable without root, and Bats runs each test in its own subshell so the override does not leak.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `tests/run_unit.sh tests/unit/lib/lock.bats`
Expected: FAIL. `setup` fails with `lib/lock.sh: No such file or directory`.

- [ ] **Step 3: Write `lib/lock.sh`**

```bash
#!/bin/bash
# Command lock (design section 3.7): per-principal state roots, holder identity and
# records, holder classification, the reclaim.d acquisition gate, the ownership
# re-check, and release. Globals set here are read by lib/journal.sh and bin/harbor.
# shellcheck disable=SC2034
harbor_os() {
  if [ -z "${HARBOR_OS:-}" ]; then
    HARBOR_OS="$(uname -s)"
  fi
  printf '%s' "${HARBOR_OS}"
}
harbor_state_root_for_principal() {
  if [ "$(id -u)" = "0" ]; then
    HARBOR_STATE_ROOT="/var/lib/harbor"
    HARBOR_LOCK_KIND="root"
  else
    HARBOR_STATE_ROOT="${HOME}/.local/state/harbor"
    HARBOR_LOCK_KIND="operator"
  fi
}
harbor_state_root_create() {
  local root="${1}" kind="${2}" mode
  case "${kind}" in
    root) mode=0755 ;;
    operator) mode=0700 ;;
    *) harbor_die 3 lock.kind "unknown lock kind ${kind}" ;;
  esac
  if [ ! -d "${root}" ]; then
    mkdir -p "$(dirname "${root}")"
    mkdir "${root}"
    chmod "${mode}" "${root}"
  fi
}
harbor_lock_boot_id() {
  case "$(harbor_os)" in
    Linux) cat /proc/sys/kernel/random/boot_id ;;
    Darwin) sysctl -n kern.boottime | sed 's/[^0-9]*\([0-9]*\).*/\1/' ;;
    *) printf '' ;;
  esac
}
harbor_lock_pid_alive() {
  local out
  out="$(ps -p "${1}" -o pid= 2>/dev/null || true)"
  [ -n "$(printf '%s' "${out}" | tr -d ' ')" ]
}
harbor_lock_start_time() {
  case "$(harbor_os)" in
    Linux)
      if [ -r "/proc/${1}/stat" ]; then
        sed 's/^.*) //' "/proc/${1}/stat" | awk '{ print $20 }'
      fi
      ;;
    Darwin)
      LC_ALL=C ps -o lstart= -p "${1}" 2>/dev/null | sed 's/^ *//; s/ *$//' || true
      ;;
  esac
}
harbor_lock_identity() {
  [ -z "${HARBOR_LOCK_ID_PID:-}" ] || return 0
  HARBOR_LOCK_ID_HOSTNAME="$(uname -n)"
  HARBOR_LOCK_ID_BOOT_ID="$(harbor_lock_boot_id)"
  HARBOR_LOCK_ID_PID="${HARBOR_PID:-$$}"
  HARBOR_LOCK_ID_START_TIME="$(harbor_lock_start_time "${HARBOR_LOCK_ID_PID}")"
  HARBOR_LOCK_ID_CMDLINE="$(printf '%s' "${HARBOR_CMDLINE:-${0}}" | tr '\n\r' '  ')"
  [ -n "${HARBOR_LOCK_ID_BOOT_ID}" ] || harbor_die 3 lock.identity "cannot read the boot id"
  [ -n "${HARBOR_LOCK_ID_START_TIME}" ] || harbor_die 3 lock.identity "cannot read the start time of pid ${HARBOR_LOCK_ID_PID}"
}
harbor_lock_write_holder() {
  local dir="${1}" fmode="${2}" tmp
  harbor_lock_identity
  tmp="${dir}/holder.tmp.${HARBOR_LOCK_ID_PID}"
  {
    printf 'hostname=%s\n' "${HARBOR_LOCK_ID_HOSTNAME}"
    printf 'boot_id=%s\n' "${HARBOR_LOCK_ID_BOOT_ID}"
    printf 'pid=%s\n' "${HARBOR_LOCK_ID_PID}"
    printf 'start_time=%s\n' "${HARBOR_LOCK_ID_START_TIME}"
    printf 'cmdline=%s\n' "${HARBOR_LOCK_ID_CMDLINE}"
  } >"${tmp}"
  chmod "${fmode}" "${tmp}"
  mv -f "${tmp}" "${dir}/holder"
}
harbor_lock_parse_holder() {
  local file="${1}" line key value seen=""
  HARBOR_HOLDER_HOSTNAME=""
  HARBOR_HOLDER_BOOT_ID=""
  HARBOR_HOLDER_PID=""
  HARBOR_HOLDER_START_TIME=""
  HARBOR_HOLDER_CMDLINE=""
  [ -f "${file}" ] || return 1
  while IFS= read -r line || [ -n "${line}" ]; do
    case "${line}" in
      *=*) ;;
      *) return 1 ;;
    esac
    key="${line%%=*}"
    value="${line#*=}"
    case " ${seen} " in
      *" ${key} "*) return 1 ;;
    esac
    case "${key}" in
      hostname) HARBOR_HOLDER_HOSTNAME="${value}" ;;
      boot_id) HARBOR_HOLDER_BOOT_ID="${value}" ;;
      pid) HARBOR_HOLDER_PID="${value}" ;;
      start_time) HARBOR_HOLDER_START_TIME="${value}" ;;
      cmdline) HARBOR_HOLDER_CMDLINE="${value}" ;;
      *) return 1 ;;
    esac
    seen="${seen} ${key}"
  done <"${file}"
  for key in hostname boot_id pid start_time cmdline; do
    case " ${seen} " in
      *" ${key} "*) ;;
      *) return 1 ;;
    esac
  done
  [ -n "${HARBOR_HOLDER_HOSTNAME}" ] || return 1
  [ -n "${HARBOR_HOLDER_BOOT_ID}" ] || return 1
  [ -n "${HARBOR_HOLDER_START_TIME}" ] || return 1
  [ -n "${HARBOR_HOLDER_CMDLINE}" ] || return 1
  case "${HARBOR_HOLDER_PID}" in
    '' | *[!0-9]*) return 1 ;;
  esac
  return 0
}
harbor_lock_classify() {
  local start
  harbor_lock_identity
  HARBOR_LOCK_CLASS=unknown
  harbor_lock_parse_holder "${1}/holder" || return 0
  [ "${HARBOR_HOLDER_HOSTNAME}" = "${HARBOR_LOCK_ID_HOSTNAME}" ] || return 0
  if [ "${HARBOR_HOLDER_BOOT_ID}" != "${HARBOR_LOCK_ID_BOOT_ID}" ]; then
    HARBOR_LOCK_CLASS=stale
    return 0
  fi
  if ! harbor_lock_pid_alive "${HARBOR_HOLDER_PID}"; then
    HARBOR_LOCK_CLASS=stale
    return 0
  fi
  start="$(harbor_lock_start_time "${HARBOR_HOLDER_PID}")"
  [ -n "${start}" ] || return 0
  if [ "${start}" != "${HARBOR_HOLDER_START_TIME}" ]; then
    HARBOR_LOCK_CLASS=stale
    return 0
  fi
  HARBOR_LOCK_CLASS=live
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `tests/run_unit.sh tests/unit/lib/lock.bats`
Expected: `1..12`, all `ok`, exit 0.

- [ ] **Step 5: Hand off for review (no commit)**

Stop here and report as described under "Working conventions": the test commands run in this task with their results, `git status --short`, and `git diff --stat`. Do not run `git commit`. After the Fable pre-commit review and the orchestrator's own review, the orchestrator stages and commits:

- Files: `lib/lock.sh`, `tests/unit/lib/lock.bats`
- Message: `feat(lock): state roots, holder identity and record, holder classification`

---

### Task 8: `lib/lock.sh` gated acquisition, reclaim, refusal, release, modes

**Files:**

- Modify: `lib/lock.sh` (append)
- Test: `tests/unit/lib/lock.bats` (append)

**Interfaces:**

- Consumes: everything from Task 7; `harbor_step` (Task 4).
- Produces:
  - `harbor_lock_inspect_hint ROOT`: prints the manual inspection instruction of spec section 3.7.
  - `harbor_lock_gate_release ROOT`: removes `ROOT/reclaim.d/holder` and `ROOT/reclaim.d`.
  - `harbor_lock_acquire ROOT KIND`: the gate protocol. Dies 3 `lock.no_state_root` when ROOT is absent, `lock.gate_busy` when `mkdir reclaim.d` fails, `lock.busy` for a live holder (own gate released first), `lock.unreadable` for `unknown` (own gate released first); renames a stale `lock.d` to `lock.<utc>.stale`, or, while that name exists, to `lock.<utc>.<n>.stale` for `n` = 1, 2, ... up to 999, taking the first name that does not exist (the held gate serializes the check, so `mv` never lands on an existing directory); when all thousand names exist it releases its own gate and dies 3 `lock.archive` with `lock.d` untouched; emits steps `lock-gate` (after the gate holder is written), `lock-mkdir` (after `mkdir lock.d`, before its holder), `lock-acquired` (after the gate is released); sets `HARBOR_LOCK_ROOT=ROOT` and `HARBOR_LOCK_SUBSHELL=${BASH_SUBSHELL}` before releasing the gate. Modes: `root` gives `0755` directories and `0644` holders; `operator` gives `0700` and `0600`.
  - `harbor_lock_owned ROOT`: true when `ROOT/lock.d/holder` parses and its hostname, boot id, pid, and start time all equal this process's identity. No subshell guard, so journal writes still work when Bats captures a function in a subshell.
  - `harbor_lock_release ROOT`: clears `HARBOR_LOCK_ROOT`; treats an absent `lock.d` as released; returns without acting when `HARBOR_LOCK_SUBSHELL` is set and differs from `BASH_SUBSHELL`, because `$$` inside a `( ... )` subshell, a command substitution, or a Bats `run` capture is still the parent's pid and the identity test alone would pass; otherwise removes `lock.d` only when `harbor_lock_owned ROOT` is true. When the variable is unset (this shell never acquired; a test acquired inside a capture) the identity test alone decides. A process-level child (`bash -c`) has its own pid and fails the identity test.

- [ ] **Step 1: Append the failing tests**

Append to `tests/unit/lib/lock.bats`:

```bash
open_log() {
  harbor_log_open "${FIX_ROOT}/harbor.log" 0600
}

contender() {
  # contender OUTFILE: a background library-level acquisition of FIX_ROOT that
  # pauses at lock-acquired. env execs bash, so CONTENDER_PID is the acquiring
  # process and its EXIT trap releases the lock when the test resumes it.
  env HARBOR_TEST_HOOKS=1 HARBOR_PAUSE_AFTER=lock-acquired \
    bash -c '. "${HARBOR_ROOT}/lib/log.sh"; . "${HARBOR_ROOT}/lib/lock.sh"; set -euo pipefail; HARBOR_PID=$$; harbor_install_traps; harbor_lock_acquire "$1" operator; exit 0' _ "${FIX_ROOT}" >"${1}" 2>&1 3>&- &
  CONTENDER_PID=$!
  PAUSED_PIDS="${PAUSED_PIDS} ${CONTENDER_PID}"
}

@test "acquire on an absent lock: gate taken and released, lock.d holder names this process, operator modes, steps logged" {
  open_log
  HARBOR_PID="$$"
  harbor_lock_acquire "${FIX_ROOT}" operator
  assert [ -f "${FIX_ROOT}/lock.d/holder" ]
  assert [ ! -e "${FIX_ROOT}/reclaim.d" ]
  assert_equal "${HARBOR_LOCK_ROOT}" "${FIX_ROOT}"
  harbor_lock_parse_holder "${FIX_ROOT}/lock.d/holder"
  assert_equal "${HARBOR_HOLDER_PID}" "$$"
  run ls -ld "${FIX_ROOT}/lock.d"
  assert_output --regexp '^drwx------'
  run ls -l "${FIX_ROOT}/lock.d/holder"
  assert_output --regexp '^-rw-------'
  run grep -o 'step lock-[a-z]*$' "${FIX_ROOT}/harbor.log"
  assert_line --index 0 'step lock-gate'
  assert_line --index 1 'step lock-mkdir'
  assert_line --index 2 'step lock-acquired'
  harbor_lock_release "${FIX_ROOT}"
  assert [ ! -e "${FIX_ROOT}/lock.d" ]
  assert_equal "${HARBOR_LOCK_ROOT}" ""
}

@test "acquire with kind root uses 0755 directories and 0644 holders" {
  HARBOR_PID="$$"
  harbor_lock_acquire "${FIX_ROOT}" root
  run ls -ld "${FIX_ROOT}/lock.d"
  assert_output --regexp '^drwxr-xr-x'
  run ls -l "${FIX_ROOT}/lock.d/holder"
  assert_output --regexp '^-rw-r--r--'
  harbor_lock_release "${FIX_ROOT}"
}

@test "acquire without a state root exits 3 and creates nothing" {
  run harbor_lock_acquire "${BATS_TEST_TMPDIR}/nowhere" operator
  assert_equal "${status}" 3
  assert_output --partial 'lock.no_state_root'
  assert [ ! -e "${BATS_TEST_TMPDIR}/nowhere" ]
}

@test "a present reclaim.d refuses immediately without claiming or releasing it and without touching lock.d" {
  mkdir "${FIX_ROOT}/reclaim.d"
  printf 'hostname=x\n' >"${FIX_ROOT}/reclaim.d/holder"
  run harbor_lock_acquire "${FIX_ROOT}" operator
  assert_equal "${status}" 3
  assert_output --partial 'lock.gate_busy'
  assert_output --partial "ls -la ${FIX_ROOT}/reclaim.d ${FIX_ROOT}/lock.d"
  assert_equal "$(cat "${FIX_ROOT}/reclaim.d/holder")" 'hostname=x'
  assert [ ! -e "${FIX_ROOT}/lock.d" ]
}

@test "a live holder exits 3 with lock.busy naming it, releases only the own gate, and leaves the holder unchanged" {
  start_sleeper
  mkdir "${FIX_ROOT}/lock.d"
  holder_record "${KEEP_PID}" "${KEEP_START}" "harbor other" >"${FIX_ROOT}/lock.d/holder"
  before="$(cat "${FIX_ROOT}/lock.d/holder")"
  run harbor_lock_acquire "${FIX_ROOT}" operator
  assert_equal "${status}" 3
  assert_output --partial 'lock.busy'
  assert_output --partial "pid ${KEEP_PID}"
  assert_output --partial 'harbor other'
  assert [ ! -e "${FIX_ROOT}/reclaim.d" ]
  assert_equal "$(cat "${FIX_ROOT}/lock.d/holder")" "${before}"
  refute_output --partial 'failed at step'
}

@test "a stale holder (pid gone) is archived as lock.<timestamp>.stale under the gate and the command proceeds" {
  mkdir "${FIX_ROOT}/lock.d"
  holder_record "$(gone_pid)" "whatever" >"${FIX_ROOT}/lock.d/holder"
  HARBOR_PID="$$"
  run harbor_lock_acquire "${FIX_ROOT}" operator
  assert_success
  assert_output --partial 'reclaimed stale lock'
  harbor_lock_parse_holder "${FIX_ROOT}/lock.d/holder"
  assert_equal "${HARBOR_HOLDER_PID}" "$$"
  assert [ ! -e "${FIX_ROOT}/reclaim.d" ]
  run find "${FIX_ROOT}" -maxdepth 1 -name 'lock.*.stale'
  assert_equal "${#lines[@]}" 1
  harbor_lock_parse_holder "${lines[0]}/holder"
  assert_equal "${HARBOR_HOLDER_START_TIME}" whatever
  harbor_lock_release "${FIX_ROOT}"
  assert [ ! -e "${FIX_ROOT}/lock.d" ]
}

@test "a stale holder by start-time mismatch or by boot id is reclaimed the same way" {
  start_sleeper
  mkdir "${FIX_ROOT}/lock.d"
  holder_record "${KEEP_PID}" "not-${KEEP_START}" >"${FIX_ROOT}/lock.d/holder"
  HARBOR_PID="$$"
  harbor_lock_acquire "${FIX_ROOT}" operator
  harbor_lock_parse_holder "${FIX_ROOT}/lock.d/holder"
  assert_equal "${HARBOR_HOLDER_PID}" "$$"
  harbor_lock_release "${FIX_ROOT}"
  mkdir "${FIX_ROOT}/lock.d"
  holder_record "${KEEP_PID}" "${KEEP_START}" | sed 's/^boot_id=.*/boot_id=other-boot/' >"${FIX_ROOT}/lock.d/holder"
  harbor_lock_acquire "${FIX_ROOT}" operator
  harbor_lock_parse_holder "${FIX_ROOT}/lock.d/holder"
  assert_equal "${HARBOR_HOLDER_PID}" "$$"
  harbor_lock_release "${FIX_ROOT}"
  run find "${FIX_ROOT}" -maxdepth 1 -name 'lock.*.stale'
  assert_equal "${#lines[@]}" 2
}

@test "a different hostname, an unreadable start time, or a lock.d without holder is refused with the inspection command and left in place" {
  start_sleeper
  mkdir "${FIX_ROOT}/lock.d"
  holder_record "${KEEP_PID}" "${KEEP_START}" | sed 's/^hostname=.*/hostname=harbor-node-other/' >"${FIX_ROOT}/lock.d/holder"
  before="$(cat "${FIX_ROOT}/lock.d/holder")"
  run harbor_lock_acquire "${FIX_ROOT}" operator
  assert_equal "${status}" 3
  assert_output --partial 'lock.unreadable'
  assert_output --partial "cat ${FIX_ROOT}/reclaim.d/holder ${FIX_ROOT}/lock.d/holder"
  assert_equal "$(cat "${FIX_ROOT}/lock.d/holder")" "${before}"
  assert [ ! -e "${FIX_ROOT}/reclaim.d" ]

  holder_record "${KEEP_PID}" "${KEEP_START}" >"${FIX_ROOT}/lock.d/holder"
  harbor_lock_identity
  harbor_lock_start_time() { printf ''; }
  run harbor_lock_acquire "${FIX_ROOT}" operator
  assert_equal "${status}" 3
  assert_output --partial 'lock.unreadable'
  assert [ -f "${FIX_ROOT}/lock.d/holder" ]
  assert [ ! -e "${FIX_ROOT}/reclaim.d" ]

  rm "${FIX_ROOT}/lock.d/holder"
  run harbor_lock_acquire "${FIX_ROOT}" operator
  assert_equal "${status}" 3
  assert_output --partial 'lock.unreadable'
  assert [ -d "${FIX_ROOT}/lock.d" ]
  assert [ ! -e "${FIX_ROOT}/reclaim.d" ]
  run find "${FIX_ROOT}" -maxdepth 1 -name 'lock.*.stale'
  assert_output ''
}

@test "release treats an absent lock.d as already released" {
  HARBOR_LOCK_ROOT="${FIX_ROOT}"
  harbor_lock_release "${FIX_ROOT}"
  assert_equal "${HARBOR_LOCK_ROOT}" ""
  assert [ ! -e "${FIX_ROOT}/lock.d" ]
}

@test "release never removes a lock.d whose holder names another process" {
  start_sleeper
  HARBOR_PID="$$"
  harbor_lock_acquire "${FIX_ROOT}" operator
  holder_record "${KEEP_PID}" "${KEEP_START}" >"${FIX_ROOT}/lock.d/holder"
  harbor_lock_release "${FIX_ROOT}"
  assert [ -f "${FIX_ROOT}/lock.d/holder" ]
  assert_equal "${HARBOR_LOCK_ROOT}" ""
  rm -r "${FIX_ROOT}/lock.d"
}

@test "a child process, an actual ( ) subshell, a command substitution, and a Bats run capture never release the parent's lock; the parent then does" {
  HARBOR_PID="$$"
  harbor_lock_acquire "${FIX_ROOT}" operator
  bash -c '. "${HARBOR_ROOT}/lib/log.sh"; . "${HARBOR_ROOT}/lib/lock.sh"; HARBOR_PID=$$; harbor_lock_release "$1"' _ "${FIX_ROOT}"
  assert [ -f "${FIX_ROOT}/lock.d/holder" ]
  # $$ is unchanged inside ( ), so only the BASH_SUBSHELL guard stops these three
  ( harbor_lock_release "${FIX_ROOT}" )
  assert [ -f "${FIX_ROOT}/lock.d/holder" ]
  assert_equal "$(harbor_lock_release "${FIX_ROOT}"; ls -A "${FIX_ROOT}/lock.d")" holder
  run harbor_lock_release "${FIX_ROOT}"
  assert_success
  assert [ -f "${FIX_ROOT}/lock.d/holder" ]
  assert_equal "${HARBOR_LOCK_ROOT}" "${FIX_ROOT}"
  harbor_lock_release "${FIX_ROOT}"
  assert [ ! -e "${FIX_ROOT}/lock.d" ]
  assert_equal "${HARBOR_LOCK_ROOT}" ""
}

@test "the EXIT trap releases an owned lock at the top level only and leaves a foreign one in place" {
  run bash -c '. "${HARBOR_ROOT}/lib/log.sh"; . "${HARBOR_ROOT}/lib/lock.sh"; set -euo pipefail; HARBOR_PID=$$; harbor_install_traps; harbor_lock_acquire "$1" operator; ( true ); [ -f "$1/lock.d/holder" ] || exit 9; ( harbor_lock_release "$1" ); [ -f "$1/lock.d/holder" ] || exit 8; x="$(harbor_lock_release "$1")"; [ -f "$1/lock.d/holder" ] || exit 7; exit 0' _ "${FIX_ROOT}"
  assert_success
  assert [ ! -e "${FIX_ROOT}/lock.d" ]
  run bash -c '. "${HARBOR_ROOT}/lib/log.sh"; . "${HARBOR_ROOT}/lib/lock.sh"; set -euo pipefail; HARBOR_PID=$$; harbor_install_traps; harbor_lock_acquire "$1" operator; printf "hostname=%s\nboot_id=%s\npid=1\nstart_time=other\ncmdline=forged\n" "$(uname -n)" "$(harbor_lock_boot_id)" >"$1/lock.d/holder"; exit 0' _ "${FIX_ROOT}"
  assert_success
  assert [ -f "${FIX_ROOT}/lock.d/holder" ]
  assert_equal "$(sed -n 's/^cmdline=//p' "${FIX_ROOT}/lock.d/holder")" forged
}

@test "repeated stale reclaims in the same second take lock.<utc>.<n>.stale names that do not exist yet and never nest" {
  harbor_utc_now() { printf '20260902T120000Z'; }
  mkdir "${FIX_ROOT}/lock.20260902T120000Z.stale" "${FIX_ROOT}/lock.20260902T120000Z.1.stale"
  HARBOR_PID="$$"
  for n in 2 3 4; do
    mkdir "${FIX_ROOT}/lock.d"
    holder_record "$(gone_pid)" "whatever" "harbor reclaim ${n}" >"${FIX_ROOT}/lock.d/holder"
    harbor_lock_acquire "${FIX_ROOT}" operator
    assert_equal "$(holder_pid "${FIX_ROOT}")" "$$"
    assert_equal "$(sed -n 's/^cmdline=//p' "${FIX_ROOT}/lock.20260902T120000Z.${n}.stale/holder")" "harbor reclaim ${n}"
    harbor_lock_release "${FIX_ROOT}"
  done
  run find "${FIX_ROOT}" -mindepth 2 -name '*.stale'
  assert_output ''
  run find "${FIX_ROOT}" -maxdepth 1 -name 'lock.*.stale'
  assert_equal "${#lines[@]}" 5
  assert [ ! -e "${FIX_ROOT}/reclaim.d" ]
}

@test "when a thousand archive names already exist the reclaim dies 3 lock.archive, releases its gate, and leaves lock.d in place" {
  harbor_utc_now() { printf '20260902T120000Z'; }
  mkdir "${FIX_ROOT}/lock.20260902T120000Z.stale"
  n=1
  while [ "${n}" -le 999 ]; do
    mkdir "${FIX_ROOT}/lock.20260902T120000Z.${n}.stale"
    n=$((n + 1))
  done
  mkdir "${FIX_ROOT}/lock.d"
  holder_record "$(gone_pid)" "whatever" "harbor crashed" >"${FIX_ROOT}/lock.d/holder"
  HARBOR_PID="$$"
  run harbor_lock_acquire "${FIX_ROOT}" operator
  assert_equal "${status}" 3
  assert_output --partial 'lock.archive'
  assert_equal "$(sed -n 's/^cmdline=//p' "${FIX_ROOT}/lock.d/holder")" 'harbor crashed'
  assert [ ! -e "${FIX_ROOT}/reclaim.d" ]
  assert [ ! -e "${FIX_ROOT}/lock.20260902T120000Z.1000.stale" ]
}

@test "double contender on an absent lock (library level): exactly one holder, one exit 3, no reclaim.d or archive left" {
  contender "${BATS_TEST_TMPDIR}/a.out"
  pa="${CONTENDER_PID}"
  contender "${BATS_TEST_TMPDIR}/b.out"
  pb="${CONTENDER_PID}"
  wait_for_one_exit "${pa}" "${pb}"
  assert [ -f "${FIX_ROOT}/lock.d/holder" ]
  assert [ ! -e "${FIX_ROOT}/reclaim.d" ]
  case "$(holder_pid "${FIX_ROOT}")" in
    "${pa}" | "${pb}") ;;
    *) fail "the holder names neither contender" ;;
  esac
  resume_holder "${FIX_ROOT}" lock-acquired
  sa=0
  wait "${pa}" || sa=$?
  sb=0
  wait "${pb}" || sb=$?
  assert_equal "$(( (sa == 0) + (sb == 0) ))" 1
  assert_equal "$(( (sa == 3) + (sb == 3) ))" 1
  assert [ ! -e "${FIX_ROOT}/lock.d" ]
  assert [ ! -e "${FIX_ROOT}/reclaim.d" ]
  run find "${FIX_ROOT}" -maxdepth 1 -name 'lock.*.stale'
  assert_output ''
  run cat "${BATS_TEST_TMPDIR}/a.out" "${BATS_TEST_TMPDIR}/b.out"
  assert_output --regexp 'lock\.(busy|gate_busy)'
  refute_output --partial 'failed at step'
}

@test "double contender on a stale lock (library level): exactly one holder, one exit 3, one archive, no reclaim.d left" {
  mkdir "${FIX_ROOT}/lock.d"
  holder_record "$(gone_pid)" "whatever" "harbor crashed" >"${FIX_ROOT}/lock.d/holder"
  contender "${BATS_TEST_TMPDIR}/a.out"
  pa="${CONTENDER_PID}"
  contender "${BATS_TEST_TMPDIR}/b.out"
  pb="${CONTENDER_PID}"
  wait_for_one_exit "${pa}" "${pb}"
  assert [ -f "${FIX_ROOT}/lock.d/holder" ]
  assert [ ! -e "${FIX_ROOT}/reclaim.d" ]
  resume_holder "${FIX_ROOT}" lock-acquired
  sa=0
  wait "${pa}" || sa=$?
  sb=0
  wait "${pb}" || sb=$?
  assert_equal "$(( (sa == 0) + (sb == 0) ))" 1
  assert_equal "$(( (sa == 3) + (sb == 3) ))" 1
  assert [ ! -e "${FIX_ROOT}/lock.d" ]
  assert [ ! -e "${FIX_ROOT}/reclaim.d" ]
  run find "${FIX_ROOT}" -maxdepth 1 -name 'lock.*.stale'
  assert_equal "${#lines[@]}" 1
  assert_equal "$(sed -n 's/^cmdline=//p' "${lines[0]}/holder")" 'harbor crashed'
  run cat "${BATS_TEST_TMPDIR}/a.out" "${BATS_TEST_TMPDIR}/b.out"
  assert_output --partial 'reclaimed stale lock'
  refute_output --partial 'failed at step'
}

@test "interrupted acquisition after lock-gate (library level): reclaim.d stays with its holder, the next acquisition refuses and touches nothing, removing reclaim.d lets it acquire" {
  run env HARBOR_TEST_HOOKS=1 HARBOR_FAIL_AFTER=lock-gate \
    bash -c '. "${HARBOR_ROOT}/lib/log.sh"; . "${HARBOR_ROOT}/lib/lock.sh"; HARBOR_PID=$$; harbor_lock_acquire "$1" operator' _ "${FIX_ROOT}"
  assert_equal "${status}" 137
  assert [ -f "${FIX_ROOT}/reclaim.d/holder" ]
  assert [ ! -e "${FIX_ROOT}/lock.d" ]
  gate_before="$(cat "${FIX_ROOT}/reclaim.d/holder")"
  HARBOR_PID="$$"
  run harbor_lock_acquire "${FIX_ROOT}" operator
  assert_equal "${status}" 3
  assert_output --partial 'lock.gate_busy'
  assert_output --partial "ls -la ${FIX_ROOT}/reclaim.d ${FIX_ROOT}/lock.d"
  assert_equal "$(cat "${FIX_ROOT}/reclaim.d/holder")" "${gate_before}"
  assert [ ! -e "${FIX_ROOT}/lock.d" ]
  rm -r "${FIX_ROOT}/reclaim.d"
  harbor_lock_acquire "${FIX_ROOT}" operator
  assert_equal "$(holder_pid "${FIX_ROOT}")" "$$"
  assert [ ! -e "${FIX_ROOT}/reclaim.d" ]
  harbor_lock_release "${FIX_ROOT}"
  assert [ ! -e "${FIX_ROOT}/lock.d" ]
}

@test "interrupted acquisition after lock-mkdir (library level): reclaim.d and a holderless lock.d stay, the next acquisition refuses, removing both lets it acquire" {
  run env HARBOR_TEST_HOOKS=1 HARBOR_FAIL_AFTER=lock-mkdir \
    bash -c '. "${HARBOR_ROOT}/lib/log.sh"; . "${HARBOR_ROOT}/lib/lock.sh"; HARBOR_PID=$$; harbor_lock_acquire "$1" operator' _ "${FIX_ROOT}"
  assert_equal "${status}" 137
  assert [ -f "${FIX_ROOT}/reclaim.d/holder" ]
  assert [ -d "${FIX_ROOT}/lock.d" ]
  assert [ ! -e "${FIX_ROOT}/lock.d/holder" ]
  HARBOR_PID="$$"
  run harbor_lock_acquire "${FIX_ROOT}" operator
  assert_equal "${status}" 3
  assert_output --partial 'lock.gate_busy'
  assert [ -f "${FIX_ROOT}/reclaim.d/holder" ]
  assert [ ! -e "${FIX_ROOT}/lock.d/holder" ]
  rm -r "${FIX_ROOT}/reclaim.d"
  run harbor_lock_acquire "${FIX_ROOT}" operator
  assert_equal "${status}" 3
  assert_output --partial 'lock.unreadable'
  assert [ -d "${FIX_ROOT}/lock.d" ]
  assert [ ! -e "${FIX_ROOT}/reclaim.d" ]
  rmdir "${FIX_ROOT}/lock.d"
  harbor_lock_acquire "${FIX_ROOT}" operator
  assert_equal "$(holder_pid "${FIX_ROOT}")" "$$"
  harbor_lock_release "${FIX_ROOT}"
  assert [ ! -e "${FIX_ROOT}/lock.d" ]
  run find "${FIX_ROOT}" -maxdepth 1 -name 'lock.*.stale'
  assert_output ''
}
```

The last four tests are the library-level red tests for the double-contender and interrupted-acquisition guarantees; Task 15 repeats them through the public command as acceptance coverage and traces back here.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `tests/run_unit.sh tests/unit/lib/lock.bats`
Expected: FAIL. The twelve Task 7 tests pass; the eighteen new ones fail with `harbor_lock_acquire: command not found` or `harbor_lock_release: command not found` (the contender and interrupted tests fail on their first assertion about `lock.d` or on the exit status, because the background or captured bash exits 127 instead).

- [ ] **Step 3: Append to `lib/lock.sh`**

```bash
harbor_lock_inspect_hint() {
  printf 'inspect with: ls -la %s/reclaim.d %s/lock.d; cat %s/reclaim.d/holder %s/lock.d/holder. If neither pid is a running harbor process, remove %s/reclaim.d and any %s/lock.d lacking a holder file, then rerun.' \
    "${1}" "${1}" "${1}" "${1}" "${1}" "${1}"
}
harbor_lock_gate_release() {
  rm -f "${1}/reclaim.d/holder"
  rmdir "${1}/reclaim.d"
}
harbor_lock_acquire() {
  local root="${1}" kind="${2}" dmode fmode gate lock stale stamp n
  case "${kind}" in
    root)
      dmode=0755
      fmode=0644
      ;;
    operator)
      dmode=0700
      fmode=0600
      ;;
    *) harbor_die 3 lock.kind "unknown lock kind ${kind}" ;;
  esac
  gate="${root}/reclaim.d"
  lock="${root}/lock.d"
  [ -d "${root}" ] || harbor_die 3 lock.no_state_root "state root ${root} does not exist"
  harbor_lock_identity
  if ! mkdir "${gate}" 2>/dev/null; then
    harbor_die 3 lock.gate_busy "${gate} exists: another command is inside the lock gate or a crash left it; $(harbor_lock_inspect_hint "${root}")"
  fi
  chmod "${dmode}" "${gate}"
  harbor_lock_write_holder "${gate}" "${fmode}"
  harbor_step lock-gate
  if [ -d "${lock}" ]; then
    harbor_lock_classify "${lock}"
    case "${HARBOR_LOCK_CLASS}" in
      live)
        harbor_lock_gate_release "${root}"
        harbor_die 3 lock.busy "${lock} is held by pid ${HARBOR_HOLDER_PID} (started ${HARBOR_HOLDER_START_TIME}) on ${HARBOR_HOLDER_HOSTNAME}: ${HARBOR_HOLDER_CMDLINE}"
        ;;
      stale)
        stamp="$(harbor_utc_now)"
        stale="${root}/lock.${stamp}.stale"
        n=0
        while [ -e "${stale}" ]; do
          n=$((n + 1))
          if [ "${n}" -gt 999 ]; then
            harbor_lock_gate_release "${root}"
            harbor_die 3 lock.archive "a thousand archives named lock.${stamp}*.stale already exist in ${root}; remove old ones and rerun"
          fi
          stale="${root}/lock.${stamp}.${n}.stale"
        done
        mv "${lock}" "${stale}"
        harbor_msg "reclaimed stale lock held by pid ${HARBOR_HOLDER_PID}; archived as ${stale}"
        ;;
      *)
        harbor_lock_gate_release "${root}"
        harbor_die 3 lock.unreadable "${lock} cannot be classified (no holder file, unparseable record, different hostname, or unreadable start time); $(harbor_lock_inspect_hint "${root}")"
        ;;
    esac
  fi
  mkdir "${lock}"
  chmod "${dmode}" "${lock}"
  harbor_step lock-mkdir
  harbor_lock_write_holder "${lock}" "${fmode}"
  HARBOR_LOCK_ROOT="${root}"
  HARBOR_LOCK_SUBSHELL="${BASH_SUBSHELL}"
  harbor_lock_gate_release "${root}"
  harbor_step lock-acquired
}
harbor_lock_owned() {
  harbor_lock_identity
  harbor_lock_parse_holder "${1}/lock.d/holder" || return 1
  [ "${HARBOR_HOLDER_HOSTNAME}" = "${HARBOR_LOCK_ID_HOSTNAME}" ] || return 1
  [ "${HARBOR_HOLDER_BOOT_ID}" = "${HARBOR_LOCK_ID_BOOT_ID}" ] || return 1
  [ "${HARBOR_HOLDER_PID}" = "${HARBOR_LOCK_ID_PID}" ] || return 1
  [ "${HARBOR_HOLDER_START_TIME}" = "${HARBOR_LOCK_ID_START_TIME}" ] || return 1
}
harbor_lock_release() {
  local lock="${1}/lock.d"
  HARBOR_LOCK_ROOT=""
  [ -d "${lock}" ] || return 0
  # A ( ) subshell, a $( ) substitution, and a Bats run capture keep the
  # parent's $$ but raise BASH_SUBSHELL; once this shell has acquired, only
  # the same shell level may release. Unset means no acquisition happened at
  # this level or above it (a test that acquired inside a capture), and the
  # identity test alone decides.
  if [ -n "${HARBOR_LOCK_SUBSHELL:-}" ] && [ "${BASH_SUBSHELL}" != "${HARBOR_LOCK_SUBSHELL}" ]; then
    return 0
  fi
  if harbor_lock_owned "${1}"; then
    rm -f "${lock}/holder"
    rmdir "${lock}"
  fi
}
```

The stale archive name uses a one-second timestamp. While the gate is held no other process archives into this root, so the loop's existence check is race-free and every reclaim in the same second takes the next unused `lock.<utc>.<n>.stale` name; `mv` therefore never lands on an existing directory (which would nest the old lock inside it). The bound of a thousand names per second is a fail-closed limit, not an expected condition.

The `HARBOR_LOCK_SUBSHELL` guard is what makes the EXIT-trap release safe under bash 3.2: `$$` inside `( ... )` is still the parent's pid, so the identity test alone would let a subshell delete the parent's lock. Production always acquires at the top level, so every subshell after that sees a mismatch. Treating an unset variable as "no guard" keeps two legitimate test patterns working without weakening production: a test that acquires under `run` (the variable is set only in the capture subshell) and later releases from the test body, and the in-process root-branch tests of Task 14.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `tests/run_unit.sh tests/unit/lib/lock.bats`
Expected: `1..30`, all `ok`, exit 0. The two double-contender tests take about a second each; the exhaustion test creates a thousand directories and takes one to three seconds.

- [ ] **Step 5: Hand off for review (no commit)**

Stop here and report as described under "Working conventions": the test commands run in this task with their results, `git status --short`, and `git diff --stat`. Do not run `git commit`. After the Fable pre-commit review and the orchestrator's own review, the orchestrator stages and commits:

- Files: `lib/lock.sh`, `tests/unit/lib/lock.bats`
- Message: `feat(lock): reclaim.d-gated acquisition, stale reclaim, fail-closed refusal, release`

---

### Task 9: `lib/lock.sh` ownership re-check and EXIT-trap release semantics

**Files:**

- Modify: `lib/lock.sh` (append)
- Test: `tests/unit/lib/lock.bats` (append)

**Interfaces:**

- Consumes: `harbor_lock_owned`, `harbor_lock_release`, `harbor_lock_acquire` (Task 8); `harbor_install_traps` (Task 4).
- Produces:
  - `harbor_lock_assert_owner ROOT`: returns 0 when `harbor_lock_owned ROOT`; otherwise `harbor_die 2 lock.lost`. Called by `lib/journal.sh` immediately before every journal write (Task 11).

- [ ] **Step 1: Append the failing tests**

Append to `tests/unit/lib/lock.bats`:

```bash
@test "ownership re-check: owned after acquire, lost after the holder is forged, exit 2 from assert_owner" {
  start_sleeper
  HARBOR_PID="$$"
  harbor_lock_acquire "${FIX_ROOT}" operator
  harbor_lock_owned "${FIX_ROOT}"
  harbor_lock_assert_owner "${FIX_ROOT}"
  holder_record "${KEEP_PID}" "${KEEP_START}" "harbor other" >"${FIX_ROOT}/lock.d/holder"
  run harbor_lock_owned "${FIX_ROOT}"
  assert_failure
  run harbor_lock_assert_owner "${FIX_ROOT}"
  assert_equal "${status}" 2
  assert_output --partial 'lock.lost'
  assert_output --partial 'nothing was written'
}
```

The release and EXIT-trap guarantees (foreign holder, child process, actual subshell, top-level trap) were driven red in Task 8; this task adds only the assertion used before journal writes.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `tests/run_unit.sh tests/unit/lib/lock.bats`
Expected: FAIL. The new test fails with `harbor_lock_assert_owner: command not found`; the thirty earlier tests pass.

- [ ] **Step 3: Append to `lib/lock.sh`**

```bash
harbor_lock_assert_owner() {
  harbor_lock_owned "${1}" || harbor_die 2 lock.lost "${1}/lock.d/holder no longer names this process; the lock was reclaimed out from under it and nothing was written"
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `tests/run_unit.sh tests/unit/lib/lock.bats`
Expected: `1..31`, all `ok`, exit 0.

- [ ] **Step 5: Hand off for review (no commit)**

Stop here and report as described under "Working conventions": the test commands run in this task with their results, `git status --short`, and `git diff --stat`. Do not run `git commit`. After the Fable pre-commit review and the orchestrator's own review, the orchestrator stages and commits:

- Files: `lib/lock.sh`, `tests/unit/lib/lock.bats`
- Message: `feat(lock): ownership re-check before journal writes`

---

### Task 10: `lib/journal.sh` observation, sync, rendering, and field parsing

**Files:**

- Create: `lib/journal.sh`
- Test: `tests/unit/lib/journal.bats`

**Interfaces:**

- Consumes: `harbor_os` (Task 7), `harbor_json_escape`, `harbor_die` (Task 3).
- Produces:
  - `harbor_sha256 PATH`: hex digest via `sha256sum` or `shasum -a 256`.
  - `harbor_stat_mode PATH`: four-digit octal mode (`0644`).
  - `harbor_stat_owner PATH`: owner user name.
  - `harbor_journal_sync_path PATH`: `sync -- PATH` when `HARBOR_SYNC_MODE=file`, whole-filesystem `sync` when `fs`; the mode defaults to `file` on Linux and `fs` on Darwin and is computed once; dies 2 `journal.sync` when the per-file sync fails and 3 `journal.platform` on any other OS.
  - `harbor_journal_dir ROOT`: prints `ROOT/journal`.
  - `harbor_journal_init ROOT`: creates `ROOT/journal` with mode `0700` when absent.
  - `harbor_journal_render OP TARGET OWNERSHIP PHASE PRE POST [RESOLVED_BY RESOLVED_AT]`: prints the canonical entry text (one field per line, two-space indent, `pre_state` and `post_state` verbatim JSON values, `resolved_by` and `resolved_at` lines only when RESOLVED_BY is given).
  - `harbor_journal_field ENTRY KEY`: prints the raw JSON value on the `"KEY":` line without its trailing comma; returns 1 when absent.
  - `harbor_journal_raw ENTRY KEY`: `harbor_journal_field` that prints empty instead of failing.
  - `harbor_json_unquote VALUE`: strips one pair of surrounding quotes and unescapes `\"` and `\\`.
  - `harbor_journal_string ENTRY KEY`: `harbor_json_unquote` of `harbor_journal_raw`.
  - `harbor_observe_file PATH`: prints `"absent"`, `"unobservable:not-a-regular-file"`, or `{"sha256":"…","mode":"0644","owner":"…"}`.
  - `harbor_journal_observe OP TARGET`: `harbor_observe_file` for op `file`; `"unobservable:<op>"` for any other op (later PRs add their observers).
  - `harbor_journal_print_entry ENTRY OBSERVED`: prints the undecidable block (`op`, `target`, `pre_state`, `post_state`, `observed`) to stderr.

- [ ] **Step 1: Write the failing tests**

`tests/unit/lib/journal.bats`:

```bash
#!/usr/bin/env bats
load '../test_helper'

setup() {
  harbor_load_libs
  fixture_state_root
  HARBOR_PID="$$"
  KEEP_PID=""
}

teardown() {
  if [ -n "${KEEP_PID}" ]; then
    kill "${KEEP_PID}" 2>/dev/null || true
  fi
}

@test "sha256, mode, and owner observe a regular file" {
  printf 'hello\n' >"${BATS_TEST_TMPDIR}/f"
  chmod 0640 "${BATS_TEST_TMPDIR}/f"
  assert_equal "$(harbor_sha256 "${BATS_TEST_TMPDIR}/f")" 5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03
  assert_equal "$(harbor_stat_mode "${BATS_TEST_TMPDIR}/f")" 0640
  assert_equal "$(harbor_stat_owner "${BATS_TEST_TMPDIR}/f")" "$(id -un)"
}

@test "harbor_observe_file renders absent, non-regular, and regular targets" {
  assert_equal "$(harbor_observe_file "${BATS_TEST_TMPDIR}/nope")" '"absent"'
  mkdir "${BATS_TEST_TMPDIR}/dir"
  assert_equal "$(harbor_observe_file "${BATS_TEST_TMPDIR}/dir")" '"unobservable:not-a-regular-file"'
  ln -s "${BATS_TEST_TMPDIR}/nope" "${BATS_TEST_TMPDIR}/link"
  assert_equal "$(harbor_observe_file "${BATS_TEST_TMPDIR}/link")" '"unobservable:not-a-regular-file"'
  printf 'hello\n' >"${BATS_TEST_TMPDIR}/f"
  chmod 0644 "${BATS_TEST_TMPDIR}/f"
  assert_equal "$(harbor_observe_file "${BATS_TEST_TMPDIR}/f")" "{\"sha256\":\"5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03\",\"mode\":\"0644\",\"owner\":\"$(id -un)\"}"
  assert_equal "$(harbor_journal_observe file "${BATS_TEST_TMPDIR}/nope")" '"absent"'
  assert_equal "$(harbor_journal_observe package curl)" '"unobservable:package"'
}

@test "the sync helper uses per-file sync on Linux and whole-filesystem sync on Darwin" {
  printf 'x\n' >"${BATS_TEST_TMPDIR}/f"
  harbor_journal_sync_path "${BATS_TEST_TMPDIR}/f"
  case "$(uname -s)" in
    Linux) assert_equal "${HARBOR_SYNC_MODE}" file ;;
    Darwin) assert_equal "${HARBOR_SYNC_MODE}" fs ;;
  esac
  HARBOR_SYNC_MODE=file
  run harbor_journal_sync_path "${BATS_TEST_TMPDIR}/missing"
  if [ "$(uname -s)" = "Linux" ]; then
    assert_equal "${status}" 2
    assert_output --partial 'journal.sync'
  fi
  HARBOR_OS=Plan9
  HARBOR_SYNC_MODE=""
  run harbor_journal_sync_path "${BATS_TEST_TMPDIR}/f"
  assert_equal "${status}" 3
  assert_output --partial 'journal.platform'
}

@test "harbor_journal_init creates a 0700 journal directory once" {
  rm -r "${FIX_ROOT}/journal"
  harbor_journal_init "${FIX_ROOT}"
  run ls -ld "${FIX_ROOT}/journal"
  assert_output --regexp '^drwx------'
  assert_equal "$(harbor_journal_dir "${FIX_ROOT}")" "${FIX_ROOT}/journal"
  harbor_journal_init "${FIX_ROOT}"
}

@test "render produces the canonical entry text with and without resolution fields" {
  run harbor_journal_render file /etc/x created prepared '"absent"' '{"sha256":"ab","mode":"0644","owner":"root"}'
  assert_line --index 0 '{'
  assert_line --index 1 '  "op": "file",'
  assert_line --index 2 '  "target": "/etc/x",'
  assert_line --index 3 '  "ownership": "created",'
  assert_line --index 4 '  "phase": "prepared",'
  assert_line --index 5 '  "pre_state": "absent",'
  assert_line --index 6 '  "post_state": {"sha256":"ab","mode":"0644","owner":"root"}'
  assert_line --index 7 '}'
  assert_equal "${#lines[@]}" 8
  run harbor_journal_render file '/tmp/we"ird' created reverted '"absent"' '"absent"' operator 20260902T120000Z
  assert_line --index 2 '  "target": "/tmp/we\"ird",'
  assert_line --index 6 '  "post_state": "absent",'
  assert_line --index 7 '  "resolved_by": "operator",'
  assert_line --index 8 '  "resolved_at": "20260902T120000Z"'
  assert_line --index 9 '}'
}

@test "field, raw, string, and unquote read a canonical entry back" {
  fixture_entry "${FIX_ROOT}" 0001 file '/tmp/we\"ird' created prepared '"absent"' '{"sha256":"ab","mode":"0644","owner":"root"}'
  e="${FIX_ROOT}/journal/0001-file.json"
  assert_equal "$(harbor_journal_field "${e}" post_state)" '{"sha256":"ab","mode":"0644","owner":"root"}'
  assert_equal "$(harbor_journal_field "${e}" pre_state)" '"absent"'
  run harbor_journal_field "${e}" resolved_by
  assert_failure
  assert_equal "$(harbor_journal_raw "${e}" resolved_by)" ""
  assert_equal "$(harbor_journal_string "${e}" target)" '/tmp/we"ird'
  assert_equal "$(harbor_journal_string "${e}" phase)" prepared
  assert_equal "$(harbor_json_unquote '"a\\b"')" 'a\b'
  assert_equal "$(harbor_json_unquote '{"k":1}')" '{"k":1}'
}

@test "print_entry writes the undecidable block to stderr" {
  fixture_entry "${FIX_ROOT}" 0002 file /etc/x created prepared '"absent"' '{"sha256":"ab","mode":"0644","owner":"root"}'
  run --separate-stderr harbor_journal_print_entry "${FIX_ROOT}/journal/0002-file.json" '{"sha256":"cd","mode":"0644","owner":"root"}'
  assert_equal "${output}" ""
  assert_equal "${stderr_lines[0]}" 'journal entry 0002-file.json is undecidable:'
  assert_equal "${stderr_lines[1]}" '  op:         file'
  assert_equal "${stderr_lines[2]}" '  target:     /etc/x'
  assert_equal "${stderr_lines[3]}" '  pre_state:  "absent"'
  assert_equal "${stderr_lines[4]}" '  post_state: {"sha256":"ab","mode":"0644","owner":"root"}'
  assert_equal "${stderr_lines[5]}" '  observed:   {"sha256":"cd","mode":"0644","owner":"root"}'
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `tests/run_unit.sh tests/unit/lib/journal.bats`
Expected: FAIL. `setup` fails with `lib/journal.sh: No such file or directory`.

- [ ] **Step 3: Write `lib/journal.sh`**

```bash
#!/bin/bash
# Ownership journal (design section 3.7): observation helpers, the platform sync
# helper, canonical entry rendering and parsing, ln-based creation, rename-over phase
# rewrites, recovery, and harbor journal resolve. HARBOR_JOURNAL_* globals are read
# by callers.
# shellcheck disable=SC2034
harbor_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "${1}" | cut -d' ' -f1
  else
    shasum -a 256 "${1}" | cut -d' ' -f1
  fi
}
harbor_stat_mode() {
  local raw
  case "$(harbor_os)" in
    Linux) raw="$(stat -c '%a' "${1}")" ;;
    Darwin) raw="$(stat -f '%Lp' "${1}")" ;;
  esac
  printf '%04d' "$((10#${raw}))"
}
harbor_stat_owner() {
  case "$(harbor_os)" in
    Linux) stat -c '%U' "${1}" ;;
    Darwin) stat -f '%Su' "${1}" ;;
  esac
}
harbor_journal_sync_path() {
  if [ -z "${HARBOR_SYNC_MODE:-}" ]; then
    case "$(harbor_os)" in
      Linux) HARBOR_SYNC_MODE="file" ;;
      Darwin) HARBOR_SYNC_MODE="fs" ;;
      *) harbor_die 3 journal.platform "unsupported platform $(harbor_os)" ;;
    esac
  fi
  case "${HARBOR_SYNC_MODE}" in
    file) sync -- "${1}" || harbor_die 2 journal.sync "sync of ${1} failed" ;;
    fs) sync ;;
  esac
}
harbor_journal_dir() {
  printf '%s/journal' "${1}"
}
harbor_journal_init() {
  local dir="${1}/journal"
  if [ ! -d "${dir}" ]; then
    mkdir "${dir}"
    chmod 0700 "${dir}"
  fi
}
harbor_journal_render() {
  local op="${1}" target="${2}" ownership="${3}" phase="${4}" pre="${5}" post="${6}"
  local resolved_by="${7:-}" resolved_at="${8:-}"
  printf '{\n'
  printf '  "op": "%s",\n' "$(harbor_json_escape "${op}")"
  printf '  "target": "%s",\n' "$(harbor_json_escape "${target}")"
  printf '  "ownership": "%s",\n' "${ownership}"
  printf '  "phase": "%s",\n' "${phase}"
  printf '  "pre_state": %s,\n' "${pre}"
  if [ -n "${resolved_by}" ]; then
    printf '  "post_state": %s,\n' "${post}"
    printf '  "resolved_by": "%s",\n' "${resolved_by}"
    printf '  "resolved_at": "%s"\n' "${resolved_at}"
  else
    printf '  "post_state": %s\n' "${post}"
  fi
  printf '}\n'
}
harbor_journal_field() {
  local line
  line="$(grep -m 1 "^  \"${2}\": " "${1}" || true)"
  [ -n "${line}" ] || return 1
  line="${line#*: }"
  line="${line%,}"
  printf '%s' "${line}"
}
harbor_journal_raw() {
  harbor_journal_field "${1}" "${2}" || true
}
harbor_json_unquote() {
  local v="${1}"
  case "${v}" in
    \"*\")
      v="${v#\"}"
      v="${v%\"}"
      ;;
  esac
  printf '%s' "${v}" | sed -e 's/\\"/"/g' -e 's/\\\\/\\/g'
}
harbor_journal_string() {
  harbor_json_unquote "$(harbor_journal_raw "${1}" "${2}")"
}
harbor_observe_file() {
  local path="${1}"
  if [ ! -e "${path}" ] && [ ! -L "${path}" ]; then
    printf '"absent"'
    return 0
  fi
  if [ ! -f "${path}" ] || [ -L "${path}" ]; then
    printf '"unobservable:not-a-regular-file"'
    return 0
  fi
  printf '{"sha256":"%s","mode":"%s","owner":"%s"}' \
    "$(harbor_sha256 "${path}")" "$(harbor_stat_mode "${path}")" "$(harbor_json_escape "$(harbor_stat_owner "${path}")")"
}
harbor_journal_observe() {
  case "${1}" in
    file) harbor_observe_file "${2}" ;;
    *) printf '"unobservable:%s"' "$(harbor_json_escape "${1}")" ;;
  esac
}
harbor_journal_print_entry() {
  {
    printf 'journal entry %s is undecidable:\n' "$(basename "${1}")"
    printf '  op:         %s\n' "$(harbor_journal_string "${1}" op)"
    printf '  target:     %s\n' "$(harbor_journal_string "${1}" target)"
    printf '  pre_state:  %s\n' "$(harbor_journal_raw "${1}" pre_state)"
    printf '  post_state: %s\n' "$(harbor_journal_raw "${1}" post_state)"
    printf '  observed:   %s\n' "${2}"
  } >&2
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `tests/run_unit.sh tests/unit/lib/journal.bats`
Expected: `1..7`, all `ok`, exit 0.

- [ ] **Step 5: Hand off for review (no commit)**

Stop here and report as described under "Working conventions": the test commands run in this task with their results, `git status --short`, and `git diff --stat`. Do not run `git commit`. After the Fable pre-commit review and the orchestrator's own review, the orchestrator stages and commits:

- Files: `lib/journal.sh`, `tests/unit/lib/journal.bats`
- Message: `feat(journal): observation, platform sync helper, canonical entry rendering and parsing`

---

### Task 11: `lib/journal.sh` entry creation via `ln`, rename-over phase rewrite, owner refusal

**Files:**

- Modify: `lib/journal.sh` (append)
- Test: `tests/unit/lib/journal.bats` (append)

**Interfaces:**

- Consumes: Task 10 functions; `harbor_lock_assert_owner` (Task 9); `HARBOR_LOCK_ID_PID` (Task 7); `harbor_log`, `harbor_utc_now` (Task 3).
- Produces:
  - `harbor_journal_next_seq DIR`: sets `HARBOR_JOURNAL_SEQ` to the highest existing `NNNN-*.json` plus one, four digits; dies 2 `journal.full` past 9999.
  - `harbor_journal_create ROOT OP TARGET OWNERSHIP PHASE PRE POST`: asserts ownership, allocates the sequence, renders to `ROOT/journal/.tmp.<seq>.<pid>`, syncs it, hard-links it to `ROOT/journal/<seq>-<OP>.json`, unlinks the temporary file, syncs the directory, logs `journal created …`, sets `HARBOR_JOURNAL_ENTRY`. On `ln` failure removes the temporary file and dies 2 `journal.collision` naming the final and temporary paths.
  - `harbor_journal_malformed ENTRY REASON`: `harbor_die 2 journal.malformed` naming the entry and REASON.
  - `harbor_journal_validate ENTRY`: the fail-closed shape check. It accepts exactly the text `harbor_journal_render` produces and nothing else, line by line, with no JSON parser and bash 3.2 only. The entry has exactly 8 lines (six fields) or exactly 10 lines (six fields plus the resolution pair) and ends with a newline; line 1 is `{`, the last line is `}`, and every line between is the quoted key preceded by two spaces, then a colon, one space, and a non-empty value with a trailing comma on every body line but the last and on no other. The keys are `op`, `target`, `ownership`, `phase`, `pre_state`, `post_state` in that order, each exactly once, followed in a 10-line entry by `resolved_by` and `resolved_at` in that order, so an unknown key, an extra line, a repeated key, a missing key, a key out of place, a comma fault, a brace fault, a blank line, trailing content after `}`, and a missing final newline are all refused. `op`, `target`, `resolved_by`, and `resolved_at` must be non-empty quoted strings; `ownership` must be `created`, `modified`, or `observed`; `phase` must be `prepared`, `applied`, or `reverted`. The resolution pair is all or nothing: one field without the other, either field twice, or an empty value is refused, and because PR 2's only manual resolution is `--reverted`, a 10-line entry whose phase is not `reverted` is refused too. Anything else is `harbor_journal_malformed` naming the entry, the line, and the failing key.
  - `harbor_journal_set_phase ENTRY PHASE [RESOLVED_BY]`: asserts ownership, validates the entry, re-renders it with the new phase (and `resolved_by` plus a fresh `resolved_at` when given), writes `.tmp.<basename>.<pid>`, syncs, renames over ENTRY, syncs the directory, logs. Dies 3 `journal.phase` for a phase outside `prepared|applied|reverted` and 2 `journal.malformed` (through `harbor_journal_validate`) before writing anything for a non-canonical entry.

- [ ] **Step 1: Append the failing tests**

Append to `tests/unit/lib/journal.bats`:

```bash
acquire() {
  harbor_lock_acquire "${FIX_ROOT}" operator
}

refuse_malformed() {
  # refuse_malformed ENTRY: harbor_journal_validate exits 2 journal.malformed naming ENTRY
  run harbor_journal_validate "${1}"
  assert_equal "${status}" 2
  assert_output --partial 'journal.malformed'
  assert_output --partial "$(basename "${1}")"
}

@test "entries are created through ln with unique ascending sequence numbers and no temporary file left" {
  acquire
  harbor_journal_create "${FIX_ROOT}" file /etc/a created prepared '"absent"' '{"sha256":"ab","mode":"0644","owner":"root"}'
  assert_equal "${HARBOR_JOURNAL_ENTRY}" "${FIX_ROOT}/journal/0001-file.json"
  harbor_journal_create "${FIX_ROOT}" file /etc/b modified prepared '{"sha256":"cd","mode":"0644","owner":"root"}' '{"sha256":"ef","mode":"0644","owner":"root"}'
  harbor_journal_create "${FIX_ROOT}" package curl observed applied '"unobservable:package"' '"unobservable:package"'
  run ls -A "${FIX_ROOT}/journal"
  assert_line --index 0 0001-file.json
  assert_line --index 1 0002-file.json
  assert_line --index 2 0003-package.json
  assert_equal "${#lines[@]}" 3
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" prepared
  assert_equal "$(entry_phase "${FIX_ROOT}" 0003)" applied
  assert_equal "$(cat "${FIX_ROOT}/journal/0001-file.json")" "$(harbor_journal_render file /etc/a created prepared '"absent"' '{"sha256":"ab","mode":"0644","owner":"root"}')"
  harbor_lock_release "${FIX_ROOT}"
}

@test "the sequence continues from the highest existing entry" {
  fixture_entry "${FIX_ROOT}" 0041 file /x created applied '"absent"' '"absent"'
  harbor_journal_next_seq "${FIX_ROOT}/journal"
  assert_equal "${HARBOR_JOURNAL_SEQ}" 0042
  rm "${FIX_ROOT}/journal/0041-file.json"
  harbor_journal_next_seq "${FIX_ROOT}/journal"
  assert_equal "${HARBOR_JOURNAL_SEQ}" 0001
  fixture_entry "${FIX_ROOT}" 9999 file /x created applied '"absent"' '"absent"'
  run harbor_journal_next_seq "${FIX_ROOT}/journal"
  assert_equal "${status}" 2
  assert_output --partial 'journal.full'
}

@test "a forced sequence collision aborts with exit 2 naming both files and overwrites nothing" {
  acquire
  harbor_journal_create "${FIX_ROOT}" file /etc/a created prepared '"absent"' '"absent"'
  before="$(cat "${FIX_ROOT}/journal/0001-file.json")"
  harbor_journal_next_seq() { HARBOR_JOURNAL_SEQ=0001; }
  run harbor_journal_create "${FIX_ROOT}" file /etc/other created prepared '"absent"' '"absent"'
  assert_equal "${status}" 2
  assert_output --partial 'journal.collision'
  assert_output --partial "${FIX_ROOT}/journal/0001-file.json"
  assert_output --partial "${FIX_ROOT}/journal/.tmp.0001.${HARBOR_PID}"
  assert_equal "$(cat "${FIX_ROOT}/journal/0001-file.json")" "${before}"
  run ls -A "${FIX_ROOT}/journal"
  assert_output 0001-file.json
  harbor_lock_release "${FIX_ROOT}"
}

@test "set_phase rewrites by rename-over, keeps every other field, and records operator resolution" {
  acquire
  harbor_journal_create "${FIX_ROOT}" file /etc/a created prepared '"absent"' '{"sha256":"ab","mode":"0644","owner":"root"}'
  e="${HARBOR_JOURNAL_ENTRY}"
  harbor_journal_set_phase "${e}" applied
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" applied
  assert_equal "$(harbor_journal_raw "${e}" post_state)" '{"sha256":"ab","mode":"0644","owner":"root"}'
  assert_equal "$(harbor_journal_string "${e}" target)" /etc/a
  assert_equal "$(harbor_journal_raw "${e}" resolved_by)" ""
  harbor_journal_set_phase "${e}" reverted operator
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" reverted
  assert_equal "$(harbor_journal_string "${e}" resolved_by)" operator
  assert_regex "$(harbor_journal_string "${e}" resolved_at)" '^[0-9]{8}T[0-9]{6}Z$'
  harbor_journal_validate "${e}"
  run ls -A "${FIX_ROOT}/journal"
  assert_output 0001-file.json
  run harbor_journal_set_phase "${e}" done
  assert_equal "${status}" 3
  assert_output --partial 'journal.phase'
  printf '{\n  "phase": "prepared"\n}\n' >"${FIX_ROOT}/journal/0002-file.json"
  run harbor_journal_set_phase "${FIX_ROOT}/journal/0002-file.json" applied
  assert_equal "${status}" 2
  assert_output --partial 'journal.malformed'
  harbor_lock_release "${FIX_ROOT}"
}

@test "a holder whose lock was reclaimed exits 2 before creating or rewriting any entry" {
  sleep 30 3>&- &
  KEEP_PID=$!
  acquire
  harbor_journal_create "${FIX_ROOT}" file /etc/a created prepared '"absent"' '"absent"'
  e="${HARBOR_JOURNAL_ENTRY}"
  holder_record "${KEEP_PID}" "$(harbor_lock_start_time "${KEEP_PID}")" >"${FIX_ROOT}/lock.d/holder"
  run harbor_journal_create "${FIX_ROOT}" file /etc/b created prepared '"absent"' '"absent"'
  assert_equal "${status}" 2
  assert_output --partial 'lock.lost'
  run harbor_journal_set_phase "${e}" applied
  assert_equal "${status}" 2
  assert_output --partial 'lock.lost'
  run ls -A "${FIX_ROOT}/journal"
  assert_output 0001-file.json
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" prepared
  rm -r "${FIX_ROOT}/lock.d"
}

@test "validate accepts a canonical entry and rejects a missing or empty target, a bad ownership or phase, a duplicate key, and a missing or empty state" {
  fixture_entry "${FIX_ROOT}" 0001 file /etc/a created prepared '"absent"' '"absent"'
  good="${FIX_ROOT}/journal/0001-file.json"
  bad="${FIX_ROOT}/journal/0002-file.json"
  harbor_journal_validate "${good}"
  grep -v '"target"' "${good}" >"${bad}"
  run harbor_journal_validate "${bad}"
  assert_equal "${status}" 2
  assert_output --partial 'journal.malformed'
  assert_output --partial '0002-file.json'
  sed 's|"target": "/etc/a"|"target": ""|' "${good}" >"${bad}"
  run harbor_journal_validate "${bad}"
  assert_equal "${status}" 2
  assert_output --partial 'journal.malformed'
  sed 's/"ownership": "created"/"ownership": "owned"/' "${good}" >"${bad}"
  run harbor_journal_validate "${bad}"
  assert_equal "${status}" 2
  assert_output --partial 'journal.malformed'
  sed 's/"phase": "prepared"/"phase": "done"/' "${good}" >"${bad}"
  run harbor_journal_validate "${bad}"
  assert_equal "${status}" 2
  assert_output --partial 'journal.malformed'
  sed '/"phase"/p' "${good}" >"${bad}"
  run harbor_journal_validate "${bad}"
  assert_equal "${status}" 2
  assert_output --partial 'journal.malformed'
  grep -v '"post_state"' "${good}" >"${bad}"
  run harbor_journal_validate "${bad}"
  assert_equal "${status}" 2
  assert_output --partial 'journal.malformed'
  sed 's/"pre_state": "absent"/"pre_state": /' "${good}" >"${bad}"
  run harbor_journal_validate "${bad}"
  assert_equal "${status}" 2
  assert_output --partial 'journal.malformed'
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" prepared
}

@test "validate rejects every departure from the canonical shape: unknown key, extra line, trailing content, missing newline, wrong order, comma faults, brace faults" {
  fixture_entry "${FIX_ROOT}" 0001 file /etc/a created prepared '"absent"' '"absent"'
  good="${FIX_ROOT}/journal/0001-file.json"
  bad="${FIX_ROOT}/journal/0002-file.json"
  harbor_journal_validate "${good}"
  sed 's/"ownership"/"owner"/' "${good}" >"${bad}"
  refuse_malformed "${bad}"
  awk 'NR == 4 { print; print "  \"extra\": \"x\","; next } { print }' "${good}" >"${bad}"
  refuse_malformed "${bad}"
  { cat "${good}"; printf 'junk\n'; } >"${bad}"
  refuse_malformed "${bad}"
  { cat "${good}"; printf '\n'; } >"${bad}"
  refuse_malformed "${bad}"
  printf '%s' "$(cat "${good}")" >"${bad}"
  refuse_malformed "${bad}"
  sed -e '2{h;d;}' -e '3G' "${good}" >"${bad}"
  refuse_malformed "${bad}"
  sed '2s/,$//' "${good}" >"${bad}"
  refuse_malformed "${bad}"
  sed '7s/$/,/' "${good}" >"${bad}"
  refuse_malformed "${bad}"
  sed '1s/{/[/' "${good}" >"${bad}"
  refuse_malformed "${bad}"
  sed '8s/}/]/' "${good}" >"${bad}"
  refuse_malformed "${bad}"
  sed '1d' "${good}" >"${bad}"
  refuse_malformed "${bad}"
  sed '$d' "${good}" >"${bad}"
  refuse_malformed "${bad}"
  sed 's/^  "op"/ "op"/' "${good}" >"${bad}"
  refuse_malformed "${bad}"
  sed 's/"op": "file"/"op":"file"/' "${good}" >"${bad}"
  refuse_malformed "${bad}"
  : >"${bad}"
  refuse_malformed "${bad}"
  harbor_journal_validate "${good}"
}

@test "validate accepts a canonical resolved entry and rejects a partial, duplicated, empty, unquoted, or misplaced resolution pair and resolution fields on a non-reverted entry" {
  full="${FIX_ROOT}/journal/0001-file.json"
  bad="${FIX_ROOT}/journal/0002-file.json"
  harbor_journal_render file /etc/a created reverted '"absent"' '"absent"' operator 20260902T120000Z >"${full}"
  harbor_journal_validate "${full}"
  harbor_journal_render file /etc/a created reverted '"absent"' '"absent"' >"${bad}"
  harbor_journal_validate "${bad}"
  grep -v '"resolved_at"' "${full}" | sed '8s/,$//' >"${bad}"
  refuse_malformed "${bad}"
  grep -v '"resolved_by"' "${full}" >"${bad}"
  refuse_malformed "${bad}"
  sed 's/"resolved_at": "20260902T120000Z"/"resolved_by": "operator"/' "${full}" >"${bad}"
  refuse_malformed "${bad}"
  sed 's/"resolved_by": "operator",/"resolved_at": "20260902T120000Z",/' "${full}" >"${bad}"
  refuse_malformed "${bad}"
  sed 's/"resolved_by": "operator"/"resolved_by": ""/' "${full}" >"${bad}"
  refuse_malformed "${bad}"
  sed 's/"resolved_at": "20260902T120000Z"/"resolved_at": ""/' "${full}" >"${bad}"
  refuse_malformed "${bad}"
  sed 's/"resolved_at": "20260902T120000Z"/"resolved_at": 20260902T120000Z/' "${full}" >"${bad}"
  refuse_malformed "${bad}"
  awk 'NR == 7 { held = $0; next } NR == 9 { print; print held; next } { print }' "${full}" >"${bad}"
  refuse_malformed "${bad}"
  harbor_journal_render file /etc/a created prepared '"absent"' '"absent"' operator 20260902T120000Z >"${bad}"
  refuse_malformed "${bad}"
  harbor_journal_render file /etc/a created applied '"absent"' '"absent"' operator 20260902T120000Z >"${bad}"
  refuse_malformed "${bad}"
  harbor_journal_validate "${full}"
}
```

The two shape tests build each non-canonical entry from a canonical one with `sed` and `awk` so the plan never spells a broken entry out by hand; `sed -e '2{h;d;}' -e '3G'` swaps lines 2 and 3 on both BSD and GNU sed. `harbor_journal_render` emits the resolution pair for any phase it is given, which is what lets the last two cases prove that validation, not rendering, refuses resolution metadata on a non-reverted entry.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `tests/run_unit.sh tests/unit/lib/journal.bats`
Expected: FAIL. The seven Task 10 tests pass; the eight new ones fail with `harbor_journal_create: command not found`, `harbor_journal_next_seq: command not found`, or `harbor_journal_validate: command not found`.

- [ ] **Step 3: Append to `lib/journal.sh`**

```bash
harbor_journal_next_seq() {
  local f last="" n
  for f in "${1}"/[0-9][0-9][0-9][0-9]-*.json; do
    [ -e "${f}" ] || continue
    last="$(basename "${f}")"
    last="${last%%-*}"
  done
  n=$((10#${last:-0} + 1))
  [ "${n}" -le 9999 ] || harbor_die 2 journal.full "${1} has reached entry 9999"
  HARBOR_JOURNAL_SEQ="$(printf '%04d' "${n}")"
}
harbor_journal_create() {
  local root="${1}" dir final tmp
  dir="${root}/journal"
  harbor_lock_assert_owner "${root}"
  harbor_journal_next_seq "${dir}"
  final="${dir}/${HARBOR_JOURNAL_SEQ}-${2}.json"
  tmp="${dir}/.tmp.${HARBOR_JOURNAL_SEQ}.${HARBOR_LOCK_ID_PID}"
  harbor_journal_render "${2}" "${3}" "${4}" "${5}" "${6}" "${7}" >"${tmp}"
  harbor_journal_sync_path "${tmp}"
  if ! ln "${tmp}" "${final}" 2>/dev/null; then
    rm -f "${tmp}"
    harbor_die 2 journal.collision "entry ${final} already exists; refusing to overwrite it with ${tmp}"
  fi
  rm -f "${tmp}"
  harbor_journal_sync_path "${dir}"
  harbor_log journal "created $(basename "${final}") ${4} ${5}"
  HARBOR_JOURNAL_ENTRY="${final}"
}
harbor_journal_malformed() {
  harbor_die 2 journal.malformed "${1} is not a canonical journal entry: ${2}"
}
# Fail-closed shape check: the entry must be, line for line, what
# harbor_journal_render writes. The positional parameters hold the keys still
# expected, in canonical order, so a key that is missing, repeated, unknown, or
# out of place fails on the first line that does not match.
harbor_journal_validate() {
  local entry="${1}" total n=0 line value phase=""
  [ -f "${entry}" ] || harbor_journal_malformed "${entry}" "not a regular file"
  total="$(awk 'END { print NR }' "${entry}")"
  case "${total}" in
    8) set -- op target ownership phase pre_state post_state ;;
    10) set -- op target ownership phase pre_state post_state resolved_by resolved_at ;;
    *) harbor_journal_malformed "${entry}" "expected 8 or 10 lines, found ${total}" ;;
  esac
  [ -z "$(tail -c 1 "${entry}")" ] || harbor_journal_malformed "${entry}" "line ${total} is not terminated by a newline"
  while IFS= read -r line || [ -n "${line}" ]; do
    n=$((n + 1))
    if [ "${n}" -eq 1 ]; then
      [ "${line}" = "{" ] || harbor_journal_malformed "${entry}" "line 1 must be {"
      continue
    fi
    if [ "${n}" -eq "${total}" ]; then
      [ "${line}" = "}" ] || harbor_journal_malformed "${entry}" "line ${n} must be }"
      continue
    fi
    case "${line}" in
      "  \"${1}\": "?*) ;;
      *) harbor_journal_malformed "${entry}" "line ${n} must be the ${1} field: keys in canonical order, one per line, two-space indent, one space after the colon" ;;
    esac
    value="${line#*: }"
    if [ "${n}" -lt "$((total - 1))" ]; then
      case "${value}" in
        *,) value="${value%,}" ;;
        *) harbor_journal_malformed "${entry}" "line ${n} (${1}) must end with a comma" ;;
      esac
    else
      case "${value}" in
        *,) harbor_journal_malformed "${entry}" "line ${n} (${1}) must not end with a comma" ;;
      esac
    fi
    [ -n "${value}" ] || harbor_journal_malformed "${entry}" "${1} is empty"
    case "${1}" in
      op | target | resolved_by | resolved_at)
        case "${value}" in
          \"?*\") ;;
          *) harbor_journal_malformed "${entry}" "${1} must be a non-empty quoted string" ;;
        esac
        ;;
      ownership)
        case "${value}" in
          '"created"' | '"modified"' | '"observed"') ;;
          *) harbor_journal_malformed "${entry}" "ownership must be created, modified, or observed" ;;
        esac
        ;;
      phase)
        case "${value}" in
          '"prepared"' | '"applied"' | '"reverted"') phase="${value}" ;;
          *) harbor_journal_malformed "${entry}" "phase must be prepared, applied, or reverted" ;;
        esac
        ;;
    esac
    shift
  done <"${entry}"
  if [ "${total}" -eq 10 ] && [ "${phase}" != '"reverted"' ]; then
    harbor_journal_malformed "${entry}" "resolved_by and resolved_at are valid only with phase reverted"
  fi
}
harbor_journal_set_phase() {
  local entry="${1}" phase="${2}" resolved_by="${3:-}"
  local dir root tmp op target ownership pre post at=""
  dir="$(dirname "${entry}")"
  root="$(dirname "${dir}")"
  case "${phase}" in
    prepared | applied | reverted) ;;
    *) harbor_die 3 journal.phase "unknown phase ${phase}" ;;
  esac
  harbor_lock_assert_owner "${root}"
  harbor_journal_validate "${entry}"
  op="$(harbor_journal_string "${entry}" op)"
  target="$(harbor_journal_string "${entry}" target)"
  ownership="$(harbor_journal_string "${entry}" ownership)"
  pre="$(harbor_journal_raw "${entry}" pre_state)"
  post="$(harbor_journal_raw "${entry}" post_state)"
  [ -z "${resolved_by}" ] || at="$(harbor_utc_now)"
  tmp="${dir}/.tmp.$(basename "${entry}").${HARBOR_LOCK_ID_PID}"
  harbor_journal_render "${op}" "${target}" "${ownership}" "${phase}" "${pre}" "${post}" "${resolved_by}" "${at}" >"${tmp}"
  harbor_journal_sync_path "${tmp}"
  mv -f "${tmp}" "${entry}"
  harbor_journal_sync_path "${dir}"
  harbor_log journal "$(basename "${entry}") ${phase}${resolved_by:+ resolved_by=${resolved_by}}"
}
```

`awk 'END { print NR }'` and `tail -c 1` are the only tools the check uses beyond bash itself; both count an unterminated final line, so `}` without a newline and anything written after `}` are refused. `set --` loads the expected keys into the function's positional parameters, which bash 3.2 supports without arrays; each accepted body line shifts one off, and the `}` line is reached exactly when none is left.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `tests/run_unit.sh tests/unit/lib/journal.bats`
Expected: `1..15`, all `ok`, exit 0.

- [ ] **Step 5: Hand off for review (no commit)**

Stop here and report as described under "Working conventions": the test commands run in this task with their results, `git status --short`, and `git diff --stat`. Do not run `git commit`. After the Fable pre-commit review and the orchestrator's own review, the orchestrator stages and commits:

- Files: `lib/journal.sh`, `tests/unit/lib/journal.bats`
- Message: `feat(journal): ln-based entry creation, rename-over phase rewrite, owner refusal`

---

### Task 12: `lib/journal.sh` recovery with strict and lenient modes

**Files:**

- Modify: `lib/journal.sh` (append)
- Test: `tests/unit/lib/journal.bats` (append)

**Interfaces:**

- Consumes: Tasks 10 and 11.
- Produces:
  - `harbor_journal_recover ROOT [EXCEPT_SEQ]`: scans `ROOT/journal/NNNN-*.json` in order; for each `prepared` entry other than `EXCEPT_SEQ`, observes the target: equal to `pre_state` marks `reverted`, equal to `post_state` marks `applied`, otherwise prints the entry beside the observed state and records the sequence in `HARBOR_JOURNAL_UNDECIDABLE` (space-separated). Without `EXCEPT_SEQ` (strict mode) any undecidable entry ends with `harbor_die 2 journal.undecidable` naming the sequences and the `harbor journal resolve <NNNN> --reverted` command. With `EXCEPT_SEQ` (lenient mode, used only by `harbor journal resolve`) it returns 0 and leaves undecidable entries `prepared`. Returns 0 immediately when the journal directory is absent. Before acting on any entry it runs `harbor_journal_validate` over every entry in both modes, so any non-canonical entry (a missing, empty, repeated, unknown, or misplaced field, a comma or brace fault, trailing content, a partial, duplicated, or empty resolution pair, or resolution fields on an entry that is not `reverted`) stops recovery with exit 2 `journal.malformed` and nothing is rewritten or silently skipped.

- [ ] **Step 1: Append the failing tests**

Append to `tests/unit/lib/journal.bats`:

```bash
@test "recovery marks a pre-equal entry reverted, a post-equal entry applied, and refuses on an undecidable one with exit 2" {
  acquire
  printf 'landed\n' >"${BATS_TEST_TMPDIR}/b"
  post_b="$(harbor_observe_file "${BATS_TEST_TMPDIR}/b")"
  fixture_entry "${FIX_ROOT}" 0001 file "${BATS_TEST_TMPDIR}/a" created prepared '"absent"' '{"sha256":"ab","mode":"0644","owner":"root"}'
  fixture_entry "${FIX_ROOT}" 0002 file "${BATS_TEST_TMPDIR}/b" created prepared '"absent"' "${post_b}"
  fixture_undecidable_file_entry "${FIX_ROOT}" 0003
  fixture_entry "${FIX_ROOT}" 0004 file "${BATS_TEST_TMPDIR}/d" created applied '"absent"' '"absent"'
  run --separate-stderr harbor_journal_recover "${FIX_ROOT}"
  assert_equal "${status}" 2
  assert_regex "${stderr}" 'journal entry 0003-file.json is undecidable:'
  assert_regex "${stderr}" 'journal.undecidable: prepared entries 0003 cannot be decided'
  assert_regex "${stderr}" 'harbor journal resolve <NNNN> --reverted'
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" reverted
  assert_equal "$(entry_phase "${FIX_ROOT}" 0002)" applied
  assert_equal "$(entry_phase "${FIX_ROOT}" 0003)" prepared
  assert_equal "$(entry_phase "${FIX_ROOT}" 0004)" applied
  assert_equal "$(cat "${FIX_ARTIFACT_0003}")" two
  harbor_lock_release "${FIX_ROOT}"
}

@test "recovery on a clean or absent journal returns 0 and touches nothing" {
  acquire
  fixture_entry "${FIX_ROOT}" 0001 file /x created applied '"absent"' '"absent"'
  harbor_journal_recover "${FIX_ROOT}"
  assert_equal "${HARBOR_JOURNAL_UNDECIDABLE}" ""
  rm -r "${FIX_ROOT}/journal"
  harbor_journal_recover "${FIX_ROOT}"
  assert [ ! -e "${FIX_ROOT}/journal" ]
  harbor_lock_release "${FIX_ROOT}"
}

@test "lenient recovery skips the named entry, recovers the decidable ones, reports the other undecidable one, and returns 0" {
  acquire
  fixture_undecidable_file_entry "${FIX_ROOT}" 0001
  fixture_entry "${FIX_ROOT}" 0002 file "${BATS_TEST_TMPDIR}/absent" created prepared '"absent"' '{"sha256":"ab","mode":"0644","owner":"root"}'
  fixture_undecidable_file_entry "${FIX_ROOT}" 0003
  run --separate-stderr harbor_journal_recover "${FIX_ROOT}" 0001
  assert_success
  assert_regex "${stderr}" 'journal entry 0003-file.json is undecidable:'
  refute_regex "${stderr}" '0001-file.json'
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" prepared
  assert_equal "$(entry_phase "${FIX_ROOT}" 0002)" reverted
  assert_equal "$(entry_phase "${FIX_ROOT}" 0003)" prepared
  harbor_journal_recover "${FIX_ROOT}" 0001 2>/dev/null
  assert_equal "${HARBOR_JOURNAL_UNDECIDABLE}" "0003"
  harbor_lock_release "${FIX_ROOT}"
}

@test "recovery refuses a malformed entry with exit 2 before rewriting anything, in strict and lenient mode alike" {
  acquire
  fixture_entry "${FIX_ROOT}" 0001 file "${BATS_TEST_TMPDIR}/absent" created prepared '"absent"' '{"sha256":"ab","mode":"0644","owner":"root"}'
  fixture_entry "${FIX_ROOT}" 0002 file /x created prepared '"absent"' '"absent"'
  grep -v '"target"' "${FIX_ROOT}/journal/0002-file.json" >"${BATS_TEST_TMPDIR}/stripped"
  cat "${BATS_TEST_TMPDIR}/stripped" >"${FIX_ROOT}/journal/0002-file.json"
  before="$(cat "${FIX_ROOT}/journal/0002-file.json")"
  run harbor_journal_recover "${FIX_ROOT}"
  assert_equal "${status}" 2
  assert_output --partial 'journal.malformed'
  assert_output --partial '0002-file.json'
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" prepared
  assert_equal "$(cat "${FIX_ROOT}/journal/0002-file.json")" "${before}"
  run harbor_journal_recover "${FIX_ROOT}" 0001
  assert_equal "${status}" 2
  assert_output --partial 'journal.malformed'
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" prepared
  assert_equal "$(cat "${FIX_ROOT}/journal/0002-file.json")" "${before}"
  run ls -A "${FIX_ROOT}/journal"
  assert_line --index 0 0001-file.json
  assert_line --index 1 0002-file.json
  assert_equal "${#lines[@]}" 2
  harbor_lock_release "${FIX_ROOT}"
}
```

Entry 0001 is decidable (the target is absent, equal to `pre_state`); it must still be `prepared` afterwards, which proves validation runs before any rewrite.

```bash
@test "recovery's validation pre-pass refuses every non-canonical shape before rewriting anything, in strict and lenient mode alike" {
  acquire
  fixture_entry "${FIX_ROOT}" 0001 file "${BATS_TEST_TMPDIR}/absent" created prepared '"absent"' '{"sha256":"ab","mode":"0644","owner":"root"}'
  good="${BATS_TEST_TMPDIR}/good"
  resolved="${BATS_TEST_TMPDIR}/resolved"
  bad="${FIX_ROOT}/journal/0002-file.json"
  harbor_journal_render file /x created prepared '"absent"' '"absent"' >"${good}"
  harbor_journal_render file /x created reverted '"absent"' '"absent"' operator 20260902T120000Z >"${resolved}"
  for shape in unknown-key extra-line trailing-junk missing-newline wrong-order missing-comma bad-brace partial-pair duplicate-pair empty-pair resolution-on-prepared; do
    case "${shape}" in
      unknown-key) sed 's/"ownership"/"owner"/' "${good}" >"${bad}" ;;
      extra-line) awk 'NR == 4 { print; print "  \"extra\": \"x\","; next } { print }' "${good}" >"${bad}" ;;
      trailing-junk) { cat "${good}"; printf 'junk\n'; } >"${bad}" ;;
      missing-newline) printf '%s' "$(cat "${good}")" >"${bad}" ;;
      wrong-order) sed -e '2{h;d;}' -e '3G' "${good}" >"${bad}" ;;
      missing-comma) sed '2s/,$//' "${good}" >"${bad}" ;;
      bad-brace) sed '1s/{/[/' "${good}" >"${bad}" ;;
      partial-pair) grep -v '"resolved_at"' "${resolved}" | sed '8s/,$//' >"${bad}" ;;
      duplicate-pair) sed 's/"resolved_at": "20260902T120000Z"/"resolved_by": "operator"/' "${resolved}" >"${bad}" ;;
      empty-pair) sed 's/"resolved_by": "operator"/"resolved_by": ""/' "${resolved}" >"${bad}" ;;
      resolution-on-prepared) harbor_journal_render file /x created prepared '"absent"' '"absent"' operator 20260902T120000Z >"${bad}" ;;
    esac
    before="$(cat "${bad}")"
    run harbor_journal_recover "${FIX_ROOT}"
    assert_equal "${status}" 2
    assert_output --partial 'journal.malformed'
    assert_output --partial '0002-file.json'
    assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" prepared
    assert_equal "$(cat "${bad}")" "${before}"
    run harbor_journal_recover "${FIX_ROOT}" 0001
    assert_equal "${status}" 2
    assert_output --partial 'journal.malformed'
    assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" prepared
    assert_equal "$(cat "${bad}")" "${before}"
  done
  run ls -A "${FIX_ROOT}/journal"
  assert_line --index 0 0001-file.json
  assert_line --index 1 0002-file.json
  assert_equal "${#lines[@]}" 2
  cp "${resolved}" "${bad}"
  harbor_journal_recover "${FIX_ROOT}"
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" reverted
  assert_equal "$(entry_phase "${FIX_ROOT}" 0002)" reverted
  assert_equal "$(cat "${bad}")" "$(cat "${resolved}")"
  harbor_lock_release "${FIX_ROOT}"
}
```

The loop rebuilds entry 0002 in each of the eleven shapes that Task 11 taught `harbor_journal_validate` to refuse and, for each, proves that both recovery modes exit 2 with the decidable entry 0001 still `prepared` and 0002 byte-for-byte unchanged. The final canonical resolved entry proves the pre-pass accepts what `harbor journal resolve` writes and that recovery then proceeds normally.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `tests/run_unit.sh tests/unit/lib/journal.bats`
Expected: FAIL. The fifteen earlier tests pass; the five new ones fail with `harbor_journal_recover: command not found`.

- [ ] **Step 3: Append to `lib/journal.sh`**

```bash
harbor_journal_recover() {
  local root="${1}" except="${2:-}" dir entry base seq phase op target pre post observed
  dir="${root}/journal"
  HARBOR_JOURNAL_UNDECIDABLE=""
  [ -d "${dir}" ] || return 0
  # Fail closed on any malformed entry before touching any entry.
  for entry in "${dir}"/[0-9][0-9][0-9][0-9]-*.json; do
    [ -e "${entry}" ] || continue
    harbor_journal_validate "${entry}"
  done
  for entry in "${dir}"/[0-9][0-9][0-9][0-9]-*.json; do
    [ -e "${entry}" ] || continue
    base="$(basename "${entry}")"
    seq="${base%%-*}"
    phase="$(harbor_journal_string "${entry}" phase)"
    [ "${phase}" = "prepared" ] || continue
    [ "${seq}" != "${except}" ] || continue
    op="$(harbor_journal_string "${entry}" op)"
    target="$(harbor_journal_string "${entry}" target)"
    pre="$(harbor_journal_raw "${entry}" pre_state)"
    post="$(harbor_journal_raw "${entry}" post_state)"
    observed="$(harbor_journal_observe "${op}" "${target}")"
    if [ "${observed}" = "${pre}" ]; then
      harbor_journal_set_phase "${entry}" reverted
      harbor_log recovery "${base} reverted (state equals pre_state)"
    elif [ "${observed}" = "${post}" ]; then
      harbor_journal_set_phase "${entry}" applied
      harbor_log recovery "${base} applied (state equals post_state)"
    else
      harbor_journal_print_entry "${entry}" "${observed}"
      HARBOR_JOURNAL_UNDECIDABLE="${HARBOR_JOURNAL_UNDECIDABLE} ${seq}"
    fi
  done
  HARBOR_JOURNAL_UNDECIDABLE="${HARBOR_JOURNAL_UNDECIDABLE# }"
  if [ -n "${HARBOR_JOURNAL_UNDECIDABLE}" ] && [ -z "${except}" ]; then
    harbor_die 2 journal.undecidable "prepared entries ${HARBOR_JOURNAL_UNDECIDABLE} cannot be decided; follow docs/runbook.md for each op and rerun, or run: harbor journal resolve <NNNN> --reverted"
  fi
  return 0
}
```

`docs/runbook.md` is named in the message because spec section 3.7 directs the operator there; the file itself arrives with PR 3, which adds the first runbook steps.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `tests/run_unit.sh tests/unit/lib/journal.bats`
Expected: `1..20`, all `ok`, exit 0.

- [ ] **Step 5: Hand off for review (no commit)**

Stop here and report as described under "Working conventions": the test commands run in this task with their results, `git status --short`, and `git diff --stat`. Do not run `git commit`. After the Fable pre-commit review and the orchestrator's own review, the orchestrator stages and commits:

- Files: `lib/journal.sh`, `tests/unit/lib/journal.bats`
- Message: `feat(journal): recovery with the three outcomes and the lenient resolve mode`

---

### Task 13: `bin/harbor` dispatcher with the pinned unknown-subcommand reply

**Files:**

- Create: `bin/harbor`
- Test: `tests/unit/bin/dispatch.bats`

**Interfaces:**

- Consumes: every library. `harbor_journal_cmd` (Task 14) is named in the `journal` arm; until Task 14 that arm is unreachable by any test.
- Produces:
  - `bin/harbor` (mode `0755`, shebang `#!/bin/bash`): `set -euo pipefail`, `LC_ALL=C` exported, `HARBOR_PID=$$`, `HARBOR_CMDLINE="harbor <args>"`, `HARBOR_JSON=0`, resolves its own path through symlinks without `readlink -f`, exports `HARBOR_ROOT`, sources `lib/log.sh`, `lib/checks.sh`, `lib/versions.sh`, `lib/lock.sh`, `lib/journal.sh`, installs traps, dispatches: no argument prints usage to stderr and exits 3; `help`, `--help`, `-h` print usage to stdout and exit 0; `journal` calls `harbor_journal_cmd` with the remaining arguments; anything else prints `{"error":"unknown_subcommand","subcommand":"<name>"}` to stdout and `harbor: unknown subcommand: <name>` to stderr and exits 3.

- [ ] **Step 1: Write the failing tests**

`tests/unit/bin/dispatch.bats`:

```bash
#!/usr/bin/env bats
load '../test_helper'

setup() {
  harbor_load_libs
  fixture_state_root
}

@test "the entry point is executable and runs under /bin/bash" {
  assert [ -x "${HARBOR}" ]
  assert_equal "$(head -n 1 "${HARBOR}")" '#!/bin/bash'
}

@test "unknown subcommand: exit 3, exactly one JSON object on stdout, one line on stderr" {
  run --separate-stderr "${HARBOR}" bogus
  assert_equal "${status}" 3
  assert_equal "${output}" '{"error":"unknown_subcommand","subcommand":"bogus"}'
  assert_equal "${stderr}" 'harbor: unknown subcommand: bogus'
}

@test "unknown subcommand with --json anywhere: the same reply" {
  run --separate-stderr "${HARBOR}" status --json
  assert_equal "${status}" 3
  assert_equal "${output}" '{"error":"unknown_subcommand","subcommand":"status"}'
  assert_equal "${stderr}" 'harbor: unknown subcommand: status'
}

@test "unknown subcommand name is JSON-escaped" {
  run --separate-stderr "${HARBOR}" 'we"ird'
  assert_equal "${status}" 3
  assert_equal "${output}" '{"error":"unknown_subcommand","subcommand":"we\"ird"}'
}

@test "unknown subcommand answers before any lock or journal access" {
  mkdir "${FIX_ROOT}/reclaim.d"
  fixture_undecidable_file_entry "${FIX_ROOT}" 0001
  run --separate-stderr env HOME="${FIX_HOME}" "${HARBOR}" provision
  assert_equal "${status}" 3
  assert_equal "${output}" '{"error":"unknown_subcommand","subcommand":"provision"}'
  assert [ -d "${FIX_ROOT}/reclaim.d" ]
  assert [ ! -e "${FIX_ROOT}/lock.d" ]
  assert [ ! -e "${FIX_ROOT}/harbor.log" ]
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" prepared
  fixture_home
  rm -r "${FIX_HOME}"
  mkdir "${FIX_HOME}"
  run env HOME="${FIX_HOME}" "${HARBOR}" bogus
  assert [ ! -e "${FIX_HOME}/.local" ]
}

@test "no subcommand prints usage to stderr and exits 3; help prints it to stdout and exits 0" {
  run --separate-stderr "${HARBOR}"
  assert_equal "${status}" 3
  assert_equal "${output}" ""
  assert_regex "${stderr}" '^usage: harbor <subcommand>'
  run --separate-stderr "${HARBOR}" help
  assert_success
  assert_regex "${output}" '^usage: harbor <subcommand>'
  assert_regex "${output}" 'journal resolve <NNNN> --reverted'
  run "${HARBOR}" --help
  assert_success
  run "${HARBOR}" -h
  assert_success
}

@test "the dispatcher runs from a symlink" {
  ln -s "${HARBOR}" "${BATS_TEST_TMPDIR}/harbor"
  run --separate-stderr "${BATS_TEST_TMPDIR}/harbor" bogus
  assert_equal "${status}" 3
  assert_equal "${output}" '{"error":"unknown_subcommand","subcommand":"bogus"}'
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `tests/run_unit.sh tests/unit/bin/dispatch.bats`
Expected: FAIL. Every test fails because `bin/harbor` does not exist (`not found` or `No such file`).

- [ ] **Step 3: Write `bin/harbor`**

```bash
#!/bin/bash
# Harbor entry point (design section 4): dispatches subcommands and contains no logic.
set -euo pipefail
LC_ALL=C
export LC_ALL
HARBOR_PID=$$
HARBOR_CMDLINE="harbor ${*:-}"
HARBOR_JSON=0
harbor_self="${0}"
while [ -L "${harbor_self}" ]; do
  harbor_link="$(readlink "${harbor_self}")"
  case "${harbor_link}" in
    /*) harbor_self="${harbor_link}" ;;
    *) harbor_self="$(dirname "${harbor_self}")/${harbor_link}" ;;
  esac
done
HARBOR_BIN_DIR="$(cd "$(dirname "${harbor_self}")" && pwd -P)"
HARBOR_ROOT="$(dirname "${HARBOR_BIN_DIR}")"
export HARBOR_ROOT
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
harbor_usage() {
  cat <<'USAGE'
usage: harbor <subcommand> [options]

subcommands:
  journal resolve <NNNN> --reverted   mark an undecidable prepared journal entry reverted
                                      without touching its artifact (design section 3.7)
  help                                print this text

Exit codes: 0 success, 1 degraded, 2 broken, 3 precondition or usage, 4 interrupted.
USAGE
}
harbor_install_traps
harbor_cmd="${1:-}"
case "${harbor_cmd}" in
  '')
    harbor_usage >&2
    exit 3
    ;;
  help | --help | -h)
    harbor_usage
    exit 0
    ;;
  journal)
    shift
    harbor_journal_cmd ${1+"$@"}
    ;;
  *)
    printf '{"error":"unknown_subcommand","subcommand":"%s"}\n' "$(harbor_json_escape "${harbor_cmd}")"
    printf 'harbor: unknown subcommand: %s\n' "${harbor_cmd}" >&2
    exit 3
    ;;
esac
HARBOR_COMPLETED=1
```

Run: `chmod +x bin/harbor`

- [ ] **Step 4: Run the tests to verify they pass**

Run: `tests/run_unit.sh tests/unit/bin/dispatch.bats`
Expected: `1..7`, all `ok`, exit 0.

- [ ] **Step 5: Hand off for review (no commit)**

Stop here and report as described under "Working conventions": the test commands run in this task with their results, `git status --short`, and `git diff --stat`. Do not run `git commit`. After the Fable pre-commit review and the orchestrator's own review, the orchestrator stages and commits:

- Files: `bin/harbor`, `tests/unit/bin/dispatch.bats`
- Message: `feat(bin): harbor dispatcher with the pinned unknown-subcommand reply`

---

### Task 14: `harbor journal resolve <NNNN> --reverted`

**Files:**

- Modify: `lib/journal.sh` (append)
- Test: `tests/unit/bin/resolve.bats`

**Interfaces:**

- Consumes: `harbor_state_root_for_principal`, `harbor_state_root_create`, `harbor_lock_acquire` (Tasks 7 and 8); `harbor_journal_init`, `harbor_journal_recover`, `harbor_journal_set_phase`, `harbor_journal_observe`, `harbor_journal_print_entry` (Tasks 10 to 12); `harbor_log_open`, `harbor_step`, `harbor_die`, `harbor_msg` (Tasks 3 and 4); `resolve_cmd` and fixtures from Task 2.
- Produces:
  - `harbor_journal_cmd ARGS...`: `resolve` dispatches to `harbor_journal_resolve`; anything else dies 3 `usage`.
  - `harbor_journal_resolve SEQ --reverted`: validates arguments (exactly two, four-digit SEQ, literal `--reverted`); picks the principal's state root; as operator creates the state root (`0700`) and opens `harbor.log` (`0600`); as root requires `/var/lib/harbor` to exist (dies 3 `journal.no_state_root` naming `sudo harbor bootstrap`), never creates or re-modes it, and opens `bootstrap.log` (`0600`; the spec fixes no mode for this file, and a root-only log without an execute bit is the conservative choice); logs the command; acquires the lock; initializes the journal; runs lenient recovery excluding SEQ; emits step `recovery-scan`; dies 3 `journal.resolve_missing`, `journal.resolve_not_prepared`, or `journal.resolve_decidable` as applicable; prints the entry beside the observed state; prompts on stderr with `Type the entry number SEQ to mark it reverted without touching TARGET:` followed by one space; reads one line from stdin; dies 3 `journal.resolve_unconfirmed` unless it equals SEQ; emits step `resolve-confirmed`; rewrites the entry `reverted` with `resolved_by: operator` and `resolved_at`; reports remaining undecidable entries. Exits 0 through the EXIT trap, which releases the lock. A malformed named entry ends in exit 2 `journal.malformed` from the recovery validation pre-pass (Task 12) before any prompt.
  - Root branch in the unit lane: the tests below call `harbor_journal_resolve` in the Bats process after overriding `harbor_state_root_for_principal` to point at a directory under `BATS_TEST_TMPDIR` with kind `root`. Nothing under `/var/lib` is read or written; the real path is exercised by PR 3's integration lane.

- [ ] **Step 1: Write the failing tests**

`tests/unit/bin/resolve.bats`:

```bash
#!/usr/bin/env bats
load '../test_helper'

setup() {
  harbor_load_libs
  fixture_state_root
}

root_fixture() {
  # root_fixture: make the libraries in this test process believe the principal
  # is root with a state root under BATS_TEST_TMPDIR (ROOT_FIX). The override
  # lives in this process only; nothing under /var/lib is touched.
  ROOT_FIX="${BATS_TEST_TMPDIR}/var-lib-harbor"
  harbor_state_root_for_principal() {
    HARBOR_STATE_ROOT="${ROOT_FIX}"
    HARBOR_LOCK_KIND=root
  }
  HARBOR_PID="$$"
  HARBOR_CMDLINE="harbor journal resolve"
}

root_resolve() {
  # root_resolve TYPED SEQ: harbor_journal_resolve in this process, TYPED on stdin
  harbor_journal_resolve "${2}" --reverted <<<"${1}"
}

@test "journal without resolve, a bad entry number, and a missing --reverted are usage errors" {
  run env HOME="${FIX_HOME}" "${HARBOR}" journal
  assert_equal "${status}" 3
  assert_output --partial 'usage: harbor journal resolve <NNNN> --reverted'
  run env HOME="${FIX_HOME}" "${HARBOR}" journal frobnicate
  assert_equal "${status}" 3
  run env HOME="${FIX_HOME}" "${HARBOR}" journal resolve 1 --reverted
  assert_equal "${status}" 3
  assert_output --partial 'four digits'
  run env HOME="${FIX_HOME}" "${HARBOR}" journal resolve 0001
  assert_equal "${status}" 3
  run env HOME="${FIX_HOME}" "${HARBOR}" journal resolve 0001 --applied
  assert_equal "${status}" 3
  assert [ ! -e "${FIX_ROOT}/lock.d" ]
}

@test "the operator state root, journal, and log are created with their modes when absent" {
  rm -r "${FIX_ROOT}"
  run resolve_cmd 0001 0001
  assert_equal "${status}" 3
  assert_output --partial 'journal.resolve_missing'
  run ls -ld "${FIX_ROOT}" "${FIX_ROOT}/journal"
  assert_line --index 0 --regexp '^drwx------'
  assert_line --index 1 --regexp '^drwx------'
  run ls -l "${FIX_ROOT}/harbor.log"
  assert_output --regexp '^-rw-------'
  assert [ ! -e "${FIX_ROOT}/lock.d" ]
  assert [ ! -e "${FIX_ROOT}/reclaim.d" ]
  run cat "${FIX_ROOT}/harbor.log"
  assert_output --partial 'command journal resolve 0001 --reverted'
  assert_output --partial 'step recovery-scan'
  assert_output --regexp 'error journal.resolve_missing exit=3'
  assert_output --regexp ' exit 3$'
}

@test "resolving an undecidable entry marks it reverted with resolved_by operator and never touches the artifact" {
  fixture_undecidable_file_entry "${FIX_ROOT}" 0001
  run --separate-stderr resolve_cmd 0001 0001
  assert_success
  assert_equal "${output}" ""
  assert_regex "${stderr}" 'journal entry 0001-file.json is undecidable:'
  assert_regex "${stderr}" "Type the entry number 0001 to mark it reverted without touching ${FIX_ARTIFACT_0001}: "
  assert_regex "${stderr}" 'entry 0001 marked reverted \(resolved_by: operator\)'
  refute_regex "${stderr}" 'failed at step'
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" reverted
  assert_equal "$(entry_raw "${FIX_ROOT}" 0001 resolved_by)" '"operator"'
  assert_regex "$(entry_raw "${FIX_ROOT}" 0001 resolved_at)" '^"[0-9]{8}T[0-9]{6}Z"$'
  assert_equal "$(cat "${FIX_ARTIFACT_0001}")" two
  assert [ ! -e "${FIX_ROOT}/lock.d" ]
  assert [ ! -e "${FIX_ROOT}/reclaim.d" ]
  run ls -A "${FIX_ROOT}/journal"
  assert_output 0001-file.json
  run cat "${FIX_ROOT}/harbor.log"
  assert_output --partial 'step resolve-confirmed'
  assert_output --partial '0001-file.json reverted resolved_by=operator'
  assert_output --regexp ' exit 0$'
}

@test "resolve refuses without the exact entry number typed back and writes nothing" {
  fixture_undecidable_file_entry "${FIX_ROOT}" 0001
  run resolve_cmd 0002 0001
  assert_equal "${status}" 3
  assert_output --partial 'journal.resolve_unconfirmed'
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" prepared
  run resolve_cmd '' 0001
  assert_equal "${status}" 3
  assert_output --partial 'journal.resolve_unconfirmed'
  run env HOME="${FIX_HOME}" HARBOR_DEV=1 "${HARBOR}" journal resolve 0001 --reverted </dev/null
  assert_equal "${status}" 3
  assert_output --partial 'journal.resolve_unconfirmed'
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" prepared
  assert_equal "$(entry_raw "${FIX_ROOT}" 0001 resolved_by)" ""
  assert [ ! -e "${FIX_ROOT}/lock.d" ]
  run cat "${FIX_ROOT}/harbor.log"
  refute_output --partial 'step resolve-confirmed'
}

@test "resolve acts only on a prepared, undecidable entry" {
  fixture_entry "${FIX_ROOT}" 0001 file "${BATS_TEST_TMPDIR}/absent" created prepared '"absent"' '{"sha256":"ab","mode":"0644","owner":"root"}'
  run resolve_cmd 0001 0001
  assert_equal "${status}" 3
  assert_output --partial 'journal.resolve_decidable'
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" prepared
  fixture_entry "${FIX_ROOT}" 0002 file /x created applied '"absent"' '"absent"'
  run resolve_cmd 0002 0002
  assert_equal "${status}" 3
  assert_output --partial 'journal.resolve_not_prepared'
  assert_output --partial 'is applied'
  run resolve_cmd 0009 0009
  assert_equal "${status}" 3
  assert_output --partial 'journal.resolve_missing'
  assert [ ! -e "${FIX_ROOT}/lock.d" ]
}

@test "three entries: the decidable one is recovered, the other undecidable one is reported and kept, only the named one is resolved, and ordinary recovery still exits 2 naming it" {
  fixture_undecidable_file_entry "${FIX_ROOT}" 0001
  fixture_entry "${FIX_ROOT}" 0002 file "${BATS_TEST_TMPDIR}/absent" created prepared '"absent"' '{"sha256":"ab","mode":"0644","owner":"root"}'
  fixture_undecidable_file_entry "${FIX_ROOT}" 0003
  run --separate-stderr resolve_cmd 0001 0001
  assert_success
  assert_regex "${stderr}" 'journal entry 0003-file.json is undecidable:'
  assert_regex "${stderr}" 'journal entry 0001-file.json is undecidable:'
  assert_regex "${stderr}" 'still undecidable and blocking ordinary commands: 0003'
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" reverted
  assert_equal "$(entry_raw "${FIX_ROOT}" 0001 resolved_by)" '"operator"'
  assert_equal "$(entry_phase "${FIX_ROOT}" 0002)" reverted
  assert_equal "$(entry_raw "${FIX_ROOT}" 0002 resolved_by)" ""
  assert_equal "$(entry_phase "${FIX_ROOT}" 0003)" prepared
  assert_equal "$(cat "${FIX_ARTIFACT_0001}")" two
  assert_equal "$(cat "${FIX_ARTIFACT_0003}")" two

  HARBOR_PID="$$"
  harbor_lock_acquire "${FIX_ROOT}" operator
  run --separate-stderr harbor_journal_recover "${FIX_ROOT}"
  assert_equal "${status}" 2
  assert_regex "${stderr}" 'journal.undecidable: prepared entries 0003 cannot be decided'
  harbor_lock_release "${FIX_ROOT}"

  run resolve_cmd 0003 0003
  assert_success
  assert_equal "$(entry_phase "${FIX_ROOT}" 0003)" reverted
  harbor_lock_acquire "${FIX_ROOT}" operator
  harbor_journal_recover "${FIX_ROOT}"
  assert_equal "${HARBOR_JOURNAL_UNDECIDABLE}" ""
  harbor_lock_release "${FIX_ROOT}"
}

@test "a malformed named entry is refused with exit 2 journal.malformed, left unchanged, and no lock is left behind" {
  fixture_undecidable_file_entry "${FIX_ROOT}" 0001
  grep -v '"target"' "${FIX_ROOT}/journal/0001-file.json" >"${BATS_TEST_TMPDIR}/stripped"
  cat "${BATS_TEST_TMPDIR}/stripped" >"${FIX_ROOT}/journal/0001-file.json"
  before="$(cat "${FIX_ROOT}/journal/0001-file.json")"
  run resolve_cmd 0001 0001
  assert_equal "${status}" 2
  assert_output --partial 'journal.malformed'
  assert_output --partial '0001-file.json'
  refute_output --partial 'Type the entry number'
  assert_equal "$(cat "${FIX_ROOT}/journal/0001-file.json")" "${before}"
  assert_equal "$(cat "${FIX_ARTIFACT_0001}")" two
  assert [ ! -e "${FIX_ROOT}/lock.d" ]
  run ls -A "${FIX_ROOT}/journal"
  assert_output 0001-file.json
}

@test "root branch: an absent state root is refused with exit 3 naming sudo harbor bootstrap, and nothing is created" {
  root_fixture
  run root_resolve 0001 0001
  assert_equal "${status}" 3
  assert_output --partial 'journal.no_state_root'
  assert_output --partial 'sudo harbor bootstrap'
  assert [ ! -e "${ROOT_FIX}" ]
  assert [ ! -e "${FIX_ROOT}/lock.d" ]
}

@test "root branch: an existing state root keeps its mode; journal 0700, bootstrap.log 0600, lock.d 0755 with a 0644 holder, no harbor.log" {
  root_fixture
  mkdir "${ROOT_FIX}"
  chmod 0750 "${ROOT_FIX}"
  run root_resolve 0001 0001
  assert_equal "${status}" 3
  assert_output --partial 'journal.resolve_missing'
  run ls -ld "${ROOT_FIX}" "${ROOT_FIX}/journal"
  assert_line --index 0 --regexp '^drwxr-x---'
  assert_line --index 1 --regexp '^drwx------'
  run ls -l "${ROOT_FIX}/bootstrap.log"
  assert_output --regexp '^-rw-------'
  assert [ ! -e "${ROOT_FIX}/harbor.log" ]
  run cat "${ROOT_FIX}/bootstrap.log"
  assert_output --partial 'command journal resolve 0001 --reverted'
  assert_output --partial 'step recovery-scan'
  assert_output --regexp 'error journal.resolve_missing exit=3'
  # harbor_die ended the run capture, not this process, and no Harbor EXIT trap
  # is installed here, so the lock the capture took is still on disk with the
  # root modes and this process's pid; the body releases it.
  run ls -ld "${ROOT_FIX}/lock.d"
  assert_output --regexp '^drwxr-xr-x'
  run ls -l "${ROOT_FIX}/lock.d/holder"
  assert_output --regexp '^-rw-r--r--'
  assert_equal "$(holder_pid "${ROOT_FIX}")" "$$"
  assert [ ! -e "${ROOT_FIX}/reclaim.d" ]
  harbor_lock_release "${ROOT_FIX}"
  assert [ ! -e "${ROOT_FIX}/lock.d" ]
}

@test "root branch: an undecidable entry under an existing state root is resolved by the typed number and the artifact is untouched" {
  root_fixture
  mkdir "${ROOT_FIX}"
  fixture_undecidable_file_entry "${ROOT_FIX}" 0001
  run --separate-stderr root_resolve 0001 0001
  assert_success
  assert_equal "${output}" ""
  assert_regex "${stderr}" 'journal entry 0001-file.json is undecidable:'
  assert_regex "${stderr}" 'entry 0001 marked reverted \(resolved_by: operator\)'
  assert_equal "$(entry_phase "${ROOT_FIX}" 0001)" reverted
  assert_equal "$(entry_raw "${ROOT_FIX}" 0001 resolved_by)" '"operator"'
  assert_equal "$(cat "${FIX_ARTIFACT_0001}")" two
  run cat "${ROOT_FIX}/bootstrap.log"
  assert_output --partial 'step resolve-confirmed'
  assert_output --partial '0001-file.json reverted resolved_by=operator'
  assert [ ! -e "${ROOT_FIX}/harbor.log" ]
  harbor_lock_release "${ROOT_FIX}"
  assert [ ! -e "${ROOT_FIX}/lock.d" ]
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `tests/run_unit.sh tests/unit/bin/resolve.bats`
Expected: FAIL. The public-command tests exit 127 (`harbor_journal_cmd: command not found`) through the dispatcher's `journal` arm; the three root-branch tests fail with `harbor_journal_resolve: command not found`.

- [ ] **Step 3: Append to `lib/journal.sh`**

```bash
harbor_journal_cmd() {
  case "${1:-}" in
    resolve)
      shift
      harbor_journal_resolve ${1+"$@"}
      ;;
    *) harbor_die 3 usage "usage: harbor journal resolve <NNNN> --reverted" ;;
  esac
}
harbor_journal_resolve() {
  local seq entry f phase op target pre post observed typed
  [ "$#" -eq 2 ] || harbor_die 3 usage "usage: harbor journal resolve <NNNN> --reverted"
  seq="${1}"
  [ "${2}" = "--reverted" ] || harbor_die 3 usage "usage: harbor journal resolve <NNNN> --reverted"
  case "${seq}" in
    [0-9][0-9][0-9][0-9]) ;;
    *) harbor_die 3 usage "entry number must be four digits, got '${seq}'" ;;
  esac
  harbor_state_root_for_principal
  if [ "${HARBOR_LOCK_KIND}" = "operator" ]; then
    harbor_state_root_create "${HARBOR_STATE_ROOT}" operator
    harbor_log_open "${HARBOR_STATE_ROOT}/harbor.log" 0600
  else
    [ -d "${HARBOR_STATE_ROOT}" ] || harbor_die 3 journal.no_state_root "${HARBOR_STATE_ROOT} does not exist; nothing to resolve (sudo harbor bootstrap creates it)"
    harbor_log_open "${HARBOR_STATE_ROOT}/bootstrap.log" 0600
  fi
  harbor_log command "journal resolve ${seq} --reverted"
  harbor_lock_acquire "${HARBOR_STATE_ROOT}" "${HARBOR_LOCK_KIND}"
  harbor_journal_init "${HARBOR_STATE_ROOT}"
  harbor_journal_recover "${HARBOR_STATE_ROOT}" "${seq}"
  harbor_step recovery-scan
  entry=""
  for f in "${HARBOR_STATE_ROOT}/journal/${seq}"-*.json; do
    if [ -e "${f}" ]; then
      entry="${f}"
      break
    fi
  done
  [ -n "${entry}" ] || harbor_die 3 journal.resolve_missing "no journal entry ${seq} in ${HARBOR_STATE_ROOT}/journal"
  phase="$(harbor_journal_string "${entry}" phase)"
  [ "${phase}" = "prepared" ] || harbor_die 3 journal.resolve_not_prepared "entry ${seq} is ${phase}, not prepared; nothing to resolve"
  op="$(harbor_journal_string "${entry}" op)"
  target="$(harbor_journal_string "${entry}" target)"
  pre="$(harbor_journal_raw "${entry}" pre_state)"
  post="$(harbor_journal_raw "${entry}" post_state)"
  observed="$(harbor_journal_observe "${op}" "${target}")"
  if [ "${observed}" = "${pre}" ] || [ "${observed}" = "${post}" ]; then
    harbor_die 3 journal.resolve_decidable "entry ${seq} is decidable (observed state equals a recorded state); rerun the ordinary command and recovery will mark it"
  fi
  harbor_journal_print_entry "${entry}" "${observed}"
  printf 'Type the entry number %s to mark it reverted without touching %s: ' "${seq}" "${target}" >&2
  IFS= read -r typed || typed=""
  [ "${typed}" = "${seq}" ] || harbor_die 3 journal.resolve_unconfirmed "entry number not confirmed; nothing written"
  harbor_step resolve-confirmed
  harbor_journal_set_phase "${entry}" reverted operator
  harbor_msg "entry ${seq} marked reverted (resolved_by: operator); ${target} was not touched"
  if [ -n "${HARBOR_JOURNAL_UNDECIDABLE}" ]; then
    harbor_msg "still undecidable and blocking ordinary commands: ${HARBOR_JOURNAL_UNDECIDABLE}"
  fi
}
```

The root branch never calls `harbor_state_root_create`: an existing `/var/lib/harbor` keeps whatever mode bootstrap gave it, and an absent one is a refusal. The `phase` value in the `journal.resolve_not_prepared` message is always one of the three phases, because recovery validated every entry before this point. The real `/var/lib/harbor` path is exercised by PR 3's integration lane, which first creates the root state root through bootstrap; the unit lane covers the same branch through the override in `root_fixture`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `tests/run_unit.sh tests/unit/bin/resolve.bats tests/unit/bin/dispatch.bats`
Expected: `1..17`, all `ok`, exit 0 (ten resolve tests, seven dispatch tests).

- [ ] **Step 5: Hand off for review (no commit)**

Stop here and report as described under "Working conventions": the test commands run in this task with their results, `git status --short`, and `git diff --stat`. Do not run `git commit`. After the Fable pre-commit review and the orchestrator's own review, the orchestrator stages and commits:

- Files: `lib/journal.sh`, `tests/unit/bin/resolve.bats`
- Message: `feat(journal): harbor journal resolve with typed confirmation and lenient recovery`

---

### Task 15: Lock contention through the public command

Every case in this task is the spec section 7 "Serialized commands" row exercised through `harbor journal resolve` against a fixture journal holding one undecidable `prepared` entry, observed only through filesystem state and the two hooks.

**Files:**

- Test: `tests/unit/bin/contention.bats`

**Interfaces:**

- Consumes: `resolve_cmd`, `pause_sentinel`, `holder_pid`, `resume_holder`, `wait_for_log_step`, `wait_for_one_exit`, `holder_record`, `fixture_undecidable_file_entry`, `entry_phase` (Task 2); the hooks (Task 4); lock and journal libraries.
- Produces: nothing new.

- [ ] **Step 1: Write the tests**

`tests/unit/bin/contention.bats`:

```bash
#!/usr/bin/env bats
load '../test_helper'

setup() {
  harbor_load_libs
  fixture_state_root
  fixture_undecidable_file_entry "${FIX_ROOT}" 0001
  PAUSED_PIDS=""
  KEEP_PID=""
}

teardown() {
  # Resume and reap every paused command so a failed assertion leaks nothing.
  local p s
  for p in ${PAUSED_PIDS}; do
    for s in lock-acquired resolve-confirmed; do
      touch "$(pause_sentinel "${p}" "${s}")"
    done
    wait "${p}" 2>/dev/null || true
    for s in lock-acquired resolve-confirmed; do
      rm -f "$(pause_sentinel "${p}" "${s}")"
    done
  done
  if [ -n "${KEEP_PID}" ]; then
    kill "${KEEP_PID}" 2>/dev/null || true
  fi
}

paused_resolve() {
  # paused_resolve STEP OUTFILE: a background resolve of 0001 paused at STEP until
  # its sentinel appears. env execs bin/harbor, so PAUSED_PID is the harbor
  # process itself: the pid in its holder record and in its sentinel name.
  env HOME="${FIX_HOME}" HARBOR_DEV=1 HARBOR_TEST_HOOKS=1 HARBOR_PAUSE_AFTER="${1}" \
    "${HARBOR}" journal resolve 0001 --reverted <<<"0001" >"${2}" 2>&1 3>&- &
  PAUSED_PID=$!
  PAUSED_PIDS="${PAUSED_PIDS} ${PAUSED_PID}"
}

gone_pid() {
  sleep 0.01 3>&- &
  local p=$!
  wait "${p}"
  printf '%s' "${p}"
}

stale_count() {
  find "${FIX_ROOT}" -maxdepth 1 -name 'lock.*.stale' | wc -l | tr -d ' '
}

@test "held lock: resolve against a paused command exits 3 with lock.busy and writes nothing" {
  paused_resolve lock-acquired "${BATS_TEST_TMPDIR}/a.out"
  pa="${PAUSED_PID}"
  wait_for_log_step "${FIX_ROOT}" lock-acquired
  before="$(cat "${FIX_ROOT}/lock.d/holder")"
  assert_equal "$(holder_pid "${FIX_ROOT}")" "${pa}"
  run resolve_cmd 0001 0001
  assert_equal "${status}" 3
  assert_output --partial 'lock.busy'
  assert_output --partial "pid ${pa}"
  assert_equal "$(cat "${FIX_ROOT}/lock.d/holder")" "${before}"
  assert [ ! -e "${FIX_ROOT}/reclaim.d" ]
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" prepared
  resume_holder "${FIX_ROOT}" lock-acquired
  wait "${pa}"
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" reverted
  assert [ ! -e "${FIX_ROOT}/lock.d" ]
}

@test "nested command: a resolve launched while this process holds the lock exits 3 with lock.busy and leaves the parent's lock and the entry alone" {
  HARBOR_PID="$$"
  harbor_lock_acquire "${FIX_ROOT}" operator
  before="$(cat "${FIX_ROOT}/lock.d/holder")"
  run resolve_cmd 0001 0001
  assert_equal "${status}" 3
  assert_output --partial 'lock.busy'
  assert_output --partial "pid $$"
  assert_equal "$(cat "${FIX_ROOT}/lock.d/holder")" "${before}"
  assert [ ! -e "${FIX_ROOT}/reclaim.d" ]
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" prepared
  harbor_lock_release "${FIX_ROOT}"
  assert [ ! -e "${FIX_ROOT}/lock.d" ]
}

@test "double contender on an absent lock: exactly one holder, one exit 3, no reclaim.d left" {
  paused_resolve lock-acquired "${BATS_TEST_TMPDIR}/a.out"
  pa="${PAUSED_PID}"
  paused_resolve lock-acquired "${BATS_TEST_TMPDIR}/b.out"
  pb="${PAUSED_PID}"
  wait_for_one_exit "${pa}" "${pb}"
  assert [ -f "${FIX_ROOT}/lock.d/holder" ]
  assert [ ! -d "${FIX_ROOT}/reclaim.d" ]
  case "$(holder_pid "${FIX_ROOT}")" in
    "${pa}" | "${pb}") ;;
    *) fail "the holder names neither contender" ;;
  esac
  resume_holder "${FIX_ROOT}" lock-acquired
  sa=0
  wait "${pa}" || sa=$?
  sb=0
  wait "${pb}" || sb=$?
  assert_equal "$(( (sa == 0) + (sb == 0) ))" 1
  assert_equal "$(( (sa == 3) + (sb == 3) ))" 1
  assert [ ! -d "${FIX_ROOT}/lock.d" ]
  assert [ ! -d "${FIX_ROOT}/reclaim.d" ]
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" reverted
  assert_equal "$(stale_count)" 0
  run cat "${BATS_TEST_TMPDIR}/a.out" "${BATS_TEST_TMPDIR}/b.out"
  assert_output --partial 'lock.'
  refute_output --partial 'failed at step'
}

@test "double contender on a stale lock: exactly one holder, one exit 3, one archived lock.*.stale, no reclaim.d left" {
  mkdir "${FIX_ROOT}/lock.d"
  holder_record "$(gone_pid)" "whatever" "harbor crashed" >"${FIX_ROOT}/lock.d/holder"
  paused_resolve lock-acquired "${BATS_TEST_TMPDIR}/a.out"
  pa="${PAUSED_PID}"
  paused_resolve lock-acquired "${BATS_TEST_TMPDIR}/b.out"
  pb="${PAUSED_PID}"
  wait_for_one_exit "${pa}" "${pb}"
  assert [ -f "${FIX_ROOT}/lock.d/holder" ]
  assert [ ! -d "${FIX_ROOT}/reclaim.d" ]
  resume_holder "${FIX_ROOT}" lock-acquired
  sa=0
  wait "${pa}" || sa=$?
  sb=0
  wait "${pb}" || sb=$?
  assert_equal "$(( (sa == 0) + (sb == 0) ))" 1
  assert_equal "$(( (sa == 3) + (sb == 3) ))" 1
  assert [ ! -d "${FIX_ROOT}/lock.d" ]
  assert [ ! -d "${FIX_ROOT}/reclaim.d" ]
  assert_equal "$(stale_count)" 1
  assert_equal "$(sed -n 's/^cmdline=//p' "${FIX_ROOT}"/lock.*.stale/holder)" 'harbor crashed'
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" reverted
  run cat "${BATS_TEST_TMPDIR}/a.out" "${BATS_TEST_TMPDIR}/b.out"
  refute_output --partial 'failed at step'
}

@test "interrupted acquisition after the gate: reclaim.d stays, the next command refuses and touches nothing, manual removal lets it acquire" {
  run resolve_cmd 0001 0001 HARBOR_TEST_HOOKS=1 HARBOR_FAIL_AFTER=lock-gate
  assert_equal "${status}" 137
  assert [ -f "${FIX_ROOT}/reclaim.d/holder" ]
  assert [ ! -e "${FIX_ROOT}/lock.d" ]
  gate_before="$(cat "${FIX_ROOT}/reclaim.d/holder")"
  run resolve_cmd 0001 0001
  assert_equal "${status}" 3
  assert_output --partial 'lock.gate_busy'
  assert_output --partial "ls -la ${FIX_ROOT}/reclaim.d ${FIX_ROOT}/lock.d"
  assert_equal "$(cat "${FIX_ROOT}/reclaim.d/holder")" "${gate_before}"
  assert [ ! -e "${FIX_ROOT}/lock.d" ]
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" prepared
  rm -r "${FIX_ROOT}/reclaim.d"
  run resolve_cmd 0001 0001
  assert_success
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" reverted
  assert [ ! -e "${FIX_ROOT}/lock.d" ]
  assert [ ! -e "${FIX_ROOT}/reclaim.d" ]
}

@test "interrupted acquisition after mkdir lock.d: reclaim.d and an unpopulated lock.d stay, the next command refuses, removing both lets it acquire" {
  run resolve_cmd 0001 0001 HARBOR_TEST_HOOKS=1 HARBOR_FAIL_AFTER=lock-mkdir
  assert_equal "${status}" 137
  assert [ -f "${FIX_ROOT}/reclaim.d/holder" ]
  assert [ -d "${FIX_ROOT}/lock.d" ]
  assert [ ! -e "${FIX_ROOT}/lock.d/holder" ]
  run resolve_cmd 0001 0001
  assert_equal "${status}" 3
  assert_output --partial 'lock.gate_busy'
  assert [ -f "${FIX_ROOT}/reclaim.d/holder" ]
  assert [ ! -e "${FIX_ROOT}/lock.d/holder" ]
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" prepared
  rm -r "${FIX_ROOT}/reclaim.d"
  run resolve_cmd 0001 0001
  assert_equal "${status}" 3
  assert_output --partial 'lock.unreadable'
  assert [ -d "${FIX_ROOT}/lock.d" ]
  assert [ ! -e "${FIX_ROOT}/reclaim.d" ]
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" prepared
  rmdir "${FIX_ROOT}/lock.d"
  run resolve_cmd 0001 0001
  assert_success
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" reverted
  assert [ ! -e "${FIX_ROOT}/lock.d" ]
  assert_equal "$(stale_count)" 0
}

@test "ownership re-check: a holder paused before the journal write whose holder record is forged exits 2 and writes nothing" {
  sleep 30 3>&- &
  KEEP_PID=$!
  paused_resolve resolve-confirmed "${BATS_TEST_TMPDIR}/a.out"
  pa="${PAUSED_PID}"
  wait_for_log_step "${FIX_ROOT}" resolve-confirmed
  holder_record "${KEEP_PID}" "$(harbor_lock_start_time "${KEEP_PID}")" "harbor other" >"${FIX_ROOT}/lock.d/holder"
  # The holder record is forged now, so resume by the paused pid, not the holder.
  touch "$(pause_sentinel "${pa}" resolve-confirmed)"
  sa=0
  wait "${pa}" || sa=$?
  assert_equal "${sa}" 2
  run cat "${BATS_TEST_TMPDIR}/a.out"
  assert_output --partial 'lock.lost'
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" prepared
  assert_equal "$(entry_raw "${FIX_ROOT}" 0001 resolved_by)" ""
  assert_equal "$(sed -n 's/^cmdline=//p' "${FIX_ROOT}/lock.d/holder")" 'harbor other'
  run ls -A "${FIX_ROOT}/journal"
  assert_output 0001-file.json
}
```

- [ ] **Step 2: Run the tests to verify they pass**

These are acceptance tests through the public command, the spec's "Serialized commands" row. Every guarantee they check was driven red at the library level first; no code is edited, sabotaged, or checked out to make them fail. The traceability is:

| Contention test | Red test that first failed for the same guarantee |
|---|---|
| held lock | Task 8 "a live holder exits 3 with lock.busy naming it ..." |
| nested command | Task 8 "a live holder exits 3 with lock.busy naming it ..." (the parent is the live holder) |
| double contender, absent lock | Task 8 "double contender on an absent lock (library level) ..." |
| double contender, stale lock | Task 8 "double contender on a stale lock (library level) ..." and "repeated stale reclaims ..." |
| interrupted after the gate | Task 8 "interrupted acquisition after lock-gate (library level) ..." |
| interrupted after mkdir lock.d | Task 8 "interrupted acquisition after lock-mkdir (library level) ..." |
| ownership re-check | Task 9 "ownership re-check ..." and Task 11 "a holder whose lock was reclaimed exits 2 ..." |

Run: `tests/run_unit.sh tests/unit/bin/contention.bats`
Expected: `1..7`, all `ok`, exit 0. Total wall time is under fifteen seconds; each paused process resumes as soon as the test creates its sentinel.

Run it three times in a row on macOS and Ubuntu to check for flakiness:

Run: `for i in 1 2 3; do tests/run_unit.sh tests/unit/bin/contention.bats || break; done`
Expected: three passing runs.

- [ ] **Step 3: Hand off for review (no commit)**

Stop here and report as described under "Working conventions": the test commands run in this task with their results, `git status --short`, and `git diff --stat`. Do not run `git commit`. After the Fable pre-commit review and the orchestrator's own review, the orchestrator stages and commits:

- Files: `tests/unit/bin/contention.bats`
- Message: `test: lock contention cases through harbor journal resolve`

---

### Task 16: Vendor shim skeleton and fixtures

**Files:**

- Create: `tests/shims/bin/harbor-shim`
- Create: `tests/shims/bin/fakevendor` (symlink to `harbor-shim`)
- Create: `tests/fixtures/shims/fakevendor/healthy/version.out`
- Create: `tests/fixtures/shims/fakevendor/failing/version.out`
- Create: `tests/fixtures/shims/fakevendor/failing/version.exit`
- Test: `tests/unit/lib/shim.bats`

**Interfaces:**

- Consumes: nothing from the libraries.
- Produces: the shim contract every later PR's vendor shim follows. A shim is a symlink named after the binary (`tailscale`, `t3`, `node`, `sudo`, ...) pointing at `harbor-shim`. When invoked it appends `<name><TAB><arg>...` to `${HARBOR_SHIM_LOG}` if set, then prints `${HARBOR_SHIM_FIXTURES:-tests/fixtures/shims}/<name>/${HARBOR_SHIM_SCENARIO:-healthy}/<key>.out` and exits with the content of `<key>.exit` (default 0), where `<key>` is the argv joined by `_` with `/` replaced by `%`, or `_noargs`. A missing fixture exits 97.

- [ ] **Step 1: Write the failing tests**

`tests/unit/lib/shim.bats`:

```bash
#!/usr/bin/env bats
load '../test_helper'

setup() {
  SHIM_BIN="${HARBOR_ROOT}/tests/shims/bin"
  LOG="${BATS_TEST_TMPDIR}/shim.log"
}

@test "a shim takes its name from the symlink and replies from the healthy scenario by default" {
  assert [ -L "${SHIM_BIN}/fakevendor" ]
  assert_equal "$(readlink "${SHIM_BIN}/fakevendor")" harbor-shim
  run env PATH="${SHIM_BIN}:${PATH}" HARBOR_SHIM_LOG="${LOG}" fakevendor version
  assert_success
  assert_output 'fakevendor 1.2.3'
}

@test "the failing scenario replies with its exit file" {
  run env HARBOR_SHIM_SCENARIO=failing "${SHIM_BIN}/fakevendor" version
  assert_equal "${status}" 2
  assert_output 'fakevendor: boom'
}

@test "every invocation appends its argv tab-separated to the shim log" {
  tab="$(printf '\t')"
  env HARBOR_SHIM_LOG="${LOG}" "${SHIM_BIN}/fakevendor" version
  env HARBOR_SHIM_LOG="${LOG}" HARBOR_SHIM_SCENARIO=failing "${SHIM_BIN}/fakevendor" version || true
  run cat "${LOG}"
  assert_line --index 0 "fakevendor${tab}version"
  assert_line --index 1 "fakevendor${tab}version"
  assert_equal "${#lines[@]}" 2
}

@test "a missing fixture is a test error with exit 97 and is still logged" {
  run env HARBOR_SHIM_LOG="${LOG}" "${SHIM_BIN}/fakevendor" serve --https=443 /path
  assert_equal "${status}" 97
  assert_output --partial 'no fixture'
  assert_output --partial 'fakevendor/healthy/serve_--https=443_%path.out'
  run "${SHIM_BIN}/fakevendor"
  assert_equal "${status}" 97
  assert_output --partial '/_noargs.out'
  assert_equal "$(cat "${LOG}")" "$(printf 'fakevendor\tserve\t--https=443\t/path')"
}

@test "HARBOR_SHIM_FIXTURES redirects fixture lookup" {
  mkdir -p "${BATS_TEST_TMPDIR}/fx/fakevendor/healthy"
  printf 'elsewhere\n' >"${BATS_TEST_TMPDIR}/fx/fakevendor/healthy/version.out"
  run env HARBOR_SHIM_FIXTURES="${BATS_TEST_TMPDIR}/fx" "${SHIM_BIN}/fakevendor" version
  assert_success
  assert_output elsewhere
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `tests/run_unit.sh tests/unit/lib/shim.bats`
Expected: FAIL. Every test fails because `tests/shims/bin/fakevendor` does not exist.

- [ ] **Step 3: Write the shim and fixtures**

`tests/shims/bin/harbor-shim`:

```bash
#!/bin/bash
# Generic vendor shim (design section 7). Vendor shims are symlinks to this file and
# take their name from the symlink. The shim appends "<name>\t<arg>..." to
# ${HARBOR_SHIM_LOG} when set, then replies from
# ${HARBOR_SHIM_FIXTURES}/<name>/<scenario>/<key>.out with the exit code in <key>.exit
# (default 0), where <key> is the argv joined by "_" with "/" replaced by "%" and
# "_noargs" for no arguments, and <scenario> is ${HARBOR_SHIM_SCENARIO:-healthy}.
# A missing fixture is a test error: exit 97.
set -euo pipefail
shim_name="$(basename "${0}")"
shim_self="${0}"
while [ -L "${shim_self}" ]; do
  shim_link="$(readlink "${shim_self}")"
  case "${shim_link}" in
    /*) shim_self="${shim_link}" ;;
    *) shim_self="$(dirname "${shim_self}")/${shim_link}" ;;
  esac
done
shim_dir="$(cd "$(dirname "${shim_self}")" && pwd -P)"
fixtures="${HARBOR_SHIM_FIXTURES:-${shim_dir}/../../fixtures/shims}"
scenario="${HARBOR_SHIM_SCENARIO:-healthy}"
if [ -n "${HARBOR_SHIM_LOG:-}" ]; then
  {
    printf '%s' "${shim_name}"
    for shim_arg in ${1+"$@"}; do
      printf '\t%s' "${shim_arg}"
    done
    printf '\n'
  } >>"${HARBOR_SHIM_LOG}"
fi
key="$(printf '%s' ${1+"$*"} | tr ' /' '_%')"
[ -n "${key}" ] || key="_noargs"
reply="${fixtures}/${shim_name}/${scenario}/${key}"
if [ ! -f "${reply}.out" ]; then
  printf 'harbor-shim: no fixture %s.out\n' "${reply}" >&2
  exit 97
fi
cat "${reply}.out"
if [ -f "${reply}.exit" ]; then
  exit "$(cat "${reply}.exit")"
fi
exit 0
```

Fixtures and the symlink:

```bash
chmod +x tests/shims/bin/harbor-shim
ln -s harbor-shim tests/shims/bin/fakevendor
mkdir -p tests/fixtures/shims/fakevendor/healthy tests/fixtures/shims/fakevendor/failing
printf 'fakevendor 1.2.3\n' >tests/fixtures/shims/fakevendor/healthy/version.out
printf 'fakevendor: boom\n' >tests/fixtures/shims/fakevendor/failing/version.out
printf '2\n' >tests/fixtures/shims/fakevendor/failing/version.exit
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `tests/run_unit.sh tests/unit/lib/shim.bats`
Expected: `1..5`, all `ok`, exit 0.

- [ ] **Step 5: Hand off for review (no commit)**

Stop here and report as described under "Working conventions": the test commands run in this task with their results, `git status --short`, and `git diff --stat`. Do not run `git commit`. After the Fable pre-commit review and the orchestrator's own review, the orchestrator stages and commits:

- Files: `tests/shims/bin/harbor-shim`, `tests/shims/bin/fakevendor`, `tests/fixtures/shims`, `tests/unit/lib/shim.bats`
- Message: `test: generic vendor shim skeleton with fixture-driven replies`

---

### Task 17: gitleaks configuration and the placeholder scan

**Files:**

- Create: `.gitleaks.toml`
- Create: `tests/lint/placeholder-patterns.txt`
- Create: `tests/lint/placeholder_scan.sh`
- Test: `tests/unit/lib/placeholder_scan.bats`

**Interfaces:**

- Consumes: nothing.
- Produces:
  - `tests/lint/placeholder_scan.sh [REPO_ROOT]`: exits 0 when every tracked regular file outside `tests/fixtures/` (the spec's only exclusion; the patterns file and `.gitleaks.toml` are scanned and pass because their patterns bracket one letter, and the `tests/vendor` submodules are gitlinks, not regular files, so `git ls-files` lists no file under them) is free of work-in-progress markers, carrier-grade NAT IPv4 literals, Tailscale auth-key prefixes, Clerk user-id prefixes, secret-named URL parameters, MagicDNS names other than `TAILNET.ts.net`, and emails outside `example.com`; otherwise prints each offending `file:line:text` and exits 1.
  - `.gitleaks.toml`: consumed by `lint.yml` (Task 18) and by `gitleaks detect` locally.

The marker words are never written literally anywhere in the repository, including this plan and the patterns file; each pattern brackets one letter (`T[O]DO`) so the file cannot match itself, and tests build the words at runtime.

- [ ] **Step 1: Write the failing test**

`tests/unit/lib/placeholder_scan.bats`:

```bash
#!/usr/bin/env bats
load '../test_helper'

setup() {
  SCAN="${HARBOR_ROOT}/tests/lint/placeholder_scan.sh"
  REPO="${BATS_TEST_TMPDIR}/repo"
  mkdir -p "${REPO}/tests/lint" "${REPO}/tests/fixtures" "${REPO}/docs"
  cp "${HARBOR_ROOT}/tests/lint/placeholder-patterns.txt" "${REPO}/tests/lint/"
  git -C "${REPO}" init -q
  git -C "${REPO}" config user.email operator@example.com
  git -C "${REPO}" config user.name OPERATOR
  printf '# clean\n\nnode harbor-node on TAILNET.ts.net at TAILNET_IP for operator@example.com via RELAY_HOSTNAME\n' >"${REPO}/docs/clean.md"
  git -C "${REPO}" add -A
}

scan() {
  run "${SCAN}" "${REPO}"
}

@test "a repository using only the placeholders passes" {
  scan
  assert_success
  assert_output ''
}

@test "work-in-progress markers are reported with file and line" {
  m=TO
  printf 'first\n%sDO: later\n' "${m}" >"${REPO}/docs/wip.md"
  git -C "${REPO}" add -A
  scan
  assert_failure
  assert_output --partial 'docs/wip.md:2:'
  m=FIX
  printf '# %sME later\n' "${m}" >"${REPO}/docs/wip.md"
  git -C "${REPO}" add -A
  scan
  assert_failure
}

@test "identifiers outside the placeholder list are reported" {
  printf 'node.mytailnet.ts.%s\n' net >"${REPO}/docs/dns.md"
  git -C "${REPO}" add -A
  scan
  assert_failure
  assert_output --partial 'MagicDNS name outside the placeholder list'
  rm "${REPO}/docs/dns.md"
  printf 'mail someone@%s\n' corp.example >"${REPO}/docs/mail.md"
  git -C "${REPO}" add -A
  scan
  assert_failure
  assert_output --partial 'email outside example.com'
  rm "${REPO}/docs/mail.md"
  printf 'ip 100.%s.1.2\n' 64 >"${REPO}/docs/ip.md"
  git -C "${REPO}" add -A
  scan
  assert_failure
  assert_output --partial 'docs/ip.md:1:'
  rm "${REPO}/docs/ip.md"
  printf 'key tskey%s-abc123\n' - >"${REPO}/docs/key.md"
  printf 'https://RELAY_HOSTNAME/x?%s=abc\n' token >>"${REPO}/docs/key.md"
  printf 'id user_%s\n' 2NNEqL2nrIRdJ194ndJqAHwEfxC >>"${REPO}/docs/key.md"
  git -C "${REPO}" add -A
  scan
  assert_failure
  assert_output --partial 'docs/key.md:1:'
  assert_output --partial 'docs/key.md:2:'
  assert_output --partial 'docs/key.md:3:'
}

@test "files under tests/fixtures and untracked files are ignored" {
  m=TO
  printf '%sDO in a fixture\n' "${m}" >"${REPO}/tests/fixtures/service-status.txt"
  printf 'node.mytailnet.ts.%s\n' net >>"${REPO}/tests/fixtures/service-status.txt"
  printf '%sDO untracked\n' "${m}" >"${REPO}/docs/untracked.md"
  git -C "${REPO}" add tests/fixtures
  scan
  assert_success
}

@test "the patterns file and .gitleaks.toml are scanned like any other tracked file" {
  m=TO
  printf 'title = "x" # %sDO tighten\n' "${m}" >"${REPO}/.gitleaks.toml"
  git -C "${REPO}" add -A
  scan
  assert_failure
  assert_output --partial '.gitleaks.toml:1:'
  rm "${REPO}/.gitleaks.toml"
  printf '%sDO\n' "${m}" >>"${REPO}/tests/lint/placeholder-patterns.txt"
  git -C "${REPO}" add -A
  scan
  assert_failure
  assert_output --partial 'tests/lint/placeholder-patterns.txt:10:'
}

@test "the real repository passes the scan" {
  run "${SCAN}" "${HARBOR_ROOT}"
  assert_success
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `tests/run_unit.sh tests/unit/lib/placeholder_scan.bats`
Expected: FAIL. `setup` fails copying the missing patterns file.

- [ ] **Step 3: Write the patterns, the scan, and the gitleaks configuration**

`tests/lint/placeholder-patterns.txt` (extended regular expressions, one per line; the bracketed letters keep this file from matching itself):

```text
(^|[^A-Za-z0-9_])T[O]DO([^A-Za-z0-9_]|$)
(^|[^A-Za-z0-9_])F[I]XME([^A-Za-z0-9_]|$)
(^|[^A-Za-z0-9_])X[X]X([^A-Za-z0-9_]|$)
(^|[^A-Za-z0-9_])T[B]D([^A-Za-z0-9_]|$)
(^|[^A-Za-z0-9_])H[A]CK([^A-Za-z0-9_]|$)
(^|[^0-9.])100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3}
tskey[-][A-Za-z0-9-]+
user_[A-Za-z0-9]{20,}
[?&#](token|code|key|secret|wsTicket)=
```

`tests/lint/placeholder_scan.sh`:

```bash
#!/bin/bash
# Placeholder scan (design sections 3.8 and 7): every tracked regular file
# except those under tests/fixtures must hold no work-in-progress marker and no
# identifier outside the placeholder list. Submodule gitlinks are not regular
# files and are skipped by the -f test. Usage:
#   tests/lint/placeholder_scan.sh [REPO_ROOT]
set -euo pipefail
root="${1:-$(cd "$(dirname "${0}")/../.." && pwd -P)}"
cd "${root}"
patterns="tests/lint/placeholder-patterns.txt"
list="$(mktemp)"
trap 'rm -f "${list}"' EXIT
git ls-files >"${list}"
status=0
while IFS= read -r f; do
  case "${f}" in
    tests/fixtures/*) continue ;;
  esac
  [ -f "${f}" ] || continue
  if grep -nIEH -f "${patterns}" -- "${f}"; then
    status=1
  fi
  bad="$(grep -oIE '[A-Za-z0-9-]+\.ts\.net' -- "${f}" | grep -vx 'TAILNET\.ts\.net' || true)"
  if [ -n "${bad}" ]; then
    printf '%s: MagicDNS name outside the placeholder list: %s\n' "${f}" "${bad}"
    status=1
  fi
  bad="$(grep -oIE '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' -- "${f}" | grep -v '@example\.com$' || true)"
  if [ -n "${bad}" ]; then
    printf '%s: email outside example.com: %s\n' "${f}" "${bad}"
    status=1
  fi
done <"${list}"
if [ "${status}" -ne 0 ]; then
  printf 'placeholder scan: failures above\n' >&2
fi
exit "${status}"
```

Run: `chmod +x tests/lint/placeholder_scan.sh`

`.gitleaks.toml`:

```toml
title = "harbor"

[extend]
useDefault = true

[[rules]]
id = "harbor-tailscale-cgnat-ip"
description = "IPv4 literal in the Tailscale carrier-grade NAT range"
regex = '''(^|[^0-9.])100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3}'''

[[rules]]
id = "harbor-magicdns-suffix"
description = "MagicDNS name other than the TAILNET.ts.net placeholder"
regex = '''[A-Za-z0-9-]+\.ts\.net'''
[rules.allowlist]
regexes = ['''^TAILNET\.ts\.net$''']

[[rules]]
id = "harbor-tailscale-auth-key"
description = "Tailscale auth key prefix"
regex = '''tskey[-][A-Za-z0-9-]+'''

[[rules]]
id = "harbor-email"
description = "Email address outside example.com"
regex = '''[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'''
[rules.allowlist]
regexes = ['''@example\.com$''']

[[rules]]
id = "harbor-clerk-user-id"
description = "Clerk user id prefix"
regex = '''user_[A-Za-z0-9]{20,}'''

[[rules]]
id = "harbor-url-secret-param"
description = "URL parameter or fragment named token, code, key, secret, or wsTicket"
regex = '''[?&#](token|code|key|secret|wsTicket)=[^&#[:space:]]+'''

[allowlist]
paths = ['''^\.gitleaks\.toml$''', '''^tests/lint/placeholder-patterns\.txt$''']
```

The `[allowlist] paths` entry is gitleaks-only: gitleaks matches its own rule text (the regex bodies in this file contain the very patterns they describe). The placeholder scan has no such exclusion and still passes on both files, because every pattern brackets one letter or spells the tokens in a way that does not match itself.

- [ ] **Step 4: Run the test to verify it passes, then run gitleaks**

Run: `tests/run_unit.sh tests/unit/lib/placeholder_scan.bats`
Expected: `1..6`, all `ok`, exit 0.

Run: `tests/lint/placeholder_scan.sh; echo "rc=$?"`
Expected: `rc=0` with no other output.

Run (requires gitleaks 8.18.4 or later installed locally; otherwise rely on Task 18's workflow): `gitleaks detect --source . --config .gitleaks.toml --no-banner --redact; echo "rc=$?"`
Expected: `no leaks found`, `rc=0`.

Prove the gitleaks rules fire, without committing anything:

```bash
d="$(mktemp -d)"
printf 'node.mytailnet.ts.%s\n' net >"${d}/leak.txt"
gitleaks detect --no-git --source "${d}" --config .gitleaks.toml --no-banner --redact; echo "rc=$?"
rm -r "${d}"
```

Expected: one finding for rule `harbor-magicdns-suffix`, `rc=1`.

- [ ] **Step 5: Hand off for review (no commit)**

Stop here and report as described under "Working conventions": the test commands run in this task with their results, `git status --short`, and `git diff --stat`. Do not run `git commit`. After the Fable pre-commit review and the orchestrator's own review, the orchestrator stages and commits:

- Files: `.gitleaks.toml`, `tests/lint/placeholder-patterns.txt`, `tests/lint/placeholder_scan.sh`, `tests/unit/lib/placeholder_scan.bats`
- Message: `ci: gitleaks Harbor rules and the placeholder scan`

---

### Task 18: `lint.yml` and `test.yml` workflows

**Files:**

- Create: `.github/workflows/lint.yml`
- Create: `.github/workflows/test.yml`
- Verify: `CONTRIBUTING.md` command blocks match the workflows exactly

**Interfaces:**

- Consumes: every file the previous tasks created; `tests/run_unit.sh` (Task 2); `tests/lint/placeholder_scan.sh` and `.gitleaks.toml` (Task 17); `.markdownlint.yml` (Task 1).
- Produces: the two workflows the PR 2 merge gate runs.

- [ ] **Step 1: Run the static checks locally to see the current state**

The workflow steps are the same commands; run them first so the workflow is a transcription of a known-green run.

Run:

```bash
shellcheck -s bash -x -a -S warning -P 'SCRIPTDIR/..:SCRIPTDIR/../..' --enable=require-variable-braces \
  bin/harbor lib/*.sh tests/run_unit.sh tests/shims/bin/harbor-shim \
  tests/lint/placeholder_scan.sh tests/unit/test_helper.bash; echo "shellcheck rc=$?"
shfmt -i 2 -ci -bn -d bin/harbor lib tests/run_unit.sh tests/shims/bin/harbor-shim \
  tests/lint/placeholder_scan.sh tests/unit/test_helper.bash; echo "shfmt rc=$?"
tests/lint/placeholder_scan.sh; echo "scan rc=$?"
npx --yes markdownlint-cli@0.41.0 --config .markdownlint.yml '**/*.md' --ignore tests/vendor; echo "markdownlint rc=$?"
```

Expected: every `rc=0` and no diff from shfmt. If ShellCheck reports anything, fix the reported line in place (the libraries were written to pass `-S warning` with `require-variable-braces`; the known-quiet spots are the `# shellcheck disable=SC2034` file headers for cross-library globals and the `# shellcheck source=` directives). If shfmt prints a diff, apply it with `shfmt -i 2 -ci -bn -w <file>` and re-run the unit tests.

- [ ] **Step 2: Write `.github/workflows/lint.yml`**

```yaml
name: lint

on:
  push:
    branches: [main]
  pull_request:

jobs:
  lint:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
          submodules: true
      - name: Install ShellCheck
        run: sudo apt-get update && sudo apt-get install -y shellcheck
      - name: Install shfmt
        run: |
          go install mvdan.cc/sh/v3/cmd/shfmt@v3.8.0
          echo "$(go env GOPATH)/bin" >> "$GITHUB_PATH"
      - name: Install gitleaks
        run: |
          base=https://github.com/gitleaks/gitleaks/releases/download/v8.18.4
          curl -sSfL -o gitleaks.tar.gz "${base}/gitleaks_8.18.4_linux_x64.tar.gz"
          curl -sSfL -o checksums.txt "${base}/gitleaks_8.18.4_checksums.txt"
          sum="$(grep 'gitleaks_8.18.4_linux_x64.tar.gz' checksums.txt | cut -d' ' -f1)"
          printf '%s  gitleaks.tar.gz\n' "${sum}" | sha256sum -c -
          tar -xzf gitleaks.tar.gz gitleaks
          sudo install -m 0755 gitleaks /usr/local/bin/gitleaks
          rm -f gitleaks gitleaks.tar.gz checksums.txt
      - name: ShellCheck
        run: >
          shellcheck -s bash -x -a -S warning -P 'SCRIPTDIR/..:SCRIPTDIR/../..'
          --enable=require-variable-braces
          bin/harbor lib/*.sh tests/run_unit.sh tests/shims/bin/harbor-shim
          tests/lint/placeholder_scan.sh tests/unit/test_helper.bash
      - name: shfmt
        run: >
          shfmt -i 2 -ci -bn -d bin/harbor lib tests/run_unit.sh tests/shims/bin/harbor-shim
          tests/lint/placeholder_scan.sh tests/unit/test_helper.bash
      - name: Placeholder scan
        run: tests/lint/placeholder_scan.sh
      - name: gitleaks
        run: gitleaks detect --source . --config .gitleaks.toml --no-banner --redact
      - name: markdownlint
        run: npx --yes markdownlint-cli@0.41.0 --config .markdownlint.yml '**/*.md' --ignore tests/vendor
```

- [ ] **Step 3: Write `.github/workflows/test.yml`**

`HARBOR_TEST_HOOKS=1` is not set lane-wide: the tests that use a hook set it beside the hook variable, and the log tests prove the hooks are inert without it.

```yaml
name: test

on:
  push:
    branches: [main]
  pull_request:

jobs:
  unit:
    strategy:
      fail-fast: false
      matrix:
        os: [ubuntu-24.04, macos-14, macos-latest]
    runs-on: ${{ matrix.os }}
    steps:
      - uses: actions/checkout@v4
        with:
          submodules: true
      - name: Show the shell the unit lane runs under
        run: /bin/bash -c 'echo "bash ${BASH_VERSION} on $(uname -sr)"'
      - name: Unit tests (Ubuntu, every directory)
        if: runner.os == 'Linux'
        run: tests/run_unit.sh
      - name: Unit tests (macOS, lib and bin under the system bash 3.2)
        if: runner.os == 'macOS'
        env:
          HARBOR_EXPECT_BASH32: "1"
        run: tests/run_unit.sh tests/unit/lib tests/unit/bin
```

The macOS jobs run `tests/unit/lib` and `tests/unit/bin`; there is no `client/` yet, and `tests/unit/bin` holds the lock cases driven through the dispatcher, which the merge gate requires under macOS bash 3.2. `tests/run_unit.sh` pins `PATH` so Bats itself runs under `/bin/bash` 3.2 on both macOS runners, and the harness test asserts the version under `HARBOR_EXPECT_BASH32=1`.

- [ ] **Step 4: Check `CONTRIBUTING.md` against the workflows**

Run: `grep -c 'SCRIPTDIR/..:SCRIPTDIR/../..' CONTRIBUTING.md .github/workflows/lint.yml`
Expected: `CONTRIBUTING.md:1` and `.github/workflows/lint.yml:1`. If the ShellCheck, shfmt, placeholder, gitleaks, or markdownlint command in `CONTRIBUTING.md` differs from the workflow in anything but line wrapping, edit `CONTRIBUTING.md` to match the workflow.

Validate the YAML parses:

Run: `for f in .github/workflows/*.yml; do python3 -c 'import sys,yaml; yaml.safe_load(open(sys.argv[1])); print(sys.argv[1], "ok")' "$f"; done`
Expected: both files print `ok`. If `yaml` is not installed, `ruby -ryaml -e 'YAML.load_file(ARGV[0]); puts ARGV[0] + " ok"' "$f"` is equivalent on macOS.

- [ ] **Step 5: Run the whole unit lane the way the workflow does**

Run: `tests/run_unit.sh`
Expected: every test file passes (`1..N` with all `ok` per file), exit 0. Expected count: harness 6, log 18, checks 6, versions 6, lock 31, journal 20, shim 5, placeholder scan 6, dispatch 7, resolve 10, contention 7 (122 tests).

- [ ] **Step 6: Hand off for review (no commit)**

Stop here and report as described under "Working conventions": the test commands run in this task with their results, `git status --short`, and `git diff --stat`. Do not run `git commit`. After the Fable pre-commit review and the orchestrator's own review, the orchestrator stages and commits:

- Files: `.github/workflows/lint.yml`, `.github/workflows/test.yml`, `CONTRIBUTING.md`
- Message: `ci: lint and unit workflows on ubuntu-24.04, macos-14, and macos-latest`

---

### Task 19: Final verification, diff review, and the PR

**Files:**

- Modify: none unless verification finds a defect; fix it in the file that owns it, re-run the task's tests, and hand the fix off like any other task so the orchestrator can review and commit it.

Steps 1 to 5 are the worker's part of this task and end in a report. Step 6 is the orchestrator's alone.

- [ ] **Step 1: Full unit lane under both shells**

Run on macOS: `tests/run_unit.sh; echo "rc=$?"` and `HARBOR_EXPECT_BASH32=1 tests/run_unit.sh tests/unit/lib tests/unit/bin; echo "rc=$?"`
Run on Ubuntu (or in a Docker `ubuntu:24.04` container with `git`, `bats` dependencies are vendored): `tests/run_unit.sh; echo "rc=$?"`
Expected: `rc=0` for each.

- [ ] **Step 2: Every static check**

Run:

```bash
shellcheck -s bash -x -a -S warning -P 'SCRIPTDIR/..:SCRIPTDIR/../..' --enable=require-variable-braces \
  bin/harbor lib/*.sh tests/run_unit.sh tests/shims/bin/harbor-shim \
  tests/lint/placeholder_scan.sh tests/unit/test_helper.bash; echo "shellcheck rc=$?"
shfmt -i 2 -ci -bn -d bin/harbor lib tests/run_unit.sh tests/shims/bin/harbor-shim \
  tests/lint/placeholder_scan.sh tests/unit/test_helper.bash; echo "shfmt rc=$?"
tests/lint/placeholder_scan.sh; echo "scan rc=$?"
gitleaks detect --source . --config .gitleaks.toml --no-banner --redact; echo "gitleaks rc=$?"
npx --yes markdownlint-cli@0.41.0 --config .markdownlint.yml '**/*.md' --ignore tests/vendor; echo "markdownlint rc=$?"
```

Expected: every `rc=0`.

- [ ] **Step 3: Secret and placeholder review of the diff**

Run:

```bash
git diff docs/harbor-design...HEAD --stat -- . ':!tests/fixtures' ':!tests/vendor'
git diff docs/harbor-design...HEAD -- . ':!tests/fixtures' ':!tests/vendor' | grep -nE '^\+' | grep -nE 'ts\.net|@[a-z0-9-]+\.[a-z]{2,}|100\.[0-9]+\.|tskey|user_[A-Za-z0-9]{20}' || echo "no identifiers beyond the placeholder list"
git ls-files -s | awk '$1 == "100755" { print $4 }'
```

Expected:

- the identifier grep prints only `TAILNET.ts.net` and `operator@example.com` occurrences (from `README.md`, `SECURITY.md`, `CONTRIBUTING.md`, this plan, and the placeholder-scan test) or the "no identifiers" line;
- the executable list is exactly `bin/harbor`, `tests/run_unit.sh`, `tests/shims/bin/harbor-shim`, `tests/lint/placeholder_scan.sh` (plus files under `tests/vendor`);
- no file under `/var/lib`, `/usr/local`, or `~/.local/state/harbor` on the machine was created by the test suite: `ls ~/.local/state/harbor 2>&1` prints "No such file or directory" unless it existed before you started.

- [ ] **Step 4: Read the whole diff once**

Run: `git diff docs/harbor-design...HEAD -- . ':!tests/vendor' | less`

Check, file by file, against the file map at the top of this plan: each file has exactly the responsibility listed, no file contains behavior from PR 3 onward (no bootstrap, apt, ufw, sshd, Tailscale, Node.js, `t3`, `status`, `upgrade`, `teardown`, client code), every shell script (`bin/harbor`, `lib/*.sh`, `tests/run_unit.sh`, `tests/shims/bin/harbor-shim`, `tests/lint/placeholder_scan.sh`, `tests/unit/test_helper.bash`) begins with `#!/bin/bash`, every executable one among them continues with `set -euo pipefail`, every function is `harbor_`-prefixed, and every global is `HARBOR_`-prefixed.

- [ ] **Step 5: Acceptance criteria**

All of the following must hold before the PR is opened:

1. `tests/run_unit.sh` exits 0 on macOS under `/bin/bash` 3.2 and on Ubuntu 24.04.
2. Every command in Task 19 Step 2 exits 0.
3. `bin/harbor bogus` prints exactly `{"error":"unknown_subcommand","subcommand":"bogus"}` on stdout, one line on stderr, exits 3, and creates nothing under `$HOME`.
4. `harbor journal resolve` cases from spec section 7 all pass: held lock, nested command, both double contenders, both interrupted acquisitions, ownership re-check, the three-entry case, and the typed-number refusal; the library-level double-contender, interrupted-acquisition, actual-subshell, and stale-archive-suffix tests of Task 8 pass under both shells.
5. Journal prepare, apply, revert, `ln` collision, all three recovery outcomes, and the malformed-entry refusals (validate, set_phase, recovery, resolve) pass at the library level; the root branch of `journal resolve` passes through the Task 14 override.
6. `versions.lock` contains the thirteen keys with empty values and loads without error.
7. `LICENSE` is MIT with the pending-review note in the PR description (decision 8).
8. `git log main..HEAD` shows one commit per task with the messages given in this plan.
9. The PR description states the changed-line count excluding `tests/fixtures` and `tests/vendor`, from `git diff docs/harbor-design...HEAD --shortstat -- . ':!tests/fixtures' ':!tests/vendor'`, and explains that the section 8 PR 2 test list is the reason it exceeds the 600-line guideline.

- [ ] **Step 6: Hand off; the orchestrator pushes the branch and opens the PR**

The worker stops after Step 5 and reports the results of Steps 1 to 5, including the changed-line count from Step 5 item 9. It does not push and does not open a pull request. After the final review, the orchestrator pushes `feat/foundation` and opens the stacked PR against `docs/harbor-design` with the title and body below; after PR 1 merges, the orchestrator retargets this PR to `main`. The command block is the orchestrator's record of that operation, not a worker step.

```bash
# Orchestrator only. Never run by an implementation worker.
git push -u origin feat/foundation
gh pr create --base docs/harbor-design --head feat/foundation --title "Foundation (PR 2): dispatcher, log, checks, versions, lock, journal, harness, CI" --body-file - <<'BODY'
## Scope

Design section 8, row 2 (Foundation). Adds README, SECURITY, CONTRIBUTING, LICENSE (MIT, decision 8, pending owner review on this PR), `bin/harbor` with the pinned unknown-subcommand reply, `lib/log.sh` with the `HARBOR_TEST_HOOKS`-gated step hook, `lib/checks.sh`, `lib/versions.sh` with a schema-only `versions.lock`, `lib/lock.sh` with the `reclaim.d` gate and the ownership re-check, `lib/journal.sh` with `ln` creation, rename-over rewrites, the platform sync helper, and `harbor journal resolve`, the Bats harness and shim skeleton, `lint.yml`, and `test.yml` on `ubuntu-24.04`, `macos-14`, and `macos-latest`.

## Tests added (design section 7)

Dispatcher, logging and hooks, lock parsing and classification (including fail-closed rejection of duplicate keys, embedded line breaks, and any empty field, the command line included); every lock case in the map: gate-present refusal, live holder, the three stale reclaims, same-second archive suffixes, the three fail-closed refusals, both double contenders and both interrupted acquisitions at the library level and again through `harbor journal resolve`, the ownership re-check, the actual-subshell and child-process release guards, and the nested-command and held-lock cases; journal prepare, apply, revert, `ln` collision, all three recovery outcomes, and refusal of any non-canonical entry (unknown or misplaced keys, extra lines or trailing content, comma or brace faults, a partial, duplicated, or empty resolution pair, resolution fields on a non-reverted entry) before any rewrite; `journal resolve` refusing without the typed number, acting only on a prepared undecidable entry, the three-entry case, and the root-principal branch through an in-process override; the shim contract; the placeholder scan against fixtures.

## Size

<N> changed lines excluding `tests/fixtures` and `tests/vendor`, above the 600-line guideline because the section 8 row for PR 2 mandates the full lock and journal test list.

## Not in this PR

Bootstrap, networking, vendor adapters, `status`, `upgrade`, `teardown`, the macOS client, `docs/runbook.md` (named in the recovery message; arrives with PR 3), and the real `/var/lib/harbor` path of `journal resolve`, which the unit lane covers only through an in-process override and PR 3's integration lane exercises for real.
BODY
```

The orchestrator replaces `<N>` with the number from Step 5 item 9 before running.

---

## Self-review against the specification

**Spec coverage.** Every PR 2 sentence in the design maps to a task:

| Spec sentence | Task |
| --- | --- |
| Section 8 row 2: README with honest status and architecture link, SECURITY.md, CONTRIBUTING.md, LICENSE | 1 |
| Section 9 decision 8: MIT, subject to owner review on this PR | 1, 19 (PR body) |
| Section 4: `bin/harbor` "dispatches subcommands, contains no logic"; unknown subcommand reply before any preflight, lock, or journal access, regardless of `--json`, exit 3, exact JSON on stdout, one line on stderr | 13 |
| Section 6.2: `set -euo pipefail`, ERR trap naming step, command, and next command; exit codes 0 to 4 | 4, 13 |
| Section 7: two hooks in one function in `lib/log.sh`, inert without `HARBOR_TEST_HOOKS=1`, only kill or pause at a boundary; `HARBOR_PAUSE_AFTER=<step>` resumes on a test-controlled file (the sentinel derived from pid and step) | 4 |
| Section 3.9: logs record step names, exit codes, vendor argv with secret-bearing arguments replaced by their flag names | 3, 4 |
| Section 5.6 (as far as PR 2 reaches): `unknown` rows with `requires_root`, `busy`, `requires_operator` do not affect the exit code | 5 |
| Section 2: `versions.lock` schema of thirteen keys, values empty until each component's PR | 6 |
| Section 3.7: state roots per principal; operator root `0700` created by `harbor journal resolve`; root modes `0755`/`0644`, operator modes `0700`/`0600` | 7, 8, 14 |
| Section 3.7: holder record fields (hostname, boot id from the named sources, `$$` PID, start time from the named sources, command line), written temp-and-rename; one line per key, every field required, records that are not canonical fail closed | 7 |
| Section 3.7: gate protocol steps 1 to 3 with no wait or retry; live, stale, and "anything else" classifications; stale archived as `lock.<timestamp>.stale` (suffixed while the name exists, never nested); inspection command; manual recovery text | 7, 8 |
| Section 3.7: ownership re-check before every journal write, exit 2 writing nothing; EXIT trap removes `lock.d` only under the same test; absent `lock.d` treated as released; subshell never removes another's lock (`BASH_SUBSHELL` guard, tested with an actual `( )` subshell) | 8, 9, 11 |
| Section 3.7: canonical journal entries; an entry that is not exactly the rendered shape (a missing, empty, repeated, unknown, or misplaced field, a comma, brace, or trailing-content fault, a partial, duplicated, or empty `resolved_by`/`resolved_at` pair, or resolution fields on an entry that is not `reverted`) is refused by recovery and rewrite alike, never skipped or rewritten | 11, 12, 14 |
| Section 3.7: sequence allocated as highest plus one; collision caught by `ln`, exit 2 naming both files | 11 |
| Section 3.7: write protocol (temp, fsync, `ln`, unlink, directory fsync), phase rewrite by rename-over, `observed` entries created directly `applied`, Linux per-file `sync` never falling back, macOS whole-filesystem `sync` | 10, 11 |
| Section 3.7: entry fields `op`, `target`, `pre_state`, `post_state`, `ownership`, `phase`; `file` observation as SHA-256 plus mode and owner | 10 |
| Section 3.7: recovery outcomes; refusal prints the entry beside the observed state and exits 2 mutating nothing | 12 |
| Section 3.7: `harbor journal resolve` semantics: lenient recovery except the named entry, acts only while still prepared and undecidable else exit 3, typed number required, `resolved_by: operator` with timestamp, never mutates the artifact, one entry per invocation, remaining entries keep blocking; both principal branches (root through an in-process override) | 14 |
| Section 7 test map, "Serialized commands", every PR 2 clause | 8, 9, 15 |
| Section 7 test map, "Crash-safe journal", unit part | 12 |
| Section 8 row 2 tests: dispatcher, logging, lock parsing, journal prepare/apply/revert/collision/recovery, resolve refusals and three-entry case, placeholder scan against fixtures | 3, 4, 7, 11, 12, 13, 14, 15, 17 |
| Section 7 static lane: ShellCheck flags, shfmt flags, gitleaks with section 3.8 rules, placeholder scan over every tracked file except `tests/fixtures`, markdownlint with line length disabled | 1, 17, 18 |
| Section 3.8: the six gitleaks Harbor rules and the placeholder list | 17 |
| Section 7 unit lane: three runners, macOS jobs on `lib/` (and the PR 2 lock tests under `bin/`), shims from `tests/shims/bin/` appending argv to a shim log and replying by scenario | 16, 18 |
| Section 7: unit tests never touch `/usr/local` or `/var/lib` and run public commands only against fixture homes | 2, 14, 15 |
| Section 2 compatibility floor: bash 3.2 for `lib/`, enforced by the `macos-14` runner | 2, 18 |
| Section 8 merge gate: lint and unit green on all runners including lock tests under macOS bash 3.2 | 18, 19 |

Deliberate limits, each stated where it applies: the real `/var/lib/harbor` path of `journal resolve` is reached only by PR 3's integration lane, while the unit lane covers the root branch through the `root_fixture` override (Task 14); `bootstrap.log` is opened `0600` because the spec fixes no mode for it (Task 14); `docs/runbook.md` is referenced by the recovery message but written in PR 3 (Task 12); `HARBOR_DEV=1` is passed by the test helper for PR 3's preflight and read by nothing in PR 2 (Task 2); `lib/checks.sh` content beyond the accumulator waits for PR 7 (Task 5). None is a PR 2 requirement left unimplemented.

**Red before green.** Every production behavior has a failing test earlier in the same task or in an earlier task: the hook contract and sentinel (Task 4 tests before Task 4 code), holder normalization and strict parsing including the empty `cmdline` rejection (Task 7), gated acquisition, archive suffixing, the subshell guard, the top-level EXIT trap, library-level double contenders and interrupted acquisitions (Task 8 tests before Task 8 code), the owner assertion (Task 9), canonical-shape validation with its unknown-key, trailing-content, order, comma, brace, and resolution-pair cases (Task 11), recovery's validation pre-pass over those same shapes (Task 12), and the root branch and malformed-entry path of `journal resolve` (Task 14). Task 15 is acceptance coverage through the public command and traces each test to its red predecessor; no step edits or reverts production code to make a test fail.

**Placeholder scan of this plan.** No work-in-progress marker words appear in this document; the patterns file and the tests build them from parts. The only MagicDNS name is `TAILNET.ts.net`, the only email is `operator@example.com`, and the auth-key prefix appears only as `tskey[-]` or split by `%s`. Task 19 Step 2 runs the real scan over the tracked tree, which includes this file.

**Interface consistency.** Names used across tasks were checked against their definitions: `harbor_die CODE ID MSG` (3) as called in 5 to 14; `harbor_step` names `lock-gate`, `lock-mkdir`, `lock-acquired` (8), `recovery-scan`, `resolve-confirmed` (14) as awaited in 8, 15, and 4; `HARBOR_PAUSE_AFTER=<step>` with the sentinel from `harbor_test_pause_sentinel` (4), mirrored by `pause_sentinel`, `holder_pid`, and `resume_holder` (2), as used in 8 and 15; `harbor_lock_acquire ROOT KIND` sets `HARBOR_LOCK_SUBSHELL` (8) as read by `harbor_lock_release` from the EXIT trap (4); `harbor_lock_assert_owner` (9) as called in 11; `harbor_journal_raw` and `harbor_journal_string` (10) as used in 11, 12, 14; `harbor_journal_validate` (11), which accepts exactly what `harbor_journal_render` (10) writes with or without the resolution pair, as called by `harbor_journal_set_phase` (11) and `harbor_journal_recover` (12) and reached from 14; `harbor_journal_recover ROOT [EXCEPT]` (12) as called in 14; `harbor_state_root_for_principal` (7) as overridden in 14; `fixture_undecidable_file_entry` sets `FIX_ARTIFACT_<SEQ>` (2) as read in 14 and 15; `resolve_cmd TYPED SEQ [ENV...]` (2) as called in 14 and 15; test counts per file in Task 18 Step 5 (122) match the tests written in Tasks 2 to 17.
