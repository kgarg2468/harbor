#!/usr/bin/env node
// Build the macOS arm64 desktop ZIP of one managed T3 release variant
// (`managed-nightly` or `reasoning`) from an explicitly supplied, disposable,
// prepared source tree of exactly that variant.
//
// Rebuild-only, unsigned, local: this is the personal managed-build mode. The
// descriptor (resolve-managed-release.mjs) must reproduce its own digest, the
// explicit four-key public config must fingerprint to the descriptor's value,
// the host must be darwin-arm64 on Node 24.13.1 with pnpm 11.10.0, and the
// tree's provenance, lock, and materialized content must equal the pinned
// upstream commit plus that variant's ordered patches (the server builder's
// own proof, asked for the selected variant). Only then is the tree mutated:
// the four release package versions are stamped, a task-owned `.env` carrying
// exactly the four public values is written, the pinned pnpm installs from
// the frozen lock, and the source tree's own scripts/build-desktop-artifact.ts
// (run by the explicit Node executable through `pnpm exec`, so the tree's
// own node_modules/.bin tools such as `vp` resolve as in a package script)
// produces one ZIP into an owned output directory. The variant is chosen once
// from the CLI; the child environment, the provenance check, the expected
// artifact identity, and the inventory all derive from that one value.
//
// The emitted archive is then examined, never trusted by name: it is
// extracted with ditto, must hold exactly one `.app` named for the expected
// product with confined links, its actual Info.plist (read through plutil)
// must carry the fixed bundle identifier, names, executable, URL schemes, and
// release version, `app.asar` must be present and `app-update.yml` absent,
// the main executable must be a thin Mach-O arm64 executable, and the
// embedded server must print the exact release identity when the packaged
// Electron runtime runs it as Node from inside the ASAR. The verified ZIP is
// then copied under its canonical name with one inventory record into a new
// directory, atomically. No signing, notarization, installation, launch,
// download, or remote publication happens here: the existing personal
// installer ad hoc signs the staged app later.
//
// Every external process goes through one injectable shell-free runner so
// unit tests drive the whole sequence against tiny fixtures. Node built-ins
// only, plus the release contract's own helpers.
import { constants as fsConstants } from "node:fs";
import { copyFile, lstat, mkdir, mkdtemp, open, readdir, readFile, realpath, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { ReleaseError, canonicalJson, computePublicConfigFingerprint, isEntryPoint, sha256Hex } from "./resolve-managed-release.mjs";
import { EXPECTED_ARTIFACTS, hashFile, validateDescriptor } from "./write-managed-release-manifest.mjs";
import {
  PINNED_NODE_VERSION,
  PINNED_PACKAGE_MANAGER,
  PINNED_PNPM_VERSION,
  RELEASE_PACKAGE_FILES,
  SERVER_PACKAGE_NAME,
  assertDisjoint,
  buildChildEnvironment,
  createRunner,
  describeHost,
  encodeDotenv,
  publishNewDirectory,
  refuseExistingEnvFiles,
  refusePriorBuildState,
  stampReleasePackageVersions,
  verifyPreparedSource,
  verifyStageLinks,
} from "./build-managed-server-runtime.mjs";

export const DESKTOP_PLATFORM = "darwin";
export const DESKTOP_ARCH = "arm64";
// The source tree's own builder, run through the explicit Node executable
// under `pnpm exec`. The builder spawns the tree's `vp` by bare name, which
// only the project bin directory that pnpm exec prepends to PATH provides;
// no globally installed tool and no ambient PATH change stands in for it.
export const DESKTOP_BUILDER_SCRIPT = "scripts/build-desktop-artifact.ts";
// Platform tools, by absolute path, never through a shell.
export const DITTO = "/usr/bin/ditto";
export const PLUTIL = "/usr/bin/plutil";
export const INFO_PLIST = "Contents/Info.plist";
export const APP_ASAR = "Contents/Resources/app.asar";
export const APP_UPDATE_FEED = "Contents/Resources/app-update.yml";
// The server CLI inside the packaged ASAR, as the desktop app spawns it.
export const EMBEDDED_SERVER_ENTRY = "apps/server/dist/bin.mjs";
// Mach-O 64-bit little-endian magic, CPU_TYPE_ARM64, MH_EXECUTE.
const MACHO_MAGIC_64 = 0xfeedfacf;
const MACHO_CPU_ARM64 = 0x0100000c;
const MACHO_EXECUTE = 0x2;
// electron-updater feed files a build could drop beside the ZIP.
const UPDATE_FEED_FILE_RE = /^(latest[^/]*|[^/]*-mac|app-update)\.ya?ml$/i;
// Hashed after stamping and required unchanged after install and build.
const SOURCE_HASH_FILES = ["pnpm-lock.yaml", ...RELEASE_PACKAGE_FILES];

function fail(message) {
  throw new ReleaseError(message);
}

function isPlainObject(value) {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function sameJson(a, b) {
  return JSON.stringify(a) === JSON.stringify(b);
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

async function requireRegularFile(file, label) {
  const stats = await lstat(file).catch(() => fail(`${label}: missing ${file}`));
  if (stats.isSymbolicLink()) fail(`${label}: ${file} is a symbolic link`);
  if (!stats.isFile()) fail(`${label}: ${file} is not a regular file`);
  if (stats.size === 0) fail(`${label}: ${file} is empty`);
  return stats;
}

// --- fixed identity ------------------------------------------------------------------

// Exactly one desktop artifact of the release set carries the CLI variant.
// Its bundle identifier, product name, schemes, id, platform, and
// architecture are never taken from the caller.
export function selectDesktopArtifact(variant) {
  const candidates = EXPECTED_ARTIFACTS.filter((a) => a.kind === "desktop" && a.variant === variant);
  if (candidates.length !== 1) {
    const known = EXPECTED_ARTIFACTS.filter((a) => a.kind === "desktop").map((a) => a.variant);
    fail(`variant ${JSON.stringify(variant)} names no desktop artifact; expected one of ${known.join(", ")}`);
  }
  const artifact = candidates[0];
  if (artifact.platform !== DESKTOP_PLATFORM || artifact.arch !== DESKTOP_ARCH || artifact.format !== "zip") {
    fail(`desktop artifact ${artifact.id} is not a ${DESKTOP_PLATFORM}-${DESKTOP_ARCH} zip`);
  }
  return artifact;
}

// The host must be the target on the pinned Node; nothing is inferred from
// a runner label or from `uname`.
export function requireDesktopHost(host) {
  if (host.platform !== DESKTOP_PLATFORM || host.arch !== DESKTOP_ARCH) {
    fail(`managed desktop builds run only on a ${DESKTOP_PLATFORM}-${DESKTOP_ARCH} host; this host is ${host.platform}-${host.arch}`);
  }
  if (host.nodeVersion !== PINNED_NODE_VERSION) {
    fail(`managed desktop builds require Node ${PINNED_NODE_VERSION}; this host runs ${host.nodeVersion}`);
  }
}

// The exact argument list handed to the source tree's builder: a full
// unsigned build (its default), one macOS arm64 ZIP, the release version,
// and an owned output directory. Never --skip-build, --signed,
// --mock-updates, or a feed repository.
export function desktopBuildArguments(version, outputDir) {
  return [DESKTOP_BUILDER_SCRIPT, "--platform", "mac", "--target", "zip", "--arch", DESKTOP_ARCH, "--build-version", version, "--output-dir", outputDir];
}

// The pnpm argument list that runs those builder arguments under the
// explicit Node executable with the project bin directory on PATH.
export function desktopBuildExecArguments(node, version, outputDir) {
  return ["exec", node, ...desktopBuildArguments(version, outputDir)];
}

// --- archive inspection -----------------------------------------------------------------

// Exactly one regular ZIP in the owned output, and no update feed beside it.
export async function locateBuiltZip(outputDir) {
  const entries = await readdir(outputDir, { withFileTypes: true }).catch((error) => fail(`cannot read build output ${outputDir}: ${error.message}`));
  const feed = entries.filter((e) => UPDATE_FEED_FILE_RE.test(e.name)).map((e) => e.name);
  if (feed.length > 0) fail(`desktop build emitted update feed metadata ${feed.join(", ")}; a managed build must not produce an update feed`);
  const zips = entries.filter((e) => e.name.toLowerCase().endsWith(".zip")).map((e) => e.name);
  if (zips.length !== 1) fail(`desktop build emitted ${zips.length} ZIP archive(s) (${zips.join(", ") || "none"}); expected exactly one`);
  const file = path.join(outputDir, zips[0]);
  await requireRegularFile(file, "desktop build output");
  return file;
}

// Exactly one top-level entry, a directory named for the expected product.
export async function locateExtractedApp(extractDir, artifact) {
  const entries = await readdir(extractDir, { withFileTypes: true });
  const apps = entries.filter((e) => e.name.endsWith(".app"));
  if (apps.length !== 1) {
    fail(`extracted archive holds ${apps.length} top-level .app bundle(s) (${apps.map((e) => e.name).join(", ") || "none"}); expected exactly one`);
  }
  const others = entries.filter((e) => !e.name.endsWith(".app")).map((e) => e.name);
  if (others.length > 0) fail(`extracted archive holds unexpected top-level entries beside the bundle: ${others.join(", ")}`);
  const expectedName = `${artifact.productName}.app`;
  if (apps[0].name !== expectedName) fail(`extracted bundle is ${apps[0].name}, expected ${expectedName}`);
  if (!apps[0].isDirectory()) fail(`extracted bundle ${expectedName} is not a directory`);
  return path.join(extractDir, expectedName);
}

// The decoded Info.plist must state the fixed identity and the release
// version, and its flattened URL schemes must be exactly the expected set:
// no duplicate, no missing, and no extra stock scheme.
export function checkBundlePlist(plist, artifact, version) {
  if (!isPlainObject(plist)) fail("Info.plist did not decode to a dictionary");
  const expect = (key, value) => {
    if (plist[key] !== value) fail(`Info.plist ${key} is ${JSON.stringify(plist[key])}, expected ${JSON.stringify(value)}`);
  };
  expect("CFBundleIdentifier", artifact.bundleId);
  expect("CFBundleDisplayName", artifact.productName);
  expect("CFBundleName", artifact.productName);
  expect("CFBundleExecutable", artifact.productName);
  expect("CFBundleShortVersionString", version);
  expect("CFBundleVersion", version);
  const types = plist.CFBundleURLTypes;
  if (!Array.isArray(types)) fail("Info.plist CFBundleURLTypes is missing or not a list");
  const schemes = [];
  types.forEach((type, index) => {
    if (!isPlainObject(type) || !Array.isArray(type.CFBundleURLSchemes)) fail(`Info.plist CFBundleURLTypes[${index}] has no CFBundleURLSchemes list`);
    for (const scheme of type.CFBundleURLSchemes) {
      if (typeof scheme !== "string") fail(`Info.plist CFBundleURLTypes[${index}] carries a non-string scheme`);
      schemes.push(scheme);
    }
  });
  if (!sameJson([...schemes].sort(), [...artifact.urlSchemes].sort())) {
    fail(`Info.plist URL schemes are ${schemes.join(", ") || "(none)"}; expected exactly ${artifact.urlSchemes.join(", ")}`);
  }
  return schemes;
}

// Thin 64-bit little-endian Mach-O, arm64, executable file type. Fat
// binaries, other architectures, libraries, and scripts are refused.
export function checkMachOArm64Executable(bytes, label) {
  if (
    bytes.length < 16 ||
    bytes.readUInt32LE(0) !== MACHO_MAGIC_64 ||
    bytes.readUInt32LE(4) !== MACHO_CPU_ARM64 ||
    bytes.readUInt32LE(12) !== MACHO_EXECUTE
  ) {
    fail(`${label} is not a thin Mach-O 64-bit arm64 executable`);
  }
}

async function readHeader(file, length = 32) {
  const handle = await open(file, "r");
  try {
    const { buffer, bytesRead } = await handle.read(Buffer.alloc(length), 0, length, 0);
    return buffer.subarray(0, bytesRead);
  } finally {
    await handle.close();
  }
}

// --- the build ---------------------------------------------------------------------------

// Builds, verifies, and publishes one managed desktop ZIP. Options:
//   source, descriptor, publicConfig, variant, destination — the CLI inputs;
//   run — process runner (createRunner); host — describeHost(); env — base
//   environment for child processes; pnpm — pnpm executable; node — Node
//   executable that runs the source builder under `pnpm exec`; tmpRoot — where the private
//   work directory is created; log — progress sink.
// Returns { destination, file, inventory, sha256, bytes }.
export async function buildManagedDesktopRuntime({
  source,
  descriptor,
  publicConfig,
  variant,
  destination,
  run = createRunner(),
  host = describeHost(),
  env = process.env,
  pnpm = "pnpm",
  node = process.execPath,
  tmpRoot = tmpdir(),
  log = () => {},
}) {
  // 1. Inputs that must agree before anything is touched. The variant is
  // selected exactly once here.
  validateDescriptor(descriptor);
  const artifact = selectDesktopArtifact(variant);
  requireDesktopHost(host);
  const version = descriptor.releaseVersion;
  if (computePublicConfigFingerprint(publicConfig) !== descriptor.publicConfig.sha256) {
    fail("public config fingerprint does not match the descriptor; the release was resolved from different public values");
  }
  const sourceDir = await realpath(source).catch((error) => fail(`source ${source}: ${error.message}`));
  if (!(await lstat(sourceDir)).isDirectory()) fail(`source ${source} is not a directory`);
  const rootManifest = await readJson(path.join(sourceDir, "package.json"), "source package.json");
  if (rootManifest.packageManager !== PINNED_PACKAGE_MANAGER) {
    fail(`source declares packageManager ${rootManifest.packageManager}; this builder is pinned to ${PINNED_PACKAGE_MANAGER}`);
  }
  await requireRegularFile(path.join(sourceDir, DESKTOP_BUILDER_SCRIPT), "source desktop builder");
  await refuseExistingEnvFiles(sourceDir);
  await refusePriorBuildState(sourceDir);
  if (await exists(destination)) fail(`destination ${destination} already exists; an artifact directory is never rewritten`);
  const childEnv = buildChildEnvironment(env, publicConfig, artifact.variant);
  const pnpmVersion = (
    await run({ command: pnpm, args: ["--version"], cwd: sourceDir, env: childEnv }).catch((error) => fail(`cannot run ${pnpm}: ${tail(error)}`))
  ).stdout.trim();
  if (pnpmVersion !== PINNED_PNPM_VERSION) {
    fail(`${pnpm} is version ${pnpmVersion}; the source pins ${PINNED_PACKAGE_MANAGER} and no other version is run`);
  }

  const work = await mkdtemp(path.join(tmpRoot, "t3-managed-desktop-"));
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
    log(`verifying prepared ${artifact.variant} source ${sourceDir} against ${descriptor.upstreamCommit}`);
    const { lockDir } = await verifyPreparedSource({
      source: sourceDir,
      descriptor,
      run,
      env: childEnv,
      indexDir,
      expectedVariant: artifact.variant,
    });
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
          fail(`${step} modified ${relative}; the pinned lock and stamped manifests must stay unchanged`);
        }
      }
    };
    const exec = async (label, spec) => run({ cwd: sourceDir, env: childEnv, ...spec }).catch((error) => fail(`${label} failed: ${tail(error)}`));

    log("pnpm install --frozen-lockfile");
    await exec("frozen install", { command: pnpm, args: ["install", "--frozen-lockfile"] });
    await requireSourceUnchanged("pnpm install");

    const buildOut = path.join(work, "build-output");
    await mkdir(buildOut);
    log(`building the unsigned ${DESKTOP_PLATFORM}-${DESKTOP_ARCH} desktop ZIP with ${DESKTOP_BUILDER_SCRIPT}`);
    await exec("desktop artifact build", { command: pnpm, args: desktopBuildExecArguments(node, version, buildOut) });
    await requireSourceUnchanged("desktop artifact build");

    // 3. Examine the actual archive.
    const builtZip = await locateBuiltZip(buildOut);
    const home = path.join(work, "home");
    const extractDir = path.join(work, "extracted");
    await mkdir(home);
    await mkdir(extractDir);
    const toolEnv = { PATH: childEnv.PATH ?? "", HOME: home, TMPDIR: home };
    log("extracting and verifying the built bundle");
    await run({ command: DITTO, args: ["-x", "-k", builtZip, extractDir], cwd: home, env: toolEnv }).catch((error) =>
      fail(`ditto extraction failed: ${tail(error)}`),
    );
    const app = await locateExtractedApp(extractDir, artifact);
    await verifyStageLinks(extractDir);
    const plistFile = path.join(app, INFO_PLIST);
    await requireRegularFile(plistFile, "bundle Info.plist");
    const plistText = (
      await run({ command: PLUTIL, args: ["-convert", "json", "-o", "-", "--", plistFile], cwd: home, env: toolEnv }).catch((error) =>
        fail(`plutil could not read Info.plist: ${tail(error)}`),
      )
    ).stdout;
    let plist;
    try {
      plist = JSON.parse(plistText);
    } catch {
      fail("plutil did not print Info.plist as JSON");
    }
    checkBundlePlist(plist, artifact, version);
    if (await exists(path.join(app, APP_UPDATE_FEED))) fail(`bundle contains ${APP_UPDATE_FEED}; a managed build must not carry an update feed`);
    await requireRegularFile(path.join(app, APP_ASAR), "bundle application archive");
    const executable = path.join(app, "Contents/MacOS", plist.CFBundleExecutable);
    const executableStats = await requireRegularFile(executable, "bundle main executable");
    if ((executableStats.mode & 0o111) === 0) fail(`bundle main executable ${executable} is not executable`);
    checkMachOArm64Executable(await readHeader(executable), "bundle main executable");

    // 4. The embedded server, run from inside the ASAR by the packaged
    // Electron runtime as Node, must report the exact release identity.
    const entry = path.join(app, APP_ASAR, EMBEDDED_SERVER_ENTRY);
    const printed = (
      await run({ command: executable, args: [entry, "--version"], cwd: home, env: { ...toolEnv, ELECTRON_RUN_AS_NODE: "1" } }).catch((error) =>
        fail(`embedded server --version failed: ${tail(error)}`),
      )
    ).stdout.trim();
    const expectedIdentity = `${SERVER_PACKAGE_NAME} v${version}`;
    if (printed !== expectedIdentity) fail(`embedded server reports version ${JSON.stringify(printed)}, expected ${JSON.stringify(expectedIdentity)}`);

    // 5. Publish the verified ZIP under its canonical name with its inventory record.
    const file = `${artifact.id}-${version}.zip`;
    const inventory = { ...artifact, urlSchemes: [...artifact.urlSchemes], file, version, embeddedServerVersion: version };
    log(`publishing ${file} into ${destination}`);
    return await publishNewDirectory(destination, async (staging) => {
      const published = path.join(staging, file);
      await copyFile(builtZip, published, fsConstants.COPYFILE_EXCL);
      const { bytes, sha256 } = await hashFile(published);
      await writeFile(path.join(staging, `${artifact.id}-${version}.inventory.json`), canonicalJson(inventory), { flag: "wx" });
      return { destination, file, inventory, sha256, bytes };
    });
  } finally {
    if (envFileOwned) await rm(envFile, { force: true });
    await rm(work, { recursive: true, force: true });
  }
}

// --- CLI ---------------------------------------------------------------------------------------

const FLAGS = ["--source", "--descriptor", "--public-config", "--variant", "--destination", "--pnpm"];
const REQUIRED_FLAGS = FLAGS.filter((flag) => flag !== "--pnpm");

export function parseArgs(argv) {
  const options = { source: null, descriptor: null, publicConfig: null, variant: null, destination: null, pnpm: "pnpm" };
  const seen = new Set();
  for (let i = 0; i < argv.length; i += 1) {
    const flag = argv[i];
    const value = argv[i + 1];
    if (!FLAGS.includes(flag)) fail(`unknown argument ${flag}; expected one of ${FLAGS.join(", ")}`);
    if (value === undefined || value.startsWith("-")) fail(`${flag} requires a value`);
    if (seen.has(flag)) fail(`${flag} given more than once`);
    seen.add(flag);
    const key = flag.slice(2).replace(/-([a-z])/g, (_, c) => c.toUpperCase());
    options[key] = ["--variant", "--pnpm"].includes(flag) ? value : path.resolve(value);
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
  const result = await buildManagedDesktopRuntime({
    source: options.source,
    descriptor,
    publicConfig,
    variant: options.variant,
    destination: options.destination,
    pnpm: options.pnpm,
    run: createRunner({ stream: true }),
    log: (message) => console.log(`build-managed-desktop-runtime: ${message}`),
  });
  console.log(
    `build-managed-desktop-runtime: built ${result.inventory.id} ${result.inventory.version} into ${result.destination} ` +
      `(${result.file}, ${result.bytes} bytes, sha256 ${result.sha256})`,
  );
}

if (isEntryPoint(import.meta)) {
  main(process.argv.slice(2)).catch((error) => {
    const message = error instanceof ReleaseError ? error.message : error.stack || String(error);
    console.error(`build-managed-desktop-runtime: ${message}`);
    process.exit(1);
  });
}
