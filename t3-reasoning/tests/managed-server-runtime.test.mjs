// Tests for scripts/build-managed-server-runtime.mjs. Every build runs
// against a tiny prepared-source fixture: a real git repository holding a
// synthetic upstream commit with the managed-nightly patches applied as
// uncommitted changes, exactly as prepare-source leaves them, plus a
// provenance record and lock. A fake runner stands in for pnpm and cargo
// only, materializing stub build output and a stub deploy stage of
// relative pnpm links; git, tar, the deployed CLI stub, and the native
// runtime probe run for real. Nothing here installs dependencies, compiles
// Rust, or touches the network.
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { chmod, cp, lstat, mkdir, mkdtemp, readdir, readFile, readlink, realpath, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { describe, it } from "node:test";
import { parseEnv, promisify } from "node:util";

import {
  PUBLIC_CONFIG_KEYS,
  ReleaseError,
  canonicalJson,
  readVerifiedLock,
  resolveManagedRelease,
  sha256Hex,
} from "../scripts/resolve-managed-release.mjs";
import { EXPECTED_ARTIFACTS } from "../scripts/write-managed-release-manifest.mjs";
import {
  PINNED_NODE_VERSION,
  RELEASE_PACKAGE_FILES,
  STAGED_INSTALL_METADATA,
  SUPPORTED_TARGETS,
  buildChildEnvironment,
  buildManagedServerRuntime,
  checkArchiveMembers,
  checkExecutableHeader,
  compareDeployedLock,
  createRunner,
  encodeDotenv,
  parseArgs,
  resolveTarget,
  stampReleasePackageVersions,
  verifyPreparedSource,
  verifyStageLinks,
} from "../scripts/build-managed-server-runtime.mjs";

const run = promisify(execFile);
const here = path.dirname(fileURLToPath(import.meta.url));
const builderScript = path.join(here, "..", "scripts", "build-managed-server-runtime.mjs");
const realRunner = createRunner();

const BUILDER_REVISION = "0123456789abcdef0123456789abcdef01234567";
const UPSTREAM_VERSION = "0.0.39-nightly.20260905.1284";
const PUBLIC_CONFIG = {
  T3CODE_RELAY_URL: "https://relay.fixture.invalid",
  T3CODE_CLERK_PUBLISHABLE_KEY: "pk_test_FIXTURE_PUBLISHABLE_VALUE",
  T3CODE_CLERK_JWT_TEMPLATE: "fixture-jwt-template",
  T3CODE_CLERK_CLI_OAUTH_CLIENT_ID: "fixture-cli-oauth-client",
};
const HOSTS = {
  "darwin-arm64": { platform: "darwin", arch: "arm64", nodeVersion: PINNED_NODE_VERSION },
  "linux-x64": { platform: "linux", arch: "x64", nodeVersion: PINNED_NODE_VERSION, glibcVersionRuntime: "2.39" },
};
// The library file each pinned @ff-labs/fff-bin-* package actually ships
// (fff-node's platform.js prefixes `lib` everywhere but Windows). Kept
// independent of the builder's constants so the fixture cannot mirror a
// wrong spelling.
const PINNED_FFF_LIBRARIES = {
  "darwin-arm64": "libfff_c.dylib",
  "linux-x64": "libfff_c.so",
};
const ROOTS = {
  "@anthropic-ai/claude-agent-sdk": "0.3.260",
  "@effect/platform-bun": "4.0.0-beta.103(effect@4.0.0-beta.103(patch_hash=aa))",
  "@effect/platform-node": "4.0.0-beta.103(effect@4.0.0-beta.103(patch_hash=aa))",
  "@effect/sql-sqlite-bun": "4.0.0-beta.103(effect@4.0.0-beta.103(patch_hash=aa))",
  "@ff-labs/fff-node": "0.9.4(patch_hash=bb)",
  "@opencode-ai/sdk": "1.15.13",
  effect: "4.0.0-beta.103(patch_hash=aa)",
  "msgpackr-extract": "3.0.4",
  "node-pty": "1.1.0",
  yaml: "2.9.0",
  yauzl: "3.4.0",
};
const PATCHES = {
  "reasoning-full": "diff --git a/one b/one\n--- a/one\n+++ b/one\n@@ -1 +1 @@\n-one\n+one patched\n",
  "desktop-runtime-common":
    "diff --git a/two b/two\n--- a/two\n+++ b/two\n@@ -1 +1 @@\n-two\n+two patched\n" +
    "diff --git a/added.txt b/added.txt\nnew file mode 100644\n--- /dev/null\n+++ b/added.txt\n@@ -0,0 +1 @@\n+added by patch\n",
  "reasoning-identity": "diff --git a/identity b/identity\n--- a/identity\n+++ b/identity\n@@ -1 +1 @@\n-stock\n+reasoning\n",
};
// Mach-O 64-bit arm64 and ELF 64-bit LE x86-64 headers, padded.
const HEADERS = {
  "darwin-arm64": Buffer.concat([Buffer.from([0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0x00, 0x00, 0x01]), Buffer.alloc(24)]),
  "linux-x64": Buffer.concat([Buffer.from([0x7f, 0x45, 0x4c, 0x46, 2, 1, 1, 0]), Buffer.alloc(10), Buffer.from([0x3e, 0]), Buffer.alloc(12)]),
};

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

// The deployed CLI stub: reports its identity the way the real Effect CLI
// does (`t3 v<version>`, captured as "t3 v0.0.38\n" from the pinned build)
// and answers the identity-only preflight. Misbehaviours are baked in per
// fixture: another version, another command name, or extra output lines.
function binScript({ version = null, name = "t3", extraLines = [], createDb = false, protocol = 2 } = {}) {
  return `import { readFileSync, writeFileSync } from "node:fs";
const pkg = JSON.parse(readFileSync(new URL("../package.json", import.meta.url), "utf8"));
const version = ${JSON.stringify(version)} ?? pkg.version;
const args = process.argv.slice(2);
const name = ${JSON.stringify(name)};
if (args[0] === "--version") console.log([name === null ? version : name + " v" + version, ...${JSON.stringify(extraLines)}].join("\\n"));
else if (args[0] === "__service-preflight") {
  const db = args[args.indexOf("--database-path") + 1];
  if (${createDb}) writeFileSync(db, "");
  console.log(JSON.stringify({ status: "ready", version, launcherProtocol: ${protocol} }));
} else process.exit(2);
`;
}

function sourceLock() {
  const dependencies = Object.fromEntries(
    Object.entries(ROOTS).map(([name, version]) => [name, { specifier: name === "effect" ? "catalog:" : version.split("(")[0], version }]),
  );
  const packages = Object.fromEntries(
    Object.entries(ROOTS).map(([name, version]) => [`${name}@${version.split("(")[0]}`, { resolution: { integrity: `sha512-${name}` } }]),
  );
  return { lockfileVersion: "9.0", importers: { ".": { devDependencies: {} }, "apps/server": { dependencies } }, packages };
}

function serverManifest(extra = {}) {
  return {
    name: "t3",
    version: "0.0.38",
    bin: { t3: "./dist/bin.mjs" },
    files: ["dist"],
    type: "module",
    dependencies: Object.fromEntries(Object.entries(ROOTS).map(([name, version]) => [name, name === "effect" ? "catalog:" : `^${version.split("(")[0]}`])),
    devDependencies: { "@t3tools/web": "workspace:*", "vite-plus": "catalog:" },
    engines: { node: ">=24.10" },
    ...extra,
  };
}

// A prepared tree of one exact variant (managed-nightly by default): upstream
// commit, that variant's ordered patches applied to the working tree,
// provenance next to the git metadata, and a lock beside it.
async function makeFixture({ trackedFixture = false, fixtureMode = 0o644, target = "darwin-arm64", variant = "managed-nightly", worktree = false, serverExtra = {}, lockMutate = (l) => l } = {}) {
  const root = await realpath(await mkdtemp(path.join(tmpdir(), "t3-server-builder-")));
  const lockDir = path.join(root, "lock");
  const patches = [];
  for (const [id, text] of Object.entries(PATCHES)) {
    const rel = path.join("patches", `${id}.patch`);
    await write(lockDir, { [rel]: text });
    patches.push({ id, path: rel, sha256: sha256Hex(text) });
  }
  const upstream = path.join(root, "upstream");
  await mkdir(upstream);
  await write(upstream, {
    "package.json": json({ name: "@t3tools/monorepo", private: true, packageManager: "pnpm@11.10.0" }),
    "pnpm-workspace.yaml": "packages:\n  - apps/*\nallowBuilds:\n  node-pty: true\n",
    "pnpm-lock.yaml": json(sourceLock()),
    ".gitignore": "node_modules\napps/*/dist\n.env\n.env.local\nnative/**/target/\n",
    ".env.example": "T3CODE_RELAY_URL=\n",
    "apps/server/package.json": json(serverManifest(serverExtra)),
    "apps/web/package.json": json({ name: "@t3tools/web", version: "0.0.38", private: true, scripts: { build: "vp build" } }),
    "apps/desktop/package.json": json({ name: "@t3tools/desktop", version: "0.0.38", main: "dist-electron/main.cjs" }),
    "packages/contracts/package.json": json({ name: "@t3tools/contracts", version: "0.0.38", exports: {} }),
    "native/resource-monitor/Cargo.toml": "[package]\nname = \"t3-resource-monitor\"\n",
    one: "one\n",
    two: "two\n",
    identity: "stock\n",
  });
  await git(upstream, ["init", "-q", "-b", "main"]);
  await git(upstream, ["add", "-A"]);
  if (trackedFixture) {
    const fixtureFile = `${typeof trackedFixture === "string" ? trackedFixture : "vendor/compiler/cases/node_modules"}/example/index.js`;
    await write(upstream, { [fixtureFile]: "export default 42;\n" });
    await chmod(path.join(upstream, fixtureFile), fixtureMode);
    await git(upstream, ["add", "-f", fixtureFile]);
  }
  await git(upstream, ["commit", "-q", "-m", "upstream"]);
  const commit = (await git(upstream, ["rev-parse", "HEAD"])).stdout.trim();

  const lockPath = path.join(lockDir, "source.lock.json");
  const lock = lockMutate({
    version: 2,
    repository: "https://example.invalid/t3code.git",
    commit,
    patches,
    variants: {
      "managed-nightly": ["reasoning-full", "desktop-runtime-common"],
      reasoning: ["reasoning-full", "desktop-runtime-common", "reasoning-identity"],
    },
  });
  await writeFile(lockPath, json(lock));

  let source = upstream;
  if (worktree) {
    source = path.join(root, "prepared");
    await git(upstream, ["worktree", "add", "-q", "--detach", source, "HEAD"]);
  }
  const applied = lock.variants[variant].map((id) => patches.find((p) => p.id === id));
  for (const patch of applied) await git(source, ["apply"], PATCHES[patch.id]);
  const gitDir = (await git(source, ["rev-parse", "--absolute-git-dir"])).stdout.trim();
  const provenance = { preparedAt: "2026-09-05T00:00:00.000Z", lock: lockPath, lockRepository: lock.repository, repository: upstream, commit, variant, patches: applied };
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
  return { root, source, lockPath, lockDir, gitDir, commit, descriptor, target, out, tmpRoot, provenance, calls: [] };
}

// --- fake pnpm and cargo -----------------------------------------------------------

async function fakeBuild(fx, opts) {
  const env = parseEnv(await readFile(path.join(fx.source, ".env"), "utf8"));
  assert.deepEqual(env, PUBLIC_CONFIG, "the build sees exactly the four public values in .env");
  await write(fx.source, {
    "apps/web/dist/index.html": "<html></html>\n",
    "apps/server/dist/bin.mjs": binScript(opts.bin),
    "apps/server/dist/service-launcher.mjs": "export {};\n",
    ...(opts.omitClient ? {} : { "apps/server/dist/client/index.html": "<html>client</html>\n" }),
  });
}

async function fakeCargo(fx, args, opts) {
  const triple = args[args.indexOf("--target") + 1];
  const file = path.join(fx.source, "native/resource-monitor/target", triple, "release", "t3-resource-monitor");
  await mkdir(path.dirname(file), { recursive: true });
  await writeFile(file, opts.badHeader ? Buffer.from("#!/bin/sh\necho monitor\n") : HEADERS[fx.target]);
  await chmod(file, opts.nonExecutable ? 0o644 : 0o755);
}

// A stub of the modern deploy: exact resolutions, the metadata pnpm writes,
// and stub packages under .pnpm reached only through relative links.
async function fakeDeploy(fx, targetDir, opts) {
  const target = SUPPORTED_TARGETS[fx.target];
  const fffLibrary = opts.fffLibrary ?? PINNED_FFF_LIBRARIES[fx.target];
  const manifest = JSON.parse(await readFile(path.join(fx.source, "apps/server/package.json"), "utf8"));
  const lock = JSON.parse(await readFile(path.join(fx.source, "pnpm-lock.yaml"), "utf8"));
  const resolved = Object.fromEntries(Object.keys(manifest.dependencies).map((name) => [name, lock.importers["apps/server"].dependencies[name].version]));
  if (opts.lockDrift) resolved.yaml = "2.8.0";
  const nm = path.join(targetDir, "node_modules");
  await write(targetDir, {
    "package.json": json({
      ...manifest,
      version: opts.deployedVersion ?? manifest.version,
      dependencies: opts.unresolvedSpec ? { ...resolved, effect: "catalog:" } : resolved,
      devDependencies: { "@t3tools/web": `@t3tools/web@file://${fx.source}/apps/web` },
      optionalDependencies: {},
    }),
    "pnpm-lock.yaml": json({
      lockfileVersion: "9.0",
      importers: {
        ".": { dependencies: Object.fromEntries(Object.entries(resolved).map(([n, v]) => [n, { specifier: v, version: v }])) },
        ...(opts.extraImporter ? { "apps/web": {} } : {}),
      },
      packages: lock.packages,
    }),
    "pnpm-workspace.yaml": "patchedDependencies: {}\n",
    "node_modules/.modules.yaml": json({ nodeLinker: opts.nodeLinker ?? "isolated", storeDir: "/Users/host/Library/pnpm/store/v11", virtualStoreDir: ".pnpm" }),
    "node_modules/.package-map.json": json({ packages: {} }),
    "node_modules/.pnpm-workspace-state-v1.json": json({ projects: {}, settings: { enableGlobalVirtualStore: opts.globalStore ?? false } }),
    "node_modules/.pnpm/lock.yaml": "lockfileVersion: '9.0'\n",
    "node_modules/.bin/yaml": `#!/bin/sh\nexport NODE_PATH="${targetDir}/node_modules"\n`,
    "node_modules/.pnpm/node_modules/.bin/download": "#!/bin/sh\n",
  });
  await cp(path.join(fx.source, "apps/server/dist"), path.join(targetDir, "dist"), { recursive: true });

  const stubs = {
    "node-pty": { "index.js": opts.ptyThrows ? 'throw new Error("Failed to load native module: pty.node");\n' : "module.exports = {};\n" },
    "msgpackr-extract": { "index.js": 'module.exports = require("node-gyp-build-optional-packages")(__dirname);\n' },
    "@ff-labs/fff-node": {
      "dist/src/index.js": `import { existsSync } from "node:fs";\nimport { createRequire } from "node:module";\nimport path from "node:path";
export function findBinary() {
  const require = createRequire(import.meta.url);
  try { return [path.join(path.dirname(require.resolve(${JSON.stringify(`${target.fffPackage}/package.json`)})), ${JSON.stringify(fffLibrary)})].find((p) => existsSync(p)) ?? null; } catch { return null; }
}\n`,
    },
  };
  // pnpm's layout: node_modules/<name> -> .pnpm/<name>@<version>/node_modules/<name>,
  // a package's own dependencies beside it, and singletons hoisted into .pnpm/node_modules.
  const place = async (base, name, version, files, packageJson = {}) => {
    const dir = path.join(base, name);
    const isModule = name === "@ff-labs/fff-node";
    await write(dir, {
      "package.json": json({ name, version, ...(isModule ? { type: "module", main: "dist/src/index.js", exports: { ".": { import: "./dist/src/index.js" } } } : { main: "index.js" }), ...packageJson }),
      ...(files ?? { "index.js": "module.exports = {};\n" }),
    });
    return dir;
  };
  const link = async (from, to) => {
    await mkdir(path.dirname(from), { recursive: true });
    await symlink(path.relative(path.dirname(from), to), from);
  };
  for (const [name, version] of Object.entries(resolved)) {
    const storeDir = path.join(nm, ".pnpm", `${name.replace("/", "+")}@${version.split("(")[0]}`, "node_modules");
    const dir = await place(storeDir, name, version.split("(")[0], stubs[name]);
    await link(path.join(nm, name), dir);
    if (name === "node-pty" && !opts.omitLoader) await place(storeDir, "node-addon-api", "8.0.0");
    if (name === "msgpackr-extract") {
      await place(storeDir, "node-gyp-build-optional-packages", "5.2.2", { "index.js": "module.exports = () => ({});\n" });
      await place(storeDir, "detect-libc", "2.0.3");
    }
    if (name === "@ff-labs/fff-node") {
      await place(storeDir, "ffi-rs", "1.3.2", {
        "index.js": 'const { existsSync } = require("node:fs");\nmodule.exports = { open({ path }) { if (!existsSync(path)) throw new Error("cannot open " + path); }, close() {} };\n',
      });
    }
  }
  const hoisted = path.join(nm, ".pnpm", "node_modules");
  if (!opts.omitNative) await place(hoisted, target.msgpackrPackage, "3.0.4", { "index.js": "", "node.napi.glibc.node": "native\n" });
  if (!opts.omitFfiNative) await place(hoisted, target.ffiPackage, "1.3.2", { "index.js": "", "ffi-rs.node": "native\n" });
  if (!opts.omitFffBin) await place(hoisted, target.fffPackage, "0.9.4", { [fffLibrary]: "native\n" });
  if (opts.includeElectron) await place(path.join(nm, ".pnpm", "electron@38.0.0", "node_modules"), "electron", "38.0.0");
  if (opts.includeWorkspace) await place(nm, "@t3tools/web", "0.0.38");
  if (opts.escapingLink) await symlink("../../../../../..", path.join(nm, "escape"));
  if (opts.danglingLink) await symlink(".pnpm/nothing/node_modules/nothing", path.join(nm, "dangling"));
  if (opts.absoluteLink) await symlink(path.join(nm, ".pnpm", "yaml@2.9.0", "node_modules", "yaml"), path.join(nm, "yaml-abs"));
}

function fakeRunner(fx, opts = {}) {
  return async (spec) => {
    fx.calls.push(spec);
    const { command, args } = spec;
    if (command === "git" || command === "tar" || command === process.execPath) return realRunner(spec);
    if (command === "pnpm") {
      assert.ok(!args.includes("--legacy"), "no legacy deploy is ever attempted");
      if (args[0] === "--version") return { stdout: `${opts.pnpmVersion ?? "11.10.0"}\n`, stderr: "" };
      if (args[0] === "install") {
        if (opts.installMutatesLock) await writeFile(path.join(fx.source, "pnpm-lock.yaml"), json({ ...sourceLock(), touched: true }));
        return { stdout: "", stderr: "" };
      }
      if (args[0] === "exec") {
        await fakeBuild(fx, opts);
        return { stdout: "", stderr: "" };
      }
      if (args.includes("deploy")) {
        if (opts.deployFails) {
          const error = new Error("pnpm deploy exited with 1");
          Object.assign(error, { stderr: "ERR_PNPM_DEPLOY_NONINJECTED_WORKSPACE  use --legacy", stdout: "", code: 1 });
          throw error;
        }
        await fakeDeploy(fx, args.at(-1), opts);
        return { stdout: "", stderr: "" };
      }
    }
    if (command === "cargo") {
      await fakeCargo(fx, args, opts);
      return { stdout: "", stderr: "" };
    }
    throw new Error(`unexpected command ${command} ${args.join(" ")}`);
  };
}

function build(fx, opts = {}, overrides = {}) {
  return buildManagedServerRuntime({
    source: fx.source,
    descriptor: fx.descriptor,
    publicConfig: PUBLIC_CONFIG,
    platform: SUPPORTED_TARGETS[fx.target].platform,
    arch: SUPPORTED_TARGETS[fx.target].arch,
    destination: path.join(fx.out, "release"),
    run: fakeRunner(fx, opts),
    host: HOSTS[fx.target],
    env: { PATH: process.env.PATH, HOME: process.env.HOME, VITE_T3CODE_RELAY_URL: "https://ambient.invalid", NODE_OPTIONS: "--trace-warnings", CARGO_HOME: "/fixture/cargo" },
    tmpRoot: fx.tmpRoot,
    parseYaml: JSON.parse,
    ...overrides,
  });
}

function commandLabel({ command, args }) {
  if (command === "git" || command === "tar") return command;
  if (command === process.execPath) return args[0] === "--input-type=module" ? "node:probe" : `node:${args[1]}`;
  if (command === "pnpm") return `pnpm ${args.includes("deploy") ? "deploy" : args[0] === "exec" ? "build" : args[0]}`;
  return command;
}

// Nothing published, no staging or lock left, the task-owned .env gone,
// the work directory removed, and the source lock untouched.
async function assertNothingPublished(fx, { lockMutated = false } = {}) {
  assert.deepEqual(await readdir(fx.out), []);
  assert.deepEqual(await readdir(fx.tmpRoot), []);
  assert.deepEqual((await readdir(fx.source)).filter((n) => n.startsWith(".env")), [".env.example"]);
  if (!lockMutated) assert.equal(await readFile(path.join(fx.source, "pnpm-lock.yaml"), "utf8"), json(sourceLock()));
}

async function refusal(fx, opts, pattern, { beforeMutation = false } = {}) {
  await rejects(() => build(fx, opts), pattern);
  await assertNothingPublished(fx, { lockMutated: Boolean(opts.installMutatesLock) });
  if (beforeMutation) {
    for (const relative of RELEASE_PACKAGE_FILES) {
      assert.equal(JSON.parse(await readFile(path.join(fx.source, relative), "utf8")).version, "0.0.38", `${relative} is not stamped`);
    }
    assert.ok(!fx.calls.some((c) => ["cargo"].includes(c.command) || (c.command === "pnpm" && c.args[0] !== "--version")), "no build command ran");
  }
}

// --- pure helpers ---------------------------------------------------------------------

describe("target resolution", () => {
  it("accepts exactly darwin-arm64 and linux-x64 on a matching pinned host", () => {
    const darwin = resolveTarget("darwin", "arm64", HOSTS["darwin-arm64"]);
    assert.equal(darwin.rustTarget, "aarch64-apple-darwin");
    assert.equal(darwin.artifact.id, "managed-server-darwin-arm64");
    const linux = resolveTarget("linux", "x64", HOSTS["linux-x64"]);
    assert.equal(linux.rustTarget, "x86_64-unknown-linux-gnu");
    assert.equal(linux.artifact.id, "managed-server-linux-x64");
    assert.equal(darwin.fffLibrary, PINNED_FFF_LIBRARIES["darwin-arm64"], "the probe expects the file the pinned Darwin package ships");
    assert.equal(linux.fffLibrary, PINNED_FFF_LIBRARIES["linux-x64"], "the probe expects the file the pinned Linux package ships");
    throws(() => resolveTarget("linux", "arm64", { ...HOSTS["linux-x64"], arch: "arm64" }), /not supported/);
    throws(() => resolveTarget("win32", "x64", { ...HOSTS["linux-x64"], platform: "win32" }), /not supported/);
    throws(() => resolveTarget("linux", "x64", HOSTS["darwin-arm64"]), /must be built on a linux-x64 host/);
    throws(() => resolveTarget("darwin", "arm64", HOSTS["linux-x64"]), /must be built on a darwin-arm64 host/);
    throws(() => resolveTarget("linux", "x64", { ...HOSTS["linux-x64"], glibcVersionRuntime: undefined }), /confirmed glibc/);
    throws(() => resolveTarget("linux", "x64", { ...HOSTS["linux-x64"], glibcVersionRuntime: "" }), /confirmed glibc/);
    throws(() => resolveTarget("darwin", "arm64", { ...HOSTS["darwin-arm64"], nodeVersion: "24.13.0" }), /require Node 24\.13\.1/);
  });
});

describe("configuration handling", () => {
  it("encodes the four values as dotenv that parseEnv reads back unchanged", () => {
    const tricky = {
      T3CODE_RELAY_URL: "https://relay.invalid/path?a=1#frag",
      T3CODE_CLERK_PUBLISHABLE_KEY: "pk_test_with\\backslash",
      T3CODE_CLERK_JWT_TEMPLATE: 'has "double" quotes',
      T3CODE_CLERK_CLI_OAUTH_CLIENT_ID: "has 'single' quotes = and #",
    };
    const text = encodeDotenv(tricky);
    assert.deepEqual(parseEnv(text), tricky);
    assert.deepEqual(text.split("\n").filter(Boolean).map((l) => l.split("=")[0]), PUBLIC_CONFIG_KEYS);
    throws(() => encodeDotenv({ ...tricky, T3CODE_RELAY_URL: `both "quotes" and 'quotes'` }), /cannot be encoded as dotenv/);
    assert.throws(() => encodeDotenv({ ...tricky, T3CODE_RELAY_URL: `both "quotes" and 'quotes'` }), (e) => !e.message.includes("quotes"));
  });

  it("scrubs build aliases, identity overrides, loader hooks, and target overrides from the child environment", () => {
    const env = buildChildEnvironment(
      {
        PATH: "/usr/bin",
        HOME: "/home/x",
        CARGO_HOME: "/home/x/.cargo",
        VITE_T3CODE_RELAY_URL: "ambient",
        EXPO_PUBLIC_CLERK_PUBLISHABLE_KEY: "ambient",
        T3CODE_RELAY_URL: "ambient",
        T3CODE_RELAY_CLIENT_OTLP_TRACES_TOKEN: "ambient",
        T3CODE_PRODUCT_VARIANT: "reasoning",
        APP_VERSION: "9.9.9",
        VERCEL_ENV: "production",
        NODE_OPTIONS: "--require x",
        NODE_PATH: "/elsewhere",
        ELECTRON_RUN_AS_NODE: "1",
        npm_config_target: "38.0.0",
        npm_config_runtime: "electron",
        CARGO_TARGET_DIR: "/shared/target",
        CARGO_BUILD_TARGET: "x86_64-unknown-linux-musl",
        RUSTFLAGS: "-C target-cpu=native",
        CARGO_ENCODED_RUSTFLAGS: "x",
        GITHUB_REPOSITORY: "t3dotgg/t3code",
        EMPTY: undefined,
      },
      PUBLIC_CONFIG,
    );
    assert.deepEqual(env, { PATH: "/usr/bin", HOME: "/home/x", CARGO_HOME: "/home/x/.cargo", ...PUBLIC_CONFIG, T3CODE_PRODUCT_VARIANT: "managed-nightly" });
  });

  it("stamps the default, an explicit managed-nightly, or an explicit reasoning variant and refuses any other", () => {
    const base = { PATH: "/usr/bin", HOME: "/home/x", T3CODE_PRODUCT_VARIANT: "reasoning", GITHUB_REPOSITORY: "t3dotgg/t3code" };
    const expected = { PATH: "/usr/bin", HOME: "/home/x", ...PUBLIC_CONFIG };
    assert.deepEqual(buildChildEnvironment(base, PUBLIC_CONFIG), { ...expected, T3CODE_PRODUCT_VARIANT: "managed-nightly" });
    assert.deepEqual(buildChildEnvironment(base, PUBLIC_CONFIG, "managed-nightly"), { ...expected, T3CODE_PRODUCT_VARIANT: "managed-nightly" });
    assert.deepEqual(buildChildEnvironment(base, PUBLIC_CONFIG, "reasoning"), { ...expected, T3CODE_PRODUCT_VARIANT: "reasoning" });
    throws(() => buildChildEnvironment(base, PUBLIC_CONFIG, "stock"), /expected variant "stock" is not one of managed-nightly, reasoning/);
    throws(() => buildChildEnvironment(base, PUBLIC_CONFIG, null), /expected variant null is not one of/);
    throws(() => buildChildEnvironment(base, PUBLIC_CONFIG, ""), /expected variant "" is not one of/);
  });

  it("stamps exactly the four release manifests and preserves every other field", async () => {
    const fx = await makeFixture();
    const before = JSON.parse(await readFile(path.join(fx.source, "apps/server/package.json"), "utf8"));
    assert.deepEqual(await stampReleasePackageVersions(fx.source, fx.descriptor.releaseVersion), RELEASE_PACKAGE_FILES);
    for (const relative of RELEASE_PACKAGE_FILES) {
      const after = JSON.parse(await readFile(path.join(fx.source, relative), "utf8"));
      assert.equal(after.version, fx.descriptor.releaseVersion, relative);
    }
    const after = JSON.parse(await readFile(path.join(fx.source, "apps/server/package.json"), "utf8"));
    assert.deepEqual({ ...after, version: before.version }, before);
    assert.deepEqual(Object.keys(after), Object.keys(before), "field order is preserved");
    assert.equal(JSON.parse(await readFile(path.join(fx.source, "package.json"), "utf8")).version, undefined, "the root manifest is untouched");
    await rm(fx.root, { recursive: true, force: true });
  });
});

describe("stage checks", () => {
  const lock = sourceLock();
  const manifest = serverManifest();
  const resolved = Object.fromEntries(Object.entries(ROOTS));
  const deployed = () => ({
    deployedManifest: { name: "t3", dependencies: { ...resolved }, optionalDependencies: {} },
    deployedLock: {
      importers: { ".": { dependencies: Object.fromEntries(Object.entries(resolved).map(([n, v]) => [n, { specifier: v, version: v }])) } },
      packages: structuredClone(lock.packages),
    },
  });

  it("accepts a dedicated lock whose resolutions equal the source importer, catalog expanded", () => {
    const roots = compareDeployedLock({ sourceLock: lock, sourceManifest: manifest, ...deployed() });
    assert.deepEqual(roots.sort(), Object.keys(ROOTS).sort());
  });

  it("refuses extra importers, missing or drifted dependencies, unresolved specifiers, and changed integrity", () => {
    const check = (mutate, pattern) => {
      const d = deployed();
      mutate(d);
      throws(() => compareDeployedLock({ sourceLock: lock, sourceManifest: manifest, ...d }), pattern);
    };
    check((d) => { d.deployedLock.importers["apps/web"] = {}; }, /importers are \., apps\/web/);
    check((d) => { delete d.deployedLock.importers["."].dependencies.yaml; }, /deployed dependencies are/);
    check((d) => { delete d.deployedManifest.dependencies.yaml; }, /deployed dependencies are/);
    check((d) => { d.deployedLock.importers["."].dependencies.yaml.version = "2.8.0"; }, /yaml: deployed 2\.8\.0, source 2\.9\.0/);
    check((d) => { d.deployedLock.importers["."].dependencies.effect.version = "4.0.0-beta.103"; }, /effect: deployed 4\.0\.0-beta\.103, source 4\.0\.0-beta\.103\(patch_hash=aa\)/);
    check((d) => { d.deployedManifest.dependencies.effect = "catalog:"; }, /effect: generated manifest carries catalog:/);
    check((d) => { d.deployedManifest.dependencies.yaml = "workspace:*"; }, /unresolved workspace:/);
    check((d) => { d.deployedLock.packages["yaml@2.9.0"].resolution.integrity = "sha512-other"; }, /yaml@2\.9\.0: package resolution differs/);
    check((d) => { delete d.deployedLock.packages["node-pty@1.1.0"]; }, /node-pty@1\.1\.0: missing package resolution/);
    throws(() => compareDeployedLock({ sourceLock: { importers: {} }, sourceManifest: manifest, ...deployed() }), /no apps\/server importer/);
    throws(
      () => compareDeployedLock({ sourceLock: lock, sourceManifest: { ...manifest, dependencies: { ...manifest.dependencies, extra: "1.0.0" } }, ...deployed() }),
      /source declares/,
    );
  });

  it("checks executable headers per target", () => {
    checkExecutableHeader(HEADERS["darwin-arm64"], SUPPORTED_TARGETS["darwin-arm64"]);
    checkExecutableHeader(HEADERS["linux-x64"], SUPPORTED_TARGETS["linux-x64"]);
    throws(() => checkExecutableHeader(HEADERS["linux-x64"], SUPPORTED_TARGETS["darwin-arm64"]), /not a Mach-O 64-bit arm64/);
    throws(() => checkExecutableHeader(HEADERS["darwin-arm64"], SUPPORTED_TARGETS["linux-x64"]), /not an ELF 64-bit/);
    const x64MachO = Buffer.from(HEADERS["darwin-arm64"]);
    x64MachO.writeUInt32LE(0x01000007, 4);
    throws(() => checkExecutableHeader(x64MachO, SUPPORTED_TARGETS["darwin-arm64"]), /not a Mach-O 64-bit arm64/);
    const aarch64Elf = Buffer.from(HEADERS["linux-x64"]);
    aarch64Elf.writeUInt16LE(0xb7, 18);
    throws(() => checkExecutableHeader(aarch64Elf, SUPPORTED_TARGETS["linux-x64"]), /not an ELF 64-bit/);
    throws(() => checkExecutableHeader(Buffer.from("#!/bin/sh\n"), SUPPORTED_TARGETS["linux-x64"]), /not an ELF/);
  });

  it("walks relative internal links and refuses escaping, absolute, or dangling ones", async () => {
    const root = await mkdtemp(path.join(tmpdir(), "t3-links-"));
    await write(root, { "node_modules/.pnpm/a@1/node_modules/a/index.js": "", "node_modules/.pnpm/a@1/node_modules/a/package.json": "{}" });
    await symlink("../node_modules/.pnpm/a@1/node_modules/a", path.join(root, "node_modules/x"));
    await symlink(".pnpm/a@1/node_modules/a", path.join(root, "node_modules/a"));
    assert.equal(await verifyStageLinks(root), 2);
    await symlink("../../..", path.join(root, "node_modules/up"));
    await rejects(() => verifyStageLinks(root), /escapes the stage/);
    await rm(path.join(root, "node_modules/up"));
    await symlink(".pnpm/missing", path.join(root, "node_modules/gone"));
    await rejects(() => verifyStageLinks(root), /dangling/);
    await rm(path.join(root, "node_modules/gone"));
    await symlink(path.join(root, "node_modules/.pnpm/a@1/node_modules/a"), path.join(root, "node_modules/abs"));
    await rejects(() => verifyStageLinks(root), /absolute/);
    await rm(root, { recursive: true, force: true });
  });

  it("requires archive members under node_modules/ with no sentinels, state, configuration, or metadata", () => {
    const good = ["node_modules/", "node_modules/t3/", "node_modules/t3/package.json", "node_modules/t3/dist/bin.mjs", "node_modules/t3/node_modules/.pnpm/x@1/node_modules/x/index.js"];
    assert.equal(checkArchiveMembers(`${good.join("\n")}\n`).length, 5);
    for (const [member, pattern] of [
      ["package.json", /outside node_modules/],
      ["node_modules/../etc", /not a plain relative path/],
      ["node_modules/t3/._bin.mjs", /AppleDouble/],
      ["node_modules/t3/.install-complete", /must not be shipped/],
      ["node_modules/.managed-artifact.json", /must not be shipped/],
      ["node_modules/t3/.env", /must not be shipped/],
      ["node_modules/t3/state.sqlite", /database state/],
      ["node_modules/t3/pnpm-lock.yaml", /still contains pnpm-lock\.yaml/],
      ["node_modules/t3/node_modules/.bin", /still contains node_modules\/\.bin/],
    ]) {
      throws(() => checkArchiveMembers(`${[...good, member].join("\n")}\n`), pattern);
    }
    throws(() => checkArchiveMembers("node_modules/t3/package.json\n"), /lacks node_modules\/t3\/dist\/bin\.mjs/);
    throws(() => checkArchiveMembers(""), /empty/);
  });
});

// --- the whole sequence ---------------------------------------------------------------

describe("buildManagedServerRuntime", () => {
  for (const target of Object.keys(SUPPORTED_TARGETS)) {
    it(`builds, verifies, and publishes ${target} with commands in the designed order`, async () => {
      const fx = await makeFixture({ target });
      const result = await build(fx);
      const destination = path.join(fx.out, "release");
      const version = fx.descriptor.releaseVersion;
      const file = `managed-server-${target}-${version}.tar.gz`;
      assert.equal(result.file, file);
      assert.deepEqual((await readdir(destination)).sort(), [file, `managed-server-${target}-${version}.inventory.json`].sort());
      assert.deepEqual(await readdir(fx.out), ["release"], "no staging or lock is left beside the destination");

      // Fixed inventory schema, nothing else.
      const expected = EXPECTED_ARTIFACTS.find((a) => a.id === `managed-server-${target}`);
      const inventoryText = await readFile(path.join(destination, `managed-server-${target}-${version}.inventory.json`), "utf8");
      assert.equal(inventoryText, canonicalJson({ ...expected, file, version }));
      assert.deepEqual(result.inventory, { ...expected, file, version });
      assert.equal(result.sha256, sha256Hex(await readFile(path.join(destination, file))));

      // Command order: stamp happens in-process before the frozen install.
      assert.deepEqual(
        fx.calls.map(commandLabel).filter((l) => l !== "git"),
        ["pnpm --version", "pnpm install", "pnpm build", "cargo", "pnpm deploy", "node:probe", "node:--version", "node:__service-preflight", "tar", "tar"],
      );
      const stampedAt = fx.calls.findIndex((c) => c.command === "pnpm" && c.args[0] === "install");
      assert.ok(stampedAt > 0);
      const deploy = fx.calls.find((c) => c.args.includes("deploy"));
      assert.deepEqual(deploy.args.slice(0, 6), ["--filter", "t3", "--config.inject-workspace-packages=true", "deploy", "--prod", "--offline"]);
      const cargo = fx.calls.find((c) => c.command === "cargo");
      assert.deepEqual(cargo.args, ["build", "--locked", "--release", "--manifest-path", "native/resource-monitor/Cargo.toml", "--target", SUPPORTED_TARGETS[target].rustTarget]);
      assert.equal(cargo.cwd, fx.source);

      // Environment isolation: build tools see the four values and the variant, never ambient aliases or loader hooks.
      for (const call of fx.calls.filter((c) => c.command === "pnpm" || c.command === "cargo")) {
        assert.equal(call.env.T3CODE_PRODUCT_VARIANT, "managed-nightly");
        assert.equal(call.env.T3CODE_RELAY_URL, PUBLIC_CONFIG.T3CODE_RELAY_URL);
        assert.equal(call.env.VITE_T3CODE_RELAY_URL, undefined);
        assert.equal(call.env.NODE_OPTIONS, undefined);
        assert.equal(call.env.CARGO_HOME, "/fixture/cargo");
      }
      for (const call of fx.calls.filter((c) => c.command === process.execPath)) {
        assert.deepEqual(Object.keys(call.env).sort(), ["HOME", "PATH", "TMPDIR"]);
        assert.notEqual(call.env.HOME, process.env.HOME, "verification runs under a disposable HOME");
        assert.notEqual(call.cwd, fx.source, "verification runs from an unrelated cwd");
      }
      const tarCall = fx.calls.find((c) => c.command === "tar");
      assert.equal(tarCall.env.COPYFILE_DISABLE, "1");
      assert.ok(tarCall.args.includes("--no-xattrs"));

      // Archive contents: node_modules root, dist, monitor, packages via relative links; no metadata, sentinels, or env.
      const listing = (await run("tar", ["-tzf", path.join(destination, file)])).stdout.split("\n").filter(Boolean).map((m) => m.replace(/\/$/, ""));
      assert.ok(listing.every((m) => m === "node_modules" || m.startsWith("node_modules/")));
      for (const member of ["node_modules/t3/package.json", "node_modules/t3/dist/bin.mjs", "node_modules/t3/dist/service-launcher.mjs", "node_modules/t3/dist/client/index.html", `node_modules/t3/dist/resource-monitor/${target}/t3-resource-monitor`, "node_modules/t3/node_modules/node-pty", "node_modules/t3/node_modules/.pnpm/node-pty@1.1.0/node_modules/node-pty/index.js"]) {
        assert.ok(listing.includes(member), `archive contains ${member}`);
      }
      for (const relative of STAGED_INSTALL_METADATA) assert.ok(!listing.includes(`node_modules/t3/${relative}`), `archive omits ${relative}`);
      assert.ok(!listing.some((m) => /\.env|\.install-complete|\.managed-artifact|\._/.test(m)));
      const extracted = await mkdtemp(path.join(tmpdir(), "t3-extract-"));
      await run("tar", ["-xzf", path.join(destination, file), "-C", extracted]);
      const shipped = JSON.parse(await readFile(path.join(extracted, "node_modules/t3/package.json"), "utf8"));
      assert.equal(shipped.version, version);
      assert.equal(shipped.devDependencies, undefined, "development workspace paths are stripped");
      assert.deepEqual(Object.keys(shipped.dependencies).sort(), Object.keys(ROOTS).sort());
      assert.equal(shipped.dependencies.effect, ROOTS.effect, "patch hash preserved in the exact resolution");
      const { stdout } = await run(process.execPath, [path.join(extracted, "node_modules/t3/dist/bin.mjs"), "--version"]);
      assert.equal(stdout, `t3 v${version}\n`, "the extracted CLI prints the real identity format");
      assert.equal(await verifyStageLinks(extracted), result.dependencySymlinks, "relative links survive extraction");
      await rm(extracted, { recursive: true, force: true });

      // The disposable tree keeps its stamped versions, loses the task-owned .env, and its lock is untouched.
      assert.equal(JSON.parse(await readFile(path.join(fx.source, "apps/web/package.json"), "utf8")).version, version);
      assert.deepEqual((await readdir(fx.source)).filter((n) => n.startsWith(".env")), [".env.example"]);
      assert.equal(await readFile(path.join(fx.source, "pnpm-lock.yaml"), "utf8"), json(sourceLock()));
      assert.deepEqual(await readdir(fx.tmpRoot), [], "the private work directory is removed");
      await rm(fx.root, { recursive: true, force: true });
    });
  }

  it("resolves provenance through a worktree's .git file", async () => {
    const fx = await makeFixture({ worktree: true });
    assert.match(await readFile(path.join(fx.source, ".git"), "utf8"), /^gitdir: /);
    const result = await build(fx);
    assert.equal(result.inventory.id, "managed-server-darwin-arm64");
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
  for (const variant of ["managed-nightly"]) {
    for (const fixtureMode of [0o644, 0o755]) {
      it(`accepts a pristine tracked node_modules fixture mode ${fixtureMode.toString(8)} for ${variant}`, async () => {
        const fx = await makeFixture({ trackedFixture: true, fixtureMode, variant });
        try {
          await build(fx);
          assert.ok(fx.calls.some((call) => call.command === "pnpm" && call.args[0] === "install"));
        } finally {
          await rm(fx.root, { recursive: true, force: true });
        }
      });
    }

    for (const trackedFixture of ["node_modules", "apps/server/node_modules", "apps/desktop/node_modules", "packages/contracts/node_modules"]) {
      it(`rejects tracked installation ${trackedFixture} for ${variant}`, async () => {
        const fx = await makeFixture({ trackedFixture, variant });
        try {
          await refusal(fx, {}, /source already contains .*node_modules/, { beforeMutation: true });
        } finally {
          await rm(fx.root, { recursive: true, force: true });
        }
      });
    }

    for (const fixtureMode of [0o644, 0o755]) {
      it(`rejects tracked fixture mode ${fixtureMode.toString(8)} drift with core.filemode=false for ${variant}`, async () => {
        const fx = await makeFixture({ trackedFixture: true, fixtureMode, variant });
        try {
          await git(fx.source, ["config", "core.filemode", "false"]);
          const file = path.join(fx.source, "vendor/compiler/cases/node_modules/example/index.js");
          const changedMode = fixtureMode === 0o644 ? 0o755 : 0o644;
          await chmod(file, changedMode);
          await refusal(fx, {}, /source already contains .*node_modules/, { beforeMutation: true });
          assert.equal((await lstat(file)).mode & 0o777, changedMode, "the rejected mode remains untouched");
        } finally {
          await rm(fx.root, { recursive: true, force: true });
        }
      });
    }

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
  it("descriptor, public config, target, and toolchain disagreements", async () => {
    const fx = await makeFixture();
    const tampered = structuredClone(fx.descriptor);
    tampered.builderRevision = "b".repeat(40);
    await rejects(() => build(fx, {}, { descriptor: tampered }), /does not match the digest recomputed/);
    await rejects(() => build(fx, {}, { publicConfig: { ...PUBLIC_CONFIG, T3CODE_RELAY_URL: "https://other.invalid" } }), /fingerprint does not match/);
    await rejects(() => build(fx, {}, { host: HOSTS["linux-x64"] }), /must be built on a darwin-arm64 host/);
    await rejects(() => build(fx, {}, { host: { ...HOSTS["darwin-arm64"], nodeVersion: "22.19.0" } }), /require Node 24\.13\.1/);
    await rejects(() => build(fx, {}, { platform: "linux", arch: "arm64" }), /not supported/);
    await rejects(() => build(fx, { pnpmVersion: "10.33.2" }), /is version 10\.33\.2; the source pins pnpm@11\.10\.0/);
    assert.ok(fx.calls.every((c) => c.args[0] === "--version"), "only pnpm --version ran");
    await assertNothingPublished(fx);
    await rm(fx.root, { recursive: true, force: true });
  });

  it("a source that declares another package manager or a production workspace dependency", async () => {
    const fx = await makeFixture({ serverExtra: { dependencies: { ...serverManifest().dependencies, "@t3tools/shared": "workspace:*" } } });
    await refusal(fx, {}, /production dependency @t3tools\/shared uses workspace:\*/, { beforeMutation: true });
    await rm(fx.root, { recursive: true, force: true });
    const other = await makeFixture();
    await writeFile(path.join(other.source, "package.json"), json({ name: "@t3tools/monorepo", packageManager: "pnpm@10.33.2" }));
    await refusal(other, {}, /declares packageManager pnpm@10\.33\.2/, { beforeMutation: true });
    await rm(other.root, { recursive: true, force: true });
  });

  it("pre-existing env files, linker overrides, and non-disposable paths", async () => {
    const fx = await makeFixture();
    await writeFile(path.join(fx.source, ".env"), "T3CODE_RELAY_URL=https://user.invalid\n");
    await rejects(() => build(fx), /already contains \.env;/);
    assert.equal(await readFile(path.join(fx.source, ".env"), "utf8"), "T3CODE_RELAY_URL=https://user.invalid\n", "a user env file is never removed");
    await rm(path.join(fx.source, ".env"));
    await refusal(fx, { pnpmVersion: "10.0.0" }, /is version 10\.0\.0/, { beforeMutation: true });
    await writeFile(path.join(fx.source, "apps/web/.env.production"), "VITE_X=1\n");
    await rejects(() => build(fx), /already contains apps\/web\/\.env\.production/);
    await rm(path.join(fx.source, "apps/web/.env.production"));
    await writeFile(path.join(fx.source, ".npmrc"), "node-linker=hoisted\n");
    await rejects(() => build(fx), /\.npmrc: nodeLinker must be isolated/);
    await writeFile(path.join(fx.source, ".npmrc"), "inject-workspace-packages=true\n");
    await rejects(() => build(fx), /inject-workspace-packages must not be configured/);
    await rm(path.join(fx.source, ".npmrc"));
    await rejects(() => build(fx, {}, { destination: path.join(fx.source, "out") }), /must be disjoint/);
    await rm(fx.root, { recursive: true, force: true });
  });

  it("a prepared tree whose provenance, lock, HEAD, or content disagree with the descriptor", async () => {
    const provenanceFile = (fx) => path.join(fx.gitDir, "harbor-source.json");
    const withProvenance = async (fx, mutate) => {
      const record = structuredClone(fx.provenance);
      mutate(record);
      await writeFile(provenanceFile(fx), json(record));
    };
    const fx = await makeFixture();
    await withProvenance(fx, (r) => { r.variant = "reasoning"; });
    await refusal(fx, {}, /variant is "reasoning"; this build requires a managed-nightly tree/, { beforeMutation: true });
    await withProvenance(fx, (r) => { r.commit = "1".repeat(40); });
    await rejects(() => build(fx), /records commit 1{40}/);
    await withProvenance(fx, (r) => { r.lockRepository = "https://elsewhere.invalid/x.git"; });
    await rejects(() => build(fx), /records lock repository/);
    await withProvenance(fx, (r) => { r.patches = r.patches.slice(0, 1); });
    await rejects(() => build(fx), /patches do not match the lock's ordered managed-nightly sequence/);
    await withProvenance(fx, (r) => { r.lock = "relative/lock.json"; });
    await rejects(() => build(fx), /lock must be the absolute path/);
    await withProvenance(fx, () => {});

    // The lock the tree was prepared from has since changed (a patch byte, so its hash no longer matches).
    const lockText = await readFile(fx.lockPath, "utf8");
    await writeFile(path.join(fx.lockDir, "patches/reasoning-identity.patch"), "tampered\n");
    await rejects(() => build(fx), /sha256 mismatch/);
    await writeFile(path.join(fx.lockDir, "patches/reasoning-identity.patch"), PATCHES["reasoning-identity"]);
    await writeFile(fx.lockPath, lockText.replace('"commit": "', '"commit": "0'));
    await rejects(() => build(fx), /must be a full 40-character|pins/);
    await writeFile(fx.lockPath, lockText);

    // Content: an edited tracked file, an extra input, and a tree the patches were never applied to.
    await writeFile(path.join(fx.source, "two"), "two edited after preparation\n");
    await rejects(() => build(fx), /content differs from .* \(1 path\(s\)\): M\ttwo/);
    await writeFile(path.join(fx.source, "two"), "two patched\n");
    await writeFile(path.join(fx.source, "extra-input.js"), "module.exports = 1;\n");
    await rejects(() => build(fx), /content differs .* A\textra-input\.js/);
    await rm(path.join(fx.source, "extra-input.js"));
    await rm(path.join(fx.source, "added.txt"));
    await rejects(() => build(fx), /content differs .* D\tadded\.txt/);
    await writeFile(path.join(fx.source, "added.txt"), "added by patch\n");
    await git(fx.source, ["commit", "-q", "-am", "committed patches"]);
    await rejects(() => build(fx), /HEAD .* is not the descriptor's upstream commit/);
    await assertNothingPublished(fx);
    assert.ok(fx.calls.every((c) => c.command === "git" || c.args[0] === "--version"));
    await rm(fx.root, { recursive: true, force: true });

    // Stale dist output is an accepted rebuilt output, not content drift; a Reasoning-identity tree is drift.
    const clean = await makeFixture();
    await write(clean.source, { "apps/server/dist/old.mjs": "", "apps/web/dist/old.html": "" });
    await build(clean);
    assert.ok(!(await readdir(path.join(clean.source, "apps/server/dist"))).includes("old.mjs"), "stale dist is replaced by the build");
    await rm(clean.root, { recursive: true, force: true });
    const reasoning = await makeFixture();
    await git(reasoning.source, ["apply"], PATCHES["reasoning-identity"]);
    await rejects(() => build(reasoning), /content differs .* M\tidentity/);
    await rm(reasoning.root, { recursive: true, force: true });
  });

  it("an exact Reasoning prepared tree is verifiable only as reasoning, and the shared server refuses it before mutation", async () => {
    const indexDir = async (fx) => {
      const dir = await mkdtemp(path.join(fx.tmpRoot, "index-"));
      return dir;
    };
    const verify = (fx, expectedVariant) =>
      verifyPreparedSource({
        source: fx.source,
        descriptor: fx.descriptor,
        run: realRunner,
        env: { PATH: process.env.PATH, HOME: process.env.HOME },
        indexDir: fx.indexDir,
        ...(expectedVariant === undefined ? {} : { expectedVariant }),
      });

    // The provenance record, applied patches, and tracked content all say reasoning.
    const reasoning = await makeFixture({ variant: "reasoning" });
    reasoning.indexDir = await indexDir(reasoning);
    assert.equal(reasoning.provenance.variant, "reasoning");
    assert.equal(await readFile(path.join(reasoning.source, "identity"), "utf8"), "reasoning\n");
    const verified = await verify(reasoning, "reasoning");
    assert.deepEqual(verified.patches.map((p) => p.id), ["reasoning-full", "desktop-runtime-common", "reasoning-identity"]);
    assert.equal(verified.lockDir, reasoning.lockDir);
    await rejects(() => verify(reasoning), /variant is "reasoning"; this build requires a managed-nightly tree/);
    await rejects(() => verify(reasoning, "managed-nightly"), /variant is "reasoning"; this build requires a managed-nightly tree/);
    await rejects(() => verify(reasoning, "stock"), /expected variant "stock" is not one of managed-nightly, reasoning/);
    // The shared server builder never accepts it, and refuses before any stamp or non-version pnpm command.
    await rm(reasoning.indexDir, { recursive: true, force: true });
    await refusal(reasoning, {}, /variant is "reasoning"; this build requires a managed-nightly tree/, { beforeMutation: true });
    assert.equal(await readFile(path.join(reasoning.source, "identity"), "utf8"), "reasoning\n", "the tree is untouched");
    await rm(reasoning.root, { recursive: true, force: true });

    // A managed-nightly tree still verifies by default and explicitly, and is not a reasoning tree.
    const nightly = await makeFixture();
    nightly.indexDir = await indexDir(nightly);
    assert.deepEqual((await verify(nightly)).patches.map((p) => p.id), ["reasoning-full", "desktop-runtime-common"]);
    await rm(nightly.indexDir, { recursive: true, force: true });
    nightly.indexDir = await indexDir(nightly);
    assert.deepEqual((await verify(nightly, "managed-nightly")).patches.map((p) => p.id), ["reasoning-full", "desktop-runtime-common"]);
    await rejects(() => verify(nightly, "reasoning"), /variant is "managed-nightly"; this build requires a reasoning tree/);
    // Provenance claiming reasoning over a managed-nightly tree fails on patch agreement, then on content.
    const provenanceFile = path.join(nightly.gitDir, "harbor-source.json");
    await writeFile(provenanceFile, json({ ...nightly.provenance, variant: "reasoning" }));
    await rejects(() => verify(nightly, "reasoning"), /patches do not match the lock's ordered reasoning sequence/);
    const reasoningPatches = ["reasoning-full", "desktop-runtime-common", "reasoning-identity"].map((id) => ({
      id,
      path: path.join("patches", `${id}.patch`),
      sha256: sha256Hex(PATCHES[id]),
    }));
    await writeFile(provenanceFile, json({ ...nightly.provenance, variant: "reasoning", patches: reasoningPatches }));
    await rm(nightly.indexDir, { recursive: true, force: true });
    nightly.indexDir = await indexDir(nightly);
    await rejects(() => verify(nightly, "reasoning"), /content differs from .* plus the ordered reasoning patches .* M\tidentity/);
    await rm(nightly.root, { recursive: true, force: true });
  });

  it("a prepared tree that already carries installed dependencies or the monitor's Cargo target", async () => {
    // Each case: refused before any build command runs, the offending entry and
    // its bytes or link target are untouched, nothing stamped or written.
    const priorState = async (relative, setup, expectedPath = relative) => {
      const fx = await makeFixture();
      const external = path.join(fx.root, "external");
      await write(external, { "sentinel.txt": "external bytes\n" });
      const snapshot = await setup(fx, external);
      const pattern = expectedPath instanceof RegExp ? expectedPath : new RegExp(`source already contains ${expectedPath.replace(/[/.]/g, "\\$&")}; a fresh prepared source tree without installed dependencies or native build output is required`);
      await refusal(fx, {}, pattern, { beforeMutation: true });
      assert.ok(fx.calls.every((c) => c.command === "git" || (c.command === "pnpm" && c.args[0] === "--version")), `${relative}: only verification commands ran`);
      assert.deepEqual(await snapshot(), await snapshot.expected, `${relative}: prior entry is preserved`);
      assert.equal(await readFile(path.join(external, "sentinel.txt"), "utf8"), "external bytes\n", `${relative}: link targets are never followed`);
      await rm(fx.root, { recursive: true, force: true });
    };
    const fileSnapshot = (fx, relative, content) => {
      const snapshot = () => readFile(path.join(fx.source, relative), "utf8");
      snapshot.expected = content;
      return snapshot;
    };
    const linkSnapshot = (fx, relative, target) => {
      const snapshot = async () => ({ link: await readlink(path.join(fx.source, relative)), isLink: (await lstat(path.join(fx.source, relative))).isSymbolicLink() });
      snapshot.expected = { link: target, isLink: true };
      return snapshot;
    };

    await priorState("node_modules", async (fx) => {
      await write(fx.source, { "node_modules/.modules.yaml": "hoistPattern: []\n", "node_modules/.pnpm/lock.yaml": "" });
      return fileSnapshot(fx, "node_modules/.modules.yaml", "hoistPattern: []\n");
    });
    await priorState("apps/server/node_modules", async (fx) => {
      await write(fx.source, { "apps/server/node_modules/yaml/index.js": "module.exports = 'stale';\n" });
      return fileSnapshot(fx, "apps/server/node_modules/yaml/index.js", "module.exports = 'stale';\n");
    });
    await priorState("packages/contracts/node_modules", async (fx) => {
      await write(fx.source, { "packages/contracts/node_modules/.modules.yaml": "stale\n" });
      return fileSnapshot(fx, "packages/contracts/node_modules/.modules.yaml", "stale\n");
    });
    await priorState("scripts/node_modules", async (fx) => {
      await write(fx.source, { "scripts/node_modules": "a plain file named node_modules\n" });
      return fileSnapshot(fx, "scripts/node_modules", "a plain file named node_modules\n");
    });
    await priorState("apps/web/node_modules", async (fx, external) => {
      await mkdir(path.join(fx.source, "apps/web"), { recursive: true });
      await symlink(external, path.join(fx.source, "apps/web/node_modules"));
      return linkSnapshot(fx, "apps/web/node_modules", external);
    });
    await priorState("apps/desktop/node_modules", async (fx) => {
      await symlink("../../missing-store/node_modules", path.join(fx.source, "apps/desktop/node_modules"));
      return linkSnapshot(fx, "apps/desktop/node_modules", "../../missing-store/node_modules");
    });
    const staleBinary = "native/resource-monitor/target/aarch64-apple-darwin/release/t3-resource-monitor";
    await priorState(staleBinary, async (fx) => {
      await write(fx.source, { [staleBinary]: HEADERS["darwin-arm64"] });
      await chmod(path.join(fx.source, staleBinary), 0o755);
      const snapshot = async () => ({ bytes: (await readFile(path.join(fx.source, staleBinary))).toString("hex"), mode: (await lstat(path.join(fx.source, staleBinary))).mode & 0o777 });
      snapshot.expected = { bytes: HEADERS["darwin-arm64"].toString("hex"), mode: 0o755 };
      return snapshot;
    }, "native/resource-monitor/target");
    await priorState("native/resource-monitor/target (empty)", async (fx) => {
      await mkdir(path.join(fx.source, "native/resource-monitor/target"));
      const snapshot = async () => (await lstat(path.join(fx.source, "native/resource-monitor/target"))).isDirectory();
      snapshot.expected = true;
      return snapshot;
    }, "native/resource-monitor/target");
    await priorState("native/resource-monitor/target", async (fx, external) => {
      await symlink(external, path.join(fx.source, "native/resource-monitor/target"));
      return linkSnapshot(fx, "native/resource-monitor/target", external);
    }, /prepared source content differs from .* A\tnative\/resource-monitor\/target/);
  });
});

describe("failures after mutation publish nothing and clean up", () => {
  const cases = [
    ["the frozen install rewrites the lock", { installMutatesLock: true }, /pnpm install modified pnpm-lock\.yaml/],
    ["the build leaves no client bundle", { omitClient: true }, /server build output: missing .*client\/index\.html/],
    ["the monitor is not a target executable", { badHeader: true }, /not a Mach-O 64-bit arm64/],
    ["the monitor is not executable", { nonExecutable: true }, /is not executable/],
    ["the modern deploy fails (no legacy fallback)", { deployFails: true }, /modern offline production deploy failed: .*NONINJECTED/],
    ["the deployed lock drifts from the source importer", { lockDrift: true }, /yaml: deployed 2\.8\.0, source 2\.9\.0/],
    ["the generated manifest keeps a catalog reference", { unresolvedSpec: true }, /effect: generated manifest carries catalog:/],
    ["the dedicated lock has another importer", { extraImporter: true }, /importers are \., apps\/web/],
    ["the stage was linked with a hoisted linker", { nodeLinker: "hoisted" }, /nodeLinker hoisted/],
    ["the stage used a global virtual store", { globalStore: true }, /global virtual store/],
    ["a link escapes the stage", { escapingLink: true }, /escapes the stage/],
    ["a link dangles", { danglingLink: true }, /dangling/],
    ["a link is absolute", { absoluteLink: true }, /is absolute/],
    ["Electron is deployed", { includeElectron: true }, /electron@38\.0\.0; workspace and Electron packages/],
    ["a workspace package is deployed", { includeWorkspace: true }, /node_modules\/@t3tools; workspace and Electron/],
    ["the target native extractor is missing", { omitNative: true }, /native runtime probe failed .*msgpackr-extract-/],
    ["an ordinary JS loader is missing", { omitLoader: true }, /native runtime probe failed .*node-addon-api/],
    ["the target fff library is missing", { omitFffBin: true }, /native runtime probe failed .*did not resolve/],
    ["the target ffi-rs addon is missing", { omitFfiNative: true }, /native runtime probe failed .*ffi-rs-/],
    ["node-pty cannot load its addon", { ptyThrows: true }, /native runtime probe failed .*pty\.node/],
    ["the fff library carries the unprefixed spelling", { fffLibrary: "fff_c.dylib" }, /did not resolve libfff_c\.dylib for this target/],
    ["the CLI reports another version", { bin: { version: "0.0.38" } }, /reports version "t3 v0\.0\.38", expected "t3 v0\.0\.39-nightly\.20260905\.1284\.managed\.1\.p[0-9a-f]+"/],
    ["the CLI reports another command name", { bin: { name: "t3-nightly" } }, /reports version "t3-nightly v0\.0\.39-nightly/],
    ["the CLI prints a bare version without its name", { bin: { name: null } }, /reports version "0\.0\.39-nightly[^"]*", expected "t3 v0\.0\.39-nightly/],
    ["the CLI prints extra lines after its identity", { bin: { extraLines: ["Node v24.13.1"] } }, /reports version "t3 v0\.0\.39-nightly[^"]*\\nNode v24\.13\.1"/],
    ["the preflight answers another protocol", { bin: { protocol: 3 } }, /preflight returned .*"launcherProtocol":3/],
    ["the preflight creates a database", { bin: { createDb: true } }, /created never-created\.sqlite/],
  ];
  for (const [name, opts, pattern] of cases) {
    it(name, async () => {
      const fx = await makeFixture();
      await refusal(fx, opts, pattern);
      if (opts.deployFails) assert.equal(fx.calls.filter((c) => c.args.includes("deploy")).length, 1, "deploy is attempted exactly once");
      await rm(fx.root, { recursive: true, force: true });
    });
  }

  it("a deployed monitor for the wrong target is refused even when the source build passed", async () => {
    const fx = await makeFixture({ target: "linux-x64" });
    await refusal(fx, { badHeader: true }, /not an ELF 64-bit/);
    await rm(fx.root, { recursive: true, force: true });
  });

  it("the Linux fff library must be libfff_c.so exactly", async () => {
    const fx = await makeFixture({ target: "linux-x64" });
    await refusal(fx, { fffLibrary: "fff_c.so" }, /did not resolve libfff_c\.so for this target/);
    await rm(fx.root, { recursive: true, force: true });
  });
});

describe("CLI", () => {
  it("parses the designed flags and requires each input", () => {
    const options = parseArgs(["--source", "src", "--descriptor", "d.json", "--public-config", "c.json", "--platform", "darwin", "--arch", "arm64", "--destination", "out"]);
    assert.deepEqual(options, {
      source: path.resolve("src"),
      descriptor: path.resolve("d.json"),
      publicConfig: path.resolve("c.json"),
      platform: "darwin",
      arch: "arm64",
      destination: path.resolve("out"),
      pnpm: "pnpm",
    });
    assert.equal(parseArgs([...["--source", "s", "--descriptor", "d", "--public-config", "c", "--platform", "linux", "--arch", "x64", "--destination", "o"], "--pnpm", "/opt/pnpm"]).pnpm, "/opt/pnpm");
    throws(() => parseArgs(["--source", "s"]), /--descriptor is required/);
    throws(() => parseArgs(["--reuse-build", "dist"]), /unknown argument --reuse-build/);
    throws(() => parseArgs(["--source", "s", "--source", "t"]), /given more than once/);
  });

  it("refuses a tampered descriptor before touching the tree, and does not run on import", async () => {
    const fx = await makeFixture();
    const descriptorPath = path.join(fx.root, "release.json");
    const configPath = path.join(fx.root, "public-config.json");
    const tampered = structuredClone(fx.descriptor);
    tampered.publicConfig.sha256 = "0".repeat(64);
    await writeFile(descriptorPath, canonicalJson(tampered));
    await writeFile(configPath, JSON.stringify(PUBLIC_CONFIG));
    const args = [builderScript, "--source", fx.source, "--descriptor", descriptorPath, "--public-config", configPath, "--platform", "darwin", "--arch", "arm64", "--destination", path.join(fx.out, "release")];
    const result = await run(process.execPath, args).then(
      () => assert.fail("must exit non-zero"),
      (error) => error,
    );
    assert.match(result.stderr, /build-managed-server-runtime: .*does not match the digest recomputed/);
    for (const value of Object.values(PUBLIC_CONFIG)) assert.doesNotMatch(result.stdout + result.stderr, new RegExp(value.replace(/[.]/g, "\\.")));
    await assertNothingPublished(fx);
    const { stdout, stderr } = await run(process.execPath, ["--input-type=module", "-e", `await import(${JSON.stringify(builderScript)});`]);
    assert.equal(stdout + stderr, "");
    await rm(fx.root, { recursive: true, force: true });
  });
});
