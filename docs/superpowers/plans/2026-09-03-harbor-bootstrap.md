# Harbor Ubuntu Bootstrap (PR 3) Implementation Plan

> **For agentic workers:** implement this plan task by task. Implementation workers never commit, push, or open a pull request: every task ends in the handoff described under "Working conventions", and the orchestrator commits after its own gate. Where a skill's own flow says to commit, this plan wins.

**Goal:** Ship PR 3 of Harbor, design section 8 row 3: the Ubuntu bootstrap. Root installs Harbor itself from a verified tag, creates the operator, installs Node.js, copies the authorized key, scopes sshd, sets the firewall and power policy, installs or adopts Tailscale, enables linger, and writes `bootstrap.json`, with every mutation journaled and every rerun converging.

**Architecture:** `bin/harbor bootstrap` dispatches to `node/bootstrap.sh`, which is bash 5 and root-only; the checks and mutations it needs live in bash 3.2 libraries under `fleet/lib/` so the unit lane can drive them on macOS. Each bootstrap step is one journaled transaction using the PR 2 protocol: inspect, write a `prepared` entry, mutate, mark `applied`. The unit lane exercises every library function against disposable fixture roots with fake vendor shims; the integration lane runs the real commands at real paths on an ephemeral Ubuntu VM.

**Tech Stack:** bash 3.2 for `fleet/lib/`, bash 5 for `fleet/node/`, Bats, the PR 2 shim skeleton, GitHub Actions (`lint.yml`, `test.yml`, and the new `integration.yml`).

> **Layout:** unchanged from PR 2. Harbor's code lives under `fleet/`; documents, `.github/workflows/`, `.gitleaks.toml`, and `.markdownlint.yml` stay at the repository root. Every code path below is relative to `fleet/` unless it starts with `docs/` or `.github/`.

## Slices

PR 3's scope is far past the 600-line guideline, so it ships as four stacked pull requests, each independently green and independently reviewable. Each slice's branch is based on the previous one.

| Slice | Branch | Contents | Tasks |
| --- | --- | --- | --- |
| 3a | `feat/bootstrap-pins` | Pinned third-party versions, `lib/apt.sh`, `lib/node.sh`, the engines-range check and its CI proof | 1 to 5 |
| 3b | `feat/bootstrap-release` | Checkout trust rules, hardened Git invocation, release staging from `git archive`, mode normalization, the entrypoint symlink, the installed-entrypoint preflight, the flag binding | 6 to 11 |
| 3c | `feat/bootstrap-node` | `node/bootstrap.sh` and the root steps: preflight, operator user, Node.js, authorized key, sshd drop-in, firewall, power, linger, `bootstrap.json` | 12 to 19 |
| 3d | `feat/bootstrap-tailscale` | `lib/tailscale.sh`, the operator grant, `harbor auth tailscale`, the `--ssh` feature gate, `integration.yml` | 20 to 25 |

## Global constraints

Everything in the PR 2 plan's "Global Constraints" still binds: the bash 3.2 subset for `lib/`, `set -euo pipefail` with the ERR trap in every executable, the exit-code table (0 success, 1 degraded or attended, 2 broken or apply failed, 3 precondition or usage, 4 interrupted), the journal write protocol, the lock roots and modes, the `HARBOR_TEST_HOOKS` gate, the placeholder list, and the static lane. In addition, for PR 3:

- Shell floor (spec section 2): `node/` may use bash 5. Nothing under `lib/` may, because the macOS unit jobs source those files under bash 3.2.
- Root code paths (spec section 3.1): every root step lives in `node/bootstrap.sh`; no other script calls `sudo`. Libraries contain the checks and the journaled mutations, never a privilege transition.
- Idempotency (spec section 6.1): every step is defined by its inspection first. A second run makes zero mutating shim calls and writes no new `created` or `modified` entry.
- Trust rules (spec section 5.1): root runs code from a checkout only under the ownership rules, and installs only `git archive` of a verified clean exact tag, never the work tree. Every Git invocation is the hardened form. `HARBOR_DEV=1` is ignored by any command run as root.
- Unit lane (spec section 7): unit tests never stage into the real `/usr/local`, never touch `/var/lib`, and never invoke a root-mutating public command. Every vendor and system binary is a shim.
- Secret handling (spec section 3.8): no secret ever reaches a command line; the authorized key is copied by path and recorded by hash, never printed.
- Sudo environment (PR 2 ledger, carried forward): the integration lane passes hooks and shim variables only through the explicit `sudo env` argument list. `sudo env` must use a fixed allowlist and must never forward `HARBOR_TEST_HOOKS`, `HARBOR_FAIL_AFTER`, `HARBOR_PAUSE_AFTER`, `HARBOR_PID`, or `TMPDIR` from an ambient environment, and no sudoers rule may `env_keep` them.

## Working conventions for every task

- Work in the worktree `/Users/krishgarg/Documents/products/harbor/.worktrees/bootstrap`, on the branch named by the slice. Run code commands from `fleet/`; run git and markdownlint from the worktree root.
- Test first: write the failing tests, run them, record the failure, then write the code until they pass. Run `tests/run_unit.sh` for the whole lane and `tests/run_unit.sh <file>` while iterating.
- Every library function is prefixed `harbor_`, every global `HARBOR_`. Libraries define functions only.
- Two-space indent, braced variables, `case` arms one level in, no space after a redirection operator.
- Each task ends in a handoff: the test commands with their verbatim results, the deviations, `git status --short`, `git diff --stat`, and the concerns worth flagging. The orchestrator gates and commits.
- A handoff with a failing test, a lint finding, or a file outside the task's list is not ready. Say so instead of working around it.

## File map (new files in PR 3)

| File | Responsibility |
| --- | --- |
| `lib/apt.sh` | Package presence inspection, journaled `apt-get install`, vendor keyring and apt source for Tailscale |
| `lib/node.sh` | Node.js presence and version inspection, download with checksum, install to `/opt/harbor/node`, the four `/usr/local/bin` symlinks, the report-only operator probe |
| `lib/checkout.sh` | Canonical checkout root derivation, the ownership and mode rules, the hardened Git invocation, the clean exact tag check |
| `lib/release.sh` | Staging `git archive` of a verified tag, mode normalization, the `RELEASE` marker, the tree hash, the entrypoint symlink, the orphan rule |
| `lib/entrypoint.sh` | The installed-entrypoint preflight and its record-less and mismatch forms, the `HARBOR_DEV` rules, the flag binding |
| `lib/user.sh` | Operator account inspection and creation, the sudo-capable-operator refusal, linger |
| `lib/ssh.sh` | Authorized-key copy, the operator sshd drop-in, `sshd -t` and `sshd -T` assertions |
| `lib/firewall.sh` | Pre-state-aware `ufw` inspection and rules |
| `lib/power.sh` | The logind drop-in and the four sleep targets |
| `lib/tailscale.sh` | Install, adoption, the operator grant, the status probe, `harbor auth tailscale` |
| `node/bootstrap.sh` | The root bootstrap sequence: preflight, the steps in table order, `bootstrap.json` |
| `.github/workflows/integration.yml` | The integration lane on an ephemeral `ubuntu-24.04` VM |

---

## Slice 3a: pinned versions and the runtime installers

### Task 1: Pin the third-party versions

**Files:** `versions.lock`; `docs/superpowers/pins/2026-09-03-pin-provenance.md` (new, records where each value came from).

**Contract.** Set the eight values PR 3 owns (spec section 2, version pinning): `ubuntu_release`, `tailscale_apt_channel`, `tailscale_version`, `nodejs_version`, `nodejs_install`, `nodejs_sha256`, `t3_version`, `t3_engines_node`. The other five keys stay empty; PR 4 sets them. Every value is exact, never `latest`. `nodejs_sha256` is the checksum of the exact tarball `nodejs_install` names, read from the release's `SHASUMS256.txt`. `t3_engines_node` is the `engines.node` range copied verbatim from the pinned `t3` package's own metadata, and `nodejs_version` must satisfy it. `tailscale_version` must exist in the stable apt channel for `ubuntu_release`.

**Provenance file.** For each value: the command that produced it, the date, and the exact output line. This is how the version-bump PR of spec section 2 is later reviewed.

**Tests.** Extend `tests/unit/lib/versions.bats`: the lock still loads; the eight keys are non-empty and the five PR 4 keys are empty; `nodejs_version` is a bare exact version; `nodejs_sha256` is 64 hex characters; `t3_engines_node` parses as a semver range.

**Acceptance.** `tests/run_unit.sh` green; every value traceable to a recorded command.

**Commit:** `chore(versions): pin Ubuntu, Node.js, Tailscale, and the T3 pair`

### Task 2: `lib/versions.sh` engines-range satisfaction

**Files:** `lib/versions.sh` (append), `tests/unit/lib/versions.bats` (append).

**Contract.** `harbor_semver_satisfies <version> <range>` decides whether an exact version satisfies a semver range, in the bash 3.2 subset, covering the range forms the pinned T3 releases actually use (`>=x.y.z`, `^x.y.z`, `>=x.y.z <a.b.c`, and the `||` alternation of those). An unrecognized range form is a fail-closed error, exit 3, never a guess. `harbor_versions_require_node_range` compares the locked `nodejs_version` to the locked `t3_engines_node` and dies 3 naming both when it does not satisfy.

**Tests.** A table of satisfying and non-satisfying pairs for each supported form; the unrecognized form exits 3; the locked pair from Task 1 satisfies.

**Commit:** `feat(versions): semver range satisfaction and the Node.js engines gate`

### Task 3: `lib/apt.sh`

**Files:** `lib/apt.sh` (new), `tests/unit/lib/apt.bats` (new), `tests/fixtures/shims/dpkg-query/*`, `tests/shims/bin/{apt-get,dpkg-query,apt-key}` symlinks to the PR 2 shim.

**Contract.** `harbor_apt_installed <pkg>` inspects with `dpkg-query` and never mutates. `harbor_apt_install <root> <pkg>...` installs only the packages that inspection reports missing, in one `apt-get install -y` invocation with `DEBIAN_FRONTEND=noninteractive`, journaling one `package` entry per package with `pre_state` `absent` and `post_state` the installed version; an already-installed package is journaled `observed` and never reinstalled. A failed install leaves the entry `prepared` for recovery. `harbor_apt_add_vendor_source` writes a keyring and a source list file for a named vendor, journaled as two `file` entries.

**Tests.** All six bootstrap packages missing, all present, and a mix; second run makes zero mutating shim calls; a failing `apt-get` leaves `prepared` and exits 2; the vendor source writes both files with mode `0644` and root ownership.

**Commit:** `feat(apt): package inspection, journaled installs, vendor source`

### Task 4: `lib/node.sh`

**Files:** `lib/node.sh` (new), `tests/unit/lib/node.bats` (new), fixtures for the download and checksum paths.

**Contract.** `harbor_node_installed_version` runs the root-owned `/opt/harbor/node/bin/node --version` and reads nothing from operator state. `harbor_node_install <root>` is a no-op when the installed version equals the lock; otherwise it downloads the tarball `nodejs_install` names to a root-owned temporary directory, verifies `nodejs_sha256` and refuses on mismatch without unpacking, extracts to `/opt/harbor/node`, and journals a `runtime-install` entry whose `pre_state` is the previously installed version or `absent`. It then creates the `node`, `npm`, `npx`, and `corepack` symlinks in `/usr/local/bin`, one journaled `file` entry each, `modified` when a symlink already points elsewhere. `harbor_node_operator_probe <operator>` runs `sh -lc 'node --version'` as the operator and only reports: a failure or a different version is a precondition line, never a reinstall.

**Tests.** Version match is a no-op with zero mutating calls; mismatch installs and journals; a bad checksum exits 2, unpacks nothing, and leaves the entry `prepared`; each symlink case (absent, correct, pointing elsewhere) journals the right ownership; the operator probe never mutates and reports its three outcomes.

**Commit:** `feat(node): checksum-verified runtime install and journaled symlinks`

### Task 5: The engines proof in CI

**Files:** `.github/workflows/lint.yml` (append a step), `fleet/tests/lint/engines_check.sh` (new), `tests/unit/lib/engines_check.bats` (new).

**Contract.** A static-lane step proves the locked `nodejs_version` satisfies the locked `t3_engines_node`, using `harbor_semver_satisfies` so one implementation is under test. Exit 0 or a message naming both values.

**Commit:** `ci: prove the pinned Node.js satisfies the pinned T3 engines range`

**Slice 3a ends here.** Open the stacked PR against `feat/foundation-2`, let Greptile review, watch the first CI wave.

---

## Slice 3b: trusted checkout, release staging, installed entrypoint

### Task 6: `lib/checkout.sh` path and ownership rules

**Files:** `lib/checkout.sh` (new), `tests/unit/lib/checkout.bats` (new).

**Contract (spec section 5.1).** `harbor_checkout_root_from_argv0` resolves `$0` with symlinks followed, requires the parent directory to be named `bin`, and returns the canonical absolute grandparent. `harbor_checkout_trusted <path> [operator]` applies the ownership rules to every component from `/` to the checkout root and to every directory and file inside it: owned by root or by the invoking `SUDO_USER`, never group- or world-writable, symlinks followed and their targets held to the same rule; once an operator identity exists, anything owned by the operator user or group, or writable by either, is rejected outright. Any failure exits 3 naming the offending path and mutates nothing.

**Tests.** A fixture tree that passes; a group-writable directory, a world-writable file, a foreign-owned component, an operator-owned file, and a symlink whose target breaks the rule each exit 3 naming that path; the canonical root is identical for the relative, parent-relative, and absolute spellings.

**Commit:** `feat(checkout): canonical root derivation and the trust rules`

### Task 7: Hardened Git invocation and the clean exact tag check

**Files:** `lib/checkout.sh` (append), `tests/unit/lib/checkout.bats` (append), a `git` shim.

**Contract.** `harbor_git <checkout> <args...>` runs exactly the hardened form of spec section 5.1 and writes nothing to any Git configuration. `harbor_checkout_tag <checkout>` requires a clean work tree and an exact tag on `HEAD`, returning the tag; dirty, untracked, detached without a tag, or between tags each exit 3. `HARBOR_DEV=1` never relaxes either function when the caller is root.

**Tests.** The shim log records the exact hardened argument vector; clean-at-a-tag returns the tag; dirty, untracked-file, and no-tag cases exit 3; a real temporary Git repository covers the tag and dirty cases end to end.

**Commit:** `feat(checkout): hardened git invocation and clean exact tag check`

### Task 8: `lib/release.sh` staging and mode normalization

**Files:** `lib/release.sh` (new), `tests/unit/lib/release.bats` (new).

**Contract (spec section 5.2).** `harbor_release_stage <checkout> <tag> <dest>` extracts `git archive` of the verified tag into a root-owned temporary directory, normalizes every mode to the installed contract (directories `0755`, ordinary files `0644`, the release's `bin/harbor` alone `0755`), writes a `RELEASE` file naming tag and commit, and moves it into place. `harbor_release_tree_hash <dir>` is a stable content hash over the staged tree. Staging journals `harbor-install` `created` with the tree hash as `post_state`. A directory already at `<tag>/` whose hash equals its `applied` entry is kept, not restaged; one with no such entry or a differing hash exits 3 naming it an orphan, and Harbor removes nothing.

**Tests.** Modes after staging match the contract whatever the archive carried; the work tree's uncommitted content never appears in the staged tree; the tree hash is stable across two stagings of the same tag and differs after a change; the keep, orphan-without-entry, and orphan-with-differing-hash cases each behave as specified.

**Commit:** `feat(release): verified-tag staging with normalized installed modes`

### Task 9: The entrypoint symlink

**Files:** `lib/release.sh` (append), `tests/unit/lib/release.bats` (append).

**Contract.** `harbor_release_link <release> <link>` writes a temporary symlink and renames it into place, journaling `file` `created` with `pre_state` `absent`, or `modified` with the prior target when a symlink into `/usr/local/lib/harbor/` is already there. A foreign regular file at the link path exits 3 naming it for manual inspection; Harbor never removes it.

**Tests.** Absent, already-correct, pointing-at-another-release, and foreign-regular-file cases; the rename is atomic in the sense that the link never resolves to a partial target during the operation.

**Commit:** `feat(release): atomic entrypoint symlink with journaled ownership`

### Task 10: `lib/entrypoint.sh` preflight

**Files:** `lib/entrypoint.sh` (new), `tests/unit/lib/entrypoint.bats` (new).

**Contract (spec section 5.2, "Installed entrypoint").** `harbor_entrypoint_check <argv0> <record>` validates the executing path: `bin/harbor` inside a root-owned `/usr/local/lib/harbor/<tag>/` whose `RELEASE` names that directory's own tag, every directory in it `0755` root-owned, every ordinary file `0644` root-owned, only `bin/harbor` also executable, and the tag in `bootstrap.json` equal to it. Otherwise exit 3. Two deferral forms skip only the record equality check: the record-less form when `bootstrap.json` is absent, the mismatch form when it names another tag. Both apply every path, ownership, and mode rule in full. Root `journal resolve` shares the deferral and requires no `harbor-install` proof. Every other command exits 3 naming `sudo harbor bootstrap` when the record is absent while `/var/lib/harbor` exists. `HARBOR_DEV=1` relaxes this check for non-root operator commands only and is ignored entirely when the caller is root.

**Tests.** A fixture release tree that passes; each mode and ownership violation (group-writable directory, world-writable file, a non-root owner, a `lib/*.sh` marked executable, a missing or mismatched `RELEASE`) exits 3; the record-less and mismatch forms accept exactly what they should and still enforce every other rule; the mismatch message names both causes and both resumes; `HARBOR_DEV=1` relaxes the operator case and does not relax the root case.

**Commit:** `feat(entrypoint): installed-release preflight with the two deferral forms`

### Task 11: The `bootstrap-flags` intent entry and the flag binding

**Files:** `lib/entrypoint.sh` (append), `tests/unit/lib/entrypoint.bats` (append).

**Contract (spec section 5.2, "Flag binding").** `harbor_bootstrap_flags_normalize` renders the security-relevant intent of a run: the operator name, the resolved authorized-key source path, and whether each of `--tailscale-ssh`, `--allow-lan-ssh`, `--harden-sshd`, `--adopt-firewall`, and `--adopt-tailscale` was given. The first run writes it as an `applied` `bootstrap-flags` entry created directly in that phase, before any other entry and before any mutation. Every later run requires its own set to equal the newest `applied` entry, else exit 3 in preflight, mutating nothing, printing the recorded set beside each differing flag. The `harbor-install` proof for the deferral forms is checked here too, after the lock is held and recovery has run.

**Tests.** First run writes the entry before any mutation; an equal set proceeds; each differing flag exits 3 with both values printed; a different administrator's key path exits 3 and the message names the recorded path; a run whose release has no `applied` `harbor-install` entry exits 3 naming the reinstall.

**Commit:** `feat(bootstrap): flag-set intent entry and the rerun binding`

**Slice 3b ends here.** Stacked PR on 3a.

---

## Slice 3c: the root bootstrap sequence

### Task 12: `lib/user.sh` operator account

**Contract.** Inspection first: does the account exist with the recorded shell and home. Creation is `useradd --create-home --shell /bin/bash <operator>` with no sudo and no extra groups, journaled `user` `created`. The sudo-capable-operator refusal of spec section 5.1 exits 3 before any Git invocation when `--operator` names root, the invoking `SUDO_USER`, or a member of the `sudo` or `admin` group. `harbor_user_linger` enables linger, journaling the pre-state.

**Commit:** `feat(user): operator account, sudo-capable refusal, linger`

### Task 13: `lib/ssh.sh` authorized key

**Contract (spec section 3.5).** The source is the invoking `SUDO_USER`'s `authorized_keys` only, and only when it exists, is readable, and is non-empty; otherwise `--authorized-key-file PATH` is required and Harbor never guesses another account. The entry records source path and mode, target path, and the SHA-256 of both. After the copy the target is owned by the operator, mode `0600`, inside a `0700` `.ssh`. An existing operator `authorized_keys` is left untouched and journaled `observed`.

**Commit:** `feat(ssh): authorized-key bootstrap with journaled hashes`

### Task 14: `lib/ssh.sh` operator drop-in

**Contract.** Write `/etc/ssh/sshd_config.d/50-harbor-operator.conf` limited to the operator: public-key-only, password and keyboard-interactive off, and no directive that changes who may log in. Run `sshd -t`, assert `sshd -T -C user=<operator>` reports both `no` values and that `sshd -T -C user=<installation user>` is unchanged for every directive, then reload. The `--harden-sshd` global drop-in is a separate journaled file and refuses unless the installation user has an authorized key.

**Commit:** `feat(ssh): operator-scoped drop-in with the sshd assertions`

### Task 15: `lib/firewall.sh`

**Contract (spec section 3.4).** Inactive `ufw` before bootstrap: set `default deny incoming`, `default allow outgoing`, add `allow in on tailscale0 to any port 22 proto tcp comment harbor`, enable. Already active: add only the tagged rule, journal the existing defaults, change nothing else. Changing defaults requires `--adopt-firewall`, which journals the prior defaults. No rule names a physical interface. `--allow-lan-ssh` adds a journaled rule for the node's current RFC 1918 network and is a status warning.

**Commit:** `feat(firewall): pre-state-aware ufw rules`

### Task 16: `lib/power.sh`

**Contract.** Write `/etc/systemd/logind.conf.d/harbor.conf` with the three lid settings `ignore`; mask sleep, suspend, hibernate, and hybrid-sleep unless already masked, journaling each pre-state; restart `systemd-logind`.

**Commit:** `feat(power): logind lid policy and masked sleep targets`

### Task 17: `node/bootstrap.sh` skeleton and preflight

**Contract.** The root-only bash 5 script the dispatcher calls. Preflight in the table's order: `/etc/os-release` reports the locked release and amd64; root with a valid `SUDO_USER` or `--authorized-key-file`; the operator-name clash refusal; the checkout or entrypoint rules of slice 3b; `/var/lib/harbor/` created if absent; lock parses and is held; `journal/` exists or `bootstrap.json` is absent too; recovery clean; the flag binding. Then the `bootstrap-flags` entry, then the install-Harbor step, the release of the lock, and the `exec` of the installed entrypoint with the original arguments.

**Commit:** `feat(bootstrap): root preflight, intent entry, install and re-exec`

### Task 18: The remaining steps in table order

**Contract.** Wire packages, operator user, Node.js, authorized key, sshd, firewall, power, and linger into the sequence, each as one journaled transaction with a named step boundary so `HARBOR_FAIL_AFTER` can cut between mutation and the `applied` write.

**Commit:** `feat(bootstrap): the journaled root step sequence`

### Task 19: `bootstrap.json`

**Contract.** Written last, mode `0644`: lock hash, flags, release tag and the absolute `entrypoint`, installed Node.js version, Tailscale ownership with its version when Harbor-installed or adopted, operator name, uid, gid, home, and timestamp. `/var/lib/harbor`, its `lock.d`, and its `reclaim.d` stay `0755` with `0644` holder records; `journal/` and `bootstrap.log` stay root-only. Bootstrap then prints the operator's next command and exits without switching user.

**Commit:** `feat(bootstrap): the 0644 state record`

**Slice 3c ends here.** Stacked PR on 3b.

---

## Slice 3d: Tailscale and the integration lane

### Task 20: `lib/tailscale.sh` install and adoption

**Contract (spec section 5.2, Tailscale rows).** Pre-existing: journal `observed`, compare to the lock, report drift as `degraded`, change nothing unless `--adopt-tailscale`, which installs the locked version and journals `modified` with the prior version. Absent: add the vendor keyring and apt source through `lib/apt.sh`, install the locked version, journal `tailscale-install` `created`. An unavailable pinned version fails naming the lock file.

**Commit:** `feat(tailscale): pinned install and guarded adoption`

### Task 21: The operator grant

**Contract.** Never run `tailscale up` here. Probe: the operator runs `tailscale status --json` without sudo, which proves read access only. Harbor-installed: `tailscale set --operator=<operator>`, journaled `created` with `pre_state` `absent`, no other preference touched. Pre-existing with a failing probe: read the prior value only through `tailscale get operator`, and only when it exists and prints an exact value, then adopt only with `--adopt-tailscale`. No exact value or no flag: mutate nothing and report the `sudo tailscale set --operator=<operator>` precondition. `BackendState` decides the closing report: running is silent, not running and Harbor-installed reports `needs_tailscale_login`, not running and pre-existing prints that the owner brings it up themselves.

**Commit:** `feat(tailscale): operator grant with the read-access probe`

### Task 22: `harbor auth tailscale`

**Contract (spec section 3.6).** Operator-run, unprivileged, allowed only on a Harbor-installed, not-running install. Runs `tailscale up --hostname=harbor-node`, plus `--ssh` only when bootstrap recorded `--tailscale-ssh` and the feature gate of Task 23 is open. Shows the login URL. A daemon refusal exits 3 with the vendor's output, mutates nothing, and prints the root-owned alternative. Tailscale authentication is never journaled.

**Commit:** `feat(auth): attended tailscale login`

### Task 23: The `--ssh` feature gate

**Contract.** `--tailscale-ssh` ships as a supported flag only if the vendor-smoke probe records that the operator can run the exact `up --ssh` form without sudo. Until that record shows acceptance, the flag is refused with exit 3 and `harbor auth tailscale` prints the `sudo tailscale set --ssh` alternative. The record lives in the repository as a dated file so the gate is reviewable, and the PR body states its state.

**Commit:** `feat(tailscale): gate --tailscale-ssh on the recorded operator probe`

### Task 24: `integration.yml`

**Contract (spec section 7, integration lane).** An `ubuntu-24.04` job with systemd as PID 1 and passwordless sudo: create a local exact tag on the checkout under test, run `sudo ./bin/harbor bootstrap` at real paths, assert operator creation, the authorized-key copy, the sshd drop-in with its `sshd -t` and both `sshd -T` assertions, the logind drop-in and masking, the firewall rule set for both pre-states against the logging `ufw` wrapper, linger plus a real `systemctl --user` through `runuser` with `XDG_RUNTIME_DIR`, the installed-entrypoint copy, symlink, re-exec, and preflight, the shimmed installs with `--version` assertions, and the Tailscale apt step against a local file-based repository holding a stub package at the locked version. Then the second run asserts zero mutating shim calls and no new entries, and `HARBOR_FAIL_AFTER=<step>` at each boundary asserts convergence on rerun. Root-phase runs pass hooks only through the explicit `sudo env` argument list.

**Commit:** `ci: integration lane for the real bootstrap on an ephemeral VM`

### Task 25: Final verification and the PR

**Contract.** The full unit lane under both shells; every static check; the integration lane green; the diff read once against the file map; the acceptance list of spec section 8 row 3 checked item by item; the PR body stating the changed-line count, the `--ssh` gate state, and the section 5.2 operator flow's manual acceptance result.

---

## Open questions for the owner

1. Spec section 9 decisions 1 to 8 are still marked pending owner approval on PR 1. This plan implements the recommended default of each, which is what section 9 says PR 2 onward does unless changed. Decisions 2, 3, 4, and 6 bind slices 3c and 3d directly.
2. The pinned values of Task 1 are a review point in their own right: they set the Node.js and Tailscale versions the node will run.
