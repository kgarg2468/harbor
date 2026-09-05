// Tests for scripts/resolve-managed-release.mjs and
// scripts/write-managed-release-manifest.mjs. Every case runs against a small
// synthetic lock, patch files, and artifact files in a temporary directory;
// the CLI cases drive the real entry points as child processes. Nothing here
// touches the network, a real upstream checkout, or a real archive.
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { createHash } from "node:crypto";
import { link, lstat, mkdtemp, mkdir, readFile, readdir, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { after, before, describe, it } from "node:test";
import { promisify } from "node:util";

import {
  MANAGED_RELEASE_RE,
  PRESENTATION_VARIANTS,
  PUBLIC_CONFIG_KEYS,
  ReleaseError,
  canonicalJson,
  compareExactVersions,
  computePublicConfigFingerprint,
  parseManagedReleaseVersion,
  readVerifiedLock,
  resolveManagedRelease,
  validateLock,
} from "../scripts/resolve-managed-release.mjs";
import {
  EXPECTED_ARTIFACTS,
  MANIFEST_FILE,
  SUMS_FILE,
  buildManifest,
  formatSha256Sums,
  hashFile,
  validateInventory,
  writeManagedReleaseManifest,
} from "../scripts/write-managed-release-manifest.mjs";

const run = promisify(execFile);
const here = path.dirname(fileURLToPath(import.meta.url));
const resolveScript = path.join(here, "..", "scripts", "resolve-managed-release.mjs");
const manifestScript = path.join(here, "..", "scripts", "write-managed-release-manifest.mjs");

const UPSTREAM_COMMIT = "9cb40178a53cca279c67a9079afab3cddf6b6ddb";
const BUILDER_REVISION = "0123456789abcdef0123456789abcdef01234567";
const UPSTREAM_VERSION = "0.0.39-nightly.20260905.1284";
// Obviously synthetic public values. The output must never contain them.
const PUBLIC_CONFIG = {
  T3CODE_RELAY_URL: "https://relay.fixture.invalid",
  T3CODE_CLERK_PUBLISHABLE_KEY: "pk_test_FIXTURE_PUBLISHABLE_VALUE",
  T3CODE_CLERK_JWT_TEMPLATE: "fixture-jwt-template",
  T3CODE_CLERK_CLI_OAUTH_CLIENT_ID: "fixture-cli-oauth-client",
};
const PATCH_CONTENT = {
  "reasoning-full": "--- a/one\n+++ b/one\n@@ -1 +1 @@\n-one\n+one patched\n",
  "desktop-runtime-common": "--- a/two\n+++ b/two\n@@ -1 +1 @@\n-two\n+two patched\n",
  "reasoning-identity": "--- a/identity\n+++ b/identity\n@@ -1 +1 @@\n-stock\n+reasoning\n",
};

function sha256(text) {
  return createHash("sha256").update(text).digest("hex");
}

async function cli(script, args, options = {}) {
  try {
    const { stdout, stderr } = await run(process.execPath, [script, ...args], options);
    return { code: 0, stdout, stderr };
  } catch (error) {
    return { code: error.code, stdout: error.stdout ?? "", stderr: error.stderr ?? "" };
  }
}

function rejects(fn, pattern) {
  return assert.rejects(fn, (error) => {
    assert.ok(error instanceof ReleaseError, `expected ReleaseError, got ${error.stack}`);
    assert.match(error.message, pattern);
    return true;
  });
}

function throws(fn, pattern) {
  assert.throws(fn, (error) => {
    assert.ok(error instanceof ReleaseError, `expected ReleaseError, got ${error.stack}`);
    assert.match(error.message, pattern);
    return true;
  });
}

// Writes a lock plus its patch files under `dir` and returns the lock path.
// `mutate` may adjust the lock object before it is written.
async function writeLockFixture(dir, { contents = PATCH_CONTENT, mutate = (lock) => lock } = {}) {
  await mkdir(path.join(dir, "patches"), { recursive: true });
  const patches = [];
  for (const [id, text] of Object.entries(contents)) {
    const rel = path.join("patches", `${id}.patch`);
    await writeFile(path.join(dir, rel), text);
    patches.push({ id, path: rel, sha256: sha256(text) });
  }
  const lock = mutate({
    version: 2,
    repository: "https://example.invalid/t3code.git",
    commit: UPSTREAM_COMMIT,
    patches,
    variants: {
      "managed-nightly": ["reasoning-full", "desktop-runtime-common"],
      reasoning: ["reasoning-full", "desktop-runtime-common", "reasoning-identity"],
    },
  });
  const lockPath = path.join(dir, "source.lock.json");
  await writeFile(lockPath, `${JSON.stringify(lock, null, 2)}\n`);
  return lockPath;
}

function baseInputs(lock, overrides = {}) {
  return {
    lock,
    upstreamVersion: UPSTREAM_VERSION,
    releaseCounter: 1,
    builderRevision: BUILDER_REVISION,
    publicConfig: PUBLIC_CONFIG,
    ...overrides,
  };
}

function inventoryFor(version, overrides = {}) {
  const files = {
    "managed-nightly-darwin-arm64": `T3-Code-${version}-arm64.zip`,
    "reasoning-darwin-arm64": `T3-Code-Reasoning-${version}-arm64.zip`,
    "managed-server-darwin-arm64": `managed-server-darwin-arm64-${version}.tar.gz`,
    "managed-server-linux-x64": `managed-server-linux-x64-${version}.tar.gz`,
  };
  return EXPECTED_ARTIFACTS.map((expected) => ({
    ...structuredClone(expected),
    file: files[expected.id],
    version,
    ...(expected.kind === "desktop" ? { embeddedServerVersion: version } : {}),
    ...(overrides[expected.id] ?? {}),
  }));
}

async function writeArtifacts(dir, inventory) {
  await mkdir(dir, { recursive: true });
  for (const record of inventory) {
    await writeFile(path.join(dir, record.file), `fixture bytes for ${record.id}\n`);
  }
}

async function tree(dir) {
  const names = await readdir(dir);
  const out = {};
  for (const name of names.sort()) out[name] = sha256(await readFile(path.join(dir, name)));
  return out;
}

// Staging directories (dot-prefixed) and publisher locks (`.lock` suffix)
// that a run must never leave behind in a destination's parent.
async function leftovers(dir) {
  return (await readdir(dir)).filter((name) => name.startsWith(".") || name.endsWith(".lock"));
}

describe("resolve-managed-release", () => {
  let root;
  let lockPath;
  let lock;
  before(async () => {
    root = await mkdtemp(path.join(tmpdir(), "t3-managed-release-"));
    lockPath = await writeLockFixture(path.join(root, "lock"));
    lock = await readVerifiedLock(lockPath);
  });
  after(() => rm(root, { recursive: true, force: true }));

  it("resolves a version of the form <upstream>.managed.<counter>.p<12hex>", () => {
    const descriptor = resolveManagedRelease(baseInputs(lock, { releaseCounter: 7 }));
    assert.match(descriptor.releaseVersion, MANAGED_RELEASE_RE);
    assert.equal(
      descriptor.releaseVersion,
      `${UPSTREAM_VERSION}.managed.7.p${descriptor.releaseInputSha256.slice(0, 12)}`,
    );
    assert.deepEqual(parseManagedReleaseVersion(descriptor.releaseVersion), {
      releaseVersion: descriptor.releaseVersion,
      upstreamVersion: UPSTREAM_VERSION,
      releaseCounter: 7,
      releaseInputShort: descriptor.releaseInputSha256.slice(0, 12),
    });
    assert.ok(compareExactVersions(descriptor.releaseVersion, UPSTREAM_VERSION) > 0, "sorts after upstream");
    assert.equal(descriptor.upstreamCommit, UPSTREAM_COMMIT);
    assert.deepEqual(descriptor.identityPatches, ["reasoning-identity"]);
    assert.deepEqual(descriptor.presentationVariants, PRESENTATION_VARIANTS);
    assert.deepEqual(
      descriptor.variants.reasoning.patches.map((p) => p.id),
      ["reasoning-full", "desktop-runtime-common", "reasoning-identity"],
    );
    assert.equal(descriptor.priorRelease, null);
  });

  it("digest is deterministic regardless of public config key order", () => {
    const reordered = Object.fromEntries(Object.entries(PUBLIC_CONFIG).reverse());
    const a = resolveManagedRelease(baseInputs(lock));
    const b = resolveManagedRelease(baseInputs(lock, { publicConfig: reordered }));
    assert.equal(a.releaseInputSha256, b.releaseInputSha256);
    assert.equal(canonicalJson(a), canonicalJson(b));
    assert.equal(computePublicConfigFingerprint(PUBLIC_CONFIG), computePublicConfigFingerprint(reordered));
  });

  it("digest is deterministic regardless of lock variant key order", () => {
    const swapped = {
      ...lock,
      variants: { reasoning: lock.variants.reasoning, "managed-nightly": lock.variants["managed-nightly"] },
    };
    assert.equal(
      resolveManagedRelease(baseInputs(swapped)).releaseInputSha256,
      resolveManagedRelease(baseInputs(lock)).releaseInputSha256,
    );
  });

  it("the counter changes the version but not the digest", () => {
    const a = resolveManagedRelease(baseInputs(lock, { releaseCounter: 1 }));
    const b = resolveManagedRelease(baseInputs(lock, { releaseCounter: 2 }));
    assert.equal(a.releaseInputSha256, b.releaseInputSha256);
    assert.notEqual(a.releaseVersion, b.releaseVersion);
    assert.ok(compareExactVersions(b.releaseVersion, a.releaseVersion) > 0);
  });

  it("a changed patch, public value, or builder revision changes the digest", async () => {
    const base = resolveManagedRelease(baseInputs(lock)).releaseInputSha256;
    const patchDir = path.join(root, "lock-changed-patch");
    const changedLock = await readVerifiedLock(
      await writeLockFixture(patchDir, {
        contents: { ...PATCH_CONTENT, "reasoning-identity": "--- a/identity\n+++ b/identity\n@@ -1 +1 @@\n-stock\n+other\n" },
      }),
    );
    const patch = resolveManagedRelease(baseInputs(changedLock)).releaseInputSha256;
    const config = resolveManagedRelease(
      baseInputs(lock, { publicConfig: { ...PUBLIC_CONFIG, T3CODE_RELAY_URL: "https://relay2.fixture.invalid" } }),
    ).releaseInputSha256;
    const builder = resolveManagedRelease(
      baseInputs(lock, { builderRevision: "fedcba9876543210fedcba9876543210fedcba98" }),
    ).releaseInputSha256;
    const commit = resolveManagedRelease(
      baseInputs({ ...lock, commit: "1111111111111111111111111111111111111111" }),
    ).releaseInputSha256;
    const upstream = resolveManagedRelease(
      baseInputs(lock, { upstreamVersion: "0.0.39-nightly.20260906.1290" }),
    ).releaseInputSha256;
    assert.equal(new Set([base, patch, config, builder, commit, upstream]).size, 6);
  });

  it("emits fingerprints and provenance, never public config values", () => {
    const text = canonicalJson(resolveManagedRelease(baseInputs(lock)));
    for (const value of Object.values(PUBLIC_CONFIG)) assert.doesNotMatch(text, new RegExp(value.replace(/[.]/g, "\\.")));
    const descriptor = JSON.parse(text);
    assert.deepEqual(descriptor.publicConfig.keys, PUBLIC_CONFIG_KEYS);
    assert.match(descriptor.publicConfig.sha256, /^[0-9a-f]{64}$/);
  });

  it("refuses non-increasing counters for the same upstream nightly", () => {
    const prior = resolveManagedRelease(baseInputs(lock, { releaseCounter: 3 }));
    throws(
      () => resolveManagedRelease(baseInputs(lock, { releaseCounter: 3, priorRelease: prior })),
      /counter 3 does not increase over prior release/,
    );
    throws(
      () => resolveManagedRelease(baseInputs(lock, { releaseCounter: 2, priorRelease: prior })),
      /counter 2 does not increase over prior release/,
    );
    const next = resolveManagedRelease(baseInputs(lock, { releaseCounter: 4, priorRelease: prior }));
    assert.deepEqual(next.priorRelease, { releaseVersion: prior.releaseVersion });
    assert.ok(compareExactVersions(next.releaseVersion, prior.releaseVersion) > 0);
    // A bare prior version string in a minimal object is enough.
    throws(
      () => resolveManagedRelease(baseInputs(lock, { releaseCounter: 3, priorRelease: { releaseVersion: prior.releaseVersion } })),
      /does not increase/,
    );
  });

  it("refuses an upstream that does not sort after the prior release's upstream", () => {
    const prior = resolveManagedRelease(baseInputs(lock, { upstreamVersion: "0.0.39-nightly.20260906.1290", releaseCounter: 9 }));
    throws(
      () => resolveManagedRelease(baseInputs(lock, { releaseCounter: 10, priorRelease: prior })),
      /upstream 0\.0\.39-nightly\.20260905\.1284 does not sort after prior release/,
    );
    // A newer upstream restarts the counter.
    const newer = resolveManagedRelease(
      baseInputs(lock, { upstreamVersion: "0.0.40-nightly.20260907.1300", releaseCounter: 1, priorRelease: prior }),
    );
    assert.ok(compareExactVersions(newer.releaseVersion, prior.releaseVersion) > 0);
  });

  it("refuses an inconsistent or malformed prior release", () => {
    const prior = resolveManagedRelease(baseInputs(lock, { releaseCounter: 1 }));
    throws(
      () => resolveManagedRelease(baseInputs(lock, { releaseCounter: 2, priorRelease: { releaseVersion: UPSTREAM_VERSION } })),
      /not a managed release version/,
    );
    throws(
      () =>
        resolveManagedRelease(
          baseInputs(lock, { releaseCounter: 2, priorRelease: { ...prior, upstreamCommit: "2222222222222222222222222222222222222222" } }),
        ),
      /pins upstream commit/,
    );
    throws(
      () => resolveManagedRelease(baseInputs(lock, { releaseCounter: 2, priorRelease: { ...prior, releaseCounter: 5 } })),
      /disagrees with its releaseVersion/,
    );
  });

  it("refuses malformed upstream versions, counters, and builder revisions", () => {
    for (const bad of ["0.0.39", "0.0.39-nightly.2026.1", `${UPSTREAM_VERSION}.managed.1.p000000000000`, "v0.0.39-nightly.20260905.1284", "0.0.39-nightly.20260905.01"]) {
      throws(() => resolveManagedRelease(baseInputs(lock, { upstreamVersion: bad })), /not an ordinary upstream nightly/);
    }
    for (const bad of [0, -1, 1.5, "3", 2 ** 53, Number.NaN]) {
      throws(() => resolveManagedRelease(baseInputs(lock, { releaseCounter: bad })), /positive safe integer/);
    }
    for (const bad of ["abc123", BUILDER_REVISION.toUpperCase(), BUILDER_REVISION.slice(0, 39)]) {
      throws(() => resolveManagedRelease(baseInputs(lock, { builderRevision: bad })), /builder revision/);
    }
  });

  it("refuses an incomplete, extended, or malformed public config without echoing values", () => {
    const { T3CODE_RELAY_URL, ...missing } = PUBLIC_CONFIG;
    throws(() => resolveManagedRelease(baseInputs(lock, { publicConfig: missing })), /missing T3CODE_RELAY_URL/);
    throws(
      () => resolveManagedRelease(baseInputs(lock, { publicConfig: { ...PUBLIC_CONFIG, CLERK_SECRET_KEY: "sk_fixture" } })),
      /unexpected keys CLERK_SECRET_KEY/,
    );
    for (const bad of ["", " x", "a\nb", 42, null]) {
      assert.throws(
        () => resolveManagedRelease(baseInputs(lock, { publicConfig: { ...PUBLIC_CONFIG, T3CODE_RELAY_URL: bad } })),
        (error) => {
          assert.match(error.message, /T3CODE_RELAY_URL must be a non-empty single-line string/);
          assert.doesNotMatch(error.message, /fixture/);
          return true;
        },
      );
    }
  });

  it("refuses locks whose variants are not exactly managed-nightly plus a reasoning identity suffix", () => {
    const withVariants = (variants) => ({ ...lock, variants });
    throws(
      () => resolveManagedRelease(baseInputs(withVariants({ "managed-nightly": lock.variants["managed-nightly"] }))),
      /variants must be exactly managed-nightly, reasoning/,
    );
    throws(
      () => resolveManagedRelease(baseInputs(withVariants({ ...lock.variants, extra: ["reasoning-full"] }))),
      /variants must be exactly managed-nightly, reasoning/,
    );
    throws(
      () => resolveManagedRelease(baseInputs(withVariants({ ...lock.variants, reasoning: lock.variants["managed-nightly"] }))),
      /must extend managed-nightly with at least one identity patch/,
    );
    throws(
      () =>
        resolveManagedRelease(
          baseInputs(withVariants({ "managed-nightly": ["reasoning-full"], reasoning: ["desktop-runtime-common", "reasoning-identity"] })),
        ),
      /common prefix must match exactly/,
    );
    throws(
      () => validateLock({ ...lock, variants: { ...lock.variants, reasoning: ["desktop-runtime-common", "reasoning-full", "reasoning-identity"] } }),
      /out of catalog order/,
    );
    throws(() => validateLock({ ...lock, version: 1 }), /require a version 2 lock/);
  });

  it("refuses patch bytes that do not match the lock, and patches outside the lock directory", async () => {
    const dir = path.join(root, "lock-drift");
    const drifted = await writeLockFixture(dir);
    await writeFile(path.join(dir, "patches", "reasoning-identity.patch"), "tampered\n");
    await rejects(() => readVerifiedLock(drifted), /reasoning-identity\.patch: sha256 mismatch/);

    const escapeDir = path.join(root, "lock-escape");
    const outside = path.join(root, "outside.patch");
    await writeFile(outside, PATCH_CONTENT["reasoning-full"]);
    const escaping = await writeLockFixture(escapeDir, {
      mutate: (l) => ({ ...l, patches: l.patches.map((p) => (p.id === "reasoning-full" ? { ...p, path: "../outside.patch" } : p)) }),
    });
    await rejects(() => readVerifiedLock(escaping), /outside the lock directory/);

    const linkDir = path.join(root, "lock-link");
    const linked = await writeLockFixture(linkDir);
    await rm(path.join(linkDir, "patches", "reasoning-full.patch"));
    await symlink(outside, path.join(linkDir, "patches", "reasoning-full.patch"));
    await rejects(() => readVerifiedLock(linked), /links outside the lock directory/);
  });

  describe("CLI", () => {
    let configPath;
    before(async () => {
      configPath = path.join(root, "public-config.json");
      await writeFile(configPath, JSON.stringify(PUBLIC_CONFIG));
    });

    function args(output, extra = []) {
      return [
        "--lock", lockPath,
        "--upstream-version", UPSTREAM_VERSION,
        "--release-counter", "2",
        "--builder-revision", BUILDER_REVISION,
        "--public-config", configPath,
        "--output", output,
        ...extra,
      ];
    }

    it("writes a canonical descriptor, GitHub outputs, and prints no config values", async () => {
      const output = path.join(root, "cli", "release.json");
      const ghOutput = path.join(root, "cli", "github-output.txt");
      await mkdir(path.dirname(output), { recursive: true });
      await writeFile(ghOutput, "earlier=kept\n");
      const result = await cli(resolveScript, args(output, ["--github-output", ghOutput]));
      assert.equal(result.code, 0, result.stderr);
      const text = await readFile(output, "utf8");
      const descriptor = JSON.parse(text);
      assert.equal(text, canonicalJson(descriptor), "descriptor file is canonical JSON");
      assert.equal(descriptor.releaseVersion, resolveManagedRelease(baseInputs(lock, { releaseCounter: 2 })).releaseVersion);
      assert.match(result.stdout, new RegExp(`resolved ${descriptor.releaseVersion.replace(/[.]/g, "\\.")}`));
      const gh = await readFile(ghOutput, "utf8");
      assert.ok(gh.startsWith("earlier=kept\n"), "existing GitHub output lines are preserved");
      assert.match(gh, new RegExp(`^release_version=${descriptor.releaseVersion.replace(/[.]/g, "\\.")}$`, "m"));
      assert.match(gh, /^public_config_sha256=[0-9a-f]{64}$/m);
      for (const value of Object.values(PUBLIC_CONFIG)) {
        assert.doesNotMatch(result.stdout + result.stderr + gh + text, new RegExp(value.replace(/[.]/g, "\\.")));
      }
    });

    it("refuses to overwrite an existing output", async () => {
      const output = path.join(root, "cli-collision", "release.json");
      await mkdir(path.dirname(output), { recursive: true });
      await writeFile(output, "{\"kept\": true}\n");
      const result = await cli(resolveScript, args(output));
      assert.notEqual(result.code, 0);
      assert.match(result.stderr, /already exists/);
      assert.equal(await readFile(output, "utf8"), "{\"kept\": true}\n");
    });

    it("refuses a prior release from a file", async () => {
      const prior = path.join(root, "prior.json");
      await writeFile(prior, canonicalJson(resolveManagedRelease(baseInputs(lock, { releaseCounter: 2 }))));
      const output = path.join(root, "cli-prior.json");
      const result = await cli(resolveScript, args(output, ["--prior-release", prior]));
      assert.notEqual(result.code, 0);
      assert.match(result.stderr, /does not increase over prior release/);
    });

    it("requires every input flag and rejects a non-integer counter", async () => {
      const missing = await cli(resolveScript, ["--lock", lockPath]);
      assert.notEqual(missing.code, 0);
      assert.match(missing.stderr, /--upstream-version is required/);
      const counter = await cli(resolveScript, args(path.join(root, "never.json")).map((v) => (v === "2" ? "02" : v)));
      assert.notEqual(counter.code, 0);
      assert.match(counter.stderr, /--release-counter must be a positive integer/);
    });

    it("refuses a --github-output that aliases the descriptor or any input, before writing anything", async () => {
      const dir = path.join(root, "gh-alias");
      await mkdir(dir, { recursive: true });
      const output = path.join(dir, "release.json");
      const priorPath = path.join(dir, "prior.json");
      await writeFile(priorPath, canonicalJson(resolveManagedRelease(baseInputs(lock, { releaseCounter: 1 }))));
      const lockDir = path.dirname(lockPath);
      const patchFile = path.join(lockDir, "patches", "reasoning-full.patch");
      const hardLink = path.join(dir, "config-hardlink.json");
      await link(configPath, hardLink);
      const symLink = path.join(dir, "config-symlink.json");
      await symlink(configPath, symLink);
      const lockDirLink = path.join(dir, "lockdir-link");
      await symlink(lockDir, lockDirLink);
      const outDirLink = path.join(dir, "outdir-link");
      await symlink(dir, outDirLink);
      const inputs = [lockPath, configPath, priorPath, patchFile];
      const before = await Promise.all(inputs.map((file) => readFile(file)));

      const cases = [
        [output, /must not be the same file as --output/],
        [path.join(outDirLink, "release.json"), /must not be the same file as --output/],
        [lockPath, /same file as the lock/],
        [path.join(lockDirLink, "source.lock.json"), /same file as the lock/],
        [configPath, /same file as the public config/],
        [priorPath, /same file as the prior release/],
        [patchFile, /same file as the patch/],
        [hardLink, /linked to the public config/],
        [symLink, /symbolic link; it must be a regular file/],
        [dir, /not a regular file/],
      ];
      for (const [ghOutput, pattern] of cases) {
        const result = await cli(resolveScript, args(output, ["--prior-release", priorPath, "--github-output", ghOutput]));
        assert.notEqual(result.code, 0, `${ghOutput} must be refused`);
        assert.match(result.stderr, pattern, ghOutput);
        for (const value of Object.values(PUBLIC_CONFIG)) {
          assert.doesNotMatch(result.stdout + result.stderr, new RegExp(value.replace(/[.]/g, "\\.")));
        }
        await assert.rejects(readFile(output), { code: "ENOENT" }, `${ghOutput}: no descriptor may be written`);
      }
      const after = await Promise.all(inputs.map((file) => readFile(file)));
      inputs.forEach((file, i) => assert.ok(before[i].equals(after[i]), `${file} must be byte-identical`));
      assert.ok((await readFile(hardLink)).equals(before[1]));

      // With a distinct regular file, the run succeeds and appends values only.
      const ghOutput = path.join(dir, "github-output.txt");
      const ok = await cli(resolveScript, args(output, ["--prior-release", priorPath, "--github-output", ghOutput]));
      assert.equal(ok.code, 0, ok.stderr);
      assert.match(await readFile(ghOutput, "utf8"), /^release_version=/m);
      JSON.parse(await readFile(output, "utf8"));
    });

    it("importing the module does not run main", async () => {
      const { stdout, stderr } = await run(process.execPath, ["--input-type=module", "-e", `await import(${JSON.stringify(resolveScript)});`]);
      assert.equal(stdout + stderr, "");
    });
  });
});

describe("write-managed-release-manifest", () => {
  let root;
  let descriptor;
  let inventory;
  let artifactsDir;
  let counter = 0;
  const destinationFor = (name) => path.join(root, "out", name);
  before(async () => {
    root = await mkdtemp(path.join(tmpdir(), "t3-managed-manifest-"));
    const lock = await readVerifiedLock(await writeLockFixture(path.join(root, "lock")));
    descriptor = resolveManagedRelease(baseInputs(lock));
    inventory = inventoryFor(descriptor.releaseVersion);
    artifactsDir = path.join(root, "artifacts");
    await writeArtifacts(artifactsDir, inventory);
  });
  after(() => rm(root, { recursive: true, force: true }));

  function publish(overrides = {}) {
    counter += 1;
    return writeManagedReleaseManifest({
      descriptor,
      inventory,
      artifactsDir,
      destination: destinationFor(`release-${counter}`),
      ...overrides,
    });
  }

  it("publishes a canonical manifest, SHA256SUMS covering everything, and the artifacts", async () => {
    const destination = destinationFor("happy");
    const manifest = await publish({ destination });
    const names = (await readdir(destination)).sort();
    assert.deepEqual(names, [MANIFEST_FILE, SUMS_FILE, ...inventory.map((r) => r.file)].sort());

    const manifestText = await readFile(path.join(destination, MANIFEST_FILE), "utf8");
    assert.equal(manifestText, canonicalJson(manifest), "written manifest is canonical JSON");
    assert.equal(manifestText, canonicalJson(JSON.parse(manifestText)), "canonical form is a fixed point");
    const written = JSON.parse(manifestText);
    assert.equal(written.schemaVersion, 1);
    assert.equal(written.releaseVersion, descriptor.releaseVersion);
    assert.equal(written.releaseInputSha256, descriptor.releaseInputSha256);
    assert.equal(written.publicConfigSha256, descriptor.publicConfig.sha256);
    assert.deepEqual(Object.keys(written.variants).sort(), ["managed-nightly", "reasoning"]);
    assert.deepEqual(written.variants.reasoning.patches.at(-1), { id: "reasoning-identity", sha256: sha256(PATCH_CONTENT["reasoning-identity"]) });
    assert.deepEqual(written.artifacts.map((a) => a.id), EXPECTED_ARTIFACTS.map((a) => a.id));
    for (const artifact of written.artifacts) {
      const actual = await hashFile(path.join(destination, artifact.file));
      assert.deepEqual({ bytes: artifact.bytes, sha256: artifact.sha256 }, actual, `${artifact.id} hash and length`);
      assert.equal(artifact.version, descriptor.releaseVersion);
      assert.equal("url" in artifact, false);
    }
    const nightly = written.artifacts.find((a) => a.id === "managed-nightly-darwin-arm64");
    assert.deepEqual(
      { bundleId: nightly.bundleId, productName: nightly.productName, urlSchemes: nightly.urlSchemes, presentationVariant: nightly.presentationVariant, embeddedServerVersion: nightly.embeddedServerVersion },
      { bundleId: "com.t3tools.t3code", productName: "T3 Code (Nightly)", urlSchemes: ["t3code", "t3code-dev"], presentationVariant: "managed-nightly", embeddedServerVersion: descriptor.releaseVersion },
    );
    const reasoning = written.artifacts.find((a) => a.id === "reasoning-darwin-arm64");
    assert.deepEqual([reasoning.bundleId, reasoning.productName, reasoning.urlSchemes, reasoning.presentationVariant], ["com.t3tools.t3code.reasoning", "T3 Code (Reasoning)", ["t3code-reasoning"], "reasoning"]);
    const linux = written.artifacts.find((a) => a.id === "managed-server-linux-x64");
    assert.deepEqual([linux.platform, linux.arch, linux.format, linux.entry, linux.launcherProtocol, linux.variant], ["linux", "x64", "tar.gz", "node_modules/t3/dist/bin.mjs", 2, "common"]);

    // SHA256SUMS: one sorted line per artifact plus the manifest, matching the bytes on disk.
    const sums = await readFile(path.join(destination, SUMS_FILE), "utf8");
    const lines = sums.split("\n").filter(Boolean);
    assert.equal(lines.length, 5);
    const sumFiles = lines.map((line) => line.slice(66));
    assert.deepEqual(sumFiles, [...sumFiles].sort(), "SHA256SUMS lines are sorted by file name");
    for (const line of lines) {
      const [hash, file] = line.split("  ");
      assert.equal(hash, sha256(await readFile(path.join(destination, file))), `${file} checksum`);
    }
    assert.ok(lines.some((line) => line.endsWith(`  ${MANIFEST_FILE}`)), "SHA256SUMS covers the manifest");
    assert.equal(sums, formatSha256Sums(lines.map((line) => ({ sha256: line.slice(0, 64), file: line.slice(66) }))));
    // No staging directory survives and the source artifacts are untouched.
    assert.deepEqual((await readdir(path.dirname(destination))).filter((n) => n.startsWith(".")), []);
    assert.deepEqual(Object.keys(await tree(artifactsDir)).sort(), inventory.map((r) => r.file).sort());
  });

  it("is byte-for-byte deterministic for the same inputs", async () => {
    const a = canonicalJson(await publish());
    const b = canonicalJson(await publish());
    assert.equal(a, b);
    assert.equal(canonicalJson(buildManifest(descriptor, JSON.parse(a).artifacts)), a);
  });

  it("requires exactly the four release artifacts", async () => {
    await rejects(() => publish({ inventory: inventory.slice(0, 3) }), /missing required artifact\(s\) managed-server-linux-x64/);
    await rejects(
      () => publish({ inventory: [...inventory, { ...inventory[3], id: "managed-server-linux-arm64", arch: "arm64", file: "x.tar.gz" }] }),
      /outside the release set: managed-server-linux-arm64/,
    );
    await rejects(() => publish({ inventory: [...inventory, inventory[0]] }), /duplicate artifact id/);
    await rejects(() => publish({ inventory: { not: "an array" } }), /must be a JSON array/);
  });

  it("refuses version and metadata that disagree with the descriptor or the fixed identity", async () => {
    const other = `${UPSTREAM_VERSION}.managed.9.p${descriptor.releaseInputShort}`;
    const withOverride = (id, override) => inventoryFor(descriptor.releaseVersion, { [id]: override });
    await rejects(() => publish({ inventory: withOverride("managed-server-linux-x64", { version: other }) }), /version .* does not equal release version/);
    await rejects(() => publish({ inventory: withOverride("reasoning-darwin-arm64", { embeddedServerVersion: other }) }), /embeddedServerVersion .* does not equal release version/);
    await rejects(() => publish({ inventory: withOverride("managed-nightly-darwin-arm64", { presentationVariant: "reasoning" }) }), /presentationVariant must be "managed-nightly"/);
    await rejects(() => publish({ inventory: withOverride("reasoning-darwin-arm64", { bundleId: "com.t3tools.t3code" }) }), /bundleId must be "com.t3tools.t3code.reasoning"/);
    await rejects(() => publish({ inventory: withOverride("managed-nightly-darwin-arm64", { urlSchemes: ["t3code"] }) }), /urlSchemes must be \["t3code","t3code-dev"\]/);
    await rejects(() => publish({ inventory: withOverride("managed-server-linux-x64", { arch: "arm64" }) }), /arch must be "x64"/);
    await rejects(() => publish({ inventory: withOverride("managed-server-darwin-arm64", { entry: "dist/bin.mjs" }) }), /entry must be "node_modules\/t3\/dist\/bin.mjs"/);
    await rejects(() => publish({ inventory: withOverride("managed-server-darwin-arm64", { launcherProtocol: 3 }) }), /launcherProtocol must be 2/);
    await rejects(() => publish({ inventory: withOverride("managed-server-darwin-arm64", { url: "https://elsewhere.invalid/x.tar.gz" }) }), /unexpected field\(s\) url/);
    const { embeddedServerVersion, ...noEmbedded } = inventory[0];
    await rejects(() => publish({ inventory: [noEmbedded, ...inventory.slice(1)] }), /missing field embeddedServerVersion/);
    await rejects(() => publish({ descriptor: { ...descriptor, releaseCounter: 2 } }), /releaseCounter does not match releaseVersion/);
    await rejects(() => publish({ descriptor: { ...descriptor, kind: "other" } }), /expected kind/);
  });

  it("refuses a descriptor whose provenance no longer reproduces its digest and version, before creating anything", async () => {
    const destination = destinationFor("tampered");
    const zeros = "0".repeat(64);
    const recomputed = /does not match the digest recomputed from its provenance/;
    const cases = [
      ["builder revision", (d) => { d.builderRevision = "b".repeat(40); }, recomputed],
      ["public config fingerprint", (d) => { d.publicConfig.sha256 = zeros; }, recomputed],
      ["upstream commit", (d) => { d.upstreamCommit = "1".repeat(40); }, recomputed],
      ["upstream version", (d) => {
        const v = "0.0.40-nightly.20260907.1300";
        d.releaseVersion = d.releaseVersion.replace(d.upstreamVersion, v);
        d.upstreamVersion = v;
      }, recomputed],
      ["identity patch hash", (d) => { d.variants.reasoning.patches.at(-1).sha256 = zeros; }, recomputed],
      ["common prefix hash divergence", (d) => { d.variants.reasoning.patches[0].sha256 = zeros; }, /common prefix must be identical/],
      ["common prefix id divergence", (d) => { d.variants.reasoning.patches[0].id = "other"; }, /common prefix must match exactly/],
      ["digest edited beyond the version suffix", (d) => { d.releaseInputSha256 = `${d.releaseInputSha256.slice(0, 12)}${"f".repeat(52)}`; }, recomputed],
      ["digest short form", (d) => { d.releaseInputShort = "000000000000"; }, /releaseInputShort does not match/],
      ["presentation variants", (d) => { d.presentationVariants = { "managed-nightly": "reasoning", reasoning: "managed-nightly" }; }, /presentationVariants must be/],
      ["identity patch list", (d) => { d.identityPatches = []; }, /identityPatches must be exactly/],
      ["zero counter", (d) => { d.releaseCounter = 0; d.releaseVersion = d.releaseVersion.replace(".managed.1.", ".managed.0."); }, /positive safe integer/],
      ["missing reasoning variant", (d) => { delete d.variants.reasoning; }, /variants must be exactly/],
      ["reasoning without an identity suffix", (d) => {
        d.variants.reasoning.patches = structuredClone(d.variants["managed-nightly"].patches);
        d.identityPatches = [];
      }, /at least one identity patch/],
      ["version suffix from another digest", (d) => { d.releaseVersion = d.releaseVersion.replace(/p[0-9a-f]{12}$/, "p000000000000"); }, /releaseVersion .* does not match the resolved/],
    ];
    for (const [name, mutate, pattern] of cases) {
      const tampered = structuredClone(descriptor);
      mutate(tampered);
      await assert.rejects(
        () => publish({ descriptor: tampered, destination }),
        (error) => {
          assert.ok(error instanceof ReleaseError, `${name}: ${error.stack}`);
          assert.match(error.message, pattern, name);
          return true;
        },
      );
    }
    await assert.rejects(readdir(destination), { code: "ENOENT" });
    assert.deepEqual(await leftovers(path.dirname(destination)), []);
    // An unmodified copy still publishes, so the refusals above are real.
    await publish({ descriptor: structuredClone(descriptor), destination });
  });

  it("refuses traversal, symlinks, directories, and reserved or colliding file names", async () => {
    const withFile = (id, file) => inventoryFor(descriptor.releaseVersion, { [id]: { file } });
    const nightly = "managed-nightly-darwin-arm64";
    for (const file of ["../escape.zip", "sub/inner.zip", path.join(artifactsDir, inventory[0].file), "..", "-flag.zip", "bad\nname.zip"]) {
      await rejects(() => publish({ inventory: withFile(nightly, file) }), /must be a bare file name|not allowed in an artifact name/);
    }
    await rejects(() => publish({ inventory: withFile(nightly, "wrong-extension.tar.gz") }), /must end with \.zip/);
    await rejects(() => publish({ inventory: withFile(nightly, "does-not-exist.zip") }), /cannot stat/);
    await symlink(path.join(artifactsDir, inventory[0].file), path.join(artifactsDir, "link.zip"));
    await rejects(() => publish({ inventory: withFile(nightly, "link.zip") }), /symbolic links are not accepted/);
    await mkdir(path.join(artifactsDir, "dir.zip"));
    await rejects(() => publish({ inventory: withFile(nightly, "dir.zip") }), /not a regular file/);
    await writeFile(path.join(artifactsDir, "empty.zip"), "");
    await rejects(() => publish({ inventory: withFile(nightly, "empty.zip") }), /is empty/);
    await rejects(() => publish({ inventory: withFile("managed-server-linux-x64", inventory[2].file) }), /is also used by artifact managed-server-darwin-arm64/);
    // Case-only differences collide on case-insensitive filesystems.
    await rejects(
      () => publish({ inventory: withFile("managed-server-linux-x64", inventory[2].file.replace("managed-server", "MANAGED-SERVER")) }),
      /is also used by artifact managed-server-darwin-arm64/,
    );
    // A record can never claim the manifest or checksum file slot.
    for (const reserved of [MANIFEST_FILE, SUMS_FILE]) {
      throws(() => validateInventory(descriptor, withFile(nightly, reserved)), /must end with \.zip|collides with a release file/);
    }
    await rejects(() => publish({ artifactsDir: path.join(root, "missing-dir") }), /artifact directory/);
  });

  it("refuses an existing destination without touching it or leaving staging behind", async () => {
    const destination = destinationFor("occupied");
    await mkdir(destination, { recursive: true });
    await writeFile(path.join(destination, "keep.txt"), "untouched\n");
    const before = await tree(destination);
    await rejects(() => publish({ destination }), /already exists; a release is never rewritten/);
    assert.deepEqual(await tree(destination), before);
    assert.deepEqual((await readdir(path.dirname(destination))).filter((n) => n.startsWith(".")), []);

    const file = destinationFor("occupied-file");
    await writeFile(file, "a file\n");
    await rejects(() => publish({ destination: file }), /already exists/);
    assert.equal(await readFile(file, "utf8"), "a file\n");

    // A completed release refuses a repeat publication and keeps its bytes.
    const published = destinationFor("published-once");
    await publish({ destination: published });
    const snapshot = await tree(published);
    await rejects(() => publish({ destination: published }), /already exists/);
    assert.deepEqual(await tree(published), snapshot);
    assert.deepEqual(await leftovers(path.dirname(published)), []);
  });

  it("serializes cooperating publishers: exactly one publishes and the lock is released", async () => {
    const destination = destinationFor("contended");
    const results = await Promise.allSettled([
      publish({ destination }),
      publish({ destination }),
      publish({ destination }),
    ]);
    const fulfilled = results.filter((r) => r.status === "fulfilled");
    assert.equal(fulfilled.length, 1, JSON.stringify(results.map((r) => r.status)));
    for (const { reason } of results.filter((r) => r.status === "rejected")) {
      assert.ok(reason instanceof ReleaseError, reason.stack);
      assert.match(reason.message, /another publisher holds .*\.lock|already exists/);
    }
    const names = Object.keys(await tree(destination)).sort();
    assert.deepEqual(names, [MANIFEST_FILE, SUMS_FILE, ...inventory.map((r) => r.file)].sort());
    assert.equal(canonicalJson(fulfilled[0].value), await readFile(path.join(destination, MANIFEST_FILE), "utf8"));
    assert.deepEqual(await leftovers(path.dirname(destination)), []);
  });

  it("refuses to publish while another publisher holds the lock, leaving that lock and nothing else", async () => {
    const destination = destinationFor("locked");
    const lockDir = `${destination}.lock`;
    await mkdir(lockDir, { recursive: true });
    await rejects(() => publish({ destination }), /another publisher holds .*locked\.lock/);
    await assert.rejects(readdir(destination), { code: "ENOENT" });
    assert.ok((await lstat(lockDir)).isDirectory(), "a foreign lock is never removed");
    assert.deepEqual(await leftovers(path.dirname(destination)), [path.basename(lockDir)]);
    await rm(lockDir, { recursive: true });
    await publish({ destination });
    assert.deepEqual(await leftovers(path.dirname(destination)), []);
  });

  it("fails before staging when validation fails, leaving no output", async () => {
    const destination = destinationFor("never-created");
    await rejects(() => publish({ destination, inventory: inventory.slice(1) }), /missing required artifact/);
    await assert.rejects(readdir(destination), { code: "ENOENT" });
    assert.deepEqual((await readdir(path.dirname(destination))).filter((n) => n.startsWith(".")), []);
  });

  describe("CLI", () => {
    it("publishes from descriptor, inventory, and artifact files, and refuses a second run", async () => {
      const dir = path.join(root, "cli");
      await mkdir(dir, { recursive: true });
      const descriptorPath = path.join(dir, "release.json");
      const inventoryPath = path.join(dir, "inventory.json");
      await writeFile(descriptorPath, canonicalJson(descriptor));
      await writeFile(inventoryPath, JSON.stringify(inventory));
      const destination = path.join(dir, "release");
      const args = ["--descriptor", descriptorPath, "--inventory", inventoryPath, "--artifacts", artifactsDir, "--destination", destination];
      const first = await cli(manifestScript, args);
      assert.equal(first.code, 0, first.stderr);
      assert.match(first.stdout, /published .* with 4 artifact\(s\)/);
      const snapshot = await tree(destination);
      assert.ok(MANIFEST_FILE in snapshot && SUMS_FILE in snapshot);
      const second = await cli(manifestScript, args);
      assert.notEqual(second.code, 0);
      assert.match(second.stderr, /already exists/);
      assert.deepEqual(await tree(destination), snapshot);
      for (const value of Object.values(PUBLIC_CONFIG)) {
        assert.doesNotMatch(first.stdout + first.stderr + (await readFile(path.join(destination, MANIFEST_FILE), "utf8")), new RegExp(value.replace(/[.]/g, "\\.")));
      }
    });

    it("requires every flag and does not run main on import", async () => {
      const result = await cli(manifestScript, ["--descriptor", path.join(root, "x.json")]);
      assert.notEqual(result.code, 0);
      assert.match(result.stderr, /--inventory is required/);
      const { stdout, stderr } = await run(process.execPath, ["--input-type=module", "-e", `await import(${JSON.stringify(manifestScript)});`]);
      assert.equal(stdout + stderr, "");
    });
  });
});
