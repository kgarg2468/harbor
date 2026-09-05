# Build variants

The component materializes two source trees from one upstream pin and one
patch catalog: a managed Nightly and the Reasoning app. This document records
the variant model in `source.lock.json`, what each variant contains today, the
tree-level proof for the current pin, and what is still missing before either
tree is a deployable release. The release shape it serves is described in
`design.md`; the patch provenance is in `nightly-port.md`.

## Why two variants

Both desktop apps talk to one shared server. Their wire contracts, reducers,
server projection, persistence, and provider ingestion must therefore be the
same code. Only the desktop identity differs: the managed Nightly replaces the
stock Nightly install and keeps its bundle id, name, URL schemes, and state
directory; the Reasoning app installs beside it under its own identity.

That is why the whole `reasoning-full` patch is applied to **both** variants.
Splitting the functional patch by feature would risk two clients decoding the
same snapshots differently. The variants differ only by the identity patch.

## Lock format, version 2

```json
{
  "version": 2,
  "repository": "https://github.com/pingdotgg/t3code.git",
  "commit": "<40-hex upstream pin>",
  "patches": [
    { "id": "reasoning-full", "path": "patches/0001-reasoning.patch", "sha256": "..." },
    { "id": "desktop-runtime-common", "path": "patches/0002-desktop-runtime-common.patch", "sha256": "..." },
    { "id": "update-admission", "path": "patches/0003-update-admission.patch", "sha256": "..." },
    { "id": "queued-update", "path": "patches/0004-queued-update.patch", "sha256": "..." },
    { "id": "update-activity", "path": "patches/0005-update-activity.patch", "sha256": "..." },
    { "id": "reasoning-identity", "path": "patches/0002-reasoning-identity.patch", "sha256": "..." }
  ],
  "variants": {
    "managed-nightly": ["reasoning-full", "desktop-runtime-common", "update-admission", "queued-update", "update-activity"],
    "reasoning": ["reasoning-full", "desktop-runtime-common", "update-admission", "queued-update", "update-activity", "reasoning-identity"]
  }
}
```

Rules the preparer enforces before it fetches or creates anything:

- `patches` is the catalog. Every entry has a non-empty unique `id`, a unique
  `path` inside the lock directory, and a 64-hex `sha256`. The catalog order
  is the canonical application order.
- `variants` is an object. Each value is an array of catalog ids with no
  repeats, every id must exist, and the ids must appear in catalog order. Two
  variants can therefore differ only by which entries they include, never by
  reordering shared entries.
- `--variant <name>` selects a variant; the default is `reasoning`. An
  unknown name is rejected with the list of defined variants.
- Only the selected variant's patches are byte-verified by a run. The
  component test suite separately verifies every catalog entry against its
  file, so an unused or broken entry still fails CI.
- Version `1` locks (flat `patches` list, no `variants`) still work exactly as
  before. `--variant` with a version `1` lock is an error.

The rest of the run is unchanged: the verified bytes are held in memory and
piped to `git apply`, the checkout is staged next to the destination under an
exclusive `<destination>.lock`, and it is renamed into place only after every
patch applies. Provenance in `.git/harbor-source.json` records the `variant`
and the resolved ordered `patches` as `{ "id", "path", "sha256" }`.

Prepare each variant into its own destination:

```sh
node t3-reasoning/scripts/prepare-source.mjs --variant managed-nightly \
  --destination /path/to/managed-nightly
node t3-reasoning/scripts/prepare-source.mjs --variant reasoning \
  --destination /path/to/reasoning
```

Never build both variants from one checkout. The desktop builder writes its
output into the source tree, so a second variant packaged from the same tree
can pick up the first variant's bundles.

## What each variant contains at this pin

| Patch id | `managed-nightly` | `reasoning` | Content |
| --- | --- | --- | --- |
| `reasoning-full` | yes | yes | reasoning channel: server, contracts, client runtime, web timeline, mobile, docs |
| `desktop-runtime-common` | yes | yes | packaged backend `T3CODE_SKIP_LOGIN_SHELL` / `os-jank` PATH fix |
| `update-admission` | yes | yes | maintenance admission primitive |
| `queued-update` | yes | yes | durable queued update controller |
| `update-activity` | yes | yes | activity ownership and required-consumer fanout helpers |
| `reasoning-identity` | no | yes | Reasoning bundle id, name, scheme, state home, artifact name, disabled official feed, manual macOS updater |

The `managed-nightly` tree keeps upstream's packaged identity: bundle id
`com.t3tools.t3code`, product name `T3 Code (Nightly)` for a nightly version,
artifact template `T3-Code-${version}-${arch}.${ext}`, schemes `t3code` and
`t3code-dev`, user-data name `t3code`, and the `~/.t3` profile. The
`reasoning` tree is byte-identical to the previous flat lock's result.

## Tree proof before the activity helper patch

Recorded on 2026-09-05 from throwaway checkouts of upstream
`9cb40178a53cca279c67a9079afab3cddf6b6ddb`, each patch applied with
`git apply` and the result staged with `git add -A && git write-tree`:

| Sequence | Tree id |
| --- | --- |
| `0001` + original `0002-desktop-identity` | `6e3be0cb047c695ffc7fdec4fd0fdb6ba8187bd2` |
| `0001` + original `0002` + `0003` + `0004` (previous flat lock) | `fae2c1a33c3d9a56522766c3971c6dae4c949203` |
| `reasoning` variant before `0005` (identity last) | `fae2c1a33c3d9a56522766c3971c6dae4c949203` |
| `managed-nightly` variant before `0005` | `b31b361eb941d8c6142df2d7f96f45216596ae96` |

So the split preserves the Reasoning tree exactly, and the
two variants differ in exactly the eight files of `reasoning-identity`: the
seven identity source and test files plus `scripts/update-reasoning-mac-app.sh`,
which only the Reasoning tree has. Every other file, including the four
common runtime files, has the same blob id in both trees. The opt-in test in
`tests/prepare-source.test.mjs` re-checks this file-level claim against a
local clone; the tree ids above are a one-time record because `0004` is
expected to change under separate review.

After applying the common `0005` activity helper patch, the managed Nightly tree
is `ef85662ecedc9e4fc0f8e771097ec39d44170e78` and the Reasoning tree is
`1008db188917e3e197b89a41766c3824e91476df`. The real-variant materialization test
continues to prove that only the eight identity files differ.

## Not ready for deployment

Both trees materialize, but neither is a release yet. The gaps are outside
this component's preparer and are tracked here so the lock is not mistaken
for a deployable configuration.

- **Reasoning presentation is not gated.** `reasoning-full` is applied to
  the managed Nightly, so its renderer currently shows the Reasoning timeline
  just like the Reasoning app. The planned fix is a
  compile-time presentation switch in a common source patch, as described in
  the managed release design; it does not exist yet. Do not describe the
  current managed Nightly UI as stock.
- **Feed ownership is upstream's.** The managed Nightly keeps upstream's
  `resolveGitHubPublishConfig`, which reads `T3CODE_DESKTOP_UPDATE_REPOSITORY`
  or ambient `GITHUB_REPOSITORY`. A package built from this tree in a
  CI-like environment would carry the official update feed and could later
  be replaced by a stock build. A managed release patch must make the feed an
  explicit managed repository, or omit it, before any managed Nightly is
  installed. The Reasoning tree already omits the feed unless mock updates are
  requested.
- **No release scripts.** Version stamping, artifact builders, manifest,
  installer, and the managed service identity described in the design are not
  part of this component yet.

## Adding a patch or a variant

1. Add the patch file under `patches/` and a catalog entry with a new unique
   id at the position where it must apply. Common patches go before
   `reasoning-identity`; a future identity-only patch goes after it.
2. Add the id to every variant that should apply it, keeping each list in
   catalog order. The preparer rejects a misordered list.
3. Update the lock's `sha256`, run the component tests, and prepare both
   variants into fresh destinations to confirm every patch applies.
4. Record the new tree ids and the file-level difference in this document.
