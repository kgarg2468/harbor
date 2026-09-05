// Tests for scripts/prepare-source.mjs. Every test drives the real CLI as a
// child process against a real fixture Git repository in a temporary directory.
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdtemp, mkdir, readFile, readdir, realpath, rm, writeFile } from "node:fs/promises";
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
  const { stdout } = await run("git", args, { cwd, env: gitEnv });
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

async function prepare({ lock, destination, repository = upstream, env = gitEnv, cwd }) {
  const args = [script, "--lock", lock, "--destination", destination, "--repository", repository];
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
});
