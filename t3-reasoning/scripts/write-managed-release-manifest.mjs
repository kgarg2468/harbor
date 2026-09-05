#!/usr/bin/env node
// Write the canonical, immutable manifest of one managed T3 release from a
// resolved descriptor (resolve-managed-release.mjs), an explicit inventory of
// the four required artifacts, and the completed artifact files themselves.
//
// The release is closed over exactly four artifacts: the two macOS arm64
// desktop zips (managed-nightly and reasoning) and the two plain-Node shared
// server runtimes (darwin-arm64 and linux-x64, the architecture resolved for
// the target host). Every inventory record must restate the identity the
// design fixes for that artifact, and every version must equal the
// descriptor's release version. Inventory file names are bare basenames
// resolved only inside the artifact directory; there is no way to reference a
// file elsewhere, and no record may carry a URL. Downloaders derive locations
// from the trusted release base plus the manifest's file names.
//
// Output is `managed-release.json`, `SHA256SUMS` (covering the manifest and
// every artifact), and a copy of each artifact, staged next to the destination
// and renamed into place only when complete. The destination is an owned
// output path: concurrent runs of this tool against it are serialized by an
// adjacent mkdir lock, an existing destination is never touched, and nothing
// is published remotely. See writeManagedReleaseManifest for the exact scope
// of the no-overwrite guarantee.
//
// Hashing covers artifact bytes and lengths only. This tool does not open,
// list, or validate archive contents; the server builder, desktop builder, and
// installer are responsible for asserting what is inside each archive.
// Dependency-free: Node built-ins only.
import { constants as fsConstants, createReadStream } from "node:fs";
import { copyFile, lstat, mkdir, mkdtemp, readFile, realpath, rename, rm, rmdir, writeFile } from "node:fs/promises";
import { createHash } from "node:crypto";
import path from "node:path";
import {
  COMMIT_RE,
  DESCRIPTOR_KIND,
  DESCRIPTOR_SCHEMA_VERSION,
  MANAGED_NIGHTLY_VARIANT,
  PRESENTATION_VARIANTS,
  PUBLIC_CONFIG_KEYS,
  REASONING_VARIANT,
  REQUIRED_VARIANTS,
  ReleaseError,
  SHA256_RE,
  canonicalJson,
  checkVariantClosure,
  computeReleaseInputDigest,
  formatManagedReleaseVersion,
  isEntryPoint,
  parseManagedReleaseVersion,
  parseUpstreamNightlyVersion,
  validateBuilderRevision,
  validateReleaseCounter,
} from "./resolve-managed-release.mjs";

export const MANIFEST_SCHEMA_VERSION = 1;
export const MANIFEST_FILE = "managed-release.json";
export const SUMS_FILE = "SHA256SUMS";
export const COMMON_VARIANT = "common";
export const SERVER_ENTRY = "node_modules/t3/dist/bin.mjs";
export const SERVER_LAUNCHER_PROTOCOL = 2;

// The fixed identity of every artifact a managed release publishes. Inventory
// records must match these exactly; the manifest emits these values, never
// values a record invents.
export const EXPECTED_ARTIFACTS = Object.freeze([
  Object.freeze({
    id: "managed-nightly-darwin-arm64",
    kind: "desktop",
    variant: MANAGED_NIGHTLY_VARIANT,
    platform: "darwin",
    arch: "arm64",
    format: "zip",
    bundleId: "com.t3tools.t3code",
    productName: "T3 Code (Nightly)",
    urlSchemes: Object.freeze(["t3code", "t3code-dev"]),
    presentationVariant: PRESENTATION_VARIANTS[MANAGED_NIGHTLY_VARIANT],
  }),
  Object.freeze({
    id: "reasoning-darwin-arm64",
    kind: "desktop",
    variant: REASONING_VARIANT,
    platform: "darwin",
    arch: "arm64",
    format: "zip",
    bundleId: "com.t3tools.t3code.reasoning",
    productName: "T3 Code (Reasoning)",
    urlSchemes: Object.freeze(["t3code-reasoning"]),
    presentationVariant: PRESENTATION_VARIANTS[REASONING_VARIANT],
  }),
  Object.freeze({
    id: "managed-server-darwin-arm64",
    kind: "server",
    variant: COMMON_VARIANT,
    platform: "darwin",
    arch: "arm64",
    format: "tar.gz",
    entry: SERVER_ENTRY,
    launcherProtocol: SERVER_LAUNCHER_PROTOCOL,
  }),
  Object.freeze({
    id: "managed-server-linux-x64",
    kind: "server",
    variant: COMMON_VARIANT,
    platform: "linux",
    arch: "x64",
    format: "tar.gz",
    entry: SERVER_ENTRY,
    launcherProtocol: SERVER_LAUNCHER_PROTOCOL,
  }),
]);

// Fields every record must carry beyond the fixed identity: the file it
// produced and the version it verified from the built output. Desktop records
// also state the version of the server embedded in the bundle.
const RECORD_FIELDS = {
  desktop: ["file", "version", "embeddedServerVersion"],
  server: ["file", "version"],
};
const RESERVED_FILES = [MANIFEST_FILE, SUMS_FILE];

function fail(message) {
  throw new ReleaseError(message);
}

function isPlainObject(value) {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function sameJson(a, b) {
  return JSON.stringify(a) === JSON.stringify(b);
}

// --- descriptor --------------------------------------------------------------

// A descriptor is trusted only if its version and digest are exactly what the
// resolver would derive from the provenance it carries. The digest is
// recomputed with the resolver's own helper from the upstream commit and
// version, the ordered per-variant patch hashes, the builder revision, the
// public-config fingerprint, and the presentation variants; the variant
// closure rule is the resolver's too. Any edit to those inputs, or to the
// digest or version, is refused here before anything is staged.
export function validateDescriptor(descriptor, label = "descriptor") {
  if (!isPlainObject(descriptor)) fail(`${label}: must be a JSON object`);
  if (descriptor.kind !== DESCRIPTOR_KIND || descriptor.schemaVersion !== DESCRIPTOR_SCHEMA_VERSION) {
    fail(`${label}: expected kind ${DESCRIPTOR_KIND} schemaVersion ${DESCRIPTOR_SCHEMA_VERSION}`);
  }
  const parsed = parseManagedReleaseVersion(descriptor.releaseVersion);
  parseUpstreamNightlyVersion(descriptor.upstreamVersion);
  if (descriptor.upstreamVersion !== parsed.upstreamVersion) {
    fail(`${label}: upstreamVersion does not match releaseVersion ${descriptor.releaseVersion}`);
  }
  validateReleaseCounter(descriptor.releaseCounter);
  if (descriptor.releaseCounter !== parsed.releaseCounter) {
    fail(`${label}: releaseCounter does not match releaseVersion ${descriptor.releaseVersion}`);
  }
  if (typeof descriptor.upstreamCommit !== "string" || !COMMIT_RE.test(descriptor.upstreamCommit)) {
    fail(`${label}: upstreamCommit must be a full 40-character lowercase SHA-1`);
  }
  validateBuilderRevision(descriptor.builderRevision);
  if (typeof descriptor.upstreamRepository !== "string" || descriptor.upstreamRepository === "") {
    fail(`${label}: upstreamRepository must be a non-empty string`);
  }
  if (typeof descriptor.releaseInputSha256 !== "string" || !SHA256_RE.test(descriptor.releaseInputSha256)) {
    fail(`${label}: releaseInputSha256 must be 64 lowercase hex characters`);
  }
  if (!isPlainObject(descriptor.publicConfig) || !SHA256_RE.test(String(descriptor.publicConfig.sha256))) {
    fail(`${label}: publicConfig.sha256 must be 64 lowercase hex characters`);
  }
  if (!sameJson(descriptor.publicConfig.keys, PUBLIC_CONFIG_KEYS)) {
    fail(`${label}: publicConfig.keys must be exactly ${PUBLIC_CONFIG_KEYS.join(", ")}`);
  }
  if (!sameJson(descriptor.presentationVariants, PRESENTATION_VARIANTS)) {
    fail(`${label}: presentationVariants must be ${JSON.stringify(PRESENTATION_VARIANTS)}`);
  }
  if (!isPlainObject(descriptor.variants)) fail(`${label}: variants must be an object`);
  const names = Object.keys(descriptor.variants).sort();
  for (const name of names) {
    const patches = descriptor.variants[name]?.patches;
    if (!Array.isArray(patches) || patches.length === 0) fail(`${label}: variants.${name}.patches must be non-empty`);
    patches.forEach((patch, index) => {
      if (typeof patch?.id !== "string" || patch.id === "" || !SHA256_RE.test(String(patch.sha256))) {
        fail(`${label}: variants.${name}.patches[${index}] must have an id and a sha256`);
      }
    });
  }
  const identityPatches = checkVariantClosure(
    Object.fromEntries(names.map((name) => [name, descriptor.variants[name].patches.map((patch) => patch.id)])),
    label,
  );
  // Same ids in the common prefix is necessary, not sufficient: the hashes
  // must agree too, or the two trees were not built from one common set.
  const common = descriptor.variants[MANAGED_NIGHTLY_VARIANT].patches;
  const reasoning = descriptor.variants[REASONING_VARIANT].patches;
  common.forEach((patch, position) => {
    if (reasoning[position].sha256 !== patch.sha256) {
      fail(
        `${label}: variants.${REASONING_VARIANT}.patches[${position}] (${patch.id}) hash differs from ` +
          `variants.${MANAGED_NIGHTLY_VARIANT}; the common prefix must be identical`,
      );
    }
  });
  if (!sameJson(descriptor.identityPatches, identityPatches)) {
    fail(`${label}: identityPatches must be exactly ${JSON.stringify(identityPatches)}`);
  }
  const digest = computeReleaseInputDigest({
    upstreamRepository: descriptor.upstreamRepository,
    upstreamCommit: descriptor.upstreamCommit,
    upstreamVersion: descriptor.upstreamVersion,
    variants: Object.fromEntries(names.map((name) => [name, descriptor.variants[name].patches])),
    builderRevision: descriptor.builderRevision,
    publicConfigSha256: descriptor.publicConfig.sha256,
    presentationVariants: descriptor.presentationVariants,
  });
  if (descriptor.releaseInputSha256 !== digest) {
    fail(
      `${label}: releaseInputSha256 ${descriptor.releaseInputSha256} does not match the digest ` +
        `recomputed from its provenance ${digest}; the descriptor has been altered`,
    );
  }
  if (descriptor.releaseInputShort !== digest.slice(0, parsed.releaseInputShort.length)) {
    fail(`${label}: releaseInputShort does not match releaseInputSha256`);
  }
  const expectedVersion = formatManagedReleaseVersion(descriptor.upstreamVersion, descriptor.releaseCounter, digest);
  if (descriptor.releaseVersion !== expectedVersion) {
    fail(`${label}: releaseVersion ${descriptor.releaseVersion} does not match the resolved ${expectedVersion}`);
  }
  return descriptor;
}

// --- inventory -------------------------------------------------------------------

// A bare, portable basename: no separators, no `.`/`..`, no control or
// backslash characters (which would need escaping in SHA256SUMS), the
// expected extension, and not one of the two files this tool writes itself.
function validateFileName(file, format, label) {
  if (typeof file !== "string" || file === "") fail(`${label}: file must be a non-empty string`);
  if (path.basename(file) !== file || file.includes("/") || file.includes("\\") || file === "." || file === "..") {
    fail(`${label}: file ${JSON.stringify(file)} must be a bare file name inside the artifact directory`);
  }
  if (/[\p{Cc}]/u.test(file) || file.startsWith("-") || file.trim() !== file) {
    fail(`${label}: file ${JSON.stringify(file)} contains characters not allowed in an artifact name`);
  }
  if (!file.endsWith(`.${format}`) || file === `.${format}`) {
    fail(`${label}: file ${JSON.stringify(file)} must end with .${format}`);
  }
  if (RESERVED_FILES.includes(file)) fail(`${label}: file ${file} collides with a release file this tool writes`);
  return file;
}

// Validates every record against the fixed artifact set and the descriptor.
// Returns the four records in canonical order, each merged with its expected
// identity, so nothing a record supplied beyond the checked fields survives.
export function validateInventory(descriptor, inventory) {
  if (!Array.isArray(inventory)) fail("inventory must be a JSON array of artifact records");
  const byId = new Map();
  inventory.forEach((record, index) => {
    if (!isPlainObject(record)) fail(`inventory[${index}] must be an object`);
    if (typeof record.id !== "string" || record.id === "") fail(`inventory[${index}].id must be a non-empty string`);
    if (byId.has(record.id)) fail(`inventory: duplicate artifact id ${record.id}`);
    byId.set(record.id, record);
  });
  const expectedIds = EXPECTED_ARTIFACTS.map((artifact) => artifact.id);
  const missing = expectedIds.filter((id) => !byId.has(id));
  const unexpected = [...byId.keys()].filter((id) => !expectedIds.includes(id));
  if (missing.length > 0) fail(`inventory is missing required artifact(s) ${missing.join(", ")}`);
  if (unexpected.length > 0) {
    fail(`inventory names artifact(s) outside the release set: ${unexpected.join(", ")}`);
  }

  const seenFiles = new Map(); // lower-cased name -> id, for case-insensitive filesystems
  return EXPECTED_ARTIFACTS.map((expected) => {
    const record = byId.get(expected.id);
    const label = `artifact ${expected.id}`;
    const allowed = [...Object.keys(expected), ...RECORD_FIELDS[expected.kind]];
    const extra = Object.keys(record).filter((key) => !allowed.includes(key));
    if (extra.length > 0) {
      fail(`${label}: unexpected field(s) ${extra.join(", ")}; records cannot add fields such as URLs`);
    }
    for (const key of allowed) {
      if (!Object.hasOwn(record, key)) fail(`${label}: missing field ${key}`);
    }
    for (const [key, value] of Object.entries(expected)) {
      if (!sameJson(record[key], value)) {
        fail(`${label}: ${key} must be ${JSON.stringify(value)}, found ${JSON.stringify(record[key])}`);
      }
    }
    if (record.version !== descriptor.releaseVersion) {
      fail(
        `${label}: version ${JSON.stringify(record.version)} does not equal release version ` +
          `${descriptor.releaseVersion}`,
      );
    }
    if (expected.kind === "desktop" && record.embeddedServerVersion !== descriptor.releaseVersion) {
      fail(
        `${label}: embeddedServerVersion ${JSON.stringify(record.embeddedServerVersion)} does not equal ` +
          `release version ${descriptor.releaseVersion}`,
      );
    }
    const file = validateFileName(record.file, expected.format, label);
    const folded = file.toLowerCase();
    if (seenFiles.has(folded)) fail(`${label}: file ${file} is also used by artifact ${seenFiles.get(folded)}`);
    seenFiles.set(folded, expected.id);
    const merged = { ...expected };
    if (merged.urlSchemes !== undefined) merged.urlSchemes = [...merged.urlSchemes];
    return {
      ...merged,
      file,
      version: record.version,
      ...(expected.kind === "desktop" ? { embeddedServerVersion: record.embeddedServerVersion } : {}),
    };
  });
}

// --- hashing -------------------------------------------------------------------

// SHA-256 and byte length of a file's bytes. Says nothing about what the
// bytes contain.
export async function hashFile(file) {
  const hash = createHash("sha256");
  let bytes = 0;
  for await (const chunk of createReadStream(file)) {
    hash.update(chunk);
    bytes += chunk.length;
  }
  return { bytes, sha256: hash.digest("hex") };
}

// The artifact must be a regular file (a symlink is refused even when its
// target is inside the directory) directly in the artifact directory.
async function requireRegularFile(dir, file) {
  const target = path.join(dir, file);
  let stats;
  try {
    stats = await lstat(target);
  } catch (error) {
    fail(`artifact file ${file}: cannot stat ${target}: ${error.message}`);
  }
  if (stats.isSymbolicLink()) fail(`artifact file ${file}: symbolic links are not accepted`);
  if (!stats.isFile()) fail(`artifact file ${file}: not a regular file`);
  if (stats.size === 0) fail(`artifact file ${file}: is empty`);
  return target;
}

// --- documents ----------------------------------------------------------------

export function buildManifest(descriptor, artifacts) {
  return {
    schemaVersion: MANIFEST_SCHEMA_VERSION,
    releaseVersion: descriptor.releaseVersion,
    upstreamVersion: descriptor.upstreamVersion,
    upstreamCommit: descriptor.upstreamCommit,
    upstreamRepository: descriptor.upstreamRepository,
    releaseCounter: descriptor.releaseCounter,
    releaseInputSha256: descriptor.releaseInputSha256,
    publicConfigSha256: descriptor.publicConfig.sha256,
    publicConfigKeys: [...PUBLIC_CONFIG_KEYS],
    builderRevision: descriptor.builderRevision,
    presentationVariants: { ...PRESENTATION_VARIANTS },
    variants: Object.fromEntries(
      REQUIRED_VARIANTS.map((name) => [
        name,
        { patches: descriptor.variants[name].patches.map(({ id, sha256 }) => ({ id, sha256 })) },
      ]),
    ),
    artifacts,
  };
}

// `sha256sum -c` format, one line per file, sorted by name.
export function formatSha256Sums(entries) {
  return [...entries]
    .sort((a, b) => (a.file < b.file ? -1 : a.file > b.file ? 1 : 0))
    .map(({ file, sha256 }) => `${sha256}  ${file}\n`)
    .join("");
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

// --- publication --------------------------------------------------------------

// Validates everything, copies each artifact into a staging directory beside
// `destination`, hashes the staged copy (the bytes that will actually be
// published), writes the manifest and SHA256SUMS, and renames the staging
// directory into place. Returns the manifest.
//
// Publication guarantee, and its scope. The destination is an owned output
// path, as with prepare-source. Invocations of this tool against one
// destination are serialized by an adjacent `<destination>.lock` directory
// (mkdir without `recursive` fails with EEXIST when another run holds it), so
// among cooperating publishers exactly one publishes and every other run
// refuses before staging anything. An existing destination, whether a prior
// release or anything else, is refused before the lock is taken and again
// after, and is never modified. What is not guaranteed: POSIX rename replaces
// an *empty* directory, and Node exposes no portable no-replace rename, so an
// unrelated process that creates an empty directory at the destination in
// the instant between the final check and the rename would be replaced. A
// non-empty directory, such as a completed release, always survives
// (ENOTEMPTY). A run killed mid-way leaves the lock behind; remove it by hand
// once no run is in progress.
export async function writeManagedReleaseManifest({ descriptor, inventory, artifactsDir, destination }) {
  validateDescriptor(descriptor);
  const records = validateInventory(descriptor, inventory);
  const sourceDir = await realpath(artifactsDir).catch((error) =>
    fail(`artifact directory ${artifactsDir}: ${error.message}`),
  );
  if (!(await lstat(sourceDir)).isDirectory()) fail(`artifact directory ${artifactsDir} is not a directory`);
  const sources = [];
  for (const record of records) sources.push(await requireRegularFile(sourceDir, record.file));

  if (await exists(destination)) fail(`destination ${destination} already exists; a release is never rewritten`);
  const parent = path.dirname(destination);
  await mkdir(parent, { recursive: true });
  const lockDir = `${destination}.lock`;
  await mkdir(lockDir).catch((error) => {
    if (error.code === "EEXIST") {
      fail(`another publisher holds ${lockDir}; wait for it, or remove the lock if it is stale`);
    }
    throw error;
  });
  try {
    if (await exists(destination)) fail(`destination ${destination} already exists; a release is never rewritten`);
    return await publishInto(destination, parent, descriptor, records, sources);
  } finally {
    await rmdir(lockDir).catch(() => {});
  }
}

async function publishInto(destination, parent, descriptor, records, sources) {
  const staging = await mkdtemp(path.join(parent, `.${path.basename(destination)}.staging-`));
  try {
    const artifacts = [];
    for (const [index, record] of records.entries()) {
      const staged = path.join(staging, record.file);
      await copyFile(sources[index], staged, fsConstants.COPYFILE_EXCL);
      const { bytes, sha256 } = await hashFile(staged);
      artifacts.push({ ...record, bytes, sha256 });
    }
    const manifest = buildManifest(descriptor, artifacts);
    const manifestText = canonicalJson(manifest);
    await writeFile(path.join(staging, MANIFEST_FILE), manifestText, { flag: "wx" });
    const sums = formatSha256Sums([
      ...artifacts.map(({ file, sha256 }) => ({ file, sha256 })),
      { file: MANIFEST_FILE, sha256: createHash("sha256").update(manifestText).digest("hex") },
    ]);
    await writeFile(path.join(staging, SUMS_FILE), sums, { flag: "wx" });
    if (await exists(destination)) fail(`destination ${destination} appeared during staging`);
    await rename(staging, destination);
    return manifest;
  } catch (error) {
    await rm(staging, { recursive: true, force: true });
    throw error;
  }
}

// --- CLI ---------------------------------------------------------------------------

const FLAGS = ["--descriptor", "--inventory", "--artifacts", "--destination"];

export function parseArgs(argv) {
  const options = { descriptor: null, inventory: null, artifacts: null, destination: null };
  for (let i = 0; i < argv.length; i += 1) {
    const flag = argv[i];
    const value = argv[i + 1];
    if (!FLAGS.includes(flag)) fail(`unknown argument ${flag}; expected one of ${FLAGS.join(", ")}`);
    if (value === undefined || value.startsWith("-")) fail(`${flag} requires a value`);
    const key = flag.slice(2);
    if (options[key] !== null) fail(`${flag} given more than once`);
    options[key] = path.resolve(value);
    i += 1;
  }
  for (const flag of FLAGS) {
    if (options[flag.slice(2)] === null) fail(`${flag} is required`);
  }
  return options;
}

async function readJson(file, label) {
  try {
    return JSON.parse(await readFile(file, "utf8"));
  } catch (error) {
    fail(`cannot read ${label} ${file}: ${error.message}`);
  }
}

export async function main(argv) {
  const options = parseArgs(argv);
  const descriptor = await readJson(options.descriptor, "descriptor");
  const inventory = await readJson(options.inventory, "inventory");
  const manifest = await writeManagedReleaseManifest({
    descriptor,
    inventory,
    artifactsDir: options.artifacts,
    destination: options.destination,
  });
  console.log(
    `write-managed-release-manifest: published ${manifest.releaseVersion} with ` +
      `${manifest.artifacts.length} artifact(s) into ${options.destination}`,
  );
}

if (isEntryPoint(import.meta)) {
  main(process.argv.slice(2)).catch((error) => {
    const message = error instanceof ReleaseError ? error.message : error.stack || String(error);
    console.error(`write-managed-release-manifest: ${message}`);
    process.exit(1);
  });
}
