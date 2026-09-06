#!/usr/bin/env node
// Discover the newest published upstream T3 Nightly and prove, locally, that
// Harbor's patch catalog still materializes on it. The proof is the real
// preparer (`prepare-source.mjs`) run twice, once per variant, against a
// candidate lock whose only changed field is the commit; the result is a new
// destination directory holding a result report and, when both variants
// applied cleanly, the candidate lock, the tracked provenance record for the
// selected release, and the verified patch listing a future PR would carry.
//
// Boundaries, enforced here rather than promised:
//
// - Read-only GitHub access through `gh api` with argv, never a shell string.
//   Endpoints are built from the fixed upstream `pingdotgg/t3code`; no API
//   response chooses a repository or a command. The token gh uses is never
//   inspected, printed, or written.
// - The checked-out lock, current provenance, and patches are read, never
//   written. The destination must be new; it is staged next to itself and
//   renamed into place only once complete, so a failure publishes nothing.
// - Every patch checksum and the two-variant closure are verified before any
//   network call. Same-version mutations (a published Nightly re-pointed at a
//   different commit, or re-published under a new release id) are refused,
//   never silently repinned.
// - Only Git and the preparer run; no dependency install, no package script,
//   no candidate code executes. Nothing pushes, opens a PR, or publishes.
//
// Exit codes: 0 for `ready` and `unchanged`, 2 for a normal patch `conflict`
// (a result report is still written), 1 for any other error.
// Dependency-free: Node built-ins, `git`, and `gh` only.
import { execFile } from "node:child_process";
import { copyFile, lstat, mkdir, mkdtemp, readFile, realpath, rename, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import {
  COMMIT_RE,
  MANAGED_NIGHTLY_VARIANT,
  REASONING_VARIANT,
  REQUIRED_VARIANTS,
  ReleaseError,
  UPSTREAM_NIGHTLY_RE,
  compareExactVersions,
  isEntryPoint,
  parseUpstreamNightlyVersion,
  readVerifiedLock,
  resolveReleaseVariants,
} from "./resolve-managed-release.mjs";

export const UPSTREAM_REPOSITORY = "https://github.com/pingdotgg/t3code.git";
export const UPSTREAM_OWNER_REPO = "pingdotgg/t3code";
export const API_PREFIX = `/repos/${UPSTREAM_OWNER_REPO}/`;
export const PROVENANCE_SCHEMA_VERSION = 1;
export const RESULT_SCHEMA_VERSION = 1;
export const RESULT_FILE = "result.json";
export const LOCK_FILE = "source.lock.json";
export const PROVENANCE_FILE = "upstream-release.json";
export const PATCH_CHECK_FILE = "patch-check.json";
export const EXIT_CONFLICT = 2;
// Annotated tags may point at annotated tags; a real chain is one or two deep.
const MAX_TAG_DEPTH = 8;
const DIAGNOSTIC_LINES = 12;
const DIAGNOSTIC_LINE_LENGTH = 400;
const PUBLISHED_AT_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/;

const componentDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const PREPARER_SCRIPT = path.join(componentDir, "scripts", "prepare-source.mjs");
const execFileAsync = promisify(execFile);

export class DiscoveryError extends Error {}

function fail(message) {
  throw new DiscoveryError(message);
}

function isPlainObject(value) {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function boundedLines(text) {
  return String(text ?? "")
    .trim()
    .split("\n")
    .slice(-DIAGNOSTIC_LINES)
    .map((line) => (line.length > DIAGNOSTIC_LINE_LENGTH ? `${line.slice(0, DIAGNOSTIC_LINE_LENGTH)}...` : line));
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

function jsonText(value) {
  return `${JSON.stringify(value, null, 2)}\n`;
}

// --- command runner and GitHub API --------------------------------------------

// The default runner: argv only, no shell. Rejections carry execFile's
// `stderr` and `code`, which the preparer classification below reads.
export async function defaultRun(command, args, { cwd, env } = {}) {
  return execFileAsync(command, args, {
    cwd,
    env: { ...process.env, ...env },
    maxBuffer: 64 * 1024 * 1024,
  });
}

// A read-only API function over `gh api`. `paginate` requests every page and
// slurps them into one array of pages. Only the fixed upstream repository's
// endpoints are accepted; anything else is a programming error, not a request.
export function createGhApi(run = defaultRun) {
  return async function api(endpoint, { paginate = false } = {}) {
    if (typeof endpoint !== "string" || !endpoint.startsWith(API_PREFIX)) {
      fail(`refusing API endpoint ${String(endpoint)}: only ${API_PREFIX}* is allowed`);
    }
    const args = ["api", "--method", "GET", ...(paginate ? ["--paginate", "--slurp"] : []), endpoint];
    let stdout;
    try {
      ({ stdout } = await run("gh", args, { env: { GH_PROMPT_DISABLED: "1", GH_NO_UPDATE_NOTIFIER: "1" } }));
    } catch (error) {
      fail(`gh api ${endpoint} failed: ${boundedLines(error.stderr || error.message).join(" ")}`);
    }
    try {
      return JSON.parse(stdout);
    } catch {
      fail(`gh api ${endpoint} returned invalid JSON`);
    }
  };
}

// --- provenance record --------------------------------------------------------

// The tracked `upstream-release.json` record. Field order is fixed so the file
// diffs cleanly across PRs.
export function validateProvenance(record, label = "current release") {
  if (!isPlainObject(record)) fail(`${label}: must be a JSON object`);
  if (record.schemaVersion !== PROVENANCE_SCHEMA_VERSION) {
    fail(`${label}: schemaVersion must be ${PROVENANCE_SCHEMA_VERSION}, found ${JSON.stringify(record.schemaVersion)}`);
  }
  if (record.repository !== UPSTREAM_OWNER_REPO) {
    fail(`${label}: repository must be ${UPSTREAM_OWNER_REPO}, found ${JSON.stringify(record.repository)}`);
  }
  if (!Number.isSafeInteger(record.releaseId) || record.releaseId < 1) {
    fail(`${label}: releaseId must be a positive integer`);
  }
  try {
    parseUpstreamNightlyVersion(record.version);
  } catch (error) {
    fail(`${label}: ${error.message}`);
  }
  if (record.tag !== `v${record.version}`) {
    fail(`${label}: tag ${JSON.stringify(record.tag)} must be v${record.version}`);
  }
  if (typeof record.commit !== "string" || !COMMIT_RE.test(record.commit)) {
    fail(`${label}: commit must be a full 40-character lowercase SHA-1`);
  }
  if (typeof record.publishedAt !== "string" || !PUBLISHED_AT_RE.test(record.publishedAt) || Number.isNaN(Date.parse(record.publishedAt))) {
    fail(`${label}: publishedAt must be an ISO-8601 UTC timestamp`);
  }
  return {
    schemaVersion: PROVENANCE_SCHEMA_VERSION,
    repository: UPSTREAM_OWNER_REPO,
    releaseId: record.releaseId,
    tag: record.tag,
    version: record.version,
    commit: record.commit,
    publishedAt: record.publishedAt,
  };
}

export function formatProvenance(release, commit) {
  return validateProvenance({
    schemaVersion: PROVENANCE_SCHEMA_VERSION,
    repository: UPSTREAM_OWNER_REPO,
    releaseId: release.releaseId,
    tag: release.tag,
    version: release.version,
    commit,
    publishedAt: release.publishedAt,
  }, "candidate provenance");
}

// --- release selection --------------------------------------------------------

// `gh api --paginate --slurp` yields an array of pages; a plain list of
// releases is accepted too. Anything else is not a releases listing.
export function normalizeReleasePages(pages) {
  if (!Array.isArray(pages)) fail("releases listing must be an array");
  if (pages.every(Array.isArray)) return pages.flat();
  if (pages.every(isPlainObject)) return pages;
  fail("releases listing mixes pages and entries");
}

// A published (non-draft) prerelease with a real publication time whose tag
// is `v` plus the exact ordinary Nightly grammar; anything else is ignored.
export function normalizeRelease(entry) {
  if (!isPlainObject(entry)) return null;
  if (entry.draft !== false || entry.prerelease !== true) return null;
  if (typeof entry.published_at !== "string" || !PUBLISHED_AT_RE.test(entry.published_at)) return null;
  if (Number.isNaN(Date.parse(entry.published_at))) return null;
  if (typeof entry.tag_name !== "string" || !entry.tag_name.startsWith("v")) return null;
  const version = entry.tag_name.slice(1);
  if (!UPSTREAM_NIGHTLY_RE.test(version)) return null;
  if (!Number.isSafeInteger(entry.id) || entry.id < 1) {
    fail(`release ${entry.tag_name} has an invalid id ${JSON.stringify(entry.id)}`);
  }
  return {
    repository: UPSTREAM_OWNER_REPO,
    releaseId: entry.id,
    tag: entry.tag_name,
    version,
    publishedAt: entry.published_at,
  };
}

// Picks the maximum exact version among published Nightlies, independent of
// response order or timestamps. With a current record: a greater version is
// `selected`; an equal version must be the same release (id and publication
// time) and is `unchanged`; an older maximum is `unchanged` too, never a
// fallback. Returns `{ status, candidate | latest, current }`.
export function selectPublishedNightly(releases, current = null) {
  const currentRecord = current === null || current === undefined ? null : validateProvenance(current);
  const candidates = normalizeReleasePages(releases).map(normalizeRelease).filter((r) => r !== null);
  if (candidates.length === 0) fail(`no published upstream Nightly prerelease found in ${UPSTREAM_OWNER_REPO}`);
  let best = candidates[0];
  for (const candidate of candidates.slice(1)) {
    const order = compareExactVersions(candidate.version, best.version);
    if (order === 0) {
      fail(`releases ${best.releaseId} and ${candidate.releaseId} both publish ${candidate.version}`);
    }
    if (order > 0) best = candidate;
  }
  if (currentRecord === null) return { status: "selected", candidate: best, current: null };
  const order = compareExactVersions(best.version, currentRecord.version);
  if (order > 0) return { status: "selected", candidate: best, current: currentRecord };
  if (order === 0 && (best.releaseId !== currentRecord.releaseId || best.publishedAt !== currentRecord.publishedAt)) {
    fail(
      `published Nightly ${best.version} changed identity: current record is release ${currentRecord.releaseId} ` +
        `published ${currentRecord.publishedAt}, upstream now lists release ${best.releaseId} published ` +
        `${best.publishedAt}; same-version changes need review, not repinning`,
    );
  }
  return { status: "unchanged", latest: best, current: currentRecord };
}

// --- tag resolution -----------------------------------------------------------

// Resolves a release tag to the full commit it names, peeling annotated tag
// objects. Missing refs surface as API errors; cycles, over-deep chains, and
// non-commit targets are refused.
export async function resolvePublishedCommit(release, api) {
  const { tag } = release;
  if (typeof tag !== "string" || tag === "") fail("release tag must be a non-empty string");
  const ref = await api(`${API_PREFIX}git/ref/tags/${encodeURIComponent(tag)}`);
  if (!isPlainObject(ref) || ref.ref !== `refs/tags/${tag}` || !isPlainObject(ref.object)) {
    fail(`tag ${tag}: ref lookup did not return exactly refs/tags/${tag}`);
  }
  let object = ref.object;
  const seen = new Set();
  for (let depth = 0; ; depth += 1) {
    if (typeof object.sha !== "string" || !COMMIT_RE.test(object.sha)) {
      fail(`tag ${tag}: object sha ${JSON.stringify(object.sha)} is not a full lowercase SHA-1`);
    }
    if (object.type === "commit") return object.sha;
    if (object.type !== "tag") fail(`tag ${tag}: points at a ${String(object.type)} object ${object.sha}, not a commit`);
    if (seen.has(object.sha)) fail(`tag ${tag}: tag object chain cycles at ${object.sha}`);
    if (depth >= MAX_TAG_DEPTH) fail(`tag ${tag}: tag object chain exceeds ${MAX_TAG_DEPTH} levels`);
    seen.add(object.sha);
    const tagObject = await api(`${API_PREFIX}git/tags/${object.sha}`);
    if (!isPlainObject(tagObject) || tagObject.sha !== object.sha || !isPlainObject(tagObject.object)) {
      fail(`tag ${tag}: tag object ${object.sha} lookup returned a different object`);
    }
    object = tagObject.object;
  }
}

// Re-reads the release by id and its tag; refuses any drift from the values
// the run selected. Same-version mutation is a blocked provenance change.
async function confirmCandidate(api, candidate, commit) {
  const reread = normalizeRelease(await api(`${API_PREFIX}releases/${candidate.releaseId}`));
  if (reread === null) fail(`release ${candidate.releaseId} (${candidate.tag}) is no longer a published Nightly prerelease`);
  for (const key of ["releaseId", "tag", "version", "publishedAt"]) {
    if (reread[key] !== candidate[key]) {
      fail(`release ${candidate.releaseId} moved: ${key} was ${candidate[key]}, now ${reread[key]}`);
    }
  }
  const commitNow = await resolvePublishedCommit(candidate, api);
  if (commitNow !== commit) {
    fail(`tag ${candidate.tag} moved from ${commit} to ${commitNow} during the run; refusing to repin`);
  }
}

// --- inputs -----------------------------------------------------------------------

async function readCurrentRelease(currentReleasePath) {
  if (currentReleasePath === null) return null;
  let text;
  try {
    text = await readFile(currentReleasePath, "utf8");
  } catch (error) {
    if (error.code === "ENOENT") {
      fail(
        `current release ${currentReleasePath} does not exist; omit --current-release only for the ` +
          "initial bootstrap of the tracked provenance record",
      );
    }
    fail(`cannot read current release ${currentReleasePath}: ${error.message}`);
  }
  let record;
  try {
    record = JSON.parse(text);
  } catch (error) {
    fail(`current release ${currentReleasePath} is not valid JSON: ${error.message}`);
  }
  return validateProvenance(record, `current release ${currentReleasePath}`);
}

// The candidate lock is the checked-in text with the one commit literal
// replaced, so a diff shows exactly that line. If the text is not in that
// canonical shape, the parsed lock is re-serialized with the new commit.
export function candidateLockText(lockText, lock, commit) {
  const literal = `"commit": "${lock.commit}"`;
  const first = lockText.indexOf(literal);
  const expected = { ...lock, commit };
  if (first !== -1 && lockText.indexOf(literal, first + 1) === -1) {
    const text = lockText.replace(literal, `"commit": "${commit}"`);
    try {
      if (JSON.stringify(JSON.parse(text)) === JSON.stringify(expected)) return text;
    } catch {
      // fall through to re-serialization
    }
  }
  return jsonText(expected);
}

// --- materialization proof ----------------------------------------------------

// The preparer runs from the private stage and resolves a relative local
// repository against its own cwd, so a relative path must be resolved against
// the caller's cwd here, before the stage exists. Absolute paths, URL
// transports (scheme://...) and SCP-like host:path forms pass through
// untouched, exactly as the preparer's own resolver treats them.
export function resolveRepositoryPath(value) {
  if (value === null || value === undefined) return null;
  if (path.isAbsolute(value) || /^[a-zA-Z][a-zA-Z0-9+.-]*:\/\//.test(value) || /^[^/\\]+:/.test(value)) {
    return value;
  }
  return path.resolve(value);
}

async function gitRun(run, cwd, args, env) {
  try {
    const { stdout } = await run("git", args, { cwd, env: { GIT_TERMINAL_PROMPT: "0", ...env } });
    return stdout;
  } catch (error) {
    fail(`git ${args[0]} in ${cwd} failed: ${boundedLines(error.stderr || error.message).join(" ")}`);
  }
}

// The preparer's machine marker for a patch that `git apply` parsed and
// rejected against the tree: one stderr line, this prefix followed by the
// single-line JSON `{"patch": <path>}`. The preparer prints it only when git
// exited 1 and every error git printed is one of its tree-rejection verdicts
// (a failed hunk, a missing preimage, a file that already exists, ...); a
// corrupt patch, an unreadable preimage, an unwritable tree, a fatal git
// error, or a killed git gets no marker. Every other preparer stderr line
// begins with "prepare-source: ", so no path, lock text, or argument echoed in
// a diagnostic can produce this line, and the human "does not apply cleanly"
// prose is never consulted: a patch path may itself contain those words or
// whitespace. The marker must come from a preparer that exited 1 by its own
// error path; a preparer that died some other way has no verdict.
const PREPARER_CONFLICT_PREFIX = "prepare-source-conflict: ";
const PREPARER_FAILURE_EXIT = 1;

function parsePreparerConflict(line) {
  let record;
  try {
    record = JSON.parse(line.slice(PREPARER_CONFLICT_PREFIX.length));
  } catch {
    return null;
  }
  if (!isPlainObject(record) || typeof record.patch !== "string" || record.patch === "") return null;
  return record;
}

function classifyPreparerFailure(error) {
  if (error?.code !== PREPARER_FAILURE_EXIT) return null;
  const lines = String(error?.stderr ?? "")
    .split("\n")
    .map((line) => line.trimEnd());
  const isMarker = (line) => line.startsWith(PREPARER_CONFLICT_PREFIX);
  const markers = lines.filter(isMarker);
  if (markers.length !== 1) return null;
  const record = parsePreparerConflict(markers[0]);
  if (record === null) return null;
  return { failedPatch: record.patch, diagnostics: boundedLines(lines.filter((line) => !isMarker(line)).join("\n")) };
}

// Runs the real preparer for one variant into a fresh destination. Returns
// `{ ok: true }` or `{ ok: false, conflict }` when the preparer reported a
// patch that does not apply cleanly; any other preparer failure, including a
// malformed patch or an operational git failure, is an error.
async function runPreparer({ run, preparerScript, candidateLock, destination, variant, repository, cwd }) {
  const args = [preparerScript, "--lock", candidateLock, "--destination", destination, "--variant", variant];
  if (repository !== null) args.push("--repository", repository);
  try {
    await run(process.execPath, args, { cwd });
    return { ok: true };
  } catch (error) {
    const conflict = classifyPreparerFailure(error);
    if (conflict !== null) return { ok: false, conflict };
    fail(
      `prepare-source --variant ${variant} failed: ` +
        boundedLines(error?.stderr || error?.message).join(" "),
    );
  }
}

// Records the patch-applied tree through a private index so the checkout's
// own index and HEAD are untouched, and checks the preparer's provenance
// against the lock's variant selection.
async function recordPreparedTree({ run, treeDir, indexFile, variant, commit, expectedPatches }) {
  const env = { GIT_INDEX_FILE: indexFile };
  const head = (await gitRun(run, treeDir, ["rev-parse", "HEAD"], env)).trim();
  if (head !== commit) fail(`prepared ${variant} tree HEAD is ${head}, expected ${commit}`);
  await gitRun(run, treeDir, ["read-tree", "HEAD"], env);
  await gitRun(run, treeDir, ["add", "-A"], env);
  const tree = (await gitRun(run, treeDir, ["write-tree"], env)).trim();
  if (!COMMIT_RE.test(tree)) fail(`prepared ${variant} tree id ${JSON.stringify(tree)} is not a full SHA-1`);

  let provenance;
  try {
    provenance = JSON.parse(await readFile(path.join(treeDir, ".git", "harbor-source.json"), "utf8"));
  } catch (error) {
    fail(`prepared ${variant} tree has no readable provenance: ${error.message}`);
  }
  if (provenance.commit !== commit || provenance.variant !== variant) {
    fail(`prepared ${variant} provenance names ${provenance.variant}@${provenance.commit}, expected ${variant}@${commit}`);
  }
  const recorded = Array.isArray(provenance.patches) ? provenance.patches : [];
  const expectedIds = expectedPatches.map(({ id, sha256 }) => `${id}:${sha256}`);
  const recordedIds = recorded.map(({ id, sha256 }) => `${id}:${sha256}`);
  if (JSON.stringify(recordedIds) !== JSON.stringify(expectedIds)) {
    fail(`prepared ${variant} provenance patches [${recordedIds.join(", ")}] differ from the lock's [${expectedIds.join(", ")}]`);
  }
  return {
    variant,
    destination: treeDir,
    head,
    tree,
    patches: expectedPatches.map(({ id, sha256 }) => ({ id, sha256 })),
  };
}

// --- orchestration ------------------------------------------------------------------

async function publishResult(destination, files) {
  const parent = path.dirname(destination);
  await mkdir(parent, { recursive: true });
  const staging = await mkdtemp(path.join(parent, `.${path.basename(destination)}.staging-`));
  try {
    for (const [name, text] of Object.entries(files)) {
      await writeFile(path.join(staging, name), text, { flag: "wx" });
    }
    if (await exists(destination)) fail(`destination ${destination} appeared during the run; nothing was overwritten`);
    await rename(staging, destination);
  } catch (error) {
    await rm(staging, { recursive: true, force: true });
    throw error;
  }
}

// Discovers, proves, and reports. Returns the result record that is also
// written to `<destination>/result.json`; `status` is `ready`, `unchanged`,
// or `conflict`. Every other outcome throws.
export async function prepareNightlyCandidate({
  lockPath,
  currentReleasePath = null,
  destination,
  repository = null,
  workRoot = tmpdir(),
  run = defaultRun,
  api = createGhApi(run),
  preparerScript = PREPARER_SCRIPT,
  now = () => new Date(),
}) {
  if (typeof lockPath !== "string" || typeof destination !== "string") fail("lockPath and destination are required");
  lockPath = path.resolve(lockPath);
  destination = path.resolve(destination);
  if (currentReleasePath !== null) currentReleasePath = path.resolve(currentReleasePath);
  repository = resolveRepositoryPath(repository);

  // 1. Local verification: lock structure, every patch checksum, two-variant
  //    closure, provenance agreement, and a new destination. No network yet.
  const lockText = await readFile(lockPath, "utf8").catch((error) => fail(`cannot read lock ${lockPath}: ${error.message}`));
  const lock = await readVerifiedLock(lockPath);
  if (lock.repository !== UPSTREAM_REPOSITORY) {
    fail(`lock ${lockPath} pins repository ${lock.repository}; discovery is restricted to ${UPSTREAM_REPOSITORY}`);
  }
  const { variants, identityPatches } = resolveReleaseVariants(lock);
  const current = await readCurrentRelease(currentReleasePath);
  if (current !== null && current.commit !== lock.commit) {
    fail(
      `current release ${currentReleasePath} records commit ${current.commit} but lock ${lockPath} pins ` +
        `${lock.commit}; reconcile them before discovery`,
    );
  }
  if (await exists(destination)) fail(`destination ${destination} already exists; it must be a new path`);
  const checkedAt = now().toISOString();
  const base = {
    tool: "discover-upstream-nightly",
    schemaVersion: RESULT_SCHEMA_VERSION,
    repository: UPSTREAM_OWNER_REPO,
    checkedAt,
    lock: { path: lockPath, commit: lock.commit },
    current,
  };

  // 2. Selection from the published release listing.
  const listing = await api(`${API_PREFIX}releases?per_page=100`, { paginate: true });
  const selection = selectPublishedNightly(listing, current);
  if (selection.status === "unchanged") {
    // The pinned version is still the newest. Its tag must still name the
    // pinned commit; a moved tag is a provenance change requiring review.
    const commitNow = await resolvePublishedCommit(current, api);
    if (commitNow !== current.commit) {
      fail(
        `tag ${current.tag} now resolves to ${commitNow} but the current release records ${current.commit}; ` +
          "same-version commit replacement is refused",
      );
    }
    const result = { ...base, status: "unchanged", latest: selection.latest };
    await publishResult(destination, { [RESULT_FILE]: jsonText(result) });
    return result;
  }
  const { candidate } = selection;

  // 3. Resolve the tag to its commit.
  const commit = await resolvePublishedCommit(candidate, api);
  const provenance = formatProvenance(candidate, commit);
  const candidateLock = candidateLockText(lockText, lock, commit);

  // 4. Private stage: a copy of the verified catalog beside a candidate lock
  //    whose only changed field is the commit, then both variants prepared
  //    by the real preparer into separate fresh destinations. The stage is
  //    owned from allocation onward: any failure before a `ready` or
  //    `conflict` report has actually been published removes it, and the
  //    original failure wins over a cleanup failure.
  await mkdir(workRoot, { recursive: true });
  const stage = await mkdtemp(path.join(workRoot, "t3-nightly-candidate-"));
  try {
    return await proveAndPublish({
      stage,
      base,
      lockPath,
      lock,
      variants,
      identityPatches,
      candidate,
      commit,
      provenance,
      candidateLock,
      destination,
      repository,
      run,
      api,
      preparerScript,
    });
  } catch (error) {
    try {
      await rm(stage, { recursive: true, force: true });
    } catch {
      // the original failure is the one to report
    }
    throw error;
  }
}

// Everything that happens inside an allocated stage: catalog copy, both
// preparer runs, tree records, the final release/tag recheck, and the
// publication of the report. Returns the published result; throws otherwise.
async function proveAndPublish({
  stage,
  base,
  lockPath,
  lock,
  variants,
  identityPatches,
  candidate,
  commit,
  provenance,
  candidateLock,
  destination,
  repository,
  run,
  api,
  preparerScript,
}) {
  const stageComponent = path.join(stage, "component");
  const realLockDir = await realpath(path.dirname(lockPath));
  await mkdir(stageComponent);
  for (const patch of lock.patches) {
    const target = path.join(stageComponent, patch.path);
    await mkdir(path.dirname(target), { recursive: true });
    await copyFile(path.resolve(realLockDir, patch.path), target);
  }
  const stageLock = path.join(stageComponent, LOCK_FILE);
  await writeFile(stageLock, candidateLock, { flag: "wx" });
  await mkdir(path.join(stage, "trees"));
  await mkdir(path.join(stage, "index"));

  const recorded = {};
  let conflict = null;
  for (const variant of REQUIRED_VARIANTS) {
    const treeDir = path.join(stage, "trees", variant);
    const outcome = await runPreparer({
      run,
      preparerScript,
      candidateLock: stageLock,
      destination: treeDir,
      variant,
      repository,
      cwd: stage,
    });
    if (!outcome.ok) {
      conflict = { variant, ...outcome.conflict };
      break;
    }
    recorded[variant] = await recordPreparedTree({
      run,
      treeDir,
      indexFile: path.join(stage, "index", `${variant}.index`),
      variant,
      commit,
      expectedPatches: variants[variant],
    });
  }

  if (conflict !== null) {
    const result = {
      ...base,
      status: "conflict",
      candidate: provenance,
      candidateLock: { previousCommit: lock.commit, commit },
      conflict,
      variants: recorded,
      work: stage,
    };
    await publishResult(destination, { [RESULT_FILE]: jsonText(result) });
    return result;
  }

  // 5. Re-read the release and tag right before publishing the result.
  await confirmCandidate(api, candidate, commit);

  const patchCheck = {
    lock: lockPath,
    previousCommit: lock.commit,
    commit,
    patches: lock.patches.map(({ id, path: p, sha256 }) => ({ id, path: p, sha256, verified: true })),
    variants: Object.fromEntries(REQUIRED_VARIANTS.map((name) => [name, lock.variants[name]])),
    identityPatches: [...identityPatches],
  };
  const result = {
    ...base,
    status: "ready",
    candidate: provenance,
    candidateLock: { previousCommit: lock.commit, commit },
    variants: {
      [MANAGED_NIGHTLY_VARIANT]: recorded[MANAGED_NIGHTLY_VARIANT],
      [REASONING_VARIANT]: recorded[REASONING_VARIANT],
    },
    files: [RESULT_FILE, LOCK_FILE, PROVENANCE_FILE, PATCH_CHECK_FILE],
    work: stage,
  };
  await publishResult(destination, {
    [RESULT_FILE]: jsonText(result),
    [LOCK_FILE]: candidateLock,
    [PROVENANCE_FILE]: jsonText(provenance),
    [PATCH_CHECK_FILE]: jsonText(patchCheck),
  });
  return result;
}

// --- CLI ------------------------------------------------------------------------

const FLAGS = ["--lock", "--current-release", "--destination", "--repository", "--work"];

export function parseArgs(argv) {
  const options = {
    lock: path.join(componentDir, "source.lock.json"),
    currentRelease: null,
    destination: null,
    repository: null,
    work: null,
  };
  const seen = new Set();
  for (let i = 0; i < argv.length; i += 1) {
    const flag = argv[i];
    const value = argv[i + 1];
    if (!FLAGS.includes(flag)) fail(`unknown argument ${flag}; expected one of ${FLAGS.join(", ")}`);
    if (value === undefined || value.startsWith("-")) fail(`${flag} requires a value`);
    if (seen.has(flag)) fail(`${flag} given more than once`);
    seen.add(flag);
    if (flag === "--repository") options.repository = value;
    else options[flag.slice(2).replace(/-([a-z])/g, (_, c) => c.toUpperCase())] = path.resolve(value);
    i += 1;
  }
  if (options.destination === null) fail("--destination is required");
  return options;
}

export async function main(argv) {
  const options = parseArgs(argv);
  const result = await prepareNightlyCandidate({
    lockPath: options.lock,
    currentReleasePath: options.currentRelease,
    destination: options.destination,
    repository: options.repository,
    ...(options.work === null ? {} : { workRoot: options.work }),
  });
  const where = path.resolve(options.destination);
  if (result.status === "unchanged") {
    console.log(`discover-upstream-nightly: unchanged; ${result.latest.tag} is still the newest published Nightly (${where})`);
    return 0;
  }
  if (result.status === "conflict") {
    console.log(
      `discover-upstream-nightly: conflict; ${result.candidate.tag} at ${result.candidate.commit} rejects ` +
        `${result.conflict.failedPatch} in variant ${result.conflict.variant} (${where})`,
    );
    return EXIT_CONFLICT;
  }
  console.log(
    `discover-upstream-nightly: ready; ${result.candidate.tag} at ${result.candidate.commit} applied both variants (${where})`,
  );
  return 0;
}

if (isEntryPoint(import.meta)) {
  main(process.argv.slice(2))
    .then((code) => {
      process.exitCode = code;
    })
    .catch((error) => {
      const expected = error instanceof DiscoveryError || error instanceof ReleaseError;
      console.error(`discover-upstream-nightly: ${expected ? error.message : error.stack || String(error)}`);
      process.exit(1);
    });
}
