#!/usr/bin/env node
// Build the portable managed shared-server runtime of one managed T3 release
// for the native host target, from an explicitly supplied, disposable,
// prepared `managed-nightly` source tree.
//
// Rebuild-only: there is no mode that trusts a pre-existing `dist`. Before the
// tree is touched, the descriptor (resolve-managed-release.mjs) must
// reproduce its own digest, the explicit four-key public config must
// fingerprint to the descriptor's value, the tree's provenance record must
// name the descriptor's upstream commit and exactly the `managed-nightly`
// patch sequence, the lock that record points at must still say the same, and
// the tracked content of the tree must equal the pinned upstream commit plus
// the ordered patches, materialized in a private index. Only then is the tree
// mutated: the four release package versions are stamped, a task-owned `.env`
// carrying exactly the four public values is written, the pinned pnpm
// installs from the frozen lock, the web and server build task runs, the
// resource monitor is compiled natively, and the modern offline production
// deploy stages `node_modules/t3` in a private directory. The stage is
// verified (unchanged source lock hashes, exact production resolutions,
// confined relative pnpm links, target-native packages loaded from an
// unrelated cwd, the monitor's executable header, the CLI's exact version,
// and the identity-only preflight that must not create a database), stripped
// of installation bookkeeping that records this host's paths, archived, and
// published as one `.tar.gz` plus one inventory record into a new directory.
//
// Accepted targets are `darwin-arm64` and `linux-x64`; the host must be the
// target (no cross builds), on Node 24.13.1 with pnpm 11.10.0. Nothing here
// contacts the network deliberately, starts the server, or publishes remotely.
// Configuration values and the inherited environment are never printed.
//
// Every external process goes through one injectable runner so unit tests
// drive the whole sequence against tiny fixtures without installing
// dependencies or compiling Rust. Node built-ins only, plus the release
// contract's own helpers; the source tree's already-installed `yaml` package
// parses pnpm lockfiles after the install step.
import { spawn } from "node:child_process";
import {
  chmod,
  copyFile,
  lstat,
  mkdir,
  mkdtemp,
  readdir,
  readFile,
  readlink,
  realpath,
  rename,
  rm,
  rmdir,
  writeFile,
} from "node:fs/promises";
import { createRequire } from "node:module";
import { tmpdir } from "node:os";
import path from "node:path";
import { parseEnv } from "node:util";
import {
  MANAGED_NIGHTLY_VARIANT,
  PUBLIC_CONFIG_KEYS,
  REQUIRED_VARIANTS,
  ReleaseError,
  canonicalJson,
  computePublicConfigFingerprint,
  isEntryPoint,
  readVerifiedLock,
  resolveReleaseVariants,
  sha256Hex,
} from "./resolve-managed-release.mjs";
import {
  EXPECTED_ARTIFACTS,
  SERVER_ENTRY,
  SERVER_LAUNCHER_PROTOCOL,
  hashFile,
  validateDescriptor,
} from "./write-managed-release-manifest.mjs";

export const PINNED_NODE_VERSION = "24.13.1";
export const PINNED_PACKAGE_MANAGER = "pnpm@11.10.0";
export const PINNED_PNPM_VERSION = "11.10.0";
export const SERVER_PACKAGE_NAME = "t3";
export const SERVER_IMPORTER = "apps/server";
export const PRODUCT_VARIANT_ENV = "T3CODE_PRODUCT_VARIANT";
// The same four files upstream's scripts/update-release-package-versions.ts
// stamps. That script needs an installed workspace; this list is checked
// against it by hand and the stamping here uses built-ins only.
export const RELEASE_PACKAGE_FILES = Object.freeze([
  "apps/server/package.json",
  "apps/desktop/package.json",
  "apps/web/package.json",
  "packages/contracts/package.json",
]);
// Host-native targets only. Each names the Rust triple, the packaged monitor
// directory, and the platform packages the native runtime closure must load.
export const SUPPORTED_TARGETS = Object.freeze({
  "darwin-arm64": Object.freeze({
    platform: "darwin",
    arch: "arm64",
    rustTarget: "aarch64-apple-darwin",
    fffPackage: "@ff-labs/fff-bin-darwin-arm64",
    fffLibrary: "libfff_c.dylib",
    ffiPackage: "@yuuang/ffi-rs-darwin-arm64",
    msgpackrPackage: "@msgpackr-extract/msgpackr-extract-darwin-arm64",
  }),
  "linux-x64": Object.freeze({
    platform: "linux",
    arch: "x64",
    rustTarget: "x86_64-unknown-linux-gnu",
    fffPackage: "@ff-labs/fff-bin-linux-x64-gnu",
    fffLibrary: "libfff_c.so",
    ffiPackage: "@yuuang/ffi-rs-linux-x64-gnu",
    msgpackrPackage: "@msgpackr-extract/msgpackr-extract-linux-x64",
  }),
});
export const MONITOR_BINARY = "t3-resource-monitor";
export const MONITOR_MANIFEST = "native/resource-monitor/Cargo.toml";
// Cargo's build cache for the monitor. Any prior entry here, like any prior
// node_modules, is ignored by git yet feeds the build, so it must be absent.
export const MONITOR_TARGET_DIRECTORY = "native/resource-monitor/target";
// Direct production roots of apps/server. All are deployed; the Bun-only
// entries are resolved but never loaded on Node.
export const BUN_ONLY_ROOTS = Object.freeze(["@effect/platform-bun", "@effect/sql-sqlite-bun"]);
// Files the stage must contain, relative to node_modules/t3.
const REQUIRED_STAGE_FILES = ["package.json", "dist/bin.mjs", "dist/service-launcher.mjs", "dist/client/index.html"];
// Installation bookkeeping pnpm writes into the stage that Node never reads
// and that records this host's absolute paths. Relative to node_modules/t3;
// nothing under .pnpm's package payloads is ever touched. Taken from the
// verified offline deploy smoke of this lock.
export const STAGED_INSTALL_METADATA = Object.freeze([
  "pnpm-lock.yaml",
  "pnpm-workspace.yaml",
  "node_modules/.modules.yaml",
  "node_modules/.package-map.json",
  "node_modules/.pnpm-workspace-state-v1.json",
  "node_modules/.pnpm/lock.yaml",
  "node_modules/.bin",
  "node_modules/.pnpm/node_modules/.bin",
]);
// Names that must never appear anywhere in the archive: host state,
// installer sentinels, configuration, and the metadata above.
const FORBIDDEN_ARCHIVE_NAMES = new Set([
  ".install-complete",
  ".managed-artifact.json",
  ".env",
  ".env.local",
  ".modules.yaml",
  ".package-map.json",
  ".pnpm-workspace-state-v1.json",
]);
const SOURCE_HASH_FILES = ["pnpm-lock.yaml", "pnpm-workspace.yaml", "apps/server/package.json"];
const ENV_FILE_DIRECTORIES = [".", "apps/web", "apps/server"];
const FORBIDDEN_DEPENDENCY_PROTOCOLS = /^(workspace|link|file):/;

function fail(message) {
  throw new ReleaseError(message);
}

// The closed set of variants a prepared tree can be verified as. The shared
// server is always built from managed-nightly; the desktop builder chooses
// one of the two. Anything else is refused before it can select patches.
function expectVariant(value) {
  if (!REQUIRED_VARIANTS.includes(value)) {
    fail(`expected variant ${JSON.stringify(value)} is not one of ${REQUIRED_VARIANTS.join(", ")}`);
  }
  return value;
}

function isPlainObject(value) {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function sameJson(a, b) {
  return JSON.stringify(a) === JSON.stringify(b);
}

function isWithin(dir, target) {
  const relative = path.relative(dir, target);
  if (relative === "") return true;
  if (path.isAbsolute(relative)) return false;
  return relative !== ".." && !relative.startsWith(`..${path.sep}`);
}

async function exists(target) {
  try {
    await lstat(target);
    return true;
  } catch (error) {
    if (error.code === "ENOENT") return false;
    throw error;
  }
}

// Nearest existing ancestor with symlinks resolved plus the lexical tail, so
// paths that do not exist yet can still be compared for aliasing.
async function canonicalPath(target) {
  let existing = path.resolve(target);
  const tail = [];
  for (;;) {
    try {
      return path.join(await realpath(existing), ...tail);
    } catch (error) {
      if (error.code !== "ENOENT" && error.code !== "ENOTDIR") throw error;
    }
    const parent = path.dirname(existing);
    if (parent === existing) return path.join(existing, ...tail);
    tail.unshift(path.basename(existing));
    existing = parent;
  }
}

async function readJson(file, label) {
  let text;
  try {
    text = await readFile(file, "utf8");
  } catch (error) {
    fail(`cannot read ${label} ${file}: ${error.message}`);
  }
  try {
    return JSON.parse(text);
  } catch (error) {
    fail(`cannot parse ${label} ${file}: ${error.message}`);
  }
}

async function hashPath(file) {
  return sha256Hex(await readFile(file));
}

function tail(error, lines = 5) {
  const text = `${error.stderr ?? ""}\n${error.stdout ?? ""}`.trim() || error.message;
  return text.split("\n").filter(Boolean).slice(-lines).join(" | ");
}

// --- process runner -------------------------------------------------------------

// The single seam for external processes. A runner receives
// `{ command, args, cwd, env, input }` and resolves `{ stdout, stderr }` on
// exit 0, rejecting with an error carrying `stdout`, `stderr`, and `code`
// otherwise. Never a shell. With `stream`, child output is echoed to stderr
// so long builds show progress; the environment itself is never printed.
export function createRunner({ stream = false } = {}) {
  return ({ command, args, cwd, env, input }) =>
    new Promise((resolve, reject) => {
      const child = spawn(command, args, { cwd, env, stdio: ["pipe", "pipe", "pipe"], shell: false });
      const out = [];
      const err = [];
      child.stdout.on("data", (chunk) => {
        out.push(chunk);
        if (stream) process.stderr.write(chunk);
      });
      child.stderr.on("data", (chunk) => {
        err.push(chunk);
        if (stream) process.stderr.write(chunk);
      });
      child.on("error", reject);
      child.on("close", (code, signal) => {
        const stdout = Buffer.concat(out).toString("utf8");
        const stderr = Buffer.concat(err).toString("utf8");
        if (code === 0) {
          resolve({ stdout, stderr });
          return;
        }
        const error = new Error(`${command} ${args.join(" ")} exited with ${code ?? signal}`);
        Object.assign(error, { stdout, stderr, code });
        reject(error);
      });
      child.stdin.on("error", () => {}); // a failing child may close stdin early
      child.stdin.end(input);
    });
}

// --- target and host --------------------------------------------------------------

export function describeHost() {
  return {
    platform: process.platform,
    arch: process.arch,
    nodeVersion: process.versions.node,
    glibcVersionRuntime:
      process.platform === "linux" ? process.report?.getReport?.()?.header?.glibcVersionRuntime : undefined,
  };
}

// Only the two fixed targets, only when the host is that target on the pinned
// Node. Linux additionally needs a confirmed glibc runtime: an unknown or
// musl host is refused rather than assumed.
export function resolveTarget(platform, arch, host) {
  const key = `${platform}-${arch}`;
  const target = SUPPORTED_TARGETS[key];
  if (target === undefined) {
    fail(`target ${key} is not supported; expected one of ${Object.keys(SUPPORTED_TARGETS).join(", ")}`);
  }
  if (host.platform !== platform || host.arch !== arch) {
    fail(`target ${key} must be built on a ${key} host; this host is ${host.platform}-${host.arch}`);
  }
  if (platform === "linux" && (typeof host.glibcVersionRuntime !== "string" || host.glibcVersionRuntime === "")) {
    fail("target linux-x64 requires a confirmed glibc runtime; the host reports none (musl or unknown libc)");
  }
  if (host.nodeVersion !== PINNED_NODE_VERSION) {
    fail(`managed server builds require Node ${PINNED_NODE_VERSION}; this host runs ${host.nodeVersion}`);
  }
  const artifact = EXPECTED_ARTIFACTS.find((a) => a.kind === "server" && a.platform === platform && a.arch === arch);
  return { key, ...target, artifact };
}

// --- version stamping --------------------------------------------------------------

// Sets `version` in the four release manifests, preserving every other field
// and their order. Built-ins only, so it works on a tree with no install.
export async function stampReleasePackageVersions(sourceDir, version) {
  const stamped = [];
  for (const relative of RELEASE_PACKAGE_FILES) {
    const file = path.join(sourceDir, relative);
    const manifest = await readJson(file, "release package manifest");
    if (!isPlainObject(manifest)) fail(`${relative} is not a JSON object`);
    manifest.version = version;
    await writeFile(file, `${JSON.stringify(manifest, null, 2)}\n`);
    stamped.push(relative);
  }
  return stamped;
}

// --- public configuration ------------------------------------------------------------

// Dotenv text for exactly the four public values. `util.parseEnv` (what the
// source's loadRepoEnv uses) applies no escape processing inside quotes, so
// each value is wrapped in whichever quote it does not contain and the text
// is parsed back before it is trusted: a value that cannot round-trip is
// refused instead of silently changed. Values never appear in errors.
export function encodeDotenv(values) {
  const lines = PUBLIC_CONFIG_KEYS.map((key) => {
    const value = values[key];
    const quote = value.includes('"') ? "'" : '"';
    return `${key}=${quote}${value}${quote}`;
  });
  const text = `${lines.join("\n")}\n`;
  const parsed = parseEnv(text);
  for (const key of PUBLIC_CONFIG_KEYS) {
    if (parsed[key] !== values[key]) fail(`public config ${key} cannot be encoded as dotenv without altering it`);
  }
  if (Object.keys(parsed).length !== PUBLIC_CONFIG_KEYS.length) fail("dotenv encoding produced unexpected keys");
  return text;
}

const DROPPED_ENV_PREFIXES = ["VITE_", "EXPO_PUBLIC_", "T3CODE_", "VERCEL", "npm_", "CARGO_TARGET_", "CARGO_BUILD_"];
const DROPPED_ENV_KEYS = new Set([
  "APP_VERSION",
  "NODE_OPTIONS",
  "NODE_PATH",
  "ELECTRON_RUN_AS_NODE",
  "RUSTFLAGS",
  "CARGO_ENCODED_RUSTFLAGS",
  "COPYFILE_DISABLE",
  "GITHUB_REPOSITORY",
]);

// The environment every build tool runs with: the caller's ordinary tool
// environment (PATH, HOME, temp, toolchain homes) minus every build alias,
// identity override, tracing value, Node loader hook, package-manager target
// override, cargo target/flag override, and release-feed selector, plus exactly the four canonical
// public values and the compile-time product variant (managed-nightly unless
// the caller names the other closed variant).
export function buildChildEnvironment(baseEnv, publicConfig, expectedVariant = MANAGED_NIGHTLY_VARIANT) {
  const variant = expectVariant(expectedVariant);
  const env = {};
  for (const [key, value] of Object.entries(baseEnv)) {
    if (value === undefined) continue;
    if (DROPPED_ENV_KEYS.has(key)) continue;
    if (DROPPED_ENV_PREFIXES.some((prefix) => key.startsWith(prefix))) continue;
    env[key] = value;
  }
  for (const key of PUBLIC_CONFIG_KEYS) env[key] = publicConfig[key];
  env[PRODUCT_VARIANT_ENV] = variant;
  return env;
}

// What the deployed CLI and the native probe run with: PATH only, a
// disposable HOME and temp, no loader hooks, no configuration.
function verificationEnvironment(childEnv, home) {
  return { PATH: childEnv.PATH ?? "", HOME: home, TMPDIR: home };
}

function gitEnvironment(childEnv) {
  return {
    ...childEnv,
    GIT_TERMINAL_PROMPT: "0",
    GIT_CONFIG_GLOBAL: "/dev/null",
    GIT_CONFIG_NOSYSTEM: "1",
  };
}

// --- prepared source -------------------------------------------------------------------

// The `.git` entry of a worktree is a file naming the real git directory;
// git itself resolves either form, so the provenance record the preparer
// wrote next to the repository metadata is looked up through git.
async function gitDirectory(git, source) {
  const { stdout } = await git(["rev-parse", "--absolute-git-dir"]).catch((error) =>
    fail(`source ${source} is not a git checkout: ${tail(error)}`),
  );
  return stdout.trim();
}

// Provenance agreement plus actual content agreement. Metadata that says the
// right thing is necessary, not sufficient: the pinned commit is read into a
// private index, the verified patch bytes are applied to it in order, and
// the resulting tree must equal the tree of the working directory's tracked
// and untracked (non-ignored) files, read into a second private index. The
// preparer's uncommitted patch application is therefore expected, while any
// edit, extra input, or missing file is a mismatch. Ignored paths
// (node_modules, dist, .env) are outside this comparison and handled
// separately. The tree must be prepared as `expectedVariant` (managed-nightly
// unless the caller names the other closed variant), and that one value
// selects the provenance check, the lock's patch sequence, and the descriptor
// entry. Returns the lock directory, ordered patches, and verified tree entries.
export async function verifyPreparedSource({ source, descriptor, run, env, indexDir, expectedVariant = MANAGED_NIGHTLY_VARIANT }) {
  const variant = expectVariant(expectedVariant);
  const git = (args, options = {}) =>
    run({ command: "git", args, cwd: source, env: { ...gitEnvironment(env), ...options.env }, input: options.input });
  const commit = descriptor.upstreamCommit;
  const gitDir = await gitDirectory(git, source);
  const head = (await git(["rev-parse", "--verify", "HEAD^{commit}"]).catch(() => fail(`source ${source} has no HEAD commit`)))
    .stdout.trim();
  if (head !== commit) fail(`source HEAD ${head} is not the descriptor's upstream commit ${commit}`);

  const provenanceFile = path.join(gitDir, "harbor-source.json");
  const provenance = await readJson(provenanceFile, "prepared-source provenance");
  if (!isPlainObject(provenance)) fail(`${provenanceFile}: must be a JSON object`);
  if (provenance.variant !== variant) {
    fail(`prepared source variant is ${JSON.stringify(provenance.variant)}; this build requires a ${variant} tree`);
  }
  if (provenance.commit !== commit) fail(`prepared source records commit ${provenance.commit}, descriptor pins ${commit}`);
  if (provenance.lockRepository !== descriptor.upstreamRepository) {
    fail(`prepared source records lock repository ${provenance.lockRepository}, descriptor names ${descriptor.upstreamRepository}`);
  }
  if (typeof provenance.lock !== "string" || !path.isAbsolute(provenance.lock)) {
    fail(`${provenanceFile}: lock must be the absolute path of the lock the tree was prepared from`);
  }
  const lock = await readVerifiedLock(provenance.lock);
  if (lock.commit !== commit) fail(`lock ${provenance.lock} pins ${lock.commit}, descriptor pins ${commit}`);
  if (lock.repository !== descriptor.upstreamRepository) {
    fail(`lock ${provenance.lock} names repository ${lock.repository}, descriptor names ${descriptor.upstreamRepository}`);
  }
  const expected = resolveReleaseVariants(lock).variants[variant];
  if (!sameJson(provenance.patches, expected)) {
    fail(`prepared source patches do not match the lock's ordered ${variant} sequence`);
  }
  const identity = (patches) => patches.map(({ id, sha256 }) => ({ id, sha256 }));
  if (!sameJson(identity(descriptor.variants[variant].patches), identity(expected))) {
    fail(`descriptor ${variant} patches do not match the lock's ordered sequence`);
  }
  const lockDir = await realpath(path.dirname(provenance.lock));
  const patches = [];
  for (const patch of expected) {
    const bytes = await readFile(path.resolve(lockDir, patch.path));
    if (sha256Hex(bytes) !== patch.sha256) fail(`patch ${patch.path}: sha256 changed since the lock was verified`);
    patches.push({ ...patch, bytes });
  }

  const expectedIndex = { GIT_INDEX_FILE: path.join(indexDir, "expected.index") };
  const actualIndex = { GIT_INDEX_FILE: path.join(indexDir, "actual.index") };
  await git(["read-tree", commit], { env: expectedIndex });
  for (const patch of patches) {
    await git(["apply", "--cached"], { env: expectedIndex, input: patch.bytes }).catch((error) =>
      fail(`patch ${patch.id} does not apply to ${commit}: ${tail(error)}`),
    );
  }
  const expectedTree = (await git(["write-tree"], { env: expectedIndex })).stdout.trim();
  await git(["read-tree", commit], { env: actualIndex });
  await git(["add", "-A", "--", "."], { env: actualIndex });
  const actualTree = (await git(["write-tree"], { env: actualIndex })).stdout.trim();
  if (expectedTree !== actualTree) {
    const { stdout } = await git(["diff-tree", "-r", "--name-status", expectedTree, actualTree]);
    const changes = stdout.trim().split("\n").filter(Boolean);
    fail(
      `prepared source content differs from ${commit} plus the ordered ${variant} patches ` +
        `(${changes.length} path(s)): ${changes.slice(0, 20).join("; ")}`,
    );
  }
  const { stdout: listing } = await git(["ls-tree", "-r", "-t", "-z", expectedTree]);
  const trackedDependencyEntries = new Map();
  for (const entry of listing.split("\0").filter(Boolean)) {
    const separator = entry.indexOf("\t");
    const relative = entry.slice(separator + 1);
    if (relative.split("/").includes("node_modules")) {
      trackedDependencyEntries.set(relative, entry.slice(0, 6));
    }
  }
  return { gitDir, lockDir, patches: expected, trackedDependencyEntries };
}

// Refuses any dotenv file the tree already carries where the build would read
// one, rather than overwriting or inheriting user configuration.
export async function refuseExistingEnvFiles(source) {
  for (const dir of ENV_FILE_DIRECTORIES) {
    const names = await readdir(path.join(source, dir)).catch(() => []);
    for (const name of names) {
      if (name.startsWith(".env") && name !== ".env.example") {
        fail(`source already contains ${path.join(dir, name)}; the builder only works on a fresh tree without env files`);
      }
    }
  }
}

// Refuses installed dependencies and the monitor's Cargo target. Exact tracked
// fixture entries may be supplied only after prepared-source verification;
// their bytes already match the expected tree. Walk every fixture descendant
// so ignored additions (including empty directories) cannot hide in it.
// Source/package/workspace install roots never qualify as fixtures. Compare
// executable state explicitly because Git may have core.filemode disabled.
// Symlinks are never allowed inside these subtrees or followed, and nothing
// is removed. Git metadata outside dependency subtrees is skipped.
export async function refusePriorBuildState(source, trackedDependencyEntries = new Map()) {
  const pending = ["."];
  while (pending.length > 0) {
    const dir = pending.pop();
    const entries = await readdir(path.join(source, dir), { withFileTypes: true }).catch((error) => fail(`cannot read ${dir} in source: ${error.message}`));
    const installRoot = dir === "." || entries.some((entry) => ["package.json", "pnpm-workspace.yaml"].includes(entry.name));
    for (const entry of entries.sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0))) {
      if (entry.name === ".git" && !dir.split("/").includes("node_modules")) continue;
      const relative = dir === "." ? entry.name : `${dir}/${entry.name}`;
      const inDependencies = relative.split("/").includes("node_modules");
      const expectedMode = trackedDependencyEntries.get(relative);
      let trackedFixtureEntry = entry.isDirectory()
        ? expectedMode === "040000"
        : entry.isFile() && ["100644", "100755"].includes(expectedMode);
      if (trackedFixtureEntry && entry.isFile()) {
        const { mode } = await lstat(path.join(source, relative));
        trackedFixtureEntry = (mode & 0o111) === (expectedMode === "100755" ? 0o111 : 0);
      }
      if ((inDependencies && !trackedFixtureEntry) || (entry.name === "node_modules" && installRoot) || relative === MONITOR_TARGET_DIRECTORY) {
        fail(`source already contains ${relative}; a fresh prepared source tree without installed dependencies or native build output is required`);
      }
      if (entry.isDirectory()) pending.push(relative);
    }
  }
}

// Production dependencies of apps/server must not reach into the workspace:
// the modern deploy route below is only valid while every runtime root is a
// registry package (catalog: expands to one).
function checkServerManifest(manifest, relative) {
  if (manifest.name !== SERVER_PACKAGE_NAME) fail(`${relative}: package name is ${manifest.name}, expected ${SERVER_PACKAGE_NAME}`);
  for (const field of ["dependencies", "optionalDependencies"]) {
    for (const [name, spec] of Object.entries(manifest[field] ?? {})) {
      if (typeof spec !== "string" || FORBIDDEN_DEPENDENCY_PROTOCOLS.test(spec)) {
        fail(`${relative}: production dependency ${name} uses ${String(spec)}; workspace, link, and file dependencies cannot be deployed`);
      }
    }
  }
}

// pnpm settings that would change how the stage is linked, in the workspace
// file or a repository .npmrc. Line-level, since no YAML parser is installed
// before the install step; the actual linker is re-checked from the stage.
async function checkLinkerSettings(source) {
  for (const relative of ["pnpm-workspace.yaml", ".npmrc"]) {
    const text = await readFile(path.join(source, relative), "utf8").catch(() => "");
    for (const line of text.split("\n")) {
      const match = /^\s*([A-Za-z-]+)\s*[:=]\s*(\S+)/.exec(line);
      if (match === null) continue;
      const key = match[1].replace(/-([a-z])/g, (_, c) => c.toUpperCase());
      if (key === "nodeLinker" && match[2] !== "isolated") fail(`${relative}: nodeLinker must be isolated`);
      if (["enableGlobalVirtualStore", "injectWorkspacePackages", "sharedWorkspaceLockfile"].includes(key) && match[2] !== "false") {
        fail(`${relative}: ${match[1]} must not be configured; the deploy invocation sets what it needs`);
      }
    }
  }
}

// --- stage verification ------------------------------------------------------------------

// Dedicated-lock agreement: the generated lock's sole importer is `.`, its
// production dependency names equal the source manifest's, every resolution
// equals the original apps/server importer's (version strings carry patch
// hashes and peer selections), the generated manifest carries those exact
// resolutions with no catalog/workspace/link/file references left, and each
// package's resolution (integrity) is unchanged.
export function compareDeployedLock({ sourceLock, sourceManifest, deployedLock, deployedManifest }) {
  const importers = Object.keys(deployedLock.importers ?? {});
  if (!sameJson(importers, ["."])) fail(`deployed lock importers are ${importers.join(", ") || "(none)"}; expected exactly .`);
  const origin = sourceLock.importers?.[SERVER_IMPORTER];
  if (!isPlainObject(origin)) fail(`source lock has no ${SERVER_IMPORTER} importer`);
  const deployed = deployedLock.importers["."];
  const differences = [];
  for (const field of ["dependencies", "optionalDependencies"]) {
    const names = Object.keys(sourceManifest[field] ?? {}).sort();
    const deployedNames = Object.keys(deployedManifest[field] ?? {}).sort();
    const lockNames = Object.keys(deployed[field] ?? {}).sort();
    if (!sameJson(names, deployedNames) || !sameJson(names, lockNames)) {
      fail(`deployed ${field} are ${lockNames.join(", ") || "(none)"}; source declares ${names.join(", ") || "(none)"}`);
    }
    for (const name of names) {
      const expected = origin[field]?.[name]?.version;
      const actual = deployed[field]?.[name]?.version;
      const spec = deployedManifest[field][name];
      if (typeof expected !== "string") differences.push(`${name}: no resolution in source ${SERVER_IMPORTER} importer`);
      else if (actual !== expected) differences.push(`${name}: deployed ${actual}, source ${expected}`);
      else if (spec !== expected) differences.push(`${name}: generated manifest carries ${spec}, lock ${expected}`);
      if (typeof spec === "string" && /^(catalog|workspace|link|file):/.test(spec)) differences.push(`${name}: unresolved ${spec}`);
      if (typeof expected !== "string") continue;
      const key = `${name}@${expected.split("(")[0]}`;
      const sourceResolution = sourceLock.packages?.[key]?.resolution;
      const deployedResolution = deployedLock.packages?.[key]?.resolution;
      if (sourceResolution === undefined || deployedResolution === undefined) differences.push(`${key}: missing package resolution`);
      else if (!sameJson(sourceResolution, deployedResolution)) differences.push(`${key}: package resolution differs`);
    }
  }
  if (differences.length > 0) fail(`deployed production resolutions differ from the source lock: ${differences.join("; ")}`);
  return Object.keys(sourceManifest.dependencies ?? {});
}

// Mach-O 64-bit arm64, or ELF 64-bit little-endian x86-64. Fat binaries,
// other architectures, and scripts are all refused.
export function checkExecutableHeader(bytes, target) {
  if (target.platform === "darwin") {
    if (bytes.length < 8 || bytes.readUInt32LE(0) !== 0xfeedfacf || bytes.readUInt32LE(4) !== 0x0100000c) {
      fail(`${MONITOR_BINARY} is not a Mach-O 64-bit arm64 executable`);
    }
    return;
  }
  if (
    bytes.length < 20 ||
    bytes.toString("latin1", 0, 4) !== "\x7fELF" ||
    bytes[4] !== 2 ||
    bytes[5] !== 1 ||
    bytes.readUInt16LE(18) !== 0x3e
  ) {
    fail(`${MONITOR_BINARY} is not an ELF 64-bit little-endian x86-64 executable`);
  }
}

async function requireRegularFile(file, label) {
  const stats = await lstat(file).catch(() => fail(`${label}: missing ${file}`));
  if (stats.isSymbolicLink()) fail(`${label}: ${file} is a symbolic link`);
  if (!stats.isFile()) fail(`${label}: ${file} is not a regular file`);
  if (stats.size === 0) fail(`${label}: ${file} is empty`);
  return stats;
}

async function checkMonitor(file, target) {
  const stats = await requireRegularFile(file, "resource monitor");
  if ((stats.mode & 0o111) === 0) fail(`resource monitor ${file} is not executable`);
  checkExecutableHeader(await readFile(file), target);
}

// Every symlink under `root` must be relative, resolve inside `root`, and
// exist. Symlinked directories are not descended (their targets are visited
// as real directories). Returns the number of links checked.
export async function verifyStageLinks(root) {
  const realRoot = await realpath(root);
  let count = 0;
  async function walk(dir) {
    for (const entry of await readdir(dir, { withFileTypes: true })) {
      const file = path.join(dir, entry.name);
      if (entry.isSymbolicLink()) {
        const link = await readlink(file);
        if (path.isAbsolute(link)) fail(`stage link ${file} is absolute (${link}); only relative links are portable`);
        const nominal = path.resolve(dir, link);
        if (!isWithin(realRoot, nominal)) fail(`stage link ${file} escapes the stage (${link})`);
        const real = await realpath(nominal).catch(() => fail(`stage link ${file} is dangling (${link})`));
        if (!isWithin(realRoot, real)) fail(`stage link ${file} resolves outside the stage`);
        count += 1;
      } else if (entry.isDirectory()) {
        await walk(file);
      }
    }
  }
  await walk(realRoot);
  return count;
}

// Runs inside a short Node child anchored at the deployed package: resolves
// every production root, loads the Node-side native modules and their JS
// loaders from the deployed files, and opens the fff library for the target
// without creating a finder. Prints the resolved paths as JSON; the parent
// checks each one is inside the stage. Bun-only roots are resolved only.
const NATIVE_PROBE = `
import { existsSync, readFileSync, realpathSync } from "node:fs";
import { createRequire } from "node:module";
import path from "node:path";
import { pathToFileURL } from "node:url";
const config = JSON.parse(process.argv[1]);
const resolved = {};
// Node's directory walk for a package, without going through its exports
// map (which may not expose package.json). Records the real package.json.
function locate(fromDir, name) {
  for (let dir = fromDir; ; dir = path.dirname(dir)) {
    const candidate = path.join(dir, "node_modules", name, "package.json");
    if (existsSync(candidate)) {
      resolved[name] = realpathSync(candidate);
      return path.dirname(resolved[name]);
    }
    if (path.dirname(dir) === dir) throw new Error("cannot locate " + name + " from " + fromDir);
  }
}
// The ESM entry of a package as the server imports it: the "import" (or
// default) condition of its root export, else its main field.
function esmEntry(dir) {
  const manifest = JSON.parse(readFileSync(path.join(dir, "package.json"), "utf8"));
  let entry = manifest.exports?.["."] ?? manifest.exports ?? manifest.main;
  if (entry && typeof entry === "object") entry = entry.import ?? entry.default;
  if (typeof entry !== "string") throw new Error("no ESM entry in " + dir);
  return pathToFileURL(path.join(dir, entry));
}
try {
  const t3Dir = path.dirname(config.packageJson);
  const roots = Object.fromEntries(config.roots.map((name) => [name, locate(t3Dir, name)]));
  const t3Require = createRequire(config.packageJson);
  t3Require("node-pty");
  t3Require("msgpackr-extract");
  locate(roots["node-pty"], "node-addon-api");
  for (const name of ["node-gyp-build-optional-packages", "detect-libc", config.msgpackrPackage]) {
    locate(roots["msgpackr-extract"], name);
  }
  const fff = await import(esmEntry(roots["@ff-labs/fff-node"]));
  const library = fff.findBinary();
  if (typeof library !== "string" || path.basename(library) !== config.fffLibrary) {
    throw new Error("fff-node did not resolve " + config.fffLibrary + " for this target");
  }
  resolved[config.fffLibrary] = realpathSync(library);
  locate(roots["@ff-labs/fff-node"], config.fffPackage);
  locate(locate(roots["@ff-labs/fff-node"], "ffi-rs"), config.ffiPackage);
  const ffi = createRequire(path.join(roots["@ff-labs/fff-node"], "package.json"))("ffi-rs");
  ffi.open({ library: "harbor-managed-server-probe", path: library });
  ffi.close("harbor-managed-server-probe");
  process.stdout.write(JSON.stringify({ resolved }));
} catch (error) {
  process.stderr.write("probe: " + String(error?.message ?? error).split("\\n")[0] + "\\n");
  process.exit(1);
}
`;

async function probeNativeRuntime({ run, node, stageT3, roots, target, env, cwd }) {
  const config = {
    packageJson: path.join(stageT3, "package.json"),
    roots,
    fffPackage: target.fffPackage,
    fffLibrary: target.fffLibrary,
    ffiPackage: target.ffiPackage,
    msgpackrPackage: target.msgpackrPackage,
  };
  const { stdout } = await run({
    command: node,
    args: ["--input-type=module", "-e", NATIVE_PROBE, JSON.stringify(config)],
    cwd,
    env,
  }).catch((error) => fail(`native runtime probe failed in the deployed package: ${tail(error)}`));
  let report;
  try {
    report = JSON.parse(stdout);
  } catch {
    fail("native runtime probe printed no report");
  }
  const realStage = await realpath(stageT3);
  for (const [name, file] of Object.entries(report.resolved ?? {})) {
    if (typeof file !== "string" || !isWithin(realStage, await realpath(file).catch(() => file))) {
      fail(`native runtime probe resolved ${name} outside the deployed package`);
    }
  }
  const missing = [...roots, ...BUN_ONLY_ROOTS, "ffi-rs", target.ffiPackage, target.fffPackage, target.msgpackrPackage].filter(
    (name) => typeof report.resolved?.[name] !== "string",
  );
  if (missing.length > 0) fail(`native runtime probe did not resolve ${missing.join(", ")}`);
  return report.resolved;
}

// --- archive ------------------------------------------------------------------------------

function tarArguments(archive, stageRoot) {
  const macOnly = process.platform === "darwin" ? ["--no-mac-metadata"] : [];
  return ["-c", "-z", "-f", archive, "--no-xattrs", ...macOnly, "-C", stageRoot, "node_modules"];
}

// Every member must live under `node_modules/`, contain no `.` or `..`
// segments, no AppleDouble sidecars, and none of the forbidden names.
export function checkArchiveMembers(listing) {
  const members = listing.split("\n").map((line) => line.replace(/\/$/, "")).filter(Boolean);
  if (members.length === 0) fail("archive is empty");
  for (const member of members) {
    const segments = member.split("/");
    if (segments[0] !== "node_modules") fail(`archive member ${member} is outside node_modules/`);
    for (const segment of segments) {
      if (segment === "" || segment === "." || segment === "..") fail(`archive member ${member} is not a plain relative path`);
      if (segment.startsWith("._")) fail(`archive member ${member} is an AppleDouble sidecar`);
      if (FORBIDDEN_ARCHIVE_NAMES.has(segment)) fail(`archive member ${member} must not be shipped`);
    }
    if (member.endsWith(".sqlite")) fail(`archive member ${member} is database state`);
  }
  for (const relative of STAGED_INSTALL_METADATA) {
    if (members.includes(`node_modules/${SERVER_PACKAGE_NAME}/${relative}`)) fail(`archive still contains ${relative}`);
  }
  if (!members.includes(`node_modules/${SERVER_PACKAGE_NAME}/dist/bin.mjs`)) fail(`archive lacks ${SERVER_ENTRY}`);
  return members;
}

// --- publication ----------------------------------------------------------------------------

// The narrow owned-output publication the release contract uses: the
// destination must be new; runs of this tool against one destination are
// serialized by an adjacent `<destination>.lock` directory (mkdir without
// `recursive` fails with EEXIST while another run holds it), so among
// cooperating publishers exactly one publishes and the others refuse before
// staging anything; `produce` fills a staging directory beside the
// destination, which is renamed into place only when complete. An existing
// destination is refused before the lock and again after it, and is never
// modified. Not guaranteed: POSIX rename replaces an *empty* directory, so an
// unrelated process creating an empty directory at the destination in the
// instant between the final check and the rename would be replaced; a
// non-empty directory always survives. A run killed mid-way leaves the lock
// behind; remove it by hand once no run is in progress. Failure removes only
// the staging directory this run created.
export async function publishNewDirectory(destination, produce) {
  if (await exists(destination)) fail(`destination ${destination} already exists; an artifact directory is never rewritten`);
  const parent = path.dirname(destination);
  await mkdir(parent, { recursive: true });
  const lockDir = `${destination}.lock`;
  await mkdir(lockDir).catch((error) => {
    if (error.code === "EEXIST") fail(`another publisher holds ${lockDir}; wait for it, or remove the lock if it is stale`);
    throw error;
  });
  try {
    if (await exists(destination)) fail(`destination ${destination} already exists; an artifact directory is never rewritten`);
    const staging = await mkdtemp(path.join(parent, `.${path.basename(destination)}.staging-`));
    try {
      const result = await produce(staging);
      if (await exists(destination)) fail(`destination ${destination} appeared during staging`);
      await rename(staging, destination);
      return result;
    } catch (error) {
      await rm(staging, { recursive: true, force: true });
      throw error;
    }
  } finally {
    await rmdir(lockDir).catch(() => {});
  }
}

// --- the build ---------------------------------------------------------------------------------

export async function assertDisjoint(pairs) {
  for (const [labelA, a, labelB, b] of pairs) {
    const ca = await canonicalPath(a);
    const cb = await canonicalPath(b);
    if (isWithin(ca, cb) || isWithin(cb, ca)) fail(`${labelA} ${a} and ${labelB} ${b} must be disjoint paths`);
  }
}

function loadYamlParser(source) {
  try {
    return createRequire(path.join(source, SERVER_IMPORTER, "package.json"))("yaml").parse;
  } catch (error) {
    fail(`cannot load the source tree's yaml package after install: ${error.message}`);
  }
}

// Builds, verifies, and publishes one managed server runtime. Options:
//   source, descriptor, publicConfig, platform, arch, destination — the CLI inputs;
//   run — process runner (createRunner); host — describeHost(); env — base
//   environment for child processes; pnpm — pnpm executable; node — Node
//   executable for verification children; tmpRoot — where the private work
//   directory is created; parseYaml — lock parser (defaults to the source
//   tree's installed yaml package); log — progress sink.
// Returns { destination, file, inventory, sha256, bytes, dependencySymlinks }.
export async function buildManagedServerRuntime({
  source,
  descriptor,
  publicConfig,
  platform,
  arch,
  destination,
  run = createRunner(),
  host = describeHost(),
  env = process.env,
  pnpm = "pnpm",
  node = process.execPath,
  tmpRoot = tmpdir(),
  parseYaml = null,
  log = () => {},
}) {
  // 1. Inputs that must agree before anything is touched.
  validateDescriptor(descriptor);
  const target = resolveTarget(platform, arch, host);
  const version = descriptor.releaseVersion;
  const fingerprint = computePublicConfigFingerprint(publicConfig);
  if (fingerprint !== descriptor.publicConfig.sha256) {
    fail("public config fingerprint does not match the descriptor; the release was resolved from different public values");
  }
  const sourceDir = await realpath(source).catch((error) => fail(`source ${source}: ${error.message}`));
  if (!(await lstat(sourceDir)).isDirectory()) fail(`source ${source} is not a directory`);
  const rootManifest = await readJson(path.join(sourceDir, "package.json"), "source package.json");
  if (rootManifest.packageManager !== PINNED_PACKAGE_MANAGER) {
    fail(`source declares packageManager ${rootManifest.packageManager}; this builder is pinned to ${PINNED_PACKAGE_MANAGER}`);
  }
  const serverManifestFile = path.join(sourceDir, SERVER_IMPORTER, "package.json");
  const serverManifest = await readJson(serverManifestFile, "server manifest");
  checkServerManifest(serverManifest, `${SERVER_IMPORTER}/package.json`);
  await checkLinkerSettings(sourceDir);
  await refuseExistingEnvFiles(sourceDir);
  if (await exists(destination)) fail(`destination ${destination} already exists; an artifact directory is never rewritten`);
  const childEnv = buildChildEnvironment(env, publicConfig, MANAGED_NIGHTLY_VARIANT);
  const pnpmVersion = (
    await run({ command: pnpm, args: ["--version"], cwd: sourceDir, env: childEnv }).catch((error) =>
      fail(`cannot run ${pnpm}: ${tail(error)}`),
    )
  ).stdout.trim();
  if (pnpmVersion !== PINNED_PNPM_VERSION) {
    fail(`${pnpm} is version ${pnpmVersion}; the source pins ${PINNED_PACKAGE_MANAGER} and no other version is run`);
  }

  const work = await mkdtemp(path.join(tmpRoot, "t3-managed-server-"));
  const envFile = path.join(sourceDir, ".env");
  let envFileOwned = false;
  try {
    await assertDisjoint([
      ["source", sourceDir, "destination", destination],
      ["source", sourceDir, "work directory", work],
      ["destination", destination, "work directory", work],
    ]);
    const indexDir = path.join(work, "index");
    await mkdir(indexDir);
    log(`verifying prepared source ${sourceDir} against ${descriptor.upstreamCommit}`);
    const { lockDir, trackedDependencyEntries } = await verifyPreparedSource({
      source: sourceDir,
      descriptor,
      run,
      env: childEnv,
      indexDir,
      expectedVariant: MANAGED_NIGHTLY_VARIANT,
    });
    await refusePriorBuildState(sourceDir, trackedDependencyEntries);
    await assertDisjoint([
      ["lock directory", lockDir, "destination", destination],
      ["lock directory", lockDir, "work directory", work],
      ["lock directory", lockDir, "source", sourceDir],
    ]);

    // 2. Mutations of the disposable tree.
    log("writing task-owned .env and stamping release package versions");
    await writeFile(envFile, encodeDotenv(publicConfig), { flag: "wx", mode: 0o600 });
    envFileOwned = true;
    await stampReleasePackageVersions(sourceDir, version);
    const sourceHashes = {};
    for (const relative of SOURCE_HASH_FILES) sourceHashes[relative] = await hashPath(path.join(sourceDir, relative));
    const requireSourceUnchanged = async (step) => {
      for (const relative of SOURCE_HASH_FILES) {
        if ((await hashPath(path.join(sourceDir, relative))) !== sourceHashes[relative]) {
          fail(`${step} modified ${relative}; the pinned lock and manifests must stay unchanged`);
        }
      }
    };
    const exec = async (label, spec) =>
      run({ cwd: sourceDir, env: childEnv, ...spec }).catch((error) => fail(`${label} failed: ${tail(error)}`));

    log("pnpm install --frozen-lockfile");
    await exec("frozen install", { command: pnpm, args: ["install", "--frozen-lockfile"] });
    await requireSourceUnchanged("pnpm install");

    log("building web client and server bundles");
    for (const relative of ["apps/web/dist", `${SERVER_IMPORTER}/dist`]) {
      await rm(path.join(sourceDir, relative), { recursive: true, force: true });
    }
    await exec("server build task", { command: pnpm, args: ["exec", "vp", "run", "--filter", SERVER_PACKAGE_NAME, "build"] });
    const serverDist = path.join(sourceDir, SERVER_IMPORTER, "dist");
    for (const relative of ["bin.mjs", "service-launcher.mjs", "client/index.html"]) {
      await requireRegularFile(path.join(serverDist, relative), "server build output");
    }

    log(`building resource monitor for ${target.rustTarget}`);
    await exec("resource monitor build", {
      command: "cargo",
      args: ["build", "--locked", "--release", "--manifest-path", MONITOR_MANIFEST, "--target", target.rustTarget],
    });
    const builtMonitor = path.join(sourceDir, "native/resource-monitor/target", target.rustTarget, "release", MONITOR_BINARY);
    await checkMonitor(builtMonitor, target);
    const packagedMonitor = path.join(serverDist, "resource-monitor", target.key, MONITOR_BINARY);
    await mkdir(path.dirname(packagedMonitor), { recursive: true });
    await copyFile(builtMonitor, packagedMonitor);
    await chmod(packagedMonitor, 0o755);
    await checkMonitor(packagedMonitor, target);

    // 3. Modern offline production deploy into a private stage. No legacy
    // fallback: if this route fails, the build fails.
    const stageRoot = path.join(work, "stage");
    const stageT3 = path.join(stageRoot, "node_modules", SERVER_PACKAGE_NAME);
    await mkdir(stageRoot);
    log("pnpm deploy --prod --offline into the private stage");
    await exec("modern offline production deploy", {
      command: pnpm,
      args: ["--filter", SERVER_PACKAGE_NAME, "--config.inject-workspace-packages=true", "deploy", "--prod", "--offline", stageT3],
    });
    await requireSourceUnchanged("pnpm deploy");

    // 4. Verification of the stage, before any metadata is removed.
    log("verifying the deployed runtime");
    for (const relative of REQUIRED_STAGE_FILES) await requireRegularFile(path.join(stageT3, relative), "deployed package");
    await checkMonitor(path.join(stageT3, "dist/resource-monitor", target.key, MONITOR_BINARY), target);
    const deployedManifest = await readJson(path.join(stageT3, "package.json"), "deployed manifest");
    if (deployedManifest.name !== SERVER_PACKAGE_NAME || deployedManifest.version !== version) {
      fail(`deployed package is ${deployedManifest.name}@${deployedManifest.version}, expected ${SERVER_PACKAGE_NAME}@${version}`);
    }
    const parse = parseYaml ?? loadYamlParser(sourceDir);
    const sourceLock = parse(await readFile(path.join(sourceDir, "pnpm-lock.yaml"), "utf8"));
    const deployedLock = parse(await readFile(path.join(stageT3, "pnpm-lock.yaml"), "utf8"));
    const stampedServerManifest = await readJson(serverManifestFile, "server manifest");
    const roots = compareDeployedLock({ sourceLock, sourceManifest: stampedServerManifest, deployedLock, deployedManifest });
    const modules = parse(await readFile(path.join(stageT3, "node_modules/.modules.yaml"), "utf8"));
    if (modules?.nodeLinker !== "isolated") fail(`deployed stage was linked with nodeLinker ${modules?.nodeLinker}; isolated is required`);
    const state = await readJson(path.join(stageT3, "node_modules/.pnpm-workspace-state-v1.json"), "deploy state");
    if (state?.settings?.enableGlobalVirtualStore !== false) fail("deployed stage used a global virtual store; links must be internal");
    for (const relative of ["node_modules/@t3tools", "node_modules/electron"]) {
      if (await exists(path.join(stageT3, relative))) fail(`deployed stage contains ${relative}; workspace and Electron packages are development-only`);
    }
    const virtualStore = await readdir(path.join(stageT3, "node_modules/.pnpm")).catch(() => []);
    const electron = virtualStore.find((name) => name.startsWith("electron@") || name.startsWith("@t3tools+"));
    if (electron !== undefined) fail(`deployed stage contains ${electron}; workspace and Electron packages are development-only`);
    const dependencySymlinks = await verifyStageLinks(stageRoot);
    const home = path.join(work, "home");
    const preflightDir = path.join(work, "preflight");
    await mkdir(home);
    await mkdir(preflightDir);
    const verifyEnv = verificationEnvironment(childEnv, home);
    await probeNativeRuntime({ run, node, stageT3, roots, target, env: verifyEnv, cwd: home });
    const entry = path.join(stageRoot, SERVER_ENTRY);
    const printed = (
      await run({ command: node, args: [entry, "--version"], cwd: home, env: verifyEnv }).catch((error) =>
        fail(`deployed CLI --version failed: ${tail(error)}`),
      )
    ).stdout.trim();
    // The Effect CLI prints its identity as `<command> v<version>` on one line.
    const expectedIdentity = `${SERVER_PACKAGE_NAME} v${version}`;
    if (printed !== expectedIdentity) fail(`deployed CLI reports version ${JSON.stringify(printed)}, expected ${JSON.stringify(expectedIdentity)}`);
    const databasePath = path.join(preflightDir, "never-created.sqlite");
    const preflightOut = (
      await run({
        command: node,
        args: [entry, "__service-preflight", "--database-path", databasePath, "--launcher-protocol", String(SERVER_LAUNCHER_PROTOCOL)],
        cwd: home,
        env: verifyEnv,
      }).catch((error) => fail(`deployed service preflight failed: ${tail(error)}`))
    ).stdout.trim();
    let preflight;
    try {
      preflight = JSON.parse(preflightOut);
    } catch {
      fail("deployed service preflight did not print a JSON result");
    }
    const expectedPreflight = { status: "ready", version, launcherProtocol: SERVER_LAUNCHER_PROTOCOL };
    if (canonicalJson(preflight) !== canonicalJson(expectedPreflight)) {
      fail(`deployed service preflight returned ${JSON.stringify(preflight)}, expected ${JSON.stringify(expectedPreflight)}`);
    }
    const created = await readdir(preflightDir);
    if (created.length > 0) fail(`service preflight created ${created.join(", ")}; it must not touch the database path`);

    // 5. Remove only installation bookkeeping, then archive and publish.
    log("removing staged installation metadata");
    for (const relative of STAGED_INSTALL_METADATA) {
      const file = path.join(stageT3, relative);
      if (!(await exists(file))) continue;
      if ((await lstat(file)).isDirectory()) await rm(file, { recursive: true });
      else await rm(file);
    }
    const { devDependencies, ...shippedManifest } = deployedManifest;
    if (devDependencies !== undefined) await writeFile(path.join(stageT3, "package.json"), `${JSON.stringify(shippedManifest, null, 2)}\n`);

    const file = `${target.artifact.id}-${version}.tar.gz`;
    const inventory = { ...target.artifact, file, version };
    log(`archiving and publishing ${file} into ${destination}`);
    return await publishNewDirectory(destination, async (staging) => {
      const archive = path.join(staging, file);
      const tarEnv = { ...childEnv, COPYFILE_DISABLE: "1" };
      await run({ command: "tar", args: tarArguments(archive, stageRoot), cwd: stageRoot, env: tarEnv }).catch((error) =>
        fail(`tar failed: ${tail(error)}`),
      );
      const { stdout } = await run({ command: "tar", args: ["-t", "-z", "-f", archive], cwd: staging, env: tarEnv }).catch(
        (error) => fail(`tar listing failed: ${tail(error)}`),
      );
      checkArchiveMembers(stdout);
      const { bytes, sha256 } = await hashFile(archive);
      await writeFile(path.join(staging, `${target.artifact.id}-${version}.inventory.json`), canonicalJson(inventory), { flag: "wx" });
      return { destination, file, inventory, sha256, bytes, dependencySymlinks };
    });
  } finally {
    if (envFileOwned) await rm(envFile, { force: true });
    await rm(work, { recursive: true, force: true });
  }
}

// --- CLI ---------------------------------------------------------------------------------------

const FLAGS = ["--source", "--descriptor", "--public-config", "--platform", "--arch", "--destination", "--pnpm"];
const REQUIRED_FLAGS = FLAGS.filter((flag) => flag !== "--pnpm");

export function parseArgs(argv) {
  const options = { source: null, descriptor: null, publicConfig: null, platform: null, arch: null, destination: null, pnpm: "pnpm" };
  const seen = new Set();
  for (let i = 0; i < argv.length; i += 1) {
    const flag = argv[i];
    const value = argv[i + 1];
    if (!FLAGS.includes(flag)) fail(`unknown argument ${flag}; expected one of ${FLAGS.join(", ")}`);
    if (value === undefined || value.startsWith("-")) fail(`${flag} requires a value`);
    if (seen.has(flag)) fail(`${flag} given more than once`);
    seen.add(flag);
    const key = flag.slice(2).replace(/-([a-z])/g, (_, c) => c.toUpperCase());
    options[key] = ["--platform", "--arch", "--pnpm"].includes(flag) ? value : path.resolve(value);
    i += 1;
  }
  for (const flag of REQUIRED_FLAGS) {
    if (!seen.has(flag)) fail(`${flag} is required`);
  }
  return options;
}

export async function main(argv) {
  const options = parseArgs(argv);
  const descriptor = await readJson(options.descriptor, "descriptor");
  const publicConfig = await readJson(options.publicConfig, "public config");
  const result = await buildManagedServerRuntime({
    source: options.source,
    descriptor,
    publicConfig,
    platform: options.platform,
    arch: options.arch,
    destination: options.destination,
    pnpm: options.pnpm,
    run: createRunner({ stream: true }),
    log: (message) => console.log(`build-managed-server-runtime: ${message}`),
  });
  console.log(
    `build-managed-server-runtime: built ${result.inventory.id} ${result.inventory.version} into ${result.destination} ` +
      `(${result.file}, ${result.bytes} bytes, sha256 ${result.sha256}, ${result.dependencySymlinks} internal links)`,
  );
}

if (isEntryPoint(import.meta)) {
  main(process.argv.slice(2)).catch((error) => {
    const message = error instanceof ReleaseError ? error.message : error.stack || String(error);
    console.error(`build-managed-server-runtime: ${message}`);
    process.exit(1);
  });
}
