# Harbor Provision and Vendor Service (PR 4) Implementation Plan

> **For agentic workers:** implement this plan task by task. Implementation workers never commit, push, or open a pull request: every task ends in the handoff described under "Working conventions", and the orchestrator commits after its own gate. Where a skill's own flow says to commit, this plan wins.

**Goal:** Ship PR 4 of Harbor, design section 8 row 4: the operator provision. The operator, over SSH from the Mac, installs Claude Code, Codex, and `t3` at locked versions into their own home prefix, installs the vendor-owned T3 service, and writes `installed.lock` and `provision.json`, with every mutation journaled in the operator journal and every rerun converging. `harbor auth claude|codex|connect` and `harbor service` ship alongside it.

**Architecture:** `bin/harbor provision` dispatches to `node/provision.sh`, the operator twin of `node/bootstrap.sh`: a preflight in the order of the design section 5.4 table, then rows that are each one journaled transaction, then the state record. It runs entirely unprivileged under the operator lock in `~/.local/state/harbor/`, and never calls `sudo`. Three new bash 3.2 libraries carry the checks and mutations: `lib/runtime.sh` owns the `runtime-install` op that Node.js, Claude Code, Codex, and `t3` now share; `lib/agents.sh` owns the two agent CLIs; `lib/t3.sh` owns the pinned `t3` invocation, the service-status adapter, the connect-status adapter, and the engines check against the installed package. The unit lane drives every function against disposable fixture home roots with fake vendor shims; the integration lane runs the real commands at real paths as the real operator; the vendor-smoke lane installs the real `t3` and proves the engines pair.

**Tech Stack:** bash 3.2 for `fleet/lib/`, bash 5 for `fleet/node/`, Bats, the PR 2 shim skeleton, GitHub Actions (`lint.yml`, `test.yml`, `integration.yml`, `vendor-smoke.yml`).

> **Layout:** unchanged. Harbor's code lives under `fleet/`; documents, `.github/workflows/`, `.gitleaks.toml`, and `.markdownlint.yml` stay at the repository root. Every code path below is relative to `fleet/` unless it starts with `docs/` or `.github/`.

## Scope fence: what PR 4 ships and what PR 5 keeps

Spec section 8 splits the T3 Connect work across two PRs, and the split is not obvious from either row alone. This plan reads it as follows, and every task below holds to it:

| Concern | PR | Why |
| --- | --- | --- |
| `t3 connect status --json` adapter | **4** | `harbor auth connect` ships in PR 4 (row 4) and cannot decide whether to run `t3 connect login` without reading `authenticated` |
| `harbor auth connect` login step | **4** | Row 4: "`harbor auth <claude\|codex\|connect>` with `auth` journaling" |
| `harbor auth connect` link step, `t3-connect-link` entry | **5** | Row 5 names it explicitly: "`connect` reporting and `harbor auth connect` link step" |
| `~/.config/harbor/config` with `access_mode`, mode 0600 | **4** | Section 5.4's "Journal and config" row is a provision step, and provision ships in PR 4 |
| `harbor access` (switching modes, reverting the previous mode's entries) | **5** | Row 5: "`access_mode` config, `harbor access`" |
| Provision's "Access mode" row for `connect`: section 5.5 steps 1 to 3 | **4** | See below — PR 4 owns every component this row needs, and deferring it makes PR 4's exit 0 unreachable |
| Provision's "Access mode" row for `tailnet`, and `harbor pair`, Serve inspection, the `t3.environment` descriptor check | **5** | Row 5 |

**Why `connect` reporting is PR 4's and not PR 5's.** Row 5 says "`connect` reporting", and the first draft of this plan deferred the whole row, having PR 4 report `access_mode_not_provisioned` as an attended note. That was wrong in a way worth stating: with `tailnet` refused at parse time (decision 1 below), `connect` is the only reachable mode, so **every** PR 4 provision run would end attended and exit 1. A release in which success is always exit 1 is a release in which exit 1 has stopped distinguishing anything, and section 5.4's "exits 0 when every unattended step holds" would be dead text no test could reach.

PR 4 already owns every component the row needs: the `t3 connect status --json` adapter (Task 14) and `harbor auth connect` (Task 15). And the reports themselves are section 3.6's own list, which names provision as the thing that emits them: "`harbor provision` never runs any of the above. It configures the selected mode and, when a vendor-observable precondition is unmet, reports … `needs_connect_login`, or `needs_connect_link` with the command to run."

So PR 4's row does section 5.5's `connect` steps 1 to 3: healthy (`desired`, `authenticated`, and `linked` all true and `relayClient.status` is `available`) contributes exit 0; `authenticated` false reports `needs_connect_login` naming `harbor auth connect`, which PR 4 ships; `linked` false reports `needs_connect_link` naming PR 5's link step; `relayClient.status` of `missing` or `unsupported` is `degraded` with the vendor's own text; `unknown` anywhere is `unknown`, never a pass. All four non-healthy outcomes are attended, exit 1.

`access_mode=tailnet` is refused at parse time with exit 3, because `harbor pair` does not exist yet and a `tailnet` node cannot be provisioned by this release. This is a deliberate, reviewable gap, not an oversight; it is stated in the PR body.

## Slices

PR 4's scope is far past the 600-line guideline, so it ships as five stacked pull requests, each independently green and independently reviewable. Each slice's branch is based on the previous one.

| Slice | Branch | Contents | Tasks |
| --- | --- | --- | --- |
| 4a | `feat/provision-pins` | The `runtime-install` observer split into `lib/runtime.sh`, the pinned agent and `t3` install values, the installed-package engines proof | 1 to 4 |
| 4b | `feat/provision-agents` | `lib/agents.sh`: install, version inspection, the two auth-status adapters, `harbor auth claude` and `harbor auth codex` | 5 to 8 |
| 4c | `feat/provision-t3` | `lib/t3.sh`: locked invocation, install, the service-status adapter and its fixtures, `t3 service install`, `harbor service` | 9 to 13 |
| 4d | `feat/provision-connect` | The connect-status adapter, `harbor auth connect`, the `auth` entry transition rule | 14 to 16 |
| 4e | `feat/provision-node` | `node/provision.sh`, the config file, `installed.lock`, `provision.json`, dispatcher and usage, the integration and vendor-smoke lanes, final verification | 17 to 22 |

## Global constraints

Everything in the PR 2 and PR 3 plans' constraints still binds. Restated because every task's requirements implicitly include this section:

- **Shell floor (spec section 2):** bash 3.2 subset for everything under `lib/`. No `readlink -f`, no associative arrays, no `mapfile`, no `${var^^}`, no `+=` on arrays. `node/` may use bash 5; write it in the 3.2 subset anyway so the unit lane can source it on the pinned `macos-14` runner.
- **Exit codes (spec section 6.2):** 0 success, 1 degraded or attended, 2 broken or apply failed, 3 precondition or usage, 4 interrupted.
- **Principal (spec section 3.1):** every path in PR 4 runs as the **operator**. No script in this PR calls `sudo`, `runuser`, `su`, or writes outside `$HOME`. A provision run that finds itself root exits 3.
- **Journal write protocol (spec section 3.7):** inspect, write a `prepared` entry, mutate, mark `applied`. Every mutation is one transaction. A failed mutation leaves its entry `prepared` and says so.
- **Operator state root (spec section 3.7):** `~/.local/state/harbor/` at `0700`, created by the preflight before the lock is acquired and before any journal write. `lock.d` and `reclaim.d` are `0700`, their holder records `0600`.
- **Idempotency (spec section 6.1):** every step is defined by its inspection first. A second run makes zero mutating shim calls and writes no new `created` or `modified` entry.
- **Vendor lifecycle untouched (spec sections 3.2 and 7):** Harbor never writes under `~/.config/systemd/user/` or any T3 home directory, never writes a unit file, never sets a bind address, port, or environment variable, and never runs `systemctl --user enable/disable/edit` on `t3code.service`. Only `t3 service install|update|uninstall` and `t3` itself touch those. The unit lane asserts that no shim invocation wrote under either path.
- **Vendor status honesty (spec sections 3.2 and 7):** unrecognized adapter output classifies as `unknown`, never a guess. Every adapter is version-pinned and backed by fixtures captured from the pinned release.
- **Secret handling (spec section 3.8):** no secret ever reaches a command line. Harbor never reads, copies, prints, or inspects a vendor credential store. `harbor auth` passes the vendor's own login output straight through and journals only the tool's documented status word.
- **Unit lane (spec section 7):** unit tests never touch `/var/lib`, `/etc`, `/usr/local`, `/opt`, or the real `~/.local/state/harbor`, and never use sudo. Every vendor and system binary is a shim. Every home root is a disposable fixture directory.
- **Sudo environment (carried forward):** the integration lane passes hooks and shim variables only through the explicit `sudo env` argument list. That allowlist is fixed and must never forward `HARBOR_TEST_HOOKS`, `HARBOR_FAIL_AFTER`, `HARBOR_PAUSE_AFTER`, `HARBOR_PID`, or `TMPDIR` from an ambient environment, and no sudoers rule may `env_keep` them. PR 4's operator-phase runs need no `sudo env` at all; where the lane must become the operator it uses `runuser -u <operator> --`, never `sudo -E`.
- **Static lane:** ShellCheck `-s bash -x -a -S warning -P 'SCRIPTDIR/..:SCRIPTDIR/../..' --enable=require-variable-braces`, shfmt `-i 2 -ci -bn`, `tests/lint/placeholder_scan.sh` **run from the repository root**, `tests/lint/engines_check.sh`, gitleaks, markdownlint.

## Working conventions for every task

- Work in the worktree `/Users/krishgarg/Documents/products/harbor/.worktrees/provision`, on the branch named by the slice. Run code commands from `fleet/`; run git and markdownlint from the worktree root.
- Test first: write the failing tests, run them, record the failure verbatim, then write the code until they pass. Run `tests/run_unit.sh` for the whole lane and `tests/run_unit.sh <file>` while iterating. The full lane takes about 27 minutes on macOS; never pipe it through `tail`, which discards failure lines. Count failures with `tests/run_unit.sh 2>&1 | grep -c '^not ok'`.
- Every library function is prefixed `harbor_`, every global `HARBOR_`. Libraries define functions only; they run nothing at source time.
- Two-space indent, braced variables, `case` arms one level in, no space after a redirection operator.
- Every operation that can fail is checked, and the failure says what state the node is in. This has been the single most common defect at the gate: an unchecked `mv` into place, an unchecked `find` feeding a loop that judges what it enumerates, an unchecked `mkdir`. An operation whose failure is silent leaves a journal entry vouching for a state that is not there.
- Each task ends in a handoff: the test commands with their verbatim results, the deviations, `git status --short`, `git diff --stat`, and the concerns worth flagging. The orchestrator gates and commits.
- A handoff with a failing test, a lint finding, or a file outside the task's list is not ready. Say so instead of working around it.

## File map (new files in PR 4)

| File | Responsibility |
| --- | --- |
| `lib/runtime.sh` | The `runtime-install` op: the shared observer, the target-to-reader dispatch, and the generic "ask a CLI its version" reader |
| `lib/agents.sh` | Claude Code and Codex: version inspection, install at the locked version into the operator's home prefix, the two auth-status adapters, `harbor auth claude` and `harbor auth codex` |
| `lib/t3.sh` | `t3` at the locked version: install, the pinned invocation, the service-status adapter, the connect-status adapter, `t3 service install`, the engines check against the installed package, `harbor service`, `harbor auth connect` |
| `lib/config.sh` | `~/.config/harbor/config`: create at `0600`, parse, validate `access_mode` |
| `node/provision.sh` | The operator provision sequence: preflight, the rows in section 5.4 table order, `installed.lock` and `provision.json` |
| `tests/fixtures/t3/service-status/*` | Captured `t3 service status` output for installed-and-current, update-pending, not-installed, and two unrecognized shapes |
| `tests/fixtures/t3/connect-status/*` | Captured `t3 connect status --json` bodies for healthy, needs-login, needs-link, relay-missing, relay-unsupported, and unparseable |
| `tests/integration/assert_provision.sh` | The integration assertions for the provision run and its rerun |
| `fleet/vendor-smoke/t3_engines_probe.sh` | The vendor-smoke T3 half: real install of the pinned `t3`, real `engines.node` compared to the lock, real `t3 service status` classified by the adapter |

Modified: `lib/node.sh` (observer moved out), `lib/versions.sh` (installed-package engines check), `bin/harbor` (dispatch and usage), `versions.lock`, `.github/workflows/integration.yml`, `.github/workflows/vendor-smoke.yml`, `.github/workflows/lint.yml`.

---

## Slice 4a: the shared runtime op and the pins

### Task 1: `lib/runtime.sh` and the `runtime-install` observer collision

**Why this is first, and why it is a real defect rather than a refactor.** `harbor_journal_observe` (`lib/journal.sh:131`) dispatches an op to the single function `harbor_observe_op_<op>`, and its own comment says that function is "defined by the library that owns that op". As of PR 3 exactly one library defines `harbor_observe_op_runtime_install`: `lib/node.sh:35`, which reads `${1}/bin/node --version` and treats its argument as a filesystem prefix. Spec section 3.7 gives the `runtime-install` op four targets — "Node.js, Claude Code, Codex, `t3`" — and the three PR 4 targets are runtime *names*, not prefixes. If `lib/agents.sh` defines the same function name, whichever library is sourced last silently wins, and operator journal recovery of a `runtime-install` entry left `prepared` by a crash would read a Claude Code entry with the Node.js reader. It would not error; it would return `"absent"` and call a decidable entry decidable with the wrong answer.

**Files:**

- Create: `lib/runtime.sh`
- Modify: `lib/node.sh:23-42` (delete `harbor_observe_op_runtime_install`; keep `harbor_node_installed_version`)
- Modify: `node/bootstrap.sh:56-57` (source `lib/runtime.sh` before `lib/node.sh`)
- Test: `tests/unit/lib/runtime.bats` (new), `tests/unit/lib/node.bats` (the observer tests move here)

**Interfaces produced:**

```text
harbor_runtime_cli_version CMD          -> "absent" | bare version | exit 2
harbor_runtime_reader_register NAME FN  -> registers FN as the version reader for target NAME
harbor_observe_op_runtime_install TARGET-> JSON string, the pre_state/post_state form
```

**Contract.** `lib/runtime.sh` owns the op. `harbor_observe_op_runtime_install` dispatches on the shape of its target: an absolute path is a prefix and is read by the reader registered for `prefix`; a bare `[a-z0-9-]+` name is a runtime and is read by the reader registered for that name. A target with no registered reader renders `"unobservable:runtime-install:<target>"` rather than guessing, which is the same fail-closed shape `harbor_journal_observe` already uses for an op with no observer. Registration is a flat `NAME=FN` list in one string variable, because `lib/` is bash 3.2 and has no associative arrays.

```bash
# HARBOR_RUNTIME_READERS: "name:function" pairs, space separated. bash 3.2 has no
# associative arrays, so the registry is a string and lookup is a case over it.
HARBOR_RUNTIME_READERS=""
harbor_runtime_reader_register() {
  HARBOR_RUNTIME_READERS="${HARBOR_RUNTIME_READERS} ${1}:${2}"
}
harbor_runtime_reader_for() {
  local want="${1}" pair
  for pair in ${HARBOR_RUNTIME_READERS}; do
    [ "${pair%%:*}" != "${want}" ] || {
      printf '%s' "${pair#*:}"
      return 0
    }
  done
  return 1
}
harbor_observe_op_runtime_install() {
  local target="${1}" key fn version
  case "${target}" in
    /*) key=prefix ;;
    "" | *[!a-z0-9-]*) key="" ;;
    *) key="${target}" ;;
  esac
  if [ -n "${key}" ] && fn="$(harbor_runtime_reader_for "${key}")"; then
    version="$("${fn}" "${target}")" || exit "$?"
    printf '"%s"' "$(harbor_json_escape "${version}")"
    return 0
  fi
  printf '"unobservable:runtime-install:%s"' "$(harbor_json_escape "${target}")"
}
```

`lib/node.sh` gains a reader and one registration line at the bottom. The reader is where the `.harbor-previous` fallback that today lives in the observer moves to, because that fallback is the Node.js swap's own semantics and belongs beside the swap rather than in a dispatcher that knows nothing about it:

```bash
# harbor_node_prefix_version PREFIX: the version reader lib/runtime.sh dispatches to
# for an absolute-path runtime-install target. When the prefix holds no runtime but
# PREFIX.harbor-previous does, it reports that version: the swap moves the displaced
# tree there and then renames the new one into place, so a crash between the two moves
# leaves the prefix empty and the whole previous runtime intact one path over. That is
# the pre-install state, not a third state.
harbor_node_prefix_version() {
  local version
  version="$(harbor_node_installed_version "${1}")" || exit "$?"
  if [ "${version}" = absent ]; then
    version="$(harbor_node_installed_version "${1}.harbor-previous")" || exit "$?"
  fi
  printf '%s' "${version}"
}
harbor_runtime_reader_register prefix harbor_node_prefix_version
```

**Tests.** `tests/unit/lib/runtime.bats`: an absolute-path target with the prefix reader registered renders the prefix version; a bare name target with its reader registered renders that reader's answer; an unregistered bare name renders `"unobservable:runtime-install:<name>"`; a target with a character outside `[a-z0-9-]` renders unobservable without any lookup; a reader that exits 2 propagates exit 2 rather than rendering. `tests/unit/lib/node.bats`: the moved observer tests still pass unchanged through the dispatcher, including the `.harbor-previous` fallback and the exit 2 on a runtime that cannot answer. A regression test asserts that sourcing `lib/runtime.sh`, `lib/node.sh`, and `lib/agents.sh` in one process leaves exactly one definition of `harbor_observe_op_runtime_install` and that a `claude` target still reads the agent reader.

**Commit:** `refactor(runtime): one owner for the runtime-install op`

### Task 2: Pin Claude Code, Codex, and the `t3` install method

**Files:**

- Modify: `versions.lock` (`claude_code_version`, `claude_code_install`, `codex_version`, `codex_install`, `t3_install`)
- Test: `tests/unit/lib/versions.bats`

**Contract (spec section 2, version pinning).** Set the five values PR 4 owns. Every value is exact, never `latest`. `t3_version` and `t3_engines_node` are already pinned by PR 3 and **must not change in this PR**; PR 4 installs at that pin and proves the pair. Each `*_install` method must yield a verifiable exact version and work without root in the operator's home prefix. A download outside a package manager requires a recorded SHA-256 and fails closed; if a chosen method needs one, add the `*_sha256` key in the same commit and say so in the handoff, because the key list in spec section 2 is otherwise closed.

**How to derive each value, exactly.** Run these from the worktree and paste the verbatim output into the handoff; do not fill any value from memory.

```bash
npm view @anthropic-ai/claude-code version
npm view @anthropic-ai/claude-code dist.tarball
npm view @openai/codex version
npm view @openai/codex dist.tarball
npm view t3@0.0.38 version          # must print 0.0.38, the PR 3 pin
npm view t3@0.0.38 engines.node     # must equal t3_engines_node in versions.lock
```

If a package's real name differs from the guess above, the handoff records the search that found the right one (`npm search`, the vendor's own install documentation) and the name used. A package that does not exist under any name is a blocker, not a value to invent: stop and report.

**Install method.** All three install through the Node.js that PR 3 put at `/opt/harbor/node` with `/usr/local/bin` symlinks, into an operator-owned npm prefix at `~/.local/harbor/npm`, so nothing needs root and nothing lands in a root-owned global. The `*_install` value records the method as an exact, replayable string, in the form `npm:<package>@<version>`, and `lib/agents.sh` and `lib/t3.sh` are the only readers of that form.

**Tests.** Extend `tests/unit/lib/versions.bats`: the lock still loads; all thirteen keys are non-empty; `claude_code_version` and `codex_version` are bare exact versions with no range operator; each `*_install` parses as `npm:<name>@<version>` and its version equals the matching `*_version` key; `t3_install`'s version equals `t3_version`; `t3_version` and `t3_engines_node` are byte-identical to their pre-PR-4 values, asserted against a fixture copy so a later edit to the lock cannot silently move the PR 3 pin.

**Commit:** `chore(versions): pin Claude Code, Codex, and the t3 install method`

### Task 3: The installed-package engines check

**Files:**

- Modify: `lib/versions.sh` (add `harbor_versions_require_installed_engines`)
- Test: `tests/unit/lib/versions.bats`

**Contract (spec section 2).** `lib/versions.sh` repeats the Node check at provision time against the **installed** `t3` package's own `engines.node`, not against the lock's copy, and exits 3 on failure. PR 3's `harbor_versions_require_node_range` compares a Node version against the locked range; this is its twin against the range the installed package declares, and the point of having both is that a drift between them is exactly the failure the check exists to catch.

**Interfaces produced:**

```text
harbor_t3_package_engines HOME    -> the engines.node string, or exit 2  (defined in lib/t3.sh, Task 9)
harbor_versions_require_installed_engines NODE_VERSION INSTALLED_RANGE
    -> 0 when NODE_VERSION satisfies INSTALLED_RANGE and INSTALLED_RANGE equals the
       locked t3_engines_node; exit 3 naming which of the two failed
```

The function takes the range as a parameter rather than reading the package itself, so `lib/versions.sh` keeps its PR 2 property of depending on nothing above it, and the package reading lives in `lib/t3.sh` where the vendor knowledge belongs.

**Tests.** A Node version that satisfies a range equal to the lock passes. A Node version that does not satisfy it exits 3 naming the Node version, the range, and `versions.lock`. A range that differs from the locked `t3_engines_node` exits 3 naming both spellings and saying the installed package disagrees with the lock, **even when the Node version satisfies both** — that case is the drift the row exists for and it must not pass quietly. An empty installed range exits 3 rather than treating "no constraint" as "any version".

**Commit:** `feat(versions): prove Node against the installed t3 package's engines range`

### Task 4: The engines proof in CI

**Files:**

- Modify: `tests/lint/engines_check.sh`
- Modify: `.github/workflows/lint.yml` (add `lib/runtime.sh`, `lib/agents.sh`, `lib/t3.sh`, `lib/config.sh`, `node/provision.sh` to the shellcheck and shfmt target lists)

**Contract.** PR 3's `engines_check.sh` proves `nodejs_version` satisfies the locked `t3_engines_node`. Extend it to also prove, without network access, that each `*_install` value's version equals its matching `*_version` key, so a lock edit that moves one and not the other fails the static lane rather than the provision run. The live-registry proof that the installed package's range equals the lock is the vendor-smoke lane's job (Task 21), not the static lane's, because the static lane has no network.

**Tests.** `tests/unit/lint/engines_check.bats`: a lock whose `claude_code_install` version differs from `claude_code_version` fails naming both; a lock where they agree passes; the existing Node-range assertions still pass.

**Commit:** `ci: prove the install methods match their pinned versions`

---

## Slice 4b: the agent CLIs

### Task 5: `lib/agents.sh` version inspection and the npm prefix

**Files:**

- Create: `lib/agents.sh`
- Test: `tests/unit/lib/agents.bats`

**Interfaces produced:**

```text
HARBOR_AGENTS="claude codex"
harbor_agents_lock_key AGENT FIELD   -> "claude_code_version" | "codex_install" | ...
harbor_agents_prefix HOME            -> "<HOME>/.local/harbor/npm"
harbor_agents_bin AGENT HOME         -> the absolute path of the agent's executable
harbor_agents_installed_version AGENT-> "absent" | bare version | exit 2
```

**Contract.** `harbor_agents_installed_version` runs `<bin> --version` and returns the bare version, `absent` when the executable is not an executable file, and exit 2 when it is present but cannot answer or answers something that is not a version — the same three-way shape `harbor_node_installed_version` already uses, because recovery treats all four runtimes identically. The agents' `--version` output is a vendor string: parse it with one anchored `case` per agent against fixtures captured from the pinned release, and classify anything else as exit 2 with the raw text, never a substring guess.

`harbor_agents_prefix` is `${HOME}/.local/harbor/npm` and is created `0755` by the install, not by inspection. Every function takes `HOME` as a parameter; no function in this library reads `$HOME` itself, so the unit lane can point them at a fixture directory.

**Tests.** For each agent: an absent executable is `absent`; a shim printing the pinned version is that version; a shim exiting non-zero is exit 2 naming the command; a shim printing non-version text is exit 2 quoting it; the prefix and bin paths are derived from the parameter and never from the ambient `$HOME`. A test asserts no function writes anything.

**Commit:** `feat(agents): version inspection for Claude Code and Codex`

### Task 6: `lib/agents.sh` install

**Files:**

- Modify: `lib/agents.sh`
- Test: `tests/unit/lib/agents.bats`

**Interfaces produced:**

```text
harbor_agents_install STATE_ROOT HOME AGENT  -> 0; journals one runtime-install entry
```

**Contract (spec sections 2 and 5.4).** Compare installed to locked before acting: a match is a no-op with no entry and no vendor call. Otherwise one `runtime-install` entry, target the bare agent name (`claude` or `codex`, which is what Task 1's dispatcher reads), `pre_state` the previous version or `"absent"`, `post_state` the locked version, `prepared` before the install and `applied` only after `<bin> --version` reports the locked version. `ownership` is `created` when the pre-state was `absent`, `modified` otherwise. A failed install leaves the entry `prepared` and exits 2 naming the entry and the vendor output. The install runs `npm install --global --prefix <prefix> <package>@<version>` with the package and version taken from the `*_install` value, never from a string built in this file, so the lock is the single source of the identity being installed.

The library registers its two readers at source time, at the bottom of the file beside Task 5's definitions, so Task 1's dispatcher can find them:

```bash
harbor_runtime_reader_register claude harbor_agents_reader_claude
harbor_runtime_reader_register codex harbor_agents_reader_codex
```

Each reader closes over the home root the same way the rest of the library does, by reading `HARBOR_AGENTS_HOME`, which `harbor_agents_install` and the provision preflight both set. A reader called with no home set exits 2 rather than falling back to `$HOME`, because recovery reading the wrong home is the failure Task 1 exists to prevent.

**Tests.** Install from absent writes one `created` entry and ends `applied`; install over a different version writes `modified` with the prior version as `pre_state`; install when the version already matches writes nothing and makes zero shim calls; a shim that fails leaves the entry `prepared` and exits 2; a shim that succeeds but reports the wrong version afterwards leaves the entry `prepared` and exits 2; `HARBOR_FAIL_AFTER` at the boundary between the install and the `applied` write leaves a `prepared` entry that recovery then decides correctly through the Task 1 dispatcher; nothing is written outside the fixture home.

**Commit:** `feat(agents): journaled install at the locked versions`

### Task 7: The auth-status adapters

**Files:**

- Modify: `lib/agents.sh`
- Create: `tests/fixtures/agents/claude-status/*`, `tests/fixtures/agents/codex-status/*`
- Test: `tests/unit/lib/agents.bats`

**Interfaces produced:**

```text
harbor_agents_auth_status AGENT HOME -> "logged-in" | "logged-out" | "unknown" | "unsupported"
```

**Contract (spec section 3.6).** `harbor auth <claude|codex>` "journals the tool's documented machine-readable auth status" and records an `auth` entry "only when that run transitioned logged-out to logged-in. A tool with no such status command gets no entry and is never logged out by Harbor."

So the adapter has four answers, and the difference between the last two is load-bearing:

- `logged-in` / `logged-out`: the tool has a documented status command and it answered clearly.
- `unknown`: the tool has the command and its answer was not one the pinned adapter recognizes. Fail closed — never journal a transition from `unknown`.
- `unsupported`: the pinned release ships **no** documented machine-readable status command for this tool. Harbor writes no entry for it ever, and `harbor auth` still runs the tool's own login, reports that it cannot verify the transition, and exits 1.

Whether each agent is `unsupported` is a measurement, not an assumption: the implementer runs the pinned CLI's `--help` and records in the handoff which subcommand, if any, is documented as machine-readable. Fixtures are captured from that release. If a tool turns out to be `unsupported`, that is a legitimate outcome and the tests assert the `unsupported` path rather than being weakened.

**Tests.** Each captured fixture classifies to its recorded answer; an empty body, a non-zero exit with a valid body, and an unrecognized body each classify `unknown`; a missing status subcommand classifies `unsupported`; the adapter never prints the vendor body to stdout, so no credential-adjacent text can reach a caller that is capturing it.

**Commit:** `feat(agents): version-pinned auth status adapters`

### Task 8: `harbor auth claude` and `harbor auth codex`

**Files:**

- Modify: `lib/agents.sh`, `lib/auth.sh` (`harbor_auth_cmd` dispatch), `bin/harbor` (usage)
- Test: `tests/unit/lib/agents.bats`, `tests/unit/lib/auth.bats`

**Contract (spec section 3.6).** Operator-run, unprivileged, refuses root through the existing `harbor_auth_refuse_root`. The preflight creates `~/.local/state/harbor/` at `0700` before acquiring the operator lock, exactly as `harbor auth tailscale` does, then: read the status, run the tool's own login with its output passed straight through to the terminal, read the status again, and write an `auth` entry (`created`, target the agent name, `pre_state` the status word before, `post_state` after) **only** on a `logged-out` to `logged-in` transition. Every other pair writes nothing: already `logged-in` is exit 0 with a line saying so and no entry; still `logged-out` is exit 1 naming the rerun; `unknown` either side is exit 1 saying the transition could not be verified; `unsupported` runs the login and exits 1 saying no entry was written and why. Harbor never reads, copies, prints, or inspects the credential store, and never logs the tool out.

**Tests.** The five transition pairs each produce the stated entry-or-no-entry and exit code; a run as root exits 3 before anything; the state root is created `0700` before the lock, asserted positionally by `HARBOR_FAIL_AFTER=lock-gate` the way `assert_auth.sh` already does for Tailscale; the vendor's login output reaches stdout unchanged; no shim invocation reads any path under a credential store fixture; `harbor auth` with an unknown tool name exits 3 with usage.

**Commit:** `feat(auth): attended Claude Code and Codex login`

---

## Slice 4c: `t3` and the vendor service

### Task 9: `lib/t3.sh` install and the pinned invocation

**Files:**

- Create: `lib/t3.sh`
- Test: `tests/unit/lib/t3.bats`

**Interfaces produced:**

```text
harbor_t3_bin HOME                -> the absolute path of the t3 executable
harbor_t3_installed_version HOME  -> "absent" | bare version | exit 2
harbor_t3_package_dir HOME        -> the installed package directory
harbor_t3_package_engines HOME    -> the engines.node string from the installed package.json, or exit 2
harbor_t3_install STATE_ROOT HOME -> 0; journals one runtime-install entry, target "t3"
harbor_t3_run HOME ARGS...        -> runs the locked t3 with ARGS, logging the vendor call
```

**Contract (spec section 2).** `t3` installs at the already-pinned `t3_version` by the `t3_install` method into the same operator npm prefix the agents use. The entry shape is Task 6's, with target `t3`. `harbor_t3_run` is the single seam through which every `t3` invocation in Harbor passes, so "driven through the `t3` npm package's CLI at the locked version" is a property of one function rather than a convention. It asserts the installed version equals the lock before invoking, and exits 3 naming `harbor provision` when it does not.

`harbor_t3_package_engines` reads `engines.node` out of the installed package's own `package.json` with the same `jq`-free parsing the rest of `lib/` uses (bootstrap installs `jq`, but `lib/` cannot depend on it because the macOS unit jobs may not have it). A `package.json` that is absent, unreadable, or carries no `engines.node` is exit 2 naming the path — never an empty range, which Task 3 already refuses.

**Tests.** The four version states; the entry shapes and the `HARBOR_FAIL_AFTER` boundary as in Task 6; `harbor_t3_run` refuses when the installed version differs from the lock and makes no vendor call; `harbor_t3_package_engines` returns the fixture's range, and exits 2 on absent, unreadable, and engines-less package files; nothing is written under `~/.config/systemd/user/` or a T3 home fixture.

**Commit:** `feat(t3): journaled install at the locked version and the pinned invocation`

### Task 10: The service-status adapter and its fixtures

**Files:**

- Modify: `lib/t3.sh`
- Create: `tests/fixtures/t3/service-status/installed-current`, `update-pending`, `not-installed`, `unrecognized-text`, `empty`
- Test: `tests/unit/lib/t3.bats`

**Interfaces produced:**

```text
harbor_t3_service_status HOME -> "installed-current" | "update-pending" | "not-installed" | "unknown"
harbor_t3_service_healthy HOME -> 0 when the adapter says installed-current and
                                  systemctl --user is-active t3code.service is "active"
```

**Contract (spec section 3.2).** The `t3 service` CLI has no JSON mode, so this is a version-pinned text adapter: **exit code first**, then the minimum set of stable phrases needed to distinguish the three real states, backed by fixtures captured from the pinned release. Unrecognized output classifies as `unknown`, never a guess. The phrase set is minimal on purpose — every extra phrase is another thing a vendor patch release can break — and each one is a comment naming the fixture it came from. A healthy service means the adapter says `installed-current` **and** `systemctl --user is-active t3code.service` prints `active`; the vendor log file need not exist.

**Tests (spec section 7, "Vendor status honesty").** Each fixture classifies to its recorded state; unrecognized text and empty output both classify `unknown`; a non-zero exit with recognizable text still classifies by exit code first and the test records which wins; `harbor_t3_service_healthy` is false when the adapter is `installed-current` but `is-active` prints `inactive`, false when the adapter is `unknown` and `is-active` prints `active`, and true only when both hold; no invocation writes under `~/.config/systemd/user/`.

**Commit:** `feat(t3): version-pinned service status adapter`

### Task 11: `t3 service install` as a journaled transaction

**Files:**

- Modify: `lib/t3.sh`
- Test: `tests/unit/lib/t3.bats`

**Interfaces produced:**

```text
harbor_observe_op_t3_service TARGET -> the adapter's word, rendered as a JSON string
harbor_t3_service_install STATE_ROOT HOME -> 0; journals one t3-service entry
```

**Contract (spec sections 3.2 and 5.4).** Inspect first: when the adapter already reports `installed-current` and the unit is `active`, write nothing and make no vendor call. Otherwise one `t3-service` entry, target `t3code.service`, `pre_state` the adapter's word before, `post_state` `installed-current`, `prepared` before `t3 service install` and `applied` only after the adapter reports `installed-current` and `is-active` prints `active`. `ownership` is `created` when the pre-state was `not-installed`, `modified` otherwise. An `unknown` pre-state exits 3 without mutating: Harbor does not install over a service whose state it could not read, because the entry it would write would vouch for a transition it never saw.

Harbor runs `t3 service install` and nothing else. It writes no unit, enables no unit, sets no bind address, port, or environment, and adds no `network-online.target` gate. The unit lane asserts this by failing if any shim invocation writes under `~/.config/systemd/user/`.

**Tests.** The healthy no-op path makes zero shim calls; `not-installed` produces a `created` entry ending `applied`; `update-pending` produces a `modified` entry; `unknown` exits 3 with no entry and no vendor call; a `t3 service install` that fails leaves the entry `prepared` and exits 2; one that succeeds but leaves `is-active` reporting `inactive` leaves the entry `prepared` and exits 2 naming both readings; `HARBOR_FAIL_AFTER` at the boundary leaves a `prepared` entry that recovery decides through `harbor_observe_op_t3_service`; the vendor-lifecycle assertion above.

**Commit:** `feat(t3): journaled vendor service install`

### Task 12: `harbor service`

**Files:**

- Modify: `lib/t3.sh`, `bin/harbor` (dispatch and usage)
- Test: `tests/unit/lib/t3.bats`

**Contract (spec section 3.2).** `harbor service <start|stop|restart|status|logs>` "prints the vendor command it runs and runs it" — it is a labelled pass-through, not a wrapper with policy. It prints the exact argv it is about to run, runs it through `harbor_t3_run`, passes the vendor's output and exit code straight through, and journals nothing: none of the five is a Harbor mutation with an inverse. An unknown verb exits 3 with usage. `harbor service` needs no lock, because it holds no state and writes no journal; say so in a comment, since every other operator command takes one.

**Tests.** Each of the five prints the vendor command and then invokes exactly it, with argv asserted from the shim log; the vendor's exit code is the command's exit code for 0, 1, and 3; an unknown verb exits 3 without a vendor call; no journal entry is written by any of them; no lock is acquired, asserted by the absence of `lock.d` afterwards.

**Commit:** `feat(service): labelled pass-through to the vendor service commands`

### Task 13: The provision-time engines check wired to the installed package

**Files:**

- Modify: `lib/t3.sh`
- Test: `tests/unit/lib/t3.bats`

**Interfaces produced:**

```text
harbor_t3_require_engines HOME -> 0, or exit 3 naming which comparison failed
```

**Contract.** Compose Task 3 and Task 9: read the installed package's `engines.node`, read the Node version the operator's shell actually resolves (`sh -lc 'node --version'`, which is what T3's service launcher will see), and hand both to `harbor_versions_require_installed_engines`. This is the check spec section 2 says "`lib/versions.sh` repeats at provision time against the installed `t3` package's own `engines.node`". The reason it reads the operator's resolved Node rather than `/opt/harbor/node/bin/node` is that the service launcher runs without an interactive profile and a shadowed `node` on the operator's `PATH` is exactly the failure this catches — and PR 3's root-side probe was report-only, so this is the first place it is enforced.

**Tests.** Matching range and satisfying Node passes; a Node version that does not satisfy the installed range exits 3 naming the version, the range, and the package path; an installed range that differs from the locked `t3_engines_node` exits 3 naming both even when Node satisfies each; a `sh -lc 'node --version'` that fails exits 3 naming the operator's profile as the thing to fix, not a reinstall.

**Commit:** `feat(t3): enforce the installed package's engines range at provision time`

---

## Slice 4d: T3 Connect login

### Task 14: The connect-status adapter

**Files:**

- Modify: `lib/t3.sh`
- Create: `tests/fixtures/t3/connect-status/healthy`, `needs-login`, `needs-link`, `relay-missing`, `relay-unsupported`, `unparseable`
- Test: `tests/unit/lib/t3.bats`

**Interfaces produced:**

```text
harbor_t3_connect_status HOME
    -> sets HARBOR_T3_CONNECT_DESIRED, _AUTHENTICATED, _LINKED, _RELAY to
       "true" | "false" | "unknown" (and _RELAY to the vendor's own status word
       or "unknown"); returns 0 always, because "unknown" is an answer
```

**Contract (spec section 5.5).** Read `t3 connect status --json`. The pinned adapter reads exactly four things — `desired`, `authenticated`, `linked`, and `relayClient.status` — and ignores the rest. Unparseable output is `unknown` across the board. `lib/` has no `jq`, so the JSON is parsed with the same anchored `sed`-based extraction `lib/journal.sh` already uses for its own fields, and a body that does not yield a value for a key sets that key `unknown` rather than empty.

Reading only four keys is not laziness: it is the spec's own instruction, and it means a vendor adding fields cannot change Harbor's classification.

**Tests.** Each fixture yields its recorded four values; `unparseable` and an empty body yield four `unknown`s; a body missing `relayClient` entirely yields `unknown` for the relay and the real values for the other three; a non-zero exit with a valid body still parses, and the test records that the body wins over the exit code here (unlike the service adapter) because this command has a documented JSON contract; the raw body never reaches stdout.

**Commit:** `feat(t3): version-pinned connect status adapter`

### Task 15: `harbor auth connect`, the login step

**Files:**

- Modify: `lib/t3.sh`, `lib/auth.sh` (dispatch), `bin/harbor` (usage)
- Test: `tests/unit/lib/t3.bats`, `tests/unit/lib/auth.bats`

**Contract (spec section 3.6).** Operator-run, unprivileged, root refused. Runs `t3 connect login` when `authenticated` is false — over SSH the CLI uses its out-of-band URL-and-code flow, so Harbor passes the vendor's output straight to the terminal and never pre-answers a prompt. Then re-read the status and write an `auth` entry (target `connect`) only on a false-to-true `authenticated` transition, by the same rule Task 8 established for the agents.

**PR 4 stops at the login.** When `authenticated` is true and `linked` is false, this release reports `needs_connect_link`, names `harbor auth connect` on PR 5 as what performs it, and exits 1. It does **not** run `t3 connect link` and does **not** write a `t3-connect-link` entry — that step and that entry are spec section 8 row 5. A comment at the branch says so and names the row, so a reader does not take the gap for an omission.

**Tests.** `authenticated` false then true writes one `auth` entry and exits 0; false then still false writes nothing and exits 1 naming the rerun; already true with `linked` true is exit 0 with no entry and no vendor call; already true with `linked` false is exit 1 reporting `needs_connect_link` with no vendor call and no entry; `unknown` either side is exit 1 with no entry; root exits 3; the vendor's login output reaches stdout unchanged; no `t3 connect link` invocation appears in the shim log in any scenario.

**Commit:** `feat(auth): T3 Connect login with the transition-only auth entry`

### Task 16: `lib/config.sh`

**Files:**

- Create: `lib/config.sh`
- Test: `tests/unit/lib/config.bats`

**Interfaces produced:**

```text
harbor_config_path HOME          -> "<HOME>/.config/harbor/config"
harbor_config_create HOME MODE   -> creates the file 0600 with access_mode=MODE; one file entry
harbor_config_access_mode HOME   -> the configured mode, or exit 3 naming the file
```

**Contract (spec sections 3.3 and 5.4).** `~/.config/harbor/config` carries `access_mode`, mode `0600`. Exactly one mode is active. The file is one `key=value` per line, no quoting, the same shape `versions.lock` and the probe record use. Creation is one journaled `file` entry through the existing `harbor_observe_file`, so it is decidable by recovery like every other file Harbor writes.

Validation: `connect` is the default and is accepted. `tailnet` is **refused with exit 3** in this release, naming that `harbor pair` (spec section 8 row 5) does not exist yet, so a `tailnet` node cannot be provisioned by PR 4 — a refusal rather than a silent downgrade to `connect`, because silently provisioning the wrong access mode is worse than not provisioning. Any other value exits 3 naming the file, the value, and the two words. A file whose mode is not `0600` exits 3 without reading it.

**Tests.** Creation writes `0600` and one `created` entry; a rerun with the same mode writes an `observed` entry and does not rewrite the file; a rerun with a different mode writes a `modified` entry; `tailnet` exits 3 naming PR 5's command; an unknown mode exits 3; a `0644` file exits 3 before its contents are read, asserted by a fixture whose contents would otherwise parse; a missing file exits 3 naming `harbor provision`.

**Commit:** `feat(config): the access_mode configuration file`

---

## Slice 4e: provision, the record, and the lanes

### Task 17: `node/provision.sh` skeleton and preflight

**Files:**

- Create: `node/provision.sh`
- Modify: `bin/harbor` (dispatch `provision`, usage)
- Test: `tests/unit/node/provision.bats`

**Contract (spec section 5.4, Preflight row, in the table's order).** The order is the order in which nothing is touched before whatever would touch it is proved sound, and none of it is skipped or reordered:

1. Not root. A root caller exits 3 naming the operator, **before anything is created**.
2. Executing from the recorded release (spec section 5.2), through the existing `harbor_entrypoint_check`.
3. `BackendState` is `Running`, through the existing `harbor_auth_backend_state`. Otherwise **exit 1**, not 3: `needs_tailscale_login` naming `harbor auth tailscale` on a Harbor-installed Tailscale, or the owner's own `tailscale up` on a pre-existing one, read from `bootstrap.json`'s `tailscale_ownership`.
4. `Linger=yes`. If linger is off, print the exact root command and **exit 3** — the spec says so explicitly, and it is 3 rather than 1 because provision cannot proceed at all without a user manager.
5. Create `~/.local/state/harbor/` at `0700` if absent — **immediately before acquiring the lock**, which is where section 3.7 puts it ("created by the first command of its principal that needs the lock, immediately before acquisition"), and therefore before any journaling, since the lock lives in it.
6. Lock parses; operator command lock held.
7. `sh -lc 'node --version'` satisfies `t3_engines_node`.
8. Journal recovery clean.

**Why the creation is step 5 and not step 1.** Section 5.4's table lists the creation first in its prose, but its constraint is "before any journaling", and section 3.7's is "immediately before acquisition" — neither says before every check. Putting it first would make a refused preflight mutate: root running `harbor provision` would create a state root under root's home and only then be told it is the wrong principal. Every cheap non-mutating refusal therefore runs first, which is also what the shipped `harbor auth tailscale` already does — `harbor_auth_refuse_root` runs before `harbor_state_root_create`, and `assert_auth.sh` proves the creation lands between the refusals and the lock. Provision is that command's twin and must not disagree with it.

The dispatcher sources this file with the provision arguments rather than executing it, exactly as it does `node/bootstrap.sh`, because an installed release carries it `0644`.

**Tests.** Each precondition fails in isolation with the stated exit code and message and mutates nothing; the state root is created `0700` before the lock, asserted positionally with `HARBOR_FAIL_AFTER=lock-gate`; the checks run in table order, asserted from the log; a root caller exits 3 before the state root is created; the whole preflight on a healthy fixture passes and reaches the first row.

**Commit:** `feat(provision): the operator preflight in table order`

### Task 18: The provision rows in table order

**Files:**

- Modify: `node/provision.sh`
- Test: `tests/unit/node/provision.bats`

**Contract (spec section 5.4, remaining rows).** Each row is one journaled transaction and each is decided by inspection first, so a rerun on a healthy node makes no mutating vendor call:

| Row | What it calls | Exit contribution |
| --- | --- | --- |
| Journal and config | `harbor_journal_init`, `harbor_config_create` | 3 on an invalid mode |
| Runtime install | `harbor_agents_install` for `claude` then `codex` | 2 on a failed install |
| Runtime auth | `harbor_agents_auth_status` for each; report `needs_login` per CLI when `logged-out`, `unknown` when the adapter says so, and `auth_status_unsupported` when it says so | 1 attended on `logged-out` and `unknown`; **0** on `logged-in` and on `unsupported` |
| T3 install | `harbor_t3_install`, then `harbor_t3_require_engines` | 2 or 3 |
| Vendor service | `harbor_t3_service_install` | 2 on failure, 3 on an `unknown` pre-state |
| Access mode | `harbor_config_access_mode`, then `harbor_t3_connect_status` and the four-way `connect` classification of the scope fence above | 0 when healthy; 1 attended on `needs_connect_login`, `needs_connect_link`, `degraded`, or `unknown` |
| State record | Task 19 | 2 on failure |

**Why `unsupported` contributes 0 and not 1.** `unsupported` means the pinned release ships no documented machine-readable status command for that tool (Task 7). It is a permanent property of the pinned versions, not a state of this node, and there is no command the operator can run to change it — so reporting it as attended would demand attention that nothing can satisfy and would make exit 0 permanently unreachable on that toolset, which is the same defect as the deferred access-mode row above. Provision reports it once as a plain informational line naming which tool and that Harbor cannot verify its login, and contributes 0. The rule this follows, and the one every attended note in this table obeys: **attended means there is a command the operator can run.**

`harbor auth <agent>` (Task 8) still exits 1 on `unsupported`, and the two are consistent rather than contradictory: there the operator explicitly asked Harbor to verify a login transition and Harbor could not, which is a real answer to a real request. Provision asked nothing of the sort.

Provision exits 0 when every unattended step holds and 1 when an attended step is still needed, naming it — reuse `harbor_bootstrap_degraded`'s shape as `harbor_provision_attended`, collecting the notes and repeating them at the end where they are not buried under the rows that ran after.

**Tests.** A healthy fixture — both agents logged in, `t3` installed, the service active, and the `connect` status fixture healthy — runs every row and **exits 0**, which is the case that proves exit 0 is reachable at all; the same fixture with `authenticated` false exits 1 naming `harbor auth connect`; with `linked` false exits 1 naming the PR 5 link step; with `relayClient.status` of `missing` exits 1 carrying the vendor's own text; with an unparseable connect body exits 1 as `unknown` and never as a pass; an agent reporting `logged-out` exits 1 naming that CLI's `harbor auth`; a rerun makes zero mutating shim calls and writes no new `created` or `modified` entry; each row's failure exits with its stated code, leaves its entry `prepared`, and does not run the rows after it; the attended notes are repeated at the end; the row order matches the table, asserted from the log.

**Commit:** `feat(provision): the section 5.4 rows in table order`

### Task 19: `installed.lock` and `provision.json`

**Files:**

- Modify: `node/provision.sh`, `lib/state.sh`
- Test: `tests/unit/lib/state.bats`, `tests/unit/node/provision.bats`

**Interfaces produced:**

```text
harbor_state_installed_lock_render          -> the 13-key lock as observed, one key=value per line
harbor_state_installed_lock_write PATH      -> writes that render to PATH 0600 via a temp-and-rename
harbor_state_provision_record PATH TIMESTAMP ACCESS_MODE ACCESS_STATE SERVICE_STATE
                                CLAUDE_AUTH CODEX_AUTH
    -> writes provision.json 0600, reading the installed versions from the same
       observers harbor_state_installed_lock_render uses, plus tailscale_ownership
       from bootstrap.json
```

**Contract (spec sections 5.4 and 5.7).** `installed.lock` is a copy of the lock **as installed** — the versions actually on the node, not the file this run read — so a later `versions.lock` edit cannot retroactively change what the record says was installed. That makes the source of every key load-bearing, and none of them may be copied from the desired lock:

| Key | Observed from |
| --- | --- |
| `claude_code_version`, `codex_version` | `harbor_agents_installed_version` for each |
| `t3_version` | `harbor_t3_installed_version` |
| `t3_engines_node` | `harbor_t3_package_engines`, the **installed** package's own range (Task 9) |
| `nodejs_version` | `sh -lc 'node --version'`, the Node the service launcher will resolve — the same reading Task 13 enforces against — **normalized to the bare form** by stripping the leading `v`, exactly as `harbor_node_installed_version` (`lib/node.sh:19`) already does, since the lock spells it `24.20.0` and the CLI prints `v24.20.0` |
| `tailscale_version` | `harbor_apt_installed` on the pinned package, reading `HARBOR_APT_VERSION` — what dpkg says is on the node, **not** `bootstrap.json` (see below) |
| `ubuntu_release` | `/etc/os-release` `VERSION_ID` |
| `claude_code_install`, `codex_install`, `t3_install`, `nodejs_install`, `nodejs_sha256`, `tailscale_apt_channel` | copied from `versions.lock`, because a **method** is not observable after the fact; the installed *version* beside it is the observed check on whether the method did what it said |

Node.js and Tailscale are in the record even though provision installs neither: PR 8's upgrade and PR 7's `versions.drift` row compare against this file, and a lock that omitted what root installed would make them compare a partial snapshot against a whole one.

**Why Tailscale is read from dpkg and not from `bootstrap.json`.** The obvious source is the `tailscale_version` that #81 added to the bootstrap record. It is the wrong one, and the reason is a rule that PR deliberately put in `harbor_state_record_render` (`lib/state.sh:55`): when the ownership is `pre-existing`, the version is blanked, because Harbor will not have its record name the version of an installation it does not hold. That blank is correct there and fatal here — copying it would make provision either write an empty key into a schema that forbids empty keys, or exit 2 on a node that is perfectly supported. A pre-existing Tailscale is a supported configuration, not a defect.

`installed.lock` asks a different question from `bootstrap.json`: not "what did Harbor install" but "what is on this node". dpkg answers that identically for all three ownerships, needs no privilege, and needs nothing from root's record. So the row reads the package.

What `bootstrap.json` is still needed for is the ownership word itself, which dpkg cannot know. `provision.json` carries `tailscale_ownership` beside the version — not `installed.lock`, whose schema is the thirteen keys of section 2 and takes no fourteenth — so PR 7's drift row and PR 8's upgrade can tell whether the version they are looking at is Harbor's to change. A version with no ownership beside it would invite exactly the mistake `harbor_state_record_render` refuses to make.

An observed value that disagrees with `versions.lock` is **not** an error here: recording the disagreement is the point, and Tasks 3 and 13 are where a disagreement that matters is refused. A key that cannot be observed at all is exit 2 naming the key and the reading that failed, never an empty value, because an empty key in this file would read to PR 7 and PR 8 as "nothing installed".

`provision.json` carries the same installed versions, `tailscale_ownership`, the service state, the access mode with its classification, the two agent auth words, and a `timestamp`.

**The `timestamp` field ships from the start and is not optional.** Spec section 5.7's operator finalization "compares against it" by deciding between the newest `<state-root>.journal.<timestamp>.done` sibling and the record, so a record written without it in PR 4 would make PR 8's finalization undecidable on every node provisioned by this release. Reuse `harbor_state_record_timestamp`, which PR 3 already defined for `bootstrap.json`, so the two records are comparable by construction rather than by two independent spellings of "now".

Both files are `0600` (they live in the `0700` operator state root and name no secret, but the operator record has no reason to be world-readable the way root's `0644` `bootstrap.json` does — root's is `0644` so operator `status` can read it without root, and nothing needs to read this one without being the operator).

**Tests.** Both files are written with mode `0600`. `installed.lock` carries all thirteen keys with none empty; each observed key equals what its observer reports and **not** what `versions.lock` says, proven by a fixture whose installed versions deliberately differ from the lock's; an unobservable key exits 2 naming the key rather than writing an empty value; the six method keys are copied verbatim from `versions.lock`. A `node --version` printing `v24.20.0` records `24.20.0`, asserted directly, because an unstripped `v` would make a healthy node read as drift against the lock in PR 7 and PR 8; every observed version key is asserted to match the anchored bare-version shape `versions.bats` already uses, so no other reader can reintroduce a vendor prefix. The Tailscale row equals what dpkg reports and is non-empty **on a `pre-existing` node**, whose `bootstrap.json` blanks its own `tailscale_version` by design — the case that would otherwise write an empty key or exit 2 on a supported node; the same fixture asserts `provision.json` carries `tailscale_ownership: pre-existing` beside it, and a `harbor-installed` fixture asserts both rows again. An absent `bootstrap.json` exits 3 naming `sudo harbor bootstrap`, which is the existing precondition, not exit 2. `provision.json` parses and carries every field; the `timestamp` is present, is the `harbor_state_record_timestamp` format, and a fixture asserts the exact key name PR 8 will read. The record is written **last**, after every row, asserted with `HARBOR_FAIL_AFTER` at the boundary before it. A rerun rewrites both and leaves no other difference. Both writes are temp-and-rename, so a record is either the previous one or the new one and never a half-written file.

**Commit:** `feat(provision): installed.lock and the provision record`

### Task 20: The integration lane

**Files:**

- Create: `tests/integration/assert_provision.sh`
- Modify: `.github/workflows/integration.yml`, `tests/integration/stub/*` (a `t3` stub, `claude` and `codex` stubs)

**Contract (spec section 7).** After the existing bootstrap job, run `harbor provision` as the real operator through `runuser -u <operator> --` — never `sudo -E` — with the shim `PATH`. What the lane actually executes: the real journal and config writes at the real operator paths, real `installed.lock` and `provision.json`, real linger and a real `systemctl --user` against the operator's manager, and a shimmed `t3 service install` that produces a **real active user unit** running a trivial loopback listener. What it asserts:

- The installed-entrypoint row of the section 7 test map, asserted through `harbor provision` — that row names PR 4 as the PR that adds it.
- `t3code.service` is `active`.
- The unit file's content equals exactly what the shim's `service install` wrote (spec section 7, "Vendor lifecycle untouched"), proving Harbor did not touch it.
- The second run makes zero mutating shim calls and writes no new entries.
- `HARBOR_FAIL_AFTER=<step>` at each row boundary converges on rerun, including between mutation and the `applied` write.
- `~/.local/state/harbor/` is `0700` and was created before the lock, the positional proof `assert_auth.sh` already established for `harbor auth tailscale`.

**Commit:** `ci: integration assertions for the operator provision`

### Task 21: The vendor-smoke T3 half

**Files:**

- Create: `fleet/vendor-smoke/t3_engines_probe.sh`
- Modify: `.github/workflows/vendor-smoke.yml` (a second job beside the Tailscale one)

**Contract (spec section 8 row 4).** The one thing the static lane cannot prove without a network: install the **real** `t3` at the pinned `t3_version` and assert that the installed package's own `engines.node` equals the locked `t3_engines_node` byte for byte. Also run the real `t3 service status` on a node where the service is not installed and assert the adapter classifies it `not-installed` rather than `unknown`, which is the "smoke: adapter classifies real output" cell of the "Vendor status honesty" row.

Follow the shape `tailscale_operator_probe.sh` established, and reuse its two hard-won properties: publish a record on **every** exit path including a `set -e` death (a `cleanup` EXIT trap guarded by a `published` flag), and never let a vendor byte reach the record, the step summary, or the job log — classify against markers this file chose and emit only words this file chose. Add the job to the existing workflow with the same `permissions: contents: read`, `timeout-minutes`, weekly schedule, `workflow_dispatch`, and `paths`-filtered `pull_request` triggers, and upload its record with `if: always()`.

**Commit:** `ci: vendor-smoke proof of the installed t3 engines range`

### Task 22: Final verification and the PR

**Contract.** The full unit lane under both shells; every static check; the integration lane green; the vendor-smoke lane green once; the diff read against the file map; the acceptance list of spec section 8 row 4 checked item by item (`t3code.service` active in the lane; smoke lane green once). The PR body states the changed-line count, the pinned values with the commands that produced them, which agents turned out to have a documented machine-readable auth status and which are `unsupported`, and the scope fence above — specifically that `t3 connect link` and the `tailnet` access mode are refused rather than half-implemented, and which PR 5 row completes each.

---

## Decisions taken, 2026-09-09

Both were put to the owner before any task was implemented, and both were settled the way this plan proposed. They are recorded here rather than left as questions, because 22 tasks are built on them.

1. **`access_mode=tailnet` is refused with exit 3**, not accepted and reported unprovisioned. `harbor pair` ships in PR 5, and a config that says `tailnet` on a node whose access is unconfigured would read as provisioned to PR 7's `harbor status`. A loud refusal beats a silent wrong state. Task 16 holds this.
2. **The npm prefix is `~/.local/harbor/npm`**, segregated from any prefix the operator already uses, rather than the conventional `~/.local`. Spec section 6.1 says Harbor never mutates what it did not create, and a shared prefix cannot guarantee that: a Harbor install could overwrite a package the operator installed themselves. The cost is that the prefix is not on a default `PATH`, so every Harbor invocation of these CLIs names the path explicitly rather than relying on resolution — which Tasks 5, 6, and 9 already do, since they take the home root as a parameter and never read `$HOME`.

## Open questions for the owner

1. **Task 2's pinned values are a review point in their own right**, as PR 3's Task 1 was: they set the agent and T3 versions the node will run. The commands that produce them are in Task 2 and their verbatim output goes in the handoff, so the review is against measured values, not asserted ones.
