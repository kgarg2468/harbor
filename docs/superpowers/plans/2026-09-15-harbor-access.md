# Harbor Remote Access (PR 5) Implementation Plan

> **For agentic workers:** implement this plan task by task. Implementation workers never commit, push, or open a pull request: every task ends in the handoff described under "Working conventions", and the orchestrator commits after its own gate. Where a skill's own flow says to commit, this plan wins.

**Goal:** Ship PR 5 of Harbor, design section 8 row 5: the node-to-desktop route. Three access modes become real — `connect` gains its link step, `tailnet` gains `harbor pair` with Harbor's own Serve pre-check and the `t3.environment` descriptor check, `ssh` gains its Node precondition check — and `harbor access set <mode>` switches between them, reverting the previous mode's journal entries first.

**Architecture:** One new adapter library and two new command libraries, all bash 3.2. `lib/serve.sh` owns everything about Tailscale Serve: normalizing `tailscale serve status` into a comparable mapping object, detecting any Funnel exposure, and the `tailscale-serve` journal op. `lib/t3.sh` grows the pieces that locate this node's own T3 server — the pinned `server-runtime.json` reader and the `/.well-known/t3/environment` descriptor fetch — and the environment check that compares the loopback descriptor with the MagicDNS one. `lib/pair.sh` owns `harbor pair`: Harbor inspects and decides before the vendor is ever invoked, predicts the exact mapping the vendor will create, journals that prediction, and verifies afterwards. `lib/access.sh` owns the mode itself. Nothing here invents a transport, and nothing here mutates a Serve mapping Harbor did not create.

**Tech Stack:** bash 3.2 for `fleet/lib/`, bash 5 for `fleet/node/`, Bats, the PR 2 shim skeleton, GitHub Actions (`lint.yml`, `test.yml`, `integration.yml`, `vendor-smoke.yml`).

> **Layout:** unchanged. Harbor's code lives under `fleet/`; documents, `.github/workflows/`, `.gitleaks.toml`, and `.markdownlint.yml` stay at the repository root. Every code path below is relative to `fleet/` unless it starts with `docs/` or `.github/`.

---

## Measured vendor facts

Every value in this section was read out of the installed pinned package, not assumed. Plan correction 33 in the PR 4 plan is why: a fixture written from Harbor's own code agrees with Harbor by construction and with the vendor only by luck, and that is exactly how `harbor_t3_package_dir` shipped a path npm has never used. Reproduce the whole table with:

```bash
npm install --global --prefix /tmp/t3probe --registry=https://registry.npmjs.org \
  --userconfig=/tmp/t3probe/npmrc.user --globalconfig=/tmp/t3probe/npmrc.global \
  --cache /tmp/t3probe/cache --no-audit --no-fund t3@0.0.38
```

Then read `/tmp/t3probe/lib/node_modules/t3/dist/bin.mjs`. Every fact below carries the source string to grep for.

| Fact | Value at `t3_version=0.0.38` | grep for |
| --- | --- | --- |
| T3 base directory | `$T3CODE_HOME`, else `~/.t3` | `resolveBaseDir` |
| State directory | `<baseDir>/userdata` (the `dev` sibling only when `devUrl` is set, which Harbor never sets) | `deriveServerPaths` |
| Runtime state file | `<stateDir>/server-runtime.json`, i.e. `~/.t3/userdata/server-runtime.json` | `serverRuntimeStatePath` |
| Runtime state schema | `{version: 1, pid: Int, host?: String, port: Int, origin: String, devUrl?: String, startedAt: String}` | `PersistedServerRuntimeState` |
| Runtime state encoding | `JSON.stringify(state)` plus one `\n` — **one line, not pretty-printed** | `persistServerRuntimeState` |
| `origin` construction | `http://${host, unless wildcard, else 127.0.0.1}:${port}` | `runtimeOriginForConfig` |
| Default server port | `3773` | `DEFAULT_PORT` |
| Descriptor path | `/.well-known/t3/environment` | `WELL_KNOWN_ENVIRONMENT_PATH` |
| Descriptor schema | `{environmentId, label, platform, serverVersion, capabilities: {...}}` | `ExecutionEnvironmentDescriptor` |
| Serve creation by the vendor | `tailscale serve --bg --https=443 http://127.0.0.1:<port>` | `runTailscaleCommand(args, TAILSCALE_SERVE_TIMEOUT)` |
| Serve removal by the vendor | `tailscale serve --https=443 off` | `disableTailscaleServe` |
| Serve port default | `443` | `input.servePort ?? 443` |
| Serve local host default | `127.0.0.1` | `input.localHost ?? "127.0.0.1"` |

**The encoding difference matters and is a trap.** `t3 connect status --json` is emitted by `JSON.stringify(x, null, 2)`, which is why `harbor_t3_connect_status` reads whole indented lines and fences the document with `{` alone on the first line and `}` alone on the last. `server-runtime.json` is emitted by `JSON.stringify(state)` with no indent argument: the entire object is **one line**. A reader copied from the connect adapter will match nothing and report every field unknown on a perfectly healthy node. Task 5 reads it as one line on purpose and its first test is a real capture, not a hand-written pretty-printed file.

**Why Harbor reads `port` and not `origin`.** Both are in the file. `origin` is a URL Harbor would have to parse, and its host is already normalized by the vendor to `127.0.0.1` only when the configured host is a wildcard — a non-wildcard non-loopback `host` reaches `origin` unchanged. Harbor needs the loopback identity, and section 5.5 requires the normalization to treat `localhost`, `127.0.0.1`, and `::1` as one. So Harbor reads `port` as the number it is and applies its own loopback canonicalization, and reads `host` only to refuse a server that is not on loopback at all. Task 5 holds this.

---

## Scope fence: what PR 5 ships and what it does not

| Concern | PR | Why |
| --- | --- | --- |
| `harbor auth connect` link step and the `t3-connect-link` entry | **5** | Row 5 names it; PR 4 left `t3.needs_connect_link` as an explicit `harbor_die 1` saying so (`lib/t3.sh:317`) |
| `harbor access get`, `harbor access set <mode>` | **5** | Row 5 |
| `ssh` as an accepted `access_mode` | **5** | `harbor_config_validate_mode` knows only `connect` and `tailnet` today; section 3.3 has three modes and `ssh` has never been accepted |
| `harbor pair`, Serve inspection, prediction, the `tailscale-serve` op | **5** | Row 5 |
| The `t3.environment` descriptor check | **5** | Row 5 |
| Funnel detection | **5** | Row 5; section 3.3 makes any Funnel exposure exit 2 |
| `harbor status` and `harbor doctor` | **7** | Row 7. PR 5 produces the identifiers (`t3.environment`, `tailscale.serve`, `service.t3`, `tailscale.running`) as **functions with words**, and provision's rows consume them; the `status` command that lists them is PR 7's |
| `harbor client verify` per-mode checks | **6** | Row 6, which depends on PR 5 only for the mode semantics this plan fixes |
| `harbor teardown` reverting access entries | **8** | Row 8. PR 5 ships `harbor access set`'s **own** revert, which is the same journal walk scoped to one mode's ops, and Task 17 writes it so PR 8 can reuse it |

**What PR 5 deliberately does not do.** It never runs `tailscale funnel`, in any code path, for any reason — Task 3 asserts the string appears nowhere under `lib/` except in a refusal message. It never runs `tailscale serve reset`. It never removes a Serve mapping it did not create: removal is PR 8's, and even there it is gated on `created` ownership and an exact match. A foreign mapping is reported with the vendor command that would remove it, and Harbor mutates nothing.

---

## The two revalidations, and the gate they control

Spec section 8 row 5 makes PR 5 responsible for two measurements against the exact pinned versions, and records both in the PR body.

**Revalidation A — the node can fetch its own MagicDNS Serve descriptor.** The `t3.environment` check compares the loopback descriptor with the one at `https://harbor-node.TAILNET.ts.net/.well-known/t3/environment`, which requires the node to reach *itself* through its own MagicDNS name and its own Serve mapping. Section 5.5: "if it cannot, `tailnet` mode is unsupported at those versions, `harbor provision --access-mode tailnet`, `harbor access set tailnet`, and `harbor pair` exit 3 naming the limitation, and `t3.environment` is never silently reported as pass or `unknown` in its place."

**Revalidation B — the pinned `t3 pair --tailscale` guard.** The upstream command carries its own descriptor guard and reuses an existing mapping only when it reaches the same environment. Harbor's pre-check is authoritative and does not rely on it, but section 5.5 requires PR 5 to record what the pinned version actually does, so that a future version changing it is a change Harbor noticed.

**Neither can run in CI.** The integration lane has no Tailscale account, no tailnet, and no MagicDNS name; its `tailscale` is a stand-in that never logs in, by design. Both revalidations are therefore **attended measurements on a real node with a real tailnet**, performed once and recorded verbatim in the PR body, exactly as PR 3 recorded the `--ssh` probe. Task 20 is that task, it produces `fleet/vendor-smoke/tailnet-environment.probe` in the same recorded-result format as `fleet/vendor-smoke/tailscale-ssh.probe`, and `lib/access.sh` reads that file to decide whether `tailnet` is a supported mode.

**This is a real dependency on the owner**, and the plan is written so that nothing else waits on it: `tailnet` ships gated by default, every `tailnet` code path is fully implemented and fully unit-tested behind the gate, and flipping the recorded result to `supported` is a one-line change to a data file plus a rerun of the lane. Tasks 1 to 19 and 21 do not depend on Revalidation A at all.

---

## Slices

PR 5's scope is far past the 600-line guideline, so it ships as five stacked pull requests, each independently green and independently reviewable. Each slice's branch is based on the previous one.

| Slice | Branch | Contents | Tasks |
| --- | --- | --- | --- |
| 5a | `feat/access-serve` | `lib/serve.sh`: the `tailscale serve status` adapter, mapping normalization, Funnel detection, the `tailscale-serve` observer | 1 to 4 |
| 5b | `feat/access-environment` | The pinned runtime-state reader, the descriptor fetch, and the `t3.environment` check in `lib/t3.sh` | 5 to 8 |
| 5c | `feat/access-connect-link` | `harbor auth connect`'s link step, the `t3-connect-link` entry, provision's completed `connect` row | 9 to 11 |
| 5d | `feat/access-pair` | `lib/pair.sh`: the pre-check, the prediction, the journaled transaction, the post-verify, `harbor pair` | 12 to 15 |
| 5e | `feat/access-modes` | `lib/access.sh`, `harbor access get\|set`, the `ssh` mode, provision's `tailnet` and `ssh` rows, the dispatcher, the revalidations, the lanes, final verification | 16 to 21 |

## Global constraints

Everything in the PR 2, PR 3, and PR 4 plans' constraints still binds. Restated because every task's requirements implicitly include this section:

- **Shell floor (spec section 2):** bash 3.2 subset for everything under `lib/`. No `readlink -f`, no associative arrays, no `mapfile`, no `${var^^}`, no `+=` on arrays, no extglob, no `[[ ]]`, no `=~`, no `printf -v`. No `case` statement lexically inside `$( )` — bash 3.2's parser takes the `)` closing a case pattern as the one closing the substitution (Correction 26). `node/` may use bash 5; write it in the 3.2 subset anyway so the unit lane can source it on the pinned `macos-14` runner.
- **Locale and collation (Correction 19):** enumerate characters (`*[!0123456789]*`) rather than using ranges; digit ranges `[0-9]` are the one safe exception.
- **Exit codes (spec section 6.2):** 0 success, 1 degraded or attended, 2 broken or apply failed, 3 precondition or usage, 4 interrupted.
- **Principal (spec section 3.1):** every path in PR 5 runs as the **operator**. No script in this PR calls `sudo`, `runuser`, or `su`, or writes outside `$HOME`. A command that finds itself root exits 3 through `harbor_auth_refuse_root`.
- **Journal write protocol (spec section 3.7):** inspect, write a `prepared` entry, mutate, mark `applied`. Every mutation is one transaction. A failed mutation leaves its entry `prepared` and says so.
- **Idempotency (spec section 6.1):** every step is defined by its inspection first. A second run makes zero mutating vendor calls and writes no new `created` or `modified` entry. **A rerun never mints a pairing token** (section 3.6) — Task 14 proves it by counting `t3 pair` invocations in the shim log.
- **Never mutate what Harbor did not create (spec sections 3.3 and 6.1):** Harbor removes only Serve mappings it created whose current normalized state equals the journaled `post_state`. An `observed` mapping is never converted to `created`, never rewritten, and never removed. Task 13 proves the `observed` case makes zero `tailscale serve` mutating calls.
- **No Funnel, ever (spec section 3.3):** Harbor never invokes `tailscale funnel`. Any Funnel exposure on any port, whoever created it, is exit 2.
- **Secret handling (spec section 3.8):** no secret ever reaches a command line. The pairing URL and QR code go straight to the terminal and are never captured, logged, journaled, persisted, or bundled. **The environment IDs are never logged, journaled, persisted, or bundled** (section 5.5) — they are compared in memory and discarded. Task 8 asserts no ID reaches the log file, the journal, or stdout.
- **Vendor lifecycle untouched (spec sections 3.2 and 7):** Harbor never writes under `~/.config/systemd/user/`, `~/.t3/`, or any T3 home directory, never writes a unit file, and never runs `systemctl --user enable/disable/edit` on `t3code.service`. `~/.t3/userdata/server-runtime.json` is **read only**, never written, never created, never removed.
- **Vendor status honesty (spec sections 3.2 and 7):** unrecognized adapter output classifies as `unknown`, never a guess. `unknown` never counts as a pass. Every adapter is version-pinned and backed by fixtures captured from the pinned release.
- **Unit lane (spec section 7):** unit tests never touch `/var/lib`, `/etc`, `/usr/local`, `/opt`, the real `~/.local/state/harbor`, the real `~/.t3`, or the real `~/.config/systemd/user/`, and never use sudo. Every vendor and system binary is a shim. Every home root is a disposable fixture directory.
- **Static lane:** ShellCheck `-s bash -x -a -S warning -P 'SCRIPTDIR/..:SCRIPTDIR/../..' --enable=require-variable-braces`, shfmt `-i 2 -ci -bn`, `tests/lint/placeholder_scan.sh` **run from the repository root**, `tests/lint/engines_check.sh`, gitleaks, markdownlint. Every new file under `lib/`, `tests/integration/`, and `vendor-smoke/` must be added to **both** lists in `.github/workflows/lint.yml` — the lists name files explicitly and a new file is silently unlinted otherwise (PR 4 shipped three stubs that way and caught it at review).

## Working conventions for every task

- Work in the worktree `/Users/krishgarg/Documents/products/harbor/.worktrees/access`, on the branch named by the slice. Run code commands from `fleet/`; run git and markdownlint from the worktree root.
- Test first: write the failing tests, run them, record the failure verbatim, then write the code until they pass. Run `tests/run_unit.sh` for the whole lane and `tests/run_unit.sh <file>` while iterating. The full lane takes about 27 minutes on macOS; never pipe it through `tail`, which discards failure lines. Count failures with `tests/run_unit.sh 2>&1 | grep -c '^not ok'`.
- Every library function is prefixed `harbor_`, every global `HARBOR_`. Libraries define functions only; they run nothing at source time.
- Two-space indent, braced variables, `case` arms one level in, no space after a redirection operator.
- Every operation that can fail is checked, and the failure says what state the node is in. This has been the single most common defect at the gate.
- **A negative assertion that has never failed is not a test** (Correction 30). `refute_output` cannot fail loudly on a misspelled needle. Where a refutation is load-bearing — "no `t3 pair` ran", "no Serve mutation happened" — assert the positive form of the same string somewhere in the suite, or break the implementation and confirm the assertion goes red. Record which you did in the handoff.
- Each task ends in a handoff: the test commands with their verbatim results, the deviations, `git status --short`, `git diff --stat`, and the concerns worth flagging. The orchestrator gates and commits.
- A handoff with a failing test, a lint finding, or a file outside the task's list is not ready. Say so instead of working around it.

## File map (new files in PR 5)

| File | Responsibility |
| --- | --- |
| `lib/serve.sh` | Tailscale Serve: the `serve status` adapter, mapping normalization including loopback canonicalization, Funnel detection, `harbor_observe_op_tailscale_serve` |
| `lib/pair.sh` | `harbor pair`: the pre-check, the predicted post-state, the journaled `tailscale-serve` transaction around `t3 pair --tailscale`, the post-verify |
| `lib/access.sh` | `~/.config/harbor/config`'s mode as a command: `harbor access get`, `harbor access set <mode>`, the previous mode's revert, the `tailnet` support gate |
| `tests/fixtures/tailscale/serve-status/*` | Captured `tailscale serve status` output: absent, the vendor's own 443 mapping, a foreign 443 mapping, a non-443 mapping, a Funnel exposure, and two unrecognized shapes |
| `tests/fixtures/t3/server-runtime/*` | Captured `server-runtime.json` bodies: the pinned one-line healthy form, a non-loopback host, a missing port, a wrong `version`, and an unparseable one |
| `tests/fixtures/t3/environment/*` | Captured `/.well-known/t3/environment` bodies: a valid descriptor, a second valid one with a different `environmentId`, a non-T3 body, and an empty body |
| `fleet/vendor-smoke/tailnet-environment.probe` | The Revalidation A recorded result, read by `lib/access.sh` to decide whether `tailnet` is supported |
| `tests/integration/assert_access.sh` | The integration assertions for `harbor access get\|set`, the `ssh` mode row, and the gated `tailnet` refusal |

Modified: `lib/t3.sh` (runtime state reader, descriptor fetch, environment check, the link step), `lib/config.sh` (the `ssh` mode, the `tailnet` gate), `node/provision.sh` (the `tailnet` and `ssh` rows), `bin/harbor` (dispatch and usage), `.github/workflows/integration.yml`, `.github/workflows/vendor-smoke.yml`, `.github/workflows/lint.yml`.

---

## Slice 5a: the Serve adapter

### Task 1: `lib/serve.sh` and the normalized mapping

**Files:**

- Create: `lib/serve.sh`
- Create: `tests/fixtures/tailscale/serve-status/absent`, `vendor-443`, `foreign-443`, `non-443`, `funnel`, `garbage`, `empty`
- Test: `tests/unit/lib/serve.bats` (new)

**Interfaces produced:**

```text
harbor_serve_status                  -> captures `tailscale serve status`; sets HARBOR_SERVE_RAW
harbor_serve_loopback_host HOST      -> "loopback" when HOST is localhost|127.0.0.1|::1|[::1], else HOST
harbor_serve_mapping                 -> the normalized HTTPS 443 mapping, or "absent", or "unnormalizable"
harbor_serve_funnel                  -> "none" | "present" | "unknown"
```

**Contract.** The normalized mapping is one string, `https:443 -> http://<canonical-host>:<port>`, where `<canonical-host>` is the literal word `loopback` when the proxy target's host is any of `localhost`, `127.0.0.1`, `::1`, or `[::1]`, and the host verbatim otherwise. Section 5.5 requires this: "Normalization canonicalizes the proxy target's loopback host before any comparison, so `localhost`, `127.0.0.1`, and `::1` are one loopback identity and a spelling difference never fails the prediction." Anything the adapter cannot reduce to that form is `unnormalizable` — never a guess, and never `absent`, because "I could not read it" and "there is nothing there" lead to opposite decisions and must never be spelled the same way.

- [ ] **Step 1: Write the fixtures, and record which of them are evidence**

These are the inputs the adapter must classify. Write them one file each under `tests/fixtures/tailscale/serve-status/`, **and write `PROVENANCE.md` beside them** saying which were measured and which were constructed. That file is not documentation politeness; it is the difference between a fixture that constrains the adapter and a fixture the adapter constrains.

Only one of them is measured. `absent` is byte-exact against a real `tailscale` CLI 1.96.4 talking to a tailscaled 1.98.2 — `No serve config\n` on stdout — and capturing it is what found correction 35. **Every populated-listener fixture below is hand-written**, because applying a Serve config to capture one was attempted and the vendor hung (correction 36). Their layout — one header per listener, handlers indented beneath as `|-- <path> proxy <target>` — is this adapter's assumption and is not vendor-confirmed.

Do not describe them in the fixture file, the commit, or the PR as captured output. An earlier draft of this plan said they were "the shapes `tailscale serve status` prints at `tailscale_version=1.102.3`" while correction 36 in the same document said they were unverified, and a reader who believed the first sentence would have treated a guess as evidence. When a populated body is eventually captured on a real node, move that row from the constructed table to the measured one in `PROVENANCE.md`; do not adjust the parser until the constructed fixtures pass.

`absent` — the empty state, one line, and the only measured fixture here:

```text
No serve config
```

`vendor-443`:

```text
https://harbor-node.TAILNET.ts.net (tailnet only)
|-- / proxy http://127.0.0.1:3773
```

`foreign-443` — a 443 mapping to something that is not this node's T3 server:

```text
https://harbor-node.TAILNET.ts.net (tailnet only)
|-- / proxy http://127.0.0.1:8080
```

`non-443` — a mapping on another port, which is not the mapping this adapter reports:

```text
https://harbor-node.TAILNET.ts.net:8443 (tailnet only)
|-- / proxy http://127.0.0.1:3773
```

`funnel` — a public exposure, which section 3.3 makes exit 2 whoever created it:

```text
https://harbor-node.TAILNET.ts.net (Funnel on)
|-- / proxy http://127.0.0.1:3773
```

`garbage` — output from a version or a state this adapter does not recognize:

```text
tailscale: unrecognized subcommand "serve"
```

`empty` — no output at all, zero bytes.

`mixed-listeners` — a non-443 listener **above** the 443 one. This is the fixture that forces the adapter to walk listeners instead of reading line 1 and grepping the rest; see correction 37:

```text
https://harbor-node.TAILNET.ts.net:8443 (tailnet only)
|-- / proxy http://127.0.0.1:9000
https://harbor-node.TAILNET.ts.net (tailnet only)
|-- / proxy http://127.0.0.1:3773
```

`ambiguous-443` — two root handlers inside one 443 listener, which is not a mapping and must not be reduced to whichever one the parser happens to see last:

```text
https://harbor-node.TAILNET.ts.net (tailnet only)
|-- / proxy http://127.0.0.1:3773
|-- / proxy http://127.0.0.1:9000
```

`no-root-443` — a 443 listener with handlers but no root handler. Something is at 443, so the answer is not `absent`; Harbor cannot describe it, so the answer is not a mapping either:

```text
https://harbor-node.TAILNET.ts.net (tailnet only)
|-- /api proxy http://127.0.0.1:3773
```

- [ ] **Step 2: Write the failing tests**

```bash
@test "the vendor's own 443 mapping normalizes to the loopback form" {
  serve_fixture vendor-443
  assert_equal "$(harbor_serve_mapping)" 'https:443 -> http://loopback:3773'
}

@test "the three loopback spellings are one identity" {
  local spelling
  for spelling in localhost 127.0.0.1 '[::1]'; do
    serve_fixture_body "https://harbor-node.TAILNET.ts.net (tailnet only)
|-- / proxy http://${spelling}:3773"
    assert_equal "$(harbor_serve_mapping)" 'https:443 -> http://loopback:3773'
  done
}

@test "a non-loopback proxy target keeps its host, because it is not this node's server" {
  serve_fixture_body "https://harbor-node.TAILNET.ts.net (tailnet only)
|-- / proxy http://10.0.0.7:3773"
  assert_equal "$(harbor_serve_mapping)" 'https:443 -> http://10.0.0.7:3773'
}

@test "no mapping is absent, and a mapping on another port is also absent at 443" {
  serve_fixture absent
  assert_equal "$(harbor_serve_mapping)" absent
  serve_fixture non-443
  assert_equal "$(harbor_serve_mapping)" absent
}

@test "output this adapter cannot reduce is unnormalizable, never absent" {
  local name
  for name in garbage empty; do
    serve_fixture "${name}"
    assert_equal "$(harbor_serve_mapping)" unnormalizable
  done
}

@test "funnel is detected from the vendor's own word and is not a mapping question" {
  serve_fixture funnel
  assert_equal "$(harbor_serve_funnel)" present
  serve_fixture vendor-443
  assert_equal "$(harbor_serve_funnel)" none
  serve_fixture garbage
  assert_equal "$(harbor_serve_funnel)" unknown
}
```

- [ ] **Step 3: Run the tests and record the failure verbatim**

Run: `tests/run_unit.sh tests/unit/lib/serve.bats`
Expected: every test fails with `harbor_serve_mapping: command not found`. Paste the first failure block into the handoff.

- [ ] **Step 4: Write `lib/serve.sh`**

```bash
#!/bin/bash
# The Tailscale Serve adapter (design sections 3.3 and 5.5). Harbor reads Serve, it
# predicts what the vendor will do to Serve, and it journals that prediction. It
# never calls `tailscale serve` to change anything and never calls `tailscale
# funnel` at all: the v1 invariant is no public inbound exposure, so Funnel is a
# thing this file detects and refuses, not a thing it operates.
#
# Every answer here is one of a fixed set of words. "absent" and "unnormalizable"
# are deliberately different words for deliberately different situations: absent
# means Harbor looked and there is no HTTPS 443 mapping, which is the state in
# which harbor pair may create one; unnormalizable means Harbor could not reduce
# what it read to a mapping it can compare, which is never a licence to act.

# harbor_serve_status: capture `tailscale serve status` into HARBOR_SERVE_RAW.
#
# Stdout only, and the reason is measured rather than reasoned -- see correction
# 35 below. Folding stderr in looks like the careful choice, but this vendor
# writes an unsolicited version-skew warning to stderr, which with 2>&1 becomes
# the first line of the body and makes a healthy node read as unnormalizable.
#
# A non-zero exit is not parsed at all: the exit code is the vendor saying it did
# not answer, and stdout in that case is not a Serve configuration however much it
# may look like one.
harbor_serve_status() {
  local out rc=0
  HARBOR_SERVE_RAW=""
  HARBOR_SERVE_WHY=""
  out="$(tailscale serve status 2>/dev/null)" || rc="$?"
  if [ "${rc}" != 0 ]; then
    HARBOR_SERVE_WHY="tailscale serve status exited ${rc}"
    return 0
  fi
  HARBOR_SERVE_RAW="${out}"
  return 0
}

# harbor_serve_loopback_host HOST: the canonical loopback identity, per section
# 5.5. Four spellings, because tailscale prints the bracketed form for IPv6 inside
# a URL and the bare form elsewhere, and a spelling difference must never fail the
# prediction Harbor journals.
harbor_serve_loopback_host() {
  case "${1}" in
    localhost | 127.0.0.1 | '::1' | '[::1]') printf 'loopback' ;;
    *) printf '%s' "${1}" ;;
  esac
}

# harbor_serve_mapping: the normalized HTTPS 443 mapping, "absent", or
# "unnormalizable". Requires harbor_serve_status to have run.
harbor_serve_mapping() {
  local header target host port
  # An empty body is not an empty config: `tailscale serve status` says so in
  # words when there is nothing configured. Zero bytes means the command did not
  # answer, which is a reading Harbor cannot use.
  [ -n "${HARBOR_SERVE_RAW}" ] || {
    printf 'unnormalizable'
    return 0
  }
  case "${HARBOR_SERVE_RAW}" in
    'No serve config'*)
      printf 'absent'
      return 0
      ;;
  esac
  # The header line carries the port. No :port suffix on the host means 443, which
  # is the port this adapter reports on; an explicit other port is a mapping this
  # adapter does not describe, and at 443 there is nothing.
  header="$(printf '%s\n' "${HARBOR_SERVE_RAW}" | sed -n '1p')"
  case "${header}" in
    'https://'*' ('*')') ;;
    *)
      printf 'unnormalizable'
      return 0
      ;;
  esac
  case "${header}" in
    *.ts.net' '*) ;;
    *)
      printf 'absent'
      return 0
      ;;
  esac
  target="$(printf '%s\n' "${HARBOR_SERVE_RAW}" | sed -n 's|^|-- / proxy \(http://.*\)$|\1|p')"
  [ -n "${target}" ] || {
    printf 'unnormalizable'
    return 0
  }
  host="${target#http://}"
  port="${host##*:}"
  host="${host%:*}"
  case "${port}" in
    '' | *[!0123456789]*)
      printf 'unnormalizable'
      return 0
      ;;
  esac
  printf 'https:443 -> http://%s:%s' "$(harbor_serve_loopback_host "${host}")" "${port}"
}

# harbor_serve_funnel: whether any Funnel exposure exists. Section 3.3 makes this
# exit 2 wherever it is asked, whoever created the exposure, which is why the
# unknown arm exists: a body this adapter cannot read is not evidence of no Funnel.
harbor_serve_funnel() {
  [ -n "${HARBOR_SERVE_RAW}" ] || {
    printf 'unknown'
    return 0
  }
  case "${HARBOR_SERVE_RAW}" in
    'No serve config'*)
      printf 'none'
      return 0
      ;;
    *'(Funnel on)'*)
      printf 'present'
      return 0
      ;;
    'https://'*)
      printf 'none'
      return 0
      ;;
  esac
  printf 'unknown'
}
```

- [ ] **Step 5: Run the tests and confirm they pass**

Run: `tests/run_unit.sh tests/unit/lib/serve.bats`
Expected: all six tests pass.

- [ ] **Step 6: Add `lib/serve.sh` to both lint lists**

In `.github/workflows/lint.yml`, add `fleet/lib/serve.sh` — it is already covered by `fleet/lib/*.sh` in the ShellCheck list and `fleet/lib` in the shfmt list, so **verify** rather than add, and say which in the handoff. Run the CI-exact commands from the repository root and paste the output.

- [ ] **Step 7: Handoff**

Report the test results verbatim, `git status --short`, and `git diff --stat`. Do not commit.

### Task 2: the `tailscale-serve` observer

**Files:**

- Modify: `lib/serve.sh` (append)
- Test: `tests/unit/lib/serve.bats` (append)

**Interfaces consumed:** `harbor_serve_status`, `harbor_serve_mapping` from Task 1; `harbor_journal_observe` from `lib/journal.sh:131`, which dispatches op `tailscale-serve` to `harbor_observe_op_tailscale_serve`.

**Interfaces produced:**

```text
harbor_observe_op_tailscale_serve TARGET -> a JSON string: "absent", "unnormalizable", or the mapping
```

**Contract.** The observer re-reads Serve every time it is called, because journal recovery runs at a different moment than the write did and the whole point is to compare against what is there *now*. Its target is the literal word `https-443`; the op has exactly one target on a node, and naming it makes the entry readable. The return is a JSON string in the same form every other observer uses, so `harbor_journal_recover`'s `observed = pre_state` and `observed = post_state` comparisons work unchanged.

- [ ] **Step 1: Write the failing tests**

```bash
@test "the observer answers the journal's three comparisons in the journal's own form" {
  serve_fixture vendor-443
  assert_equal "$(harbor_observe_op_tailscale_serve https-443)" \
    '"https:443 -> http://loopback:3773"'
  serve_fixture absent
  assert_equal "$(harbor_observe_op_tailscale_serve https-443)" '"absent"'
  serve_fixture garbage
  assert_equal "$(harbor_observe_op_tailscale_serve https-443)" '"unnormalizable"'
}

@test "the observer reaches the journal through its op name, not by being called directly" {
  # The dispatch in lib/journal.sh is what recovery actually uses; a function that
  # is correct but unreachable under its op name decides nothing.
  serve_fixture vendor-443
  assert_equal "$(harbor_journal_observe tailscale-serve https-443)" \
    '"https:443 -> http://loopback:3773"'
}

@test "the observer re-reads rather than answering from the last reading" {
  serve_fixture absent
  assert_equal "$(harbor_observe_op_tailscale_serve https-443)" '"absent"'
  serve_fixture vendor-443
  assert_equal "$(harbor_observe_op_tailscale_serve https-443)" \
    '"https:443 -> http://loopback:3773"'
}
```

- [ ] **Step 2: Run the tests and record the failure verbatim**

Run: `tests/run_unit.sh tests/unit/lib/serve.bats`
Expected: the three new tests fail; the observer test through `harbor_journal_observe` fails with `"unobservable:tailscale-serve"`, which is the fail-closed answer for an op with no observer. Paste it — it is the proof that the dispatch is what the test exercises.

- [ ] **Step 3: Append the observer to `lib/serve.sh`**

```bash
# harbor_observe_op_tailscale_serve TARGET: the tailscale-serve op's observer, found
# by harbor_journal_observe under this exact name. It re-reads Serve on every call
# rather than trusting HARBOR_SERVE_RAW: recovery runs long after the write that
# left the entry prepared, and answering from a stale capture would compare the
# entry against the world as it was when Harbor last looked, which is the one
# reading that cannot decide anything.
harbor_observe_op_tailscale_serve() {
  harbor_serve_status
  printf '"%s"' "$(harbor_json_escape "$(harbor_serve_mapping)")"
}
```

- [ ] **Step 4: Run the tests and confirm they pass**

Run: `tests/run_unit.sh tests/unit/lib/serve.bats`
Expected: all nine tests pass.

- [ ] **Step 5: Handoff**

### Task 3: the no-Funnel invariant, proved rather than stated

**Files:**

- Test: `tests/unit/lib/serve.bats` (append)
- Test: `tests/lint/placeholder_scan.sh` — read it, do not modify it

**Why this is its own task.** Section 3.3's Funnel rule is an invariant about code that does *not* exist, and there is no natural place for such a rule to be tested. Stating it in a comment is what every project does and is why the rule eventually breaks. This test fails the moment anyone adds the call.

- [ ] **Step 1: Write the failing test**

```bash
@test "no library invokes tailscale funnel, in any code path" {
  # Section 3.3: Harbor never invokes tailscale funnel. The only permitted
  # appearances of the word are in prose -- a comment or a message telling the
  # operator what the vendor command would be -- never as a command.
  local hits
  hits="$(grep -rn 'tailscale funnel' "${HARBOR_ROOT}/lib" "${HARBOR_ROOT}/node" \
    "${HARBOR_ROOT}/bin" || :)"
  # Every hit must be inside a comment or a quoted message. A bare invocation is
  # a line whose first word after optional whitespace is `tailscale`.
  local bare
  bare="$(printf '%s\n' "${hits}" | sed -n 's/^[^:]*:[0-9]*: *//p' \
    | grep -c '^tailscale funnel' || :)"
  assert_equal "${bare}" 0
}

@test "the funnel guard is not vacuous" {
  # Correction 30: a refutation that has never failed is not a test. Prove this
  # one can fail by giving it a file that violates the rule.
  mkdir -p "${BATS_TEST_TMPDIR}/lib"
  printf '#!/bin/bash\ntailscale funnel 443 on\n' >"${BATS_TEST_TMPDIR}/lib/bad.sh"
  local bare
  bare="$(grep -rn 'tailscale funnel' "${BATS_TEST_TMPDIR}/lib" \
    | sed -n 's/^[^:]*:[0-9]*: *//p' | grep -c '^tailscale funnel' || :)"
  assert_equal "${bare}" 1
}
```

- [ ] **Step 2: Run the tests**

Run: `tests/run_unit.sh tests/unit/lib/serve.bats`
Expected: both pass immediately — the first because no library invokes it, the second because the planted file does. Record that the first test passed on its first run **and** that the second test proves the technique detects a violation; a guard that passes trivially and has never been shown to fail is exactly what Correction 30 is about.

- [ ] **Step 3: Handoff**

### Task 4: slice 5a verification

- [ ] **Step 1: Run the full unit lane**

Run: `tests/run_unit.sh 2>&1 | grep -c '^not ok'`
Expected: `0`.

- [ ] **Step 2: Run the CI-exact static lane from the repository root**

```bash
shellcheck -s bash -x -a -S warning -P 'SCRIPTDIR/..:SCRIPTDIR/../..' \
  --enable=require-variable-braces \
  fleet/bin/harbor fleet/lib/*.sh fleet/node/*.sh fleet/tests/run_unit.sh \
  fleet/tests/shims/bin/harbor-shim \
  fleet/tests/lint/placeholder_scan.sh fleet/tests/unit/test_helper.bash \
  fleet/tests/integration/*.sh fleet/tests/integration/lib/*.sh \
  fleet/tests/integration/bin/curl fleet/tests/integration/bin/passthrough \
  fleet/tests/integration/bin/ufw fleet/tests/integration/stub/tailscale \
  fleet/tests/integration/stub/t3 fleet/tests/integration/stub/claude \
  fleet/tests/integration/stub/codex \
  fleet/vendor-smoke/*.sh
"$HOME/go/bin/shfmt" -i 2 -ci -bn -d fleet/bin/harbor fleet/lib fleet/node \
  fleet/tests/run_unit.sh fleet/tests/shims/bin/harbor-shim \
  fleet/tests/lint/placeholder_scan.sh fleet/tests/unit/test_helper.bash \
  fleet/tests/integration/*.sh fleet/tests/integration/lib/*.sh \
  fleet/tests/integration/bin/curl fleet/tests/integration/bin/passthrough \
  fleet/tests/integration/bin/ufw fleet/tests/integration/stub/tailscale \
  fleet/tests/integration/stub/t3 fleet/tests/integration/stub/claude \
  fleet/tests/integration/stub/codex \
  fleet/vendor-smoke/*.sh
fleet/tests/lint/placeholder_scan.sh
fleet/tests/lint/engines_check.sh
gitleaks detect --source . --config .gitleaks.toml --no-banner --redact
npx --yes markdownlint-cli@0.41.0 --config .markdownlint.yml \
  '*.md' 'docs/**/*.md' 'fleet/**/*.md' --ignore fleet/tests/vendor
```

Expected: every command exits 0.

- [ ] **Step 3: Handoff for the slice**

Report the total test count, the failure count, and the static lane output. The orchestrator opens the 5a pull request.

---

## Slice 5b: locating this node's own T3 server

### Task 5: the pinned `server-runtime.json` reader

**Files:**

- Modify: `lib/t3.sh` (append after `harbor_t3_service_healthy`)
- Create: `tests/fixtures/t3/server-runtime/healthy`, `non-loopback-host`, `no-port`, `wrong-version`, `pretty-printed`, `garbage`
- Test: `tests/unit/lib/t3_runtime.bats` (new)

**Interfaces produced:**

```text
harbor_t3_state_dir HOME     -> "<HOME>/.t3/userdata", the pinned default
harbor_t3_runtime_path HOME  -> "<HOME>/.t3/userdata/server-runtime.json"
harbor_t3_runtime_port HOME  -> the loopback port, or "" with a reason in HARBOR_T3_RUNTIME_WHY
```

**Contract.** The reader answers the loopback port of a running T3 server on this node, or nothing plus a reason. It reads a **single-line** JSON object — see "Measured vendor facts": `persistServerRuntimeState` uses `JSON.stringify(state)` with no indent, unlike `t3 connect status --json`. It refuses a `version` other than `1`, because the schema is `Literal(1)` and a different version is a file whose fields Harbor has not measured. It refuses a `host` that is present and not a loopback spelling: `runtimeOriginForConfig` only substitutes `127.0.0.1` for a wildcard host, so a server bound to a routable address is a server Harbor's loopback assumption does not describe.

Harbor never writes, creates, or removes this file.

- [ ] **Step 1: Capture the fixtures**

`healthy` — the pinned single-line form, exactly as `persistServerRuntimeState` writes it, with the trailing newline:

```text
{"version":1,"pid":4242,"port":3773,"origin":"http://127.0.0.1:3773","startedAt":"2026-09-15T08:00:00.000Z"}
```

`non-loopback-host` — a server bound somewhere Harbor's assumption does not cover:

```text
{"version":1,"pid":4242,"host":"10.0.0.7","port":3773,"origin":"http://10.0.0.7:3773","startedAt":"2026-09-15T08:00:00.000Z"}
```

`no-port`:

```text
{"version":1,"pid":4242,"origin":"http://127.0.0.1:3773","startedAt":"2026-09-15T08:00:00.000Z"}
```

`wrong-version`:

```text
{"version":2,"pid":4242,"port":3773,"origin":"http://127.0.0.1:3773","startedAt":"2026-09-15T08:00:00.000Z"}
```

`pretty-printed` — the shape a reader copied from the connect adapter would expect, and which the vendor never writes. It is a fixture so that the suite records that this reader does **not** depend on indentation:

```text
{
  "version": 1,
  "pid": 4242,
  "port": 3773,
  "origin": "http://127.0.0.1:3773",
  "startedAt": "2026-09-15T08:00:00.000Z"
}
```

`garbage` — a truncated write:

```text
{"version":1,"pid":4242,"po
```

- [ ] **Step 2: Write the failing tests**

```bash
@test "the pinned paths are the measured ones and creating nothing" {
  assert_equal "$(harbor_t3_state_dir "${FIX_HOME}")" "${FIX_HOME}/.t3/userdata"
  assert_equal "$(harbor_t3_runtime_path "${FIX_HOME}")" \
    "${FIX_HOME}/.t3/userdata/server-runtime.json"
  # Asking where it is must not bring it into existence, the same rule
  # harbor_t3_bin and harbor_t3_package_dir already hold.
  assert [ ! -e "${FIX_HOME}/.t3" ]
}

@test "the pinned one-line body yields the port" {
  runtime_fixture healthy
  assert_equal "$(harbor_t3_runtime_port "${FIX_HOME}")" 3773
}

@test "indentation is not what the reader depends on" {
  # The vendor writes one line. A reader that only works on one line would be
  # right today and wrong the moment the vendor pretty-prints, and a reader that
  # only works pretty-printed is wrong right now. Both shapes answer.
  runtime_fixture pretty-printed
  assert_equal "$(harbor_t3_runtime_port "${FIX_HOME}")" 3773
}

@test "an absent file is an absent server, with a reason" {
  assert_equal "$(harbor_t3_runtime_port "${FIX_HOME}")" ''
  assert_equal "${HARBOR_T3_RUNTIME_WHY}" not-running
}

@test "a version other than the measured literal is refused, not read" {
  runtime_fixture wrong-version
  assert_equal "$(harbor_t3_runtime_port "${FIX_HOME}")" ''
  assert_equal "${HARBOR_T3_RUNTIME_WHY}" unrecognized-version
}

@test "a non-loopback host is refused, because the loopback assumption does not describe it" {
  runtime_fixture non-loopback-host
  assert_equal "$(harbor_t3_runtime_port "${FIX_HOME}")" ''
  assert_equal "${HARBOR_T3_RUNTIME_WHY}" not-loopback
}

@test "a missing port and an unreadable body are each their own reason" {
  runtime_fixture no-port
  assert_equal "$(harbor_t3_runtime_port "${FIX_HOME}")" ''
  assert_equal "${HARBOR_T3_RUNTIME_WHY}" no-port
  runtime_fixture garbage
  assert_equal "$(harbor_t3_runtime_port "${FIX_HOME}")" ''
  assert_equal "${HARBOR_T3_RUNTIME_WHY}" unreadable
}

@test "a symlink at the runtime path is refused before it is followed" {
  # lib/t3.sh refuses a linked package and lib/ssh.sh a linked .ssh for the same
  # reason: a reader that follows a link lets a file outside this path decide.
  mkdir -p "${FIX_HOME}/.t3/userdata"
  ln -s /etc/passwd "${FIX_HOME}/.t3/userdata/server-runtime.json"
  assert_equal "$(harbor_t3_runtime_port "${FIX_HOME}")" ''
  assert_equal "${HARBOR_T3_RUNTIME_WHY}" foreign
}

@test "the reader never writes to the vendor's directory" {
  runtime_fixture healthy
  local before
  before="$(find "${FIX_HOME}/.t3" -type f -exec sha256sum {} + | LC_ALL=C sort)"
  harbor_t3_runtime_port "${FIX_HOME}" >/dev/null
  assert_equal "$(find "${FIX_HOME}/.t3" -type f -exec sha256sum {} + | LC_ALL=C sort)" \
    "${before}"
}
```

- [ ] **Step 3: Run the tests and record the failure verbatim**

Run: `tests/run_unit.sh tests/unit/lib/t3_runtime.bats`

- [ ] **Step 4: Append the reader to `lib/t3.sh`**

```bash
# harbor_t3_state_dir HOME: the pinned T3 state directory. Measured from the
# pinned package rather than assumed: deriveServerPaths joins the base directory
# with "userdata" (the "dev" sibling appears only when devUrl is set, which Harbor
# never sets), and resolveBaseDir defaults the base directory to ~/.t3 when
# T3CODE_HOME is unset. Harbor never sets T3CODE_HOME and never writes here.
harbor_t3_state_dir() {
  printf '%s/.t3/userdata' "${1}"
}
# harbor_t3_runtime_path HOME: where a live T3 server persists its runtime state.
# Asking creates nothing, the same rule harbor_t3_bin holds.
harbor_t3_runtime_path() {
  printf '%s/server-runtime.json' "$(harbor_t3_state_dir "${1}")"
}
# harbor_t3_runtime_port HOME: the loopback port of the running T3 server, or the
# empty string with HARBOR_T3_RUNTIME_WHY naming which of the six reasons applies.
#
# The port, not the origin. Both are in the file, but origin is a URL whose host
# the vendor normalizes to 127.0.0.1 only for a wildcard bind -- a routable host
# reaches origin unchanged -- and section 5.5 requires Harbor's own loopback
# canonicalization to be what decides. So Harbor reads port as the number it is,
# and reads host only to refuse a server its loopback assumption does not cover.
#
# The body is one line. persistServerRuntimeState writes JSON.stringify(state)
# with no indent argument, unlike t3 connect status --json, which is
# JSON.stringify(x, null, 2). A reader copied from the connect adapter matches
# nothing here and reports every field missing on a healthy node. The sed below
# is written against the value, not the line, so both shapes answer.
harbor_t3_runtime_port() {
  local file body version host port
  HARBOR_T3_RUNTIME_WHY=""
  file="$(harbor_t3_runtime_path "${1}")"
  # Before -f, which follows a link, as does the read below. A link accepted here
  # would let a file outside the vendor's own state directory name the port Harbor
  # goes on to journal as a prediction.
  if [ -L "${file}" ]; then
    HARBOR_T3_RUNTIME_WHY=foreign
    return 0
  fi
  if [ ! -f "${file}" ]; then
    HARBOR_T3_RUNTIME_WHY=not-running
    return 0
  fi
  if [ ! -r "${file}" ]; then
    HARBOR_T3_RUNTIME_WHY=unreadable
    return 0
  fi
  # Newlines squeezed out so one pattern reads both the pinned single-line form
  # and a pretty-printed one. This is a value reader, not a line reader: the
  # fields it wants are scalars whose spelling does not depend on layout.
  body="$(tr -d '\n' <"${file}")"
  case "${body}" in
    '{'*'}') ;;
    *)
      HARBOR_T3_RUNTIME_WHY=unreadable
      return 0
      ;;
  esac
  version="$(printf '%s' "${body}" | sed -n 's/.*"version"[ ]*:[ ]*\([0-9][0-9]*\).*/\1/p')"
  if [ "${version}" != 1 ]; then
    HARBOR_T3_RUNTIME_WHY=unrecognized-version
    return 0
  fi
  # host is optional in the schema. Present and non-loopback means the server is
  # not where Harbor's prediction would put it, which is a refusal rather than a
  # port Harbor would go on to describe as loopback.
  host="$(printf '%s' "${body}" | sed -n 's/.*"host"[ ]*:[ ]*"\([^"]*\)".*/\1/p')"
  if [ -n "${host}" ] && [ "$(harbor_serve_loopback_host "${host}")" != loopback ]; then
    HARBOR_T3_RUNTIME_WHY=not-loopback
    return 0
  fi
  port="$(printf '%s' "${body}" | sed -n 's/.*"port"[ ]*:[ ]*\([0-9][0-9]*\).*/\1/p')"
  case "${port}" in
    '' | *[!0123456789]*)
      HARBOR_T3_RUNTIME_WHY=no-port
      return 0
      ;;
  esac
  printf '%s' "${port}"
}
```

- [ ] **Step 5: Source order**

`harbor_t3_runtime_port` calls `harbor_serve_loopback_host`, so `lib/serve.sh` must be sourced before `lib/t3.sh`. Add the source line to `bin/harbor` immediately before the `lib/t3.sh` line, and to any `node/` script that sources `lib/t3.sh`. Add `# shellcheck source=lib/serve.sh` above it, matching the existing lines.

- [ ] **Step 6: Run the tests and confirm they pass**

Run: `tests/run_unit.sh tests/unit/lib/t3_runtime.bats` then the whole lane.

- [ ] **Step 7: Handoff**

### Task 6: the descriptor fetch

**Files:**

- Modify: `lib/t3.sh` (append)
- Create: `tests/fixtures/t3/environment/valid`, `valid-other-id`, `not-t3`, `empty`
- Test: `tests/unit/lib/t3_runtime.bats` (append)

**Interfaces produced:**

```text
harbor_t3_descriptor_id URL -> the environmentId, or "" with HARBOR_T3_DESCRIPTOR_WHY
```

**Contract.** One HTTP GET, through `curl`, with a bounded timeout, no credentials, no redirects followed to another host, and the body never printed. The answer is the `environmentId` field of an `ExecutionEnvironmentDescriptor` — measured schema, see the facts table — or the empty string plus a reason. **The ID is a value Harbor holds in memory and compares; it is never logged, journaled, persisted, or bundled** (section 5.5). Task 8 asserts that.

- [ ] **Step 1: Capture the fixtures**

`valid`:

```text
{"environmentId":"env_2f7a91c4","label":"harbor-node","platform":"linux","serverVersion":"0.0.38","capabilities":{"repositoryIdentity":true}}
```

`valid-other-id` — a well-formed descriptor for a different environment, which is the `broken` case:

```text
{"environmentId":"env_9b3e04d1","label":"someone-elses-box","platform":"linux","serverVersion":"0.0.38","capabilities":{"repositoryIdentity":true}}
```

`not-t3` — something answered, but not a T3 descriptor:

```text
<!DOCTYPE html><html><body>nginx</body></html>
```

`empty` — zero bytes.

- [ ] **Step 2: Write the failing tests**

```bash
@test "a valid descriptor yields its environmentId" {
  descriptor_shim valid
  assert_equal "$(harbor_t3_descriptor_id http://loopback.invalid/.well-known/t3/environment)" \
    env_2f7a91c4
}

@test "a body that is not a T3 descriptor is refused with its own reason" {
  descriptor_shim not-t3
  assert_equal "$(harbor_t3_descriptor_id http://loopback.invalid/.well-known/t3/environment)" ''
  assert_equal "${HARBOR_T3_DESCRIPTOR_WHY}" not-a-descriptor
}

@test "an empty body and an unreachable endpoint are different reasons" {
  descriptor_shim empty
  assert_equal "$(harbor_t3_descriptor_id http://loopback.invalid/.well-known/t3/environment)" ''
  assert_equal "${HARBOR_T3_DESCRIPTOR_WHY}" not-a-descriptor
  descriptor_shim unreachable
  assert_equal "$(harbor_t3_descriptor_id http://loopback.invalid/.well-known/t3/environment)" ''
  assert_equal "${HARBOR_T3_DESCRIPTOR_WHY}" unreachable
}

@test "the fetch carries no credential and follows no redirect" {
  descriptor_shim valid
  harbor_t3_descriptor_id http://loopback.invalid/.well-known/t3/environment >/dev/null
  local argv
  argv="$(cat "${FIX_SHIM_LOG}")"
  # The positive form as well as the refutations, because a refutation whose
  # needle is misspelled cannot fail (Correction 30).
  assert_regex "${argv}" '--max-time'
  refute_regex "${argv}" '--location'
  refute_regex "${argv}" '(-u|--user|--header|Authorization|--netrc)'
}
```

- [ ] **Step 3: Run the tests and record the failure verbatim**

- [ ] **Step 4: Append the fetch to `lib/t3.sh`**

```bash
# harbor_t3_descriptor_id URL: the environmentId at URL, or "" with
# HARBOR_T3_DESCRIPTOR_WHY naming the reason. The body is never printed, never
# logged, and never kept: section 5.5 says the IDs are never logged, journaled,
# persisted, or bundled, and the only way to hold to that is for the body to reach
# nothing but this function's own local.
#
# -q and an empty -i config so no ~/.curlrc supplies a credential or a proxy; no
# --location, because a descriptor Harbor reached by being redirected somewhere
# else is a descriptor for somewhere else; a bounded --max-time, because this runs
# inside harbor pair between a prediction and a vendor invocation and must not hang
# there. A non-zero curl is unreachable, which is an "unknown" input to the
# environment check and never a pass.
harbor_t3_descriptor_id() {
  local url="${1}" body id xt=0
  case "$-" in *x*) xt=1 ;; esac
  [ "${xt}" = 0 ] || set +x
  HARBOR_T3_DESCRIPTOR_WHY=""
  if ! body="$(curl -q -fsS --no-progress-meter --connect-timeout 5 --max-time 15 "${url}" 2>/dev/null)"; then
    HARBOR_T3_DESCRIPTOR_WHY=unreachable
    [ "${xt}" = 0 ] || set -x
    return 0
  fi
  id="$(printf '%s' "${body}" | tr -d '\n' \
    | sed -n 's/.*"environmentId"[ ]*:[ ]*"\([^"]*\)".*/\1/p')"
  unset body
  if [ -z "${id}" ]; then
    HARBOR_T3_DESCRIPTOR_WHY=not-a-descriptor
    [ "${xt}" = 0 ] || set -x
    return 0
  fi
  printf '%s' "${id}"
  [ "${xt}" = 0 ] || set -x
}
```

- [ ] **Step 5: Run the tests and confirm they pass**

- [ ] **Step 6: Handoff**

### Task 7: the `t3.environment` check

**Files:**

- Modify: `lib/t3.sh` (append)
- Test: `tests/unit/lib/t3_environment.bats` (new)

**Interfaces consumed:** `harbor_t3_runtime_port`, `harbor_t3_descriptor_id`, `harbor_serve_status`, `harbor_serve_mapping`.

**Interfaces produced:**

```text
harbor_t3_environment HOME MAGICDNS -> "pass" | "broken" | "unknown"
                                       HARBOR_T3_ENVIRONMENT_WHY carries the identifier and reason
```

**Contract, quoted from section 5.5.** "Pass: both are T3 descriptors with equal IDs. Fail, reported `broken`: the MagicDNS endpoint answered and the body is missing, not a T3 descriptor, or carries a different ID, so the route fronts something other than this node's T3 server. `unknown`: the local server or its runtime state is unreadable (`service.t3` reports why) or the MagicDNS endpoint could not be reached (`tailscale.serve` or `tailscale.running` reports why); `unknown` never counts as a pass."

The asymmetry is the whole design and is easy to get backwards: **a MagicDNS endpoint that answered with the wrong thing is `broken`; a MagicDNS endpoint that did not answer at all is `unknown`.** One means the route fronts a stranger, which is a finding. The other means Harbor could not look, which is not.

`HARBOR_T3_ENVIRONMENT_WHY` is set to `<identifier>: <reason>`, where the identifier is one of `service.t3`, `tailscale.serve`, or `tailscale.running` — the names PR 7's `harbor status` will list.

- [ ] **Step 1: Write the failing tests**

These are eight of the seventeen scenarios spec section 8 row 5 names. The other nine belong to Tasks 13 and 18.

```bash
@test "equal IDs from both endpoints is the only pass" {
  runtime_fixture healthy
  descriptor_shim_for loopback valid
  descriptor_shim_for magicdns valid
  assert_equal "$(harbor_t3_environment "${FIX_HOME}" harbor-node.TAILNET.ts.net)" pass
}

@test "a different ID at the MagicDNS endpoint is broken, because the route fronts a stranger" {
  runtime_fixture healthy
  descriptor_shim_for loopback valid
  descriptor_shim_for magicdns valid-other-id
  assert_equal "$(harbor_t3_environment "${FIX_HOME}" harbor-node.TAILNET.ts.net)" broken
  assert_regex "${HARBOR_T3_ENVIRONMENT_WHY}" '^tailscale\.serve: '
}

@test "a MagicDNS endpoint answering something that is not a descriptor is broken" {
  runtime_fixture healthy
  descriptor_shim_for loopback valid
  descriptor_shim_for magicdns not-t3
  assert_equal "$(harbor_t3_environment "${FIX_HOME}" harbor-node.TAILNET.ts.net)" broken
}

@test "a MagicDNS endpoint that did not answer is unknown, never broken and never a pass" {
  # The asymmetry: answering wrongly is a finding, not answering is not.
  runtime_fixture healthy
  descriptor_shim_for loopback valid
  descriptor_shim_for magicdns unreachable
  assert_equal "$(harbor_t3_environment "${FIX_HOME}" harbor-node.TAILNET.ts.net)" unknown
  assert_regex "${HARBOR_T3_ENVIRONMENT_WHY}" '^tailscale\.(serve|running): '
}

@test "an unreadable local runtime state is unknown under service.t3" {
  runtime_fixture garbage
  descriptor_shim_for magicdns valid
  assert_equal "$(harbor_t3_environment "${FIX_HOME}" harbor-node.TAILNET.ts.net)" unknown
  assert_regex "${HARBOR_T3_ENVIRONMENT_WHY}" '^service\.t3: unreadable'
}

@test "no running local server is unknown under service.t3, not broken" {
  descriptor_shim_for magicdns valid
  assert_equal "$(harbor_t3_environment "${FIX_HOME}" harbor-node.TAILNET.ts.net)" unknown
  assert_regex "${HARBOR_T3_ENVIRONMENT_WHY}" '^service\.t3: not-running'
}

@test "a local server that answers nothing is unknown, because Harbor has nothing to compare" {
  runtime_fixture healthy
  descriptor_shim_for loopback unreachable
  descriptor_shim_for magicdns valid
  assert_equal "$(harbor_t3_environment "${FIX_HOME}" harbor-node.TAILNET.ts.net)" unknown
  assert_regex "${HARBOR_T3_ENVIRONMENT_WHY}" '^service\.t3: '
}

@test "the local endpoint is built from the runtime port, never from the Serve target" {
  # Section 5.5: "Harbor never uses the proxy target to locate the T3 server."
  # A Serve mapping pointing somewhere else must not change which local endpoint
  # Harbor asks, or a foreign mapping could make itself agree with itself.
  runtime_fixture healthy
  serve_fixture foreign-443
  descriptor_shim_for loopback valid
  descriptor_shim_for magicdns valid
  harbor_t3_environment "${FIX_HOME}" harbor-node.TAILNET.ts.net >/dev/null
  assert_regex "$(cat "${FIX_SHIM_LOG}")" 'http://127\.0\.0\.1:3773/\.well-known/t3/environment'
  refute_regex "$(cat "${FIX_SHIM_LOG}")" 'http://127\.0\.0\.1:8080/'
}
```

- [ ] **Step 2: Run the tests and record the failure verbatim**

- [ ] **Step 3: Append the check to `lib/t3.sh`**

```bash
# harbor_t3_environment HOME MAGICDNS: the t3.environment identifier of section
# 5.5, as one of pass, broken, or unknown, with HARBOR_T3_ENVIRONMENT_WHY carrying
# "<identifier>: <reason>" for the status row PR 7 will print.
#
# The asymmetry between broken and unknown is the whole check and is the thing to
# get right: a MagicDNS endpoint that answered with something other than this
# node's descriptor means the route fronts something else, which is a finding; a
# MagicDNS endpoint that did not answer means Harbor could not look, which is not.
# Reporting the second as broken would tell an operator to go hunt a foreign
# mapping every time their tailnet hiccuped; reporting the first as unknown would
# let a stranger's route pass as merely unverified. Neither is ever a pass.
#
# The local endpoint is built from the runtime state's port, never from the Serve
# mapping's proxy target (section 5.5: "Harbor never uses the proxy target to
# locate the T3 server"). Using the target would let a foreign mapping be compared
# against the thing it points at, which agrees with itself by construction.
harbor_t3_environment() {
  local home="${1}" magicdns="${2}" port local_id remote_id
  HARBOR_T3_ENVIRONMENT_WHY=""
  port="$(harbor_t3_runtime_port "${home}")"
  if [ -z "${port}" ]; then
    HARBOR_T3_ENVIRONMENT_WHY="service.t3: ${HARBOR_T3_RUNTIME_WHY}; the local T3 server could not be located, so there is nothing to compare the tailnet route against"
    printf 'unknown'
    return 0
  fi
  local_id="$(harbor_t3_descriptor_id "http://127.0.0.1:${port}/.well-known/t3/environment")"
  if [ -z "${local_id}" ]; then
    HARBOR_T3_ENVIRONMENT_WHY="service.t3: ${HARBOR_T3_DESCRIPTOR_WHY}; the local T3 server did not answer its own descriptor, so there is nothing to compare the tailnet route against"
    printf 'unknown'
    return 0
  fi
  remote_id="$(harbor_t3_descriptor_id "https://${magicdns}/.well-known/t3/environment")"
  if [ -z "${remote_id}" ]; then
    case "${HARBOR_T3_DESCRIPTOR_WHY}" in
      unreachable)
        HARBOR_T3_ENVIRONMENT_WHY="tailscale.serve: unreachable; https://${magicdns}/ did not answer, so the route could not be checked; this is not a verified pass"
        printf 'unknown'
        return 0
        ;;
    esac
    # It answered, and what it answered was not a T3 descriptor. That is the route
    # fronting something else, which is exactly what this check exists to find.
    HARBOR_T3_ENVIRONMENT_WHY="tailscale.serve: not-a-descriptor; https://${magicdns}/ answered, but not with a T3 environment descriptor, so the route fronts something other than this node's T3 server"
    printf 'broken'
    return 0
  fi
  if [ "${remote_id}" = "${local_id}" ]; then
    printf 'pass'
    return 0
  fi
  # The two IDs are never named in the message. Section 5.5: the IDs are never
  # logged, journaled, persisted, or bundled, and a message is all three.
  HARBOR_T3_ENVIRONMENT_WHY="tailscale.serve: different-environment; https://${magicdns}/ answered with a T3 descriptor for a different environment, so the route fronts something other than this node's T3 server"
  printf 'broken'
}
```

- [ ] **Step 4: Run the tests and confirm they pass**

- [ ] **Step 5: Handoff**

### Task 8: the IDs never leave memory, proved

**Files:**

- Test: `tests/unit/lib/t3_environment.bats` (append)

**Why this is its own task.** Section 5.5's "never logged, journaled, persisted, or bundled" is a property of every future change to these three functions, not of the code as written today. A test that greps the artifacts for the fixture's ID fails the moment anyone adds a helpful diagnostic.

- [ ] **Step 1: Write the test**

```bash
@test "no environment ID reaches the log, the journal, stdout, or any file Harbor wrote" {
  runtime_fixture healthy
  descriptor_shim_for loopback valid
  descriptor_shim_for magicdns valid-other-id
  harbor_log_open "${FIX_ROOT}/harbor.log" 0600
  harbor_journal_init "${FIX_ROOT}"
  local out
  out="$(harbor_t3_environment "${FIX_HOME}" harbor-node.TAILNET.ts.net)"
  assert_equal "${out}" broken
  # The two IDs from the fixtures, by their literal values.
  local id
  for id in env_2f7a91c4 env_9b3e04d1; do
    refute_regex "${out}" "${id}"
    refute_regex "${HARBOR_T3_ENVIRONMENT_WHY}" "${id}"
    assert_equal "$(grep -rl "${id}" "${FIX_ROOT}" 2>/dev/null | wc -l | tr -d ' ')" 0
  done
}

@test "the ID leak guard is not vacuous" {
  # Correction 30 again: prove the grep finds an ID when one is there.
  printf 'env_2f7a91c4\n' >"${FIX_ROOT}/planted"
  assert_equal "$(grep -rl env_2f7a91c4 "${FIX_ROOT}" | wc -l | tr -d ' ')" 1
  rm -f "${FIX_ROOT}/planted"
}
```

- [ ] **Step 2: Run the tests, then the whole lane, then the static lane from Task 4 Step 2**

- [ ] **Step 3: Handoff for slice 5b**

---

## Slice 5c: the connect link step

### Task 9: `t3 connect link` and the `t3-connect-link` entry

**Files:**

- Modify: `lib/t3.sh:280-345` (`harbor_t3_connect`, replacing the `true:false` arm at line 317)
- Test: `tests/unit/lib/t3_connect.bats` (append)

**Interfaces consumed:** `harbor_t3_connect_status`, `harbor_t3_run`, `harbor_journal_create`, `harbor_service_cmd`.

**Interfaces produced:**

```text
harbor_t3_connect_link HOME -> runs `t3 connect link`, returns its exit code
```

**Contract, from section 5.5 step 2.** `harbor auth connect` "journals `t3-connect-link` (`created`, pre-state `linked: false`) before running `t3 connect link`, then restarts the service so it reconciles the link." Section 3.6 adds: "passing the vendor's relay-client download prompt through rather than pre-answering it".

This is a `prepared`-then-`applied` transaction, unlike the `auth` entry beside it, which is written already-applied because Harbor reads both ends of a login it has no inverse for. The link is different: it has a documented inverse (`t3 connect unlink`, which PR 8's teardown uses), so it is journaled the ordinary way and a crash leaves it `prepared` for recovery to decide.

**The prompt is passed through, which means the vendor's stdin and stdout are the terminal's.** `harbor_t3_run` must not capture either. Confirm before writing: `harbor_t3_run` (`lib/t3.sh:228`) does not redirect, and `harbor_t3_connect_login` relies on that already.

- [ ] **Step 1: Write the failing tests**

```bash
@test "the link step journals prepared before the vendor runs, and applied after" {
  connect_status_fixture authenticated-not-linked
  connect_link_shim success
  run harbor_t3_connect "${FIX_ROOT}" "${FIX_HOME}"
  assert_success
  assert_equal "$(entry_raw "${FIX_ROOT}" 0001 op)" '"t3-connect-link"'
  assert_equal "$(entry_raw "${FIX_ROOT}" 0001 ownership)" '"created"'
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" applied
  assert_equal "$(entry_raw "${FIX_ROOT}" 0001 pre_state)" '"false"'
  assert_equal "$(entry_raw "${FIX_ROOT}" 0001 post_state)" '"true"'
}

@test "the entry is written before the vendor is invoked, not after it returns" {
  # The order is the contract: a crash during t3 connect link must leave an entry
  # recovery can decide. Proved by crashing at the boundary between them.
  connect_status_fixture authenticated-not-linked
  connect_link_shim success
  HARBOR_TEST_HOOKS=1 HARBOR_FAIL_AFTER=connect-link-prepared \
    run harbor_t3_connect "${FIX_ROOT}" "${FIX_HOME}"
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" prepared
  # And the vendor never ran, which is what makes this a revertible entry.
  refute_regex "$(cat "${FIX_SHIM_LOG}")" 'connect link'
  assert_regex "$(cat "${FIX_SHIM_LOG}")" 'connect status --json'
}

@test "a link the vendor did not complete leaves the entry prepared and says so" {
  connect_status_fixture authenticated-not-linked
  connect_link_shim failure
  run harbor_t3_connect "${FIX_ROOT}" "${FIX_HOME}"
  assert_equal "${status}" 1
  assert_output --partial 'stays prepared'
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" prepared
}

@test "the service is restarted after a successful link, so it reconciles" {
  connect_status_fixture authenticated-not-linked
  connect_link_shim success
  run harbor_t3_connect "${FIX_ROOT}" "${FIX_HOME}"
  assert_success
  assert_regex "$(cat "${FIX_SHIM_LOG}")" 'service restart'
}

@test "an already-linked node runs no link and journals nothing" {
  connect_status_fixture healthy
  run harbor_t3_connect "${FIX_ROOT}" "${FIX_HOME}"
  assert_success
  assert_output --partial 'already authorized and linked'
  refute_regex "$(cat "${FIX_SHIM_LOG}")" 'connect link'
  assert_equal "$(ls -A "${FIX_ROOT}/journal" | wc -l | tr -d ' ')" 0
}

@test "the vendor's prompt is not pre-answered and its streams are not captured" {
  # Section 3.6: pass the relay-client download prompt through. A captured stdout
  # is a prompt the operator never sees, and a supplied stdin is a prompt Harbor
  # answered on their behalf.
  connect_status_fixture authenticated-not-linked
  connect_link_shim prompts
  run harbor_t3_connect "${FIX_ROOT}" "${FIX_HOME}"
  assert_output --partial 'Download the relay client?'
}
```

- [ ] **Step 2: Run the tests and record the failure verbatim**

Expected: the first five fail, because line 317 still dies with `t3.needs_connect_link`. Paste that message — it is the seam PR 4 left on purpose and this task closes.

- [ ] **Step 3: Add `harbor_t3_connect_link` and replace the `true:false` arm**

```bash
# harbor_t3_connect_link HOME: the vendor's own link command, streams untouched.
# Section 3.6 requires the relay-client download prompt to reach the operator
# rather than being pre-answered, so nothing here redirects stdin or stdout, and
# harbor_t3_run already emits the vendor line after its version guard.
harbor_t3_connect_link() {
  local home="${1}" rc=0
  harbor_t3_run "${home}" connect link || rc="$?"
  harbor_log t3 "connect link exited ${rc}"
  return "${rc}"
}
```

The `true:false` arm of the `case` in `harbor_t3_connect` becomes:

```bash
    true:false)
      # Journaled the ordinary way, unlike the auth entry beside it. That one is
      # written already-applied because Harbor has no inverse for a vendor login
      # and can only record a transition it read both ends of. The link does have
      # an inverse -- t3 connect unlink, which PR 8's teardown runs -- so it is a
      # prepared-then-applied transaction and a crash in the middle leaves an
      # entry recovery can decide against the vendor's own status.
      harbor_msg "auth.connect: T3 Connect is authorized but not linked; running its own link below — follow what it prints, including any relay-client prompt, which Harbor passes through rather than answering for you"
      harbor_journal_create "${root}" t3-connect-link connect created prepared '"false"' '"true"'
      entry="${HARBOR_JOURNAL_ENTRY}"
      harbor_step "connect-link-prepared"
      harbor_t3_connect_link "${home}" || rc="$?"
      harbor_step "connect-link"
      harbor_t3_connect_status "${home}"
      case "${HARBOR_T3_CONNECT_LINKED}" in
        true) ;;
        *)
          harbor_die 1 t3.link_incomplete "T3 Connect still reports linked=${HARBOR_T3_CONNECT_LINKED} after its own link exited ${rc}, so the link was not completed; $(basename "${entry}") stays prepared and rerunning is safe: harbor auth connect"
          ;;
      esac
      harbor_journal_set_phase "${entry}" applied
      # Restart so the running service reconciles the link it did not have when it
      # started (section 5.5 step 2). The vendor's own verb, through the vendor's
      # own CLI: Harbor never runs systemctl against this unit.
      harbor_service_cmd restart "${home}" || harbor_die 1 t3.link_unreconciled "T3 Connect is linked and $(basename "${entry}") is applied, but the service restart that makes the running server pick the link up failed; run: harbor service restart"
      harbor_msg "T3 Connect is linked on this node; recorded it as $(basename "${entry}") and restarted the service so it reconciles"
      return 0
      ;;
```

- [ ] **Step 4: Register the observer for the new op**

`harbor_journal_recover` dispatches `t3-connect-link` to `harbor_observe_op_t3_connect_link`. Without it, a crashed link entry renders `"unobservable:t3-connect-link"` and recovery reports it undecidable forever. Append to `lib/t3.sh`:

```bash
# harbor_observe_op_t3_connect_link TARGET: the linked field, as the journal's
# own string form, so recovery of a crashed link decides against the vendor's
# status rather than against a file. TARGET is the literal word connect; the op
# has one target on a node.
harbor_observe_op_t3_connect_link() {
  harbor_t3_connect_status "${HARBOR_AGENTS_HOME}"
  printf '"%s"' "${HARBOR_T3_CONNECT_LINKED}"
}
```

- [ ] **Step 5: Write the recovery test**

```bash
@test "a crashed link is decided by the vendor's own status on the next run" {
  connect_status_fixture authenticated-not-linked
  connect_link_shim success
  HARBOR_TEST_HOOKS=1 HARBOR_FAIL_AFTER=connect-link-prepared \
    run harbor_t3_connect "${FIX_ROOT}" "${FIX_HOME}"
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" prepared
  # The vendor never linked, so the world still equals pre_state and recovery
  # reverts. This is the case the -prepared boundary exists for.
  HARBOR_AGENTS_HOME="${FIX_HOME}"
  harbor_journal_recover "${FIX_ROOT}"
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" reverted
}

@test "a link the vendor completed before the crash is recovered as applied" {
  connect_status_fixture authenticated-not-linked
  connect_link_shim success
  HARBOR_TEST_HOOKS=1 HARBOR_FAIL_AFTER=connect-link \
    run harbor_t3_connect "${FIX_ROOT}" "${FIX_HOME}"
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" prepared
  # Now the vendor has linked, so the world equals post_state.
  connect_status_fixture healthy
  HARBOR_AGENTS_HOME="${FIX_HOME}"
  harbor_journal_recover "${FIX_ROOT}"
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" applied
}
```

- [ ] **Step 6: Run the tests and confirm they pass**

- [ ] **Step 7: Handoff**

### Task 10: provision's completed `connect` row

**Files:**

- Modify: `node/provision.sh:184-215` (the `needs_connect_link` arm's message)
- Test: `tests/unit/node/provision.bats` (modify the needs-link test)

**Why.** The row currently tells the operator to "run the PR 5 link step, harbor auth connect, once that release is available; this release provides login only". This release *is* that release. Leaving the text is not cosmetic: it tells an operator on a correctly-working node that the fix for their state does not exist.

- [ ] **Step 1: Write the failing test**

```bash
@test "the needs_connect_link report names the command that now exists" {
  provision_connect_fixture authenticated-not-linked
  run provision_run
  assert_equal "${status}" 1
  assert_output --partial 'needs_connect_link'
  assert_output --partial 'run harbor auth connect, then rerun harbor provision'
  # The PR 4 text must be gone, and the refutation is paired with the positive
  # assertion above so a misspelled needle cannot pass silently.
  refute_output --partial 'once that release is available'
}
```

- [ ] **Step 2: Run the test and record the failure verbatim**

- [ ] **Step 3: Change the message**

```bash
        */true/false/available)
          access_state=needs_connect_link
          harbor_provision_attended needs_connect_link "run harbor auth connect, then rerun harbor provision"
          ;;
```

- [ ] **Step 4: Run the tests and confirm they pass**

- [ ] **Step 5: Handoff**

### Task 11: slice 5c verification

- [ ] **Step 1: Run the full unit lane and the static lane from Task 4 Step 2**
- [ ] **Step 2: Handoff for the slice**

---

## Slice 5d: `harbor pair`

### Task 12: the pre-check, before the vendor is ever invoked

**Files:**

- Create: `lib/pair.sh`
- Test: `tests/unit/lib/pair.bats` (new)

**Interfaces consumed:** everything from 5a and 5b.

**Interfaces produced:**

```text
harbor_pair_precheck STATE_ROOT HOME MAGICDNS -> "create" | "reuse" | exits 2
```

**Contract, from section 5.5 step 4.** "Harbor observes the normalized 443 mapping. If one exists, it runs the environment check first: pass means the mapping is journaled `tailscale-serve` `observed` and the vendor may reuse it; a mapping the adapter cannot normalize, a check result of `unknown`, or any failure exits 2 without invoking `t3 pair` and without mutating Serve."

Three outcomes, and the exit-2 arm is the important one: **Harbor decides before the vendor runs, and a decision it cannot make is a refusal, not a delegation.** Section 3.6: `harbor pair` "refuses, without calling the vendor or touching Serve, unless the mapping is absent or fronts this node's T3 server."

- [ ] **Step 1: Write the failing tests**

```bash
@test "no mapping means create" {
  serve_fixture absent
  runtime_fixture healthy
  assert_equal "$(harbor_pair_precheck "${FIX_ROOT}" "${FIX_HOME}" "${MAGICDNS}")" create
}

@test "a mapping that passes the environment check means reuse, journaled observed" {
  serve_fixture vendor-443
  runtime_fixture healthy
  descriptor_shim_for loopback valid
  descriptor_shim_for magicdns valid
  assert_equal "$(harbor_pair_precheck "${FIX_ROOT}" "${FIX_HOME}" "${MAGICDNS}")" reuse
  assert_equal "$(entry_raw "${FIX_ROOT}" 0001 op)" '"tailscale-serve"'
  assert_equal "$(entry_raw "${FIX_ROOT}" 0001 ownership)" '"observed"'
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" applied
}

@test "a foreign mapping exits 2 without calling the vendor and without touching Serve" {
  serve_fixture vendor-443
  runtime_fixture healthy
  descriptor_shim_for loopback valid
  descriptor_shim_for magicdns valid-other-id
  run harbor_pair_precheck "${FIX_ROOT}" "${FIX_HOME}" "${MAGICDNS}"
  assert_equal "${status}" 2
  assert_output --partial 'fronts something other than this node'
  # Both halves of the invariant, each asserted positively somewhere in this file
  # so the refutations cannot pass on a misspelled needle.
  refute_regex "$(cat "${FIX_SHIM_LOG}")" 't3 pair'
  refute_regex "$(cat "${FIX_SHIM_LOG}")" 'tailscale serve --'
  # And the remediation names the vendor command rather than another token.
  assert_output --partial 'tailscale serve status'
  refute_output --partial 'harbor pair'
}

@test "an unknown environment check exits 2, because unknown is never permission to act" {
  serve_fixture vendor-443
  runtime_fixture healthy
  descriptor_shim_for loopback valid
  descriptor_shim_for magicdns unreachable
  run harbor_pair_precheck "${FIX_ROOT}" "${FIX_HOME}" "${MAGICDNS}"
  assert_equal "${status}" 2
  refute_regex "$(cat "${FIX_SHIM_LOG}")" 't3 pair'
}

@test "a mapping the adapter cannot normalize exits 2" {
  serve_fixture garbage
  runtime_fixture healthy
  run harbor_pair_precheck "${FIX_ROOT}" "${FIX_HOME}" "${MAGICDNS}"
  assert_equal "${status}" 2
  refute_regex "$(cat "${FIX_SHIM_LOG}")" 't3 pair'
}

@test "a Funnel exposure exits 2 in every arm, whoever created it" {
  # Section 3.3: any Funnel exposure on any port makes this exit 2.
  serve_fixture funnel
  runtime_fixture healthy
  run harbor_pair_precheck "${FIX_ROOT}" "${FIX_HOME}" "${MAGICDNS}"
  assert_equal "${status}" 2
  assert_output --partial 'Funnel'
  refute_regex "$(cat "${FIX_SHIM_LOG}")" 't3 pair'
}

@test "the vendor is invoked in exactly one arm, which proves the refutations above" {
  # Correction 30: six refutations of "t3 pair" above, none of which has ever
  # failed. This is the positive form, and it is what makes them meaningful.
  serve_fixture absent
  runtime_fixture healthy
  descriptor_shim_for loopback valid
  descriptor_shim_for magicdns valid
  pair_shim success
  run harbor_pair "${FIX_ROOT}" "${FIX_HOME}" "${MAGICDNS}"
  assert_regex "$(cat "${FIX_SHIM_LOG}")" 't3 pair --tailscale'
}
```

- [ ] **Step 2: Run the tests and record the failure verbatim**

- [ ] **Step 3: Write the pre-check into `lib/pair.sh`**

```bash
#!/bin/bash
# harbor pair (design sections 3.6 and 5.5). The shape of this file is the point:
# Harbor inspects, decides, and journals a prediction, and only then does the
# vendor run. The vendor's own guard exists and is documented, and Harbor does not
# rely on it -- section 5.5 calls Harbor's pre-check authoritative. A wrapper that
# delegated the decision would be a wrapper that mutates a stranger's Serve
# mapping whenever the vendor's guard changed.

# harbor_pair_precheck STATE_ROOT HOME MAGICDNS: "create", "reuse", or exit 2.
# Nothing here calls the vendor and nothing here touches Serve.
harbor_pair_precheck() {
  local root="${1}" home="${2}" magicdns="${3}" mapping funnel verdict
  harbor_serve_status
  # Funnel first, and in every arm. Section 3.3 makes any public exposure exit 2
  # whoever created it, so it is not a question about this mapping and must not be
  # reachable only through one branch.
  funnel="$(harbor_serve_funnel)"
  case "${funnel}" in
    present)
      harbor_die 2 pair.funnel "this node has a Funnel exposure, which publishes it beyond the tailnet; Harbor's v1 invariant is no public inbound exposure and it never creates or removes a Funnel; inspect it with: tailscale serve status, and remove it yourself with the vendor command it names; nothing was changed"
      ;;
    unknown)
      harbor_die 2 pair.serve_unreadable "Harbor could not read this node's Serve configuration, so it cannot tell whether a Funnel exposure or a foreign mapping exists; inspect it with: tailscale serve status; nothing was changed and t3 pair was not run"
      ;;
  esac
  mapping="$(harbor_serve_mapping)"
  case "${mapping}" in
    absent)
      printf 'create'
      return 0
      ;;
    unnormalizable)
      harbor_die 2 pair.serve_unreadable "this node has a Serve configuration Harbor could not reduce to a comparable HTTPS 443 mapping, so it cannot tell whether the route already fronts this node's T3 server; inspect it with: tailscale serve status; nothing was changed and t3 pair was not run"
      ;;
  esac
  # A mapping exists. Section 5.5: an existing mapping is never a pairing need;
  # the environment check judges it, and it judges it before the vendor runs.
  verdict="$(harbor_t3_environment "${home}" "${magicdns}")"
  case "${verdict}" in
    pass) ;;
    broken)
      harbor_die 2 pair.foreign_mapping "this node already has an HTTPS 443 Serve mapping (${mapping}), and it fronts something other than this node's T3 server: ${HARBOR_T3_ENVIRONMENT_WHY}; Harbor never mutates a Serve mapping it did not create, and minting another pairing token would not change the route; inspect it with: tailscale serve status, remove it with the vendor command that lists it if it is yours, then rerun harbor pair; nothing was changed and t3 pair was not run"
      ;;
    *)
      harbor_die 2 pair.environment_unknown "this node already has an HTTPS 443 Serve mapping (${mapping}), and Harbor could not verify what it fronts: ${HARBOR_T3_ENVIRONMENT_WHY}; an unverified route is not a route Harbor will pair through; resolve the reason above and rerun harbor pair; nothing was changed and t3 pair was not run"
      ;;
  esac
  # It fronts this node's own T3 server. Journal it observed, which is the word
  # section 3.7 reserves for state Harbor found correct and did not create. An
  # observed mapping is never converted to created and never removed by teardown.
  harbor_journal_create "${root}" tailscale-serve https-443 observed applied \
    "\"${mapping}\"" "\"${mapping}\""
  printf 'reuse'
}
```

- [ ] **Step 4: Run the tests and confirm the pre-check tests pass**

The last test, which invokes `harbor_pair`, still fails — Task 13 writes it. Say so in the handoff rather than stubbing the function.

- [ ] **Step 5: Handoff**

### Task 13: the prediction, the transaction, and the post-verify

**Files:**

- Modify: `lib/pair.sh` (append)
- Test: `tests/unit/lib/pair.bats` (append)

**Interfaces produced:**

```text
harbor_pair_prediction HOME -> the normalized mapping the vendor will create, or exits 2
harbor_pair STATE_ROOT HOME MAGICDNS -> 0 | 1 | 2
```

**Contract, from section 5.5 step 4.** "If no mapping exists, Harbor first predicts the exact normalized post-state from the pinned runtime state, `https:443` proxied to the loopback host and port the T3 server reports, journals `tailscale-serve` `prepared` with `pre_state` `absent` and that prediction as `post_state`, and only then runs `t3 pair --tailscale`, passing its output straight to the terminal without capturing or delaying it. Afterwards it re-reads the normalized mapping."

Then the four post-states, verbatim:

| After the vendor | Entry | Exit |
| --- | --- | --- |
| Absent | `reverted`; the vendor's message stands | the vendor's |
| Equal to the prediction, environment check passes | `applied`, `created` | 0 |
| Equal to the prediction, check `unknown` | `applied`, `created` | 1, naming `harbor status` as the retry, never a verified pass |
| Equal to the prediction, check `broken` | `applied`, `created` | 2 |
| Anything else | left `prepared` | 2, print the entry and the real mapping, mutate nothing |

- [ ] **Step 1: Write the failing tests**

```bash
@test "the prediction is built from the runtime port, in the normalized form" {
  runtime_fixture healthy
  assert_equal "$(harbor_pair_prediction "${FIX_HOME}")" \
    'https:443 -> http://loopback:3773'
}

@test "a node with no locatable T3 server cannot be paired, and says which reason" {
  run harbor_pair_prediction "${FIX_HOME}"
  assert_equal "${status}" 2
  assert_output --partial 'not-running'
}

@test "the entry is prepared with the prediction before the vendor runs" {
  serve_fixture absent
  runtime_fixture healthy
  pair_shim success
  HARBOR_TEST_HOOKS=1 HARBOR_FAIL_AFTER=pair-prepared \
    run harbor_pair "${FIX_ROOT}" "${FIX_HOME}" "${MAGICDNS}"
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" prepared
  assert_equal "$(entry_raw "${FIX_ROOT}" 0001 pre_state)" '"absent"'
  assert_equal "$(entry_raw "${FIX_ROOT}" 0001 post_state)" \
    '"https:443 -> http://loopback:3773"'
  refute_regex "$(cat "${FIX_SHIM_LOG}")" 't3 pair'
}

@test "a mapping matching the prediction with a passing check is created and exits 0" {
  serve_fixture absent
  runtime_fixture healthy
  pair_shim success
  serve_fixture_after_pair vendor-443
  descriptor_shim_for loopback valid
  descriptor_shim_for magicdns valid
  run harbor_pair "${FIX_ROOT}" "${FIX_HOME}" "${MAGICDNS}"
  assert_success
  assert_equal "$(entry_raw "${FIX_ROOT}" 0001 ownership)" '"created"'
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" applied
}

@test "a created mapping whose check is unknown exits 1 and is never called verified" {
  serve_fixture absent
  runtime_fixture healthy
  pair_shim success
  serve_fixture_after_pair vendor-443
  descriptor_shim_for loopback valid
  descriptor_shim_for magicdns unreachable
  run harbor_pair "${FIX_ROOT}" "${FIX_HOME}" "${MAGICDNS}"
  assert_equal "${status}" 1
  assert_output --partial 'harbor status'
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" applied
  refute_output --partial 'verified'
}

@test "a created mapping whose check is broken exits 2" {
  serve_fixture absent
  runtime_fixture healthy
  pair_shim success
  serve_fixture_after_pair vendor-443
  descriptor_shim_for loopback valid
  descriptor_shim_for magicdns valid-other-id
  run harbor_pair "${FIX_ROOT}" "${FIX_HOME}" "${MAGICDNS}"
  assert_equal "${status}" 2
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" applied
}

@test "a vendor that created nothing leaves the entry reverted and its own message standing" {
  serve_fixture absent
  runtime_fixture healthy
  pair_shim failure
  serve_fixture_after_pair absent
  run harbor_pair "${FIX_ROOT}" "${FIX_HOME}" "${MAGICDNS}"
  assert_failure
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" reverted
  assert_output --partial 'the vendor could not publish'
}

@test "a mapping that is neither absent nor the prediction is the undecidable case" {
  serve_fixture absent
  runtime_fixture healthy
  pair_shim success
  serve_fixture_after_pair foreign-443
  run harbor_pair "${FIX_ROOT}" "${FIX_HOME}" "${MAGICDNS}"
  assert_equal "${status}" 2
  # Left prepared for the section 3.7 recovery, with both sides printed.
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" prepared
  assert_output --partial 'https:443 -> http://loopback:3773'
  assert_output --partial 'https:443 -> http://loopback:8080'
  assert_output --partial 'harbor journal resolve'
}

@test "an interrupt leaves a prepared entry a later recovery decides by the prediction" {
  serve_fixture absent
  runtime_fixture healthy
  pair_shim success
  HARBOR_TEST_HOOKS=1 HARBOR_FAIL_AFTER=pair-vendor \
    run harbor_pair "${FIX_ROOT}" "${FIX_HOME}" "${MAGICDNS}"
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" prepared
  # The vendor did create the mapping before the crash; recovery recognizes it by
  # the predicted post_state, which is why the prediction is journaled at all.
  serve_fixture vendor-443
  harbor_journal_recover "${FIX_ROOT}"
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" applied
}

@test "a rerun on a healthy paired node mints no pairing token" {
  # Section 3.6: rerunning provision never mints a pairing token, and neither does
  # rerunning pair on a node whose mapping already fronts its own server.
  serve_fixture vendor-443
  runtime_fixture healthy
  descriptor_shim_for loopback valid
  descriptor_shim_for magicdns valid
  run harbor_pair "${FIX_ROOT}" "${FIX_HOME}" "${MAGICDNS}"
  refute_regex "$(cat "${FIX_SHIM_LOG}")" 't3 pair'
}
```

- [ ] **Step 2: Run the tests and record the failure verbatim**

- [ ] **Step 3: Append the prediction and the command to `lib/pair.sh`**

```bash
# harbor_pair_prediction HOME: the exact normalized mapping the pinned vendor will
# create. Measured, not guessed: the pinned t3 runs
#   tailscale serve --bg --https=443 http://127.0.0.1:<port>
# with servePort defaulting to 443 and localHost to 127.0.0.1, and <port> is the
# port from server-runtime.json. Harbor journals this string as post_state before
# the vendor runs, which is what lets recovery recognize a mapping created just
# before a crash -- there is no other record that the vendor got that far.
harbor_pair_prediction() {
  local port
  port="$(harbor_t3_runtime_port "${1}")"
  [ -n "${port}" ] \
    || harbor_die 2 pair.no_server "this node's T3 server could not be located (${HARBOR_T3_RUNTIME_WHY}), so Harbor cannot predict the Serve mapping the vendor would create and will not run t3 pair blind; check the service with: harbor service status; nothing was changed"
  printf 'https:443 -> http://loopback:%s' "${port}"
}

# harbor_pair STATE_ROOT HOME MAGICDNS: the whole attended command.
harbor_pair() {
  local root="${1}" home="${2}" magicdns="${3}" decision prediction entry after verdict rc=0
  decision="$(harbor_pair_precheck "${root}" "${home}" "${magicdns}")" || exit "$?"
  if [ "${decision}" = reuse ]; then
    harbor_msg "pair: this node already publishes its own T3 server over HTTPS 443 on the tailnet, and the environment check confirms the route reaches it; no pairing token was minted and Serve was not touched — open the environment in T3 Code, or mint a fresh token yourself with: t3 pair --tailscale"
    return 0
  fi
  prediction="$(harbor_pair_prediction "${home}")" || exit "$?"
  harbor_journal_create "${root}" tailscale-serve https-443 created prepared \
    '"absent"' "\"$(harbor_json_escape "${prediction}")\""
  entry="${HARBOR_JOURNAL_ENTRY}"
  harbor_step "pair-prepared"
  harbor_msg "pair: running t3 pair --tailscale below; its pairing URL and QR code go straight to your terminal and Harbor neither captures nor stores them"
  # Streams untouched: section 3.6 requires the vendor's output to pass straight to
  # the terminal "without capturing or delaying it", and a one-time pairing token
  # that reached a Harbor variable would be a token in a place section 3.8 forbids.
  harbor_t3_run "${home}" pair --tailscale || rc="$?"
  harbor_step "pair-vendor"
  harbor_serve_status
  after="$(harbor_serve_mapping)"
  if [ "${after}" = absent ]; then
    harbor_journal_set_phase "${entry}" reverted
    harbor_die "${rc}" pair.vendor_failed "the vendor could not publish this node over Tailscale Serve (t3 pair --tailscale exited ${rc}) and left no HTTPS 443 mapping; its own output above says why; $(basename "${entry}") is reverted and rerunning is safe: harbor pair"
  fi
  if [ "${after}" != "${prediction}" ]; then
    # Section 3.7's undecidable case: something is at 443 and it is not what Harbor
    # said would be. Print both sides and stop; reconciliation is the runbook's.
    harbor_msg "pair: Harbor predicted ${prediction}"
    harbor_msg "pair: the node now has ${after}"
    harbor_die 2 pair.undecidable "the HTTPS 443 mapping after t3 pair --tailscale is not the one Harbor predicted, so Harbor cannot tell whether the vendor created it or something else did, and it will not claim ownership of a mapping it cannot account for; $(basename "${entry}") stays prepared; inspect with: tailscale serve status, and when you have decided, resolve the entry with: harbor journal resolve $(basename "${entry}" .json | sed 's/-.*//') --reverted; nothing was changed"
  fi
  harbor_journal_set_phase "${entry}" applied
  verdict="$(harbor_t3_environment "${home}" "${magicdns}")"
  case "${verdict}" in
    pass)
      harbor_msg "pair: this node now publishes its own T3 server over HTTPS 443 on the tailnet, and the environment check confirms the route reaches it; recorded as $(basename "${entry}")"
      return 0
      ;;
    unknown)
      harbor_die 1 pair.environment_unknown "the mapping Harbor predicted was created and recorded as $(basename "${entry}"), but the route could not be verified: ${HARBOR_T3_ENVIRONMENT_WHY}; this is not a verified pass, and it may simply be a tailnet that has not settled — retry the check with: harbor status"
      ;;
  esac
  harbor_die 2 pair.environment_broken "the mapping Harbor predicted was created and recorded as $(basename "${entry}"), but the route does not reach this node's T3 server: ${HARBOR_T3_ENVIRONMENT_WHY}; inspect with: tailscale serve status"
}
```

- [ ] **Step 4: Run the tests and confirm they pass**

- [ ] **Step 5: Prove the refutations are not vacuous**

The suite now contains eight `refute_regex ... 't3 pair'` assertions. Break the implementation once — remove the `return 0` from the `reuse` arm so the vendor runs in a case it must not — and confirm the reuse test goes red. Restore, and record the verbatim red output in the handoff. This is the Correction 30 requirement for a load-bearing refutation.

- [ ] **Step 6: Handoff**

### Task 14: `harbor pair` as a command

**Files:**

- Modify: `bin/harbor` (source `lib/serve.sh` and `lib/pair.sh`, add dispatch and usage)
- Modify: `lib/pair.sh` (append the command wrapper)
- Test: `tests/unit/bin/harbor.bats` (append)

**Interfaces produced:**

```text
harbor_pair_cmd [ARGS...] -> the whole command: refuse root, refuse other modes, lock, recover, pair
```

**Contract.** Section 3.6: `harbor pair` "refuses other modes". The MagicDNS name comes from `tailscale status --json`, through the existing `lib/tailscale.sh` reader — Harbor does not ask the operator for it and does not construct it from a hostname it assumed.

- [ ] **Step 1: Write the failing tests**

```bash
@test "pair refuses a node whose access mode is not tailnet" {
  config_fixture connect
  run harbor_pair_cmd
  assert_equal "${status}" 3
  assert_output --partial 'access_mode=connect'
  assert_output --partial 'harbor access set tailnet'
  refute_regex "$(cat "${FIX_SHIM_LOG}")" 't3 pair'
}

@test "pair refuses root" {
  config_fixture tailnet
  HARBOR_FAKE_UID=0 run harbor_pair_cmd
  assert_equal "${status}" 3
}

@test "pair takes the operator lock and recovers before it decides anything" {
  config_fixture tailnet
  serve_fixture absent
  runtime_fixture healthy
  pair_shim success
  serve_fixture_after_pair vendor-443
  descriptor_shim_for loopback valid
  descriptor_shim_for magicdns valid
  run harbor_pair_cmd
  assert_success
  assert_regex "$(cat "${FIX_ROOT}/harbor.log")" 'command pair'
  assert_regex "$(cat "${FIX_ROOT}/harbor.log")" 'step recovery-scan'
  assert [ ! -e "${FIX_ROOT}/lock.d" ]
}

@test "pair takes its MagicDNS name from the vendor, not from an assumed hostname" {
  config_fixture tailnet
  serve_fixture absent
  runtime_fixture healthy
  tailscale_status_fixture magicdns-name 'other-node.TAILNET.ts.net'
  pair_shim success
  serve_fixture_after_pair vendor-443
  descriptor_shim_for loopback valid
  descriptor_shim_for magicdns valid
  run harbor_pair_cmd
  # other-node, not harbor-node: the fixture deliberately does not match the
  # hostname bootstrap would have chosen, so a name Harbor assembled instead of
  # read cannot pass this by coincidence.
  assert_regex "$(cat "${FIX_SHIM_LOG}")" 'https://other-node\.TAILNET\.ts\.net/'
}

@test "the usage text lists pair" {
  run harbor_usage
  assert_output --partial 'pair'
  assert_output --partial 'tailnet'
}
```

- [ ] **Step 2: Run the tests and record the failure verbatim**

- [ ] **Step 3: Write `harbor_pair_cmd` and wire the dispatcher**

```bash
# harbor_pair_cmd: the attended pairing command of design section 3.6. Mode first,
# because pairing a connect node would publish it on the tailnet it deliberately
# is not on; lock and recovery next, for the same reason harbor_t3_connect does
# them in that order -- this operator journal can hold a crashed provision, and a
# prepared tailscale-serve entry from a crashed pair is exactly what recovery is
# for. Only then is anything inspected.
harbor_pair_cmd() {
  local root home mode magicdns
  [ "$#" -eq 0 ] || harbor_die 3 usage "usage: harbor pair"
  harbor_auth_refuse_root
  home="${HOME}"
  mode="$(harbor_config_access_mode "${home}")" || exit "$?"
  [ "${mode}" = tailnet ] \
    || harbor_die 3 pair.wrong_mode "this node's access_mode=${mode}, and pairing over Tailscale Serve is the tailnet mode's step; switch modes with: harbor access set tailnet, which reverts the current mode's entries first; nothing was changed"
  harbor_access_require_tailnet_supported
  root="$(harbor_state_root_path "${home}")"
  harbor_state_root_create "${root}" operator
  harbor_log_open "${root}/harbor.log" 0600
  harbor_log command pair
  harbor_lock_acquire "${root}" operator
  harbor_journal_init "${root}"
  # shellcheck disable=SC2034
  HARBOR_AGENTS_HOME="${home}"
  harbor_versions_load "$(harbor_versions_lock_path)"
  harbor_journal_recover "${root}"
  harbor_step recovery-scan
  magicdns="$(harbor_tailscale_magicdns)" \
    || harbor_die 3 pair.no_magicdns "this node has no MagicDNS name, so there is no tailnet URL to pair through; log in with: harbor auth tailscale, and confirm MagicDNS is enabled for your tailnet; nothing was changed"
  harbor_pair "${root}" "${home}" "${magicdns}"
}
```

In `bin/harbor`, add the two source lines (`lib/serve.sh` before `lib/t3.sh`, `lib/pair.sh` after it), the dispatch arm, and the usage entry:

```bash
  pair)
    shift
    harbor_pair_cmd ${1+"$@"}
    ;;
```

```text
  pair                                publish this node's T3 server over Tailscale Serve and
                                      mint a one-time pairing token, attended, as the operator
                                      (design section 3.6); tailnet mode only, and Harbor never
                                      touches a Serve mapping it did not create
```

- [ ] **Step 4: Add `harbor_tailscale_magicdns` to `lib/tailscale.sh`**

```bash
# harbor_tailscale_magicdns: this node's own MagicDNS name, from the vendor's own
# status, or return 1. Read rather than constructed: a name Harbor assembled from
# the hostname it asked for at bootstrap would be a name that is right until the
# tailnet renames the node, and every URL built from it would then point at
# someone else.
harbor_tailscale_magicdns() {
  local body name
  body="$(tailscale status --json 2>/dev/null)" || return 1
  name="$(printf '%s\n' "${body}" | tr -d '\n' \
    | sed -n 's/.*"Self"[ ]*:[ ]*{[^}]*"DNSName"[ ]*:[ ]*"\([^"]*\)".*/\1/p')"
  # The vendor prints the FQDN with a trailing dot.
  name="${name%.}"
  [ -n "${name}" ] || return 1
  printf '%s' "${name}"
}
```

- [ ] **Step 5: Run the tests and confirm they pass**

- [ ] **Step 6: Handoff**

### Task 15: slice 5d verification

- [ ] **Step 1: Run the full unit lane and the static lane from Task 4 Step 2**
- [ ] **Step 2: Handoff for the slice**

---

## Slice 5e: the modes

### Task 16: the `ssh` mode and the `tailnet` gate in `lib/config.sh`

**Files:**

- Modify: `lib/config.sh:6-21` (`harbor_config_validate_mode`)
- Create: `fleet/vendor-smoke/tailnet-environment.probe`
- Test: `tests/unit/lib/config.bats` (append)

**Interfaces produced:**

```text
harbor_access_tailnet_supported          -> 0 when the recorded probe says supported, else 1
harbor_access_require_tailnet_supported  -> exits 3 with the limitation when it is not
```

**Contract.** `harbor_config_validate_mode` currently accepts `connect` and refuses `tailnet` with "cannot be provisioned by this release because harbor pair does not exist yet". `harbor pair` now exists, so that refusal moves to the recorded-probe gate, and `ssh` is accepted for the first time.

The probe file's format mirrors `fleet/vendor-smoke/tailscale-ssh.probe`, which PR 3 established: a small key-value record a human writes after an attended measurement, read by `lib/` to decide a feature gate. Ship it with `result=unsupported` until Task 20's measurement says otherwise.

- [ ] **Step 1: Write the probe file**

```text
# Revalidation A of design section 5.5, recorded by PR 5.
#
# Question: on the exact pinned tailscale_version and t3_version, can the node
# fetch its own Serve descriptor at
# https://harbor-node.TAILNET.ts.net/.well-known/t3/environment?
#
# This cannot be measured in CI: the integration lane has no Tailscale account,
# no tailnet, and no MagicDNS name, and its tailscale is a stand-in that never
# logs in. It is an attended measurement on a real node, recorded here by hand
# after the owner runs the procedure in the PR body, exactly as PR 3 recorded the
# --ssh probe. lib/access.sh reads result= and gates tailnet mode on it.
#
# Until result=supported, harbor provision --access-mode tailnet, harbor access
# set tailnet, and harbor pair exit 3 naming the limitation, and t3.environment
# is never reported as pass or unknown in its place (section 5.5).
result=unsupported
measured_tailscale_version=
measured_t3_version=
measured_on=
note=not yet measured; see the PR 5 body for the procedure
```

- [ ] **Step 2: Write the failing tests**

```bash
@test "ssh is an accepted access mode" {
  run harbor_config_validate_mode "${FIX_CONFIG}" ssh
  assert_success
}

@test "connect is accepted and an unknown mode names all three" {
  run harbor_config_validate_mode "${FIX_CONFIG}" connect
  assert_success
  run harbor_config_validate_mode "${FIX_CONFIG}" wireguard
  assert_equal "${status}" 3
  assert_output --partial 'connect'
  assert_output --partial 'tailnet'
  assert_output --partial 'ssh'
}

@test "tailnet parses, and the gate is what refuses it" {
  # The distinction matters: tailnet is a real mode this release implements, and
  # the refusal is about a measurement, not about a missing command. A parse-time
  # rejection would make the message unfixable by measuring anything.
  run harbor_config_validate_mode "${FIX_CONFIG}" tailnet
  assert_success
}

@test "the recorded probe decides whether tailnet is supported" {
  probe_fixture unsupported
  run harbor_access_require_tailnet_supported
  assert_equal "${status}" 3
  assert_output --partial 'has not been verified on the pinned versions'
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
```

- [ ] **Step 3: Run the tests and record the failure verbatim**

- [ ] **Step 4: Change `harbor_config_validate_mode` and add the gate**

```bash
harbor_config_validate_mode() {
  local file="${1}" mode="${2}"
  case "${mode}" in
    connect | ssh | tailnet) ;;
    # All three words, because all three are the vocabulary of section 3.3 and a
    # reader of this message is entitled to the whole list. tailnet is accepted
    # here and gated separately by the recorded revalidation: refusing it at parse
    # time would produce a message no measurement could ever fix.
    *) harbor_die 3 config.access_mode "${file}: access_mode '${mode}' is unknown; the modes are connect, tailnet, and ssh; configuration was not accepted" ;;
  esac
}
```

In `lib/access.sh` (created in Task 17, but these two functions go in first so Task 14's `harbor_pair_cmd` can call them):

```bash
# harbor_access_probe_path: the recorded Revalidation A result. Under the release
# root, so an installed release carries the value it was tested at rather than
# reading whatever a checkout on the node happens to say.
harbor_access_probe_path() {
  printf '%s/vendor-smoke/tailnet-environment.probe' "${HARBOR_ROOT}"
}
# harbor_access_tailnet_supported: 0 only when the recorded probe says supported.
# Fails closed on a missing, unreadable, or unrecognized file: section 5.5 makes
# an unverified tailnet an explicit exit 3 gate, never a silently accepted mode.
harbor_access_tailnet_supported() {
  local file result
  file="$(harbor_access_probe_path)"
  [ -f "${file}" ] && [ -r "${file}" ] || return 1
  result="$(sed -n 's/^result=//p' "${file}" | sed -n 1p)"
  [ "${result}" = supported ] || return 1
  return 0
}
harbor_access_require_tailnet_supported() {
  harbor_access_tailnet_supported \
    || harbor_die 3 access.tailnet_unverified "tailnet mode is implemented but not enabled on this release: whether a node can fetch its own Serve descriptor through its MagicDNS name has not been verified on the pinned tailscale and t3 versions, and design section 5.5 makes an unverified tailnet an explicit refusal rather than a mode Harbor accepts and cannot check; the recorded result is in vendor-smoke/tailnet-environment.probe and the procedure that fills it in is in the PR 5 body; use: harbor access set connect, or harbor access set ssh; nothing was changed"
}
```

- [ ] **Step 5: Run the tests and confirm they pass**

- [ ] **Step 6: Handoff**

### Task 17: `lib/access.sh` and the mode revert

**Files:**

- Modify: `lib/access.sh` (append to Task 16's two functions)
- Test: `tests/unit/lib/access.bats` (new)

**Interfaces produced:**

```text
harbor_access_mode_ops MODE            -> the journal ops that belong to MODE, space separated
harbor_access_revert STATE_ROOT MODE   -> reverts MODE's applied entries, newest first
harbor_access_cmd get|set MODE         -> the command
```

**Contract, from section 3.3.** "`harbor access set <mode>` reverts the previous mode's journal entries (section 5.7), configures the new one, and reports any attended step still needed."

**What "reverts" means here, precisely, and what it does not.** Reverting an access entry means running the op's documented inverse and marking the entry `reverted` — and only for entries this mode created. Three rules, each with a test:

1. An entry whose ownership is `observed` is never reverted. Harbor did not create it and section 6.1 forbids mutating it.
2. A `tailscale-serve` entry is reverted only when the current normalized mapping still equals its `post_state`. A mapping that has changed since Harbor created it is one someone else has touched, and removing it would be removing a stranger's configuration. Such an entry is reported and left alone.
3. Entries are reverted newest first, so a mode that journaled two dependent mutations unwinds in the order it made them.

The inverses, both measured:

| op | inverse | measured from |
| --- | --- | --- |
| `tailscale-serve` | `tailscale serve --https=443 off` | `disableTailscaleServe` in the pinned package |
| `t3-connect-link` | `t3 connect unlink` | section 3.3's wrapped-commands column |

- [ ] **Step 1: Write the failing tests**

```bash
@test "each mode owns exactly the ops it journals" {
  assert_equal "$(harbor_access_mode_ops connect)" 't3-connect-link'
  assert_equal "$(harbor_access_mode_ops tailnet)" 'tailscale-serve'
  assert_equal "$(harbor_access_mode_ops ssh)" ''
}

@test "a created serve entry whose mapping still matches is reverted with the vendor's inverse" {
  seed_entry 0001 tailscale-serve https-443 created applied \
    '"absent"' '"https:443 -> http://loopback:3773"'
  serve_fixture vendor-443
  run harbor_access_revert "${FIX_ROOT}" tailnet
  assert_success
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" reverted
  assert_regex "$(cat "${FIX_SHIM_LOG}")" 'tailscale serve --https=443 off'
}

@test "an observed entry is never reverted and the vendor is never called for it" {
  seed_entry 0001 tailscale-serve https-443 observed applied \
    '"https:443 -> http://loopback:3773"' '"https:443 -> http://loopback:3773"'
  serve_fixture vendor-443
  run harbor_access_revert "${FIX_ROOT}" tailnet
  assert_success
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" applied
  assert_output --partial 'Harbor did not create'
  refute_regex "$(cat "${FIX_SHIM_LOG}")" 'serve --https=443 off'
}

@test "a created entry whose mapping has changed is reported and left alone" {
  seed_entry 0001 tailscale-serve https-443 created applied \
    '"absent"' '"https:443 -> http://loopback:3773"'
  serve_fixture foreign-443
  run harbor_access_revert "${FIX_ROOT}" tailnet
  assert_equal "${status}" 1
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" applied
  assert_output --partial 'has changed since Harbor created it'
  refute_regex "$(cat "${FIX_SHIM_LOG}")" 'serve --https=443 off'
}

@test "the inverse is run once per entry, newest first" {
  seed_entry 0001 t3-connect-link connect created applied '"false"' '"true"'
  seed_entry 0002 t3-connect-link connect created applied '"false"' '"true"'
  connect_status_fixture healthy
  run harbor_access_revert "${FIX_ROOT}" connect
  assert_success
  assert_equal "$(grep -c 'connect unlink' "${FIX_SHIM_LOG}")" 2
  # Newest first: 0002's unlink is logged before 0001's.
  assert_regex "$(cat "${FIX_ROOT}/harbor.log")" '0002-.*reverted(.|\n)*0001-.*reverted'
}

@test "another mode's entries are not touched" {
  seed_entry 0001 tailscale-serve https-443 created applied \
    '"absent"' '"https:443 -> http://loopback:3773"'
  serve_fixture vendor-443
  run harbor_access_revert "${FIX_ROOT}" connect
  assert_success
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" applied
  refute_regex "$(cat "${FIX_SHIM_LOG}")" 'serve --https=443 off'
}

@test "the revert guard is not vacuous" {
  # Correction 30: the three refutations above have never failed. Prove the
  # positive form reaches the shim log in the one arm that must call the vendor.
  seed_entry 0001 tailscale-serve https-443 created applied \
    '"absent"' '"https:443 -> http://loopback:3773"'
  serve_fixture vendor-443
  harbor_access_revert "${FIX_ROOT}" tailnet
  assert_equal "$(grep -c 'serve --https=443 off' "${FIX_SHIM_LOG}")" 1
}
```

- [ ] **Step 2: Run the tests and record the failure verbatim**

- [ ] **Step 3: Write the revert**

```bash
# harbor_access_mode_ops MODE: the journal ops a mode's setup creates. ssh journals
# nothing on the node -- section 5.5: "nothing on the node beyond bootstrap and the
# vendor service" -- and an empty answer is the honest one, not an omission.
harbor_access_mode_ops() {
  case "${1}" in
    connect) printf 't3-connect-link' ;;
    tailnet) printf 'tailscale-serve' ;;
    ssh) ;;
  esac
}

# harbor_access_revert STATE_ROOT MODE: run each of MODE's applied entries' own
# inverse and mark it reverted. Returns 1 when any entry was reported rather than
# reverted, so the caller can report attended work rather than claim a clean switch.
#
# Three rules, and they are the whole of section 6.1 in this context. An observed
# entry is never reverted: Harbor did not create that state and does not remove it.
# A created entry is reverted only when the world still equals its post_state:
# anything else has been touched since, and unwinding it would unwind someone
# else's change. Newest first, so dependent mutations unwind in the order made.
harbor_access_revert() {
  local root="${1}" mode="${2}" ops entry base seq op ownership phase post observed attended=0
  ops="$(harbor_access_mode_ops "${mode}")"
  [ -n "${ops}" ] || return 0
  for entry in $(harbor_access_entries_newest_first "${root}"); do
    op="$(harbor_journal_string "${entry}" op)"
    case " ${ops} " in
      *" ${op} "*) ;;
      *) continue ;;
    esac
    phase="$(harbor_journal_string "${entry}" phase)"
    [ "${phase}" = applied ] || continue
    base="$(basename "${entry}")"
    seq="${base%%-*}"
    ownership="$(harbor_journal_string "${entry}" ownership)"
    if [ "${ownership}" = observed ]; then
      harbor_msg "access: ${base} records a ${op} Harbor did not create, so it is left exactly as it is; remove it yourself if it is yours"
      continue
    fi
    post="$(harbor_journal_raw "${entry}" post_state)"
    observed="$(harbor_journal_observe "${op}" "$(harbor_journal_string "${entry}" target)")" || exit "$?"
    if [ "${observed}" != "${post}" ]; then
      harbor_msg "access: ${base} records a ${op} whose state has changed since Harbor created it, so Harbor will not undo it; inspect it and, when you have decided, resolve the entry with: harbor journal resolve ${seq} --reverted"
      attended=1
      continue
    fi
    harbor_access_inverse "${op}" || harbor_die 2 access.revert_failed "the inverse of ${op} recorded in ${base} failed, so the previous mode is only partly undone and the new mode was not configured; the vendor's output above says why; rerun: harbor access set ${mode}"
    harbor_journal_set_phase "${entry}" reverted
    harbor_log access "${base} reverted (${op})"
  done
  [ "${attended}" = 0 ]
}

# harbor_access_inverse OP: the vendor's own documented inverse. Both measured:
# disableTailscaleServe in the pinned t3 runs `tailscale serve --https=443 off`,
# and section 3.3's table names `t3 connect unlink`. Harbor never invents one.
harbor_access_inverse() {
  case "${1}" in
    tailscale-serve) tailscale serve --https=443 off ;;
    t3-connect-link) harbor_t3_run "${HARBOR_AGENTS_HOME}" connect unlink ;;
    *) return 1 ;;
  esac
}

# harbor_access_entries_newest_first STATE_ROOT: the journal's entry paths, highest
# sequence first. A separate function because a case statement inside $( ) is a
# bash 3.2 parse error (Correction 26) and the loop above needs the list in one.
harbor_access_entries_newest_first() {
  find "${1}/journal" -maxdepth 1 -type f -name '[0-9][0-9][0-9][0-9]-*.json' \
    | LC_ALL=C sort -r
}
```

- [ ] **Step 4: Run the tests and confirm they pass**

- [ ] **Step 5: Handoff**

### Task 18: `harbor access get|set`

**Files:**

- Modify: `lib/access.sh` (append)
- Modify: `bin/harbor` (dispatch and usage)
- Test: `tests/unit/lib/access.bats` (append)

**Contract.** `harbor access get` prints the current mode and exits 0. `harbor access set <mode>` validates the mode, gates `tailnet`, refuses a no-op switch with a message rather than churning the journal, reverts the previous mode's entries, rewrites the config, and reports what attended step the new mode still needs.

- [ ] **Step 1: Write the failing tests**

```bash
@test "get prints the configured mode" {
  config_fixture connect
  run harbor_access_cmd get
  assert_success
  assert_output connect
}

@test "setting the mode already configured changes nothing and says so" {
  config_fixture connect
  run harbor_access_cmd set connect
  assert_success
  assert_output --partial 'already connect'
  assert_equal "$(ls -A "${FIX_ROOT}/journal" | wc -l | tr -d ' ')" 0
}

@test "switching reverts the old mode's entries before it writes the new config" {
  config_fixture tailnet
  probe_fixture supported
  seed_entry 0001 tailscale-serve https-443 created applied \
    '"absent"' '"https:443 -> http://loopback:3773"'
  serve_fixture vendor-443
  run harbor_access_cmd set connect
  assert_success
  assert_equal "$(entry_phase "${FIX_ROOT}" 0001)" reverted
  assert_equal "$(cat "${FIX_CONFIG}")" access_mode=connect
  # Order: the revert's log line precedes the config write's journal entry.
  assert_regex "$(cat "${FIX_ROOT}/harbor.log")" '0001-.*reverted(.|\n)*config-file'
}

@test "a failed revert leaves the old mode configured, not a half-switched node" {
  config_fixture tailnet
  probe_fixture supported
  seed_entry 0001 tailscale-serve https-443 created applied \
    '"absent"' '"https:443 -> http://loopback:3773"'
  serve_fixture vendor-443
  serve_off_shim failure
  run harbor_access_cmd set connect
  assert_equal "${status}" 2
  assert_equal "$(cat "${FIX_CONFIG}")" access_mode=tailnet
}

@test "switching to tailnet is refused while the revalidation is unrecorded" {
  config_fixture connect
  probe_fixture unsupported
  run harbor_access_cmd set tailnet
  assert_equal "${status}" 3
  assert_output --partial 'has not been verified on the pinned versions'
  assert_equal "$(cat "${FIX_CONFIG}")" access_mode=connect
}

@test "each new mode reports the attended step it still needs" {
  config_fixture connect
  probe_fixture supported
  connect_status_fixture authenticated-not-linked
  run harbor_access_cmd set tailnet
  assert_success
  assert_output --partial 'harbor pair'
  config_fixture tailnet
  run harbor_access_cmd set connect
  assert_success
  assert_output --partial 'harbor auth connect'
  config_fixture connect
  run harbor_access_cmd set ssh
  assert_success
  assert_output --partial 'no further step on this node'
}

@test "set refuses an unknown mode without touching the config" {
  config_fixture connect
  run harbor_access_cmd set wireguard
  assert_equal "${status}" 3
  assert_equal "$(cat "${FIX_CONFIG}")" access_mode=connect
}

@test "set with no mode, and get with one, are usage errors" {
  run harbor_access_cmd set
  assert_equal "${status}" 3
  run harbor_access_cmd get connect
  assert_equal "${status}" 3
}
```

- [ ] **Step 2: Run the tests and record the failure verbatim**

- [ ] **Step 3: Write the command**

```bash
# harbor_access_cmd get|set MODE: the access mode as a command (section 3.3).
harbor_access_cmd() {
  local verb="${1:-}" mode="${2:-}" home root current
  harbor_auth_refuse_root
  home="${HOME}"
  case "${verb}" in
    get)
      [ "$#" -eq 1 ] || harbor_die 3 usage "usage: harbor access get"
      harbor_config_access_mode "${home}" || exit "$?"
      printf '\n'
      return 0
      ;;
    set)
      [ "$#" -eq 2 ] || harbor_die 3 usage "usage: harbor access set <connect|tailnet|ssh>"
      ;;
    *) harbor_die 3 usage "usage: harbor access <get|set <connect|tailnet|ssh>>" ;;
  esac
  # Validated before anything is locked or read, so a typo costs nothing.
  harbor_config_validate_mode "$(harbor_config_path "${home}")" "${mode}"
  [ "${mode}" != tailnet ] || harbor_access_require_tailnet_supported
  root="$(harbor_state_root_path "${home}")"
  harbor_state_root_create "${root}" operator
  harbor_log_open "${root}/harbor.log" 0600
  harbor_log command "access set ${mode}"
  harbor_lock_acquire "${root}" operator
  harbor_journal_init "${root}"
  # shellcheck disable=SC2034
  HARBOR_AGENTS_HOME="${home}"
  harbor_versions_load "$(harbor_versions_lock_path)"
  harbor_journal_recover "${root}"
  harbor_step recovery-scan
  current="$(harbor_config_access_mode "${home}")" || exit "$?"
  if [ "${current}" = "${mode}" ]; then
    harbor_msg "access: this node's access_mode is already ${mode}; nothing was reverted, rewritten, or journaled"
    return 0
  fi
  # Revert first, and write the config only if it succeeded. The other order would
  # leave a node whose config names a mode whose setup never happened, on top of a
  # previous mode whose entries still claim to be applied -- two wrong answers
  # where failing here leaves exactly one state, the one the node was already in.
  harbor_access_revert "${root}" "${current}" || harbor_msg "access: the previous mode left attended work, listed above; it does not block the switch"
  harbor_config_create "${root}" "${home}" "${mode}"
  harbor_access_report_next "${mode}" "${home}"
}

# harbor_access_report_next MODE HOME: the attended step the new mode still needs,
# named as the command that performs it (section 3.6's list).
harbor_access_report_next() {
  case "${1}" in
    connect)
      harbor_msg "access: access_mode is now connect; the attended step is: harbor auth connect, then: harbor provision"
      ;;
    tailnet)
      harbor_msg "access: access_mode is now tailnet; the attended step is: harbor pair, then: harbor provision"
      ;;
    ssh)
      harbor_msg "access: access_mode is now ssh; there is no further step on this node — the desktop starts and manages its own remote server over SSH, and Harbor neither manages nor observes it; run: harbor provision to confirm the node's Node.js satisfies the launcher's requirement"
      ;;
  esac
}
```

Dispatcher arm and usage entry in `bin/harbor`:

```bash
  access)
    shift
    harbor_access_cmd ${1+"$@"}
    ;;
```

```text
  access get                          print this node's access mode
  access set <connect|tailnet|ssh>    switch access modes: revert the previous mode's journal
                                      entries, write the new mode, and report the attended step
                                      it needs (design section 3.3)
```

- [ ] **Step 4: Run the tests and confirm they pass**

- [ ] **Step 5: Handoff**

### Task 19: provision's `tailnet` and `ssh` rows

**Files:**

- Modify: `node/provision.sh:184-215` (the access-mode `case`)
- Test: `tests/unit/node/provision.bats` (append)

**Contract.** Section 5.5's `tailnet` steps 1, 2, and 5, and the `ssh` Node check. Provision never runs an attended command: it reports and names the command.

- [ ] **Step 1: Write the failing tests**

```bash
@test "tailnet with connect still desired reports that connect is active" {
  provision_config tailnet
  probe_fixture supported
  provision_connect_fixture desired-true
  run provision_run
  assert_equal "${status}" 1
  assert_output --partial 'connect is still active'
  assert_output --partial 'harbor access set tailnet'
}

@test "tailnet with no mapping reports needs_pairing and names harbor pair" {
  provision_config tailnet
  probe_fixture supported
  provision_connect_fixture desired-false
  serve_fixture absent
  run provision_run
  assert_equal "${status}" 1
  assert_output --partial 'needs_pairing'
  assert_output --partial 'harbor pair'
}

@test "tailnet with a passing mapping and no funnel is healthy" {
  provision_config tailnet
  probe_fixture supported
  provision_connect_fixture desired-false
  serve_fixture vendor-443
  runtime_fixture healthy
  descriptor_shim_for loopback valid
  descriptor_shim_for magicdns valid
  run provision_run
  assert_success
}

@test "an existing mapping is never a pairing need, whatever the environment check says" {
  # Section 5.5 step 2, exactly: "An existing mapping is never a pairing need; the
  # environment check judges it." Reporting needs_pairing here would tell the
  # operator to mint a token as the fix for a foreign route, which section 5.5
  # forbids in those words.
  provision_config tailnet
  probe_fixture supported
  provision_connect_fixture desired-false
  serve_fixture vendor-443
  runtime_fixture healthy
  descriptor_shim_for loopback valid
  descriptor_shim_for magicdns valid-other-id
  run provision_run
  assert_equal "${status}" 2
  assert_output --partial 'broken'
  refute_output --partial 'needs_pairing'
}

@test "any funnel exposure is exit 2 in the tailnet row" {
  provision_config tailnet
  probe_fixture supported
  provision_connect_fixture desired-false
  serve_fixture funnel
  run provision_run
  assert_equal "${status}" 2
  assert_output --partial 'Funnel'
}

@test "tailnet is refused entirely while the revalidation is unrecorded" {
  provision_config tailnet
  probe_fixture unsupported
  run provision_run
  assert_equal "${status}" 3
  assert_output --partial 'has not been verified on the pinned versions'
}

@test "ssh verifies the operator's login shell can resolve a satisfying node" {
  provision_config ssh
  login_shell_node_shim 24.20.0
  run provision_run
  assert_success
}

@test "ssh reports the launcher's own check failing, with the command T3 runs" {
  provision_config ssh
  login_shell_node_shim absent
  run provision_run
  assert_equal "${status}" 1
  assert_output --partial "sh -lc 'command -v node && node --version'"
}
```

- [ ] **Step 2: Run the tests and record the failure verbatim**

- [ ] **Step 3: Add the two arms to the access-mode `case`**

```bash
    tailnet)
      harbor_access_require_tailnet_supported
      # Step 1: connect must not still be desired. Two modes both claiming the
      # route is the state section 3.3 forbids with "Exactly one mode is active".
      harbor_t3_connect_status "${HOME}"
      case "${HARBOR_T3_CONNECT_DESIRED}" in
        true)
          access_state=connect_still_active
          harbor_provision_attended tailnet.connect_active "T3 Connect is still active on this node, so two routes would claim it; switch properly with: harbor access set tailnet, which reverts the connect entries first, then rerun harbor provision"
          ;;
        *)
          harbor_serve_status
          # Funnel before the mapping, and regardless of it: section 3.3 makes any
          # public exposure exit 2 whoever created it and whatever else is true.
          case "$(harbor_serve_funnel)" in
            present)
              access_state=broken
              harbor_provision_broken tailnet.funnel "this node has a Funnel exposure, which publishes it beyond the tailnet; Harbor never creates or removes a Funnel; inspect it with: tailscale serve status and remove it with the vendor command it names"
              ;;
            unknown)
              access_state=unknown
              harbor_provision_attended tailnet.serve_unknown "Harbor could not read this node's Serve configuration; inspect it with: tailscale serve status, then rerun harbor provision"
              ;;
            *)
              harbor_provision_tailnet_mapping
              ;;
          esac
          ;;
      esac
      ;;
    ssh)
      # Section 5.5: nothing on the node beyond bootstrap and the vendor service.
      # The one thing provision verifies is the check T3's own SSH launcher makes,
      # through the same login shell the launcher will use -- not through the Node
      # this process inherited, which is not the one the launcher will find.
      if harbor_t3_login_shell_node "${HOME}"; then
        :
      else
        access_state=needs_node
        harbor_provision_attended ssh.node "the T3 SSH launcher runs sh -lc 'command -v node && node --version' on this node and this release's check of that command failed (${HARBOR_T3_LOGIN_NODE_WHY}); make node resolvable from the operator's login shell, then rerun harbor provision"
      fi
      ;;
```

`harbor_provision_tailnet_mapping` is a helper in `node/provision.sh`, written as a function because a `case` inside `$( )` is a bash 3.2 parse error (Correction 26) and this arm needs two nested ones:

```bash
harbor_provision_tailnet_mapping() {
  local mapping verdict magicdns
  mapping="$(harbor_serve_mapping)"
  case "${mapping}" in
    absent)
      # Step 2: no mapping is the one pairing need. An existing mapping never is.
      access_state=needs_pairing
      harbor_provision_attended needs_pairing "run harbor pair, which publishes this node's T3 server over Tailscale Serve and mints a one-time pairing token, then rerun harbor provision"
      return 0
      ;;
    unnormalizable)
      access_state=unknown
      harbor_provision_attended tailnet.serve_unknown "this node has a Serve configuration Harbor could not reduce to a comparable HTTPS 443 mapping; inspect it with: tailscale serve status, then rerun harbor provision"
      return 0
      ;;
  esac
  magicdns="$(harbor_tailscale_magicdns)" || {
    access_state=unknown
    harbor_provision_attended tailnet.no_magicdns "this node has no MagicDNS name, so the tailnet route cannot be checked; log in with: harbor auth tailscale and confirm MagicDNS is enabled, then rerun harbor provision"
    return 0
  }
  verdict="$(harbor_t3_environment "${HOME}" "${magicdns}")"
  case "${verdict}" in
    pass) return 0 ;;
    broken)
      access_state=broken
      harbor_provision_broken tailnet.environment "${HARBOR_T3_ENVIRONMENT_WHY}; minting another pairing token would not change the route — inspect it with: tailscale serve status"
      return 0
      ;;
  esac
  access_state=unknown
  harbor_provision_attended tailnet.environment_unknown "${HARBOR_T3_ENVIRONMENT_WHY}; rerun harbor provision once the tailnet has settled"
}
```

And `harbor_t3_login_shell_node` in `lib/t3.sh`, which is the same probe `harbor_t3_require_engines` already performs, factored out so the `ssh` row and the engines check cannot drift apart:

```bash
# harbor_t3_login_shell_node HOME: whether the operator's login shell resolves a
# node satisfying the locked engines range, which is the check T3's own SSH
# launcher makes (section 5.5). Through sh -lc, not through this process's PATH:
# the launcher has no interactive profile and a node that only this process can
# see is a node the launcher will not find.
harbor_t3_login_shell_node() {
  local out version
  HARBOR_T3_LOGIN_NODE_WHY=""
  out="$(HOME="${1}" sh -lc 'command -v node >/dev/null && node --version' 2>/dev/null)" || {
    HARBOR_T3_LOGIN_NODE_WHY="the login shell could not resolve node"
    return 1
  }
  case "${out}" in
    v*) version="${out#v}" ;;
    *)
      HARBOR_T3_LOGIN_NODE_WHY="node --version printed '${out}', which is not a version this reader can vouch for"
      return 1
      ;;
  esac
  harbor_versions_satisfies "${version}" "$(harbor_version_require t3_engines_node)" || {
    HARBOR_T3_LOGIN_NODE_WHY="the login shell's node is ${version}, which does not satisfy the locked range"
    return 1
  }
  return 0
}
```

- [ ] **Step 4: Run the tests and confirm they pass**

- [ ] **Step 5: Handoff**

### Task 20: the two revalidations

**Files:**

- Modify: `fleet/vendor-smoke/tailnet-environment.probe` (record the result)
- Modify: `.github/workflows/vendor-smoke.yml` (the Revalidation B half, which CI *can* run)

**This task has two halves with different owners.**

**Half A, attended, performed by the owner on a real node.** Revalidation A cannot run in CI. The procedure, which goes verbatim into the PR body so the measurement is reproducible:

```bash
# On a bootstrapped, provisioned, tailnet-joined node, as the operator:
harbor access set tailnet          # expect exit 3 while the probe says unsupported
# Temporarily record result=supported in the installed release's probe file, then:
harbor pair                        # the vendor publishes Serve and prints a token
tailscale status --json | sed -n 's/.*"DNSName": "\([^"]*\)".*/\1/p'
curl -fsS "https://<that name without the trailing dot>/.well-known/t3/environment"
```

Record in the probe file: `result=supported` if the last command prints a T3 descriptor whose `environmentId` equals the one at `http://127.0.0.1:<port>/.well-known/t3/environment`; `result=unsupported` and the vendor's error otherwise. Fill in `measured_tailscale_version`, `measured_t3_version`, `measured_on`, and `note`. Paste the whole transcript into the PR body.

**If the measurement says unsupported, that is a result, not a failure**, and PR 5 still merges: `tailnet` is then a mode Harbor implements, unit-tests completely, and refuses at runtime with an accurate message, which is exactly what section 5.5 prescribes.

**Half B, in CI.** Revalidation B — what the pinned `t3 pair --tailscale` guard does — is measurable without a tailnet, because the question is what the command does when Serve is *not* available. Add a `t3-pair-guard` job to `vendor-smoke.yml` that installs the real pinned `t3`, starts no server, runs `t3 pair --tailscale` in the isolated private environment `t3_engines_probe.sh` already builds, and records which fixed word its refusal matches — `no-running-server`, `tailscale-unavailable`, or `unexpected`. The measured error classes are in the pinned package: `NoRunningServerError`, `TailscaleUnavailableError`, `MagicDnsNameMissingError`.

- [ ] **Step 1: Write the Half B probe**

Extend `fleet/vendor-smoke/t3_engines_probe.sh` rather than creating a second script: it already builds the private prefix, the clean environment, the EXIT trap, and the fixed-word record, and a second script would duplicate all four. Add after the existing service-status measurement:

```bash
# ---------------------------------------------------------------------------
banner 'the pinned t3 pair --tailscale guard, with no server and no tailnet'
# ---------------------------------------------------------------------------
# Revalidation B of design section 5.5. Harbor's own pre-check is authoritative
# and does not rely on this guard, but the spec requires PR 5 to record what the
# pinned version actually does, so that a version which changes it is a version
# Harbor noticed. There is no running T3 server and no tailnet here, so the
# question this answers is which refusal the guard reaches -- not whether it
# would reuse a mapping, which needs a tailnet and is Revalidation A's job.
pair_rc=0
timeout --kill-after=5s 60s "${vendor_env[@]}" "${prefix}/bin/t3" pair --tailscale \
  >"${work}/pair.out" 2>&1 || pair_rc="$?"
# Fixed words only. The vendor's text stays in the private capture.
if [ "${pair_rc}" = 0 ]; then
  emit pair_guard unexpected-success
  verdict=fail
elif grep -q 'No running T3 Code server found' "${work}/pair.out"; then
  emit pair_guard no-running-server
elif grep -q 'Could not talk to Tailscale' "${work}/pair.out"; then
  emit pair_guard tailscale-unavailable
else
  emit pair_guard unexpected
  verdict=fail
fi
```

- [ ] **Step 2: Run the lane and record the result**

The `pair_guard` value goes in the PR body beside the engines record. Either `no-running-server` or `tailscale-unavailable` is a pass: both are the guard refusing rather than acting, which is the property Harbor depends on not silently changing.

- [ ] **Step 3: Handoff**

Report both halves. If Half A has not been performed, say exactly that and leave `result=unsupported` — do not guess, and do not mark it supported to make a test pass.

### Task 21: the integration lane, the dispatcher, and final verification

**Files:**

- Create: `tests/integration/assert_access.sh`
- Modify: `.github/workflows/integration.yml` (an `access` job)
- Modify: `.github/workflows/lint.yml` (both lists: `assert_access.sh` is covered by `fleet/tests/integration/*.sh`; **verify** and say so)
- Modify: `tests/integration/stub/t3` (the `pair --tailscale` and `connect link|unlink` verbs)
- Modify: `tests/integration/stub/tailscale` (the `serve status` and `serve --https=443 off` verbs)

**Contract.** The integration lane proves the three things the unit lane structurally cannot: that `harbor access set` works at the real config path as the real operator, that the `ssh` row's `sh -lc` probe goes through a real login shell, and that `tailnet` refuses with exit 3 on a release whose probe says unsupported. It does **not** prove pairing end to end — there is no tailnet — and the assert script says so in a comment rather than implying coverage it does not have.

- [ ] **Step 1: Extend the two stubs**

Both stubs dispatch on the argument vector and count arguments, per the PR 4 review: matching on `"${*}"` makes `("serve" "status")` and the single argument `("serve status")` the same string. Follow the existing `it_cmd` pattern exactly.

- [ ] **Step 2: Write `assert_access.sh`**

Follow `assert_provision.sh`'s shape: run as root, drive the operator through `runuser -u "${IT_OPERATOR}" -- env -i` with the fixed variable list, one check per line through the `it_*` helpers, `it_done` at the end. Assert:

- `harbor access get` prints `connect` on a freshly provisioned node
- `harbor access set ssh` rewrites `~/.config/harbor/config` to `access_mode=ssh` at mode `0600`, journals a `config-file` entry, and reports "no further step on this node"
- `harbor access set tailnet` exits 3 and leaves the config at `access_mode=ssh`
- `harbor access set connect` reverts nothing (the `ssh` mode journals no ops) and reports `harbor auth connect`
- a second `harbor access set connect` makes zero mutating stub calls and writes no new `created` or `modified` entry
- the operator lock is released in every case

- [ ] **Step 3: Add the `access` job to `integration.yml`**

`needs: bootstrap`, one runner, no matrix — the crash boundaries this slice adds are covered by the unit lane's `HARBOR_FAIL_AFTER` tests, and a full bootstrap per boundary is not worth a runner for a command that writes one file.

- [ ] **Step 4: Run every lane**

```bash
tests/run_unit.sh 2>&1 | grep -c '^not ok'   # expect 0
```

Then the full CI-exact static lane from Task 4 Step 2, from the repository root.

- [ ] **Step 5: Write the PR body**

It must state, per the spec's merge gate for row 5:

- the changed-line count, from `git diff --shortstat origin/main...HEAD`
- the Revalidation A result verbatim, including the transcript, or an explicit statement that it has not been measured and that `tailnet` therefore ships gated
- the Revalidation B `pair_guard` word from the vendor-smoke record
- that zero `t3 pair` invocations occur in every rejected pre-existing-mapping scenario, with the test names that prove it
- that no mode runs `tailscale serve reset` or `tailscale funnel`, with the test name that proves it
- that no scenario mutates a mapping Harbor did not create, with the test name that proves it
- the scope fence from the table at the top of this plan

- [ ] **Step 6: Handoff for the slice**

---

## Self-review against the spec

**Spec coverage.** Section 8 row 5 names eleven deliverables. `access_mode` config → Task 16. `harbor access` → Tasks 17 and 18. `connect` reporting → Task 10. `harbor auth connect` link step → Task 9. `tailnet` reporting → Task 19. `harbor pair` with Harbor's own Serve pre-check → Tasks 12 to 14. The `t3.environment` descriptor check with the pinned runtime-state field → Tasks 5 to 7. Its `broken` versus `unknown` distinction → Task 7, which is the single hardest thing in this plan and has its own eight-test suite. `ssh` checks → Task 19. Funnel detection → Tasks 1 and 3. The two revalidations recorded in the PR → Task 20.

Row 5's seventeen unit scenarios map as: healthy, needs-login, needs-link, needs-pairing, relay-missing → Tasks 9, 10, 19 (four of these five already exist from PR 4 and are extended); funnel → Tasks 12 and 19; environment-mismatch, environment-non-t3, environment-missing, environment-unknown → Task 7; environment-unknown-post-vendor → Task 13; foreign-serve-mapping, ambiguous-serve-mapping, same-environment-mapping → Task 12; observed-mapping-changed → Task 17; predicted-post-mismatch, serve-interrupted → Task 13. "Rerun mints no pairing token" → Task 13's last test. "Mode switch reverts the previous mode's entries" → Task 17.

**Gaps found and closed while reviewing.** Three, each now a step above rather than a note:

1. `harbor_journal_recover` dispatches `t3-connect-link` to an observer that did not exist in the first draft, so a crashed link would have been permanently undecidable. Task 9 Step 4 adds it.
2. `lib/serve.sh` must be sourced before `lib/t3.sh`, because `harbor_t3_runtime_port` calls `harbor_serve_loopback_host`. Task 5 Step 5 is that ordering, stated where the dependency is introduced rather than discovered at the dispatcher.
3. The first draft put `harbor_access_require_tailnet_supported` in Task 18, after Task 14's `harbor_pair_cmd` had already called it. Task 16 now produces it, before either consumer.

**Type consistency.** The words are fixed and used identically throughout: the mapping is `absent` | `unnormalizable` | `https:443 -> http://<host>:<port>`; the environment verdict is `pass` | `broken` | `unknown`; the runtime reason is `not-running` | `unreadable` | `foreign` | `unrecognized-version` | `not-loopback` | `no-port`; the descriptor reason is `unreachable` | `not-a-descriptor`; the pre-check decision is `create` | `reuse`. Every `harbor_*` name in a later task's "consumes" block is produced by an earlier task's "produces" block.

---

## Corrections

### Correction 35: the stream a vendor does not promise you is still a stream you captured

`harbor_serve_status` was written to capture both streams, with a comment
explaining why that was the careful choice: this vendor prints refusals on stderr,
and a refusal is part of the reading. The reasoning was sound and the code was
wrong, which is the combination worth naming.

A real `tailscale` was available on the development machine — CLI 1.96.4 talking to
a tailscaled 1.98.2, a version skew produced by nothing more exotic than the CLI
and the daemon being upgraded at different times. On that pair, `tailscale serve
status` prints this to **stderr**, unprompted, on every single invocation:

```text
Warning: client version "1.96.4-t41cb72f27" != tailscaled server version "1.98.2-taaf7caef1-gc4a37aed9"
```

and `No serve config` to stdout. With `2>&1`, `HARBOR_SERVE_RAW` begins with
`Warning:`, every prefix match in the adapter misses, and a node with a perfectly
healthy empty Serve config reads as `unnormalizable` rather than `absent`. The
consequences were all downstream and all wrong: `harbor pair` exits 2 with
`pair.serve_unreadable`, and provision's tailnet row goes attended — on a node with
nothing wrong with it. And a node whose `tailscale` package was upgraded under a
running `tailscaled` is not an edge case; it is what every unattended `apt upgrade`
produces.

Three things generalize:

**A vendor's stderr is not a channel it has promised to use only for errors.** The
reason to capture stderr was to catch refusals. The reason not to is that stderr is
also where a CLI puts anything it wants a human to see and did not want in the
data. Those two uses are indistinguishable once merged. Where a vendor offers an
exit code — and this one does — the exit code is the refusal channel, and stdout is
the data channel. Correction 33 said a reader's contract is a claim about something
outside the repository; this is the same claim about a stream boundary.

**The eleven tests that passed all set `HARBOR_SERVE_RAW` directly.** Not one of
them called `harbor_serve_status`. The single function in the file that talks to
the real vendor was the single function with no test, and it is exactly where the
bug was. A suite that mocks at the boundary tests everything except the boundary.
The fix added four tests that drive `harbor_serve_status` through a stub that
writes to both streams, and one of them is a deliberate re-introduction check: with
`2>&1` restored, test 10 goes red, which is what makes the other three mean
something.

**The measurement cost about two minutes.** `tailscale serve status` on an
already-installed client, with no tailnet mutation of any kind. The empty-state
wording `No serve config` was confirmed correct at the same time, which is the
other half of the result: the fixtures were not all wrong, and knowing which ones
were right required the same two minutes as finding the one that was.

### Correction 36: `tailscale serve --bg` is not guaranteed to return

While capturing a populated Serve mapping for the fixtures, `tailscale serve --bg
--https=443 http://127.0.0.1:3773` was run on the same real client. It **hung
indefinitely** — three attempts, one over two minutes, one with stdin closed and an
alarm, all producing no stdout, only the version-skew warning on stderr, and in
every case leaving the Serve config untouched at `{}`. It never applied anything
and it never returned.

The populated-mapping fixtures are therefore still hand-written and still marked
unverified, which is a gap this plan should not pretend it closed. But the failed
measurement produced something more valuable than the fixture would have:

**Slice 5d runs this exact command with no timeout.** `harbor_pair` calls
`harbor_t3_run "${home}" pair --tailscale`, streams deliberately untouched so the
pairing URL reaches the operator, and the pinned `t3` shells out to `tailscale
serve --bg --https=443 http://127.0.0.1:<port>` internally. If that call can hang
on a developer's Mac it can hang on a node, and `harbor pair` would then hang
**after** writing its `prepared` journal entry and **before** its post-verify —
holding the operator lock the whole time. The operator sees nothing, `^C` takes the
exit-4 interrupt path, and the entry is left for recovery, which is at least
correct; but an unbounded hang inside a locked transaction is not a thing to
discover in production.

Task 13 must therefore bound the vendor call. The bound cannot be a plain
`timeout`, because that would also truncate the operator's own time to scan a QR
code — the vendor is interactive by design. The distinction to implement is that
Harbor bounds the part it is waiting on, not the part the human is: `t3 pair
--tailscale` is given a generous wall-clock ceiling (the pinned vendor's own
`TAILSCALE_SERVE_TIMEOUT` is 10s and its `PAIR_PROBE_TIMEOUT` 2500ms, so a ceiling
of several minutes is far past any legitimate vendor-side wait), and on expiry
Harbor takes the same path as a vendor that created nothing: re-read Serve, and
decide from the world rather than from the exit code. That is the path Task 13
already has; it just needs to be reachable from a timeout as well as from a
non-zero exit.

The general lesson is the one Correction 34 started: a measurement that fails to
produce the artifact you wanted has still measured something. Here the artifact was
a fixture and the finding was a hang in a code path two slices away, and the
finding was worth more.

### Correction 37: two halves of a parser that disagree, and the half that wins

`harbor_serve_mapping` shipped to review reading the **first line** to decide which
port the listener was on, and then grepping the **whole body** for a proxy target.
Each half is defensible alone. Together they describe two different documents.

`tailscale serve status` prints one header per listener with that listener's
handlers indented beneath it. Give it a node with an 8443 listener above its 443
one and the halves disagree outright: the first-line read says "this is 8443, so
there is nothing at 443" and returns `absent`, while the grep it never reaches
would have returned the 443 listener's target. The half that won is the one that
returns `absent` — and `harbor_pair_precheck` treats `absent` as permission to
create a mapping. A parse bug therefore ended in Harbor calling the vendor to
mutate Serve on a node that already had a 443 listener, defeating the single
invariant `lib/serve.sh` exists to hold.

The fix walks the body listener by listener, tracks which listener it is inside,
and takes a target only from the 443 one. It also names two states the short
version could not express: two root handlers in one listener is `unnormalizable`
rather than whichever the parser saw last, and a 443 listener with handlers but no
root handler is `unnormalizable` rather than `absent`.

Three things generalize:

**A reader built from two independent scans of the same text has a consistency
requirement nobody wrote down.** The first-line read and the global grep were never
checked against each other, and there was no place in the code where they met and
could have been. The walk has one cursor and one notion of "which listener am I
in", so the question cannot arise. Prefer the parser that cannot hold two opinions
over the one that happens to hold the same opinion on your fixtures.

**All seven original fixtures were single-listener.** They agreed with the parser
because they were written from the same mental model as the parser, which is
correction 33 restated at the level of shape rather than value: the fixtures
covered the cases the author had already thought of, so passing them measured only
that the author was self-consistent. The bug needed a fixture whose *structure*,
not whose *content*, was new.

**The reviewer found this and the measurement did not.** Correction 35 came from
running the real vendor; this came from Greptile reading the code and asking what
happens with two listeners. Neither technique subsumes the other: measurement finds
the things the world does that you did not imagine, and review finds the things
your code does that you did not intend. A change to a vendor adapter wants both,
and this slice needed both.

## Open questions for the owner

1. **Revalidation A needs a real node on a real tailnet, and only the owner has one.** Nothing in Tasks 1 to 19 or 21 waits on it: `tailnet` is fully implemented and fully unit-tested behind a gate that reads one data file. But until that file records `supported`, `tailnet` is a mode Harbor refuses at runtime, and a node that wants tailnet-only routing cannot have it. The measurement is the six commands in Task 20 Half A and takes a few minutes on a node that is already bootstrapped and joined.
2. **PR 5 is five stacked PRs, like PR 4 was.** Slices 5a through 5d are pure additions with no behavior change to any shipped command until 5c changes one message and 5e changes the mode vocabulary. If a smaller first landing is preferred, 5a and 5b can merge as a single "adapters only" PR that ships no new subcommand at all.
