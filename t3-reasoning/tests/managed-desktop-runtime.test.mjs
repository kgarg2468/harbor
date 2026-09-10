// Tests for scripts/build-managed-desktop-runtime.mjs. Every build runs
// against a tiny prepared-source fixture: a real git repository holding a
// synthetic upstream commit with one exact variant's patches applied as
// uncommitted changes, plus a provenance record and lock. One fake runner
// stands in for pnpm (including the `pnpm exec node` run of the source
// tree's desktop builder), ditto, plutil, and the packaged Electron
// executable: it materializes a ZIP into the owned
// output directory, an `.app` tree when it receives the exact ditto call,
// and deterministic plist / embedded-version output for the exact platform
// commands. Git runs for real. Nothing here installs dependencies, runs
// Electron, signs, or touches the network.
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { chmod, lstat, mkdir, mkdtemp, readdir, readFile, realpath, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { describe, it } from "node:test";
import { parseEnv, promisify } from "node:util";

import { ReleaseError, canonicalJson, readVerifiedLock, resolveManagedRelease, sha256Hex } from "../scripts/resolve-managed-release.mjs";
import { EXPECTED_ARTIFACTS } from "../scripts/write-managed-release-manifest.mjs";
import { PINNED_NODE_VERSION, RELEASE_PACKAGE_FILES, createRunner } from "../scripts/build-managed-server-runtime.mjs";
import {
  DITTO,
  PLUTIL,
  buildManagedDesktopRuntime,
  checkBundlePlist,
  checkMachOArm64Executable,
  desktopBuildArguments,
  desktopBuildExecArguments,
  parseArgs,
  requireDesktopHost,
  selectDesktopArtifact,
} from "../scripts/build-managed-desktop-runtime.mjs";

const run = promisify(execFile);
const here = path.dirname(fileURLToPath(import.meta.url));
const builderScript = path.join(here, "..", "scripts", "build-managed-desktop-runtime.mjs");
const realRunner = createRunner();

const BUILDER_REVISION = "0123456789abcdef0123456789abcdef01234567";
const UPSTREAM_VERSION = "0.0.39-nightly.20260905.1284";
const PUBLIC_CONFIG = {
  T3CODE_RELAY_URL: "https://relay.fixture.invalid",
  T3CODE_CLERK_PUBLISHABLE_KEY: "pk_test_FIXTURE_PUBLISHABLE_VALUE",
  T3CODE_CLERK_JWT_TEMPLATE: "fixture-jwt-template",
  T3CODE_CLERK_CLI_OAUTH_CLIENT_ID: "fixture-cli-oauth-client",
};
const HOST = { platform: "darwin", arch: "arm64", nodeVersion: PINNED_NODE_VERSION };
// The Node executable the builder is told to use; the fake runner requires it
// as the program `pnpm exec` runs. It is never spawned directly.
const FAKE_NODE = "/fixture/bin/node";
const VARIANTS = ["managed-nightly", "reasoning"];
const DESKTOP = Object.fromEntries(VARIANTS.map((v) => [v, EXPECTED_ARTIFACTS.find((a) => a.kind === "desktop" && a.variant === v)]));
const PATCHES = {
  "reasoning-full": "diff --git a/one b/one\n--- a/one\n+++ b/one\n@@ -1 +1 @@\n-one\n+one patched\n",
  "desktop-runtime-common":
    "diff --git a/two b/two\n--- a/two\n+++ b/two\n@@ -1 +1 @@\n-two\n+two patched\n" +
    "diff --git a/added.txt b/added.txt\nnew file mode 100644\n--- /dev/null\n+++ b/added.txt\n@@ -0,0 +1 @@\n+added by patch\n",
  "reasoning-identity": "diff --git a/identity b/identity\n--- a/identity\n+++ b/identity\n@@ -1 +1 @@\n-stock\n+reasoning\n",
};
// Mach-O headers: magic, cputype, cpusubtype, filetype, padded to 32 bytes.
function machO({ cpu = 0x0100000c, filetype = 2, magic = 0xfeedfacf } = {}) {
  const b = Buffer.alloc(32);
  b.writeUInt32LE(magic, 0);
  b.writeUInt32LE(cpu, 4);
  b.writeUInt32LE(0, 8);
  b.writeUInt32LE(filetype, 12);
  return b;
}
const HEADERS = {
  arm64: machO(),
  x64: machO({ cpu: 0x01000007 }),
  dylib: machO({ filetype: 6 }),
  fat: Buffer.concat([Buffer.from([0xca, 0xfe, 0xba, 0xbe, 0, 0, 0, 2]), Buffer.alloc(24)]),
  script: Buffer.from("#!/bin/sh\nexec electron\n"),
  short: Buffer.from([0xcf, 0xfa, 0xed, 0xfe]),
};
const ALLOWED_COMMANDS = new Set(["git", "pnpm", DITTO, PLUTIL]);
const FORBIDDEN_ARGS = ["--skip-build", "--signed", "--mock-updates", "--publish", "--repo", "--repository", "-p", "--prepackaged"];

function json(value) {
  return `${JSON.stringify(value, null, 2)}\n`;
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

async function git(cwd, args, input) {
  return realRunner({
    command: "git",
    args: ["-c", "user.name=OPERATOR", "-c", "user.email=operator@example.com", ...args],
    cwd,
    env: { ...process.env, GIT_CONFIG_GLOBAL: "/dev/null", GIT_CONFIG_NOSYSTEM: "1" },
    input,
  });
}

async function write(root, files) {
  for (const [relative, content] of Object.entries(files)) {
    const file = path.join(root, relative);
    await mkdir(path.dirname(file), { recursive: true });
    await writeFile(file, content);
  }
}

// A prepared tree of one exact variant: upstream commit, that variant's
// ordered patches applied to the working tree, provenance next to the git
// metadata, and a lock beside it. The upstream tree carries the source's
// own desktop builder entry so the wrapper can require it.
async function makeFixture({ trackedFixture = false, variant = "managed-nightly" } = {}) {
  const root = await realpath(await mkdtemp(path.join(tmpdir(), "t3-desktop-builder-")));
  const lockDir = path.join(root, "lock");
  const patches = [];
  for (const [id, text] of Object.entries(PATCHES)) {
    const rel = path.join("patches", `${id}.patch`);
    await write(lockDir, { [rel]: text });
    patches.push({ id, path: rel, sha256: sha256Hex(text) });
  }
  const source = path.join(root, "upstream");
  await mkdir(source);
  await write(source, {
    "package.json": json({ name: "@t3tools/monorepo", private: true, packageManager: "pnpm@11.10.0" }),
    "pnpm-workspace.yaml": "packages:\n  - apps/*\n",
    "pnpm-lock.yaml": "lockfileVersion: '9.0'\nimporters:\n  .: {}\n",
    ".gitignore": "node_modules\napps/*/dist\napps/desktop/dist-electron\n.env\n.env.local\nnative/**/target/\n",
    ".env.example": "T3CODE_RELAY_URL=\n",
    "scripts/build-desktop-artifact.ts": "// the source tree's desktop builder (stub)\nexport {};\n",
    "apps/server/package.json": json({ name: "t3", version: "0.0.38", type: "module", bin: { t3: "./dist/bin.mjs" } }),
    "apps/web/package.json": json({ name: "@t3tools/web", version: "0.0.38", private: true }),
    "apps/desktop/package.json": json({ name: "@t3tools/desktop", version: "0.0.38", main: "dist-electron/main.cjs" }),
    "packages/contracts/package.json": json({ name: "@t3tools/contracts", version: "0.0.38", exports: {} }),
    one: "one\n",
    two: "two\n",
    identity: "stock\n",
  });
  await git(source, ["init", "-q", "-b", "main"]);
  await git(source, ["add", "-A"]);
  if (trackedFixture) {
    await write(source, { "vendor/compiler/cases/node_modules/example/index.js": "export default 42;\n" });
    await git(source, ["add", "-f", "vendor/compiler/cases/node_modules/example/index.js"]);
  }
  await git(source, ["commit", "-q", "-m", "upstream"]);
  const commit = (await git(source, ["rev-parse", "HEAD"])).stdout.trim();

  const lockPath = path.join(lockDir, "source.lock.json");
  const lock = {
    version: 2,
    repository: "https://example.invalid/t3code.git",
    commit,
    patches,
    variants: {
      "managed-nightly": ["reasoning-full", "desktop-runtime-common"],
      reasoning: ["reasoning-full", "desktop-runtime-common", "reasoning-identity"],
    },
  };
  await writeFile(lockPath, json(lock));
  const applied = lock.variants[variant].map((id) => patches.find((p) => p.id === id));
  for (const patch of applied) await git(source, ["apply"], PATCHES[patch.id]);
  const gitDir = (await git(source, ["rev-parse", "--absolute-git-dir"])).stdout.trim();
  const provenance = { preparedAt: "2026-09-05T00:00:00.000Z", lock: lockPath, lockRepository: lock.repository, repository: source, commit, variant, patches: applied };
  await writeFile(path.join(gitDir, "harbor-source.json"), json(provenance));

  const descriptor = resolveManagedRelease({
    lock: await readVerifiedLock(lockPath),
    upstreamVersion: UPSTREAM_VERSION,
    releaseCounter: 1,
    builderRevision: BUILDER_REVISION,
    publicConfig: PUBLIC_CONFIG,
  });
  const out = path.join(root, "out");
  const tmpRoot = path.join(root, "tmp");
  await mkdir(out);
  await mkdir(tmpRoot);
  // Deterministic but distinctive archive bytes: the published copy must be these.
  const zipBytes = Buffer.concat([Buffer.from("PK\x03\x04"), Buffer.from(`fixture zip for ${variant} ${descriptor.releaseVersion}\n`), Buffer.alloc(64, 7)]);
  return { root, source, lockPath, lockDir, gitDir, commit, descriptor, variant, artifact: DESKTOP[variant], out, tmpRoot, provenance, zipBytes, calls: [], seen: {} };
}

// --- the fake process seam --------------------------------------------------------------

// The `.app` tree ditto would leave behind, shaped per fixture options.
async function materializeApp(fx, dir, opts) {
  const { artifact } = fx;
  const appName = opts.appName ?? `${artifact.productName}.app`;
  const exeName = opts.exeName ?? artifact.productName;
  const apps = opts.noApp ? [] : [appName, ...(opts.extraApp ? ["Other.app"] : [])];
  for (const name of apps) {
    const app = path.join(dir, name);
    await write(app, {
      "Contents/Info.plist": Buffer.from("bplist00\x00fixture"),
      "Contents/Frameworks/Electron Framework.framework/Versions/A/Electron Framework": "framework\n",
      ...(opts.omitAsar ? {} : { "Contents/Resources/app.asar": opts.emptyAsar ? "" : "asar bytes\n" }),
      ...(opts.includeFeed ? { "Contents/Resources/app-update.yml": "provider: github\n" } : {}),
      ...(opts.omitExecutable ? {} : { [`Contents/MacOS/${exeName}`]: opts.header ?? HEADERS.arm64 }),
    });
    await symlink("A", path.join(app, "Contents/Frameworks/Electron Framework.framework/Versions/Current"));
    if (opts.escapingLink) await symlink("../../../../../..", path.join(app, "Contents/Frameworks/escape"));
    if (!opts.omitExecutable) await chmod(path.join(app, `Contents/MacOS/${exeName}`), opts.nonExecutable ? 0o644 : 0o755);
  }
  if (opts.extraTopLevel) await writeFile(path.join(dir, "README.txt"), "stray\n");
  fx.appExecutable = path.join(dir, appName, "Contents/MacOS", exeName);
  fx.app = path.join(dir, appName);
}

function plistFor(fx, opts) {
  const { artifact } = fx;
  const version = fx.descriptor.releaseVersion;
  const base = {
    CFBundleIdentifier: artifact.bundleId,
    CFBundleDisplayName: artifact.productName,
    CFBundleName: artifact.productName,
    CFBundleExecutable: artifact.productName,
    CFBundlePackageType: "APPL",
    CFBundleShortVersionString: version,
    CFBundleVersion: version,
    LSMinimumSystemVersion: "12.0",
    CFBundleURLTypes: [{ CFBundleURLName: artifact.bundleId, CFBundleURLSchemes: [...artifact.urlSchemes] }],
  };
  return typeof opts.plist === "function" ? opts.plist(base) : { ...base, ...(opts.plist ?? {}) };
}

// The desktop build step is the one `pnpm exec` call.
function isBuildCall({ command, args }) {
  return command === "pnpm" && args[0] === "exec";
}

function fakeRunner(fx, opts = {}) {
  return async (spec) => {
    fx.calls.push(spec);
    const { command, args } = spec;
    assert.equal(spec.shell, undefined, "the runner spec never asks for a shell");
    if (command === "git") return realRunner(spec);
    if (command === "pnpm") {
      if (args[0] === "--version") return { stdout: `${opts.pnpmVersion ?? "11.10.0"}\n`, stderr: "" };
      if (args[0] === "install") {
        fx.seen.versionAtInstall = JSON.parse(await readFile(path.join(fx.source, "apps/desktop/package.json"), "utf8")).version;
        if (opts.installMutatesLock) await writeFile(path.join(fx.source, "pnpm-lock.yaml"), "lockfileVersion: '9.0'\nimporters:\n  .: {}\ntouched: true\n");
        return { stdout: "", stderr: "" };
      }
    }
    if (isBuildCall(spec)) {
      // `pnpm exec <node> scripts/build-desktop-artifact.ts ...`: the explicit
      // Node executable runs the source tree's own builder with the project
      // bin directory on PATH, as a package script would see it.
      assert.equal(args[1], FAKE_NODE, "pnpm exec runs the explicit Node executable");
      assert.equal(args[2], "scripts/build-desktop-artifact.ts", "the source tree's own builder runs");
      const env = parseEnv(await readFile(path.join(fx.source, ".env"), "utf8"));
      assert.deepEqual(env, PUBLIC_CONFIG, "the build sees exactly the four public values in .env");
      const outputDir = args[args.indexOf("--output-dir") + 1];
      const version = args[args.indexOf("--build-version") + 1];
      if (opts.buildMutatesManifest) {
        const file = path.join(fx.source, "apps/desktop/package.json");
        await writeFile(file, json({ ...JSON.parse(await readFile(file, "utf8")), version: "9.9.9" }));
      }
      if (opts.buildFails) {
        const error = new Error("build exited with 1");
        Object.assign(error, { stdout: "", stderr: "electron-builder: boom\n", code: 1 });
        throw error;
      }
      const names = opts.zipNames ?? [`${fx.artifact.productName.replace(/[^A-Za-z0-9]+/g, "-").replace(/-$/, "")}-${version}-arm64-mac.zip`];
      for (const name of names) await writeFile(path.join(outputDir, name), fx.zipBytes);
      if (opts.feedFile) await writeFile(path.join(outputDir, opts.feedFile), `version: ${version}\n`);
      if (opts.extraOutput) await writeFile(path.join(outputDir, opts.extraOutput), "debug\n");
      return { stdout: "", stderr: "" };
    }
    if (command === DITTO) {
      assert.deepEqual(args.slice(0, 2), ["-x", "-k"], "ditto extracts the archive shell-free");
      const [zip, dir] = args.slice(2);
      assert.equal(args.length, 4);
      assert.ok(zip.endsWith(".zip"));
      assert.deepEqual(await readFile(zip), fx.zipBytes, "ditto receives the archive the build emitted");
      assert.deepEqual(await readdir(dir), [], "the extraction directory is owned and empty");
      if (opts.extractFails) {
        const error = new Error("ditto exited with 1");
        Object.assign(error, { stdout: "", stderr: "ditto: Couldn't read PKZip signature.\n", code: 1 });
        throw error;
      }
      await materializeApp(fx, dir, opts);
      return { stdout: "", stderr: "" };
    }
    if (command === PLUTIL) {
      assert.deepEqual(args.slice(0, 5), ["-convert", "json", "-o", "-", "--"], "plutil prints the plist as JSON to stdout");
      assert.equal(args.length, 6);
      assert.equal(args[5], path.join(fx.app, "Contents/Info.plist"), "the plist read is the extracted bundle's");
      assert.deepEqual(await readFile(args[5]), Buffer.from("bplist00\x00fixture"));
      if (opts.plutilFails) {
        const error = new Error("plutil exited with 1");
        Object.assign(error, { stdout: "", stderr: "Property List error\n", code: 1 });
        throw error;
      }
      return { stdout: opts.plutilOutput ?? JSON.stringify(plistFor(fx, opts)), stderr: "" };
    }
    if (fx.appExecutable !== undefined && command === fx.appExecutable) {
      assert.deepEqual(args, [path.join(fx.app, "Contents/Resources/app.asar/apps/server/dist/bin.mjs"), "--version"]);
      assert.equal(spec.env.ELECTRON_RUN_AS_NODE, "1", "the packaged runtime runs as Node");
      if (opts.embeddedFails) {
        const error = new Error("electron exited with 1");
        Object.assign(error, { stdout: "", stderr: "Error: Cannot find module 'apps/server/dist/bin.mjs'\n", code: 1 });
        throw error;
      }
      return { stdout: `${opts.embeddedIdentity ?? `t3 v${fx.descriptor.releaseVersion}`}\n`, stderr: "" };
    }
    throw new Error(`unexpected command ${command} ${args.join(" ")}`);
  };
}

function build(fx, opts = {}, overrides = {}) {
  return buildManagedDesktopRuntime({
    source: fx.source,
    descriptor: fx.descriptor,
    publicConfig: PUBLIC_CONFIG,
    variant: fx.variant,
    destination: path.join(fx.out, "release"),
    run: fakeRunner(fx, opts),
    host: HOST,
    env: {
      PATH: process.env.PATH,
      HOME: process.env.HOME,
      VITE_T3CODE_RELAY_URL: "https://ambient.invalid",
      NODE_OPTIONS: "--trace-warnings",
      ELECTRON_RUN_AS_NODE: "1",
      T3CODE_DESKTOP_SIGNED: "1",
      T3CODE_DESKTOP_SKIP_BUILD: "1",
      T3CODE_DESKTOP_MOCK_UPDATES: "1",
      T3CODE_PRODUCT_VARIANT: "stock",
      GITHUB_REPOSITORY: "t3dotgg/t3code",
      CSC_LINK: "/fixture/cert.p12",
    },
    node: FAKE_NODE,
    tmpRoot: fx.tmpRoot,
    ...overrides,
  });
}

function commandLabel(fx, { command, args }) {
  if (command === "git") return "git";
  if (isBuildCall({ command, args })) return `pnpm exec ${args[1] === FAKE_NODE ? "node" : args[1]} ${args[2]}`;
  if (command === "pnpm") return `pnpm ${args[0]}`;
  if (command === DITTO) return "ditto";
  if (command === PLUTIL) return "plutil";
  if (command === fx.appExecutable) return `electron ${args.at(-1)}`;
  return command;
}

// Nothing published, no staging or lock left, the task-owned .env gone, and
// the work directory (index, build output, extraction, home) removed.
async function assertNothingPublished(fx) {
  assert.deepEqual(await readdir(fx.out), []);
  assert.deepEqual(await readdir(fx.tmpRoot), []);
  assert.deepEqual((await readdir(fx.source)).filter((n) => n.startsWith(".env")), [".env.example"]);
}

async function refusal(fx, opts, pattern, { beforeMutation = false, overrides = {} } = {}) {
  await rejects(() => build(fx, opts, overrides), pattern);
  await assertNothingPublished(fx);
  if (beforeMutation) {
    for (const relative of RELEASE_PACKAGE_FILES) {
      assert.equal(JSON.parse(await readFile(path.join(fx.source, relative), "utf8")).version, "0.0.38", `${relative} is not stamped`);
    }
    assert.ok(fx.calls.every((c) => c.command === "git" || (c.command === "pnpm" && c.args[0] === "--version")), "only git and pnpm --version ran");
  }
}

// --- fixed identity and pure checks ----------------------------------------------------

describe("fixed identity", () => {
  it("selects exactly the desktop artifact of the named variant and nothing the caller supplies", () => {
    assert.equal(selectDesktopArtifact("managed-nightly").id, "managed-nightly-darwin-arm64");
    assert.equal(selectDesktopArtifact("managed-nightly").bundleId, "com.t3tools.t3code");
    assert.equal(selectDesktopArtifact("reasoning").id, "reasoning-darwin-arm64");
    assert.equal(selectDesktopArtifact("reasoning").bundleId, "com.t3tools.t3code.reasoning");
    assert.deepEqual(selectDesktopArtifact("reasoning").urlSchemes, ["t3code-reasoning"]);
    for (const value of ["common", "stock", "", undefined, null, "MANAGED-NIGHTLY"]) {
      throws(() => selectDesktopArtifact(value), /names no desktop artifact; expected one of managed-nightly, reasoning/);
    }
  });

  it("requires a darwin-arm64 host on the pinned Node", () => {
    requireDesktopHost(HOST);
    throws(() => requireDesktopHost({ ...HOST, platform: "linux" }), /only on a darwin-arm64 host; this host is linux-arm64/);
    throws(() => requireDesktopHost({ ...HOST, arch: "x64" }), /this host is darwin-x64/);
    throws(() => requireDesktopHost({ ...HOST, nodeVersion: "24.13.0" }), /require Node 24\.13\.1; this host runs 24\.13\.0/);
  });

  it("hands the source builder exactly the unsigned full-build ZIP arguments", () => {
    assert.deepEqual(desktopBuildArguments("1.2.3", "/tmp/out"), [
      "scripts/build-desktop-artifact.ts", "--platform", "mac", "--target", "zip", "--arch", "arm64", "--build-version", "1.2.3", "--output-dir", "/tmp/out",
    ]);
    assert.deepEqual(desktopBuildExecArguments("/opt/node", "1.2.3", "/tmp/out"), [
      "exec", "/opt/node", "scripts/build-desktop-artifact.ts", "--platform", "mac", "--target", "zip", "--arch", "arm64", "--build-version", "1.2.3", "--output-dir", "/tmp/out",
    ], "pnpm exec runs the explicit Node executable, then the builder arguments unchanged");
  });

  it("requires the decoded plist to carry the fixed identity, the release version, and exactly the expected schemes", () => {
    const artifact = DESKTOP.reasoning;
    const good = () => ({
      CFBundleIdentifier: artifact.bundleId,
      CFBundleDisplayName: artifact.productName,
      CFBundleName: artifact.productName,
      CFBundleExecutable: artifact.productName,
      CFBundleShortVersionString: "1.2.3",
      CFBundleVersion: "1.2.3",
      CFBundleURLTypes: [{ CFBundleURLSchemes: ["t3code-reasoning"] }],
    });
    assert.deepEqual(checkBundlePlist(good(), artifact, "1.2.3"), ["t3code-reasoning"]);
    const nightly = DESKTOP["managed-nightly"];
    const nightlyPlist = { ...good(), CFBundleIdentifier: nightly.bundleId, CFBundleDisplayName: nightly.productName, CFBundleName: nightly.productName, CFBundleExecutable: nightly.productName, CFBundleURLTypes: [{ CFBundleURLSchemes: ["t3code-dev"] }, { CFBundleURLSchemes: ["t3code"] }] };
    assert.deepEqual(checkBundlePlist(nightlyPlist, nightly, "1.2.3"), ["t3code-dev", "t3code"], "scheme order across URL types is not significant");
    const check = (mutate, pattern) => {
      const plist = good();
      mutate(plist);
      throws(() => checkBundlePlist(plist, artifact, "1.2.3"), pattern);
    };
    check((p) => { p.CFBundleIdentifier = "com.t3tools.t3code"; }, /CFBundleIdentifier is "com\.t3tools\.t3code", expected "com\.t3tools\.t3code\.reasoning"/);
    check((p) => { p.CFBundleDisplayName = "T3 Code"; }, /CFBundleDisplayName is "T3 Code", expected "T3 Code \(Reasoning\)"/);
    check((p) => { p.CFBundleName = "T3 Code"; }, /CFBundleName is "T3 Code"/);
    check((p) => { p.CFBundleExecutable = "T3 Code"; }, /CFBundleExecutable is "T3 Code"/);
    check((p) => { p.CFBundleShortVersionString = "1.2.4"; }, /CFBundleShortVersionString is "1\.2\.4", expected "1\.2\.3"/);
    check((p) => { p.CFBundleVersion = "0.0.38"; }, /CFBundleVersion is "0\.0\.38"/);
    check((p) => { delete p.CFBundleVersion; }, /CFBundleVersion is undefined/);
    check((p) => { p.CFBundleURLTypes[0].CFBundleURLSchemes.push("t3code"); }, /URL schemes are t3code-reasoning, t3code; expected exactly t3code-reasoning/);
    check((p) => { p.CFBundleURLTypes.push({ CFBundleURLSchemes: ["t3code-reasoning"] }); }, /URL schemes are t3code-reasoning, t3code-reasoning; expected exactly t3code-reasoning/);
    check((p) => { p.CFBundleURLTypes[0].CFBundleURLSchemes = []; }, /URL schemes are \(none\); expected exactly t3code-reasoning/);
    check((p) => { delete p.CFBundleURLTypes; }, /CFBundleURLTypes is missing/);
    check((p) => { p.CFBundleURLTypes = [{}]; }, /CFBundleURLTypes\[0\] has no CFBundleURLSchemes list/);
    check((p) => { p.CFBundleURLTypes[0].CFBundleURLSchemes = [1]; }, /non-string scheme/);
    throws(() => checkBundlePlist([], artifact, "1.2.3"), /did not decode to a dictionary/);
  });

  it("accepts only a thin Mach-O arm64 executable header", () => {
    checkMachOArm64Executable(HEADERS.arm64, "exe");
    for (const name of ["x64", "dylib", "fat", "script", "short"]) {
      throws(() => checkMachOArm64Executable(HEADERS[name], "exe"), /exe is not a thin Mach-O 64-bit arm64 executable/);
    }
  });
});

// --- the whole sequence --------------------------------------------------------------------

describe("buildManagedDesktopRuntime", () => {
  for (const variant of VARIANTS) {
    it(`builds, verifies, and publishes the ${variant} ZIP with commands in the designed order`, async () => {
      const fx = await makeFixture({ variant });
      const result = await build(fx);
      const destination = path.join(fx.out, "release");
      const version = fx.descriptor.releaseVersion;
      const expected = DESKTOP[variant];
      const file = `${expected.id}-${version}.zip`;
      assert.equal(result.file, file);
      assert.equal(result.destination, destination);
      assert.deepEqual((await readdir(destination)).sort(), [file, `${expected.id}-${version}.inventory.json`].sort());
      assert.deepEqual(await readdir(fx.out), ["release"], "no staging or lock is left beside the destination");

      // Fixed inventory record, nothing else; the hash and size cover the published bytes.
      const record = { ...expected, urlSchemes: [...expected.urlSchemes], file, version, embeddedServerVersion: version };
      assert.equal(await readFile(path.join(destination, `${expected.id}-${version}.inventory.json`), "utf8"), canonicalJson(record));
      assert.deepEqual(result.inventory, record);
      assert.deepEqual(Object.keys(result.inventory).sort(), [...Object.keys(expected), "file", "version", "embeddedServerVersion"].sort());
      const published = await readFile(path.join(destination, file));
      assert.deepEqual(published, fx.zipBytes, "the published ZIP is the archive ditto inspected, byte for byte");
      assert.equal(result.sha256, sha256Hex(published));
      assert.equal(result.bytes, published.length);

      // Order: source proof (git), stamp (in-process, before install), frozen install, full build, extraction, plist, embedded server, publish.
      assert.deepEqual(
        fx.calls.map((c) => commandLabel(fx, c)).filter((l) => l !== "git"),
        ["pnpm --version", "pnpm install", "pnpm exec node scripts/build-desktop-artifact.ts", "ditto", "plutil", "electron --version"],
      );
      assert.ok(fx.calls.some((c) => c.command === "git" && c.args.includes("write-tree")), "the source proof ran");
      const lastGit = fx.calls.map((c) => c.command).lastIndexOf("git");
      const install = fx.calls.findIndex((c) => c.command === "pnpm" && c.args[0] === "install");
      assert.ok(lastGit < install, "the proof completes before the frozen install");
      assert.equal(fx.seen.versionAtInstall, version, "manifests are stamped before the frozen install");
      const installCall = fx.calls[install];
      assert.deepEqual(installCall.args, ["install", "--frozen-lockfile"]);
      assert.equal(installCall.cwd, fx.source);

      // The source builder: `pnpm exec` with the explicit Node executable and exact arguments, an owned output directory
      // inside the work directory, the sanitized environment. Node is never spawned directly: only pnpm exec puts the
      // tree's node_modules/.bin (where the builder finds `vp`) on PATH.
      const buildCall = fx.calls.find((c) => isBuildCall(c));
      const outputDir = buildCall.args.at(-1);
      assert.deepEqual(buildCall.args, ["exec", FAKE_NODE, ...desktopBuildArguments(version, outputDir)]);
      assert.deepEqual(buildCall.args, desktopBuildExecArguments(FAKE_NODE, version, outputDir));
      assert.ok(outputDir.startsWith(`${fx.tmpRoot}${path.sep}t3-managed-desktop-`), "build output is owned by the work directory");
      assert.equal(buildCall.cwd, fx.source);
      assert.ok(fx.calls.every((c) => c.command !== FAKE_NODE), "the Node executable is only ever run through pnpm exec");
      assert.equal(fx.calls.filter((c) => isBuildCall(c)).length, 1, "the source builder runs exactly once");
      for (const call of fx.calls.filter((c) => c.command === "pnpm")) {
        assert.equal(call.env.T3CODE_PRODUCT_VARIANT, variant, "the child product variant is the selected variant");
        assert.equal(call.env.T3CODE_RELAY_URL, PUBLIC_CONFIG.T3CODE_RELAY_URL);
        for (const key of ["VITE_T3CODE_RELAY_URL", "NODE_OPTIONS", "ELECTRON_RUN_AS_NODE", "T3CODE_DESKTOP_SIGNED", "T3CODE_DESKTOP_SKIP_BUILD", "T3CODE_DESKTOP_MOCK_UPDATES", "GITHUB_REPOSITORY"]) {
          assert.equal(call.env[key], undefined, `${key} is scrubbed`);
        }
        assert.equal(call.env.CSC_LINK, "/fixture/cert.p12", "ordinary tool environment passes through; signing is the source builder's default-off concern");
      }

      // Nothing forbidden: no skip/signed/mock/publish flags, no shell, no package provider, no remote publication.
      for (const call of fx.calls) {
        assert.ok(ALLOWED_COMMANDS.has(call.command) || call.command === fx.appExecutable, `unexpected command ${call.command}`);
        for (const arg of call.args) assert.ok(!FORBIDDEN_ARGS.includes(arg), `${call.command} carries ${arg}`);
      }

      // Verification children run under a disposable HOME from an unrelated cwd with a minimal environment.
      for (const call of fx.calls.filter((c) => c.command === DITTO || c.command === PLUTIL)) {
        assert.deepEqual(Object.keys(call.env).sort(), ["HOME", "PATH", "TMPDIR"]);
        assert.notEqual(call.env.HOME, process.env.HOME);
        assert.notEqual(call.cwd, fx.source);
      }
      const electron = fx.calls.find((c) => c.command === fx.appExecutable);
      assert.deepEqual(Object.keys(electron.env).sort(), ["ELECTRON_RUN_AS_NODE", "HOME", "PATH", "TMPDIR"]);
      assert.notEqual(electron.env.HOME, process.env.HOME);
      assert.notEqual(electron.cwd, fx.source);
      assert.ok(fx.appExecutable.endsWith(path.join(`${expected.productName}.app`, "Contents", "MacOS", expected.productName)));

      // The disposable tree keeps its stamped versions and loses the task-owned .env; the work directory is gone.
      for (const relative of RELEASE_PACKAGE_FILES) {
        assert.equal(JSON.parse(await readFile(path.join(fx.source, relative), "utf8")).version, version, `${relative} is stamped`);
      }
      assert.deepEqual((await readdir(fx.source)).filter((n) => n.startsWith(".env")), [".env.example"]);
      assert.deepEqual(await readdir(fx.tmpRoot), [], "the private work directory is removed");
      await rm(fx.root, { recursive: true, force: true });
    });
  }

  it("ignores stray non-feed build output beside the single ZIP", async () => {
    const fx = await makeFixture();
    await build(fx, { extraOutput: "builder-debug.yml" });
    await rm(fx.root, { recursive: true, force: true });
  });

  it("refuses to publish over an existing destination or while another publisher holds the lock, without mutating either", async () => {
    const fx = await makeFixture();
    const destination = path.join(fx.out, "release");
    await mkdir(destination);
    await writeFile(path.join(destination, "keep.txt"), "kept\n");
    await rejects(() => build(fx), /already exists/);
    assert.deepEqual(await readdir(destination), ["keep.txt"]);
    assert.ok(fx.calls.every((c) => c.command === "git" || (c.command === "pnpm" && c.args[0] === "--version")), "only verification commands ran");
    await rm(destination, { recursive: true });
    await mkdir(`${destination}.lock`);
    await rejects(() => build(fx), /another publisher holds/);
    assert.deepEqual(await readdir(fx.out), ["release.lock"], "a foreign lock is never removed");
    assert.deepEqual((await readdir(fx.source)).filter((n) => n.startsWith(".env")), [".env.example"]);
    assert.deepEqual(await readdir(fx.tmpRoot), []);
    await rm(fx.root, { recursive: true, force: true });
  });

  it("never prints or embeds public config values in errors", async () => {
    const fx = await makeFixture();
    const error = await build(fx, {}, { publicConfig: { ...PUBLIC_CONFIG, T3CODE_RELAY_URL: "https://other.invalid" } }).then(
      () => assert.fail("must refuse"),
      (e) => e,
    );
    assert.match(error.message, /fingerprint does not match/);
    assert.doesNotMatch(error.message, /fixture|other\.invalid|pk_test/);
    await rm(fx.root, { recursive: true, force: true });
  });
});

describe("tracked dependency fixtures", () => {
  for (const variant of ["managed-nightly", "reasoning"]) {
    it(`accepts a pristine tracked node_modules fixture for ${variant}`, async () => {
      const fx = await makeFixture({ trackedFixture: true, variant });
      try {
        await build(fx);
        assert.ok(fx.calls.some((call) => call.command === "pnpm" && call.args[0] === "install"));
      } finally {
        await rm(fx.root, { recursive: true, force: true });
      }
    });

    it(`rejects stale additions inside a tracked node_modules fixture for ${variant}`, async () => {
      for (const addition of ["example/stale.js", "empty-directory", "external-link", "dangling-link"]) {
        const fx = await makeFixture({ trackedFixture: true, variant });
        const relative = `vendor/compiler/cases/node_modules/${addition}`;
        try {
          if (addition === "empty-directory") await mkdir(path.join(fx.source, relative));
          else if (addition === "external-link") await symlink(fx.lockDir, path.join(fx.source, relative));
          else if (addition === "dangling-link") await symlink("missing", path.join(fx.source, relative));
          else await write(fx.source, { [relative]: "stale bytes\n" });
          await refusal(fx, {}, /source already contains .*node_modules/, { beforeMutation: true });
          assert.ok(await lstat(path.join(fx.source, relative)), "the rejected entry remains untouched");
        } finally {
          await rm(fx.root, { recursive: true, force: true });
        }
      }
    });
  }
});

describe("refusals before any mutation", () => {
  it("descriptor, public config, variant, host, and toolchain disagreements", async () => {
    const fx = await makeFixture();
    const tampered = structuredClone(fx.descriptor);
    tampered.builderRevision = "b".repeat(40);
    await rejects(() => build(fx, {}, { descriptor: tampered }), /does not match the digest recomputed/);
    await rejects(() => build(fx, {}, { publicConfig: { ...PUBLIC_CONFIG, T3CODE_RELAY_URL: "https://other.invalid" } }), /fingerprint does not match/);
    await rejects(() => build(fx, {}, { variant: "common" }), /variant "common" names no desktop artifact/);
    await rejects(() => build(fx, {}, { variant: "stock" }), /variant "stock" names no desktop artifact/);
    await rejects(() => build(fx, {}, { variant: undefined }), /names no desktop artifact/);
    await rejects(() => build(fx, {}, { host: { platform: "linux", arch: "x64", nodeVersion: PINNED_NODE_VERSION } }), /only on a darwin-arm64 host; this host is linux-x64/);
    await rejects(() => build(fx, {}, { host: { ...HOST, arch: "x64" } }), /this host is darwin-x64/);
    await rejects(() => build(fx, {}, { host: { ...HOST, nodeVersion: "22.19.0" } }), /require Node 24\.13\.1/);
    assert.deepEqual(fx.calls, [], "nothing ran");
    await rejects(() => build(fx, { pnpmVersion: "10.33.2" }), /is version 10\.33\.2; the source pins pnpm@11\.10\.0/);
    assert.ok(fx.calls.every((c) => c.command === "pnpm" && c.args[0] === "--version"), "only pnpm --version ran");
    await assertNothingPublished(fx);
    for (const relative of RELEASE_PACKAGE_FILES) assert.equal(JSON.parse(await readFile(path.join(fx.source, relative), "utf8")).version, "0.0.38");
    await rm(fx.root, { recursive: true, force: true });
  });

  it("a source without the desktop builder, with another package manager, env files, prior build state, or non-disposable paths", async () => {
    const fx = await makeFixture();
    await writeFile(path.join(fx.source, "package.json"), json({ name: "@t3tools/monorepo", packageManager: "pnpm@10.33.2" }));
    await refusal(fx, {}, /declares packageManager pnpm@10\.33\.2/, { beforeMutation: true });
    await writeFile(path.join(fx.source, "package.json"), json({ name: "@t3tools/monorepo", private: true, packageManager: "pnpm@11.10.0" }));
    await rm(path.join(fx.source, "scripts/build-desktop-artifact.ts"));
    await refusal(fx, {}, /source desktop builder: missing .*scripts\/build-desktop-artifact\.ts/, { beforeMutation: true });
    await writeFile(path.join(fx.source, "scripts/build-desktop-artifact.ts"), "// the source tree's desktop builder (stub)\nexport {};\n");
    await writeFile(path.join(fx.source, ".env"), "T3CODE_RELAY_URL=https://user.invalid\n");
    await rejects(() => build(fx), /already contains \.env;/);
    assert.equal(await readFile(path.join(fx.source, ".env"), "utf8"), "T3CODE_RELAY_URL=https://user.invalid\n", "a user env file is never removed");
    await rm(path.join(fx.source, ".env"));
    await writeFile(path.join(fx.source, "apps/web/.env.production"), "VITE_X=1\n");
    await rejects(() => build(fx), /already contains apps\/web\/\.env\.production/);
    await rm(path.join(fx.source, "apps/web/.env.production"));
    await write(fx.source, { "node_modules/.modules.yaml": "hoistPattern: []\n" });
    await refusal(fx, {}, /source already contains node_modules; a fresh prepared source tree/, { beforeMutation: true });
    await rm(path.join(fx.source, "node_modules"), { recursive: true });
    await write(fx.source, { "apps/desktop/node_modules/electron/index.js": "" });
    await refusal(fx, {}, /source already contains apps\/desktop\/node_modules/, { beforeMutation: true });
    await rm(path.join(fx.source, "apps/desktop/node_modules"), { recursive: true });
    assert.ok(fx.calls.every((c) => c.command === "git" || (c.command === "pnpm" && c.args[0] === "--version")), "only verification commands ran");
    await rejects(() => build(fx, {}, { destination: path.join(fx.source, "out") }), /must be disjoint/);
    await rejects(() => build(fx, {}, { tmpRoot: fx.source }), /must be disjoint/);
    await assertNothingPublished(fx);
    await rm(fx.root, { recursive: true, force: true });
  });

  it("a prepared tree whose variant, provenance, lock, HEAD, or content disagree with the selected variant", async () => {
    // Each variant's tree is refused when built as the other variant, before any stamp or install.
    const nightly = await makeFixture({ variant: "managed-nightly" });
    await refusal(nightly, {}, /variant is "managed-nightly"; this build requires a reasoning tree/, { beforeMutation: true, overrides: { variant: "reasoning" } });
    assert.equal(await readFile(path.join(nightly.source, "identity"), "utf8"), "stock\n");
    const reasoning = await makeFixture({ variant: "reasoning" });
    await refusal(reasoning, {}, /variant is "reasoning"; this build requires a managed-nightly tree/, { beforeMutation: true, overrides: { variant: "managed-nightly" } });
    assert.equal(await readFile(path.join(reasoning.source, "identity"), "utf8"), "reasoning\n");
    await rm(reasoning.root, { recursive: true, force: true });

    // Provenance that claims reasoning over a managed-nightly tree is caught on patches, then on content.
    const provenanceFile = path.join(nightly.gitDir, "harbor-source.json");
    await writeFile(provenanceFile, json({ ...nightly.provenance, variant: "reasoning" }));
    await refusal(nightly, {}, /patches do not match the lock's ordered reasoning sequence/, { beforeMutation: true, overrides: { variant: "reasoning" } });
    const reasoningPatches = ["reasoning-full", "desktop-runtime-common", "reasoning-identity"].map((id) => ({ id, path: path.join("patches", `${id}.patch`), sha256: sha256Hex(PATCHES[id]) }));
    await writeFile(provenanceFile, json({ ...nightly.provenance, variant: "reasoning", patches: reasoningPatches }));
    await refusal(nightly, {}, /content differs from .* plus the ordered reasoning patches .* M\tidentity/, { beforeMutation: true, overrides: { variant: "reasoning" } });
    await writeFile(provenanceFile, json(nightly.provenance));

    // The ordinary disagreements, as the selected variant.
    await writeFile(provenanceFile, json({ ...nightly.provenance, commit: "1".repeat(40) }));
    await refusal(nightly, {}, /records commit 1{40}/, { beforeMutation: true });
    await writeFile(provenanceFile, json({ ...nightly.provenance, patches: nightly.provenance.patches.slice(0, 1) }));
    await refusal(nightly, {}, /patches do not match the lock's ordered managed-nightly sequence/, { beforeMutation: true });
    await writeFile(provenanceFile, json(nightly.provenance));
    await writeFile(path.join(nightly.lockDir, "patches/desktop-runtime-common.patch"), "tampered\n");
    await refusal(nightly, {}, /sha256 mismatch/, { beforeMutation: true });
    await writeFile(path.join(nightly.lockDir, "patches/desktop-runtime-common.patch"), PATCHES["desktop-runtime-common"]);
    await writeFile(path.join(nightly.source, "two"), "two edited after preparation\n");
    await refusal(nightly, {}, /content differs from .* plus the ordered managed-nightly patches \(1 path\(s\)\): M\ttwo/, { beforeMutation: true });
    await writeFile(path.join(nightly.source, "two"), "two patched\n");
    await writeFile(path.join(nightly.source, "scripts/extra-input.ts"), "export {};\n");
    await refusal(nightly, {}, /content differs .* A\tscripts\/extra-input\.ts/, { beforeMutation: true });
    await rm(path.join(nightly.source, "scripts/extra-input.ts"));
    await git(nightly.source, ["commit", "-q", "-am", "committed patches"]);
    await refusal(nightly, {}, /HEAD .* is not the descriptor's upstream commit/, { beforeMutation: true });
    await rm(nightly.root, { recursive: true, force: true });
  });
});

describe("failures after mutation publish nothing and clean up", () => {
  const nightlyId = "com\\.t3tools\\.t3code";
  const cases = [
    ["the frozen install rewrites the lock", { installMutatesLock: true }, /pnpm install modified pnpm-lock\.yaml/, "pnpm install"],
    ["the desktop build rewrites a stamped manifest", { buildMutatesManifest: true }, /desktop artifact build modified apps\/desktop\/package\.json/, "pnpm exec node scripts/build-desktop-artifact.ts"],
    ["the desktop build fails", { buildFails: true }, /desktop artifact build failed: .*boom/, "pnpm exec node scripts/build-desktop-artifact.ts"],
    ["the build emits no ZIP", { zipNames: [] }, /emitted 0 ZIP archive\(s\) \(none\); expected exactly one/, "pnpm exec node scripts/build-desktop-artifact.ts"],
    ["the build emits two ZIPs", { zipNames: ["a.zip", "b.zip"] }, /emitted 2 ZIP archive\(s\) \(a\.zip, b\.zip\); expected exactly one/, "pnpm exec node scripts/build-desktop-artifact.ts"],
    ["the build emits an update feed beside the ZIP", { feedFile: "latest-mac.yml" }, /update feed metadata latest-mac\.yml; a managed build must not produce an update feed/, "pnpm exec node scripts/build-desktop-artifact.ts"],
    ["the build emits a channel feed beside the ZIP", { feedFile: "beta-mac.yml" }, /update feed metadata beta-mac\.yml/, "pnpm exec node scripts/build-desktop-artifact.ts"],
    ["extraction fails", { extractFails: true }, /ditto extraction failed: .*PKZip/, "ditto"],
    ["the archive holds no app", { noApp: true }, /holds 0 top-level \.app bundle\(s\) \(none\); expected exactly one/, "ditto"],
    ["the archive holds two apps", { extraApp: true }, /holds 2 top-level \.app bundle\(s\)/, "ditto"],
    ["the archive holds a stray top-level file", { extraTopLevel: true }, /unexpected top-level entries beside the bundle: README\.txt/, "ditto"],
    ["the app is named for another product", { appName: "T3 Code.app", exeName: "T3 Code" }, /extracted bundle is T3 Code\.app, expected T3 Code \(Nightly\)\.app/, "ditto"],
    ["a bundle link escapes the extracted tree", { escapingLink: true }, /escapes the stage/, "ditto"],
    ["plutil cannot read the plist", { plutilFails: true }, /plutil could not read Info\.plist: .*Property List error/, "plutil"],
    ["plutil prints something other than JSON", { plutilOutput: "<plist/>" }, /plutil did not print Info\.plist as JSON/, "plutil"],
    ["the bundle identifier is the Reasoning one", { plist: { CFBundleIdentifier: "com.t3tools.t3code.reasoning" } }, new RegExp(`CFBundleIdentifier is "${nightlyId}\\.reasoning", expected "${nightlyId}"`), "plutil"],
    ["the display name is stock", { plist: { CFBundleDisplayName: "T3 Code" } }, /CFBundleDisplayName is "T3 Code", expected "T3 Code \(Nightly\)"/, "plutil"],
    ["the bundle name is stock", { plist: { CFBundleName: "T3 Code" } }, /CFBundleName is "T3 Code"/, "plutil"],
    ["the executable name differs", { plist: { CFBundleExecutable: "T3 Code" } }, /CFBundleExecutable is "T3 Code"/, "plutil"],
    ["the short version is the upstream version", { plist: { CFBundleShortVersionString: "0.0.39-nightly.20260905.1284" } }, /CFBundleShortVersionString is "0\.0\.39-nightly\.20260905\.1284", expected "0\.0\.39-nightly\.20260905\.1284\.managed\.1\.p[0-9a-f]+"/, "plutil"],
    ["the bundle version is stale", { plist: { CFBundleVersion: "0.0.38" } }, /CFBundleVersion is "0\.0\.38"/, "plutil"],
    ["an extra stock scheme is registered", { plist: (p) => ({ ...p, CFBundleURLTypes: [...p.CFBundleURLTypes, { CFBundleURLSchemes: ["t3code-reasoning"] }] }) }, /URL schemes are t3code, t3code-dev, t3code-reasoning; expected exactly t3code, t3code-dev/, "plutil"],
    ["a scheme is duplicated", { plist: (p) => ({ ...p, CFBundleURLTypes: [...p.CFBundleURLTypes, { CFBundleURLSchemes: ["t3code"] }] }) }, /URL schemes are t3code, t3code-dev, t3code; expected exactly/, "plutil"],
    ["a scheme is missing", { plist: { CFBundleURLTypes: [{ CFBundleURLSchemes: ["t3code"] }] } }, /URL schemes are t3code; expected exactly t3code, t3code-dev/, "plutil"],
    ["no schemes are registered", { plist: { CFBundleURLTypes: [] } }, /URL schemes are \(none\)/, "plutil"],
    ["app-update.yml is packaged", { includeFeed: true }, /bundle contains Contents\/Resources\/app-update\.yml; a managed build must not carry an update feed/, "plutil"],
    ["app.asar is missing", { omitAsar: true }, /bundle application archive: missing .*app\.asar/, "plutil"],
    ["app.asar is empty", { emptyAsar: true }, /bundle application archive: .*app\.asar is empty/, "plutil"],
    ["the main executable is missing", { omitExecutable: true }, /bundle main executable: missing .*Contents\/MacOS\/T3 Code \(Nightly\)/, "plutil"],
    ["the main executable is not executable", { nonExecutable: true }, /bundle main executable .* is not executable/, "plutil"],
    ["the main executable is x86-64", { header: HEADERS.x64 }, /bundle main executable is not a thin Mach-O 64-bit arm64 executable/, "plutil"],
    ["the main executable is a fat binary", { header: HEADERS.fat }, /not a thin Mach-O 64-bit arm64 executable/, "plutil"],
    ["the main executable is a library", { header: HEADERS.dylib }, /not a thin Mach-O 64-bit arm64 executable/, "plutil"],
    ["the main executable is a script", { header: HEADERS.script }, /not a thin Mach-O 64-bit arm64 executable/, "plutil"],
    ["the embedded server reports the upstream version", { embeddedIdentity: "t3 v0.0.38" }, /embedded server reports version "t3 v0\.0\.38", expected "t3 v0\.0\.39-nightly\.20260905\.1284\.managed\.1\.p[0-9a-f]+"/, "electron --version"],
    ["the embedded server reports another command name", { embeddedIdentity: "t3-nightly v0.0.39-nightly.20260905.1284.managed.1.p0" }, /reports version "t3-nightly v/, "electron --version"],
    ["the embedded server prints a bare version", { embeddedIdentity: "0.0.39-nightly.20260905.1284.managed.1.p0" }, /reports version "0\.0\.39-nightly[^"]*", expected "t3 v/, "electron --version"],
    ["the embedded server prints extra lines", { embeddedIdentity: "t3 v0.0.39-nightly.20260905.1284.managed.1.p0\nElectron v38" }, /reports version "t3 v0\.0\.39-nightly[^"]*\\nElectron v38"/, "electron --version"],
    ["the embedded server cannot start from the ASAR", { embeddedFails: true }, /embedded server --version failed: .*Cannot find module/, "electron --version"],
  ];
  for (const [name, opts, pattern, lastCommand] of cases) {
    it(name, async () => {
      const fx = await makeFixture();
      await refusal(fx, opts, pattern);
      const labels = fx.calls.map((c) => commandLabel(fx, c)).filter((l) => l !== "git");
      assert.equal(labels.at(-1), lastCommand, `refused right after ${lastCommand}: ${labels.join(", ")}`);
      assert.ok(!labels.includes("electron --version") || lastCommand === "electron --version", "the embedded server never runs before the bundle is verified");
      await rm(fx.root, { recursive: true, force: true });
    });
  }

  it("a Reasoning bundle carrying the Nightly identity is refused", async () => {
    // A mutated disposable tree is never reused: each case gets a fresh prepared tree.
    for (const [opts, pattern] of [
      [{ plist: { CFBundleIdentifier: "com.t3tools.t3code" } }, /CFBundleIdentifier is "com\.t3tools\.t3code", expected "com\.t3tools\.t3code\.reasoning"/],
      [{ plist: (p) => ({ ...p, CFBundleURLTypes: [{ CFBundleURLSchemes: ["t3code-reasoning", "t3code"] }] }) }, /URL schemes are t3code-reasoning, t3code; expected exactly t3code-reasoning/],
      [{ appName: "T3 Code (Nightly).app", exeName: "T3 Code (Nightly)" }, /extracted bundle is T3 Code \(Nightly\)\.app, expected T3 Code \(Reasoning\)\.app/],
    ]) {
      const fx = await makeFixture({ variant: "reasoning" });
      await refusal(fx, opts, pattern);
      await rm(fx.root, { recursive: true, force: true });
    }
  });

  it("a stamped tree from a failed build is content drift for the next run, so it is never reused", async () => {
    const fx = await makeFixture();
    await refusal(fx, { zipNames: [] }, /emitted 0 ZIP archive/);
    await refusal(fx, {}, /content differs from .* plus the ordered managed-nightly patches \(4 path\(s\)\): M\tapps\/desktop\/package\.json/, { beforeMutation: false });
    await rm(fx.root, { recursive: true, force: true });
  });
});

describe("CLI", () => {
  it("parses the designed flags and requires each input", () => {
    const options = parseArgs(["--source", "src", "--descriptor", "d.json", "--public-config", "c.json", "--variant", "reasoning", "--destination", "out"]);
    assert.deepEqual(options, {
      source: path.resolve("src"),
      descriptor: path.resolve("d.json"),
      publicConfig: path.resolve("c.json"),
      variant: "reasoning",
      destination: path.resolve("out"),
      pnpm: "pnpm",
    });
    assert.equal(parseArgs(["--source", "s", "--descriptor", "d", "--public-config", "c", "--variant", "managed-nightly", "--destination", "o", "--pnpm", "/opt/pnpm"]).pnpm, "/opt/pnpm");
    throws(() => parseArgs(["--source", "s"]), /--descriptor is required/);
    throws(() => parseArgs(["--source", "s", "--descriptor", "d", "--public-config", "c", "--destination", "o"]), /--variant is required/);
    for (const flag of ["--signed", "--skip-build", "--mock-updates", "--platform", "--arch", "--bundle-id", "--product-name", "--publish"]) {
      throws(() => parseArgs([flag, "x"]), new RegExp(`unknown argument ${flag}`));
    }
    throws(() => parseArgs(["--variant", "reasoning", "--variant", "managed-nightly"]), /given more than once/);
  });

  it("refuses a tampered descriptor before touching the tree, and does not run on import", async () => {
    const fx = await makeFixture();
    const descriptorPath = path.join(fx.root, "release.json");
    const configPath = path.join(fx.root, "public-config.json");
    const tampered = structuredClone(fx.descriptor);
    tampered.publicConfig.sha256 = "0".repeat(64);
    await writeFile(descriptorPath, canonicalJson(tampered));
    await writeFile(configPath, JSON.stringify(PUBLIC_CONFIG));
    const args = [builderScript, "--source", fx.source, "--descriptor", descriptorPath, "--public-config", configPath, "--variant", "reasoning", "--destination", path.join(fx.out, "release")];
    const result = await run(process.execPath, args).then(
      () => assert.fail("must exit non-zero"),
      (error) => error,
    );
    assert.match(result.stderr, /build-managed-desktop-runtime: .*does not match the digest recomputed/);
    for (const value of Object.values(PUBLIC_CONFIG)) assert.doesNotMatch(result.stdout + result.stderr, new RegExp(value.replace(/[.]/g, "\\.")));
    await assertNothingPublished(fx);
    const { stdout, stderr } = await run(process.execPath, ["--input-type=module", "-e", `await import(${JSON.stringify(builderScript)});`]);
    assert.equal(stdout + stderr, "");
    await rm(fx.root, { recursive: true, force: true });
  });
});
