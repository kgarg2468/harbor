// Tests for scripts/prepare-source.mjs. Every test drives the real CLI as a
// child process against a real fixture Git repository in a temporary directory.
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdtemp, mkdir, readFile, readdir, realpath, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { after, before, describe, it } from "node:test";
import { promisify } from "node:util";

const run = promisify(execFile);
const here = path.dirname(fileURLToPath(import.meta.url));
const script = path.join(here, "..", "scripts", "prepare-source.mjs");

const gitEnv = {
  ...process.env,
  GIT_AUTHOR_NAME: "OPERATOR",
  GIT_AUTHOR_EMAIL: "operator@example.com",
  GIT_COMMITTER_NAME: "OPERATOR",
  GIT_COMMITTER_EMAIL: "operator@example.com",
  GIT_CONFIG_GLOBAL: "/dev/null",
  GIT_CONFIG_SYSTEM: "/dev/null",
};

async function git(cwd, ...args) {
  // A real upstream checkout's `ls-files -s` listing exceeds the 1 MiB default.
  const { stdout } = await run("git", args, { cwd, env: gitEnv, maxBuffer: 64 * 1024 * 1024 });
  return stdout.trim();
}

function sha256(text) {
  return createHash("sha256").update(text).digest("hex");
}

// Patches are written by hand so the test does not depend on git's diff output.
const PATCH_ONE = `diff --git a/hello.txt b/hello.txt
--- a/hello.txt
+++ b/hello.txt
@@ -1 +1 @@
-one
+one patched
`;
// Depends on PATCH_ONE having been applied first, which proves ordering.
const PATCH_TWO = `diff --git a/hello.txt b/hello.txt
--- a/hello.txt
+++ b/hello.txt
@@ -1 +1 @@
-one patched
+one patched twice
diff --git a/feature.txt b/feature.txt
new file mode 100644
--- /dev/null
+++ b/feature.txt
@@ -0,0 +1 @@
+feature
`;
// Applies cleanly to the pinned commit but yields different content than
// PATCH_ONE, so a run that re-reads the patch file after verification is
// observable.
const PATCH_TAMPERED = `diff --git a/hello.txt b/hello.txt
--- a/hello.txt
+++ b/hello.txt
@@ -1 +1 @@
-one
+one tampered
`;
// Expects content the pinned commit never had, so git apply must reject it.
const PATCH_CONFLICT = `diff --git a/hello.txt b/hello.txt
--- a/hello.txt
+++ b/hello.txt
@@ -1 +1 @@
-two
+two patched
`;
// Stands in for a variant-only patch: touches a file no common patch touches.
const PATCH_IDENTITY = `diff --git a/identity.txt b/identity.txt
new file mode 100644
--- /dev/null
+++ b/identity.txt
@@ -0,0 +1 @@
+variant identity
`;

let root;
let upstream;
let pinned;
let unpinnedHead;
let lockDir;
let caseCount = 0;

async function writePatch(name, text) {
  await writeFile(path.join(lockDir, name), text);
  return { path: name, sha256: sha256(text) };
}

async function writeLock(name, lock) {
  const file = path.join(lockDir, name);
  await writeFile(file, `${JSON.stringify(lock, null, 2)}\n`);
  return file;
}

async function prepare({ lock, destination, repository = upstream, env = gitEnv, cwd, variant }) {
  const args = [script, "--lock", lock, "--destination", destination, "--repository", repository];
  if (variant !== undefined) args.push("--variant", variant);
  try {
    const { stdout, stderr } = await run(process.execPath, args, { env, cwd });
    return { code: 0, stdout, stderr };
  } catch (error) {
    return { code: error.code, stdout: error.stdout, stderr: error.stderr };
  }
}

async function freshCase() {
  const dir = path.join(root, `case-${caseCount++}`);
  await mkdir(dir);
  return { dir, destination: path.join(dir, "source") };
}

async function entries(dir) {
  return (await readdir(dir)).sort();
}

async function readProvenance(destination) {
  return JSON.parse(await readFile(path.join(destination, ".git", "harbor-source.json"), "utf8"));
}

// Path -> blob id for every file in a prepared checkout, patches included.
// Blob ids are content hashes, so two independent checkouts compare directly.
async function blobsByPath(checkout) {
  await git(checkout, "add", "-A");
  const listing = await git(checkout, "ls-files", "-s");
  return new Map(
    listing
      .split("\n")
      .filter(Boolean)
      .map((line) => {
        const [meta, file] = line.split("\t");
        return [file, meta.split(" ")[1]];
      }),
  );
}

// A version 2 fixture lock: a catalog of three patches and two variants that
// share the first two. `overrides` lets a test break one aspect at a time.
async function writeVariantLock(name, patches, overrides = {}) {
  const [one, two, identity] = patches;
  return writeLock(name, {
    version: 2,
    repository: upstream,
    commit: pinned,
    patches: [
      { id: "one", ...one },
      { id: "two", ...two },
      { id: "identity", ...identity },
    ],
    variants: {
      "managed-nightly": ["one", "two"],
      reasoning: ["one", "two", "identity"],
    },
    ...overrides,
  });
}

before(async () => {
  root = await mkdtemp(path.join(tmpdir(), "prepare-source-"));
  upstream = path.join(root, "upstream");
  lockDir = path.join(root, "locks");
  await mkdir(upstream);
  await mkdir(lockDir);
  await git(upstream, "-c", "init.defaultBranch=main", "init", "-q");
  await writeFile(path.join(upstream, "hello.txt"), "one\n");
  await git(upstream, "add", "hello.txt");
  await git(upstream, "commit", "-q", "-m", "pinned");
  pinned = await git(upstream, "rev-parse", "HEAD");
  await writeFile(path.join(upstream, "hello.txt"), "newer\n");
  await git(upstream, "commit", "-q", "-am", "newer than the pin");
  unpinnedHead = await git(upstream, "rev-parse", "HEAD");
  assert.notEqual(pinned, unpinnedHead);
});

after(async () => {
  await rm(root, { recursive: true, force: true });
});

describe("prepare-source", () => {
  it("materializes the exact pinned commit, detached, without patches", async () => {
    const { destination } = await freshCase();
    const lock = await writeLock("plain.json", {
      version: 1,
      repository: "https://example.com/not-used.git",
      commit: pinned,
      patches: [],
    });
    const result = await prepare({ lock, destination });
    assert.equal(result.code, 0, result.stderr);
    assert.equal(await git(destination, "rev-parse", "HEAD"), pinned);
    await assert.rejects(git(destination, "symbolic-ref", "-q", "HEAD"), "HEAD must be detached");
    assert.equal(await readFile(path.join(destination, "hello.txt"), "utf8"), "one\n");
    assert.equal(await git(destination, "status", "--porcelain"), "");
    const provenance = JSON.parse(
      await readFile(path.join(destination, ".git", "harbor-source.json"), "utf8"),
    );
    assert.equal(provenance.commit, pinned);
    assert.equal(provenance.repository, upstream);
    assert.equal(provenance.lockRepository, "https://example.com/not-used.git");
    assert.deepEqual(provenance.patches, []);
  });

  it("applies verified patches in lock order", async () => {
    const { destination } = await freshCase();
    const one = await writePatch("0001-one.patch", PATCH_ONE);
    const two = await writePatch("0002-two.patch", PATCH_TWO);
    const lock = await writeLock("patched.json", {
      version: 1,
      repository: upstream,
      commit: pinned,
      patches: [one, two],
    });
    const result = await prepare({ lock, destination });
    assert.equal(result.code, 0, result.stderr);
    assert.equal(await git(destination, "rev-parse", "HEAD"), pinned);
    assert.equal(await readFile(path.join(destination, "hello.txt"), "utf8"), "one patched twice\n");
    assert.equal(await readFile(path.join(destination, "feature.txt"), "utf8"), "feature\n");
    const provenance = JSON.parse(
      await readFile(path.join(destination, ".git", "harbor-source.json"), "utf8"),
    );
    assert.deepEqual(provenance.patches, [one, two]);
  });

  it("rejects a patch whose checksum does not match and publishes nothing", async () => {
    const { dir, destination } = await freshCase();
    const one = await writePatch("0001-tampered.patch", PATCH_ONE);
    const lock = await writeLock("tampered.json", {
      version: 1,
      repository: upstream,
      commit: pinned,
      patches: [{ ...one, sha256: sha256("something else") }],
    });
    const result = await prepare({ lock, destination });
    assert.notEqual(result.code, 0);
    assert.match(result.stderr, /0001-tampered\.patch/);
    assert.match(result.stderr, /sha256/i);
    assert.deepEqual(await entries(dir), []);
  });

  it("rejects a conflicting patch and leaves no staging behind", async () => {
    const { dir, destination } = await freshCase();
    const one = await writePatch("0001-good.patch", PATCH_ONE);
    const bad = await writePatch("0002-conflict.patch", PATCH_CONFLICT);
    const lock = await writeLock("conflict.json", {
      version: 1,
      repository: upstream,
      commit: pinned,
      patches: [one, bad],
    });
    const result = await prepare({ lock, destination });
    assert.notEqual(result.code, 0);
    assert.match(result.stderr, /0002-conflict\.patch/);
    assert.deepEqual(await entries(dir), []);
  });

  it("refuses to touch an existing destination", async () => {
    const { dir, destination } = await freshCase();
    await mkdir(destination);
    await writeFile(path.join(destination, "keep.txt"), "mine\n");
    const lock = await writeLock("existing.json", {
      version: 1,
      repository: upstream,
      commit: pinned,
      patches: [],
    });
    const result = await prepare({ lock, destination });
    assert.notEqual(result.code, 0);
    assert.match(result.stderr, /already exists/);
    assert.deepEqual(await entries(dir), ["source"]);
    assert.deepEqual(await entries(destination), ["keep.txt"]);
    assert.equal(await readFile(path.join(destination, "keep.txt"), "utf8"), "mine\n");
  });

  it(
    "applies the verified patch bytes even if the patch file changes before git apply",
    { skip: process.platform === "win32" && "needs a POSIX shell wrapper on PATH" },
    async () => {
      const { dir, destination } = await freshCase();
      const one = await writePatch("0001-swap.patch", PATCH_ONE);
      const lock = await writeLock("swap.json", {
        version: 1,
        repository: upstream,
        commit: pinned,
        patches: [one],
      });
      // A git wrapper on PATH that rewrites the patch file the moment the tool
      // reaches `git apply`, i.e. after verification and the network fetch.
      const realGit = (await run("sh", ["-c", "command -v git"])).stdout.trim();
      const bin = path.join(dir, "bin");
      const tampered = path.join(dir, "tampered.patch");
      const marker = path.join(dir, "tampered.marker");
      await mkdir(bin);
      await writeFile(tampered, PATCH_TAMPERED);
      await writeFile(
        path.join(bin, "git"),
        `#!/bin/sh
if [ "$1" = "apply" ]; then cp "$TAMPER_SOURCE" "$TAMPER_TARGET" && : > "$TAMPER_MARKER"; fi
exec "$REAL_GIT" "$@"
`,
        { mode: 0o755 },
      );
      const env = {
        ...gitEnv,
        PATH: `${bin}${path.delimiter}${process.env.PATH}`,
        REAL_GIT: realGit,
        TAMPER_SOURCE: tampered,
        TAMPER_TARGET: path.join(lockDir, one.path),
        TAMPER_MARKER: marker,
      };
      const result = await prepare({ lock, destination, env });
      // Prove the wrapper fired and the on-disk patch really changed.
      assert.equal(await readFile(marker, "utf8"), "");
      assert.equal(await readFile(path.join(lockDir, one.path), "utf8"), PATCH_TAMPERED);
      assert.equal(result.code, 0, result.stderr);
      assert.equal(await readFile(path.join(destination, "hello.txt"), "utf8"), "one patched\n");
    },
  );

  it("serializes concurrent runs: one publishes, the loser never replaces it", async () => {
    const { dir, destination } = await freshCase();
    const one = await writePatch("0001-race.patch", PATCH_ONE);
    const withPatch = await writeLock("race-a.json", {
      version: 1,
      repository: upstream,
      commit: pinned,
      patches: [one],
    });
    const plain = await writeLock("race-b.json", {
      version: 1,
      repository: upstream,
      commit: pinned,
      patches: [],
    });
    const runs = [withPatch, plain];
    const results = await Promise.all(runs.map((lock) => prepare({ lock, destination })));
    const winners = results.filter((r) => r.code === 0);
    assert.equal(winners.length, 1, results.map((r) => r.stderr).join("\n"));
    const loser = results.find((r) => r.code !== 0);
    assert.match(loser.stderr, /another prepare-source run|already exists/);
    assert.doesNotMatch(loser.stdout ?? "", /prepared /);
    // The published checkout is entirely the winner's: its lock, its content.
    const provenance = JSON.parse(
      await readFile(path.join(destination, ".git", "harbor-source.json"), "utf8"),
    );
    const winnerLock = runs[results.indexOf(winners[0])];
    assert.equal(provenance.lock, winnerLock);
    const expected = winnerLock === withPatch ? "one patched\n" : "one\n";
    assert.equal(await readFile(path.join(destination, "hello.txt"), "utf8"), expected);
    assert.equal(await git(destination, "rev-parse", "HEAD"), pinned);
    // No staging directory and no lock left behind by either run.
    assert.deepEqual(await entries(dir), ["source"]);
  });

  it("resolves a relative --repository path against the caller's cwd", async () => {
    const { destination } = await freshCase();
    const lock = await writeLock("relative.json", {
      version: 1,
      repository: "https://example.com/not-used.git",
      commit: pinned,
      patches: [],
    });
    // `upstream` lives directly under `root`; git runs from the staging
    // directory, so an unresolved "./upstream" would not be found.
    const result = await prepare({ lock, destination, repository: "./upstream", cwd: root });
    assert.equal(result.code, 0, result.stderr);
    assert.equal(await git(destination, "rev-parse", "HEAD"), pinned);
    const provenance = JSON.parse(
      await readFile(path.join(destination, ".git", "harbor-source.json"), "utf8"),
    );
    // A child process reports its cwd as a real path (macOS symlinks /var).
    assert.equal(provenance.repository, path.join(await realpath(root), "upstream"));
  });

  it("passes a --repository URL through to git unchanged", async () => {
    const { destination } = await freshCase();
    const lock = await writeLock("url.json", {
      version: 1,
      repository: "https://example.com/not-used.git",
      commit: pinned,
      patches: [],
    });
    const url = `file://${upstream}`;
    const result = await prepare({ lock, destination, repository: url, cwd: root });
    assert.equal(result.code, 0, result.stderr);
    const provenance = JSON.parse(
      await readFile(path.join(destination, ".git", "harbor-source.json"), "utf8"),
    );
    assert.equal(provenance.repository, url);
  });

  it("fails when the pinned commit is not in the repository", async () => {
    const { dir, destination } = await freshCase();
    const lock = await writeLock("missing.json", {
      version: 1,
      repository: upstream,
      commit: "0123456789abcdef0123456789abcdef01234567",
      patches: [],
    });
    const result = await prepare({ lock, destination });
    assert.notEqual(result.code, 0);
    assert.match(result.stderr, /0123456789abcdef0123456789abcdef01234567/);
    assert.deepEqual(await entries(dir), []);
  });

  it("rejects a lock that does not pin a full commit", async () => {
    const { dir, destination } = await freshCase();
    const lock = await writeLock("short.json", {
      version: 1,
      repository: upstream,
      commit: pinned.slice(0, 12),
      patches: [],
    });
    const result = await prepare({ lock, destination });
    assert.notEqual(result.code, 0);
    assert.match(result.stderr, /commit/);
    assert.deepEqual(await entries(dir), []);
  });

  describe("patch path containment", () => {
    // Every rejection case points at a repository that does not exist, so a
    // run that reached git would fail with a fetch error instead of the
    // containment error asserted here. Every patch file carries a matching
    // checksum, so the checksum check alone would have let it through.
    const noRepository = "/nonexistent/prepare-source-never-fetched.git";

    async function expectRejected(dir, destination, lock, patchPath) {
      const result = await prepare({ lock, destination, repository: noRepository });
      assert.notEqual(result.code, 0);
      assert.match(result.stderr, /lock directory/);
      assert.ok(result.stderr.includes(patchPath), result.stderr);
      assert.doesNotMatch(result.stderr, /git |fetching/);
      assert.deepEqual(await entries(dir), []);
    }

    it("rejects a patch path that escapes the lock directory with ..", async () => {
      const { dir, destination } = await freshCase();
      // The file really exists one level above the lock directory.
      await writeFile(path.join(root, "escape.patch"), PATCH_ONE);
      const lock = await writeLock("escape.json", {
        version: 1,
        repository: upstream,
        commit: pinned,
        patches: [{ path: "../escape.patch", sha256: sha256(PATCH_ONE) }],
      });
      await expectRejected(dir, destination, lock, "../escape.patch");
    });

    it("rejects an absolute patch path", async () => {
      const { dir, destination } = await freshCase();
      const absolute = path.join(root, "absolute.patch");
      await writeFile(absolute, PATCH_ONE);
      const lock = await writeLock("absolute.json", {
        version: 1,
        repository: upstream,
        commit: pinned,
        patches: [{ path: absolute, sha256: sha256(PATCH_ONE) }],
      });
      await expectRejected(dir, destination, lock, absolute);
    });

    it("rejects a symlink inside the lock directory that points outside it", async () => {
      const { dir, destination } = await freshCase();
      const target = path.join(root, "symlink-target.patch");
      await writeFile(target, PATCH_ONE);
      await symlink(target, path.join(lockDir, "link.patch"));
      const lock = await writeLock("symlink.json", {
        version: 1,
        repository: upstream,
        commit: pinned,
        patches: [{ path: "link.patch", sha256: sha256(PATCH_ONE) }],
      });
      await expectRejected(dir, destination, lock, "link.patch");
    });

    it("accepts a patch nested in a subdirectory of the lock directory", async () => {
      const { destination } = await freshCase();
      await mkdir(path.join(lockDir, "patches", "nested"), { recursive: true });
      const nested = path.join("patches", "nested", "0001-nested.patch");
      await writeFile(path.join(lockDir, nested), PATCH_ONE);
      const lock = await writeLock("nested.json", {
        version: 1,
        repository: upstream,
        commit: pinned,
        patches: [{ path: nested, sha256: sha256(PATCH_ONE) }],
      });
      const result = await prepare({ lock, destination });
      assert.equal(result.code, 0, result.stderr);
      assert.equal(await readFile(path.join(destination, "hello.txt"), "utf8"), "one patched\n");
      const provenance = JSON.parse(
        await readFile(path.join(destination, ".git", "harbor-source.json"), "utf8"),
      );
      assert.deepEqual(provenance.patches, [{ path: nested, sha256: sha256(PATCH_ONE) }]);
    });

    it("accepts a contained directory whose name merely starts with ..", async () => {
      const { destination } = await freshCase();
      // "..patches" is an ordinary name, not a parent reference; a naive
      // startsWith("..") check would reject it.
      await mkdir(path.join(lockDir, "..patches"), { recursive: true });
      const dotted = path.join("..patches", "feature.patch");
      await writeFile(path.join(lockDir, dotted), PATCH_ONE);
      const lock = await writeLock("dotted.json", {
        version: 1,
        repository: upstream,
        commit: pinned,
        patches: [{ path: dotted, sha256: sha256(PATCH_ONE) }],
      });
      const result = await prepare({ lock, destination });
      assert.equal(result.code, 0, result.stderr);
      assert.equal(await readFile(path.join(destination, "hello.txt"), "utf8"), "one patched\n");
    });
  });

  describe("version 2 variants", () => {
    let fixturePatches;
    before(async () => {
      fixturePatches = [
        await writePatch("v2-one.patch", PATCH_ONE),
        await writePatch("v2-two.patch", PATCH_TWO),
        await writePatch("v2-identity.patch", PATCH_IDENTITY),
      ];
    });

    it("defaults to the reasoning variant and records the resolved ordered patches", async () => {
      const { destination } = await freshCase();
      const lock = await writeVariantLock("v2-default.json", fixturePatches);
      const result = await prepare({ lock, destination });
      assert.equal(result.code, 0, result.stderr);
      assert.match(result.stdout, /prepared .* variant reasoning .* with 3 patch\(es\)/);
      assert.equal(await git(destination, "rev-parse", "HEAD"), pinned);
      assert.equal(await readFile(path.join(destination, "hello.txt"), "utf8"), "one patched twice\n");
      assert.equal(await readFile(path.join(destination, "identity.txt"), "utf8"), "variant identity\n");
      const provenance = await readProvenance(destination);
      assert.equal(provenance.variant, "reasoning");
      assert.equal(provenance.commit, pinned);
      assert.deepEqual(provenance.patches, [
        { id: "one", ...fixturePatches[0] },
        { id: "two", ...fixturePatches[1] },
        { id: "identity", ...fixturePatches[2] },
      ]);
    });

    it("applies only the selected variant's patches", async () => {
      const { destination } = await freshCase();
      const lock = await writeVariantLock("v2-nightly.json", fixturePatches);
      const result = await prepare({ lock, destination, variant: "managed-nightly" });
      assert.equal(result.code, 0, result.stderr);
      assert.match(result.stdout, /variant managed-nightly .* with 2 patch\(es\)/);
      assert.doesNotMatch(result.stdout, /identity/);
      assert.equal(await readFile(path.join(destination, "hello.txt"), "utf8"), "one patched twice\n");
      assert.deepEqual(await entries(destination), [".git", "feature.txt", "hello.txt"]);
      const provenance = await readProvenance(destination);
      assert.equal(provenance.variant, "managed-nightly");
      assert.deepEqual(provenance.patches, [
        { id: "one", ...fixturePatches[0] },
        { id: "two", ...fixturePatches[1] },
      ]);
    });

    it("prepares two variants into independent destinations that differ only by the declared suffix", async () => {
      const { dir } = await freshCase();
      const lock = await writeVariantLock("v2-pair.json", fixturePatches);
      const nightly = path.join(dir, "managed-nightly");
      const reasoning = path.join(dir, "reasoning");
      const results = await Promise.all([
        prepare({ lock, destination: nightly, variant: "managed-nightly" }),
        prepare({ lock, destination: reasoning, variant: "reasoning" }),
      ]);
      for (const result of results) assert.equal(result.code, 0, result.stderr);
      assert.deepEqual(await entries(dir), ["managed-nightly", "reasoning"]);

      const nightlyBlobs = await blobsByPath(nightly);
      const reasoningBlobs = await blobsByPath(reasoning);
      // Every file the common patches produce is byte-identical in both trees.
      for (const [file, blob] of nightlyBlobs) {
        assert.equal(reasoningBlobs.get(file), blob, `${file} differs between variants`);
      }
      const extra = [...reasoningBlobs.keys()].filter((file) => !nightlyBlobs.has(file));
      assert.deepEqual(extra, ["identity.txt"]);

      const nightlyProvenance = await readProvenance(nightly);
      const reasoningProvenance = await readProvenance(reasoning);
      assert.equal(nightlyProvenance.commit, reasoningProvenance.commit);
      assert.deepEqual(reasoningProvenance.patches.slice(0, 2), nightlyProvenance.patches);
      assert.deepEqual(
        reasoningProvenance.patches.slice(2).map((patch) => patch.id),
        ["identity"],
      );
    });

    describe("rejections before any filesystem work", () => {
      // Every case points at a repository that does not exist, so a run that
      // got as far as git would fail with a fetch error instead. The case
      // directory must stay empty: no destination, no staging, no lock.
      const noRepository = "/nonexistent/prepare-source-never-fetched.git";

      async function expectRejected({ lock, variant, pattern }) {
        const { dir, destination } = await freshCase();
        const result = await prepare({ lock, destination, repository: noRepository, variant });
        assert.notEqual(result.code, 0);
        assert.match(result.stderr, pattern);
        assert.doesNotMatch(result.stderr, /git |fetching/);
        assert.deepEqual(await entries(dir), []);
      }

      it("rejects an unknown variant and names the known ones", async () => {
        const lock = await writeVariantLock("v2-unknown-variant.json", fixturePatches);
        await expectRejected({
          lock,
          variant: "stock",
          pattern: /unknown variant stock; the lock defines: managed-nightly, reasoning/,
        });
      });

      it("rejects --variant against a version 1 lock", async () => {
        const one = fixturePatches[0];
        const lock = await writeLock("v1-with-variant.json", {
          version: 1,
          repository: upstream,
          commit: pinned,
          patches: [one],
        });
        await expectRejected({ lock, variant: "reasoning", pattern: /version 1 lock/ });
      });

      it("rejects a duplicate patch id in the catalog", async () => {
        const [one, two, identity] = fixturePatches;
        const lock = await writeVariantLock("v2-dup-id.json", fixturePatches, {
          patches: [
            { id: "one", ...one },
            { id: "one", ...two },
            { id: "identity", ...identity },
          ],
        });
        await expectRejected({ lock, pattern: /duplicate patch id one/ });
      });

      it("rejects a catalog entry without an id", async () => {
        const [one, two, identity] = fixturePatches;
        const lock = await writeVariantLock("v2-no-id.json", fixturePatches, {
          patches: [{ id: "one", ...one }, { ...two }, { id: "identity", ...identity }],
        });
        await expectRejected({ lock, pattern: /patches\[1\]\.id/ });
      });

      it("rejects a variant that references an unknown patch id", async () => {
        const lock = await writeVariantLock("v2-bad-ref.json", fixturePatches, {
          variants: { "managed-nightly": ["one", "two"], reasoning: ["one", "two", "three"] },
        });
        await expectRejected({
          lock,
          pattern: /variants\.reasoning\[2\] references unknown patch id three/,
        });
      });

      it("rejects a variant that lists a patch id twice", async () => {
        const lock = await writeVariantLock("v2-dup-ref.json", fixturePatches, {
          variants: { "managed-nightly": ["one", "one"], reasoning: ["one", "two", "identity"] },
        });
        await expectRejected({
          lock,
          variant: "managed-nightly",
          pattern: /variants\.managed-nightly lists patch id one twice/,
        });
      });

      it("rejects a variant whose ids are out of catalog order", async () => {
        const lock = await writeVariantLock("v2-order.json", fixturePatches, {
          variants: { "managed-nightly": ["one", "two"], reasoning: ["one", "identity", "two"] },
        });
        await expectRejected({
          lock,
          pattern: /variants\.reasoning\[2\] \(two\) is out of catalog order/,
        });
      });

      it("rejects a lock whose variants field is not an object", async () => {
        const lock = await writeVariantLock("v2-variants-array.json", fixturePatches, {
          variants: [["one", "two"]],
        });
        await expectRejected({ lock, pattern: /variants must be an object/ });
      });

      it("rejects a checksum mismatch on a patch the selected variant applies", async () => {
        const [one, two, identity] = fixturePatches;
        const lock = await writeVariantLock("v2-digest.json", fixturePatches, {
          patches: [
            { id: "one", ...one },
            { id: "two", ...two },
            { id: "identity", ...identity, sha256: sha256("something else") },
          ],
        });
        await expectRejected({
          lock,
          variant: "reasoning",
          pattern: /v2-identity\.patch: sha256 mismatch/,
        });
      });

      it("rejects a catalog path that escapes the lock directory", async () => {
        const [one, two] = fixturePatches;
        await writeFile(path.join(root, "v2-escape.patch"), PATCH_IDENTITY);
        const lock = await writeVariantLock("v2-escape.json", fixturePatches, {
          patches: [
            { id: "one", ...one },
            { id: "two", ...two },
            { id: "identity", path: "../v2-escape.patch", sha256: sha256(PATCH_IDENTITY) },
          ],
        });
        await expectRejected({ lock, pattern: /\.\.\/v2-escape\.patch: path resolves outside the lock directory/ });
      });
    });
  });
});

// The component's real lock, checked statically: every catalog file is present
// with its recorded checksum, and the two variants differ by exactly the
// Reasoning identity patch, which touches only identity files.
describe("source.lock.json", () => {
  const componentDir = path.join(here, "..");
  const lockFile = path.join(componentDir, "source.lock.json");
  const COMMON_RUNTIME_FILES = [
    "apps/desktop/src/backend/DesktopBackendConfiguration.test.ts",
    "apps/desktop/src/backend/DesktopBackendConfiguration.ts",
    "apps/server/src/os-jank.test.ts",
    "apps/server/src/os-jank.ts",
  ];
  const IDENTITY_FILES = [
    "apps/desktop/src/app/DesktopClerk.test.ts",
    "apps/desktop/src/app/DesktopEnvironment.test.ts",
    "apps/desktop/src/app/DesktopEnvironment.ts",
    "apps/desktop/src/electron/ElectronProtocol.test.ts",
    "apps/desktop/src/electron/ElectronProtocol.ts",
    "scripts/build-desktop-artifact.test.ts",
    "scripts/build-desktop-artifact.ts",
    "scripts/update-reasoning-mac-app.sh",
  ];

  function patchedFiles(patchText) {
    return [...patchText.matchAll(/^diff --git a\/(\S+) b\//gm)].map((match) => match[1]).sort();
  }

  it("is a version 2 lock whose catalog checksums match the patch files", async () => {
    const lock = JSON.parse(await readFile(lockFile, "utf8"));
    assert.equal(lock.version, 2);
    assert.match(lock.commit, /^[0-9a-f]{40}$/);
    for (const patch of lock.patches) {
      const content = await readFile(path.join(componentDir, patch.path));
      assert.equal(
        createHash("sha256").update(content).digest("hex"),
        patch.sha256,
        `${patch.id} (${patch.path}) checksum`,
      );
    }
  });

  it("defines managed-nightly as reasoning without the identity patch", async () => {
    const lock = JSON.parse(await readFile(lockFile, "utf8"));
    assert.deepEqual(Object.keys(lock.variants).sort(), ["managed-nightly", "reasoning"]);
    assert.deepEqual(lock.variants.reasoning, [...lock.variants["managed-nightly"], "reasoning-identity"]);
    assert.ok(lock.variants["managed-nightly"].includes("reasoning-full"));
    assert.ok(lock.variants["managed-nightly"].includes("desktop-runtime-common"));
  });

  it("keeps the packaged runtime fix common and the Reasoning identity separate", async () => {
    const lock = JSON.parse(await readFile(lockFile, "utf8"));
    const byId = new Map(lock.patches.map((patch) => [patch.id, patch]));
    const common = await readFile(path.join(componentDir, byId.get("desktop-runtime-common").path), "utf8");
    const identity = await readFile(path.join(componentDir, byId.get("reasoning-identity").path), "utf8");
    assert.deepEqual(patchedFiles(common), COMMON_RUNTIME_FILES);
    assert.deepEqual(patchedFiles(identity), IDENTITY_FILES);
    assert.match(common, /T3CODE_SKIP_LOGIN_SHELL/);
    assert.doesNotMatch(common, /t3code-reasoning|com\.t3tools\.t3code\.reasoning|T3 Code \(Reasoning\)/);
    // The identity patch also carries the disabled official feed, so the
    // managed Nightly tree keeps upstream's feed resolver until a managed
    // release patch owns the feed explicitly.
    assert.match(identity, /^-export const resolveGitHubPublishConfig/m);
  });

  // Opt-in: materialize both real variants from a local clone that contains
  // the pinned commit, then prove the trees differ only in the identity files.
  //   T3_REASONING_UPSTREAM_REPOSITORY=/path/to/clone node --test ...
  const localUpstream = process.env.T3_REASONING_UPSTREAM_REPOSITORY;
  it(
    "materializes both real variants from a local clone and differs only in identity files",
    { skip: !localUpstream && "set T3_REASONING_UPSTREAM_REPOSITORY to a clone with the pinned commit" },
    async () => {
      const dir = await mkdtemp(path.join(tmpdir(), "prepare-source-variants-"));
      try {
        const nightly = path.join(dir, "managed-nightly");
        const reasoning = path.join(dir, "reasoning");
        for (const [destination, variant] of [
          [nightly, "managed-nightly"],
          [reasoning, "reasoning"],
        ]) {
          const result = await prepare({ lock: lockFile, destination, repository: localUpstream, variant });
          assert.equal(result.code, 0, result.stderr);
        }
        const lock = JSON.parse(await readFile(lockFile, "utf8"));
        const nightlyProvenance = await readProvenance(nightly);
        const reasoningProvenance = await readProvenance(reasoning);
        assert.equal(nightlyProvenance.commit, lock.commit);
        assert.deepEqual(
          nightlyProvenance.patches.map((patch) => patch.id),
          lock.variants["managed-nightly"],
        );
        assert.deepEqual(
          reasoningProvenance.patches.map((patch) => patch.id),
          lock.variants.reasoning,
        );

        const nightlyBlobs = await blobsByPath(nightly);
        const reasoningBlobs = await blobsByPath(reasoning);
        const differing = [];
        for (const [file, blob] of reasoningBlobs) {
          if (nightlyBlobs.get(file) !== blob) differing.push(file);
        }
        for (const file of nightlyBlobs.keys()) {
          if (!reasoningBlobs.has(file)) differing.push(file);
        }
        assert.deepEqual(differing.sort(), IDENTITY_FILES);
        for (const file of COMMON_RUNTIME_FILES) {
          assert.ok(nightlyBlobs.has(file), `${file} missing from managed-nightly`);
        }
        // Managed Nightly keeps upstream's packaged identity.
        const protocol = await readFile(path.join(nightly, IDENTITY_FILES[4]), "utf8");
        assert.match(protocol, /DESKTOP_PRODUCTION_SCHEME = "t3code";/);
        const reasoningProtocol = await readFile(path.join(reasoning, IDENTITY_FILES[4]), "utf8");
        assert.match(reasoningProtocol, /DESKTOP_PRODUCTION_SCHEME = "t3code-reasoning";/);
      } finally {
        await rm(dir, { recursive: true, force: true });
      }
    },
  );
});
