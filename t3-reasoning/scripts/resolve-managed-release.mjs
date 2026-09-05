#!/usr/bin/env node
// Resolve the immutable version and provenance descriptor of one managed T3
// release from explicit inputs only: the version 2 source lock (patch bytes
// re-verified against the declared hashes), the exact upstream nightly version
// the lock's commit was published as, a monotonic release counter, the full
// git revision of the builder that will run the release, and the four public
// build-configuration values read from an explicit JSON file, never from the
// ambient environment.
//
// The release version is
//
//   <upstream nightly>.managed.<counter>.p<12 hex of the release-input digest>
//
// The digest covers the upstream repository, commit, and version, the ordered
// patch ids and hashes of both variants, the builder revision, the fingerprint
// of the public configuration, and the presentation variant each desktop
// build is compiled with. The counter is deliberately outside the digest, so a rebuild of
// identical inputs under a new counter keeps the same `p` suffix. The
// descriptor carries fingerprints, versions, and provenance only; no
// configuration value is ever written or printed.
//
// An optional prior release descriptor lets the resolver refuse a version that
// does not increase over the previous managed build of the same upstream
// nightly. Nothing here consults the network; the publication job separately
// refuses tags and assets that already exist.
// Dependency-free: Node built-ins only.
import { createHash } from "node:crypto";
import { realpathSync } from "node:fs";
import { appendFile, lstat, readFile, realpath, stat, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

export const MANAGED_NIGHTLY_VARIANT = "managed-nightly";
export const REASONING_VARIANT = "reasoning";
// The only variants a managed release may carry, and the relationship the
// lock must express between them: `reasoning` applies exactly the
// `managed-nightly` sequence followed by at least one identity-only patch.
export const REQUIRED_VARIANTS = Object.freeze([MANAGED_NIGHTLY_VARIANT, REASONING_VARIANT]);
// The compile-time `T3CODE_PRODUCT_VARIANT` each desktop tree is built with.
// Recorded explicitly so the digest and every desktop artifact record state
// it rather than inferring it from a bundle name.
export const PRESENTATION_VARIANTS = Object.freeze({
  [MANAGED_NIGHTLY_VARIANT]: MANAGED_NIGHTLY_VARIANT,
  [REASONING_VARIANT]: REASONING_VARIANT,
});
// The four non-secret build values, in canonical (sorted) order. They are
// fingerprinted, never emitted.
export const PUBLIC_CONFIG_KEYS = Object.freeze([
  "T3CODE_CLERK_CLI_OAUTH_CLIENT_ID",
  "T3CODE_CLERK_JWT_TEMPLATE",
  "T3CODE_CLERK_PUBLISHABLE_KEY",
  "T3CODE_RELAY_URL",
]);
export const DESCRIPTOR_KIND = "t3-managed-release-descriptor";
export const DESCRIPTOR_SCHEMA_VERSION = 1;
const RELEASE_INPUT_SCHEMA = "t3-managed-release-input/1";
const PUBLIC_CONFIG_SCHEMA = "t3-managed-public-config/1";
const SHORT_DIGEST_LENGTH = 12;

export const COMMIT_RE = /^[0-9a-f]{40}$/;
export const SHA256_RE = /^[0-9a-f]{64}$/;
const NUMERIC = "(?:0|[1-9]\\d*)";
// An ordinary upstream nightly: `<major>.<minor>.<patch>-nightly.<yyyymmdd>.<run>`.
export const UPSTREAM_NIGHTLY_RE = new RegExp(
  `^${NUMERIC}\\.${NUMERIC}\\.${NUMERIC}-nightly\\.[1-9]\\d{7}\\.${NUMERIC}$`,
);
// The managed release form built on top of it.
export const MANAGED_RELEASE_RE = new RegExp(
  `^(${NUMERIC}\\.${NUMERIC}\\.${NUMERIC}-nightly\\.[1-9]\\d{7}\\.${NUMERIC})` +
    `\\.managed\\.(${NUMERIC})\\.p([0-9a-f]{${SHORT_DIGEST_LENGTH}})$`,
);

export class ReleaseError extends Error {}

function fail(message) {
  throw new ReleaseError(message);
}

function isPlainObject(value) {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

// JSON with every object's keys sorted recursively, so two structurally equal
// inputs serialize to identical bytes whatever order their keys were written
// in. Arrays keep their order: sequence is meaningful for patch lists.
export function canonicalize(value) {
  if (Array.isArray(value)) return value.map(canonicalize);
  if (isPlainObject(value)) {
    return Object.fromEntries(
      Object.keys(value)
        .sort()
        .map((key) => [key, canonicalize(value[key])]),
    );
  }
  return value;
}

export function canonicalJson(value) {
  return `${JSON.stringify(canonicalize(value), null, 2)}\n`;
}

export function sha256Hex(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}

// --- exact version handling -------------------------------------------------

export function parseUpstreamNightlyVersion(version) {
  if (typeof version !== "string" || !UPSTREAM_NIGHTLY_RE.test(version)) {
    fail(
      `upstream version ${JSON.stringify(version)} is not an ordinary upstream nightly ` +
        "(<major>.<minor>.<patch>-nightly.<yyyymmdd>.<run>)",
    );
  }
  return version;
}

// Splits `<upstream>.managed.<counter>.p<digest>` into its parts.
export function parseManagedReleaseVersion(version) {
  const match = typeof version === "string" ? MANAGED_RELEASE_RE.exec(version) : null;
  if (match === null) {
    fail(
      `release version ${JSON.stringify(version)} is not a managed release version ` +
        "(<upstream nightly>.managed.<counter>.p<12 hex>)",
    );
  }
  // The grammar admits `0` and arbitrarily long digit runs; the counter rule
  // (positive safe integer) is applied here so every consumer inherits it.
  const releaseCounter = validateReleaseCounter(Number(match[2]));
  return {
    releaseVersion: version,
    upstreamVersion: match[1],
    releaseCounter,
    releaseInputShort: match[3],
  };
}

export function formatManagedReleaseVersion(upstreamVersion, releaseCounter, releaseInputSha256) {
  return `${upstreamVersion}.managed.${releaseCounter}.p${releaseInputSha256.slice(0, SHORT_DIGEST_LENGTH)}`;
}

function splitExactVersion(version) {
  const match = /^(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?$/.exec(version);
  if (match === null) fail(`version ${JSON.stringify(version)} is not an exact SemVer version`);
  return {
    core: [Number(match[1]), Number(match[2]), Number(match[3])],
    prerelease: match[4] === undefined ? [] : match[4].split("."),
  };
}

function compareIdentifiers(a, b) {
  const aNumeric = /^\d+$/.test(a);
  const bNumeric = /^\d+$/.test(b);
  if (aNumeric && bNumeric) return Math.sign(Number(a) - Number(b));
  if (aNumeric) return -1; // numeric identifiers sort before alphanumeric ones
  if (bNumeric) return 1;
  return a < b ? -1 : a > b ? 1 : 0;
}

// SemVer 2.0.0 precedence for exact versions without build metadata. Extra
// pre-release identifiers sort after a shorter, otherwise equal prefix, which
// is what places `<nightly>.managed.N.pXXXX` after `<nightly>`.
export function compareExactVersions(left, right) {
  const a = splitExactVersion(left);
  const b = splitExactVersion(right);
  for (let i = 0; i < 3; i += 1) {
    if (a.core[i] !== b.core[i]) return a.core[i] < b.core[i] ? -1 : 1;
  }
  if (a.prerelease.length === 0 || b.prerelease.length === 0) {
    return Math.sign(b.prerelease.length - a.prerelease.length);
  }
  const shared = Math.min(a.prerelease.length, b.prerelease.length);
  for (let i = 0; i < shared; i += 1) {
    const order = compareIdentifiers(a.prerelease[i], b.prerelease[i]);
    if (order !== 0) return order;
  }
  return Math.sign(a.prerelease.length - b.prerelease.length);
}

// --- lock verification -------------------------------------------------------

// Structural validation of a version 2 lock: a catalog of `{ id, path, sha256 }`
// and `variants` listing catalog ids in catalog order. Mirrors the preparer's
// rules; the preparer cannot be imported because it runs on import.
export function validateLock(lock, label = "lock") {
  if (!isPlainObject(lock)) fail(`${label}: must be a JSON object`);
  if (lock.version !== 2) fail(`${label}: managed releases require a version 2 lock, found ${lock.version}`);
  if (typeof lock.repository !== "string" || lock.repository === "") {
    fail(`${label}: repository must be a non-empty string`);
  }
  if (typeof lock.commit !== "string" || !COMMIT_RE.test(lock.commit)) {
    fail(`${label}: commit must be a full 40-character lowercase SHA-1`);
  }
  if (!Array.isArray(lock.patches) || lock.patches.length === 0) {
    fail(`${label}: patches must be a non-empty array`);
  }
  const indexById = new Map();
  const seenPaths = new Set();
  lock.patches.forEach((patch, index) => {
    if (!isPlainObject(patch)) fail(`${label}: patches[${index}] must be an object`);
    if (typeof patch.id !== "string" || patch.id === "") {
      fail(`${label}: patches[${index}].id must be a non-empty string`);
    }
    if (typeof patch.path !== "string" || patch.path === "") {
      fail(`${label}: patches[${index}].path must be a non-empty string`);
    }
    if (typeof patch.sha256 !== "string" || !SHA256_RE.test(patch.sha256)) {
      fail(`${label}: patches[${index}].sha256 must be 64 lowercase hex characters`);
    }
    if (indexById.has(patch.id)) fail(`${label}: duplicate patch id ${patch.id} at patches[${index}]`);
    if (seenPaths.has(patch.path)) fail(`${label}: duplicate patch path ${patch.path} at patches[${index}]`);
    indexById.set(patch.id, index);
    seenPaths.add(patch.path);
  });
  if (!isPlainObject(lock.variants)) fail(`${label}: variants must be an object`);
  for (const [name, ids] of Object.entries(lock.variants)) {
    if (!Array.isArray(ids) || ids.length === 0) {
      fail(`${label}: variants.${name} must be a non-empty array of patch ids`);
    }
    let previous = -1;
    ids.forEach((id, position) => {
      if (typeof id !== "string" || !indexById.has(id)) {
        fail(`${label}: variants.${name}[${position}] references unknown patch id ${String(id)}`);
      }
      const index = indexById.get(id);
      if (index <= previous) {
        fail(`${label}: variants.${name}[${position}] (${id}) repeats or is out of catalog order`);
      }
      previous = index;
    });
  }
  return lock;
}

// A managed release is closed over exactly two variants, and the Reasoning
// sequence must be the managed-nightly sequence plus a non-empty identity
// suffix. `variantIds` maps variant name to its ordered patch ids. Returns
// the identity suffix. Shared by the lock resolver and the manifest writer's
// descriptor validation so the closure rule has one implementation.
export function checkVariantClosure(variantIds, label = "lock") {
  if (!isPlainObject(variantIds)) fail(`${label}: variants must be an object`);
  const names = Object.keys(variantIds).sort();
  const expected = [...REQUIRED_VARIANTS].sort();
  if (names.length !== expected.length || names.some((name, i) => name !== expected[i])) {
    fail(
      `${label} variants must be exactly ${expected.join(", ")}; found ${names.join(", ") || "(none)"}`,
    );
  }
  const common = variantIds[MANAGED_NIGHTLY_VARIANT];
  const reasoning = variantIds[REASONING_VARIANT];
  if (!Array.isArray(common) || !Array.isArray(reasoning) || common.length === 0) {
    fail(`${label}: each variant must list at least one patch id`);
  }
  if (reasoning.length <= common.length) {
    fail(
      `variant ${REASONING_VARIANT} must extend ${MANAGED_NIGHTLY_VARIANT} with at least one identity patch`,
    );
  }
  common.forEach((id, position) => {
    if (reasoning[position] !== id) {
      fail(
        `variant ${REASONING_VARIANT}[${position}] is ${reasoning[position]} but ` +
          `${MANAGED_NIGHTLY_VARIANT}[${position}] is ${id}; the common prefix must match exactly`,
      );
    }
  });
  return reasoning.slice(common.length);
}

// Returns the ordered catalog entries per variant and the identity suffix ids
// for a validated lock.
export function resolveReleaseVariants(lock) {
  const identityPatches = checkVariantClosure(lock.variants);
  const byId = new Map(lock.patches.map((patch) => [patch.id, patch]));
  const entries = (ids) => ids.map((id) => ({ id, path: byId.get(id).path, sha256: byId.get(id).sha256 }));
  return {
    variants: {
      [MANAGED_NIGHTLY_VARIANT]: entries(lock.variants[MANAGED_NIGHTLY_VARIANT]),
      [REASONING_VARIANT]: entries(lock.variants[REASONING_VARIANT]),
    },
    identityPatches,
  };
}

function isWithin(dir, target) {
  const relative = path.relative(dir, target);
  if (relative === "") return true;
  if (path.isAbsolute(relative)) return false;
  return relative !== ".." && !relative.startsWith(`..${path.sep}`);
}

async function resolvePatchFile(realLockDir, patchPath) {
  if (path.isAbsolute(patchPath)) fail(`patch ${patchPath}: path must be relative to the lock directory`);
  const nominal = path.resolve(realLockDir, patchPath);
  if (!isWithin(realLockDir, nominal)) fail(`patch ${patchPath}: path resolves outside the lock directory`);
  let real;
  try {
    real = await realpath(nominal);
  } catch (error) {
    fail(`patch ${patchPath}: cannot resolve ${nominal}: ${error.message}`);
  }
  if (!isWithin(realLockDir, real)) fail(`patch ${patchPath}: links outside the lock directory`);
  return real;
}

// Re-hashes every catalog patch file and refuses any byte-level drift from the
// lock, so the digest below can be computed from the lock's hashes alone.
export async function verifyLockPatches(lock, lockPath) {
  const lockDir = await realpath(path.dirname(lockPath));
  for (const patch of lock.patches) {
    const file = await resolvePatchFile(lockDir, patch.path);
    let content;
    try {
      content = await readFile(file);
    } catch (error) {
      fail(`patch ${patch.path}: cannot read: ${error.message}`);
    }
    const actual = sha256Hex(content);
    if (actual !== patch.sha256) {
      fail(`patch ${patch.path}: sha256 mismatch (lock ${patch.sha256}, file ${actual})`);
    }
  }
}

export async function readVerifiedLock(lockPath) {
  let lock;
  try {
    lock = JSON.parse(await readFile(lockPath, "utf8"));
  } catch (error) {
    fail(`cannot read lock ${lockPath}: ${error.message}`);
  }
  validateLock(lock, `lock ${lockPath}`);
  await verifyLockPatches(lock, lockPath);
  return lock;
}

// --- inputs ------------------------------------------------------------------

export function validateReleaseCounter(value) {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 1) {
    fail(`release counter must be a positive safe integer, found ${JSON.stringify(value)}`);
  }
  return value;
}

export function validateBuilderRevision(value) {
  if (typeof value !== "string" || !COMMIT_RE.test(value)) {
    fail("builder revision must be a full 40-character lowercase git SHA-1");
  }
  return value;
}

// Exactly the four public keys, each a non-empty single-line string. Extra
// keys are refused so nothing beyond the public set can reach the fingerprint.
// Values are never included in any error message.
export function validatePublicConfig(config) {
  if (!isPlainObject(config)) fail("public config must be a JSON object");
  const keys = Object.keys(config).sort();
  const missing = PUBLIC_CONFIG_KEYS.filter((key) => !keys.includes(key));
  const extra = keys.filter((key) => !PUBLIC_CONFIG_KEYS.includes(key));
  if (missing.length > 0) fail(`public config is missing ${missing.join(", ")}`);
  if (extra.length > 0) fail(`public config has unexpected keys ${extra.join(", ")}`);
  for (const key of PUBLIC_CONFIG_KEYS) {
    const value = config[key];
    if (typeof value !== "string" || value === "" || value.trim() !== value || /[\p{Cc}]/u.test(value)) {
      fail(`public config ${key} must be a non-empty single-line string without surrounding whitespace`);
    }
  }
  return Object.fromEntries(PUBLIC_CONFIG_KEYS.map((key) => [key, config[key]]));
}

export function computePublicConfigFingerprint(config) {
  const values = validatePublicConfig(config);
  return sha256Hex(canonicalJson({ schema: PUBLIC_CONFIG_SCHEMA, values }));
}

// The digest binds every provenance claim the descriptor and manifest make:
// the upstream repository, commit, and version; for each variant the ordered
// patch sequence as `{ id, sha256 }` pairs (order and ids are significant, so
// the same bytes under a renamed or reordered patch id digest differently;
// paths are not, they are lock-local); the builder revision; the
// public-config fingerprint; and the presentation variants. Object key order
// never matters because the input is canonicalized.
export function computeReleaseInputDigest({
  upstreamRepository,
  upstreamCommit,
  upstreamVersion,
  variants,
  builderRevision,
  publicConfigSha256,
  presentationVariants,
}) {
  const input = {
    schema: RELEASE_INPUT_SCHEMA,
    upstreamRepository,
    upstreamCommit,
    upstreamVersion,
    variants: Object.fromEntries(
      Object.entries(variants).map(([name, patches]) => [
        name,
        patches.map(({ id, sha256 }) => ({ id, sha256 })),
      ]),
    ),
    builderRevision,
    publicConfigSha256,
    presentationVariants,
  };
  return sha256Hex(canonicalJson(input));
}

// Refuses a candidate that would not sort after the previous managed build.
// Same upstream nightly: the counter must strictly increase. A different
// upstream: the new upstream must have greater precedence, and the counter
// restarts at any positive value.
export function checkAgainstPriorRelease(candidate, prior) {
  if (prior === null || prior === undefined) return null;
  if (!isPlainObject(prior)) fail("prior release must be a JSON object");
  const parsed = parseManagedReleaseVersion(prior.releaseVersion);
  if (prior.upstreamVersion !== undefined && prior.upstreamVersion !== parsed.upstreamVersion) {
    fail(`prior release upstreamVersion ${prior.upstreamVersion} disagrees with its releaseVersion`);
  }
  if (prior.releaseCounter !== undefined && prior.releaseCounter !== parsed.releaseCounter) {
    fail(`prior release releaseCounter ${prior.releaseCounter} disagrees with its releaseVersion`);
  }
  if (parsed.upstreamVersion === candidate.upstreamVersion) {
    if (prior.upstreamCommit !== undefined && prior.upstreamCommit !== candidate.upstreamCommit) {
      fail(
        `prior release ${parsed.releaseVersion} pins upstream commit ${prior.upstreamCommit} for the ` +
          `same upstream version, but the lock pins ${candidate.upstreamCommit}`,
      );
    }
    if (candidate.releaseCounter <= parsed.releaseCounter) {
      fail(
        `release counter ${candidate.releaseCounter} does not increase over prior release ` +
          `${parsed.releaseVersion} (counter ${parsed.releaseCounter}) for upstream ${candidate.upstreamVersion}`,
      );
    }
  } else if (compareExactVersions(candidate.upstreamVersion, parsed.upstreamVersion) <= 0) {
    fail(
      `upstream ${candidate.upstreamVersion} does not sort after prior release ${parsed.releaseVersion} ` +
        `(upstream ${parsed.upstreamVersion})`,
    );
  }
  if (compareExactVersions(candidate.releaseVersion, parsed.releaseVersion) <= 0) {
    fail(`release ${candidate.releaseVersion} does not sort after prior release ${parsed.releaseVersion}`);
  }
  return { releaseVersion: parsed.releaseVersion };
}

// --- resolution ----------------------------------------------------------------

// `lock` must already be verified (see readVerifiedLock). Returns the
// descriptor; pure apart from hashing, so it is deterministic for equal inputs.
export function resolveManagedRelease({
  lock,
  upstreamVersion,
  releaseCounter,
  builderRevision,
  publicConfig,
  priorRelease = null,
}) {
  validateLock(lock);
  const { variants, identityPatches } = resolveReleaseVariants(lock);
  parseUpstreamNightlyVersion(upstreamVersion);
  validateReleaseCounter(releaseCounter);
  validateBuilderRevision(builderRevision);
  const publicConfigSha256 = computePublicConfigFingerprint(publicConfig);
  const releaseInputSha256 = computeReleaseInputDigest({
    upstreamRepository: lock.repository,
    upstreamCommit: lock.commit,
    upstreamVersion,
    variants,
    builderRevision,
    publicConfigSha256,
    presentationVariants: PRESENTATION_VARIANTS,
  });
  const releaseVersion = formatManagedReleaseVersion(upstreamVersion, releaseCounter, releaseInputSha256);
  const prior = checkAgainstPriorRelease(
    { releaseVersion, upstreamVersion, upstreamCommit: lock.commit, releaseCounter },
    priorRelease,
  );
  return {
    kind: DESCRIPTOR_KIND,
    schemaVersion: DESCRIPTOR_SCHEMA_VERSION,
    releaseVersion,
    upstreamVersion,
    upstreamCommit: lock.commit,
    upstreamRepository: lock.repository,
    releaseCounter,
    releaseInputSha256,
    releaseInputShort: releaseInputSha256.slice(0, SHORT_DIGEST_LENGTH),
    builderRevision,
    publicConfig: { keys: [...PUBLIC_CONFIG_KEYS], sha256: publicConfigSha256 },
    presentationVariants: { ...PRESENTATION_VARIANTS },
    variants: Object.fromEntries(
      Object.entries(variants).map(([name, patches]) => [name, { patches: patches.map((p) => ({ ...p })) }]),
    ),
    identityPatches: [...identityPatches],
    priorRelease: prior,
  };
}

// --- CLI ------------------------------------------------------------------------

const FLAGS = [
  "--lock",
  "--upstream-version",
  "--release-counter",
  "--builder-revision",
  "--public-config",
  "--prior-release",
  "--output",
  "--github-output",
];
const REQUIRED_FLAGS = ["--upstream-version", "--release-counter", "--builder-revision", "--public-config", "--output"];
const componentDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

export function parseArgs(argv) {
  const options = {
    lock: path.join(componentDir, "source.lock.json"),
    upstreamVersion: null,
    releaseCounter: null,
    builderRevision: null,
    publicConfig: null,
    priorRelease: null,
    output: null,
    githubOutput: null,
  };
  const seen = new Set();
  for (let i = 0; i < argv.length; i += 1) {
    const flag = argv[i];
    const value = argv[i + 1];
    if (!FLAGS.includes(flag)) fail(`unknown argument ${flag}; expected one of ${FLAGS.join(", ")}`);
    if (value === undefined || value.startsWith("-")) fail(`${flag} requires a value`);
    if (seen.has(flag)) fail(`${flag} given more than once`);
    seen.add(flag);
    switch (flag) {
      case "--upstream-version":
        options.upstreamVersion = value;
        break;
      case "--release-counter":
        if (!/^[1-9]\d*$/.test(value)) fail(`--release-counter must be a positive integer, found ${value}`);
        options.releaseCounter = Number(value);
        break;
      case "--builder-revision":
        options.builderRevision = value;
        break;
      default:
        options[flag.slice(2).replace(/-([a-z])/g, (_, c) => c.toUpperCase())] = path.resolve(value);
    }
    i += 1;
  }
  for (const flag of REQUIRED_FLAGS) {
    if (!seen.has(flag)) fail(`${flag} is required`);
  }
  return options;
}

async function readJson(file, label) {
  try {
    return JSON.parse(await readFile(file, "utf8"));
  } catch {
    fail(`cannot read or parse ${label} ${file}`);
  }
}

// Only fingerprints, versions, and provenance are written to a GitHub Actions
// output file; the lines are appended because that file is shared by steps.
function githubOutputLines(descriptor) {
  return [
    `release_version=${descriptor.releaseVersion}`,
    `upstream_version=${descriptor.upstreamVersion}`,
    `upstream_commit=${descriptor.upstreamCommit}`,
    `release_counter=${descriptor.releaseCounter}`,
    `release_input_sha256=${descriptor.releaseInputSha256}`,
    `public_config_sha256=${descriptor.publicConfig.sha256}`,
    `builder_revision=${descriptor.builderRevision}`,
  ]
    .map((line) => `${line}\n`)
    .join("");
}

// The canonical form of a path that may not exist yet: the nearest existing
// ancestor with symlinks resolved, plus the remaining lexical tail. Two paths
// with the same canonical form name the same eventual file.
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

// The GitHub output file is appended to after the descriptor is written, so
// it must not alias the descriptor or anything this run read: the lock, the
// public config, the prior release, or a patch file. Aliases are detected
// both by canonical path (symlinked or aliased directories, dangling links)
// and, where the file exists, by device and inode (hard links, symlinked
// files). A symlink is refused outright: the CI `GITHUB_OUTPUT` file is a
// regular file. Runs before any write, so a refusal leaves nothing behind.
// Error messages name paths only, never contents.
export async function guardGithubOutput(githubOutput, output, inputs) {
  let existing = null;
  try {
    existing = await lstat(githubOutput);
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
  }
  if (existing !== null && existing.isSymbolicLink()) {
    fail(`--github-output ${githubOutput} is a symbolic link; it must be a regular file`);
  }
  if (existing !== null && !existing.isFile()) {
    fail(`--github-output ${githubOutput} is not a regular file`);
  }
  const canonical = await canonicalPath(githubOutput);
  if (canonical === (await canonicalPath(output))) {
    fail(`--github-output ${githubOutput} must not be the same file as --output ${output}`);
  }
  for (const { label, file } of inputs) {
    if (canonical === (await canonicalPath(file))) {
      fail(`--github-output ${githubOutput} must not be the same file as the ${label} ${file}`);
    }
    if (existing === null) continue;
    const input = await stat(file);
    if (input.dev === existing.dev && input.ino === existing.ino) {
      fail(`--github-output ${githubOutput} is linked to the ${label} ${file}; it must be a separate file`);
    }
  }
}

export async function main(argv) {
  const options = parseArgs(argv);
  const lock = await readVerifiedLock(options.lock);
  const publicConfig = await readJson(options.publicConfig, "public config");
  const priorRelease = options.priorRelease === null ? null : await readJson(options.priorRelease, "prior release");
  const descriptor = resolveManagedRelease({
    lock,
    upstreamVersion: options.upstreamVersion,
    releaseCounter: options.releaseCounter,
    builderRevision: options.builderRevision,
    publicConfig,
    priorRelease,
  });
  if (options.githubOutput !== null) {
    const lockDir = await realpath(path.dirname(options.lock));
    await guardGithubOutput(options.githubOutput, options.output, [
      { label: "lock", file: options.lock },
      { label: "public config", file: options.publicConfig },
      ...(options.priorRelease === null ? [] : [{ label: "prior release", file: options.priorRelease }]),
      ...lock.patches.map((patch) => ({ label: "patch", file: path.resolve(lockDir, patch.path) })),
    ]);
  }
  // `wx` refuses an existing file: a descriptor is never overwritten.
  try {
    await writeFile(options.output, canonicalJson(descriptor), { flag: "wx" });
  } catch (error) {
    if (error.code === "EEXIST") fail(`output ${options.output} already exists; a descriptor is never overwritten`);
    throw error;
  }
  if (options.githubOutput !== null) await appendFile(options.githubOutput, githubOutputLines(descriptor));
  console.log(
    `resolve-managed-release: resolved ${descriptor.releaseVersion} ` +
      `(inputs ${descriptor.releaseInputSha256}) into ${options.output}`,
  );
}

// import.meta.main (Node 24, 22.18+) is true only for the process entry
// module. Older runtimes leave it undefined; there the entry is recognized by
// comparing real paths, which also covers symlinked or aliased invocations.
export function isEntryPoint(meta = import.meta) {
  if (typeof meta.main === "boolean") return meta.main;
  const entry = process.argv[1];
  if (!entry) return false;
  try {
    return realpathSync(entry) === realpathSync(fileURLToPath(meta.url));
  } catch {
    return false;
  }
}

if (isEntryPoint()) {
  main(process.argv.slice(2)).catch((error) => {
    const message = error instanceof ReleaseError ? error.message : error.stack || String(error);
    console.error(`resolve-managed-release: ${message}`);
    process.exit(1);
  });
}
