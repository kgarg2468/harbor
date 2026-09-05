# Nightly port of the Reasoning feature set

This document records where the Reasoning patch set came from, what it
contains, how it was exported, and how to move it to the next Nightly. The
product contract is in `design.md`; this file is the provenance and
maintenance record for the current pin.

## Current pin

| Item | Value |
| --- | --- |
| Upstream repository | `https://github.com/pingdotgg/t3code.git` |
| Upstream commit | `9cb40178a53cca279c67a9079afab3cddf6b6ddb` |
| Upstream tag at that commit | `v0.0.39-nightly.20260905.1284` |
| Patch `reasoning-full` | `patches/0001-reasoning.patch` (34 files) |
| Patch `desktop-runtime-common` | `patches/0002-desktop-runtime-common.patch` (4 files) |
| Patch `reasoning-identity` | `patches/0002-reasoning-identity.patch` (8 files) |
| Upstream license | `UPSTREAM-LICENSE` (MIT, T3 Tools Inc., copied unchanged) |

These three patches together change exactly the 46 files that the ported
feature commit changes against the upstream commit. They were originally
exported as two patches; the desktop patch was split by whole file on
2026-09-05 into the common runtime fix and the Reasoning identity, so the
`managed-nightly` variant in `build-variants.md` can leave the identity out.
The tag was confirmed on the upstream remote at the pinned SHA on 2026-09-05.

## Provenance

The feature work was written by Krish Garg in a private fork of T3 Code, on
the branch `local/reasoning-mac-app`. The upstream history it was built on and
the two revisions that matter for this port are:

- Original upstream base: `31c1c5996f88e3acf1566adc11c9b51ac7561554`
  (upstream `feat(mobile): add video playback with native iOS controls`,
  2026-08-31). Harbor's previous `source.lock.json` pinned this commit with an
  empty patch list.
- Old feature baseline: `6bb0110001d498c5adbc3321d55f134eff8a072f`
  (`fix(server): request detailed Codex reasoning summaries`, 2026-08-31).
  This is the last commit on the private branch before the shared-environment
  sync work began. It carries the same 46-file surface as the port, except
  that the old numbered migration `044_ProjectionThreadMessagesChannel` was
  replaced by `ReasoningSchema.ts` (see the migration section below).
- Port commit: `f3e26496cc51495a8ab59639748adf9a1c75dc92`
  (`Port existing reasoning and desktop identity to nightly 20260905`),
  authored on 2026-09-05 in a working clone with the pinned upstream commit
  as its only parent. That clone is not a Harbor artifact. The patch files
  are the artifact, and the port commit is reproduced from them by
  `prepare-source`.

### Excluded on purpose

The private branch continued past the old baseline with 14 commits
(`6bb0110..6c500066e`, 17 files, about 9,800 added lines) that add a
shared-environment sync installer under `scripts/reasoning-sync/`, plus
further uncommitted edits to the same files in that checkout. That installer
was never finished or reviewed. None of it is in either patch. The
shared-environment, queued-update, and fork work described in `design.md`
starts from this pin, not from that code.

The upstream `LICENSE` file is not changed by the port. Its bytes are carried
here as `UPSTREAM-LICENSE` so the license travels with the patches.

## Scope exception for the initial import

`design.md` asks for implementation PRs of one observable concern, generally
under 600 changed lines. This import is an explicit, one-time exception: it
packages an existing, already implemented and reviewed feature baseline of
about 4,300 changed lines as two patches so the component starts from the
same code that has been running as the private Reasoning app. Changes after
this pin follow the normal size guidance as new, small patches.

## What the patches contain

### `0001-reasoning.patch`

Everything outside the desktop identity surface:

- Server: provider runtime ingestion of reasoning deltas, projection of
  reasoning into thread messages, checkpoint and provider command reactors
  that ignore reasoning for turn settlement, the Claude adapter asking for
  summarized thinking, the Codex runtime asking for detailed summaries, and
  the persistence layer described below.
- Contracts and client runtime: the reasoning message channel on the message
  shape, and a thread reducer that carries that channel and ignores reasoning
  messages when tracking the latest assistant message.
- Web: the timeline logic and component that render each reasoning burst as a
  collapsible row under the turn's tool group.
- Mobile: the thread activity helper skips reasoning so activity state is
  unchanged there. The mobile app does not render reasoning yet.
- Docs: `docs/user/reasoning.md` and glossary and provider notes.

### `0002-desktop-runtime-common.patch`

The functional packaged-startup fix, applied to both variants:

- `apps/desktop/src/backend/DesktopBackendConfiguration.ts` and its test: the
  packaged primary backend child is started with `T3CODE_SKIP_LOGIN_SHELL=1`;
  development and the WSL backend keep stock hydration.
- `apps/server/src/os-jank.ts` and its test: with that signal set, PATH
  hydration keeps the inherited PATH and only appends `launchctl` entries on
  macOS, with injectable readers so tests prove the login shell never runs.

### `0002-reasoning-identity.patch`

The remaining `apps/desktop/**` and `scripts/**` files, applied to the
`reasoning` variant only:

- Every packaged (non-development) identity surface belongs to the Reasoning
  app so it installs beside the official app without colliding
  (`DesktopEnvironment.ts`, `ElectronProtocol.ts`, `DesktopClerk.test.ts`,
  and their tests).
- Build tooling: `scripts/build-desktop-artifact.ts` and its test carry the
  Reasoning bundle id, product name, artifact name, URL scheme, Linux names,
  staged package name, and the removal of the official update feed.
- The manual macOS updater script `scripts/update-reasoning-mac-app.sh`.

Development builds keep the stock identity in every patch. The
`managed-nightly` variant receives neither of the identity changes nor the
feed removal, so it keeps upstream's packaged identity and upstream's
`resolveGitHubPublishConfig`; see `build-variants.md` for why that tree is
not yet deployable.

## Migration identity repair

Earlier Reasoning builds shipped the `channel` column on
`projection_thread_messages` as numbered migration 44,
`ProjectionThreadMessagesChannel`. Upstream later assigned id 44 to
`ClearAutomaticProjectModelDefaults`. A database migrated by the old build
therefore records id 44 as already applied, and a stock migrator would skip
upstream's 44 forever.

The port moves the Reasoning schema out of the numbered manifest into
`apps/server/src/persistence/ReasoningSchema.ts`, so it cannot collide with
whichever id upstream adds next. On a full migration run:

1. `repairLegacyReasoningMigration` looks at the record for id 44. If it
   carries exactly the legacy name, it runs upstream's 44 body and renames the
   record inside one transaction. Any other unexpected name at id 44 is
   reported as a migrator `BadState` error rather than guessed at. The channel
   column and the rows written under it are left untouched.
2. The upstream manifest runs as usual.
3. `ensureReasoningSchema` adds the `channel` column if it is missing. It is
   idempotent and cheap.

Partial runs that stop at a requested upstream migration skip both steps so
upstream migration tests observe the stock schema.

## Separate desktop identity

The Reasoning app must run next to the official app on the same machine
without touching its data, callbacks, or updater. Packaged builds use:

| Surface | Reasoning value |
| --- | --- |
| Bundle and app user model id | `com.t3tools.t3code.reasoning` |
| Display and product name | `T3 Code (Reasoning)` |
| URL scheme | `t3code-reasoning` only; `t3code` and `t3code-dev` are never claimed |
| State directory | `~/.t3-reasoning` unless a non-empty `T3CODE_HOME` is set |
| Electron user data directory | `t3code-reasoning`, with no legacy fallback to the stock directory |
| Linux executable, desktop entry, WM class | `t3code-reasoning` |
| Artifact name | `T3-Code-Reasoning-<version>-<arch>.<ext>` |

The packaged backend child is started with `T3CODE_SKIP_LOGIN_SHELL=1`. With
that set, PATH hydration keeps the inherited PATH and only appends
`launchctl` entries on macOS, so a user's shell rc files cannot block the
backend before it binds its port. Development keeps stock hydration.

## Updater feed intentionally disabled

The Reasoning build is private. `build-desktop-artifact.ts` no longer reads
`T3CODE_DESKTOP_UPDATE_REPOSITORY` or `GITHUB_REPOSITORY`, so no GitHub
publish configuration and no `app-update.yml` ever land in the package, even
in CI-like environments. The opt-in mock update server remains for local
update testing only. The manual updater script refuses to install any bundle
that contains `app-update.yml`.

This is deliberate: the stock auto-updater must never replace the Reasoning
app with a plain official build. The queued, per-machine update flow in
`design.md` is future work and is not implemented by this pin.

## Manual updater script scope

`scripts/update-reasoning-mac-app.sh` is carried in the desktop patch with
its executable mode. It is a manual, operator-run tool for macOS arm64 that
builds the unsigned ZIP, verifies the bundle identity, and swaps it into
`/Applications/T3 Code (Reasoning).app` with rollback. It never modifies the
official app.

Its default sync mode expects the private branch layout: a checked-out
`local/reasoning-mac-app` branch and the remotes `origin` and `upstream`.
A `prepare-source` checkout has neither. It is a detached checkout at the
pinned commit with the patches applied as uncommitted changes, so the sync
mode does not apply. Use `--skip-sync` to build a prepared checkout as-is.
Harbor does not invoke this script, and nothing in this component installs,
updates, or launches an app. Moving to a newer Nightly is done by changing
the source lock, not by the script.

## How the patches were exported

From the working clone, with `UP` the upstream commit and `PORT` the port
commit:

```sh
GITOPTS=(-c core.quotePath=true -c diff.noprefix=false -c diff.mnemonicPrefix=false \
  -c diff.renames=false -c diff.algorithm=myers -c color.ui=never)
git "${GITOPTS[@]}" diff --no-color --no-ext-diff --no-renames --binary --full-index "$UP..$PORT" \
  -- . ':(exclude)apps/desktop' ':(exclude)apps/server/src/os-jank.ts' \
     ':(exclude)apps/server/src/os-jank.test.ts' ':(exclude)scripts' \
  > t3-reasoning/patches/0001-reasoning.patch
git "${GITOPTS[@]}" diff --no-color --no-ext-diff --no-renames --binary --full-index "$UP..$PORT" \
  -- apps/desktop/src/backend/DesktopBackendConfiguration.ts \
     apps/desktop/src/backend/DesktopBackendConfiguration.test.ts \
     apps/server/src/os-jank.ts apps/server/src/os-jank.test.ts \
  > t3-reasoning/patches/0002-desktop-runtime-common.patch
git "${GITOPTS[@]}" diff --no-color --no-ext-diff --no-renames --binary --full-index "$UP..$PORT" \
  -- apps/desktop scripts \
     ':(exclude)apps/desktop/src/backend/DesktopBackendConfiguration.ts' \
     ':(exclude)apps/desktop/src/backend/DesktopBackendConfiguration.test.ts' \
  > t3-reasoning/patches/0002-reasoning-identity.patch
shasum -a 256 t3-reasoning/patches/*.patch
```

`--full-index` and `--binary` make the patches self-describing and let
`git apply` check blob ids. The SHA-256 of each file goes into the
`patches` catalog of `source.lock.json`.

The two `0002` files in this component were not produced by those commands
but by partitioning the original single desktop patch into whole `diff --git`
sections, byte for byte, so that the section bytes are unchanged from the
reviewed original (SHA-256
`cc839a3d8682e71340e848a10116e7ab1dd530f3e10c3c424d711eb889bcbd09`). The
commands above produce the same file sets; re-export with them on the next
port.

## Moving to the next Nightly

Updates are not automatic. Nothing discovers new Nightlies. To port:

1. Pick the new upstream Nightly tag and resolve it to its full commit SHA.
2. Change `commit` in `source.lock.json` to that SHA and run
   `prepare-source` for each variant into a fresh destination. If every patch
   applies in both variants, run the focused upstream checks in those
   checkouts and stop here.
3. If a patch does not apply, make a working clone at the new commit, apply
   the `reasoning` variant's patches with `git apply --3way`, resolve the
   conflicts, and commit the result as a single port commit on top of the new
   upstream commit.
4. Re-export the three patches with the commands above, update their
   `sha256` values in the `patches` catalog of `source.lock.json`, and update
   the pin table in this document.
5. Run `prepare-source --variant reasoning` again and confirm the prepared
   tree matches the new port commit: stage everything in the checkout,
   compare `git write-tree` against the port commit's tree id. Prepare
   `managed-nightly` too and confirm its tree differs from the Reasoning tree
   in exactly the identity patch's files (the opt-in test in the README does
   this).
6. Run the component checks listed in the README.

Keep the split rule when re-exporting: the four packaged-runtime files
(`apps/desktop/src/backend/DesktopBackendConfiguration.ts` and its test,
`apps/server/src/os-jank.ts` and its test) go to the common runtime patch;
the rest of `apps/desktop/**` and `scripts/**` go to the Reasoning identity
patch; everything else goes to the reasoning patch. A new file that belongs
to none of the rules, or a runtime file that gains an identity hunk, is a
signal to revisit the split, not to guess. The lock test asserts the file
sets of both `0002` patches.

## Verification evidence for this pin

Recorded on 2026-09-05. The three sources are kept separate because they
were produced by different runs.

Packaging run in Harbor (this document's author):

- `prepare-source` with the lock above, fetching from a local read-only clone
  into a new temporary destination, applied both original patches. Staging
  every file in the result gave tree id
  `6e3be0cb047c695ffc7fdec4fd0fdb6ba8187bd2`, the same tree id as the port
  commit. The updater script was checked in at mode `100755`.
- The component's `node --test` suite and `markdownlint` pass (see README).

Split proof, recorded on 2026-09-05 in a throwaway clone at the pinned
commit (see `build-variants.md` for the variant trees):

- `0001-reasoning.patch` plus the two split `0002` patches, applied in either
  order, staged to the same tree id `6e3be0cb047c695ffc7fdec4fd0fdb6ba8187bd2`
  as `0001` plus the original `0002-desktop-identity.patch`.
- The bytes of the two split files concatenated in original section order
  equal the original patch file exactly.

Main session, separately verified in the ported checkout, as reported to the
packaging run: the server test suite (113 tests), the web timeline logic
suite (110 tests), typecheck across five packages, a built server, and a
two-client smoke run with 10 checks against a real server.

Earlier implementation report, as reported to the packaging run: 598 focused
tests passing across the touched suites, including desktop (57), os-jank (7),
and desktop artifact (68).

Full upstream test runs and CI changes were out of scope for the packaging
run. No live installation, update, or activation has occurred.
