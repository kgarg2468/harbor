# T3 Reasoning

Harbor's component for the Reasoning variant of T3 Code: the exact upstream
source revision plus a maintained, reviewable feature patch set. The design is
in `docs/design.md`.

## Status

Initial bootstrap: reproducible source preparation only. This directory pins an
upstream revision and can materialize it locally with the patch set applied.
Nothing here builds, installs, updates, or synchronizes anything, and nothing
here touches an existing T3 installation or its data. The pinned revision is a
reproducibility baseline, not a claim that it is the current Nightly.

## Layout

- `source.lock.json`: the pin. `version` is `1`; `repository` is the upstream
  HTTPS URL; `commit` is the full SHA-1; `patches` is the ordered list of
  `{ "path", "sha256" }` entries, with paths relative to the lock file. The
  patch list is empty until the feature import lands.
- `scripts/prepare-source.mjs`: the CLI that materializes the pin.
- `tests/prepare-source.test.mjs`: tests that drive the CLI against a
  temporary fixture repository with real `git` processes.
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

The tool first reads every patch and verifies its SHA-256 against the lock,
before any network or filesystem work. It then fetches the pinned commit into
a staging directory next to the destination, checks it out detached, applies
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

## Running the checks

```sh
node --test t3-reasoning/tests/*.test.mjs
npx --yes markdownlint-cli@0.41.0 --config .markdownlint.yml 't3-reasoning/**/*.md'
```

These are the commands `.github/workflows/t3-reasoning.yml` runs on Linux and
macOS whenever this directory changes.
