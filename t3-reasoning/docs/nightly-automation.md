# Nightly automation: discovery and materialization proof

This document describes `scripts/discover-upstream-nightly.mjs`, the first
bounded piece of managed Nightly automation: a helper that finds the newest
published upstream Nightly, proves locally that Harbor's patch catalog still
materializes on it for both variants, and writes a candidate report. It
mutates nothing on GitHub and nothing in the checkout. The two trusted
workflows that run it on a schedule, propose the candidate PR, and check the
PR's exact head are described at the end, together with the stages that
remain boundaries (merge policy and the four-artifact build).

## What the helper does

1. Reads the version 2 lock, re-hashes every catalog patch, and checks the
   two-variant closure (`reasoning` extends `managed-nightly` by identity
   patches only). All of this happens before any network call.
2. Reads the tracked provenance record `upstream-release.json` when given, and
   requires its commit to equal the lock's commit.
3. Lists `pingdotgg/t3code` releases read-only through `gh api`, paginated,
   and selects the maximum exact ordinary Nightly version among published,
   non-draft prereleases with a real publication time. Response order,
   timestamps, `/releases/latest`, stable releases, and unrelated prereleases
   play no part.
4. Resolves the selected tag to a full commit, peeling annotated tag objects.
   A missing ref, a cycle, or a non-commit target is an error.
5. Copies the verified patch files into a private stage beside a candidate
   lock whose only changed field is `commit`, then runs the real
   `prepare-source.mjs` twice against that lock, once per variant, into
   separate fresh destinations. The preparer's own fetch, checkout equality
   check, and exact sequential `git apply` are the proof. No `--3way`, fuzz,
   conflict markers, or branch checkout substitute for it.
6. Records each prepared tree through a private Git index (`read-tree HEAD`,
   `add -A`, `write-tree`) so the report captures the patch-applied tree while
   HEAD stays the upstream commit, and checks the preparer's provenance
   against the lock's variant selection.
7. Re-reads the release and the tag immediately before publishing and fails if
   the identity, publication state, or commit moved.
8. Writes the result into a new destination directory atomically: it is staged
   next to the destination and renamed into place only when complete.

## CLI

```sh
node t3-reasoning/scripts/discover-upstream-nightly.mjs \
  --lock t3-reasoning/source.lock.json \
  --current-release t3-reasoning/upstream-release.json \
  --destination "$RUNNER_TEMP/t3-nightly-candidate"
```

Flags:

- `--destination <new path>` (required): where the report goes. The path must
  not exist; an existing path is refused before any network call.
- `--lock <file>`: the version 2 lock. Defaults to the component's
  `source.lock.json`. Its `repository` must be exactly
  `https://github.com/pingdotgg/t3code.git`; discovery never follows an API
  response to another repository.
- `--current-release <file>`: the tracked provenance record. Omit it only for
  the initial bootstrap, before any record exists. When the flag is given, a
  missing file is an error, and so is a corrupt one; neither is treated as
  "no current release".
- `--repository <path-or-url>`: passed through to the preparer's
  `--repository`, so the pinned commit is fetched from a local clone or mirror
  instead of the public upstream. A relative local path is resolved against
  the directory the helper was invoked from, before the private stage exists;
  absolute paths, URLs, and SCP-like `host:path` forms are passed through
  untouched. The candidate lock still records the public URL. Intended for
  tests and caches.
- `--work <dir>`: parent directory for the private stage (copied catalog,
  candidate lock, prepared trees, private index files). Defaults to the system
  temporary directory. The stage is kept only once a `ready` or `conflict`
  report has actually been written to the destination; every other outcome
  after the stage is allocated (a setup failure, a preparer error, the final
  release or tag re-read failing or reporting drift, or a refused publication)
  removes it. Prepared trees must never be added to a Harbor PR.

Exit codes:

| Code | Meaning |
| --- | --- |
| 0 | `ready` or `unchanged`; the destination holds the report |
| 2 | `conflict`; a patch did not apply cleanly, and the destination holds only the report |
| 1 | any other error (usage, lock or provenance validation, API failure, moved tag, preparer failure other than a clean-apply rejection); no destination is created |

A `conflict` is exactly the preparer reporting that `git apply` parsed a patch
and rejected it against the candidate tree: a failed hunk, a file the patch
expects that is missing, or a file it would create that already exists. Git's
exit status 1 alone does not establish that, because git uses the same status
and the same closing "patch does not apply" line when it could not read a
preimage (a permission or I/O error). The preparer therefore requires exit 1
plus git's own tree-rejection verdict lines, in git's untranslated wording
(`patch failed: <path>:<line>`, `No such file or directory`, `already exists in
working directory`, and the like), with no other `error:` line present. For such a rejection the
preparer prints, besides its human diagnostic, one machine-readable stderr
line: `prepare-source-conflict: {"patch":"<path>"}`, with the catalog path
JSON-encoded on that single line. Every other `git apply` outcome, such as an
unreadable preimage, an unwritable tree, a corrupt or empty patch, any
unrecognized error, or a killed git, gets no marker and is reported as an
ordinary failure, which the helper treats as an error: exit 1, no destination,
and the stage removed. The helper classifies only on that exact marker line
from a preparer that exited 1; it never reads git's stderr and never parses
the human prose, because a catalog path may itself contain spaces or the words
"does not apply cleanly". Every other preparer stderr line begins with the
`prepare-source:` prefix, so no path or argument echoed in a diagnostic can
forge the marker.

The `gh` binary must be on `PATH`. A workflow supplies its normal token to gh
the usual way; the helper never reads, prints, or persists it, and every gh
call is a `GET` built from argv, never an interpolated shell string.

## Output

`result.json` is always written. Its `status` is one of:

- `unchanged`: the pinned version is still the newest published Nightly. The
  report carries `latest` (the newest listing entry) and `current`. The
  current tag is re-resolved and must still name the pinned commit; a moved
  tag for the same version is an error, never a silent repin.
- `conflict`: a newer Nightly was selected and resolved, but a variant's patch
  sequence did not apply. The report carries `candidate` (the provenance that
  would have been recorded), `candidateLock` (previous and new commit),
  `conflict` (variant, failing patch path, and the last lines of the
  preparer's stderr, bounded), any variant that succeeded first under
  `variants`, and the stage path under `work`. Nothing else is emitted and
  no older Nightly is tried instead.
- `ready`: both variants applied. The destination additionally contains:
  - `source.lock.json`: the candidate lock, byte-identical to the input lock
    except for the `commit` line.
  - `upstream-release.json`: the tracked provenance record for the selected
    release, in this exact shape:

    ```json
    {
      "schemaVersion": 1,
      "repository": "pingdotgg/t3code",
      "releaseId": 383342473,
      "tag": "v0.0.39-nightly.20260905.1289",
      "version": "0.0.39-nightly.20260905.1289",
      "commit": "8d3c56b487810455f7b695d1b849b4370b132d03",
      "publishedAt": "2026-09-05T18:53:55Z"
    }
    ```

  - `patch-check.json`: every catalog patch with its verified checksum, the
    ordered ids per variant, and the identity suffix.

  The `ready` report also records, per variant, the prepared tree path, HEAD
  (the candidate commit), the tree id of the patch-applied working tree, and
  the ordered patch ids and hashes the preparer recorded.

The values above are the example from the design review, not a record to
commit today: the tracked provenance is bootstrapped only from an actually
selected and pinned candidate, and it stays immutable even if the GitHub
release description later changes. The resolver keeps receiving the upstream
version explicitly from this reviewed record.

## Boundaries

The helper never:

- writes the checked-out lock, provenance record, or patches (every mode
  leaves the checkout byte-identical);
- pushes a branch, opens a PR, publishes a release, or changes any GitHub
  setting;
- installs dependencies, runs package scripts, or executes candidate source;
- overwrites an existing destination, or falls back to an older Nightly after
  a conflict;
- repins a published version to a different commit.

A same-version change upstream (the tag moved, or the release deleted and
recreated under a new id or publication time) is a blocked provenance change
that needs human review; the helper reports it as an error.

## Exports and testing

The module exports `selectPublishedNightly(releases, current)`,
`resolvePublishedCommit(release, api)`, `prepareNightlyCandidate(options)`,
`createGhApi(run)`, `validateProvenance`, `candidateLockText`, and
`parseArgs`. `prepareNightlyCandidate` accepts injected `api` (endpoint to
parsed JSON), `run` (argv command runner), `preparerScript`, `workRoot`, and
`now`, so `tests/discover-upstream-nightly.test.mjs` runs every path against a
deterministic fake API and a local fixture Git repository through the real
preparer and real `git`, with no network access. The CLI cases shim `gh` on
`PATH` with a script that logs its argv and answers from fixture files.

```sh
node --test t3-reasoning/tests/discover-upstream-nightly.test.mjs
```

## Workflows

Two workflows consume the report contract above. Both run only checked-in
code from the default branch, take their inputs as environment variables or
API arguments (never shell interpolation), use pinned action revisions, and
check out with persisted credentials disabled. Neither builds, signs,
publishes, merges, installs, or changes a repository setting.

### Discovery: `.github/workflows/t3-managed-nightly-discovery.yml`

Triggers: a daily `schedule` (05:23 UTC) and `workflow_dispatch`. The job runs
only when the ref is `main`. The concurrency group is fixed and never cancels
a run in progress, so a run that is already publishing finishes.

The job runs the helper with `--destination "$RUNNER_TEMP/t3-nightly-candidate"`
and `--work "$RUNNER_TEMP/t3-nightly-work"`, and passes `--current-release`
only when `t3-reasoning/upstream-release.json` is tracked (the first run is the
bootstrap). Exit 0 and 2 are consumed by reading `result.json`; exit 1 fails
the step with no report. The run artifact `t3-nightly-discovery-report`
retains `result.json` for `ready`, `unchanged`, and `conflict`, plus
`patch-check.json` for `ready`. Exit 1 produces no report artifact. Prepared
trees stay under the work directory and never leave the runner.

| Status | Behavior |
| --- | --- |
| `unchanged` | Summary only; nothing else happens. |
| `conflict` | Report uploaded, then the run fails with an annotation naming the variant and the failing patch. |
| `ready` | The candidate PR is proposed and the checker is dispatched, as below. |

On `ready` the publish step, a trusted script that imports this helper's own
`candidateLockText` and `validateProvenance`, first re-checks the emitted files
against the checkout: the candidate lock must equal the base lock with only
the commit line replaced and must pin a different commit; the provenance must
name that commit and match the report; and, when a tracked record exists, the
candidate version must be greater. It then copies exactly the two files into
the checkout and requires `git status` to show nothing but them. The commit is
created through the Git data API from the base commit's tree plus the two
blobs (parent = the run's base commit), so nothing else can be pushed and no
credential ever enters git configuration. The branch is deterministic,
`t3/nightly-candidate/<upstream version>`, and is only ever created, never
force-updated. A PR against `main` is opened and the checker is dispatched on
`main` with the PR number and the exact pushed SHA, because a token-created
push and PR do not launch the ordinary `push`/`pull_request` workflows.

Rerun behavior for an existing candidate branch. Before the branch is reused
in any way, its head must be proven to be exactly the deterministic candidate
commit, read-only through the Git data API: a single-parent commit whose
parent is the run's base commit or an ancestor of it on `main` (checked with
the compare API), and whose tree differs from that parent's tree in nothing
but the two candidate paths, each a plain `100644` blob with the expected id.
Byte-identical candidate files alone are not enough, because a branch can
carry them beside extra files or extra commits.

- Proven head and an open PR owning it: idempotent. Nothing is written; the
  checker is dispatched again for the existing head.
- Proven head and no PR ever opened (an earlier run failed after the push):
  the PR is created against the existing head.
- Anything else, before any write or dispatch: different content at the head,
  an extra or changed path (including under `.github/workflows/`), a mode
  change, a merge commit or a parent that is not on `main`, a tree listing the
  API cannot return completely, a closed PR, or PR history without the branch.
  The run fails and names the reason. Close the PR and delete the branch by
  hand, then rerun.

Not proposed automatically: a provenance-only bootstrap where the newest
Nightly is the commit already pinned (commit `upstream-release.json` by hand),
and a candidate that has gone stale because the default branch's catalog
moved (close the PR, delete the branch, rerun). An older open candidate PR is
not closed when a newer Nightly is proposed.

Job permissions are `contents: write`, `pull-requests: write`, and
`actions: write`; the token is supplied to `gh` only through the environment.

### Candidate checker: `.github/workflows/t3-managed-nightly-candidate.yml`

`workflow_dispatch` with inputs `pull_request_number` and `head_sha` (a full
40-character lowercase SHA). Jobs run only when the ref is `main`; the
concurrency group is per head SHA and never cancels.

The `validate` job (`contents: read`, `pull-requests: read`):

1. Checks both inputs' grammar in the shell before any checkout.
2. Checks out the trusted default-branch code, and fetches the candidate SHA
   into `candidate/` as data only (full history, persisted credentials
   disabled). Nothing under `candidate/` is executed; every script that runs
   comes from the trusted checkout.
3. Reads the PR through the API and requires it to be open, based on `main`,
   with base and head in this repository, `head.sha` equal to the input, and
   a `t3/nightly-candidate/<version>` head branch.
4. Requires the diff between the merge-base with `origin/main` and the head
   to be exactly `t3-reasoning/source.lock.json` (modified) and
   `t3-reasoning/upstream-release.json` (added or modified), both plain
   `100644` files, with no rename detection. A head already contained in
   `main` is refused.
5. Requires the candidate lock text to equal both the merge-base lock and the
   trusted default-branch lock with only the commit line replaced, so every
   catalog entry, hash, variant, and the repository URL are retained and a
   stale candidate is refused.
6. Validates the provenance record with this helper's rules, requires its
   commit to equal the lock commit and its version to equal the branch
   version, requires it to advance the tracked record when one exists, and
   re-reads the upstream release by id and resolves its tag read-only through
   `gh api`; both must match the record.
7. Overlays the two validated files onto the trusted checkout, re-verifies
   the catalog hashes, then runs the trusted component unit tests, Markdown
   lint, and the real preparer for both variants (the materialization proof).

The `status` job (`statuses: write`, `pull-requests: read`) runs after
`validate` whatever its result and publishes the commit status
`t3-managed-nightly-candidate` on the exact SHA. It reports `success` only
when `validate` succeeded and the PR is still open and still owns that SHA;
otherwise it reports `failure` (a moved head is reported as such) and the job
itself fails. This context exists only on candidate heads: the checker runs by
explicit dispatch from discovery, so ordinary Harbor and fleet PRs never
receive it. It is the status the candidate merge path must require on the
PR's exact head SHA, not a required status check on `main` (see below).

## What is still not configured

- The repository setting that lets Actions create PRs is currently off, and
  no automation identity exists. Until it is enabled (or a narrowly scoped
  GitHub App token is used), the discovery run creates the branch and then
  fails at PR creation; the next run recovers by creating the PR.
- Review and merge policy for bot-authored candidate PRs, including whether
  Greptile reviews them. The merge path for these two-file PRs (a trusted
  merge identity or a later merge automation) must require a `success`
  `t3-managed-nightly-candidate` status on the PR's exact head SHA and merge
  nothing else. That requirement belongs to the candidate merge path only: do
  not add the context as a required status check in a `main` branch rule,
  because ordinary PRs never receive it and such a rule would leave every
  non-candidate PR waiting on a check that never reports. (A global required
  check would first need a general workflow that reports a result for every
  PR, which does not exist.) Auto-merge is disabled and no branch rules are
  enforced today, so following a Nightly stops at an open, checked PR.
- Porting the newer reviewed source changes into the patch catalog. The helper
  proves only the catalog that is checked in; a `conflict` result is the
  signal that a patch needs to be re-ported by hand.
- The four-artifact managed release build, signing and notarization policy,
  the public build configuration, and immutable release enforcement.
