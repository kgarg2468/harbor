# T3 Reasoning

Harbor's component for the Reasoning variant of T3 Code: the exact upstream
source revision plus a maintained, reviewable feature patch set. The design is
in `docs/design.md`; the provenance and maintenance record for the current
pin is in `docs/nightly-port.md`.

## Status

Reproducible port of the existing Reasoning feature set onto the latest
Nightly. `source.lock.json` pins upstream commit
`9cb40178a53cca279c67a9079afab3cddf6b6ddb`, which is tag
`v0.0.39-nightly.20260905.1284`, and four checksummed patches. Preparing the
source yields a checkout you can install dependencies into and build the
server from, using upstream's own scripts.

What this component does not do:

- It does not update automatically or discover new Nightlies. Moving to a
  newer Nightly is a change to `source.lock.json`, and possibly to the
  patches, made and reviewed by hand. See `docs/nightly-port.md`.
- It does not install, update, launch, or synchronize anything, and it does
  not touch an existing T3 installation or its data. No shared live
  installation exists yet.
- It does not implement the shared environments, queued updates, or
  conversation forks from `docs/design.md`. Those start from this pin.

## Layout

- `source.lock.json`: the pin. `version` is `1`; `repository` is the upstream
  HTTPS URL; `commit` is the full SHA-1; `patches` is the ordered list of
  `{ "path", "sha256" }` entries. Each path is relative to the lock file and
  must stay inside the lock file's directory: absolute paths, `..` escapes,
  and symlinks whose real target lies elsewhere are rejected even when the
  checksum matches. Subdirectories are fine.
- `patches/0001-reasoning.patch`: streaming provider reasoning into the
  thread timeline, with its server, contracts, client runtime, web, mobile,
  and docs changes.
- `patches/0002-desktop-identity.patch`: the separate Reasoning desktop
  identity, the disabled updater feed, the packaged backend PATH fix, and the
  manual macOS updater script.
- `patches/0003-update-admission.patch`: a tested command-admission primitive
  for maintenance. It is not yet wired into server requests or an updater;
  it does not by itself detect agent activity or enable automatic updates.
- `patches/0004-queued-update.patch`: the durable queue controller, with injected
  staging and activation operations. See `docs/queued-updates.md`; it is not
  connected to the live updater yet.
- `UPSTREAM-LICENSE`: upstream's MIT license, copied unchanged.
- `scripts/prepare-source.mjs`: the CLI that materializes the pin.
- `tests/prepare-source.test.mjs`: tests that drive the CLI against a
  temporary fixture repository with real `git` processes.
- `docs/design.md`: the product contract. `docs/nightly-port.md`: where the
  patches came from, what they change, and how to re-port them.
- `.build/`: ignored build output, including the default checkout.

## Preparing the source

Requires Node.js 24 and `git`. No npm dependencies.

```sh
node t3-reasoning/scripts/prepare-source.mjs
```

Defaults are the component's `source.lock.json` and the destination
`t3-reasoning/.build/source`. Options:

- `--lock /absolute/lock.json`: use another lock file.
- `--destination /absolute/new/path`: write somewhere else. The path must not
  exist; the tool never modifies or replaces an existing directory.
- `--repository <path-or-url>`: fetch from a local clone or mirror instead of
  the lock's repository. The lock's commit is still required exactly. Intended
  for offline tests and caches. A relative local path such as `./mirror` is
  resolved against the directory you run the command from; URLs and SCP-like
  `host:path` forms are passed to `git` unchanged.

The tool first checks that every patch path stays inside the lock directory
(symlinks resolved), then reads each patch and verifies its SHA-256 against
the lock, all before any network or filesystem work. It then fetches the
pinned commit into a staging directory next to the destination, checks it out
detached, applies
the patches in order by piping the already-verified bytes into `git apply`
(the patch files are never re-read, so a file changing after verification
cannot reach the checkout), and only then renames the staging directory into
place. A checksum mismatch, a patch that does not apply, or a commit missing
from the repository exits non-zero, removes the staging directory created by
that run, and publishes nothing.

Runs against the same destination are serialized by an exclusive lock
directory, `<destination>.lock`, created with `mkdir` and removed when the run
ends. A second run started while the first holds the lock exits non-zero
before fetching anything. If a run is killed and leaves the lock behind, remove
the directory by hand once no run is in progress.

This protection has a precise boundary: the destination is an owned build
output path, and the guarantee is that invocations of this tool never replace
each other's output or an existing path. It is not a defense against arbitrary
concurrent writers. On POSIX, `rename` replaces an empty directory, so an
outside process that creates an empty directory at the destination during the
final publish step would have it replaced.

The result is a detached checkout at the pinned commit with the patches applied
as uncommitted working-tree changes, so `git diff` in the checkout shows the
whole feature delta. The provenance record, including the lock used, the
repository actually fetched from, the commit, and the patch checksums, is
written to `.git/harbor-source.json` inside the checkout.

## Installing dependencies and building the server

The prepared checkout is a normal upstream monorepo. Its `package.json`
declares `pnpm@11.10.0` and Node `^24.13.1`; use those versions, for example
through `corepack`. From inside the checkout:

```sh
pnpm install --frozen-lockfile
pnpm --filter @t3tools/web build
pnpm --filter t3 build:bundle
pnpm --filter t3 start
```

The web build produces the static client the server serves; the server
bundle lands in `apps/server/dist`. Focused checks in the checkout are
`pnpm --filter t3 test` for the server and `pnpm typecheck` for the
workspace. These are upstream's scripts, run by hand; Harbor's CI does not
run them, and none of them install or start a desktop app.

## Running the checks

```sh
node --test t3-reasoning/tests/*.test.mjs
npx --yes markdownlint-cli@0.41.0 --config .markdownlint.yml 't3-reasoning/**/*.md'
```

These are the commands `.github/workflows/t3-reasoning.yml` runs on Linux and
macOS whenever this directory changes.

The first two patches reproduce the port commit's tree recorded in
`docs/nightly-port.md`. Later patches add incremental features beyond that
baseline. The admission primitive's focused check in a prepared checkout is
`pnpm --filter t3 test src/updateAdmission.test.ts` (11 tests).
