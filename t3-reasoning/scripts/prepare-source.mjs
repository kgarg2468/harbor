#!/usr/bin/env node
// Materialize the exact upstream T3 source pinned in source.lock.json, then
// apply the component's ordered, checksum-verified feature patches, into a new
// destination directory. A version 2 lock names variants, each an ordered
// selection from one checksummed patch catalog; `--variant` picks one. The
// result is staged next to the destination and renamed into place only after
// every step succeeds; an existing destination is never modified. Concurrent
// runs against the same destination are serialized by an adjacent mkdir lock.
// Dependency-free: Node built-ins and the git binary only.
import { execFile } from "node:child_process";
import { createHash } from "node:crypto";
import {
  lstat,
  mkdir,
  mkdtemp,
  readFile,
  realpath,
  rename,
  rm,
  rmdir,
  writeFile,
} from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);
const componentDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const COMMIT_RE = /^[0-9a-f]{40}$/;
const SHA256_RE = /^[0-9a-f]{64}$/;
// The variant prepared when `--variant` is omitted. Version 1 locks have no
// variants and ignore this; the flag is then an error.
const DEFAULT_VARIANT = "reasoning";

class PrepareError extends Error {}

function fail(message) {
  throw new PrepareError(message);
}

function parseArgs(argv) {
  const options = {
    lock: path.join(componentDir, "source.lock.json"),
    destination: path.join(componentDir, ".build", "source"),
    repository: null,
    variant: null,
  };
  for (let i = 0; i < argv.length; i += 1) {
    const flag = argv[i];
    const value = argv[i + 1];
    if (!["--lock", "--destination", "--repository", "--variant"].includes(flag)) {
      fail(`unknown argument ${flag}; expected --lock, --destination, --repository, or --variant`);
    }
    if (value === undefined || value.startsWith("-")) {
      fail(`${flag} requires a value`);
    }
    if (flag === "--repository") options.repository = resolveRepository(value);
    else if (flag === "--variant") options.variant = value;
    else options[flag.slice(2)] = path.resolve(value);
    i += 1;
  }
  return options;
}

// Git runs from the staging directory, so a relative local path must be
// resolved against the caller's cwd first. Transport forms are passed through
// untouched: URLs (scheme://...) and SCP-like host:path, which git recognizes
// by a colon before any slash.
function resolveRepository(value) {
  if (path.isAbsolute(value) || /^[a-zA-Z][a-zA-Z0-9+.-]*:\/\//.test(value) || /^[^/\\]+:/.test(value)) {
    return value;
  }
  return path.resolve(value);
}

function isPlainObject(value) {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

async function readLock(lockPath) {
  let lock;
  try {
    lock = JSON.parse(await readFile(lockPath, "utf8"));
  } catch (error) {
    fail(`cannot read lock ${lockPath}: ${error.message}`);
  }
  if (lock?.version !== 1 && lock?.version !== 2) {
    fail(`lock ${lockPath}: unsupported version ${lock?.version}`);
  }
  if (typeof lock.repository !== "string" || lock.repository === "" || lock.repository.startsWith("-")) {
    fail(`lock ${lockPath}: repository must be a non-empty string`);
  }
  if (typeof lock.commit !== "string" || !COMMIT_RE.test(lock.commit)) {
    fail(`lock ${lockPath}: commit must be a full 40-character lowercase SHA-1`);
  }
  if (!Array.isArray(lock.patches)) fail(`lock ${lockPath}: patches must be an array`);
  lock.patches.forEach((patch, index) => {
    if (typeof patch?.path !== "string" || patch.path === "") {
      fail(`lock ${lockPath}: patches[${index}].path must be a non-empty string`);
    }
    if (typeof patch.sha256 !== "string" || !SHA256_RE.test(patch.sha256)) {
      fail(`lock ${lockPath}: patches[${index}].sha256 must be 64 lowercase hex characters`);
    }
  });
  if (lock.version === 2) validateCatalogAndVariants(lock, lockPath);
  return lock;
}

// Version 2: `patches` is a catalog of `{ id, path, sha256 }` in canonical
// order, and `variants` maps each variant name to the ordered ids it applies.
// Every reference must resolve, no id or path may repeat, and a variant must
// list its ids in catalog order so the variants can only differ by which
// catalog entries they include, never by re-ordering them.
function validateCatalogAndVariants(lock, lockPath) {
  const indexById = new Map();
  const seenPaths = new Set();
  lock.patches.forEach((patch, index) => {
    if (typeof patch.id !== "string" || patch.id === "") {
      fail(`lock ${lockPath}: patches[${index}].id must be a non-empty string`);
    }
    if (indexById.has(patch.id)) {
      fail(`lock ${lockPath}: duplicate patch id ${patch.id} at patches[${index}]`);
    }
    if (seenPaths.has(patch.path)) {
      fail(`lock ${lockPath}: duplicate patch path ${patch.path} at patches[${index}]`);
    }
    indexById.set(patch.id, index);
    seenPaths.add(patch.path);
  });
  if (!isPlainObject(lock.variants)) {
    fail(`lock ${lockPath}: variants must be an object mapping variant names to patch id lists`);
  }
  for (const [name, ids] of Object.entries(lock.variants)) {
    if (name === "") fail(`lock ${lockPath}: variant names must be non-empty`);
    if (!Array.isArray(ids)) fail(`lock ${lockPath}: variants.${name} must be an array of patch ids`);
    let previous = -1;
    const seen = new Set();
    ids.forEach((id, position) => {
      if (typeof id !== "string" || !indexById.has(id)) {
        fail(`lock ${lockPath}: variants.${name}[${position}] references unknown patch id ${String(id)}`);
      }
      if (seen.has(id)) fail(`lock ${lockPath}: variants.${name} lists patch id ${id} twice`);
      seen.add(id);
      const index = indexById.get(id);
      if (index <= previous) {
        fail(
          `lock ${lockPath}: variants.${name}[${position}] (${id}) is out of catalog order; ` +
            `variants must list patch ids in the order of the patches catalog`,
        );
      }
      previous = index;
    });
  }
}

// Returns `{ variant, patches }` for the run: the ordered catalog entries the
// selected variant applies (version 2), or the whole flat list (version 1, no
// variant). Pure lock/argument logic, so every rejection here happens before
// any network or filesystem work.
function resolveVariant(lock, requestedVariant) {
  if (lock.version === 1) {
    if (requestedVariant !== null) {
      fail(`--variant ${requestedVariant} is not supported by a version 1 lock, which has no variants`);
    }
    return { variant: null, patches: lock.patches.map(({ path: p, sha256 }) => ({ path: p, sha256 })) };
  }
  const variant = requestedVariant ?? DEFAULT_VARIANT;
  if (!Object.hasOwn(lock.variants, variant)) {
    const known = Object.keys(lock.variants).sort().join(", ") || "(none)";
    fail(`unknown variant ${variant}; the lock defines: ${known}`);
  }
  const byId = new Map(lock.patches.map((patch) => [patch.id, patch]));
  return {
    variant,
    patches: lock.variants[variant].map((id) => {
      const { path: p, sha256 } = byId.get(id);
      return { id, path: p, sha256 };
    }),
  };
}

// True when `target` is `dir` itself or lies somewhere beneath it. Both paths
// must already be absolute and normalized. Only an exact `..` segment counts
// as a parent reference; a name that merely starts with two dots, such as
// `..patches`, is an ordinary directory.
function isWithin(dir, target) {
  const relative = path.relative(dir, target);
  if (relative === "") return true;
  if (path.isAbsolute(relative)) return false;
  return relative !== ".." && !relative.startsWith(`..${path.sep}`);
}

// Resolves a lock's patch path to the real file it names, refusing anything
// that lands outside the lock directory: absolute paths, `..` escapes, and
// symlinks (at any depth) whose target lies elsewhere. Returns the real path,
// which is what the caller then reads. `realLockDir` is the lock directory
// with its own symlinks already resolved, so both sides compare like for like.
async function resolvePatchFile(realLockDir, patchPath) {
  if (path.isAbsolute(patchPath)) {
    fail(`patch ${patchPath}: path must be relative to the lock directory, not absolute`);
  }
  const nominal = path.resolve(realLockDir, patchPath);
  if (!isWithin(realLockDir, nominal)) {
    fail(`patch ${patchPath}: path resolves outside the lock directory ${realLockDir}`);
  }
  let real;
  try {
    real = await realpath(nominal);
  } catch (error) {
    fail(`patch ${patchPath}: cannot resolve ${nominal}: ${error.message}`);
  }
  if (!isWithin(realLockDir, real)) {
    fail(`patch ${patchPath}: ${nominal} links to ${real}, outside the lock directory ${realLockDir}`);
  }
  return real;
}

// Returns the resolved patches in order with their verified bytes, after
// confirming each file lies within the lock directory and its SHA-256 matches
// the lock. Runs before any network or filesystem work; the bytes verified
// here are the bytes applied later, so a patch file changing on disk after
// this point cannot reach `git apply`.
async function verifyPatches(patches, lockPath) {
  const lockDir = await realpath(path.dirname(lockPath));
  const verified = [];
  for (const patch of patches) {
    const file = await resolvePatchFile(lockDir, patch.path);
    let content;
    try {
      content = await readFile(file);
    } catch (error) {
      fail(`patch ${patch.path}: cannot read ${file}: ${error.message}`);
    }
    const actual = createHash("sha256").update(content).digest("hex");
    if (actual !== patch.sha256) {
      fail(`patch ${patch.path}: sha256 mismatch (lock ${patch.sha256}, file ${actual})`);
    }
    verified.push({ ...patch, content });
  }
  return verified;
}

// Runs git; `input`, when given, is written to git's stdin.
async function git(cwd, args, input) {
  const env = { ...process.env, GIT_TERMINAL_PROMPT: "0" };
  try {
    const pending = execFileAsync("git", args, { cwd, env, maxBuffer: 64 * 1024 * 1024 });
    pending.child.stdin.on("error", () => {}); // a failing git may close stdin early
    pending.child.stdin.end(input);
    return await pending;
  } catch (error) {
    const detail = (error.stderr || error.message || "").trim().split("\n").slice(-3).join(" ");
    fail(`git ${args[0]} failed: ${detail}`);
  }
}

async function fetchCommit(staging, repository, commit) {
  await git(staging, ["-c", "init.defaultBranch=main", "init", "-q"]);
  await git(staging, ["remote", "add", "origin", repository]);
  try {
    // Fetch only the pinned object. Hosts that refuse unadvertised objects
    // fall through to a full fetch of the advertised refs.
    await git(staging, ["fetch", "-q", "--depth", "1", "origin", commit]);
  } catch {
    await git(staging, ["fetch", "-q", "origin"]);
  }
  await git(staging, ["checkout", "-q", "--detach", commit]).catch(() =>
    fail(`commit ${commit} was not found in ${repository}`),
  );
  const { stdout } = await git(staging, ["rev-parse", "HEAD"]);
  if (stdout.trim() !== commit) fail(`checked out ${stdout.trim()} but lock pins ${commit}`);
}

function describePatch(patch) {
  return patch.id === undefined ? patch.path : `${patch.id} (${patch.path})`;
}

async function applyPatches(staging, patches) {
  for (const patch of patches) {
    // Apply the verified bytes from memory via stdin, never re-reading the file.
    await git(staging, ["apply"], patch.content).catch((error) =>
      fail(`patch ${patch.path} does not apply cleanly: ${error.message}`),
    );
    console.log(`prepare-source: applied ${describePatch(patch)}`);
  }
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

async function main() {
  const options = parseArgs(process.argv.slice(2));
  const lock = await readLock(options.lock);
  const repository = options.repository ?? lock.repository;
  if (repository.startsWith("-")) fail("--repository must not start with '-'");
  const selection = resolveVariant(lock, options.variant);
  const patches = await verifyPatches(selection.patches, options.lock);

  const destination = options.destination;
  if (await exists(destination)) fail(`destination ${destination} already exists; remove it first`);
  const parent = path.dirname(destination);
  await mkdir(parent, { recursive: true });

  // Exclusive lock: mkdir without `recursive` fails with EEXIST if another run
  // holds it, so concurrent runs against one destination are serialized and
  // the loser exits before fetching anything. A run killed mid-way leaves the
  // lock behind; remove it by hand once no run is in progress.
  const lockDir = `${destination}.lock`;
  await mkdir(lockDir).catch((error) => {
    if (error.code === "EEXIST") {
      fail(`another prepare-source run holds ${lockDir}; wait for it, or remove the lock if stale`);
    }
    throw error;
  });
  try {
    if (await exists(destination)) fail(`destination ${destination} already exists; remove it first`);
    await prepareInto(destination, parent, options, lock, repository, selection.variant, patches);
  } finally {
    await rmdir(lockDir).catch(() => {});
  }
  const variantNote = selection.variant === null ? "" : ` variant ${selection.variant}`;
  console.log(
    `prepare-source: prepared ${destination}${variantNote} at ${lock.commit} with ${patches.length} patch(es)`,
  );
}

async function prepareInto(destination, parent, options, lock, repository, variant, patches) {
  const staging = await mkdtemp(path.join(parent, `.${path.basename(destination)}.staging-`));
  try {
    console.log(`prepare-source: fetching ${lock.commit} from ${repository}`);
    await fetchCommit(staging, repository, lock.commit);
    await applyPatches(staging, patches);
    // The record names the variant and the fully resolved, ordered patch
    // sequence with its checksums, so two prepared trees can be compared by
    // their provenance alone. Version 1 locks record the flat list unchanged.
    const provenance = {
      preparedAt: new Date().toISOString(),
      lock: options.lock,
      lockRepository: lock.repository,
      repository,
      commit: lock.commit,
      ...(variant === null ? {} : { variant }),
      patches: patches.map(({ id, path: p, sha256 }) =>
        id === undefined ? { path: p, sha256 } : { id, path: p, sha256 },
      ),
    };
    await writeFile(
      path.join(staging, ".git", "harbor-source.json"),
      `${JSON.stringify(provenance, null, 2)}\n`,
    );
    // Publish. The lock keeps other runs of this tool out; this re-check plus
    // rename's own refusal to replace a non-empty directory are the guard
    // against anything else. An empty directory created here by an outside
    // process at exactly this moment would be replaced (POSIX rename
    // semantics); the destination is an owned build-output path, not a
    // location shared with arbitrary concurrent writers.
    if (await exists(destination)) fail(`destination ${destination} appeared during preparation`);
    await rename(staging, destination);
  } catch (error) {
    await rm(staging, { recursive: true, force: true });
    throw error;
  }
}

main().catch((error) => {
  const message = error instanceof PrepareError ? error.message : error.stack || String(error);
  console.error(`prepare-source: ${message}`);
  process.exit(1);
});
