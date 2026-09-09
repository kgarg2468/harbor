#!/usr/bin/env node
// Publish one managed T3 release closure to GitHub as one immutable
// prerelease of the fixed Harbor repository, and provide the small trusted
// steps the release workflow needs around it. Every subcommand is closed to
// `kgarg2468/harbor` and the `t3-managed-v` tag prefix; no caller input can
// name another repository, ref, tag, or platform.
//
// Subcommands (see parseArgs):
//
// - `public-config`: build the exact four-key public-config JSON from the
//   environment through the resolver's own validation, without printing a
//   value.
// - `verify-upstream`: validate the tracked provenance record against the
//   verified lock, re-read the official upstream release by id, and peel its
//   tag; any drift fails closed.
// - `prior`: find the highest published, immutable, non-draft Harbor
//   prerelease whose tag is exactly `t3-managed-v<managed version>`, download
//   its unique `managed-release.json` by numeric asset id, and write it as the
//   resolver's `--prior-release` input.
// - `preflight`: require immutable releases to be enabled and the intended
//   tag to be absent from refs and from releases of every state.
// - `assemble`: collect exactly one archive and one inventory per build row
//   into one flat artifact directory plus one inventory array, without
//   executing anything downloaded.
// - `publish`: prove the local six-file closure, repeat the trust and
//   upstream checks, create one draft prerelease, upload the six files
//   without clobber, re-read and verify remote identities, sizes, and
//   digests, publish by changing only `draft`, then verify the immutable
//   exact-tag release resolves to the builder commit.
//
// GitHub is reached only through `gh api` with argv (never a shell string)
// via one injectable runner, so unit tests drive every path offline. The
// wrapper accepts GET, POST, and PATCH only: nothing here can delete, force,
// clobber, or edit an existing release, tag, or asset. A failure before the
// publish call leaves the draft (not visible to the public) in place for a
// person to inspect. Once the publish PATCH has been sent, the release may be
// public: a lost PATCH response or a failed post-publication proof is
// reported with the release id for manual inspection and nothing is retried,
// reused, or removed. The next workflow run consumes a new counter and tag.
//
// Credentials: every release operation runs on the workflow's own
// `GITHUB_TOKEN` (contents read/write). The one exception is the repository's
// immutable-releases setting, which GitHub serves only to repository
// Administration read. That single fixed GET runs through a separate closed
// client whose token comes from `T3_MANAGED_RELEASE_ADMIN_READ_TOKEN` and is
// handed to its child `gh` process only as `GH_TOKEN`, never as an argument,
// output, or log line. A missing token or a refused read is fatal before any
// fan-out or mutation.
// Dependency-free: Node built-ins, `gh`, and the release contract's helpers.
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { constants as fsConstants } from "node:fs";
import { appendFile, copyFile, lstat, mkdir, readdir, readFile, realpath, writeFile } from "node:fs/promises";
import path from "node:path";
import {
  API_PREFIX as UPSTREAM_API_PREFIX,
  DiscoveryError,
  UPSTREAM_REPOSITORY,
  createGhApi as createUpstreamApi,
  normalizeRelease as normalizeUpstreamRelease,
  normalizeReleasePages,
  resolvePublishedCommit,
  validateProvenance,
} from "./discover-upstream-nightly.mjs";
import {
  COMMIT_RE,
  PRESENTATION_VARIANTS,
  PUBLIC_CONFIG_KEYS,
  REQUIRED_VARIANTS,
  ReleaseError,
  SHA256_RE,
  canonicalJson,
  checkVariantClosure,
  compareExactVersions,
  computePublicConfigFingerprint,
  computeReleaseInputDigest,
  formatManagedReleaseVersion,
  isEntryPoint,
  parseManagedReleaseVersion,
  parseUpstreamNightlyVersion,
  readVerifiedLock,
  validateBuilderRevision,
  validateLock,
  validatePublicConfig,
} from "./resolve-managed-release.mjs";
import { EXPECTED_ARTIFACTS, MANIFEST_FILE, SUMS_FILE, formatSha256Sums, hashFile } from "./write-managed-release-manifest.mjs";

export const HARBOR_REPOSITORY = "kgarg2468/harbor";
export const HARBOR_API_PREFIX = `/repos/${HARBOR_REPOSITORY}/`;
export const HARBOR_UPLOAD_PREFIX = `https://uploads.github.com/repos/${HARBOR_REPOSITORY}/releases/`;
export const HARBOR_RELEASE_URL_PREFIX = `https://api.github.com/repos/${HARBOR_REPOSITORY}/releases/`;
export const TAG_PREFIX = "t3-managed-v";
export const TRUSTED_REF = "refs/heads/main";
// The only endpoint the administration-read credential may ever reach.
export const IMMUTABLE_SETTINGS_ENDPOINT = `${HARBOR_API_PREFIX}immutable-releases`;
export const ADMIN_READ_TOKEN_ENV = "T3_MANAGED_RELEASE_ADMIN_READ_TOKEN";
// Actions artifact name prefix of one build row; the row's artifact id follows.
export const BUILD_ARTIFACT_PREFIX = "t3-managed-build-";
export const MANIFEST_SCHEMA_VERSION = 1;
const RELEASE_FILE_COUNT = 6;
const MAX_TAG_DEPTH = 8;
const DIAGNOSTIC_LINES = 6;
const ALLOWED_METHODS = ["GET", "POST", "PATCH"];
const ASSET_NAME_RE = /^[A-Za-z0-9][A-Za-z0-9._-]*$/;
const PUBLISHED_AT_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/;
const CONTENT_TYPES = { json: "application/json", zip: "application/zip", "tar.gz": "application/gzip" };

export class PublishError extends Error {}

function fail(message) {
  throw new PublishError(message);
}

function isPlainObject(value) {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function sameJson(a, b) {
  return JSON.stringify(a) === JSON.stringify(b);
}

function isReleaseId(value) {
  return Number.isSafeInteger(value) && value >= 1;
}

function boundedTail(text) {
  return String(text ?? "")
    .trim()
    .split("\n")
    .slice(-DIAGNOSTIC_LINES)
    .join(" ");
}

export function releaseTag(releaseVersion) {
  return `${TAG_PREFIX}${parseManagedReleaseVersion(releaseVersion).releaseVersion}`;
}

// The managed version a tag names, or null when the tag is not exactly
// `t3-managed-v<valid managed version>`.
export function managedVersionOfTag(tag) {
  if (typeof tag !== "string" || !tag.startsWith(TAG_PREFIX)) return null;
  try {
    return parseManagedReleaseVersion(tag.slice(TAG_PREFIX.length)).releaseVersion;
  } catch (error) {
    if (error instanceof ReleaseError) return null;
    throw error;
  }
}

// --- GitHub API through gh ------------------------------------------------------

// Only Harbor's own REST prefix and Harbor's asset upload URL are reachable.
// Anything else, including the repository root, a path escape, or another
// host, is a programming error refused before gh runs.
export function requireHarborEndpoint(endpoint) {
  if (typeof endpoint !== "string") fail(`refusing API endpoint ${String(endpoint)}: not a string`);
  const upload = /^https:\/\/uploads\.github\.com\/repos\/kgarg2468\/harbor\/releases\/\d+\/assets\?name=[A-Za-z0-9._%-]+$/;
  if (upload.test(endpoint)) return endpoint;
  if (!endpoint.startsWith(HARBOR_API_PREFIX) || endpoint.length === HARBOR_API_PREFIX.length) {
    fail(`refusing API endpoint ${endpoint}: only ${HARBOR_API_PREFIX}* and ${HARBOR_UPLOAD_PREFIX}<id>/assets are allowed`);
  }
  if (endpoint.split("?")[0].split("/").some((segment) => segment === "..")) {
    fail(`refusing API endpoint ${endpoint}: path escape`);
  }
  return endpoint;
}

// The default runner: argv only, no shell; optional stdin text; raw
// (Buffer) or text stdout. Rejections carry `stderr` and `code`.
//
// Lifecycle. The input is written and stdin closed as soon as the child is
// spawned, so a child that exits, or closes its stdin without reading it,
// before that completes makes this side's stdin socket fail (EPIPE, or a
// destroyed stream). That failure is only a symptom of the child's own
// outcome: it is recorded, never left as an unhandled stream error, and the
// child's `close` stays authoritative. A nonzero exit is reported as the
// child's failure; a zero exit is trusted when no input was owed or the
// input was delivered, and is otherwise rejected, because a request body
// that never reached the child is not a success. A spawn failure rejects
// at once. Every path settles exactly once, and no rejection ever carries
// the input or the child's environment.
export function defaultRun(command, args, { input = "", raw = false, env = {}, cwd } = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, {
      cwd,
      env: { ...process.env, GIT_TERMINAL_PROMPT: "0", GH_PROMPT_DISABLED: "1", GH_NO_UPDATE_NOTIFIER: "1", ...env },
      stdio: ["pipe", "pipe", "pipe"],
    });
    const label = `${command} ${args.slice(0, 3).join(" ")}`;
    const out = [];
    let stderr = "";
    let stdinError = null;
    let settled = false;
    const settle = (outcome) => {
      if (settled) return;
      settled = true;
      outcome();
    };
    const failure = (message, code) => {
      const error = new Error(message);
      error.code = code;
      error.stderr = stderr;
      return error;
    };
    const recordStdinError = (error) => {
      if (stdinError === null) stdinError = error;
    };
    child.stdout.on("data", (chunk) => out.push(chunk));
    child.stderr.on("data", (chunk) => (stderr += chunk));
    child.stdin.on("error", recordStdinError);
    child.on("error", (error) => settle(() => reject(error)));
    child.on("close", (code) =>
      settle(() => {
        if (code !== 0) return reject(failure(`${label} exited ${code}`, code));
        if (stdinError !== null && input.length > 0) {
          const reason = typeof stdinError.code === "string" ? stdinError.code : "stream failure";
          return reject(failure(`${label} exited 0 but its stdin failed before the request body was delivered (${reason})`, reason));
        }
        resolve({ stdout: raw ? Buffer.concat(out) : Buffer.concat(out).toString("utf8"), stderr });
      }),
    );
    try {
      child.stdin.end(input);
    } catch (error) {
      recordStdinError(error);
      child.stdin.destroy();
    }
  });
}

// `api(method, endpoint, options)` over `gh api`. Options: `body` (JSON on
// stdin), `inputFile` (raw request body from a file, for uploads),
// `contentType`, `paginate` (every page slurped into one array of pages),
// `raw` (octet-stream response as a Buffer). GET, POST, and PATCH only.
export function createHarborApi(run = defaultRun) {
  return async function api(method, endpoint, { body, inputFile, contentType, paginate = false, raw = false } = {}) {
    if (!ALLOWED_METHODS.includes(method)) fail(`refusing method ${String(method)}: only ${ALLOWED_METHODS.join(", ")} are used`);
    requireHarborEndpoint(endpoint);
    if (body !== undefined && inputFile !== undefined) fail("body and inputFile are exclusive");
    const args = ["api", "--method", method];
    if (paginate) args.push("--paginate", "--slurp");
    if (raw) args.push("-H", "Accept: application/octet-stream");
    if (contentType !== undefined) args.push("-H", `Content-Type: ${contentType}`);
    if (body !== undefined) args.push("--input", "-");
    if (inputFile !== undefined) args.push("--input", inputFile);
    args.push(endpoint);
    let stdout;
    try {
      ({ stdout } = await run("gh", args, { input: body === undefined ? "" : JSON.stringify(body), raw }));
    } catch (error) {
      fail(`gh api ${method} ${endpoint} failed: ${boundedTail(error.stderr || error.message)}`);
    }
    if (raw) return Buffer.isBuffer(stdout) ? stdout : Buffer.from(stdout);
    if (String(stdout).trim() === "") return null;
    try {
      return JSON.parse(stdout);
    } catch {
      fail(`gh api ${method} ${endpoint} returned invalid JSON`);
    }
  };
}

// A closed reader for the repository's immutable-releases setting, the one
// call that needs repository Administration read. It can only GET the fixed
// endpoint; the token is supplied to the child `gh` solely as `GH_TOKEN` and
// is never part of argv, output, or an error message. Fails closed without a
// usable token.
export function createImmutableSettingsReader({ token, run = defaultRun }) {
  return async function readImmutableSetting() {
    if (typeof token !== "string" || token.trim() === "") {
      fail(`${ADMIN_READ_TOKEN_ENV} is not set; the immutable-releases setting needs a repository Administration read token`);
    }
    const args = ["api", "--method", "GET", IMMUTABLE_SETTINGS_ENDPOINT];
    let stdout;
    try {
      ({ stdout } = await run("gh", args, { env: { GH_TOKEN: token } }));
    } catch (error) {
      const detail = boundedTail(error.stderr || error.message).split(token).join("[redacted]");
      fail(`gh api GET ${IMMUTABLE_SETTINGS_ENDPOINT} failed (the ${ADMIN_READ_TOKEN_ENV} identity needs repository Administration read): ${detail}`);
    }
    try {
      return JSON.parse(stdout);
    } catch {
      fail(`gh api GET ${IMMUTABLE_SETTINGS_ENDPOINT} returned invalid JSON`);
    }
  };
}

// --- public config --------------------------------------------------------------

// Exactly the four public keys, read from the given environment and checked
// by the resolver's validator, which never echoes a value. Written once.
export async function writePublicConfig({ env = process.env, output }) {
  const config = validatePublicConfig(Object.fromEntries(PUBLIC_CONFIG_KEYS.map((key) => [key, env[key]])));
  const text = canonicalJson(config);
  await writeNew(output, text, "public config");
  return { output, sha256: computePublicConfigFingerprint(config) };
}

async function writeNew(file, text, label) {
  await mkdir(path.dirname(file), { recursive: true });
  try {
    await writeFile(file, text, { flag: "wx" });
  } catch (error) {
    if (error.code === "EEXIST") fail(`${label} output ${file} already exists; it is never overwritten`);
    throw error;
  }
}

// --- manifest -------------------------------------------------------------------

function validateAssetName(name, label) {
  if (typeof name !== "string" || !ASSET_NAME_RE.test(name) || name === "." || name === "..") {
    fail(`${label}: file ${JSON.stringify(name)} is not a bare release asset name`);
  }
  return name;
}

// A published manifest is trusted only when its version and digest are
// exactly what the resolver derives from the provenance it carries, and its
// artifact list is exactly the fixed four with the fixed identities.
export function validateManifest(manifest, label = "manifest") {
  if (!isPlainObject(manifest)) fail(`${label}: must be a JSON object`);
  if (manifest.schemaVersion !== MANIFEST_SCHEMA_VERSION) {
    fail(`${label}: schemaVersion must be ${MANIFEST_SCHEMA_VERSION}, found ${JSON.stringify(manifest.schemaVersion)}`);
  }
  const parsed = parseManagedReleaseVersion(manifest.releaseVersion);
  parseUpstreamNightlyVersion(manifest.upstreamVersion);
  if (manifest.upstreamVersion !== parsed.upstreamVersion) fail(`${label}: upstreamVersion does not match releaseVersion`);
  if (manifest.releaseCounter !== parsed.releaseCounter) fail(`${label}: releaseCounter does not match releaseVersion`);
  if (typeof manifest.upstreamCommit !== "string" || !COMMIT_RE.test(manifest.upstreamCommit)) {
    fail(`${label}: upstreamCommit must be a full 40-character lowercase SHA-1`);
  }
  if (typeof manifest.upstreamRepository !== "string" || manifest.upstreamRepository === "") {
    fail(`${label}: upstreamRepository must be a non-empty string`);
  }
  validateBuilderRevision(manifest.builderRevision);
  if (typeof manifest.releaseInputSha256 !== "string" || !SHA256_RE.test(manifest.releaseInputSha256)) {
    fail(`${label}: releaseInputSha256 must be 64 lowercase hex characters`);
  }
  if (typeof manifest.publicConfigSha256 !== "string" || !SHA256_RE.test(manifest.publicConfigSha256)) {
    fail(`${label}: publicConfigSha256 must be 64 lowercase hex characters`);
  }
  if (!sameJson(manifest.publicConfigKeys, PUBLIC_CONFIG_KEYS)) fail(`${label}: publicConfigKeys must be exactly ${PUBLIC_CONFIG_KEYS.join(", ")}`);
  if (!sameJson(manifest.presentationVariants, PRESENTATION_VARIANTS)) fail(`${label}: presentationVariants must be ${JSON.stringify(PRESENTATION_VARIANTS)}`);
  if (!isPlainObject(manifest.variants)) fail(`${label}: variants must be an object`);
  const names = Object.keys(manifest.variants).sort();
  if (!sameJson(names, [...REQUIRED_VARIANTS].sort())) fail(`${label}: variants must be exactly ${REQUIRED_VARIANTS.join(", ")}`);
  for (const name of names) {
    const patches = manifest.variants[name]?.patches;
    if (!Array.isArray(patches) || patches.length === 0) fail(`${label}: variants.${name}.patches must be non-empty`);
    patches.forEach((patch, index) => {
      if (!isPlainObject(patch) || typeof patch.id !== "string" || patch.id === "" || !SHA256_RE.test(String(patch.sha256))) {
        fail(`${label}: variants.${name}.patches[${index}] must have an id and a sha256`);
      }
    });
  }
  checkVariantClosure(Object.fromEntries(names.map((name) => [name, manifest.variants[name].patches.map((patch) => patch.id)])), label);
  const digest = computeReleaseInputDigest({
    upstreamRepository: manifest.upstreamRepository,
    upstreamCommit: manifest.upstreamCommit,
    upstreamVersion: manifest.upstreamVersion,
    variants: Object.fromEntries(names.map((name) => [name, manifest.variants[name].patches])),
    builderRevision: manifest.builderRevision,
    publicConfigSha256: manifest.publicConfigSha256,
    presentationVariants: manifest.presentationVariants,
  });
  if (manifest.releaseInputSha256 !== digest) {
    fail(`${label}: releaseInputSha256 does not match the digest recomputed from its provenance; the manifest has been altered`);
  }
  const expectedVersion = formatManagedReleaseVersion(manifest.upstreamVersion, manifest.releaseCounter, digest);
  if (manifest.releaseVersion !== expectedVersion) fail(`${label}: releaseVersion ${manifest.releaseVersion} does not match the resolved ${expectedVersion}`);

  if (!Array.isArray(manifest.artifacts) || manifest.artifacts.length !== EXPECTED_ARTIFACTS.length) {
    fail(`${label}: artifacts must list exactly four release artifacts`);
  }
  const byId = new Map();
  manifest.artifacts.forEach((record, index) => {
    if (!isPlainObject(record) || typeof record.id !== "string") fail(`${label}: artifacts[${index}] must be an object with an id`);
    if (byId.has(record.id)) fail(`${label}: duplicate artifact id ${record.id}`);
    byId.set(record.id, record);
  });
  const seenFiles = new Set([MANIFEST_FILE.toLowerCase(), SUMS_FILE.toLowerCase()]);
  const artifacts = EXPECTED_ARTIFACTS.map((expected) => {
    const record = byId.get(expected.id);
    const artifactLabel = `${label}: artifact ${expected.id}`;
    if (record === undefined) fail(`${label}: artifacts must list exactly four release artifacts; ${expected.id} is missing`);
    for (const [key, value] of Object.entries(expected)) {
      if (!sameJson(record[key], value)) fail(`${artifactLabel}: ${key} must be ${JSON.stringify(value)}`);
    }
    validateAssetName(record.file, artifactLabel);
    if (!record.file.endsWith(`.${expected.format}`)) fail(`${artifactLabel}: file must end with .${expected.format}`);
    const folded = record.file.toLowerCase();
    if (seenFiles.has(folded)) fail(`${artifactLabel}: file ${record.file} collides with another release file`);
    seenFiles.add(folded);
    if (!Number.isSafeInteger(record.bytes) || record.bytes < 1) fail(`${artifactLabel}: bytes must be a positive integer`);
    if (typeof record.sha256 !== "string" || !SHA256_RE.test(record.sha256)) fail(`${artifactLabel}: sha256 must be 64 lowercase hex characters`);
    if (record.version !== manifest.releaseVersion) fail(`${artifactLabel}: version must equal the release version`);
    return { id: expected.id, file: record.file, format: expected.format, bytes: record.bytes, sha256: record.sha256 };
  });
  return { manifest, parsed, artifacts, tag: `${TAG_PREFIX}${manifest.releaseVersion}` };
}

function parseManifestText(text, label) {
  let manifest;
  try {
    manifest = JSON.parse(text);
  } catch (error) {
    fail(`${label}: cannot parse JSON: ${error.message}`);
  }
  return validateManifest(manifest, label);
}

// --- local closure -----------------------------------------------------------------

async function requireRegularFile(dir, name, label) {
  const target = path.join(dir, name);
  let stats;
  try {
    stats = await lstat(target);
  } catch (error) {
    if (error.code === "ENOENT") fail(`${label}: ${name} is missing`);
    fail(`${label}: cannot stat ${name}: ${error.message}`);
  }
  if (stats.isSymbolicLink()) fail(`${label}: ${name} is a symbolic link; only regular files are published`);
  if (!stats.isFile()) fail(`${label}: ${name} is not a regular file`);
  if (stats.size === 0) fail(`${label}: ${name} is empty`);
  return target;
}

function contentTypeFor(name, format) {
  if (name === SUMS_FILE) return "text/plain";
  if (name === MANIFEST_FILE) return CONTENT_TYPES.json;
  return CONTENT_TYPES[format] ?? "application/octet-stream";
}

// The release directory must contain exactly the six feed files, all regular,
// with every SHA256SUMS entry and every manifest size/digest matching the
// local bytes. Nothing is read from anywhere else and nothing is executed.
export async function readReleaseClosure(releaseDir) {
  const label = "release directory";
  let dir;
  try {
    dir = await realpath(releaseDir);
  } catch (error) {
    fail(`${label} ${releaseDir}: ${error.message}`);
  }
  if (!(await lstat(dir)).isDirectory()) fail(`${label} ${releaseDir} is not a directory`);
  const manifestPath = await requireRegularFile(dir, MANIFEST_FILE, label);
  const manifestText = await readFile(manifestPath, "utf8");
  const { manifest, artifacts, tag } = parseManifestText(manifestText, MANIFEST_FILE);

  const expectedNames = [MANIFEST_FILE, SUMS_FILE, ...artifacts.map((artifact) => artifact.file)];
  const present = (await readdir(dir)).sort();
  for (const name of present) {
    if (!expectedNames.includes(name)) fail(`${label}: unexpected file ${name}; only the six feed files may be published`);
  }
  for (const name of expectedNames) {
    if (!present.includes(name)) fail(`${label}: ${name} is missing`);
  }
  if (present.length !== RELEASE_FILE_COUNT) fail(`${label}: expected exactly ${RELEASE_FILE_COUNT} files, found ${present.length}`);

  const sumsPath = await requireRegularFile(dir, SUMS_FILE, label);
  const sumsText = await readFile(sumsPath, "utf8");
  const entries = sumsText
    .split("\n")
    .filter((line) => line !== "")
    .map((line) => {
      const match = /^([0-9a-f]{64})  (\S.*)$/.exec(line);
      if (match === null) fail(`SHA256SUMS: unparseable line ${JSON.stringify(line)}`);
      return { sha256: match[1], file: match[2] };
    });
  const sumNames = entries.map((entry) => entry.file);
  if (!sameJson([...sumNames].sort(), expectedNames.filter((name) => name !== SUMS_FILE).sort())) {
    fail(`SHA256SUMS must cover exactly the manifest and the four artifacts; found ${sumNames.join(", ") || "(none)"}`);
  }
  if (sumsText !== formatSha256Sums(entries)) fail("SHA256SUMS is not in the writer's sorted canonical form");
  const sumsByFile = new Map(entries.map((entry) => [entry.file, entry.sha256]));

  const files = [];
  const manifestHash = await hashFile(manifestPath);
  if (sumsByFile.get(MANIFEST_FILE) !== manifestHash.sha256) fail(`SHA256SUMS entry for ${MANIFEST_FILE} does not match its bytes`);
  files.push({ name: MANIFEST_FILE, path: manifestPath, ...manifestHash, contentType: contentTypeFor(MANIFEST_FILE) });
  files.push({ name: SUMS_FILE, path: sumsPath, ...(await hashFile(sumsPath)), contentType: contentTypeFor(SUMS_FILE) });
  for (const artifact of artifacts) {
    const file = await requireRegularFile(dir, artifact.file, label);
    const actual = await hashFile(file);
    if (actual.bytes !== artifact.bytes) fail(`artifact ${artifact.file}: manifest records ${artifact.bytes} bytes, file has ${actual.bytes}`);
    if (actual.sha256 !== artifact.sha256) fail(`artifact ${artifact.file}: manifest sha256 does not match the file bytes`);
    if (sumsByFile.get(artifact.file) !== actual.sha256) fail(`SHA256SUMS entry for ${artifact.file} does not match its bytes`);
    files.push({ name: artifact.file, path: file, ...actual, contentType: contentTypeFor(artifact.file, artifact.format) });
  }
  return { dir, manifest, tag, files };
}

// --- trust and upstream checks --------------------------------------------------------

export function requireTrustedContext({ repository, ref, builderRevision, manifest = null }) {
  if (repository !== HARBOR_REPOSITORY) fail(`repository must be ${HARBOR_REPOSITORY}, found ${JSON.stringify(repository)}`);
  if (ref !== TRUSTED_REF) fail(`ref must be ${TRUSTED_REF}, found ${JSON.stringify(ref)}`);
  validateBuilderRevision(builderRevision);
  if (manifest !== null && manifest.builderRevision !== builderRevision) {
    fail(`manifest builderRevision ${manifest.builderRevision} is not the trusted commit ${builderRevision}`);
  }
}

// The tracked provenance record must agree with the verified lock (and the
// manifest when given), the official release must still be the same
// published Nightly prerelease, and its tag must still peel to the pinned
// commit. Same-version mutation upstream fails closed.
export async function verifyUpstreamRelease({ record, lock = null, manifest = null, upstreamApi }) {
  const provenance = validateProvenance(record, "upstream release record");
  if (lock !== null) {
    validateLock(lock);
    if (lock.repository !== UPSTREAM_REPOSITORY) fail(`lock pins repository ${lock.repository}; managed releases build only ${UPSTREAM_REPOSITORY}`);
    if (lock.commit !== provenance.commit) fail(`lock pins commit ${lock.commit} but the upstream release record names ${provenance.commit}`);
  }
  if (manifest !== null) {
    if (manifest.upstreamVersion !== provenance.version) fail(`manifest upstreamVersion ${manifest.upstreamVersion} is not the tracked ${provenance.version}`);
    if (manifest.upstreamCommit !== provenance.commit) fail(`manifest upstreamCommit ${manifest.upstreamCommit} is not the tracked ${provenance.commit}`);
    if (manifest.upstreamRepository !== UPSTREAM_REPOSITORY) fail(`manifest upstreamRepository ${manifest.upstreamRepository} is not ${UPSTREAM_REPOSITORY}`);
  }
  const reread = normalizeUpstreamRelease(await upstreamApi(`${UPSTREAM_API_PREFIX}releases/${provenance.releaseId}`));
  if (reread === null) fail(`upstream release ${provenance.releaseId} (${provenance.tag}) is no longer a published Nightly prerelease`);
  for (const key of ["releaseId", "tag", "version", "publishedAt"]) {
    if (reread[key] !== provenance[key]) fail(`upstream release ${provenance.releaseId} moved: ${key} was ${provenance[key]}, now ${reread[key]}`);
  }
  const commit = await resolvePublishedCommit(provenance, upstreamApi);
  if (commit !== provenance.commit) fail(`upstream tag ${provenance.tag} resolves to ${commit}, the record pins ${provenance.commit}`);
  return provenance;
}

// `readImmutableSetting` is the closed reader above (or a test double); it
// is deliberately not the ordinary release API, whose token cannot read this.
export async function requireImmutableReleasesEnabled(readImmutableSetting) {
  const setting = await readImmutableSetting();
  if (!isPlainObject(setting) || setting.enabled !== true) {
    fail(`immutable releases are not enabled for ${HARBOR_REPOSITORY}; enable the repository setting before publishing`);
  }
}

function tagRefEndpoint(tag) {
  return `${HARBOR_API_PREFIX}git/ref/tags/${encodeURIComponent(tag)}`;
}

// A release listing used as evidence: every row must be an object with a
// string tag, or the listing proves nothing. Well-formed rows for other tags
// are the caller's to ignore.
function requireReleaseRows(listing) {
  if (!Array.isArray(listing)) fail("releases listing must be an array");
  listing.forEach((item, index) => {
    if (!Array.isArray(item) && !isPlainObject(item)) {
      fail(`releases listing entry ${index} is malformed (${String(item)}); refusing to treat it as evidence`);
    }
  });
  const releases = normalizeReleasePages(listing);
  releases.forEach((release, index) => {
    if (!isPlainObject(release) || typeof release.tag_name !== "string") {
      fail(`releases listing entry ${index} is malformed (${isPlainObject(release) ? "no tag_name string" : String(release)}); refusing to treat it as evidence`);
    }
  });
  return releases;
}

// No Git ref and no release of any state, including drafts, may already use
// the intended tag. Collisions are refused, never reused or removed. A
// malformed row in either listing is not evidence of absence and fails.
export async function requireTagAbsent(api, tag) {
  const refs = await api("GET", `${HARBOR_API_PREFIX}git/matching-refs/tags/${encodeURIComponent(tag)}`);
  if (!Array.isArray(refs)) fail("matching-refs did not return a list");
  refs.forEach((ref, index) => {
    if (!isPlainObject(ref) || typeof ref.ref !== "string") fail(`matching-refs entry ${index} is malformed; refusing to treat it as evidence that refs/tags/${tag} is absent`);
    if (ref.ref === `refs/tags/${tag}`) fail(`ref refs/tags/${tag} already exists at ${ref.object?.sha ?? "?"}; refusing to reuse it`);
  });
  const releases = requireReleaseRows(await api("GET", `${HARBOR_API_PREFIX}releases?per_page=100`, { paginate: true }));
  for (const release of releases) {
    if (release.tag_name !== tag) continue;
    const state = release.draft === true ? "draft" : "published";
    fail(`${state} release ${release.id} already uses tag ${tag}; refusing to reuse, edit, or replace it`);
  }
}

// Peels the Harbor tag to the commit it names.
export async function resolveHarborTagCommit(api, tag) {
  const ref = await api("GET", tagRefEndpoint(tag));
  if (!isPlainObject(ref) || ref.ref !== `refs/tags/${tag}` || !isPlainObject(ref.object)) fail(`tag ${tag}: ref lookup did not return exactly refs/tags/${tag}`);
  let object = ref.object;
  const seen = new Set();
  for (let depth = 0; ; depth += 1) {
    if (typeof object.sha !== "string" || !COMMIT_RE.test(object.sha)) fail(`tag ${tag}: object sha is not a full lowercase SHA-1`);
    if (object.type === "commit") return object.sha;
    if (object.type !== "tag") fail(`tag ${tag}: points at a ${String(object.type)} object, not a commit`);
    if (seen.has(object.sha) || depth >= MAX_TAG_DEPTH) fail(`tag ${tag}: tag object chain cycles or is too deep`);
    seen.add(object.sha);
    const tagObject = await api("GET", `${HARBOR_API_PREFIX}git/tags/${object.sha}`);
    if (!isPlainObject(tagObject) || tagObject.sha !== object.sha || !isPlainObject(tagObject.object)) fail(`tag ${tag}: tag object lookup returned a different object`);
    object = tagObject.object;
  }
}

// --- prior release --------------------------------------------------------------------

function releaseUrl(id) {
  return `${HARBOR_RELEASE_URL_PREFIX}${id}`;
}

function assetUrl(id) {
  return `${HARBOR_RELEASE_URL_PREFIX}assets/${id}`;
}

function isPublicationTime(value) {
  return typeof value === "string" && PUBLISHED_AT_RE.test(value) && !Number.isNaN(Date.parse(value));
}

// Published (non-draft) prereleases whose tag is exactly the managed grammar
// are candidates. Deliberately ignored, and only when well-formed: drafts,
// stable releases, tags outside the grammar, and explicitly unpublished
// entries (`published_at: null`). Anything else malformed on a managed tag
// (a non-boolean state flag, a non-time publication field), a candidate that
// is not immutable, or two candidates with one version anywhere in the
// listing fail closed. Returns the maximum version's release or null,
// independent of listing order and page boundaries.
export function selectPriorRelease(listing) {
  const candidates = [];
  const seenVersions = new Map();
  for (const entry of requireReleaseRows(listing)) {
    const releaseVersion = managedVersionOfTag(entry.tag_name);
    if (releaseVersion === null) continue;
    const label = `release ${JSON.stringify(entry.id)} (${entry.tag_name})`;
    if (typeof entry.draft !== "boolean" || typeof entry.prerelease !== "boolean") fail(`${label} is malformed: draft and prerelease must be booleans`);
    if (entry.draft || !entry.prerelease) continue;
    if (entry.published_at === null) continue;
    if (!isPublicationTime(entry.published_at)) fail(`${label} is malformed: published_at ${JSON.stringify(entry.published_at)} is not a publication time`);
    if (!isReleaseId(entry.id)) fail(`release ${entry.tag_name} has an invalid id ${JSON.stringify(entry.id)}`);
    if (entry.immutable !== true) fail(`release ${entry.id} (${entry.tag_name}) is not immutable; every managed release must be immutable`);
    const earlier = seenVersions.get(releaseVersion);
    if (earlier !== undefined) fail(`releases ${earlier} and ${entry.id} both publish ${releaseVersion}`);
    seenVersions.set(releaseVersion, entry.id);
    candidates.push({ releaseId: entry.id, tag: entry.tag_name, releaseVersion, publishedAt: entry.published_at });
  }
  if (candidates.length === 0) return null;
  let best = candidates[0];
  for (const candidate of candidates.slice(1)) {
    const order = compareExactVersions(candidate.releaseVersion, best.releaseVersion);
    if (order === 0) fail(`releases ${best.releaseId} and ${candidate.releaseId} both publish ${candidate.releaseVersion}`);
    if (order > 0) best = candidate;
  }
  return best;
}

function requireHarborRelease(release, id, label) {
  if (!isPlainObject(release) || release.id !== id) fail(`${label}: release ${id} was not returned by id`);
  if (release.url !== releaseUrl(id)) fail(`${label}: release ${id} does not belong to repository ${HARBOR_REPOSITORY}`);
  if (!Array.isArray(release.assets)) fail(`${label}: release ${id} has no asset list`);
  return release;
}

function parseDigest(asset, label) {
  if (asset.digest === undefined || asset.digest === null) return null;
  const match = typeof asset.digest === "string" ? /^sha256:([0-9a-f]{64})$/.exec(asset.digest) : null;
  if (match === null) fail(`${label}: asset ${asset.name} has an unrecognized digest ${JSON.stringify(asset.digest)}`);
  return match[1];
}

async function downloadAssetBytes(api, asset, label) {
  if (!isReleaseId(asset.id)) fail(`${label}: asset ${asset.name} has an invalid id`);
  if (asset.url !== assetUrl(asset.id)) fail(`${label}: asset ${asset.name} does not belong to repository ${HARBOR_REPOSITORY}`);
  const bytes = await api("GET", `${HARBOR_API_PREFIX}releases/assets/${asset.id}`, { raw: true });
  if (!Buffer.isBuffer(bytes)) fail(`${label}: asset ${asset.name} download returned no bytes`);
  return bytes;
}

// Re-reads the selected release by id and downloads its unique manifest by
// numeric asset id. The reread must still carry the exact publication
// identity that made it the prior (tag, state, immutability, publication
// time) and a well-formed manifest asset with a positive size that matches
// the downloaded bytes. The manifest must name exactly the tag's version.
export async function fetchPriorManifest(api, prior) {
  const label = `prior release ${prior.releaseId}`;
  const release = requireHarborRelease(await api("GET", `${HARBOR_API_PREFIX}releases/${prior.releaseId}`), prior.releaseId, label);
  if (release.tag_name !== prior.tag || release.draft !== false || release.prerelease !== true || release.immutable !== true) {
    fail(`${label} is no longer the published immutable prerelease ${prior.tag}${release.immutable !== true ? " (not immutable)" : ""}`);
  }
  if (!isPublicationTime(release.published_at) || release.published_at !== prior.publishedAt) {
    fail(`${label}: publication time ${JSON.stringify(release.published_at)} is not the listed ${prior.publishedAt}; the release changed between listing and reread`);
  }
  if (!release.assets.every(isPlainObject)) fail(`${label}: malformed asset list`);
  const manifests = release.assets.filter((asset) => asset.name === MANIFEST_FILE);
  if (manifests.length !== 1) fail(`${label} must carry exactly one ${MANIFEST_FILE} asset, found ${manifests.length}`);
  const [asset] = manifests;
  if (!Number.isSafeInteger(asset.size) || asset.size < 1) fail(`${label}: ${MANIFEST_FILE} size ${JSON.stringify(asset.size)} is not a positive integer`);
  const bytes = await downloadAssetBytes(api, asset, label);
  const actual = createHash("sha256").update(bytes).digest("hex");
  const digest = parseDigest(asset, label);
  if (digest !== null && digest !== actual) fail(`${label}: ${MANIFEST_FILE} digest does not match the downloaded bytes`);
  if (asset.size !== bytes.length) fail(`${label}: ${MANIFEST_FILE} size ${asset.size} does not match the downloaded ${bytes.length} bytes`);
  const text = bytes.toString("utf8");
  const { manifest } = parseManifestText(text, `${label} ${MANIFEST_FILE}`);
  if (manifest.releaseVersion !== prior.releaseVersion) {
    fail(`${label}: manifest releaseVersion ${manifest.releaseVersion} does not equal its tag's ${prior.releaseVersion}`);
  }
  if (manifest.builderRevision === undefined) fail(`${label}: manifest has no builderRevision`);
  return { manifest, text };
}

export async function findPriorRelease({ api }) {
  const prior = selectPriorRelease(await api("GET", `${HARBOR_API_PREFIX}releases?per_page=100`, { paginate: true }));
  if (prior === null) return null;
  const { manifest, text } = await fetchPriorManifest(api, prior);
  return { prior, manifest, text };
}

// --- assembly ---------------------------------------------------------------------------

async function regularEntries(dir, label) {
  let names;
  try {
    names = (await readdir(dir)).sort();
  } catch (error) {
    if (error.code === "ENOENT") fail(`${label}: build row directory is missing`);
    throw error;
  }
  for (const name of names) {
    const stats = await lstat(path.join(dir, name));
    if (stats.isSymbolicLink()) fail(`${label}: ${name} is a symbolic link`);
    if (!stats.isFile()) fail(`${label}: ${name} is not a regular file`);
  }
  return names;
}

// Each expected row directory must hold exactly one inventory JSON and one
// archive in the expected format, and the inventory must name that archive
// and its own artifact id. Archives are copied, never opened.
export async function assembleBuilds({ buildsDir, artifactsDir, inventoryOutput }) {
  const records = [];
  const copies = [];
  for (const expected of EXPECTED_ARTIFACTS) {
    const label = `build row ${expected.id}`;
    const rowDir = path.join(buildsDir, `${BUILD_ARTIFACT_PREFIX}${expected.id}`);
    const names = await regularEntries(rowDir, label);
    const inventories = names.filter((name) => name.endsWith(".inventory.json"));
    const archives = names.filter((name) => name.endsWith(`.${expected.format}`) && !name.endsWith(".inventory.json"));
    if (inventories.length !== 1 || archives.length !== 1 || names.length !== 2) {
      fail(`${label}: expected exactly one *.inventory.json and one *.${expected.format}, found ${names.join(", ") || "(nothing)"}`);
    }
    let record;
    try {
      record = JSON.parse(await readFile(path.join(rowDir, inventories[0]), "utf8"));
    } catch (error) {
      fail(`${label}: cannot parse ${inventories[0]}: ${error.message}`);
    }
    if (!isPlainObject(record)) fail(`${label}: inventory must be a JSON object`);
    if (record.id !== expected.id) fail(`${label}: inventory names artifact ${JSON.stringify(record.id)}, expected ${expected.id}`);
    if (record.file !== archives[0]) fail(`${label}: inventory file ${JSON.stringify(record.file)} is not the row's archive ${archives[0]}`);
    validateAssetName(record.file, label);
    records.push(record);
    copies.push({ from: path.join(rowDir, archives[0]), to: path.join(artifactsDir, archives[0]) });
  }
  await mkdir(path.dirname(artifactsDir), { recursive: true });
  try {
    await mkdir(artifactsDir);
  } catch (error) {
    if (error.code === "EEXIST") fail(`artifact directory ${artifactsDir} already exists; it must be new`);
    throw error;
  }
  for (const copy of copies) await copyFile(copy.from, copy.to, fsConstants.COPYFILE_EXCL);
  await writeNew(inventoryOutput, canonicalJson(records), "inventory");
  return records;
}

// --- publication ----------------------------------------------------------------------------

function uploadEndpoint(releaseId, name) {
  return `${HARBOR_UPLOAD_PREFIX}${releaseId}/assets?name=${encodeURIComponent(name)}`;
}

async function createDraft(api, { tag, builderRevision, manifest }) {
  const body = {
    tag_name: tag,
    target_commitish: builderRevision,
    name: tag,
    body:
      `Managed T3 release ${manifest.releaseVersion}: upstream ${manifest.upstreamVersion} at ` +
      `${manifest.upstreamCommit}, built by ${HARBOR_REPOSITORY}@${builderRevision}. ` +
      "Immutable; verify assets against SHA256SUMS and managed-release.json.",
    draft: true,
    prerelease: true,
    make_latest: "false",
  };
  const release = await api("POST", `${HARBOR_API_PREFIX}releases`, { body });
  if (!isPlainObject(release) || !isReleaseId(release.id)) fail("release creation did not return an id");
  const id = release.id;
  requireHarborRelease(release, id, "created draft");
  if (release.tag_name !== tag) fail(`created draft ${id} carries tag ${release.tag_name}, expected ${tag}`);
  if (release.draft !== true || release.prerelease !== true) fail(`created release ${id} is not a draft prerelease`);
  if (release.target_commitish !== builderRevision) fail(`created draft ${id} targets ${release.target_commitish}, expected ${builderRevision}`);
  return id;
}

async function uploadAssets(api, releaseId, files) {
  const uploaded = [];
  for (const file of files) {
    const asset = await api("POST", uploadEndpoint(releaseId, file.name), { inputFile: file.path, contentType: file.contentType });
    if (!isPlainObject(asset) || asset.name !== file.name) fail(`upload of ${file.name} returned a different asset`);
    if (!isReleaseId(asset.id)) fail(`upload of ${file.name} returned an invalid asset id`);
    if (asset.size !== file.bytes) fail(`upload of ${file.name} reports size ${asset.size}, expected ${file.bytes}`);
    if (asset.state !== "uploaded") fail(`upload of ${file.name} is in state ${asset.state}`);
    uploaded.push({ name: file.name, id: asset.id, size: asset.size });
  }
  return uploaded;
}

// Exactly the six expected asset names, each with the expected size and
// state, and each digest equal to the local bytes: from the API's digest
// when it reports one, otherwise from the bytes downloaded by asset id. After
// publication `known` carries the identities already proven on the draft, so
// an omitted digest is checked against that proof (same id, same size) rather
// than downloaded a second time; the release is immutable by then.
async function verifyRemoteAssets(api, release, files, label, known = null) {
  const assets = release.assets;
  if (!assets.every(isPlainObject)) fail(`${label}: malformed asset list`);
  const names = assets.map((asset) => asset.name);
  const expected = files.map((file) => file.name);
  if (new Set(names).size !== names.length) fail(`${label}: duplicate asset names ${names.join(", ")}`);
  const missing = expected.filter((name) => !names.includes(name));
  const extra = names.filter((name) => !expected.includes(name));
  if (missing.length > 0) fail(`${label}: asset(s) ${missing.join(", ")} are missing`);
  if (extra.length > 0) fail(`${label}: unexpected asset(s) ${extra.join(", ")}; only the six feed files may be published`);
  const verified = [];
  for (const file of files) {
    const asset = assets.find((candidate) => candidate.name === file.name);
    if (!isReleaseId(asset.id)) fail(`${label}: asset ${file.name} has an invalid id`);
    if (asset.state !== "uploaded") fail(`${label}: asset ${file.name} is in state ${asset.state}, not uploaded`);
    if (asset.size !== file.bytes) fail(`${label}: asset ${file.name} size ${asset.size} differs from the local ${file.bytes} bytes`);
    let sha256 = parseDigest(asset, label);
    const proven = known === null ? undefined : known.find((entry) => entry.name === file.name);
    if (sha256 === null && proven !== undefined && proven.id === asset.id && proven.size === asset.size) {
      sha256 = proven.sha256;
    }
    if (sha256 === null) {
      const bytes = await downloadAssetBytes(api, asset, label);
      if (bytes.length !== file.bytes) fail(`${label}: asset ${file.name} downloaded ${bytes.length} bytes, expected ${file.bytes}`);
      sha256 = createHash("sha256").update(bytes).digest("hex");
    }
    if (sha256 !== file.sha256) fail(`${label}: asset ${file.name} sha256 ${sha256} differs from the local ${file.sha256}`);
    verified.push({ name: file.name, id: asset.id, size: asset.size, sha256 });
  }
  return verified;
}

async function readRelease(api, id, label) {
  return requireHarborRelease(await api("GET", `${HARBOR_API_PREFIX}releases/${id}`), id, label);
}

function requireReleaseIdentity(release, { tag, builderRevision }, label) {
  if (release.tag_name !== tag) fail(`${label}: tag is ${release.tag_name}, expected ${tag}`);
  if (release.target_commitish !== builderRevision) fail(`${label}: target commit is ${release.target_commitish}, expected ${builderRevision}`);
  if (release.prerelease !== true) fail(`${label}: release is not a prerelease`);
}

async function verifyDraft(api, id, { tag, builderRevision, files }) {
  const label = `draft ${id}`;
  const release = await readRelease(api, id, label);
  if (release.draft !== true) fail(`${label}: release is no longer a draft; refusing to touch a release this run did not just create`);
  requireReleaseIdentity(release, { tag, builderRevision }, label);
  return verifyRemoteAssets(api, release, files, label);
}

// The one visible mutation. It is sent exactly once: if the response is lost
// or malformed the release may already be public, so the failure names the
// id for manual inspection and nothing retries, reuses, or removes it.
async function publishDraft(api, id) {
  let release;
  try {
    release = await api("PATCH", `${HARBOR_API_PREFIX}releases/${id}`, { body: { draft: false } });
  } catch (error) {
    if (!(error instanceof PublishError)) throw error;
    fail(`the publish call for release ${id} failed and its status is uncertain (the release may already be public; inspect release ${id} by id and never reuse its tag): ${error.message}`);
  }
  if (!isPlainObject(release) || release.id !== id) fail(`publishing release ${id} did not return it; its status is uncertain and it may already be public, inspect release ${id} by id`);
  if (release.draft !== false) fail(`release ${id} is still a draft after the publish call; its status is uncertain, inspect release ${id} by id`);
}

async function verifyPublished(api, id, { tag, builderRevision, files, uploaded }) {
  const label = `published release ${id}`;
  const release = await readRelease(api, id, label);
  if (release.draft !== false) fail(`${label}: draft is not false`);
  requireReleaseIdentity(release, { tag, builderRevision }, label);
  if (typeof release.published_at !== "string" || !PUBLISHED_AT_RE.test(release.published_at) || Number.isNaN(Date.parse(release.published_at))) {
    fail(`${label}: published_at is not a publication time`);
  }
  if (release.immutable !== true) fail(`${label}: the API does not report immutable: true; the release is not protected`);
  const assets = await verifyRemoteAssets(api, release, files, label, uploaded);
  assets.forEach((asset, index) => {
    const before = uploaded[index];
    if (asset.id !== before.id || asset.size !== before.size || asset.sha256 !== before.sha256) {
      fail(`${label}: asset ${asset.name} changed between verification and publication`);
    }
  });
  const byTag = await api("GET", `${HARBOR_API_PREFIX}releases/tags/${encodeURIComponent(tag)}`);
  if (!isPlainObject(byTag) || byTag.id !== id) fail(`releases/tags/${tag} names release ${byTag?.id}, expected ${id}`);
  const tagCommit = await resolveHarborTagCommit(api, tag);
  if (tagCommit !== builderRevision) fail(`tag ${tag} resolves to ${tagCommit}, expected the builder commit ${builderRevision}`);
  return { release, assets, tagCommit };
}

// Proves the local closure, repeats every trust check, and publishes once.
// Nothing is deleted, edited, forced, or reused at any point. A failure
// before the publish call leaves the draft where it is and reports; a
// failure at or after the publish call reports the release id, because the
// release may by then be public and only a person may decide what follows.
export async function publishManagedRelease({ releaseDir, repository, ref, builderRevision, upstreamRecord, lock = null, api, upstreamApi, readImmutableSetting }) {
  const closure = await readReleaseClosure(releaseDir);
  const { manifest, tag, files } = closure;
  requireTrustedContext({ repository, ref, builderRevision, manifest });
  await verifyUpstreamRelease({ record: upstreamRecord, lock, manifest, upstreamApi });
  await requireImmutableReleasesEnabled(readImmutableSetting);
  await requireTagAbsent(api, tag);

  const releaseId = await createDraft(api, { tag, builderRevision, manifest });
  await uploadAssets(api, releaseId, files);
  const uploaded = await verifyDraft(api, releaseId, { tag, builderRevision, files });
  await publishDraft(api, releaseId);
  const { release, assets, tagCommit } = await verifyPublished(api, releaseId, { tag, builderRevision, files, uploaded });
  return {
    releaseId,
    tag,
    releaseVersion: manifest.releaseVersion,
    htmlUrl: typeof release.html_url === "string" ? release.html_url : "",
    publishedAt: release.published_at,
    immutable: release.immutable === true,
    tagCommit,
    assets,
  };
}

// --- CLI -----------------------------------------------------------------------------------

const COMMANDS = {
  "public-config": { flags: ["--output", "--github-output"], required: ["--output"] },
  "verify-upstream": { flags: ["--lock", "--upstream-release"], required: ["--lock", "--upstream-release"] },
  prior: { flags: ["--output", "--github-output"], required: ["--output"] },
  preflight: { flags: ["--release-version", "--github-output"], required: ["--release-version"] },
  assemble: { flags: ["--builds", "--artifacts", "--inventory"], required: ["--builds", "--artifacts", "--inventory"] },
  publish: {
    flags: ["--release-dir", "--lock", "--upstream-release", "--repository", "--ref", "--builder-revision", "--github-output"],
    required: ["--release-dir", "--lock", "--upstream-release", "--repository", "--ref", "--builder-revision"],
  },
};
const VALUE_FLAGS = ["--release-version", "--repository", "--ref", "--builder-revision"];

export function parseArgs(argv) {
  const [command, ...rest] = argv;
  if (command === undefined) fail(`a subcommand is required: ${Object.keys(COMMANDS).join(", ")}`);
  const spec = COMMANDS[command];
  if (spec === undefined) fail(`unknown subcommand ${command}; expected one of ${Object.keys(COMMANDS).join(", ")}`);
  const options = {};
  const seen = new Set();
  for (let i = 0; i < rest.length; i += 1) {
    const flag = rest[i];
    const value = rest[i + 1];
    if (!spec.flags.includes(flag)) fail(`unknown argument ${flag} for ${command}; expected one of ${spec.flags.join(", ")}`);
    if (value === undefined || value.startsWith("-")) fail(`${flag} requires a value`);
    if (seen.has(flag)) fail(`${flag} given more than once`);
    seen.add(flag);
    const key = flag.slice(2).replace(/-([a-z])/g, (_, c) => c.toUpperCase());
    options[key] = VALUE_FLAGS.includes(flag) ? value : path.resolve(value);
    i += 1;
  }
  for (const flag of spec.required) {
    if (!seen.has(flag)) fail(`${flag} is required for ${command}`);
  }
  return { command, options };
}

async function readJson(file, label) {
  try {
    return JSON.parse(await readFile(file, "utf8"));
  } catch (error) {
    fail(`cannot read ${label} ${file}: ${error.message}`);
  }
}

async function emitOutputs(githubOutput, lines) {
  if (githubOutput === undefined) return;
  await appendFile(githubOutput, lines.map((line) => `${line}\n`).join(""));
}

async function summary(text) {
  if (process.env.GITHUB_STEP_SUMMARY) await appendFile(process.env.GITHUB_STEP_SUMMARY, text);
}

// Takes the administration-read token out of this process's environment so
// only the closed setting reader ever hands it to a child, and only as
// GH_TOKEN. Fatal when absent: the setting check cannot be skipped.
function takeAdminReadToken(env = process.env) {
  const token = env[ADMIN_READ_TOKEN_ENV];
  delete env[ADMIN_READ_TOKEN_ENV];
  if (typeof token !== "string" || token.trim() === "") {
    fail(`${ADMIN_READ_TOKEN_ENV} is not set; the immutable-releases setting check needs a separate repository Administration read token`);
  }
  return token;
}

export async function main(argv) {
  const { command, options } = parseArgs(argv);
  const log = (message) => console.log(`publish-managed-release: ${message}`);
  switch (command) {
    case "public-config": {
      const { sha256 } = await writePublicConfig({ output: options.output });
      await emitOutputs(options.githubOutput, [`public_config_sha256=${sha256}`]);
      log(`wrote the ${PUBLIC_CONFIG_KEYS.length}-key public config (fingerprint ${sha256})`);
      return;
    }
    case "verify-upstream": {
      const lock = await readVerifiedLock(options.lock);
      const record = await readJson(options.upstreamRelease, "upstream release record");
      const provenance = await verifyUpstreamRelease({ record, lock, upstreamApi: createUpstreamApi() });
      log(`upstream ${provenance.tag} (release ${provenance.releaseId}) still names ${provenance.commit}`);
      return;
    }
    case "prior": {
      const found = await findPriorRelease({ api: createHarborApi() });
      if (found === null) {
        await emitOutputs(options.githubOutput, ["prior_tag=", "prior_manifest="]);
        await summary(`- prior release: none published yet\n`);
        log("no published immutable managed release exists; the resolver runs without --prior-release");
        return;
      }
      await writeNew(options.output, found.text, "prior manifest");
      await emitOutputs(options.githubOutput, [`prior_tag=${found.prior.tag}`, `prior_manifest=${options.output}`]);
      await summary(`- prior release: \`${found.prior.tag}\` (release ${found.prior.releaseId})\n`);
      log(`prior release ${found.prior.tag} (release ${found.prior.releaseId}) manifest written to ${options.output}`);
      return;
    }
    case "preflight": {
      const tag = releaseTag(options.releaseVersion);
      const readImmutableSetting = createImmutableSettingsReader({ token: takeAdminReadToken() });
      const api = createHarborApi();
      await requireImmutableReleasesEnabled(readImmutableSetting);
      await requireTagAbsent(api, tag);
      await emitOutputs(options.githubOutput, [`release_tag=${tag}`]);
      log(`immutable releases are enabled and ${tag} is unused`);
      return;
    }
    case "assemble": {
      const records = await assembleBuilds({ buildsDir: options.builds, artifactsDir: options.artifacts, inventoryOutput: options.inventory });
      log(`assembled ${records.length} artifacts into ${options.artifacts} with inventory ${options.inventory}`);
      return;
    }
    case "publish": {
      const readImmutableSetting = createImmutableSettingsReader({ token: takeAdminReadToken() });
      const lock = await readVerifiedLock(options.lock);
      const record = await readJson(options.upstreamRelease, "upstream release record");
      const result = await publishManagedRelease({
        releaseDir: options.releaseDir,
        repository: options.repository,
        ref: options.ref,
        builderRevision: options.builderRevision,
        upstreamRecord: record,
        lock,
        api: createHarborApi(),
        upstreamApi: createUpstreamApi(),
        readImmutableSetting,
      });
      await emitOutputs(options.githubOutput, [
        `release_id=${result.releaseId}`,
        `release_tag=${result.tag}`,
        `release_version=${result.releaseVersion}`,
        `release_url=${result.htmlUrl}`,
        `tag_commit=${result.tagCommit}`,
      ]);
      await summary(
        `## t3 managed release\n\n- published \`${result.tag}\` (release ${result.releaseId}, immutable) at \`${result.tagCommit}\`\n` +
          result.assets.map((asset) => `- \`${asset.name}\` (${asset.size} bytes, sha256 \`${asset.sha256}\`)\n`).join(""),
      );
      log(`published ${result.tag} as immutable release ${result.releaseId} with ${result.assets.length} assets`);
      return;
    }
    default:
      fail(`unknown subcommand ${command}`);
  }
}

if (isEntryPoint(import.meta)) {
  main(process.argv.slice(2)).catch((error) => {
    const expected = error instanceof PublishError || error instanceof ReleaseError || error instanceof DiscoveryError;
    console.error(`publish-managed-release: ${expected ? error.message : error.stack || String(error)}`);
    process.exit(1);
  });
}
