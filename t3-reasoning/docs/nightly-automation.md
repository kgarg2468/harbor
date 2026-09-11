# Nightly automation: discovery and materialization proof

This document describes `scripts/discover-upstream-nightly.mjs`, the first
bounded piece of managed Nightly automation: a helper that finds the newest
published upstream Nightly, proves locally that Harbor's patch catalog still
materializes on it for both variants, and writes a candidate report. It
mutates nothing on GitHub and nothing in the checkout. The trusted workflows
that run it on a schedule, propose the candidate PR, check the PR's exact
head, and publish the four-artifact managed release once a candidate has
merged are described at the end, together with the stages that remain
boundaries (signing and installation).

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

Discovery and checker workflows consume the report contract above. A trusted
promoter merges an exact clean candidate and dispatches managed publication. All run only checked-in code
from the default branch, take their inputs as environment variables or API
arguments (never shell interpolation), use action revisions pinned by full
commit SHA, and check out with persisted credentials disabled. None signs, installs, or changes a repository setting; only the promoter
merges and only the release workflow builds and publishes.

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

### Automatic promotion: `.github/workflows/t3-managed-nightly-promote.yml`

The trusted main-only reconciler runs at minutes 8, 23, 38, and 53 each hour,
plus `workflow_dispatch`, with fixed noncancelling concurrency. It runs
`scripts/promote-nightly-candidate.mjs` from the exact workflow SHA and
requires that SHA still be current main. Candidate objects are read only
through GitHub APIs; no candidate checkout, hook, script, dependency, or
binary executes. Permissions are contents/pull-requests/actions write and
statuses/checks read, with no repository-setting changes.

The promoter paginates open same-repository PRs and requires a GitHub Actions
bot-created, open, nondraft candidate against current main. The branch must
own the exact head and name the provenance version. That head must have one
parent on main ancestry, and complete Git trees must differ from its parent
in exactly the lock and provenance files as plain `100644` blobs. Blob sizes
and Git hashes are checked. The lock must match both the parent and current
main with only the commit line replaced. Trusted lock/provenance validators
are reused, and the official published release, peeled tag, and newest
Nightly listing must agree. A superseded or stale candidate stays pending.

The latest exact-head candidate status must come from GitHub Actions and link
to a successful, completed run of the exact trusted checker workflow,
`workflow_dispatch` on main at the current base revision, with successful
`validate` and `status` jobs from that run attempt. Missing or stale checker
proof triggers a fresh checker dispatch; an active main checker suppresses
repeat dispatch because its inputs are not exposed in the run listing.

Greptile must authenticate as app id `867647`, check name `Greptile Review`.
Its latest exact-head check must complete successfully with zero annotations,
an empty paginated annotation listing, and the exact summary
`2 files reviewed, 0 comments added.`. Any other grammar stays pending.
All inline review comments and any `CHANGES_REQUESTED` review block promotion
conservatively, including historical findings: these REST records do not
expose a reliable app id. PR body prose is never a gate. Missing, delayed,
unknown, failed, or truncated results never become success after a timeout.

Every gate is read again immediately before a merge request with explicit
head SHA. After merging, the promoter authenticates the bot merge, its two
parents, and its exact resulting tree before dispatching
`t3-managed-release.yml` on main with `expected_main_sha`. This explicit
workflow dispatch is necessary because a merge with `GITHUB_TOKEN` suppresses
the ordinary push-triggered release event. No `check_run` event is required.

If the merge succeeds but its response or release dispatch is lost, a later
scheduled run recovers only a bot-merged candidate whose merge commit is
still current main. It repeats provenance, ancestry, checker, and review
proofs. Active or successful release runs for that exact main SHA suppress
another dispatch; failed runs may be retried. An older merge after main has
advanced, a merge with additional tree changes, or a newer upstream Nightly
is not recovered automatically. GitHub offers no atomic base-SHA merge guard
or dispatch idempotency key: head SHA is guarded by the merge API, main is
re-read around the write, and the release input fails closed if dispatch
resolves a moved main. A dispatch invisible in the API can be retried by a
later schedule; publication retains its existing immutable-tag safeguards.

Tests use an injected API, command runner, and clock, with no live mutations:

```sh
node --test t3-reasoning/tests/promote-nightly-candidate.test.mjs
```

### Managed release publication: `.github/workflows/t3-managed-release.yml`

Triggers: a push to `main` that changes `t3-reasoning/source.lock.json` or
`t3-reasoning/upstream-release.json` (a merged candidate), and
`workflow_dispatch` with optional `expected_main_sha`, for a new attempt
after a build failure or a public-config or builder change. Automated
promotion supplies the full expected SHA. The first resolve step fails before
checkout or building when it differs from `github.sha`; the run name includes
that expected SHA (or the workflow SHA for a manual rebuild). Every job is gated on
`github.repository == 'kgarg2468/harbor'` and `github.ref ==
'refs/heads/main'`; there is no pull-request trigger and no caller-supplied
ref, repository, tag, or platform. The concurrency group is fixed and never
cancels a run in progress. The top-level permission is `contents: read`;
only the final `publish` job has `contents: write`.

Every Node step comes from `scripts/publish-managed-release.mjs`, whose
subcommands are closed to `kgarg2468/harbor` and the `t3-managed-v` tag
prefix, reach GitHub only through `gh api` with argv, and accept only `GET`,
`POST`, and `PATCH`: nothing in the workflow can delete, force, clobber, or
edit an existing release, tag, or asset.

Every release operation (upstream re-read, prior lookup, tag checks, draft
creation, uploads, publication, and postchecks) runs on the workflow's own
`GITHUB_TOKEN` with `contents: read` in `resolve` and `contents: write` in
`publish`. The one exception is the repository's immutable-releases setting
(`GET /repos/kgarg2468/harbor/immutable-releases`), which GitHub serves only
to an identity with repository **Administration read**, a permission the
workflow token cannot be granted. That single read runs through a separate,
closed, GET-only client whose credential is the fine-grained secret
`T3_MANAGED_RELEASE_ADMIN_READ_TOKEN`. The secret needs only repository
Administration read on `kgarg2468/harbor` (no contents write, no other
permission), is exported only to the `preflight` step of `resolve` and the
final `publish` step, and is handed to that client's child `gh` solely as
`GH_TOKEN`, never as an argument, output, summary, or log line. A missing
secret or a refused read is fatal in `preflight` before any build row runs
and again in `publish` before any release mutation. The workflow never
requests `administration:` in its `permissions` map and never changes the
setting.

The `resolve` job (Ubuntu) checks out exactly `github.sha`, requires
`git rev-parse HEAD` to equal it and a clean tree, and installs Node 24.13.1
and pnpm 11.10.0. `verify-upstream` re-verifies the lock and every patch
checksum, validates the tracked provenance record, requires lock/record
commit agreement, re-reads the official release by id, and peels its tag;
any moved, deleted, draft, non-prerelease, or retargeted upstream release
fails closed. `public-config` builds the four-key public-config file from
exactly the repository variables `T3CODE_CLERK_CLI_OAUTH_CLIENT_ID`,
`T3CODE_CLERK_JWT_TEMPLATE`, `T3CODE_CLERK_PUBLISHABLE_KEY`, and
`T3CODE_RELAY_URL` through the resolver's validator, printing only the
fingerprint. `prior` selects the highest published, immutable, non-draft
prerelease whose tag is exactly `t3-managed-v<managed version>`. Only
well-formed rows are deliberately ignored: drafts, stable releases, tags
outside the grammar, and explicitly unpublished entries (`published_at:
null`). A row that is not an object or has no string tag, a managed-tag row
whose `draft` or `prerelease` is not a boolean or whose `published_at` is
not a publication time, a mutable managed release, or the same managed
version appearing twice anywhere in the paginated listing (regardless of
order or page boundary) fails closed. The selected release is re-read by id
and must still carry the listed tag, state, immutability, and publication
time and exactly one well-formed `managed-release.json` asset with a
positive size; that asset is downloaded by numeric id, its size and any
reported digest must match the bytes, and the manifest must name the tag's
version. The resolver then runs
exactly once with the lock, the tracked upstream version, `github.run_number`
as the counter, `github.sha` as the builder revision, the public config, and
the prior manifest when one exists. `preflight` requires immutable releases
to be enabled (read with the Administration-read secret described above)
and the intended tag to be absent from Git refs and from releases of every
state, including drafts; a collision is refused, never reused or removed,
and a malformed ref or release row is not evidence of absence and fails.
The job uploads one short-retention artifact holding only the descriptor
and the public-config file.

The `build` job is one static four-row matrix with `fail-fast: false`:
`managed-server-darwin-arm64` and `managed-server-linux-x64` run the server
builder on `macos-15` and `ubuntu-24.04`; `managed-nightly-darwin-arm64` and
`reasoning-darwin-arm64` run the desktop builder on `macos-15`. Each row
checks out the same SHA, installs the pinned Node, pnpm, and Rust 1.95.0
with its exact native target, downloads the shared inputs, requires the
descriptor's `builderRevision` to equal `github.sha`, prepares a fresh source
tree with the real preparer for its variant, and runs exactly one existing
builder into a new destination. Nothing is cached, shared between rows,
signed, or notarized.

Both native server artifacts must then start and pass the existing
two-client shared smoke (`scripts/smoke-shared.mjs`, see
[shared-smoke.md](shared-smoke.md)) on their own runner before they leave it
and before anything is published. On each server row the `shared-smoke`
step, with its own ten-minute timeout, selects exactly
`built/<artifact id>-<version>.tar.gz`, requires it to be a regular
non-symlink file, extracts it into a private root beneath the runner's temp
directory that only this step creates and removes, and requires the
extracted `runtime/node_modules/t3/dist/bin.mjs` to be a regular non-symlink
file. It then runs the checked-in smoke from that root under a scrubbed
environment (`env -i`) holding only the runner `PATH`, an isolated `HOME`
and `TMPDIR` inside that root, and `T3CODE_SKIP_LOGIN_SHELL=1`: no GitHub
token, admin-read secret, public config, provider credential, or ambient
home reaches the built server. The smoke starts the archive's server on its
own loopback port and private `T3CODE_HOME`, pairs two clients, creates a
project and thread, renames the thread from the second client, observes the
rename on the first including across a disconnect and reconnect, starts no
provider turn, and prints pass/fail counts plus redacted failure details. A
missing archive or
entry, an extraction failure, a failed or timed-out smoke, or a cleanup
setup error fails that row with no retry, fallback, or ignored exit, so its
archive is never uploaded and the release is never published. The desktop
rows and the `publish` job never open or execute an archive. Only the row's
canonical archive and its one inventory JSON are uploaded, under
`t3-managed-build-<artifact id>`.

The `publish` job (Ubuntu, `contents: write`) repeats the trusted checkout
and upstream checks, downloads the four rows into separate directories,
and runs `assemble`, which requires exactly one inventory and one archive per
row and copies the archives into one flat directory without opening them.
The existing manifest writer then produces the release directory, and
`publish` proves it holds exactly the six feed files (`managed-release.json`,
`SHA256SUMS`, and the four archives) with every checksum and size matching
local bytes, re-checks repository, ref, builder commit, upstream identity,
the immutable setting, and tag absence, and only then mutates GitHub, in this
order: create one draft prerelease tagged `t3-managed-v<version>` at
`target_commitish` = `github.sha` with `make_latest: false`; upload the six
files without clobber; re-read the draft and require its tag, target, state,
and exact six asset names and sizes, comparing every API digest with local
bytes (an asset without a digest is downloaded by id and hashed); publish by
changing only `draft` to `false`; re-read by id and by exact tag, peel the
tag to `github.sha`, and require `draft: false`, `prerelease: true`, a
publication time, unchanged assets, and `immutable: true`.

Failure handling is deliberately non-destructive, and what a red run leaves
behind depends on where it failed. A failure before the publish call (an
upload, the draft re-read, or a size/digest mismatch) leaves the draft in
place for inspection; drafts are not visible to the public. Once the publish
`PATCH` has been sent, the release may already be public: a lost or
malformed `PATCH` response is reported as an uncertain publication naming
the release id, and a failed post-publication proof (not immutable, a
changed asset, a tag that does not resolve to `github.sha`) is reported
against a release that is already visible. In every case the publisher sends
the publish call at most once, retries nothing, and deletes, edits, or reuses
nothing; a person inspects the release by its recorded id and exact tag and
decides what follows. The next run consumes a new run number and therefore
a new version and tag. The published release is the feed transaction:
clients see the previous immutable release until every artifact is present
and the draft is published.

The publisher is unit-tested against a fake GitHub API and the structure of
the workflow is asserted in `tests/publish-managed-release.test.mjs`:

```sh
node --test t3-reasoning/tests/publish-managed-release.test.mjs
```

## What is still not configured

- Actions may now create PRs: `can_approve_pull_request_reviews` is enabled
  while `default_workflow_permissions` remains `read`, so the discovery run
  opens its candidate PR with the workflow token. No separate automation
  identity exists; candidate PRs carry the token's identity.
- Greptile must actually review bot-created candidate heads and produce the
  authenticated clean check described above. The promoter never bypasses a
  missing review. Do not make the candidate context globally required on
  main: ordinary Harbor and fleet PRs never receive it. The exact-head gate
  belongs to this narrow candidate merge path.
- Porting the newer reviewed source changes into the patch catalog. The helper
  proves only the catalog that is checked in; a `conflict` result is the
  signal that a patch needs to be re-ported by hand.
- The release workflow's prerequisites: immutable releases are not yet
  enabled for the repository (the `preflight` step fails closed until they
  are); the repository secret `T3_MANAGED_RELEASE_ADMIN_READ_TOKEN` is not
  yet installed (a fine-grained token for `kgarg2468/harbor` with repository
  Administration read and nothing else, required because the workflow token
  cannot read the immutable-releases setting; `preflight` and `publish` fail
  closed without it); the four `T3CODE_*` repository variables are not yet
  installed; and the pinned Rust 1.95.0 toolchain has not yet been proven to
  build the current prepared source on both runner images. Managed releases
  are unsigned personal builds; Apple signing and notarization policy, the
  runtime feed poller, and desktop download and installation remain separate
  work.
