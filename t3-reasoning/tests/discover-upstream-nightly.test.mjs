// Tests for scripts/discover-upstream-nightly.mjs. Selection and tag peeling
// run against real-shaped API fixtures; the materialization cases run the
// real preparer and real git against a local fixture repository through a
// recording argv runner and a deterministic fake API. The CLI cases shim `gh`
// with a script that answers from fixture files and logs its argv. Nothing
// here touches the network or the component's real checkout.
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdirSync } from "node:fs";
import { mkdtemp, mkdir, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { after, before, describe, it } from "node:test";
import { promisify } from "node:util";

import {
  API_PREFIX,
  DiscoveryError,
  EXIT_CONFLICT,
  LOCK_FILE,
  PATCH_CHECK_FILE,
  PROVENANCE_FILE,
  RESULT_FILE,
  UPSTREAM_OWNER_REPO,
  UPSTREAM_REPOSITORY,
  candidateLockText,
  createGhApi,
  defaultRun,
  normalizeReleasePages,
  parseArgs,
  prepareNightlyCandidate,
  resolvePublishedCommit,
  resolveRepositoryPath,
  selectPublishedNightly,
  validateProvenance,
} from "../scripts/discover-upstream-nightly.mjs";
import { ReleaseError } from "../scripts/resolve-managed-release.mjs";

const execFileAsync = promisify(execFile);
const here = path.dirname(fileURLToPath(import.meta.url));
const script = path.join(here, "..", "scripts", "discover-upstream-nightly.mjs");

const gitEnv = {
  GIT_AUTHOR_NAME: "OPERATOR",
  GIT_AUTHOR_EMAIL: "operator@example.com",
  GIT_COMMITTER_NAME: "OPERATOR",
  GIT_COMMITTER_EMAIL: "operator@example.com",
  GIT_CONFIG_GLOBAL: "/dev/null",
  GIT_CONFIG_SYSTEM: "/dev/null",
};

const CURRENT_VERSION = "0.0.39-nightly.20260905.1284";
const NEWER_VERSION = "0.0.39-nightly.20260905.1289";
const CURRENT_PUBLISHED = "2026-09-05T16:10:00Z";
const NEWER_PUBLISHED = "2026-09-05T18:53:55Z";
const RELEASES_ENDPOINT = `${API_PREFIX}releases?per_page=100`;
const SHA_A = "a".repeat(40);
const SHA_B = "b".repeat(40);
const SHA_C = "c".repeat(40);

const PATCH_ONE = `diff --git a/hello.txt b/hello.txt
--- a/hello.txt
+++ b/hello.txt
@@ -1 +1 @@
-one
+one patched
`;
const PATCH_TWO = `diff --git a/hello.txt b/hello.txt
--- a/hello.txt
+++ b/hello.txt
@@ -1 +1 @@
-one patched
+one patched twice
diff --git a/feature.txt b/feature.txt
new file mode 100644
--- /dev/null
+++ b/feature.txt
@@ -0,0 +1 @@
+feature
`;
const PATCH_IDENTITY = `diff --git a/identity.txt b/identity.txt
new file mode 100644
--- /dev/null
+++ b/identity.txt
@@ -0,0 +1 @@
+variant identity
`;

function sha256(text) {
  return createHash("sha256").update(text).digest("hex");
}

function refFor(tag) {
  return `${API_PREFIX}git/ref/tags/${encodeURIComponent(tag)}`;
}

function releaseEntry({ id, tag, publishedAt, draft = false, prerelease = true }) {
  return {
    id,
    tag_name: tag,
    name: tag,
    draft,
    prerelease,
    published_at: publishedAt,
    created_at: publishedAt,
    target_commitish: "main",
    assets: [],
  };
}

function lightweightRef(tag, sha) {
  return { ref: `refs/tags/${tag}`, node_id: "x", object: { sha, type: "commit" } };
}

function currentRecord(commit, overrides = {}) {
  return {
    schemaVersion: 1,
    repository: UPSTREAM_OWNER_REPO,
    releaseId: 100,
    tag: `v${CURRENT_VERSION}`,
    version: CURRENT_VERSION,
    commit,
    publishedAt: CURRENT_PUBLISHED,
    ...overrides,
  };
}

// A deterministic API: `routes` maps endpoints to a value, an Error to throw,
// or a function of the call index. Every call is recorded in order.
function fakeApi(routes) {
  const calls = [];
  const api = async (endpoint, options = {}) => {
    calls.push({ endpoint, paginate: options.paginate === true });
    if (!Object.hasOwn(routes, endpoint)) throw new DiscoveryError(`gh api ${endpoint} failed: HTTP 404: Not Found`);
    let value = routes[endpoint];
    if (typeof value === "function") value = value(calls.length - 1);
    if (value instanceof Error) throw value;
    return structuredClone(value);
  };
  api.calls = calls;
  return api;
}

function rejects(fn, pattern) {
  return assert.rejects(fn, (error) => {
    assert.ok(error instanceof DiscoveryError || error instanceof ReleaseError, `unexpected ${error.stack}`);
    assert.match(error.message, pattern);
    return true;
  });
}

function throwsDiscovery(fn, pattern) {
  assert.throws(fn, (error) => {
    assert.ok(error instanceof DiscoveryError || error instanceof ReleaseError, `unexpected ${error.stack}`);
    assert.match(error.message, pattern);
    return true;
  });
}

describe("selectPublishedNightly", () => {
  const listing = [
    [
      releaseEntry({ id: 5, tag: "v0.0.40", publishedAt: "2026-09-06T00:00:00Z", prerelease: false }),
      releaseEntry({ id: 4, tag: `v${NEWER_VERSION}`, publishedAt: NEWER_PUBLISHED }),
      releaseEntry({ id: 9, tag: "v0.0.39-nightly.20260905.1300", publishedAt: "2026-09-05T20:00:00Z", draft: true }),
      releaseEntry({ id: 8, tag: "v0.0.39-nightly.20260905.1299", publishedAt: null }),
    ],
    [
      releaseEntry({ id: 7, tag: "v0.0.39-beta.1", publishedAt: "2026-09-05T23:00:00Z" }),
      releaseEntry({ id: 6, tag: "0.0.39-nightly.20260905.1298", publishedAt: "2026-09-05T23:00:00Z" }),
      // Newest timestamp and first in its page, but an older exact version.
      releaseEntry({ id: 3, tag: "v0.0.39-nightly.20260905.1288", publishedAt: "2026-09-05T23:59:59Z" }),
      releaseEntry({ id: 100, tag: `v${CURRENT_VERSION}`, publishedAt: CURRENT_PUBLISHED }),
    ],
  ];

  it("flattens pages and accepts a flat listing", () => {
    assert.equal(normalizeReleasePages(listing).length, 8);
    assert.equal(normalizeReleasePages(listing[0]).length, 4);
    throwsDiscovery(() => normalizeReleasePages({ releases: [] }), /must be an array/);
    throwsDiscovery(() => normalizeReleasePages([listing[0], listing[0][0]]), /mixes pages and entries/);
  });

  it("selects the maximum exact Nightly version, ignoring drafts, null publication, stable and unrelated prereleases", () => {
    const selection = selectPublishedNightly(listing, null);
    assert.equal(selection.status, "selected");
    assert.equal(selection.current, null);
    assert.deepEqual(selection.candidate, {
      repository: UPSTREAM_OWNER_REPO,
      releaseId: 4,
      tag: `v${NEWER_VERSION}`,
      version: NEWER_VERSION,
      publishedAt: NEWER_PUBLISHED,
    });
  });

  it("orders by exact version, not by digit strings or timestamps", () => {
    const pages = [
      [
        releaseEntry({ id: 1, tag: "v0.0.39-nightly.20260905.999", publishedAt: "2026-09-05T23:00:00Z" }),
        releaseEntry({ id: 2, tag: "v0.0.39-nightly.20260905.1000", publishedAt: "2026-09-05T01:00:00Z" }),
        releaseEntry({ id: 3, tag: "v0.0.38-nightly.20260906.5", publishedAt: "2026-09-06T01:00:00Z" }),
      ],
    ];
    assert.equal(selectPublishedNightly(pages, null).candidate.releaseId, 2);
  });

  it("selects a strictly newer version over the current record", () => {
    const selection = selectPublishedNightly(listing, currentRecord(SHA_A));
    assert.equal(selection.status, "selected");
    assert.equal(selection.candidate.version, NEWER_VERSION);
    assert.equal(selection.current.commit, SHA_A);
  });

  // The current release plus only ignorable or older entries.
  const currentIsNewest = [
    [listing[0][0], listing[0][2], listing[0][3]],
    [
      listing[1][0],
      listing[1][1],
      releaseEntry({ id: 2, tag: "v0.0.39-nightly.20260905.1280", publishedAt: "2026-09-05T23:59:59Z" }),
      listing[1][3],
    ],
  ];

  it("reports unchanged when the current version is the newest", () => {
    const selection = selectPublishedNightly(currentIsNewest, currentRecord(SHA_A));
    assert.equal(selection.status, "unchanged");
    assert.equal(selection.latest.releaseId, 100);
  });

  it("reports unchanged, never a fallback, when every published Nightly is older", () => {
    const older = [[releaseEntry({ id: 2, tag: "v0.0.39-nightly.20260905.1280", publishedAt: "2026-09-05T23:59:59Z" })]];
    const selection = selectPublishedNightly(older, currentRecord(SHA_A));
    assert.equal(selection.status, "unchanged");
    assert.equal(selection.latest.version, "0.0.39-nightly.20260905.1280");
  });

  it("refuses the current version under a different release id or publication time", () => {
    const only = currentIsNewest;
    throwsDiscovery(
      () => selectPublishedNightly(only, currentRecord(SHA_A, { releaseId: 101 })),
      /changed identity.*release 101.*release 100/,
    );
    throwsDiscovery(
      () => selectPublishedNightly(only, currentRecord(SHA_A, { publishedAt: "2026-09-05T16:10:01Z" })),
      /changed identity/,
    );
  });

  it("refuses two releases publishing the same version", () => {
    const pages = [[listing[0][1], { ...listing[0][1], id: 44 }]];
    throwsDiscovery(() => selectPublishedNightly(pages, null), /releases 4 and 44 both publish/);
  });

  it("fails when no published Nightly exists", () => {
    throwsDiscovery(() => selectPublishedNightly([[listing[0][0], listing[0][2]]], null), /no published upstream Nightly/);
    throwsDiscovery(() => selectPublishedNightly([[]], null), /no published upstream Nightly/);
  });

  it("validates the current record before consulting the listing", () => {
    throwsDiscovery(() => selectPublishedNightly(listing, currentRecord(SHA_A, { repository: "evil/t3code" })), /repository/);
    throwsDiscovery(() => selectPublishedNightly(listing, currentRecord(SHA_A, { tag: "v9.9.9" })), /tag/);
    throwsDiscovery(() => selectPublishedNightly(listing, currentRecord("abc")), /commit/);
    throwsDiscovery(() => selectPublishedNightly(listing, currentRecord(SHA_A, { schemaVersion: 2 })), /schemaVersion/);
    throwsDiscovery(() => selectPublishedNightly(listing, currentRecord(SHA_A, { version: "0.0.39" })), /not an ordinary upstream nightly/);
    throwsDiscovery(() => selectPublishedNightly(listing, currentRecord(SHA_A, { publishedAt: "yesterday" })), /publishedAt/);
    assert.deepEqual(Object.keys(validateProvenance(currentRecord(SHA_A))), [
      "schemaVersion",
      "repository",
      "releaseId",
      "tag",
      "version",
      "commit",
      "publishedAt",
    ]);
  });

  it("refuses a candidate whose release id is malformed", () => {
    const pages = [[releaseEntry({ id: "4", tag: `v${NEWER_VERSION}`, publishedAt: NEWER_PUBLISHED })]];
    throwsDiscovery(() => selectPublishedNightly(pages, null), /invalid id/);
  });
});

describe("resolvePublishedCommit", () => {
  const tag = `v${NEWER_VERSION}`;
  const release = { tag };

  it("resolves a lightweight tag directly to its commit", async () => {
    const api = fakeApi({ [refFor(tag)]: lightweightRef(tag, SHA_A) });
    assert.equal(await resolvePublishedCommit(release, api), SHA_A);
    assert.deepEqual(api.calls.map((c) => c.endpoint), [refFor(tag)]);
  });

  it("peels annotated tags, including nested tag objects", async () => {
    const api = fakeApi({
      [refFor(tag)]: { ref: `refs/tags/${tag}`, object: { sha: SHA_B, type: "tag" } },
      [`${API_PREFIX}git/tags/${SHA_B}`]: { sha: SHA_B, tag, object: { sha: SHA_C, type: "tag" } },
      [`${API_PREFIX}git/tags/${SHA_C}`]: { sha: SHA_C, tag, object: { sha: SHA_A, type: "commit" } },
    });
    assert.equal(await resolvePublishedCommit(release, api), SHA_A);
    assert.equal(api.calls.length, 3);
  });

  it("rejects a missing ref", async () => {
    await rejects(() => resolvePublishedCommit(release, fakeApi({})), /404/);
  });

  it("rejects a ref lookup that names a different ref", async () => {
    const api = fakeApi({ [refFor(tag)]: lightweightRef("v0.0.39-nightly.20260905.1289-rc", SHA_A) });
    await rejects(() => resolvePublishedCommit(release, api), /did not return exactly refs\/tags/);
    await rejects(() => resolvePublishedCommit(release, fakeApi({ [refFor(tag)]: [lightweightRef(tag, SHA_A)] })), /did not return exactly/);
  });

  it("rejects a cyclic tag chain", async () => {
    const api = fakeApi({
      [refFor(tag)]: { ref: `refs/tags/${tag}`, object: { sha: SHA_B, type: "tag" } },
      [`${API_PREFIX}git/tags/${SHA_B}`]: { sha: SHA_B, object: { sha: SHA_C, type: "tag" } },
      [`${API_PREFIX}git/tags/${SHA_C}`]: { sha: SHA_C, object: { sha: SHA_B, type: "tag" } },
    });
    await rejects(() => resolvePublishedCommit(release, api), /cycles at/);
  });

  it("rejects a tag pointing at a non-commit object", async () => {
    const api = fakeApi({ [refFor(tag)]: { ref: `refs/tags/${tag}`, object: { sha: SHA_A, type: "tree" } } });
    await rejects(() => resolvePublishedCommit(release, api), /tree object .* not a commit/);
  });

  it("rejects a short or uppercase sha and a tag object answering for another sha", async () => {
    await rejects(
      () => resolvePublishedCommit(release, fakeApi({ [refFor(tag)]: lightweightRef(tag, SHA_A.slice(0, 12)) })),
      /not a full lowercase SHA-1/,
    );
    await rejects(
      () => resolvePublishedCommit(release, fakeApi({ [refFor(tag)]: lightweightRef(tag, SHA_A.toUpperCase()) })),
      /not a full lowercase SHA-1/,
    );
    const api = fakeApi({
      [refFor(tag)]: { ref: `refs/tags/${tag}`, object: { sha: SHA_B, type: "tag" } },
      [`${API_PREFIX}git/tags/${SHA_B}`]: { sha: SHA_C, object: { sha: SHA_A, type: "commit" } },
    });
    await rejects(() => resolvePublishedCommit(release, api), /returned a different object/);
  });
});

describe("createGhApi", () => {
  it("invokes gh with argv, paginating only when asked, and parses the JSON", async () => {
    const commands = [];
    const run = async (command, args, options) => {
      commands.push({ command, args, options });
      return { stdout: JSON.stringify([[{ id: 1 }]]), stderr: "" };
    };
    const api = createGhApi(run);
    assert.deepEqual(await api(RELEASES_ENDPOINT, { paginate: true }), [[{ id: 1 }]]);
    await api(refFor("v1.0.0-nightly.20260101.1"));
    assert.deepEqual(
      commands.map((c) => [c.command, ...c.args]),
      [
        ["gh", "api", "--method", "GET", "--paginate", "--slurp", RELEASES_ENDPOINT],
        ["gh", "api", "--method", "GET", refFor("v1.0.0-nightly.20260101.1")],
      ],
    );
    for (const { args, options } of commands) {
      assert.ok(args.every((arg) => typeof arg === "string"));
      assert.equal(options.env.GH_PROMPT_DISABLED, "1");
      assert.equal(options.env.GH_TOKEN, undefined, "the helper never sets or forwards a token itself");
    }
  });

  it("refuses endpoints outside the fixed upstream repository", async () => {
    const api = createGhApi(async () => assert.fail("must not run"));
    await rejects(() => api("/repos/other/repo/releases"), /only \/repos\/pingdotgg\/t3code\/\* is allowed/);
    await rejects(() => api("https://evil.invalid/repos/pingdotgg/t3code/releases"), /only/);
  });

  it("surfaces gh failures and invalid JSON as errors", async () => {
    const failing = createGhApi(async () => {
      const error = new Error("gh: HTTP 404");
      error.stderr = "gh: Not Found (HTTP 404)\n";
      throw error;
    });
    await rejects(() => failing(RELEASES_ENDPOINT), /HTTP 404/);
    const garbage = createGhApi(async () => ({ stdout: "not json", stderr: "" }));
    await rejects(() => garbage(RELEASES_ENDPOINT), /invalid JSON/);
  });
});

describe("candidateLockText", () => {
  it("changes only the commit literal and keeps the rest of the text byte for byte", () => {
    const lock = { version: 2, repository: UPSTREAM_REPOSITORY, commit: SHA_A, patches: [], variants: {} };
    const text = `{\n  "version": 2,\n  "repository": "${UPSTREAM_REPOSITORY}",\n  "commit": "${SHA_A}",\n  "patches": [],\n  "variants": {}\n}\n`;
    assert.equal(candidateLockText(text, lock, SHA_B), text.replace(SHA_A, SHA_B));
    // Non-canonical text is re-serialized with the new commit.
    const compact = JSON.stringify(lock);
    assert.deepEqual(JSON.parse(candidateLockText(compact, lock, SHA_B)), { ...lock, commit: SHA_B });
  });
});

describe("parseArgs", () => {
  it("requires --destination and rejects unknown or repeated flags", () => {
    throwsDiscovery(() => parseArgs([]), /--destination is required/);
    throwsDiscovery(() => parseArgs(["--destination", "x", "--destination", "y"]), /more than once/);
    throwsDiscovery(() => parseArgs(["--bogus", "x"]), /unknown argument/);
    throwsDiscovery(() => parseArgs(["--destination"]), /requires a value/);
    const options = parseArgs(["--destination", "out", "--lock", "l.json", "--repository", "./mirror"]);
    assert.equal(options.destination, path.resolve("out"));
    assert.equal(options.lock, path.resolve("l.json"));
    assert.equal(options.repository, "./mirror");
    assert.equal(options.currentRelease, null);
  });
});

describe("resolveRepositoryPath", () => {
  it("resolves a relative local path against the caller's cwd and passes other forms through", () => {
    assert.equal(resolveRepositoryPath("./mirror"), path.resolve("mirror"));
    assert.equal(resolveRepositoryPath("mirrors/t3code"), path.resolve("mirrors/t3code"));
    assert.equal(resolveRepositoryPath("/abs/mirror"), "/abs/mirror");
    assert.equal(resolveRepositoryPath(UPSTREAM_REPOSITORY), UPSTREAM_REPOSITORY);
    assert.equal(resolveRepositoryPath("ssh://git@github.com/pingdotgg/t3code.git"), "ssh://git@github.com/pingdotgg/t3code.git");
    assert.equal(resolveRepositoryPath("git@github.com:pingdotgg/t3code.git"), "git@github.com:pingdotgg/t3code.git");
    assert.equal(resolveRepositoryPath(null), null);
  });
});

// --- materialization against a local fixture --------------------------------------

let root;
let upstream;
let pinned;
let clean;
let firstConflict;
let secondConflict;
let componentDir;
let lockPath;
let lockText;
let lockObject;
let currentPath;
let caseCount = 0;

async function git(cwd, ...args) {
  const { stdout } = await execFileAsync("git", args, { cwd, env: { ...process.env, ...gitEnv } });
  return stdout.trim();
}

async function commitAll(message) {
  await git(upstream, "add", "-A");
  await git(upstream, "commit", "-q", "-m", message);
  return git(upstream, "rev-parse", "HEAD");
}

// Recursively hashes every file under `dir` so a run's effect on the checkout
// can be proven absent.
async function snapshot(dir) {
  const files = (await readdir(dir, { recursive: true, withFileTypes: true }))
    .filter((entry) => entry.isFile())
    .map((entry) => path.relative(dir, path.join(entry.parentPath, entry.name)))
    .sort();
  const out = {};
  for (const file of files) out[file] = sha256(await readFile(path.join(dir, file)));
  return out;
}

async function entries(dir) {
  return (await readdir(dir)).sort();
}

async function readJson(file) {
  return JSON.parse(await readFile(file, "utf8"));
}

// A runner that records every argv and delegates to the real execFile with an
// isolated git configuration.
function recordingRun() {
  const commands = [];
  const run = async (command, args, options = {}) => {
    commands.push({ command, args: [...args], cwd: options.cwd ?? null });
    return defaultRun(command, args, { ...options, env: { ...gitEnv, ...options.env } });
  };
  run.commands = commands;
  return run;
}

function routesFor({ commit, listing, tagCommit = commit, rereadCommit = commit, reread }) {
  const tag = `v${NEWER_VERSION}`;
  let refCalls = 0;
  return {
    [RELEASES_ENDPOINT]: listing,
    [refFor(tag)]: () => {
      refCalls += 1;
      return lightweightRef(tag, refCalls === 1 ? tagCommit : rereadCommit);
    },
    [refFor(`v${CURRENT_VERSION}`)]: lightweightRef(`v${CURRENT_VERSION}`, pinned),
    [`${API_PREFIX}releases/4`]: reread ?? releaseEntry({ id: 4, tag, publishedAt: NEWER_PUBLISHED }),
  };
}

function fullListing() {
  return [
    [
      releaseEntry({ id: 4, tag: `v${NEWER_VERSION}`, publishedAt: NEWER_PUBLISHED }),
      releaseEntry({ id: 9, tag: "v0.0.39-nightly.20260905.1300", publishedAt: "2026-09-05T20:00:00Z", draft: true }),
    ],
    [releaseEntry({ id: 100, tag: `v${CURRENT_VERSION}`, publishedAt: CURRENT_PUBLISHED })],
  ];
}

async function freshCase() {
  const dir = path.join(root, `case-${caseCount++}`);
  await mkdir(dir);
  return { dir, destination: path.join(dir, "candidate"), work: path.join(dir, "work") };
}

async function discover({ dir, destination, work }, { api, currentReleasePath = currentPath, lock = lockPath } = {}) {
  const run = recordingRun();
  const before = await snapshot(componentDir);
  let result;
  let error = null;
  try {
    result = await prepareNightlyCandidate({
      lockPath: lock,
      currentReleasePath,
      destination,
      repository: upstream,
      workRoot: work,
      run,
      api,
      now: () => new Date("2026-09-05T19:00:00Z"),
    });
  } catch (caught) {
    error = caught;
  }
  // Every mode leaves the real checkout byte-identical.
  assert.deepEqual(await snapshot(componentDir), before);
  return { result, error, run, dir, destination };
}

// Independently records a prepared tree with a private index, as the tool does.
async function independentTree(treeDir, indexFile) {
  const env = { ...process.env, ...gitEnv, GIT_INDEX_FILE: indexFile };
  const opts = { cwd: treeDir, env };
  await execFileAsync("git", ["read-tree", "HEAD"], opts);
  await execFileAsync("git", ["add", "-A"], opts);
  return (await execFileAsync("git", ["write-tree"], opts)).stdout.trim();
}

before(async () => {
  root = await mkdtemp(path.join(tmpdir(), "discover-nightly-"));
  upstream = path.join(root, "upstream");
  await mkdir(upstream);
  await git(upstream, "-c", "init.defaultBranch=main", "init", "-q");
  await writeFile(path.join(upstream, "hello.txt"), "one\n");
  pinned = await commitAll("pinned");
  await writeFile(path.join(upstream, "notes.txt"), "newer upstream work that patches tolerate\n");
  clean = await commitAll("clean candidate");
  await writeFile(path.join(upstream, "identity.txt"), "upstream now ships this file\n");
  secondConflict = await commitAll("identity file already exists");
  await rm(path.join(upstream, "identity.txt"));
  await writeFile(path.join(upstream, "hello.txt"), "newer\n");
  firstConflict = await commitAll("hello rewritten");
  assert.equal(new Set([pinned, clean, secondConflict, firstConflict]).size, 4);

  componentDir = path.join(root, "component");
  await mkdir(path.join(componentDir, "patches"), { recursive: true });
  const patches = [
    { id: "one", path: "patches/0001-one.patch", text: PATCH_ONE },
    { id: "two", path: "patches/0002-two.patch", text: PATCH_TWO },
    { id: "identity", path: "patches/0003-identity.patch", text: PATCH_IDENTITY },
  ];
  for (const patch of patches) await writeFile(path.join(componentDir, patch.path), patch.text);
  lockObject = {
    version: 2,
    repository: UPSTREAM_REPOSITORY,
    commit: pinned,
    patches: patches.map(({ id, path: p, text }) => ({ id, path: p, sha256: sha256(text) })),
    variants: { "managed-nightly": ["one", "two"], reasoning: ["one", "two", "identity"] },
  };
  lockText = `${JSON.stringify(lockObject, null, 2)}\n`;
  lockPath = path.join(componentDir, "source.lock.json");
  await writeFile(lockPath, lockText);
  currentPath = path.join(componentDir, "upstream-release.json");
  await writeFile(currentPath, `${JSON.stringify(currentRecord(pinned), null, 2)}\n`);
});

after(async () => {
  await rm(root, { recursive: true, force: true });
});

describe("prepareNightlyCandidate", () => {
  it("proves a newer Nightly on both variants and publishes the candidate atomically", async () => {
    const c = await freshCase();
    const api = fakeApi(routesFor({ commit: clean, listing: fullListing() }));
    const { result, error, run, destination } = await discover(c, { api });
    assert.equal(error, null, error?.stack);
    assert.equal(result.status, "ready");
    assert.deepEqual(await entries(destination), [LOCK_FILE, PATCH_CHECK_FILE, RESULT_FILE, PROVENANCE_FILE].sort());
    assert.deepEqual(await entries(c.dir), ["candidate", "work"], "no staging left beside the destination");

    // Tracked provenance: exactly the design's record shape for the selected release.
    const provenance = await readJson(path.join(destination, PROVENANCE_FILE));
    assert.deepEqual(provenance, {
      schemaVersion: 1,
      repository: "pingdotgg/t3code",
      releaseId: 4,
      tag: `v${NEWER_VERSION}`,
      version: NEWER_VERSION,
      commit: clean,
      publishedAt: NEWER_PUBLISHED,
    });
    assert.deepEqual(result.candidate, provenance);
    assert.deepEqual(result.current, currentRecord(pinned));

    // The candidate lock differs from the checked-in lock by the commit line only.
    const candidateText = await readFile(path.join(destination, LOCK_FILE), "utf8");
    assert.equal(candidateText, lockText.replace(pinned, clean));
    assert.deepEqual(JSON.parse(candidateText), { ...lockObject, commit: clean });
    assert.deepEqual(result.candidateLock, { previousCommit: pinned, commit: clean });

    const patchCheck = await readJson(path.join(destination, PATCH_CHECK_FILE));
    assert.deepEqual(patchCheck.patches.map((p) => [p.id, p.sha256, p.verified]), lockObject.patches.map((p) => [p.id, p.sha256, true]));
    assert.deepEqual(patchCheck.variants, lockObject.variants);
    assert.deepEqual(patchCheck.identityPatches, ["identity"]);
    assert.equal(patchCheck.commit, clean);

    // API order: verify first, list, resolve, materialize, then re-read release and tag.
    assert.deepEqual(api.calls.map((call) => call.endpoint), [
      RELEASES_ENDPOINT,
      refFor(`v${NEWER_VERSION}`),
      `${API_PREFIX}releases/4`,
      refFor(`v${NEWER_VERSION}`),
    ]);
    assert.equal(api.calls[0].paginate, true);
    assert.equal(api.calls[1].paginate, false);

    // Both variants ran through the real preparer as argv against separate fresh paths.
    const preparerRuns = run.commands.filter((cmd) => cmd.command === process.execPath);
    assert.equal(preparerRuns.length, 2);
    const stageLock = path.join(result.work, "component", LOCK_FILE);
    const variantOf = (cmd) => cmd.args[cmd.args.indexOf("--variant") + 1];
    const destinationOf = (cmd) => cmd.args[cmd.args.indexOf("--destination") + 1];
    assert.deepEqual(preparerRuns.map(variantOf), ["managed-nightly", "reasoning"]);
    assert.notEqual(destinationOf(preparerRuns[0]), destinationOf(preparerRuns[1]));
    for (const cmd of preparerRuns) {
      assert.equal(cmd.args[0], path.join(here, "..", "scripts", "prepare-source.mjs"));
      assert.equal(cmd.args[cmd.args.indexOf("--lock") + 1], stageLock);
      assert.equal(cmd.args[cmd.args.indexOf("--repository") + 1], upstream);
      assert.ok(cmd.args.every((arg) => typeof arg === "string" && !/\s&&|\|\|;/.test(arg)));
      assert.ok(!cmd.args.some((arg) => arg.includes("--3way") || arg.includes("--reject")));
    }
    // The stage lock is the candidate lock; the copied catalog stays relative to it.
    assert.equal(await readFile(stageLock, "utf8"), candidateText);
    for (const patch of lockObject.patches) {
      assert.equal(sha256(await readFile(path.join(result.work, "component", patch.path))), patch.sha256);
    }
    // Only git and the preparer ran.
    assert.deepEqual([...new Set(run.commands.map((cmd) => cmd.command))].sort(), ["git", process.execPath].sort());

    // Tree proofs: each prepared checkout is HEAD = candidate commit with the
    // patches applied in the working tree, recorded through a private index.
    for (const variant of ["managed-nightly", "reasoning"]) {
      const record = result.variants[variant];
      assert.equal(record.head, clean);
      assert.equal(destinationOf(preparerRuns.find((cmd) => variantOf(cmd) === variant)), record.destination);
      assert.equal(await git(record.destination, "rev-parse", "HEAD"), clean);
      await execFileAsync("git", ["diff", "--cached", "--quiet"], { cwd: record.destination, env: { ...process.env, ...gitEnv } });
      const expectedTree = await independentTree(record.destination, path.join(c.dir, `${variant}.index`));
      assert.equal(record.tree, expectedTree);
      assert.deepEqual(
        record.patches,
        lockObject.variants[variant].map((id) => ({ id, sha256: lockObject.patches.find((p) => p.id === id).sha256 })),
      );
    }
    assert.notEqual(result.variants["managed-nightly"].tree, result.variants.reasoning.tree);
    assert.equal(await readFile(path.join(result.variants.reasoning.destination, "identity.txt"), "utf8"), "variant identity\n");
    assert.equal(await readFile(path.join(result.variants["managed-nightly"].destination, "hello.txt"), "utf8"), "one patched twice\n");
    assert.deepEqual(await entries(result.variants["managed-nightly"].destination), [".git", "feature.txt", "hello.txt", "notes.txt"]);
  });

  it("bootstraps without a current record only when the flag is omitted", async () => {
    const c = await freshCase();
    const api = fakeApi(routesFor({ commit: clean, listing: fullListing() }));
    const { result, error } = await discover(c, { api, currentReleasePath: null });
    assert.equal(error, null, error?.stack);
    assert.equal(result.status, "ready");
    assert.equal(result.current, null);
    assert.equal(result.candidate.commit, clean);
  });

  it("refuses a missing or corrupt current record explicitly, before any API call", async () => {
    const missing = await freshCase();
    const api = fakeApi(routesFor({ commit: clean, listing: fullListing() }));
    const { error } = await discover(missing, { api, currentReleasePath: path.join(missing.dir, "absent.json") });
    assert.ok(error instanceof DiscoveryError);
    assert.match(error.message, /does not exist; omit --current-release only for the initial bootstrap/);
    assert.equal(api.calls.length, 0);
    assert.deepEqual(await entries(missing.dir), []);

    const corrupt = await freshCase();
    const corruptPath = path.join(corrupt.dir, "corrupt.json");
    await writeFile(corruptPath, "{ not json\n");
    const corruptRun = await discover(corrupt, { api, currentReleasePath: corruptPath });
    assert.match(corruptRun.error.message, /not valid JSON/);
    assert.equal(api.calls.length, 0);
  });

  it("reports unchanged when the current release is still the newest and its tag still names the pinned commit", async () => {
    const c = await freshCase();
    const listing = [[releaseEntry({ id: 100, tag: `v${CURRENT_VERSION}`, publishedAt: CURRENT_PUBLISHED })]];
    const api = fakeApi(routesFor({ commit: clean, listing }));
    const { result, error, run, destination } = await discover(c, { api });
    assert.equal(error, null, error?.stack);
    assert.equal(result.status, "unchanged");
    assert.deepEqual(result.latest, {
      repository: UPSTREAM_OWNER_REPO,
      releaseId: 100,
      tag: `v${CURRENT_VERSION}`,
      version: CURRENT_VERSION,
      publishedAt: CURRENT_PUBLISHED,
    });
    assert.deepEqual(await entries(destination), [RESULT_FILE]);
    assert.deepEqual(await readJson(path.join(destination, RESULT_FILE)), result);
    assert.deepEqual(api.calls.map((call) => call.endpoint), [RELEASES_ENDPOINT, refFor(`v${CURRENT_VERSION}`)]);
    assert.equal(run.commands.length, 0, "no git or preparer run for an unchanged result");
    assert.equal(await readFile(lockPath, "utf8"), lockText);
  });

  it("refuses same-version commit replacement instead of repinning", async () => {
    const c = await freshCase();
    const listing = [[releaseEntry({ id: 100, tag: `v${CURRENT_VERSION}`, publishedAt: CURRENT_PUBLISHED })]];
    const routes = routesFor({ commit: clean, listing });
    routes[refFor(`v${CURRENT_VERSION}`)] = lightweightRef(`v${CURRENT_VERSION}`, clean);
    const api = fakeApi(routes);
    const { error, run, destination } = await discover(c, { api });
    assert.ok(error instanceof DiscoveryError);
    assert.match(error.message, /same-version commit replacement is refused/);
    assert.equal(run.commands.length, 0);
    assert.deepEqual(await entries(c.dir), [], `${destination} must not exist`);
  });

  it("refuses the current version re-published under another release id", async () => {
    const c = await freshCase();
    const listing = [[releaseEntry({ id: 101, tag: `v${CURRENT_VERSION}`, publishedAt: CURRENT_PUBLISHED })]];
    const api = fakeApi(routesFor({ commit: clean, listing }));
    const { error } = await discover(c, { api });
    assert.match(error.message, /changed identity/);
    assert.deepEqual(await entries(c.dir), []);
  });

  it("requires the current record to agree with the lock commit, before any API call", async () => {
    const c = await freshCase();
    const stale = path.join(c.dir, "stale.json");
    await writeFile(stale, JSON.stringify(currentRecord(clean)));
    const api = fakeApi(routesFor({ commit: clean, listing: fullListing() }));
    const { error } = await discover(c, { api, currentReleasePath: stale });
    assert.match(error.message, /records commit .* but lock .* pins/);
    assert.equal(api.calls.length, 0);
    assert.deepEqual(await entries(c.dir), ["stale.json"]);
  });

  it("verifies every patch checksum before any API call", async () => {
    const c = await freshCase();
    const brokenDir = path.join(c.dir, "component");
    await mkdir(path.join(brokenDir, "patches"), { recursive: true });
    for (const patch of lockObject.patches) {
      await writeFile(path.join(brokenDir, patch.path), await readFile(path.join(componentDir, patch.path)));
    }
    // Tamper with a patch the managed-nightly variant does not even apply.
    await writeFile(path.join(brokenDir, "patches/0003-identity.patch"), `${PATCH_IDENTITY}\n`);
    const brokenLock = path.join(brokenDir, "source.lock.json");
    await writeFile(brokenLock, lockText);
    const api = fakeApi(routesFor({ commit: clean, listing: fullListing() }));
    const { error, run } = await discover(c, { api, lock: brokenLock, currentReleasePath: null });
    assert.ok(error instanceof ReleaseError, error?.stack);
    assert.match(error.message, /0003-identity\.patch: sha256 mismatch/);
    assert.equal(api.calls.length, 0);
    assert.equal(run.commands.length, 0);
    assert.deepEqual(await entries(c.dir), ["component"]);
  });

  it("refuses a lock that names any repository other than the public upstream", async () => {
    const c = await freshCase();
    const otherDir = path.join(c.dir, "component");
    await mkdir(path.join(otherDir, "patches"), { recursive: true });
    for (const patch of lockObject.patches) {
      await writeFile(path.join(otherDir, patch.path), await readFile(path.join(componentDir, patch.path)));
    }
    const otherLock = path.join(otherDir, "source.lock.json");
    await writeFile(otherLock, lockText.replace(UPSTREAM_REPOSITORY, "https://github.com/someone/t3code.git"));
    const api = fakeApi(routesFor({ commit: clean, listing: fullListing() }));
    const { error } = await discover(c, { api, lock: otherLock, currentReleasePath: null });
    assert.match(error.message, /discovery is restricted to https:\/\/github\.com\/pingdotgg\/t3code\.git/);
    assert.equal(api.calls.length, 0);
  });

  it("refuses an existing destination before any API call and leaves it untouched", async () => {
    const c = await freshCase();
    await mkdir(c.destination);
    await writeFile(path.join(c.destination, "keep.txt"), "mine\n");
    const api = fakeApi(routesFor({ commit: clean, listing: fullListing() }));
    const { error, run } = await discover(c, { api });
    assert.match(error.message, /already exists; it must be a new path/);
    assert.equal(api.calls.length, 0);
    assert.equal(run.commands.length, 0);
    assert.deepEqual(await entries(c.destination), ["keep.txt"]);
    assert.equal(await readFile(path.join(c.destination, "keep.txt"), "utf8"), "mine\n");
  });

  it("reports a first-variant conflict with bounded diagnostics and no candidate files", async () => {
    const c = await freshCase();
    const api = fakeApi(routesFor({ commit: firstConflict, listing: fullListing() }));
    const { result, error, run, destination } = await discover(c, { api });
    assert.equal(error, null, error?.stack);
    assert.equal(result.status, "conflict");
    assert.deepEqual(result.conflict.variant, "managed-nightly");
    assert.equal(result.conflict.failedPatch, "patches/0001-one.patch");
    assert.ok(Array.isArray(result.conflict.diagnostics) && result.conflict.diagnostics.length > 0);
    assert.ok(result.conflict.diagnostics.length <= 12);
    assert.ok(result.conflict.diagnostics.every((line) => line.length <= 403));
    assert.equal(result.candidate.commit, firstConflict);
    assert.equal(result.candidate.version, NEWER_VERSION);
    assert.deepEqual(result.variants, {});
    assert.deepEqual(await entries(destination), [RESULT_FILE]);
    assert.deepEqual(await readJson(path.join(destination, RESULT_FILE)), result);
    // Only one preparer run; no re-read of the release, no fallback to the older Nightly.
    assert.equal(run.commands.filter((cmd) => cmd.command === process.execPath).length, 1);
    assert.deepEqual(api.calls.map((call) => call.endpoint), [RELEASES_ENDPOINT, refFor(`v${NEWER_VERSION}`)]);
    assert.equal(await readFile(lockPath, "utf8"), lockText);
    assert.deepEqual(await readJson(currentPath), currentRecord(pinned));
  });

  it("reports a second-variant conflict after the first variant succeeded", async () => {
    const c = await freshCase();
    const api = fakeApi(routesFor({ commit: secondConflict, listing: fullListing() }));
    const { result, error, run, destination } = await discover(c, { api });
    assert.equal(error, null, error?.stack);
    assert.equal(result.status, "conflict");
    assert.equal(result.conflict.variant, "reasoning");
    assert.equal(result.conflict.failedPatch, "patches/0003-identity.patch");
    assert.equal(result.variants["managed-nightly"].head, secondConflict);
    assert.match(result.variants["managed-nightly"].tree, /^[0-9a-f]{40}$/);
    assert.equal(result.variants.reasoning, undefined);
    assert.equal(run.commands.filter((cmd) => cmd.command === process.execPath).length, 2);
    assert.deepEqual(await entries(destination), [RESULT_FILE]);
    // A published conflict report keeps its stage, as documented.
    assert.deepEqual(await entries(c.work), [path.basename(result.work)]);
  });

  it("fails when the tag moves during the run, publishes nothing, and removes the stage", async () => {
    const c = await freshCase();
    const api = fakeApi(routesFor({ commit: clean, listing: fullListing(), rereadCommit: secondConflict }));
    const { error, run, destination } = await discover(c, { api });
    assert.ok(error instanceof DiscoveryError, error?.stack);
    assert.match(error.message, /moved from .* during the run; refusing to repin/);
    assert.equal(run.commands.filter((cmd) => cmd.command === process.execPath).length, 2, "both trees were prepared");
    assert.deepEqual(await entries(c.dir), ["work"], `${destination} must not exist`);
    assert.deepEqual(await entries(c.work), [], "a late tag move removes the owned stage");
  });

  it("fails when the release is unpublished or re-identified during the run and removes the stage", async () => {
    const drafted = await freshCase();
    const draft = releaseEntry({ id: 4, tag: `v${NEWER_VERSION}`, publishedAt: NEWER_PUBLISHED, draft: true });
    let outcome = await discover(drafted, { api: fakeApi(routesFor({ commit: clean, listing: fullListing(), reread: draft })) });
    assert.match(outcome.error.message, /no longer a published Nightly prerelease/);
    assert.deepEqual(await entries(drafted.dir), ["work"]);
    assert.deepEqual(await entries(drafted.work), []);

    const retimed = await freshCase();
    const republished = releaseEntry({ id: 4, tag: `v${NEWER_VERSION}`, publishedAt: "2026-09-05T18:53:56Z" });
    outcome = await discover(retimed, { api: fakeApi(routesFor({ commit: clean, listing: fullListing(), reread: republished })) });
    assert.match(outcome.error.message, /moved: publishedAt/);
    assert.deepEqual(await entries(retimed.dir), ["work"]);
    assert.deepEqual(await entries(retimed.work), []);
  });

  it("fails when the final release re-read itself fails after both trees were prepared, and removes the stage", async () => {
    const c = await freshCase();
    const routes = routesFor({ commit: clean, listing: fullListing() });
    routes[`${API_PREFIX}releases/4`] = new DiscoveryError(`gh api ${API_PREFIX}releases/4 failed: HTTP 502: Bad Gateway`);
    const api = fakeApi(routes);
    const { error, run, result } = await discover(c, { api });
    assert.equal(result, undefined);
    assert.ok(error instanceof DiscoveryError, error?.stack);
    assert.match(error.message, /HTTP 502/);
    assert.equal(run.commands.filter((cmd) => cmd.command === process.execPath).length, 2, "both trees were prepared");
    assert.deepEqual(await entries(c.dir), ["work"]);
    assert.deepEqual(await entries(c.work), [], "a failed final API call removes the owned stage");
  });

  it("removes the stage when publication fails after a successful confirmation", async () => {
    const c = await freshCase();
    const routes = routesFor({ commit: clean, listing: fullListing() });
    // The destination appears between the successful re-read and the final
    // rename, so publication is refused; nothing is overwritten.
    const reread = routes[`${API_PREFIX}releases/4`];
    routes[`${API_PREFIX}releases/4`] = () => {
      mkdirSync(c.destination);
      return reread;
    };
    const api = fakeApi(routes);
    const { error, run, result } = await discover(c, { api });
    assert.equal(result, undefined);
    assert.ok(error instanceof DiscoveryError, error?.stack);
    assert.match(error.message, /appeared during the run; nothing was overwritten/);
    assert.equal(api.calls.length, 4, "confirmation completed before publication");
    assert.equal(run.commands.filter((cmd) => cmd.command === process.execPath).length, 2);
    assert.deepEqual(await entries(c.dir), ["candidate", "work"], "no staging left beside the destination");
    assert.deepEqual(await entries(c.destination), [], "the foreign destination is untouched");
    assert.deepEqual(await entries(c.work), [], "a failed publication removes the owned stage");
  });

  it("treats a non-conflict preparer failure as an error, not a conflict", async () => {
    const c = await freshCase();
    // A commit the fixture repository does not have: the preparer cannot fetch it.
    const api = fakeApi(routesFor({ commit: SHA_A, listing: fullListing() }));
    const { error, result } = await discover(c, { api });
    assert.equal(result, undefined);
    assert.ok(error instanceof DiscoveryError, error?.stack);
    assert.match(error.message, /prepare-source --variant managed-nightly failed/);
    assert.deepEqual(await entries(c.dir), ["work"]);
    assert.deepEqual(await entries(c.work), [], "an unexpected failure removes its stage");
  });
});

// --- CLI ------------------------------------------------------------------------------

describe("CLI", { skip: process.platform === "win32" && "needs a POSIX shell wrapper on PATH" }, () => {
  // A `gh` on PATH that logs its argv and answers GET requests from fixture
  // files keyed by endpoint, so the real entry point runs end to end.
  async function ghShim(dir, responses) {
    const bin = path.join(dir, "bin");
    const fixtures = path.join(dir, "gh-fixtures");
    await mkdir(bin);
    await mkdir(fixtures);
    for (const [endpoint, value] of Object.entries(responses)) {
      await writeFile(path.join(fixtures, encodeURIComponent(endpoint)), JSON.stringify(value));
    }
    const log = path.join(dir, "gh.log");
    await writeFile(
      path.join(bin, "gh"),
      `#!/bin/sh
printf '%s\\n' "$@" >> "$GH_SHIM_LOG"
printf -- '--\\n' >> "$GH_SHIM_LOG"
for last; do :; done
file="$GH_SHIM_FIXTURES/$(node -e 'process.stdout.write(encodeURIComponent(process.argv[1]))' "$last")"
if [ -f "$file" ]; then cat "$file"; else echo "gh: Not Found (HTTP 404)" >&2; exit 1; fi
`,
      { mode: 0o755 },
    );
    return {
      env: {
        ...process.env,
        ...gitEnv,
        PATH: `${bin}${path.delimiter}${process.env.PATH}`,
        GH_SHIM_LOG: log,
        GH_SHIM_FIXTURES: fixtures,
      },
      log,
    };
  }

  async function cli(args, env, cwd = undefined) {
    try {
      const { stdout, stderr } = await execFileAsync(process.execPath, [script, ...args], { env, cwd });
      return { code: 0, stdout, stderr };
    } catch (error) {
      return { code: error.code, stdout: error.stdout ?? "", stderr: error.stderr ?? "" };
    }
  }

  it("exits 0 with a ready candidate, passing every gh call as argv", async () => {
    const c = await freshCase();
    const tag = `v${NEWER_VERSION}`;
    const { env, log } = await ghShim(c.dir, {
      [RELEASES_ENDPOINT]: fullListing(),
      [refFor(tag)]: lightweightRef(tag, clean),
      [`${API_PREFIX}releases/4`]: releaseEntry({ id: 4, tag, publishedAt: NEWER_PUBLISHED }),
    });
    const result = await cli(
      [
        "--lock", lockPath,
        "--current-release", currentPath,
        "--destination", c.destination,
        "--repository", upstream,
        "--work", c.work,
      ],
      env,
    );
    assert.equal(result.code, 0, result.stderr);
    assert.match(result.stdout, new RegExp(`ready; ${tag} at ${clean} applied both variants`));
    const written = await readJson(path.join(c.destination, RESULT_FILE));
    assert.equal(written.status, "ready");
    assert.equal((await readJson(path.join(c.destination, PROVENANCE_FILE))).commit, clean);
    const invocations = (await readFile(log, "utf8")).split("--\n").filter(Boolean).map((block) => block.trimEnd().split("\n"));
    assert.deepEqual(invocations, [
      ["api", "--method", "GET", "--paginate", "--slurp", RELEASES_ENDPOINT],
      ["api", "--method", "GET", refFor(tag)],
      ["api", "--method", "GET", `${API_PREFIX}releases/4`],
      ["api", "--method", "GET", refFor(tag)],
    ]);
  });

  it("resolves a relative --repository against the invocation cwd, not the private stage", async () => {
    const c = await freshCase();
    const tag = `v${NEWER_VERSION}`;
    const { env } = await ghShim(c.dir, {
      [RELEASES_ENDPOINT]: fullListing(),
      [refFor(tag)]: lightweightRef(tag, clean),
      [`${API_PREFIX}releases/4`]: releaseEntry({ id: 4, tag, publishedAt: NEWER_PUBLISHED }),
    });
    // Invoked from the mirror's parent with a relative mirror path.
    const result = await cli(
      [
        "--lock", lockPath,
        "--current-release", currentPath,
        "--destination", c.destination,
        "--repository", `./${path.basename(upstream)}`,
        "--work", c.work,
      ],
      env,
      path.dirname(upstream),
    );
    assert.equal(result.code, 0, result.stderr);
    const written = await readJson(path.join(c.destination, RESULT_FILE));
    assert.equal(written.status, "ready");
    for (const variant of ["managed-nightly", "reasoning"]) {
      assert.equal(written.variants[variant].head, clean);
      assert.equal(await git(written.variants[variant].destination, "rev-parse", "HEAD"), clean);
    }
  });

  it("exits 2 on a patch conflict and still writes the report", async () => {
    const c = await freshCase();
    const tag = `v${NEWER_VERSION}`;
    const { env } = await ghShim(c.dir, {
      [RELEASES_ENDPOINT]: fullListing(),
      [refFor(tag)]: lightweightRef(tag, firstConflict),
    });
    const result = await cli(
      ["--lock", lockPath, "--current-release", currentPath, "--destination", c.destination, "--repository", upstream, "--work", c.work],
      env,
    );
    assert.equal(result.code, EXIT_CONFLICT, result.stderr);
    assert.match(result.stdout, /conflict; .* rejects patches\/0001-one\.patch in variant managed-nightly/);
    assert.equal((await readJson(path.join(c.destination, RESULT_FILE))).status, "conflict");
  });

  it("exits 1 on an API failure without creating the destination", async () => {
    const c = await freshCase();
    const { env } = await ghShim(c.dir, {});
    const result = await cli(
      ["--lock", lockPath, "--current-release", currentPath, "--destination", c.destination, "--repository", upstream, "--work", c.work],
      env,
    );
    assert.equal(result.code, 1);
    assert.match(result.stderr, /discover-upstream-nightly: gh api .*releases\?per_page=100 failed: .*HTTP 404/);
    assert.deepEqual(await entries(c.dir), ["bin", "gh-fixtures", "gh.log"]);
  });

  it("exits 1 on a usage error", async () => {
    const result = await cli(["--lock", lockPath], { ...process.env, ...gitEnv });
    assert.equal(result.code, 1);
    assert.match(result.stderr, /--destination is required/);
  });
});
