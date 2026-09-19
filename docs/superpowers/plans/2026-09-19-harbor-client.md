# Harbor PR 6 — macOS client Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `harbor client setup` and `harbor client verify`, run from a clone on the operator's Mac, so a Mac can be configured for and can prove its reach to a provisioned node in every access mode, with no `jq` and no dependency on PR 7 having landed.

**Architecture:** `fleet/lib/client.sh` holds everything both halves need — the Tailscale-client preflight, the MagicDNS lookup, and the JSON reader that flattens a document once through macOS's built-in `/usr/bin/osascript -l JavaScript` into the one-key-per-line shape the rest of the repository already reads. `fleet/client/setup.sh` writes `~/.ssh/harbor.conf` and journals the `~/.ssh/config` include; `fleet/client/verify.sh` pings the node, runs `ssh harbor-node harbor status --json`, classifies all five documented exit codes plus the pre-PR-7 reply, and then applies the one per-mode requirement the node's own reported mode selects. `bin/harbor` gains a `client` arm that, alone among subcommands, does not run the installed-entrypoint check.

**Tech Stack:** bash 3.2 subset (this code runs on stock macOS), `/usr/bin/osascript -l JavaScript`, the app-bundled Tailscale CLI, OpenSSH, Bats on `macos-14` and `macos-latest`.

## Global Constraints

Every task's requirements implicitly include this section. Values are copied verbatim from the spec and from the conventions the merged PRs established.

- **bash 3.2 subset** for `fleet/lib/client.sh`, `fleet/client/*.sh` and `fleet/bin/harbor`. Forbidden: `readlink -f`, associative arrays, `mapfile`, `${var^^}`, `+=` on arrays, extglob, `[[ ]]`, `=~`, `printf -v`, and a `case` statement lexically inside `$( )`. `fleet/tests/unit/**` is bash 5 and may use all of these.
- **Everything runs under `set -euo pipefail`.** Any variable a reader consumes that a caller might not have set is read as `${VAR:-}`.
- **Stock macOS lacks** `sha256sum`, `stat -c`, `sed -i`, `date -d`, `readlink -f`, `grep -P`, `timeout`, GNU awk extensions and `cat -A`. Use `shasum -a 256`, `stat -f`, a temp file and `mv`, and `perl`-free alternatives. This is not a portability nicety here: macOS is the only platform this code runs on.
- **Exit codes are exactly five:** 0 success, 1 degraded or attended, 2 broken or apply failed, 3 precondition or usage, 4 interrupted. `harbor_die` does `exit "${code}"` verbatim — never pass it a captured status from another program.
- **Journal write protocol (spec 3.7):** inspect → write `prepared` → mutate → mark `applied`. Ownership vocabulary: `created`, `modified`, `observed`. `harbor_journal_recover` only processes `phase = prepared`; `reverted` is the one phase recovery skips forever, so a premature `reverted` strands an artifact permanently.
- **No secret reaches a command line, a log line or a journal entry.** The client never prints, copies or inspects a vendor credential store, and never logs a vendor tool out.
- **Harbor never writes, creates or removes anything under the vendor's `~/.t3`.**
- **Harbor never invokes `tailscale funnel` in any code path, and never runs `tailscale serve reset`.** The client is read-only towards Tailscale: it runs `status` and `ping` and nothing else.
- **PR 6 must not depend on PR 7.** No CI job may require a real node or a node that has `harbor status`. Every remote reply in the test lane is a fixture.
- **CI-exact static gate.** ShellCheck: `shellcheck -s bash -x -a -S warning -P 'SCRIPTDIR/..:SCRIPTDIR/../..' --enable=require-variable-braces <explicit list>`. shfmt: `shfmt -i 2 -ci -bn -d <same list, with fleet/lib and fleet/node as directories>`. `shfmt` lives at `$HOME/go/bin/shfmt`. Also `fleet/tests/lint/placeholder_scan.sh` (walks **tracked** files, so `git add` first; it permits exactly one MagicDNS name, `TAILNET.ts.net`) and `fleet/tests/lint/engines_check.sh`. markdownlint: `npx --yes markdownlint-cli@0.41.0 --config .markdownlint.yml '*.md' 'docs/**/*.md' 'fleet/**/*.md' --ignore fleet/tests/vendor`.
- **Unit tests must never touch** `/var/lib`, `/etc`, `/usr/local`, `/opt`, the real `~/.local/state/harbor`, the real `~/.ssh`, the real `~/.t3`, or the real `~/.config/systemd/user/`, and must never use `sudo`.
- **bats-assert has no `refute_equal`.** A new worktree needs `git submodule update --init --recursive`.

## The check-id contract with PR 7

`client verify` reads the node's `harbor status --json` document. PR 7 has not been written, so this plan **pins the vocabulary PR 7 must emit** rather than guessing at it later. These are the only fields `verify` reads:

| Field | Meaning | Used for |
|---|---|---|
| `checks[].id` | the check's stable identifier | selecting the rows below |
| `checks[].state` | `pass`, `warn`, `fail` or `unknown` | the verdict of a row |
| `checks[].detail` | one human line | the message `verify` prints for a failing row |
| `access.mode` | `connect`, `tailnet` or `ssh` | choosing which per-mode row applies |
| `error` | present only on exit 3 and exit 4 documents | classifying a single-`error` object |
| `subcommand` | present only on `error = unknown_subcommand` | recognizing the pre-PR-7 node |

| Mode | Required row | Requirement |
|---|---|---|
| `connect` | `t3.connect_link` | `state = pass` |
| `tailnet` | `t3.environment` | `state = pass`, **and** the Mac completes a TLS connection to `https://harbor-node.TAILNET.ts.net/` |
| `ssh` | `ssh.node` | `state = pass` |

`t3.environment` and `ssh.node` are already the identifiers `fleet/node/provision.sh` uses for the same two conditions; `t3.connect_link` matches the `t3-connect-link` journal op. When PR 7 is planned, this table is the contract it satisfies. If PR 7 chooses different identifiers, PR 7 changes this table and `fleet/client/verify.sh` together — `verify` must never silently treat a missing row as a pass.

---

### Task 1: `fleet/lib/client.sh` and the JSON reader

**Files:**

- Create: `fleet/lib/client.sh`
- Test: `fleet/tests/unit/lib/client_json.bats`

**Interfaces:**

- Consumes: `harbor_die`, `harbor_msg`, `harbor_log` from `fleet/lib/log.sh`.
- Produces: `harbor_client_json_flatten` (stdin → flattened stdout), `harbor_client_json_field FLATFILE PATH` (a field's value, decoded), `harbor_client_json_has FLATFILE PATH` (exit 0 when the path is present).

The reader flattens the whole document **once**. Each `osascript` spawn costs about a tenth of a second, and a per-field reader would spawn one for every field on every row; more importantly, a flattened document is a plain text file that a test can assert against directly, which a chain of live queries is not.

The JSON arrives on **stdin**, never as an argument. A status document is remote input, and an argument is visible in the process table to every user on the Mac.

Values are emitted JSON-encoded, so a value containing a newline or a tab still occupies exactly one line. `harbor_client_json_field` decodes the three escapes that can appear in a value Harbor emits.

- [ ] **Step 1: Write the failing test**

```bash
# fleet/tests/unit/lib/client_json.bats
setup() {
  load '../test_helper'
  harbor_load_lib log.sh
  harbor_load_lib client.sh
}

@test "an object flattens to one dotted path per scalar" {
  run harbor_client_json_flatten <<'JSON'
{"access":{"mode":"connect"},"n":3,"ok":true,"nil":null}
JSON
  assert_success
  assert_line "$(printf 'access.mode\t"connect"')"
  assert_line "$(printf 'n\t3')"
  assert_line "$(printf 'ok\ttrue')"
  assert_line "$(printf 'nil\tnull')"
}

@test "an array flattens to numeric path components" {
  run harbor_client_json_flatten <<'JSON'
{"checks":[{"id":"ssh.node","state":"pass"},{"id":"t3.environment","state":"fail"}]}
JSON
  assert_success
  assert_line "$(printf 'checks.0.id\t"ssh.node"')"
  assert_line "$(printf 'checks.1.state\t"fail"')"
}

@test "a value containing a newline or a tab still occupies one line" {
  run harbor_client_json_flatten <<'JSON'
{"detail":"first\nsecond\tthird"}
JSON
  assert_success
  assert_equal "${#lines[@]}" 1
  assert_line "$(printf 'detail\t"first\\nsecond\\tthird"')"
}

@test "a body that is not JSON fails rather than emitting nothing" {
  run harbor_client_json_flatten <<'BODY'
harbor: unknown subcommand: status
BODY
  assert_failure
}

@test "an empty body fails rather than flattening to nothing" {
  run harbor_client_json_flatten </dev/null
  assert_failure
}

@test "a field is returned decoded, and a missing one is distinguishable from an empty one" {
  printf 'a\t"x\\ty"\nb\t""\n' >"${BATS_TEST_TMPDIR}/flat"
  run harbor_client_json_field "${BATS_TEST_TMPDIR}/flat" a
  assert_success
  assert_output "$(printf 'x\ty')"
  run harbor_client_json_field "${BATS_TEST_TMPDIR}/flat" b
  assert_success
  assert_output ''
  run harbor_client_json_has "${BATS_TEST_TMPDIR}/flat" b
  assert_success
  run harbor_client_json_has "${BATS_TEST_TMPDIR}/flat" c
  assert_failure
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `fleet/tests/run_unit.sh fleet/tests/unit/lib/client_json.bats`
Expected: FAIL, `harbor_client_json_flatten: command not found`.

- [ ] **Step 3: Write the implementation**

```bash
# fleet/lib/client.sh
# The Mac half of Harbor (design section 5.5). Everything here runs on stock
# macOS, so it is bash 3.2 and it uses only what a Mac ships with: no jq, no
# GNU coreutils, no Homebrew.

# harbor_client_json_flatten: JSON on stdin, one "path<TAB>json-value" line per
# scalar on stdout. Nonzero, and nothing on stdout, for a body that is not JSON.
#
# macOS's built-in JavaScript host is the whole JSON dependency (design section
# 5.5: "client/ and PR 6 need no jq on the Mac"). The document arrives on stdin
# rather than as an argument because it is remote input and an argument is
# visible in the process table to every user on this Mac.
#
# Flattened once rather than queried per field: each osascript spawn costs about
# a tenth of a second, and a flattened document is a plain file a test can assert
# against, which a chain of live queries is not.
#
# Values stay JSON-encoded so a value carrying a newline or a tab still occupies
# exactly one line. harbor_client_json_field decodes them on the way out.
harbor_client_json_flatten() {
  /usr/bin/osascript -l JavaScript -e '
    ObjC.import("Foundation");
    var input = $.NSString.alloc.initWithDataEncoding(
      $.NSFileHandle.fileHandleWithStandardInput.readDataToEndOfFile,
      $.NSUTF8StringEncoding);
    if (input.js === undefined) { throw new Error("input is not UTF-8"); }
    var doc = JSON.parse(input.js);
    var out = [];
    function walk(path, value) {
      if (value !== null && typeof value === "object") {
        var keys = Array.isArray(value)
          ? value.map(function (_, i) { return String(i); })
          : Object.keys(value);
        if (keys.length === 0) { return; }
        keys.forEach(function (k) {
          walk(path === "" ? k : path + "." + k, value[k]);
        });
        return;
      }
      out.push(path + "\t" + JSON.stringify(value));
    }
    walk("", doc);
    out.join("\n");
  '
}

# harbor_client_json_field FLATFILE PATH: the value at PATH, decoded. A string
# loses its quotes and its escapes; a number, boolean or null is printed as it
# stands. An absent path prints nothing and still succeeds, which is why callers
# that care about the difference ask harbor_client_json_has first.
harbor_client_json_field() {
  local raw
  raw="$(sed -n "s/^${2}$(printf '\t')//p" "${1}" | sed -n 1p)"
  case "${raw}" in
    '"'*'"')
      raw="${raw#\"}"
      raw="${raw%\"}"
      # One left-to-right pass, not a chain of substitutions. A chain decodes the
      # escapes in whatever order it is written in, so the literal two characters
      # \n -- which arrive encoded as \\n -- get their second backslash eaten by
      # the \n rule and come out as a real newline. Measured: the sed chain gets
      # "lit \\n not newline" wrong and this gets it right.
      #
      # Only the escapes Harbor's own JSON writer emits (lib/journal.sh's
      # harbor_json_escape) and the two whitespace ones a detail line can carry.
      # An escape this does not know stays as written rather than being guessed
      # at: a wrong decoding of a remote detail line is worse than a literal one.
      printf '%s' "${raw}" | awk '{
        s = $0; out = ""; i = 1
        while (i <= length(s)) {
          c = substr(s, i, 1)
          if (c == "\\" && i < length(s)) {
            n = substr(s, i + 1, 1)
            if (n == "n") { out = out "\n"; i += 2; continue }
            if (n == "t") { out = out "\t"; i += 2; continue }
            if (n == "\"") { out = out "\""; i += 2; continue }
            if (n == "\\") { out = out "\\"; i += 2; continue }
          }
          out = out c; i++
        }
        printf "%s", out
      }'
      ;;
    *) printf '%s' "${raw}" ;;
  esac
}

# harbor_client_json_has FLATFILE PATH: exit 0 when PATH is present, whatever its
# value. "Absent" and "present and empty" are different answers about a node, and
# a verifier that cannot tell them apart will call a missing check a passing one.
harbor_client_json_has() {
  grep -q "^${2}$(printf '\t')" "${1}"
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `fleet/tests/run_unit.sh fleet/tests/unit/lib/client_json.bats`
Expected: PASS, 6 tests.

**Measured on macOS 25.2 before this plan was written**, so the implementer is
not discovering it: the JXA above flattens the nested document, the array, and
the escaped value exactly as the tests expect; a non-JSON body, an empty body and
invalid UTF-8 each exit 1 with nothing on stdout. One behaviour to know about —
a top-level scalar such as `3` is valid JSON and flattens to a single line with
an empty path, exit 0. `harbor_client_json_flatten` therefore answers
"parseable", not "a status document"; every caller in Task 6 and Task 7 must
establish the fields it needs with `harbor_client_json_has` rather than treating
a successful flatten as a well-formed reply.

- [ ] **Step 5: Add the escape-ordering test**

The one case a substitution chain gets wrong, so the decoder cannot quietly be rewritten as one later:

```bash
@test "an encoded literal backslash-n stays two characters" {
  printf 'x\t"lit \\\\n not newline"\n' >"${BATS_TEST_TMPDIR}/flat"
  run harbor_client_json_field "${BATS_TEST_TMPDIR}/flat" x
  assert_success
  assert_output 'lit \n not newline'
}
```

- [ ] **Step 6: Run the static gate**

Add `fleet/lib/client.sh` to nothing yet — it is matched by the existing `fleet/lib/*.sh` glob in both ShellCheck and shfmt lists. Run both with the exact CI command lines.
Expected: clean.

- [ ] **Step 7: Commit**

```bash
git add fleet/lib/client.sh fleet/tests/unit/lib/client_json.bats
git commit -m "The Mac's JSON reader: flatten once through the built-in JavaScript host"
```

---

### Task 2: the Tailscale client preflight

**Files:**

- Modify: `fleet/lib/client.sh`
- Test: `fleet/tests/unit/lib/client_tailscale.bats`

**Interfaces:**

- Consumes: `harbor_client_json_flatten`, `harbor_client_json_field`, `harbor_client_json_has` from Task 1.
- Produces: `harbor_client_tailscale_cli` (the path to the app-bundled CLI, or nonzero), `harbor_client_tailscale_status FLATFILE` (writes the flattened status, or nonzero), `harbor_client_magicdns FLATFILE HOSTNAME` (the node's MagicDNS name without its trailing dot), `harbor_client_preflight FLATFILE` (the whole gate).

The Mac's Tailscale is the app-bundled CLI at `/Applications/Tailscale.app/Contents/MacOS/Tailscale`, which is where the App Store and the standalone build both put it. `HARBOR_CLIENT_TAILSCALE` overrides it so the test lane can shim it; that variable is a test seam and is documented as one.

Three refusals, all exit 3, all before anything is written: no CLI, a backend that is not `Running`, and MagicDNS off. Section 5.5 names the last one explicitly.

- [ ] **Step 1: Write the failing test**

```bash
# fleet/tests/unit/lib/client_tailscale.bats
setup() {
  load '../test_helper'
  harbor_load_lib log.sh
  harbor_load_lib client.sh
  HARBOR_CLIENT_TAILSCALE="${BATS_TEST_TMPDIR}/tailscale"
  export HARBOR_CLIENT_TAILSCALE
  FLAT="${BATS_TEST_TMPDIR}/flat"
}

# The shim answers with whatever fixture the test selected. Writing it as a file
# rather than a function matters: harbor_client_tailscale_status runs it as a
# command, and a function would let a bug that forgets to invoke it pass.
shim() {
  cat >"${HARBOR_CLIENT_TAILSCALE}" <<EOF
#!/bin/bash
cat "${1}"
EOF
  chmod 0755 "${HARBOR_CLIENT_TAILSCALE}"
}

fixture() {
  printf '%s' "${1}" >"${BATS_TEST_TMPDIR}/status.json"
  shim "${BATS_TEST_TMPDIR}/status.json"
}

@test "a missing CLI is a precondition naming where the app puts it" {
  rm -f "${HARBOR_CLIENT_TAILSCALE}"
  run harbor_client_preflight "${FLAT}"
  assert_failure 3
  assert_output --partial 'Tailscale'
}

@test "a backend that is not Running is a precondition, not a failure to read" {
  fixture '{"BackendState":"NeedsLogin","MagicDNSSuffix":"TAILNET.ts.net","Peer":{}}'
  run harbor_client_preflight "${FLAT}"
  assert_failure 3
  assert_output --partial 'NeedsLogin'
}

@test "MagicDNS off is a precondition, which section 5.5 names" {
  fixture '{"BackendState":"Running","MagicDNSSuffix":"","Peer":{}}'
  run harbor_client_preflight "${FLAT}"
  assert_failure 3
  assert_output --partial 'MagicDNS'
}

@test "a logged-in client with MagicDNS on passes and leaves the status flattened" {
  fixture '{"BackendState":"Running","MagicDNSSuffix":"TAILNET.ts.net","Peer":{"k1":{"HostName":"harbor-node","DNSName":"harbor-node.TAILNET.ts.net."}}}'
  run harbor_client_preflight "${FLAT}"
  assert_success
  harbor_client_preflight "${FLAT}"
  assert_equal 'Running' "$(harbor_client_json_field "${FLAT}" BackendState)"
}

@test "the node's MagicDNS name comes back without its trailing dot" {
  fixture '{"BackendState":"Running","MagicDNSSuffix":"TAILNET.ts.net","Peer":{"k1":{"HostName":"other","DNSName":"other-node.TAILNET.ts.net."},"k2":{"HostName":"harbor-node","DNSName":"harbor-node.TAILNET.ts.net."}}}'
  harbor_client_preflight "${FLAT}"
  run harbor_client_magicdns "${FLAT}" harbor-node
  assert_success
  assert_output 'harbor-node.TAILNET.ts.net'
}

@test "a tailnet with no such peer is a precondition, never an empty host name" {
  fixture '{"BackendState":"Running","MagicDNSSuffix":"TAILNET.ts.net","Peer":{"k1":{"HostName":"other","DNSName":"other-node.TAILNET.ts.net."}}}'
  harbor_client_preflight "${FLAT}"
  run harbor_client_magicdns "${FLAT}" harbor-node
  assert_failure 3
  assert_output --partial 'harbor-node'
}

@test "a status the CLI cannot produce is a precondition, not a crash" {
  cat >"${HARBOR_CLIENT_TAILSCALE}" <<'EOF'
#!/bin/bash
printf 'failed to connect to local tailscaled\n' >&2
exit 1
EOF
  chmod 0755 "${HARBOR_CLIENT_TAILSCALE}"
  run harbor_client_preflight "${FLAT}"
  assert_failure 3
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `fleet/tests/run_unit.sh fleet/tests/unit/lib/client_tailscale.bats`
Expected: FAIL, `harbor_client_preflight: command not found`.

- [ ] **Step 3: Write the implementation**

```bash
# Appended to fleet/lib/client.sh

# The app-bundled CLI, which is where both the App Store build and the standalone
# build put it. HARBOR_CLIENT_TAILSCALE overrides it; that is a test seam and
# nothing else reads it.
harbor_client_tailscale_cli() {
  local cli="${HARBOR_CLIENT_TAILSCALE:-/Applications/Tailscale.app/Contents/MacOS/Tailscale}"
  [ -x "${cli}" ] || return 1
  printf '%s' "${cli}"
}

# harbor_client_tailscale_status FLATFILE: the Mac's own tailscale status,
# flattened into FLATFILE. Nonzero when the CLI could not answer or did not
# answer JSON -- both of which are preconditions to the caller, never findings.
harbor_client_tailscale_status() {
  local cli
  cli="$(harbor_client_tailscale_cli)" || return 1
  "${cli}" status --json 2>/dev/null | harbor_client_json_flatten >"${1}" || return 1
  [ -s "${1}" ] || return 1
}

# harbor_client_preflight FLATFILE: the three things that must be true of this
# Mac before anything is written or reached (design section 5.5).
harbor_client_preflight() {
  local flat="${1}" backend suffix
  harbor_client_tailscale_cli >/dev/null \
    || harbor_die 3 client.tailscale_absent "the Tailscale client is not installed on this Mac, or its CLI is not where the app puts it (/Applications/Tailscale.app/Contents/MacOS/Tailscale); install Tailscale and log in, then rerun"
  harbor_client_tailscale_status "${flat}" \
    || harbor_die 3 client.tailscale_unreadable "the Tailscale client is installed but did not answer 'status --json' on this Mac; open the app and make sure it is running, then rerun"
  backend="$(harbor_client_json_field "${flat}" BackendState)"
  [ "${backend}" = Running ] \
    || harbor_die 3 client.tailscale_not_running "the Tailscale client on this Mac reports BackendState ${backend}, not Running; log in through the app, then rerun"
  suffix="$(harbor_client_json_field "${flat}" MagicDNSSuffix)"
  # Section 5.5 names this one: without MagicDNS there is no harbor-node name to
  # put in an ssh block and no https://harbor-node.TAILNET.ts.net/ to reach, so
  # this is a precondition for both halves rather than a warning for one.
  [ -n "${suffix}" ] \
    || harbor_die 3 client.magicdns_off "this tailnet has MagicDNS turned off, so the node has no name this Mac can use; turn MagicDNS on in the Tailscale admin console, then rerun"
}

# harbor_client_magicdns FLATFILE HOSTNAME: the peer's MagicDNS name, without the
# trailing dot the status document carries. Refusing here rather than returning
# an empty string is the point: an empty HostName in an ssh block is a block that
# silently connects somewhere else.
harbor_client_magicdns() {
  local flat="${1}" want="${2}" key name
  # The tab in the sed pattern is written with printf rather than typed: a literal
  # tab in a source file is invisible and the next editor to touch this line will
  # turn it into spaces.
  for key in $(sed -n "s/^Peer\.\([^.]*\)\.HostName$(printf '\t').*\$/\1/p" "${flat}"); do
    if [ "$(harbor_client_json_field "${flat}" "Peer.${key}.HostName")" = "${want}" ]; then
      name="$(harbor_client_json_field "${flat}" "Peer.${key}.DNSName")"
      printf '%s' "${name%.}"
      return 0
    fi
  done
  harbor_die 3 client.node_absent "this Mac's tailnet has no node named ${want}; run 'harbor auth tailscale' on the node first, and check it appears in the Tailscale admin console"
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `fleet/tests/run_unit.sh fleet/tests/unit/lib/client_tailscale.bats`
Expected: PASS, 7 tests.

- [ ] **Step 5: Mutation-check the MagicDNS refusal**

Temporarily replace the `harbor_die` in `harbor_client_magicdns` with `printf '' ; return 0`. Re-run.
Expected: the "no such peer" test goes red. Restore.

- [ ] **Step 6: Commit**

```bash
git add fleet/lib/client.sh fleet/tests/unit/lib/client_tailscale.bats
git commit -m "The Mac's three preconditions, and the node's name without its trailing dot"
```

---

### Task 3: the `~/.ssh/harbor.conf` block

**Files:**

- Modify: `fleet/lib/client.sh`
- Test: `fleet/tests/unit/lib/client_sshconf.bats`

**Interfaces:**

- Consumes: Task 2's `harbor_client_magicdns`.
- Produces: `harbor_client_conf_body MAGICDNS USER` (the file's exact bytes on stdout), `harbor_client_conf_write PATH MAGICDNS USER` (write atomically at `0600`).

The block is the one section 5.5 specifies and nothing more: `HostName` from the node's MagicDNS name, `User harbor`, `IdentitiesOnly yes`. It also serves T3's desktop-managed SSH launch, which is why the host alias is exactly `harbor-node` and not something Harbor invents per node.

Written through a temp file and `mv`, at `0600` before it is moved: an ssh configuration that exists world-readable for even an instant is an ssh configuration that was world-readable.

- [ ] **Step 1: Write the failing test**

```bash
# fleet/tests/unit/lib/client_sshconf.bats
setup() {
  load '../test_helper'
  harbor_load_lib log.sh
  harbor_load_lib client.sh
}

@test "the block is exactly the three directives section 5.5 names" {
  run harbor_client_conf_body harbor-node.TAILNET.ts.net harbor
  assert_success
  assert_line 'Host harbor-node'
  assert_line '  HostName harbor-node.TAILNET.ts.net'
  assert_line '  User harbor'
  assert_line '  IdentitiesOnly yes'
}

@test "the file is written 0600 and its bytes are the body" {
  local out="${BATS_TEST_TMPDIR}/harbor.conf"
  harbor_client_conf_write "${out}" harbor-node.TAILNET.ts.net harbor
  assert_equal 600 "$(stat -f '%OLp' "${out}")"
  assert_equal "$(harbor_client_conf_body harbor-node.TAILNET.ts.net harbor)" "$(cat "${out}")"
}

@test "a rewrite replaces the file rather than appending to it" {
  local out="${BATS_TEST_TMPDIR}/harbor.conf"
  harbor_client_conf_write "${out}" harbor-node.TAILNET.ts.net harbor
  harbor_client_conf_write "${out}" other-node.TAILNET.ts.net harbor
  assert_equal 1 "$(grep -c '^Host harbor-node$' "${out}")"
  assert_equal '  HostName other-node.TAILNET.ts.net' "$(sed -n 2p "${out}")"
}

@test "no temp file survives a successful write" {
  local out="${BATS_TEST_TMPDIR}/harbor.conf"
  harbor_client_conf_write "${out}" harbor-node.TAILNET.ts.net harbor
  assert_equal 1 "$(find "${BATS_TEST_TMPDIR}" -maxdepth 1 -type f | wc -l | tr -d ' ')"
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `fleet/tests/run_unit.sh fleet/tests/unit/lib/client_sshconf.bats`
Expected: FAIL, `harbor_client_conf_body: command not found`.

- [ ] **Step 3: Write the implementation**

```bash
# Appended to fleet/lib/client.sh

# The block design section 5.5 specifies, and nothing else. The alias is exactly
# "harbor-node" because T3's desktop-managed SSH launch uses this same block, so
# the name is part of the contract rather than a label Harbor is free to choose.
harbor_client_conf_body() {
  printf 'Host harbor-node\n'
  printf '  HostName %s\n' "${1}"
  printf '  User %s\n' "${2}"
  printf '  IdentitiesOnly yes\n'
}

# Written at 0600 before it moves into place. An ssh configuration that is
# world-readable for an instant was world-readable.
harbor_client_conf_write() {
  local path="${1}" tmp
  tmp="${path}.tmp.$$"
  harbor_client_conf_body "${2}" "${3}" >"${tmp}"
  chmod 0600 "${tmp}"
  mv -f "${tmp}" "${path}"
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `fleet/tests/run_unit.sh fleet/tests/unit/lib/client_sshconf.bats`
Expected: PASS, 4 tests.

- [ ] **Step 5: Commit**

```bash
git add fleet/lib/client.sh fleet/tests/unit/lib/client_sshconf.bats
git commit -m "The harbor-node ssh block, written 0600 before it moves into place"
```

---

### Task 4: the journaled `~/.ssh/config` include

**Files:**

- Modify: `fleet/lib/client.sh`
- Test: `fleet/tests/unit/lib/client_include.bats`

**Interfaces:**

- Consumes: `harbor_journal_create`, `harbor_journal_set_phase`, `harbor_journal_observe`, `harbor_observe_file` from `fleet/lib/journal.sh`.
- Produces: `harbor_client_include_line` (the exact line), `harbor_client_include_present PATH` (exit 0 when already there), `harbor_client_include_add STATE_ROOT PATH` (journaled as `ssh-include`), `harbor_client_include_remove STATE_ROOT PATH`.

`Include ~/.ssh/harbor.conf` must be added **once** to `~/.ssh/config`, and `ssh` requires an `Include` to precede any `Host` block it is meant to affect — so it is prepended, not appended. A second run finds it and writes nothing, and journals nothing.

The ownership word is the honest one: `modified` when `~/.ssh/config` already existed (Harbor changed someone else's file), `created` when it did not. This is the distinction Task 5's `--remove` turns on, and getting it wrong here is what makes a removal either refuse to run or delete a file it did not create.

- [ ] **Step 1: Write the failing test**

```bash
# fleet/tests/unit/lib/client_include.bats
setup() {
  load '../test_helper'
  harbor_load_lib log.sh
  harbor_load_lib journal.sh
  harbor_load_lib client.sh
  ROOT="${BATS_TEST_TMPDIR}/state"
  CONFIG="${BATS_TEST_TMPDIR}/ssh/config"
  mkdir -p "${ROOT}/journal" "$(dirname "${CONFIG}")"
}

entry() {
  find "${ROOT}/journal" -name '*.json' | LC_ALL=C sort | sed -n "${1:-1}p"
}

@test "the include goes in once, at the top, and is journaled created when there was no config" {
  harbor_client_include_add "${ROOT}" "${CONFIG}"
  assert_equal "$(harbor_client_include_line)" "$(sed -n 1p "${CONFIG}")"
  assert_equal created "$(harbor_journal_string "$(entry)" ownership)"
  assert_equal applied "$(harbor_journal_string "$(entry)" phase)"
}

@test "an existing config is modified, not created, and keeps every line it had" {
  printf 'Host example\n  User someone\n' >"${CONFIG}"
  harbor_client_include_add "${ROOT}" "${CONFIG}"
  assert_equal "$(harbor_client_include_line)" "$(sed -n 1p "${CONFIG}")"
  assert_line --index 1 'Host example'
  run cat "${CONFIG}"
  assert_line '  User someone'
  assert_equal modified "$(harbor_journal_string "$(entry)" ownership)"
}

@test "the include precedes every Host block, because ssh ignores one that does not" {
  printf 'Host example\n  User someone\n' >"${CONFIG}"
  harbor_client_include_add "${ROOT}" "${CONFIG}"
  local include_at host_at
  include_at="$(grep -n '^Include ' "${CONFIG}" | cut -d: -f1)"
  host_at="$(grep -n '^Host ' "${CONFIG}" | head -1 | cut -d: -f1)"
  [ "${include_at}" -lt "${host_at}" ]
}

@test "a second run adds nothing and journals nothing" {
  harbor_client_include_add "${ROOT}" "${CONFIG}"
  local before after
  before="$(shasum -a 256 "${CONFIG}" | cut -d' ' -f1)"
  harbor_client_include_add "${ROOT}" "${CONFIG}"
  after="$(shasum -a 256 "${CONFIG}" | cut -d' ' -f1)"
  assert_equal "${before}" "${after}"
  assert_equal 1 "$(find "${ROOT}/journal" -name '*.json' | wc -l | tr -d ' ')"
}

@test "an include already present by the operator's own hand is left alone and journaled observed" {
  printf '%s\nHost example\n' "$(harbor_client_include_line)" >"${CONFIG}"
  harbor_client_include_add "${ROOT}" "${CONFIG}"
  assert_equal 0 "$(find "${ROOT}/journal" -name '*.json' | wc -l | tr -d ' ')"
}

@test "the entry is prepared before the file changes and applied after" {
  HARBOR_FAIL_AFTER=client-include-prepared run harbor_client_include_add "${ROOT}" "${CONFIG}"
  assert_failure
  assert_equal prepared "$(harbor_journal_string "$(entry)" phase)"
  assert_equal "$(harbor_journal_raw "$(entry)" pre_state)" "$(harbor_journal_observe file "${CONFIG}")"
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `fleet/tests/run_unit.sh fleet/tests/unit/lib/client_include.bats`
Expected: FAIL, `harbor_client_include_add: command not found`.

- [ ] **Step 3: Write the implementation**

```bash
# Appended to fleet/lib/client.sh

# The literal design section 5.5 names. Spelled with ~ rather than an expanded
# path because that is what the operator would have written and what ssh itself
# expands; an absolute path here would differ from the documented line and make
# the "already present" check miss a hand-written one.
harbor_client_include_line() {
  printf 'Include ~/.ssh/harbor.conf'
}

harbor_client_include_present() {
  [ -f "${1}" ] || return 1
  grep -q "^$(harbor_client_include_line)\$" "${1}"
}

# harbor_client_include_add STATE_ROOT CONFIG: the include, once, prepended.
#
# Prepended rather than appended because ssh applies an Include where it stands,
# so one added after an existing "Host *" block would be read too late to affect
# anything above it -- a configuration that looks right in the file and does
# nothing in practice.
#
# Ownership is the honest word, and the whole of --remove turns on it: modified
# when the operator already had a config, created when Harbor made the file.
harbor_client_include_add() {
  local root="${1}" config="${2}" ownership pre tmp
  if harbor_client_include_present "${config}"; then
    # Already there, by Harbor's hand on an earlier run or by the operator's.
    # Either way there is nothing to do and nothing to own, and a journal entry
    # for a mutation that did not happen is a claim recovery would act on.
    return 0
  fi
  if [ -f "${config}" ]; then ownership=modified; else ownership=created; fi
  pre="$(harbor_journal_observe file "${config}")"
  harbor_journal_create "${root}" file "${config}" "${ownership}" prepared "${pre}" '' \
    || exit "$?"
  harbor_step "client-include-prepared"
  tmp="${config}.tmp.$$"
  harbor_client_include_line >"${tmp}"
  printf '\n' >>"${tmp}"
  [ -f "${config}" ] && cat "${config}" >>"${tmp}"
  chmod 0600 "${tmp}"
  mv -f "${tmp}" "${config}"
  harbor_journal_set_phase "${HARBOR_JOURNAL_ENTRY}" applied \
    "$(harbor_journal_observe file "${config}")" \
    || harbor_die 2 client.include_record "the include was added to ${config} but its journal entry could not be marked applied; inspect the journal before rerunning"
}
```

> **Note for the implementer:** `harbor_journal_create`'s exact signature and
> whether `harbor_journal_set_phase` takes an observed state are established by
> `fleet/lib/journal.sh` — read it and match the call sites in
> `fleet/lib/pair.sh:109` and `fleet/lib/t3.sh:332` rather than the sketch above.
> If `set_phase` does not take a post-state, write the post-state through
> whatever helper those two call sites use. Do not change `journal.sh`.

- [ ] **Step 4: Run the test to verify it passes**

Run: `fleet/tests/run_unit.sh fleet/tests/unit/lib/client_include.bats`
Expected: PASS, 6 tests.

- [ ] **Step 5: Mutation-check the prepend**

Change `cat "${config}" >>"${tmp}"` / prepend order so the include is appended instead. Re-run.
Expected: the "precedes every Host block" test goes red. Restore.

- [ ] **Step 6: Mutation-check the ownership word**

Hard-code `ownership=created`. Re-run.
Expected: the "existing config is modified" test goes red. Restore.

- [ ] **Step 7: Commit**

```bash
git add fleet/lib/client.sh fleet/tests/unit/lib/client_include.bats
git commit -m "The ssh include, prepended once and journaled with the ownership --remove turns on"
```

---

### Task 5: `client setup` and `client setup --remove`

**Files:**

- Create: `fleet/client/setup.sh`
- Test: `fleet/tests/unit/client/setup.bats`

**Interfaces:**

- Consumes: everything from Tasks 2, 3 and 4.
- Produces: `harbor_client_setup ARGS...`, called by Task 8's dispatcher arm.

The order is: preflight, then the version report, then `harbor.conf`, then the include. The version report is a **warning** and never a refusal — section 5.5 says so, because T3 detects skew itself and a Mac that is one patch ahead is not a broken Mac.

`--remove` reverts only the include, and only when Harbor's own entry says it created or modified it. It never removes `harbor.conf`, because section 5.5 says `--remove` "reverts the ssh include" and nothing else, and because the file is the thing a hand-written `Include` may still point at.

An `observed` entry, or an entry whose file no longer matches the recorded post-state, is attended: reported, left alone, exit 1. This is the same three-way rule `fleet/lib/access.sh` uses, for the same reason — "not what I left" is not "the state before me", and a reversion recorded against a reading that cannot tell is an entry `harbor_journal_recover` skips forever.

- [ ] **Step 1: Write the failing test**

```bash
# fleet/tests/unit/client/setup.bats
# Covers: the order of the three steps, the version report as a warning, the
# rerun, and every arm of --remove.
setup() {
  load '../test_helper'
  harbor_load_lib log.sh
  harbor_load_lib journal.sh
  harbor_load_lib client.sh
  HOME="${BATS_TEST_TMPDIR}/home"
  mkdir -p "${HOME}/.ssh"
  export HOME
  # ... shim HARBOR_CLIENT_TAILSCALE as in Task 2, and HARBOR_CLIENT_T3_APP for
  # the desktop version report.
}

@test "setup writes harbor.conf, adds the include, and reports both" { : ; }
@test "a desktop version differing from t3_version is a warning and exit 0, never a refusal" { : ; }
@test "a desktop that is not installed is reported and is still exit 0" { : ; }
@test "a second setup rewrites nothing and journals nothing" { : ; }
@test "the preflight runs before anything is written: MagicDNS off leaves no harbor.conf" { : ; }
@test "--remove takes the include out and marks the entry reverted" { : ; }
@test "--remove leaves harbor.conf alone, because section 5.5 reverts the include only" { : ; }
@test "--remove on a config Harbor only observed reports it, changes nothing, and exits 1" { : ; }
@test "--remove on a config that no longer matches the recorded post_state is attended, not a reversion" { : ; }
@test "--remove with no entry at all exits 0 and says there was nothing to undo" { : ; }
@test "--remove works with Tailscale uninstalled, because the include is this Mac's own file" { : ; }
@test "--remove works with MagicDNS off, for the same reason" { : ; }
@test "a setup interrupted after the mv leaves a prepared entry the next setup recovers to applied" { : ; }
@test "recovery runs before the already-present early return, not after it" { : ; }
```

> **Note for the implementer:** the bodies above are named, not written, because
> each one is a direct analogue of a test that already exists and is already
> right. Write each body by reading its counterpart first:
> `fleet/tests/unit/lib/access.bats` for the four `--remove` arms (it has the
> `observed`, the changed-artifact, and the neither-state cases, and the shims
> that make them non-vacuous), and `fleet/tests/unit/lib/config.bats` for the
> rerun-is-a-no-op shape. Do not invent a new idiom for these.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `fleet/tests/run_unit.sh fleet/tests/unit/client/setup.bats`
Expected: FAIL for every test.

- [ ] **Step 3: Write `fleet/client/setup.sh`**

```bash
# fleet/client/setup.sh
# The Mac half of design section 5.5, run from a clone: confirm the Tailscale
# client, report the desktop's version against the pinned one, write the
# harbor-node ssh block, and add the include once.
#
# Sourced by bin/harbor, not executed, for the same reason node/provision.sh is:
# an installed release carries every ordinary file 0644 and only bin/harbor is
# executable (design section 5.2). Nothing installs this on the Mac today, and
# keeping the convention costs nothing and stops the odd one out from appearing
# later.

harbor_client_setup() {
  local remove=no arg
  for arg in ${1+"$@"}; do
    case "${arg}" in
      --remove) remove=yes ;;
      *) harbor_die 3 client.usage "usage: harbor client setup [--remove]" ;;
    esac
  done
  ...
}
```

The implementer writes the body against the tests. The rules it must satisfy, each of which one test above names:

1. **The client lock, then `harbor_journal_recover`, before anything else — on both paths, `--remove` included.** Every operator command on the node does this, and the client has its own state root and its own journal for the same reason. Without it a `setup` interrupted between the `mv` and the `applied` write leaves a `prepared` entry that nothing ever resolves: the next `setup` finds the include already present and returns before touching the journal at all, and `--remove` then meets an entry it cannot act on. Recovery is the only thing that decides such an entry, and it has to run before the early return, not after it.
2. `harbor_client_preflight` — **on the `setup` path only.** Reverting a line from a file in this Mac's own home does not depend on Tailscale being installed, logged in, running, or having MagicDNS on, and gating it on all four means an operator who uninstalls Tailscale can never remove the include Harbor put there. `--remove` reads the journal and the file and nothing else.
3. The version report next: print the desktop's version beside `t3_version` from `versions.lock`. Differing is a warning. Missing is a warning. Neither changes the exit code.
4. `harbor_client_conf_write "${HOME}/.ssh/harbor.conf"`.
5. `harbor_client_include_add "${root}" "${HOME}/.ssh/config"`.
6. `--remove` runs step 1 and then the include reversion, in the three-way form described above.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `fleet/tests/run_unit.sh fleet/tests/unit/client/setup.bats`
Expected: PASS, 10 tests.

- [ ] **Step 5: Mutation-check the `--remove` guards**

One at a time: (a) let an `observed` entry be reverted, (b) drop the post-state comparison, (c) let `--remove` delete `harbor.conf`. Re-run after each.
Expected: at least one test red for each. Restore after each.

- [ ] **Step 6: Commit**

```bash
git add fleet/client/setup.sh fleet/tests/unit/client/setup.bats
git commit -m "harbor client setup, and a --remove that reverts the include and nothing else"
```

---

### Task 6: the remote status call and its five exit codes

**Files:**

- Create: `fleet/client/verify.sh`
- Create: `fleet/tests/fixtures/client/status-*.json`
- Test: `fleet/tests/unit/client/verify_codes.bats`

**Interfaces:**

- Consumes: Task 1's reader.
- Produces: `harbor_client_status FLATFILE` — runs `ssh harbor-node harbor status --json`, classifies the reply, and either succeeds with the flattened document in `FLATFILE` or dies with the right code and the right word.

This is the whole of the "Client verify accepts all codes" row of the test map, and it is the part of PR 6 that must be right without PR 7 existing. Every case below is a fixture.

| Remote exit | Body | Verdict |
|---|---|---|
| 0, 1, 2 | a check list | pass the document on |
| 3 | `{"error":"unknown_subcommand","subcommand":"status"}` | **precondition, exit 3**, naming the node's release as predating `harbor status` |
| 3 | any other single-`error` object | ordinary precondition, exit 3 |
| 4 | the `interrupted` error object | the remote command was interrupted, exit 4 |
| 4 | empty | transport failure, exit 2 |
| 255 | empty | `ssh` transport failure, exit 2 |
| any | not JSON | parse failure, exit 2 |
| 5 and up, or any other code | valid JSON | **undocumented**, exit 2 |

The distinction that matters most is the fourth row against the fifth: a node whose Harbor predates `harbor status` is a node that needs upgrading, and telling its operator "the connection failed" would send them to the network. Section 5.5 pins the reply's shape for exactly this reason, and `fleet/bin/harbor:139` already emits it.

- [ ] **Step 1: Write the fixtures**

Create one file per row of the table under `fleet/tests/fixtures/client/`. The exit-3 unknown-subcommand fixture must be **byte-identical** to what `fleet/bin/harbor` prints — generate it by running the shipped dispatcher with an unknown subcommand rather than typing it, and add a test that asserts the fixture still matches what the dispatcher emits. A fixture that drifts from the code it models is a test that passes while the thing it tests is broken.

- [ ] **Step 2: Write the failing test**

One test per row of the table, each asserting both the exit code and a distinguishing word in the message; plus the fixture-matches-the-dispatcher test.

- [ ] **Step 3: Run the tests to verify they fail**

Run: `fleet/tests/run_unit.sh fleet/tests/unit/client/verify_codes.bats`
Expected: FAIL for every test.

- [ ] **Step 4: Write the implementation**

`ssh` is run through `HARBOR_CLIENT_SSH` (default `ssh`), which the lane shims. Capture stdout to a file and the status to a variable; never let a nonzero `ssh` abort the script under `set -e`.

```bash
harbor_client_status() {
  local flat="${1}" body rc=0
  body="$(mktemp -t harbor-client)"
  "${HARBOR_CLIENT_SSH:-ssh}" harbor-node harbor status --json >"${body}" 2>/dev/null || rc="$?"
  ...
}
```

Classification order matters and must be: parse the body first, then branch on `rc`. A body that will not parse is a transport or parse failure whatever `rc` says, and deciding on `rc` first would let a 255 with a stray JSON fragment through.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `fleet/tests/run_unit.sh fleet/tests/unit/client/verify_codes.bats`
Expected: PASS, one per row plus the fixture check.

- [ ] **Step 6: Mutation-check the pre-PR-7 arm**

Delete the `unknown_subcommand` branch so it falls through to the ordinary exit-3 arm. Re-run.
Expected: that row's test goes red on its message, not only its code. If it stays green, the test is asserting the code alone — fix the test.

- [ ] **Step 7: Commit**

```bash
git add fleet/client/verify.sh fleet/tests/fixtures/client fleet/tests/unit/client/verify_codes.bats
git commit -m "Every documented status exit code, and the pre-PR-7 node told apart from a broken link"
```

---

### Task 7: `client verify` end to end, per mode

**Files:**

- Modify: `fleet/client/verify.sh`
- Test: `fleet/tests/unit/client/verify_modes.bats`

**Interfaces:**

- Consumes: Task 2's preflight, Task 6's `harbor_client_status`.
- Produces: `harbor_client_verify ARGS...`.

Order: preflight, `tailscale ping harbor-node`, remote status, then the one per-mode row from the contract table at the top of this plan.

Rules every test names:

- A `ping` that fails is exit 2 and the remote status is never attempted — there is nothing to ask.
- The mode comes from the node's own `access.mode`, never from the Mac. The Mac has no business holding an opinion about which mode the node is in, and a Mac that held a stale one would verify the wrong thing and pass.
- **An absent `access.mode`, or one that is not `connect`, `tailnet` or `ssh`, is a failure — never a pass.** This is the same hole as a missing required row, one level up and worse: with no recognized mode no per-mode row is selected at all, so a `case` with three arms and no default would accept a parseable document having verified nothing about the node's actual reach. Write the default arm first and give it its own test for both spellings, absent and unknown.
- A **missing** required row is a failure, not a pass. This is the one place a permissive reader would turn a node that cannot answer into a node that is fine.
- `tailnet` additionally requires a completed TLS connection to `https://harbor-node.TAILNET.ts.net/`. Use the Mac's own `curl`, with no credential, following no redirect, and never printing the response body — the same rule the node's descriptor fetch follows. The MagicDNS name comes from `harbor_client_magicdns`, so the literal `TAILNET.ts.net` never appears outside documentation, which is also what `placeholder_scan.sh` requires.
- An environment ID is never logged, journaled, persisted or bundled (section 5.5). `verify` compares nothing of the sort — it reads the node's own `t3.environment` verdict — and must not start.

- [ ] **Step 1: Write the failing test**

Tests, one per rule, plus one per mode for the pass case and one per mode for the fail case. Reuse the fixture idiom from Task 6.

- [ ] **Step 2 through 5:** fail, implement, pass, mutation-check the missing-row rule specifically (make a missing row a pass; the three "missing row" tests must go red).

- [ ] **Step 6: Commit**

```bash
git add fleet/client/verify.sh fleet/tests/unit/client/verify_modes.bats
git commit -m "harbor client verify: the node names its own mode, and a missing row is never a pass"
```

---

### Task 8: the `client` arm of the dispatcher

**Files:**

- Modify: `fleet/bin/harbor`
- Test: `fleet/tests/unit/bin/harbor.bats`

`client` is the one subcommand that does **not** run `harbor_entrypoint_check`. Every other subcommand runs on a bootstrapped node from an installed release; `client` runs on a Mac, from a clone, against a node it has not touched — there is no `/usr/local/bin/harbor`, no `bootstrap.json` and no release to check, and a check that cannot apply must not be written as one that always passes.

`fleet/lib/client.sh` is sourced with the others; `fleet/client/setup.sh` and `fleet/client/verify.sh` are sourced inside their arms, the way `node/bootstrap.sh` and `node/provision.sh` are.

- [ ] **Step 1: Write the failing test** — `harbor client` with no verb exits 3 with usage; an unknown verb exits 3; `harbor client setup` and `harbor client verify` reach their functions; `harbor help` lists `client`.
- [ ] **Step 2: Run it, see it fail.**
- [ ] **Step 3: Add the arm and the usage lines.**
- [ ] **Step 4: Run it, see it pass.**
- [ ] **Step 5: Commit.**

---

### Task 9: the macOS test lane

**Files:**

- Modify: `.github/workflows/test.yml`
- Modify: `.github/workflows/lint.yml`
- Create: `fleet/tests/shims/client/tailscale`, `fleet/tests/shims/client/ssh`

**Read this before touching `test.yml`.** The lane is the opposite shape to the obvious guess, and it was measured, not assumed:

```yaml
      - name: Unit tests (Ubuntu, every directory)
        if: runner.os == 'Linux'
        run: tests/run_unit.sh                       # -r tests/unit, everything
      - name: Unit tests (macOS, lib and bin under the system bash 3.2)
        if: runner.os == 'macOS'
        env:
          HARBOR_EXPECT_BASH32: "1"
        run: tests/run_unit.sh tests/unit/lib tests/unit/bin
```

So a new `fleet/tests/unit/client/` directory would run on **Ubuntu**, where `/usr/bin/osascript` does not exist, and would **not** run on macOS, which is the only platform it is about. Both halves need fixing, and in opposite directions:

- The macOS step gets `tests/unit/client` added to its argument list. `HARBOR_EXPECT_BASH32=1` then also enforces the bash 3.2 subset on `lib/client.sh` and `client/*.sh`, which is exactly the enforcement this code wants.
- The client tests skip on anything that is not Darwin, from inside `setup()`, rather than by removing the directory from Ubuntu's run. Ubuntu's step is deliberately spelled "every directory" — narrowing it to a list would mean the next directory anyone adds is silently untested there. A skip keeps that property and still parses and loads every file.

The skip goes in each client `.bats` file's `setup()`, as the first thing it does:

```bash
setup() {
  [ "$(uname -s)" = Darwin ] || skip 'the client runs on macOS only'
  load '../test_helper'
  ...
}
```

`run_unit.sh` discovers tests with `-r tests/unit`, so no discovery change is needed beyond the argument list above.

`lint.yml` needs `fleet/client/*.sh` added to **both** the ShellCheck and the shfmt lists, and the two shims added by name (they have no extension, like `fleet/tests/integration/stub/tailscale`). Verify by reading the lists rather than assuming a glob covers them — `fleet/lib/*.sh` already covers `lib/client.sh`, but nothing covers `fleet/client/`.

- [ ] **Step 1: Add the two shims**, dispatching on the argument vector with the count checked first, for the reason `fleet/tests/integration/stub/tailscale` gives: matching on `"${*}"` makes `("serve" "status")` and `("serve status")` the same string.
- [ ] **Step 2: Add `fleet/client/*.sh` and the two shims to both lint lists.**
- [ ] **Step 3: Add `tests/unit/client` to the macOS step, and the Darwin skip to each client `.bats` file.**
- [ ] **Step 4: Prove both directions.** Run `fleet/tests/run_unit.sh fleet/tests/unit/client` on this Mac and see the tests run; then run one of them with `uname` shimmed to report Linux, or assert the skip some other way, and see them skip rather than fail. A skip that would have been a failure on the Ubuntu runner is the whole point of this step.
- [ ] **Step 5: Run the whole CI-exact static gate and the full unit lane on this Mac.**
- [ ] **Step 6: Commit.**

---

### Task 10: docs and final verification

**Files:**

- Modify: `README.md`
- Modify: `docs/architecture.md` if it carries a subcommand list

- [ ] **Step 1: Add the two commands to the README's honest status section**, including the sentence that matters: until PR 7 ships `harbor status`, `client verify` against a real node reports the node's release as predating it, exit 3, and this is the designed answer rather than a gap.
- [ ] **Step 2: Run markdownlint with the exact CI command line.**
- [ ] **Step 3: Run the full unit lane and the complete static gate.** Record the test count.
- [ ] **Step 4: Walk the merge gate for section 8's PR 6 row** and write each answer into the PR body: both macOS jobs green; no job requires a real node or PR 7; fixtures exist for exit 0 through 4 including the exit-4 `interrupted` object, the no-body transport cases, the non-JSON body, the undocumented code, and the pre-PR-7 unknown-subcommand reply; no `jq` invocation anywhere in `fleet/client/` or `fleet/lib/client.sh`; the literal `TAILNET.ts.net` appears only in documentation.
- [ ] **Step 5: Commit and open the PR.**

---

## Self-review notes

- **Spec coverage.** Section 5.5's Mac paragraph: the Tailscale login check (Task 2), the MagicDNS exit 3 (Task 2), the version report as a warning (Task 5), `harbor.conf` with its three directives (Task 3), the `ssh-include` journal entry (Task 4), `--remove` (Task 5), `tailscale ping` (Task 7), all five exit codes (Task 6), the pre-PR-7 reply (Task 6), `osascript`-only JSON (Task 1), and the three per-mode requirements (Task 7). Section 5.5's line about `harbor client setup --remove` reverting the ssh include is Task 5. The section 8 row's gate is Task 10.
- **Deliberate gap.** The manual per-mode acceptance steps in section 5.5 ("the environment is listed and connects under Settings → Connections", and the two others) are attended checks on a real Mac with a real node. They are not automatable and PR 6's gate does not depend on them; they belong in the PR body as a procedure, the way PR 5 recorded Revalidation A.
- **Known risk.** Task 6 and Task 7 encode a contract PR 7 has not yet met. The contract table at the top of this plan is the mitigation: PR 7's plan must open by reading it, and any identifier PR 7 changes must be changed in `fleet/client/verify.sh` in the same PR.
