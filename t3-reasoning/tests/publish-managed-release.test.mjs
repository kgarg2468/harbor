// Tests for scripts/publish-managed-release.mjs and the structure of
// .github/workflows/t3-managed-release.yml. The publisher runs against a
// real six-file release closure written by the existing manifest writer from
// a synthetic lock, an in-memory fake of the Harbor GitHub API that records
// every call, and a deterministic fake of the upstream release API. The
// workflow assertions extract the small YAML subset the workflow is written in
// (top-level keys, jobs, permissions, and the static matrix) rather than
// snapshotting the whole file. Nothing here reaches GitHub.
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdtemp, mkdir, readFile, readdir, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { after, before, describe, it } from "node:test";
import { promisify } from "node:util";

import {
  API_PREFIX as UPSTREAM_API_PREFIX,
  DiscoveryError,
  UPSTREAM_OWNER_REPO,
  UPSTREAM_REPOSITORY,
} from "../scripts/discover-upstream-nightly.mjs";
import {
  PUBLIC_CONFIG_KEYS,
  ReleaseError,
  canonicalJson,
  readVerifiedLock,
  resolveManagedRelease,
} from "../scripts/resolve-managed-release.mjs";
import {
  EXPECTED_ARTIFACTS,
  MANIFEST_FILE,
  SUMS_FILE,
  hashFile,
  writeManagedReleaseManifest,
} from "../scripts/write-managed-release-manifest.mjs";
import {
  ADMIN_READ_TOKEN_ENV,
  BUILD_ARTIFACT_PREFIX,
  HARBOR_API_PREFIX,
  HARBOR_REPOSITORY,
  IMMUTABLE_SETTINGS_ENDPOINT,
  PublishError,
  TAG_PREFIX,
  TRUSTED_REF,
  assembleBuilds,
  createHarborApi,
  createImmutableSettingsReader,
  findPriorRelease,
  parseArgs,
  publishManagedRelease,
  readReleaseClosure,
  releaseTag,
  requireHarborEndpoint,
  requireImmutableReleasesEnabled,
  requireTagAbsent,
  selectPriorRelease,
  validateManifest,
  verifyUpstreamRelease,
  writePublicConfig,
} from "../scripts/publish-managed-release.mjs";

const execFileAsync = promisify(execFile);
const here = path.dirname(fileURLToPath(import.meta.url));
const script = path.join(here, "..", "scripts", "publish-managed-release.mjs");
const workflowPath = path.join(here, "..", "..", ".github", "workflows", "t3-managed-release.yml");

const UPSTREAM_COMMIT = "9cb40178a53cca279c67a9079afab3cddf6b6ddb";
const BUILDER_REVISION = "0123456789abcdef0123456789abcdef01234567";
const OTHER_REVISION = "fedcba9876543210fedcba9876543210fedcba98";
const UPSTREAM_VERSION = "0.0.39-nightly.20260905.1284";
const UPSTREAM_RELEASE_ID = 384223346;
const UPSTREAM_PUBLISHED = "2026-09-05T16:10:00Z";
const PUBLIC_CONFIG = {
  T3CODE_RELAY_URL: "https://relay.fixture.invalid",
  T3CODE_CLERK_PUBLISHABLE_KEY: "pk_test_FIXTURE_PUBLISHABLE_VALUE",
  T3CODE_CLERK_JWT_TEMPLATE: "fixture-jwt-template",
  T3CODE_CLERK_CLI_OAUTH_CLIENT_ID: "fixture-cli-oauth-client",
};
const PATCH_CONTENT = {
  "reasoning-full": "--- a/one\n+++ b/one\n@@ -1 +1 @@\n-one\n+one patched\n",
  "desktop-runtime-common": "--- a/two\n+++ b/two\n@@ -1 +1 @@\n-two\n+two patched\n",
  "reasoning-identity": "--- a/identity\n+++ b/identity\n@@ -1 +1 @@\n-stock\n+reasoning\n",
};
const RELEASES_ENDPOINT = `${HARBOR_API_PREFIX}releases?per_page=100`;
const IMMUTABLE_ENDPOINT = `${HARBOR_API_PREFIX}immutable-releases`;

function sha256(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}

function rejects(fn, pattern) {
  return assert.rejects(fn, (error) => {
    const expected = error instanceof PublishError || error instanceof ReleaseError || error instanceof DiscoveryError;
    assert.ok(expected, `unexpected ${error.stack}`);
    assert.match(error.message, pattern);
    return true;
  });
}

function throwsPublish(fn, pattern) {
  assert.throws(fn, (error) => {
    const expected = error instanceof PublishError || error instanceof ReleaseError || error instanceof DiscoveryError;
    assert.ok(expected, `unexpected ${error.stack}`);
    assert.match(error.message, pattern);
    return true;
  });
}

async function cli(args, options = {}) {
  try {
    const { stdout, stderr } = await execFileAsync(process.execPath, [script, ...args], options);
    return { code: 0, stdout, stderr };
  } catch (error) {
    return { code: error.code, stdout: error.stdout ?? "", stderr: error.stderr ?? "" };
  }
}

// --- release closure fixture ---------------------------------------------------

async function writeLockFixture(dir) {
  await mkdir(path.join(dir, "patches"), { recursive: true });
  const patches = [];
  for (const [id, text] of Object.entries(PATCH_CONTENT)) {
    const rel = path.join("patches", `${id}.patch`);
    await writeFile(path.join(dir, rel), text);
    patches.push({ id, path: rel, sha256: sha256(text) });
  }
  const lock = {
    version: 2,
    repository: UPSTREAM_REPOSITORY,
    commit: UPSTREAM_COMMIT,
    patches,
    variants: {
      "managed-nightly": ["reasoning-full", "desktop-runtime-common"],
      reasoning: ["reasoning-full", "desktop-runtime-common", "reasoning-identity"],
    },
  };
  const lockPath = path.join(dir, "source.lock.json");
  await writeFile(lockPath, `${JSON.stringify(lock, null, 2)}\n`);
  return lockPath;
}

function inventoryFor(version) {
  const files = {
    "managed-nightly-darwin-arm64": `T3-Code-${version}-arm64.zip`,
    "reasoning-darwin-arm64": `T3-Code-Reasoning-${version}-arm64.zip`,
    "managed-server-darwin-arm64": `managed-server-darwin-arm64-${version}.tar.gz`,
    "managed-server-linux-x64": `managed-server-linux-x64-${version}.tar.gz`,
  };
  return EXPECTED_ARTIFACTS.map((expected) => ({
    ...structuredClone(expected),
    file: files[expected.id],
    version,
    ...(expected.kind === "desktop" ? { embeddedServerVersion: version } : {}),
  }));
}

function upstreamRecord(overrides = {}) {
  return {
    schemaVersion: 1,
    repository: UPSTREAM_OWNER_REPO,
    releaseId: UPSTREAM_RELEASE_ID,
    tag: `v${UPSTREAM_VERSION}`,
    version: UPSTREAM_VERSION,
    commit: UPSTREAM_COMMIT,
    publishedAt: UPSTREAM_PUBLISHED,
    ...overrides,
  };
}

// Builds one complete release under `root/<name>` with the real resolver and
// manifest writer. Returns { releaseDir, descriptor, manifest, lock, lockPath }.
async function writeRelease(root, name, { releaseCounter = 1, builderRevision = BUILDER_REVISION, priorRelease = null } = {}) {
  const dir = path.join(root, name);
  const lockPath = await writeLockFixture(path.join(dir, "lock"));
  const lock = await readVerifiedLock(lockPath);
  const descriptor = resolveManagedRelease({
    lock,
    upstreamVersion: UPSTREAM_VERSION,
    releaseCounter,
    builderRevision,
    publicConfig: PUBLIC_CONFIG,
    priorRelease,
  });
  const inventory = inventoryFor(descriptor.releaseVersion);
  const artifactsDir = path.join(dir, "artifacts");
  await mkdir(artifactsDir, { recursive: true });
  for (const record of inventory) {
    await writeFile(path.join(artifactsDir, record.file), `fixture bytes for ${record.id} in ${name}\n`.repeat(3));
  }
  const releaseDir = path.join(dir, "release");
  const manifest = await writeManagedReleaseManifest({ descriptor, inventory, artifactsDir, destination: releaseDir });
  return { releaseDir, descriptor, manifest, lock, lockPath, inventory, artifactsDir };
}

// --- fake Harbor GitHub API ----------------------------------------------------

function releaseUrl(id) {
  return `https://api.github.com/repos/${HARBOR_REPOSITORY}/releases/${id}`;
}

function assetUrl(id) {
  return `https://api.github.com/repos/${HARBOR_REPOSITORY}/releases/assets/${id}`;
}

function httpError(status, text = "") {
  const error = new PublishError(`gh api failed: HTTP ${status}${text ? `: ${text}` : ""}`);
  error.status = status;
  return error;
}

// A stateful fake of the parts of the GitHub REST API the publisher uses:
// the immutable-releases setting, tag refs, releases in every state, and
// assets with bytes. Every call is recorded in order. `hooks.before(call)`
// runs before a call is served and may throw or mutate state; `hooks.after`
// may rewrite a response. `options.omitDigest` drops asset digests so the
// publisher must download bytes by id.
function fakeGitHub({ immutable = true, releases = [], refs = {}, omitDigest = false } = {}) {
  const state = {
    immutable,
    nextId: 1000,
    releases: new Map(),
    refs: new Map(Object.entries(refs)),
    tagObjects: new Map(),
    assetBytes: new Map(),
    omitDigest,
  };
  for (const release of releases) {
    const entry = { assets: [], immutable: true, ...structuredClone(release), url: releaseUrl(release.id), html_url: `https://github.com/${HARBOR_REPOSITORY}/releases/tag/${release.tag_name}` };
    for (const asset of entry.assets) {
      asset.url ??= assetUrl(asset.id);
      if (asset.bytes !== undefined) {
        state.assetBytes.set(asset.id, Buffer.from(asset.bytes));
        asset.size ??= Buffer.byteLength(asset.bytes);
        if (!omitDigest && asset.digest === undefined) asset.digest = `sha256:${sha256(asset.bytes)}`;
        delete asset.bytes;
      }
    }
    state.releases.set(entry.id, entry);
  }
  const calls = [];
  const hooks = { before: null, after: null };
  const path_ = (endpoint) => endpoint.slice(HARBOR_API_PREFIX.length);

  function findRelease(id) {
    const release = state.releases.get(Number(id));
    if (release === undefined) throw httpError(404, "Not Found");
    return release;
  }

  async function serve(call) {
    const { method, endpoint, options } = call;
    if (endpoint.startsWith("https://uploads.github.com/")) {
      const match = /^https:\/\/uploads\.github\.com\/repos\/kgarg2468\/harbor\/releases\/(\d+)\/assets\?name=(.+)$/.exec(endpoint);
      if (match === null || method !== "POST") throw httpError(404, "Not Found");
      const release = findRelease(match[1]);
      const name = decodeURIComponent(match[2]);
      if (release.assets.some((asset) => asset.name === name)) throw httpError(422, "Validation Failed: already_exists");
      const bytes = await readFile(options.inputFile);
      state.nextId += 1;
      const asset = { id: state.nextId, name, size: bytes.length, state: "uploaded", content_type: options.contentType ?? "application/octet-stream", url: assetUrl(state.nextId) };
      if (!state.omitDigest) asset.digest = `sha256:${sha256(bytes)}`;
      state.assetBytes.set(asset.id, bytes);
      release.assets.push(asset);
      return structuredClone(asset);
    }
    const rel = path_(endpoint);
    if (method === "GET") {
      if (rel === "immutable-releases") return { enabled: state.immutable, enforced_by_owner: false };
      let match;
      if ((match = /^git\/matching-refs\/tags\/(.+)$/.exec(rel)) !== null) {
        const prefix = decodeURIComponent(match[1]);
        return [...state.refs.entries()].filter(([tag]) => tag.startsWith(prefix)).map(([tag, sha]) => ({ ref: `refs/tags/${tag}`, object: { sha, type: "commit" } }));
      }
      if ((match = /^git\/ref\/tags\/(.+)$/.exec(rel)) !== null) {
        const tag = decodeURIComponent(match[1]);
        if (!state.refs.has(tag)) throw httpError(404, "Not Found");
        const sha = state.refs.get(tag);
        const type = state.tagObjects.has(sha) ? "tag" : "commit";
        return { ref: `refs/tags/${tag}`, object: { sha, type } };
      }
      if ((match = /^git\/tags\/([0-9a-f]{40})$/.exec(rel)) !== null) {
        if (!state.tagObjects.has(match[1])) throw httpError(404, "Not Found");
        return { sha: match[1], object: state.tagObjects.get(match[1]) };
      }
      if (rel === "releases?per_page=100") {
        const all = [...state.releases.values()].map((r) => structuredClone(r));
        return options.paginate ? [all.slice(0, 2), all.slice(2)].filter((page) => page.length > 0) : all;
      }
      if ((match = /^releases\/tags\/(.+)$/.exec(rel)) !== null) {
        const tag = decodeURIComponent(match[1]);
        const release = [...state.releases.values()].find((r) => r.tag_name === tag && r.draft === false);
        if (release === undefined) throw httpError(404, "Not Found");
        return structuredClone(release);
      }
      if ((match = /^releases\/assets\/(\d+)$/.exec(rel)) !== null) {
        const id = Number(match[1]);
        if (options.raw) {
          if (!state.assetBytes.has(id)) throw httpError(404, "Not Found");
          return Buffer.from(state.assetBytes.get(id));
        }
        for (const release of state.releases.values()) {
          const asset = release.assets.find((a) => a.id === id);
          if (asset !== undefined) return structuredClone(asset);
        }
        throw httpError(404, "Not Found");
      }
      if ((match = /^releases\/(\d+)$/.exec(rel)) !== null) return structuredClone(findRelease(match[1]));
      throw httpError(404, `no fake route for GET ${rel}`);
    }
    if (method === "POST" && rel === "releases") {
      const body = options.body;
      if (typeof body?.tag_name !== "string") throw httpError(422, "tag_name required");
      if ([...state.releases.values()].some((r) => r.tag_name === body.tag_name)) throw httpError(422, "already_exists");
      state.nextId += 1;
      const release = {
        id: state.nextId,
        tag_name: body.tag_name,
        name: body.name ?? body.tag_name,
        body: body.body ?? "",
        draft: body.draft === true,
        prerelease: body.prerelease === true,
        target_commitish: body.target_commitish,
        published_at: body.draft === true ? null : "2026-09-08T00:00:00Z",
        created_at: "2026-09-08T00:00:00Z",
        immutable: false,
        assets: [],
        url: releaseUrl(state.nextId),
        html_url: `https://github.com/${HARBOR_REPOSITORY}/releases/tag/${body.tag_name}`,
      };
      state.releases.set(release.id, release);
      return structuredClone(release);
    }
    let match;
    if (method === "PATCH" && (match = /^releases\/(\d+)$/.exec(rel)) !== null) {
      const release = findRelease(match[1]);
      const body = options.body ?? {};
      if (body.draft === false && release.draft === true) {
        release.draft = false;
        release.published_at = "2026-09-08T00:05:00Z";
        release.immutable = state.immutable;
        if (!state.refs.has(release.tag_name)) state.refs.set(release.tag_name, release.target_commitish);
      }
      for (const key of Object.keys(body)) if (key !== "draft") release[key] = body[key];
      return structuredClone(release);
    }
    throw httpError(405, `fake refuses ${method} ${rel}`);
  }

  const api = async (method, endpoint, options = {}) => {
    requireHarborEndpoint(endpoint);
    const call = { index: calls.length, method, endpoint, options: { ...options } };
    calls.push(call);
    if (hooks.before !== null) await hooks.before(call, state);
    let response = await serve(call);
    if (hooks.after !== null) response = await hooks.after(call, response, state);
    return response;
  };
  api.calls = calls;
  api.state = state;
  api.hooks = hooks;
  // The separately credentialed setting reader, recorded in the same call
  // list so ordering assertions see it.
  api.readImmutableSetting = () => api("GET", IMMUTABLE_ENDPOINT);
  return api;
}

function upstreamApi(routes) {
  const calls = [];
  const api = async (endpoint, options = {}) => {
    calls.push({ endpoint, paginate: options.paginate === true });
    if (!Object.hasOwn(routes, endpoint)) throw new DiscoveryError(`gh api ${endpoint} failed: HTTP 404: Not Found`);
    const value = routes[endpoint];
    if (value instanceof Error) throw value;
    return structuredClone(value);
  };
  api.calls = calls;
  return api;
}

function upstreamRoutes({ record = upstreamRecord(), commit = UPSTREAM_COMMIT, overrides = {} } = {}) {
  return {
    [`${UPSTREAM_API_PREFIX}releases/${record.releaseId}`]: {
      id: record.releaseId,
      tag_name: record.tag,
      name: record.tag,
      draft: false,
      prerelease: true,
      published_at: record.publishedAt,
      target_commitish: "main",
      assets: [],
      ...overrides,
    },
    [`${UPSTREAM_API_PREFIX}git/ref/tags/${encodeURIComponent(record.tag)}`]: { ref: `refs/tags/${record.tag}`, object: { sha: commit, type: "commit" } },
  };
}

function summarize(calls) {
  return calls.map((call) => `${call.method} ${call.endpoint.startsWith(HARBOR_API_PREFIX) ? call.endpoint.slice(HARBOR_API_PREFIX.length) : call.endpoint}`);
}

function managedRelease({ id, version, draft = false, prerelease = true, immutable = true, published = "2026-09-01T00:00:00Z", manifest, assets, tag }) {
  const tagName = tag ?? `${TAG_PREFIX}${version}`;
  const entry = { id, tag_name: tagName, name: tagName, draft, prerelease, immutable, published_at: draft ? null : published, target_commitish: BUILDER_REVISION, assets: assets ?? [] };
  if (manifest !== undefined) entry.assets = [{ id: id * 10, name: MANIFEST_FILE, bytes: canonicalJson(manifest), state: "uploaded" }];
  return entry;
}

// --- tests -----------------------------------------------------------------------------

describe("publish-managed-release", () => {
  let root;
  let first;
  before(async () => {
    root = await mkdtemp(path.join(tmpdir(), "t3-publish-"));
    first = await writeRelease(root, "first");
  });
  after(() => rm(root, { recursive: true, force: true }));

  function publishOptions(overrides = {}) {
    const api = overrides.api ?? fakeGitHub();
    return {
      releaseDir: first.releaseDir,
      repository: HARBOR_REPOSITORY,
      ref: TRUSTED_REF,
      builderRevision: BUILDER_REVISION,
      upstreamRecord: upstreamRecord(),
      lock: first.lock,
      api,
      readImmutableSetting: api.readImmutableSetting,
      upstreamApi: upstreamApi(upstreamRoutes()),
      ...overrides,
    };
  }

  describe("constants and endpoint closure", () => {
    it("fixes the repository, tag prefix, and trusted ref", () => {
      assert.equal(HARBOR_REPOSITORY, "kgarg2468/harbor");
      assert.equal(TAG_PREFIX, "t3-managed-v");
      assert.equal(TRUSTED_REF, "refs/heads/main");
      assert.equal(HARBOR_API_PREFIX, "/repos/kgarg2468/harbor/");
      assert.equal(releaseTag(first.manifest.releaseVersion), `t3-managed-v${first.manifest.releaseVersion}`);
      throwsPublish(() => releaseTag("1.2.3"), /not a managed release version/);
    });

    it("accepts only Harbor repository endpoints and the Harbor upload URL", () => {
      requireHarborEndpoint(`${HARBOR_API_PREFIX}releases/1`);
      requireHarborEndpoint("https://uploads.github.com/repos/kgarg2468/harbor/releases/12/assets?name=managed-release.json");
      for (const endpoint of [
        "/repos/kgarg2468/harbor",
        "/repos/kgarg2468/harbor-fork/releases",
        "/repos/pingdotgg/t3code/releases",
        `${HARBOR_API_PREFIX}../other/releases`,
        "https://uploads.github.com/repos/other/repo/releases/12/assets?name=x",
        "https://uploads.github.com/repos/kgarg2468/harbor/releases/12/assets?name=../x",
        "https://api.github.com/repos/kgarg2468/harbor/releases",
        42,
      ]) {
        throwsPublish(() => requireHarborEndpoint(endpoint), /refusing/);
      }
    });

    it("createHarborApi drives gh api with argv only, never a shell, and only GET/POST/PATCH", async () => {
      const invocations = [];
      const run = async (command, args, options) => {
        invocations.push({ command, args, options });
        if (options.raw) return { stdout: Buffer.from("raw-bytes"), stderr: "" };
        if (args.includes("--paginate")) return { stdout: "[[{\"id\":1}]]", stderr: "" };
        return { stdout: "{\"ok\":true}", stderr: "" };
      };
      const api = createHarborApi(run);
      assert.deepEqual(await api("GET", `${HARBOR_API_PREFIX}immutable-releases`), { ok: true });
      assert.deepEqual(await api("GET", RELEASES_ENDPOINT, { paginate: true }), [[{ id: 1 }]]);
      assert.deepEqual(await api("PATCH", `${HARBOR_API_PREFIX}releases/5`, { body: { draft: false } }), { ok: true });
      assert.ok((await api("GET", `${HARBOR_API_PREFIX}releases/assets/7`, { raw: true })).equals(Buffer.from("raw-bytes")));
      await api("POST", "https://uploads.github.com/repos/kgarg2468/harbor/releases/5/assets?name=SHA256SUMS", { inputFile: "/tmp/x", contentType: "text/plain" });
      assert.deepEqual(invocations.map((i) => i.command), ["gh", "gh", "gh", "gh", "gh"]);
      assert.deepEqual(invocations[0].args, ["api", "--method", "GET", `${HARBOR_API_PREFIX}immutable-releases`]);
      assert.deepEqual(invocations[1].args, ["api", "--method", "GET", "--paginate", "--slurp", RELEASES_ENDPOINT]);
      assert.deepEqual(invocations[2].args, ["api", "--method", "PATCH", "--input", "-", `${HARBOR_API_PREFIX}releases/5`]);
      assert.equal(invocations[2].options.input, JSON.stringify({ draft: false }));
      assert.deepEqual(invocations[3].args, ["api", "--method", "GET", "-H", "Accept: application/octet-stream", `${HARBOR_API_PREFIX}releases/assets/7`]);
      assert.deepEqual(invocations[4].args, ["api", "--method", "POST", "-H", "Content-Type: text/plain", "--input", "/tmp/x", "https://uploads.github.com/repos/kgarg2468/harbor/releases/5/assets?name=SHA256SUMS"]);
      await rejects(() => api("DELETE", `${HARBOR_API_PREFIX}releases/5`), /refusing method DELETE/);
      await rejects(() => api("PUT", `${HARBOR_API_PREFIX}releases/5`), /refusing method PUT/);
      await rejects(() => api("GET", "/repos/other/repo/releases"), /refusing/);
      assert.equal(invocations.length, 5, "refused calls never reach gh");
      const failing = createHarborApi(async () => {
        const error = new Error("boom");
        error.stderr = "gh: HTTP 500: Server Error";
        throw error;
      });
      await rejects(() => failing("GET", `${HARBOR_API_PREFIX}releases/1`), /HTTP 500/);
      const invalid = createHarborApi(async () => ({ stdout: "not json", stderr: "" }));
      await rejects(() => invalid("GET", `${HARBOR_API_PREFIX}releases/1`), /invalid JSON/);
    });

    it("the immutable-setting reader is GET-only on one fixed endpoint, passes the admin-read token only as the child GH_TOKEN, and never echoes it", async () => {
      const token = "ghp_ADMINREADFIXTURETOKEN";
      assert.equal(ADMIN_READ_TOKEN_ENV, "T3_MANAGED_RELEASE_ADMIN_READ_TOKEN");
      assert.equal(IMMUTABLE_SETTINGS_ENDPOINT, `${HARBOR_API_PREFIX}immutable-releases`);
      const invocations = [];
      const run = async (command, args, options) => {
        invocations.push({ command, args, options });
        return { stdout: "{\"enabled\":true,\"enforced_by_owner\":false}", stderr: "" };
      };
      const read = createImmutableSettingsReader({ token, run });
      assert.deepEqual(await read(), { enabled: true, enforced_by_owner: false });
      assert.equal(invocations.length, 1);
      assert.equal(invocations[0].command, "gh");
      assert.deepEqual(invocations[0].args, ["api", "--method", "GET", IMMUTABLE_SETTINGS_ENDPOINT]);
      assert.equal(invocations[0].options.env.GH_TOKEN, token, "the token reaches gh only through its environment");
      assert.ok(!JSON.stringify(invocations[0].args).includes(token), "the token is never an argument");
      await requireImmutableReleasesEnabled(read);
      // Missing or empty token: fatal before any gh call.
      for (const missing of [undefined, "", "   ", 42]) {
        const never = createImmutableSettingsReader({ token: missing, run: async () => assert.fail("gh must not run") });
        await rejects(() => never(), /T3_MANAGED_RELEASE_ADMIN_READ_TOKEN/);
      }
      // Authorization failure is reported without the token and fails closed.
      const forbidden = createImmutableSettingsReader({
        token,
        run: async () => {
          const error = new Error("boom");
          error.stderr = `gh: HTTP 403: Resource not accessible by integration (${token})`;
          throw error;
        },
      });
      await assert.rejects(
        () => requireImmutableReleasesEnabled(forbidden),
        (error) => {
          assert.ok(error instanceof PublishError, error.stack);
          assert.match(error.message, /immutable-releases/);
          assert.match(error.message, /HTTP 403/);
          assert.doesNotMatch(error.message, /ADMINREADFIXTURETOKEN/);
          return true;
        },
      );
      const disabled = createImmutableSettingsReader({ token, run: async () => ({ stdout: "{\"enabled\":false}", stderr: "" }) });
      await rejects(() => requireImmutableReleasesEnabled(disabled), /immutable releases are not enabled/);
      const invalid = createImmutableSettingsReader({ token, run: async () => ({ stdout: "nope", stderr: "" }) });
      await rejects(() => requireImmutableReleasesEnabled(invalid), /invalid JSON/);
    });
  });

  describe("public config", () => {
    it("writes exactly the four keys from the environment, never printing values", async () => {
      const output = path.join(root, "public-config.json");
      const env = { ...PUBLIC_CONFIG, T3CODE_UNRELATED: "ignored", PATH: "/usr/bin" };
      const result = await writePublicConfig({ env, output });
      assert.equal(result.sha256, first.descriptor.publicConfig.sha256);
      const written = JSON.parse(await readFile(output, "utf8"));
      assert.deepEqual(Object.keys(written), [...PUBLIC_CONFIG_KEYS]);
      assert.deepEqual(written, PUBLIC_CONFIG);
      await rejects(() => writePublicConfig({ env, output }), /already exists/);
    });

    it("refuses missing, empty, or control-bearing values without echoing them", async () => {
      for (const [name, env] of [
        ["missing", { ...PUBLIC_CONFIG, T3CODE_RELAY_URL: undefined }],
        ["empty", { ...PUBLIC_CONFIG, T3CODE_CLERK_JWT_TEMPLATE: "" }],
        ["control", { ...PUBLIC_CONFIG, T3CODE_CLERK_PUBLISHABLE_KEY: "pk_test_SECRETISH\n" }],
      ]) {
        const output = path.join(root, `public-config-${name}.json`);
        await assert.rejects(
          () => writePublicConfig({ env, output }),
          (error) => {
            assert.ok(error instanceof ReleaseError, error.stack);
            assert.doesNotMatch(error.message, /SECRETISH|fixture|relay\.fixture/);
            return true;
          },
        );
        await assert.rejects(readFile(output), { code: "ENOENT" });
      }
    });
  });

  describe("prior release selection", () => {
    const prior = (id, counter) => managedRelease({ id, version: `${UPSTREAM_VERSION}.managed.${counter}.p${"a".repeat(12)}` });

    it("selects the maximum managed version independent of order, ignoring drafts, stable releases, malformed tags, and unpublished entries", () => {
      const listing = [
        [
          managedRelease({ id: 1, version: `${UPSTREAM_VERSION}.managed.9.p${"b".repeat(12)}`, draft: true }),
          managedRelease({ id: 2, version: `${UPSTREAM_VERSION}.managed.8.p${"b".repeat(12)}`, prerelease: false }),
          { id: 3, tag_name: `${TAG_PREFIX}not-a-version`, draft: false, prerelease: true, immutable: true, published_at: "2026-09-01T00:00:00Z", assets: [] },
          { id: 4, tag_name: `v${UPSTREAM_VERSION}`, draft: false, prerelease: true, immutable: true, published_at: "2026-09-01T00:00:00Z", assets: [] },
          managedRelease({ id: 5, version: `${UPSTREAM_VERSION}.managed.7.p${"b".repeat(12)}`, published: null }),
        ],
        [prior(6, 2), prior(7, 3), prior(8, 1), { id: 9, tag_name: `${TAG_PREFIX}${UPSTREAM_VERSION}.managed.3.p${"a".repeat(12)}extra`, draft: false, prerelease: true, immutable: true, published_at: "2026-09-01T00:00:00Z", assets: [] }],
      ];
      const selected = selectPriorRelease(listing);
      assert.equal(selected.releaseId, 7);
      assert.equal(selected.releaseVersion, `${UPSTREAM_VERSION}.managed.3.p${"a".repeat(12)}`);
      assert.equal(selectPriorRelease([...listing].reverse().map((page) => [...page].reverse())).releaseId, 7);
      assert.equal(selectPriorRelease([]), null);
      assert.equal(selectPriorRelease([[managedRelease({ id: 1, version: `${UPSTREAM_VERSION}.managed.1.p${"a".repeat(12)}`, draft: true })]]), null);
    });

    it("fails closed on duplicate managed versions, a mutable prior release, and malformed API data", () => {
      throwsPublish(() => selectPriorRelease([prior(1, 2), prior(2, 2)]), /both publish/);
      throwsPublish(() => selectPriorRelease([{ ...prior(1, 2), immutable: false }]), /not immutable/);
      throwsPublish(() => selectPriorRelease([{ ...prior(1, 2), immutable: undefined }]), /not immutable/);
      throwsPublish(() => selectPriorRelease([{ ...prior(1, 2), id: "1" }]), /invalid id/);
      throwsPublish(() => selectPriorRelease({ releases: [] }), /must be an array/);
      throwsPublish(() => selectPriorRelease([[prior(1, 2)], prior(2, 3)]), /mixes pages/);
    });

    it("rejects a duplicate managed version wherever it appears, independent of order and page boundaries", () => {
      throwsPublish(() => selectPriorRelease([prior(1, 3), prior(2, 2), prior(3, 2)]), /releases 2 and 3 both publish/);
      throwsPublish(() => selectPriorRelease([prior(1, 2), prior(2, 3), prior(3, 2)]), /releases 1 and 3 both publish/);
      throwsPublish(() => selectPriorRelease([[prior(1, 3), prior(2, 2)], [prior(3, 2)]]), /both publish/);
      throwsPublish(() => selectPriorRelease([[prior(1, 2)], [prior(2, 3)], [prior(3, 1), prior(4, 2)]]), /both publish/);
      // A duplicate hidden behind a draft or stable entry with the same tag is still a duplicate.
      throwsPublish(() => selectPriorRelease([prior(1, 3), prior(2, 1), prior(3, 1), managedRelease({ id: 4, version: `${UPSTREAM_VERSION}.managed.5.p${"a".repeat(12)}`, draft: true })]), /both publish/);
      assert.equal(selectPriorRelease([[prior(1, 3), prior(2, 2)], [prior(3, 1)]]).releaseId, 1);
    });

    it("rejects malformed release rows instead of skipping them, while still ignoring well-formed drafts, stable releases, malformed tags, and unpublished entries", () => {
      const version = `${UPSTREAM_VERSION}.managed.2.p${"a".repeat(12)}`;
      const malformed = [
        ["null row", [null]],
        ["string row", ["release"]],
        ["array row inside a page", [[[prior(1, 2)]]]],
        ["null row on the second page", [[prior(1, 2)], [null]]],
        ["non-string tag", [{ ...prior(1, 2), tag_name: 5 }]],
        ["missing tag", [{ ...prior(1, 2), tag_name: undefined }]],
        ["string draft on a managed tag", [{ ...prior(1, 2), draft: "false" }]],
        ["missing draft on a managed tag", [{ ...prior(1, 2), draft: undefined }]],
        ["string prerelease on a managed tag", [{ ...prior(1, 2), prerelease: "true" }]],
        ["missing prerelease on a managed tag", [{ ...prior(1, 2), prerelease: undefined }]],
        ["numeric published_at on a managed tag", [{ ...prior(1, 2), published_at: 1725148800 }]],
        ["unparseable published_at on a managed tag", [{ ...prior(1, 2), published_at: "yesterday" }]],
      ];
      for (const [label, listing] of malformed) {
        throwsPublish(() => selectPriorRelease(listing), /malformed/);
        assert.ok(true, label);
      }
      // Deliberate ignoring survives for well-formed rows.
      assert.equal(selectPriorRelease([managedRelease({ id: 1, version, draft: true })]), null);
      assert.equal(selectPriorRelease([managedRelease({ id: 1, version, prerelease: false })]), null);
      assert.equal(selectPriorRelease([managedRelease({ id: 1, version, published: null })]), null);
      assert.equal(selectPriorRelease([{ id: 1, tag_name: `${TAG_PREFIX}not-a-version`, draft: "x", prerelease: 7, immutable: false, published_at: 3, assets: [] }]), null, "a malformed tag is ignored before its other fields matter");
      assert.equal(selectPriorRelease([{ id: 1, tag_name: "v1.2.3", draft: "x", prerelease: 7, immutable: false, published_at: 3, assets: [] }]), null, "an unrelated tag is ignored");
    });

    it("downloads the unique prior manifest by asset id, requires tag/manifest agreement and exact repository trust, and hands it to the resolver", async () => {
      const priorRelease = await writeRelease(root, "prior", { releaseCounter: 1 });
      const api = fakeGitHub({ releases: [managedRelease({ id: 40, version: priorRelease.manifest.releaseVersion, manifest: priorRelease.manifest })] });
      const found = await findPriorRelease({ api });
      assert.equal(found.prior.releaseId, 40);
      assert.equal(found.prior.tag, `${TAG_PREFIX}${priorRelease.manifest.releaseVersion}`);
      assert.deepEqual(found.manifest, priorRelease.manifest);
      assert.equal(found.text, canonicalJson(priorRelease.manifest));
      assert.deepEqual(summarize(api.calls), ["GET releases?per_page=100", "GET releases/40", "GET releases/assets/400"]);
      assert.equal(api.calls[2].options.raw, true, "the manifest is downloaded by numeric asset id");
      // The resolver accepts that manifest as the prior release and requires a greater counter.
      const next = resolveManagedRelease({ lock: priorRelease.lock, upstreamVersion: UPSTREAM_VERSION, releaseCounter: 2, builderRevision: BUILDER_REVISION, publicConfig: PUBLIC_CONFIG, priorRelease: found.manifest });
      assert.equal(next.priorRelease.releaseVersion, priorRelease.manifest.releaseVersion);
      throwsPublish(
        () => resolveManagedRelease({ lock: priorRelease.lock, upstreamVersion: UPSTREAM_VERSION, releaseCounter: 1, builderRevision: BUILDER_REVISION, publicConfig: PUBLIC_CONFIG, priorRelease: found.manifest }),
        /does not increase/,
      );
      assert.equal(await findPriorRelease({ api: fakeGitHub() }), null);
    });

    it("fails closed on wrong or multiple prior manifest assets, tag/manifest disagreement, drift on re-read, and an untrusted asset location", async () => {
      const priorRelease = await writeRelease(root, "prior-bad", { releaseCounter: 1 });
      const version = priorRelease.manifest.releaseVersion;
      const otherVersion = `${UPSTREAM_VERSION}.managed.1.p${"c".repeat(12)}`;
      const cases = [
        ["no manifest asset", managedRelease({ id: 41, version, assets: [{ id: 410, name: "SHA256SUMS", bytes: "x", state: "uploaded" }] }), /exactly one managed-release.json/],
        ["two manifest assets", managedRelease({ id: 42, version, assets: [{ id: 420, name: MANIFEST_FILE, bytes: "{}", state: "uploaded" }, { id: 421, name: MANIFEST_FILE, bytes: "{}", state: "uploaded" }] }), /exactly one managed-release.json/],
        ["manifest for another version", managedRelease({ id: 43, version: otherVersion, manifest: priorRelease.manifest }), /does not equal its tag/],
        ["malformed manifest", managedRelease({ id: 44, version, assets: [{ id: 440, name: MANIFEST_FILE, bytes: "{\"schemaVersion\":1}", state: "uploaded" }] }), /not a managed release version/],
        ["tampered manifest", managedRelease({ id: 45, version, manifest: { ...priorRelease.manifest, upstreamCommit: OTHER_REVISION } }), /does not match the digest/],
        ["digest disagrees with bytes", managedRelease({ id: 46, version, assets: [{ id: 460, name: MANIFEST_FILE, bytes: canonicalJson(priorRelease.manifest), digest: `sha256:${"0".repeat(64)}`, state: "uploaded" }] }), /digest/],
        ["asset outside the repository", managedRelease({ id: 47, version, assets: [{ id: 470, name: MANIFEST_FILE, bytes: canonicalJson(priorRelease.manifest), state: "uploaded", url: "https://api.github.com/repos/other/repo/releases/assets/470" }] }), /repository/],
      ];
      for (const [label, release, pattern] of cases) {
        await rejects(() => findPriorRelease({ api: fakeGitHub({ releases: [release] }) }), pattern).catch((error) => assert.fail(`${label}: ${error.message}`));
      }
      const moved = fakeGitHub({ releases: [managedRelease({ id: 48, version, manifest: priorRelease.manifest })] });
      moved.hooks.after = (call, response) => (call.endpoint.endsWith("releases/48") ? { ...response, immutable: false } : response);
      await rejects(() => findPriorRelease({ api: moved }), /not immutable/);
      const untrusted = fakeGitHub({ releases: [managedRelease({ id: 49, version, manifest: priorRelease.manifest })] });
      untrusted.hooks.after = (call, response) => (call.endpoint.endsWith("releases/49") ? { ...response, url: "https://api.github.com/repos/other/repo/releases/49" } : response);
      await rejects(() => findPriorRelease({ api: untrusted }), /repository/);
    });

    it("revalidates the selected prior's publication identity and manifest asset metadata on reread, including a valid size", async () => {
      const priorRelease = await writeRelease(root, "prior-reread", { releaseCounter: 1 });
      const version = priorRelease.manifest.releaseVersion;
      const text = canonicalJson(priorRelease.manifest);
      const sizeCases = [
        ["missing size", { size: undefined }],
        ["string size", { size: String(Buffer.byteLength(text)) }],
        ["zero size", { size: 0 }],
        ["negative size", { size: -1 }],
        ["fractional size", { size: 1.5 }],
        ["wrong size", { size: Buffer.byteLength(text) + 1 }],
      ];
      for (const [label, override] of sizeCases) {
        const api = fakeGitHub({ releases: [managedRelease({ id: 50, version, manifest: priorRelease.manifest })] });
        api.hooks.after = (call, response) => (call.endpoint.endsWith("releases/50") ? { ...response, assets: response.assets.map((a) => ({ ...a, ...override })) } : response);
        await rejects(() => findPriorRelease({ api }), /size/).catch((error) => assert.fail(`${label}: ${error.message}`));
      }
      const rereadCases = [
        ["published_at removed", { published_at: null }, /publication/],
        ["published_at missing", { published_at: undefined }, /publication/],
        ["published_at changed", { published_at: "2026-09-02T00:00:00Z" }, /publication/],
        ["published_at malformed", { published_at: "2026-09-01" }, /publication/],
        ["draft again", { draft: true }, /no longer the published/],
        ["draft malformed", { draft: "false" }, /no longer the published/],
        ["prerelease malformed", { prerelease: "true" }, /no longer the published/],
        ["stable now", { prerelease: false }, /no longer the published/],
        ["tag moved", { tag_name: `${TAG_PREFIX}${version}x` }, /no longer the published/],
        ["asset malformed", { assets: [null] }, /malformed/],
        ["asset id malformed", { assets: [{ id: "500", name: MANIFEST_FILE, size: Buffer.byteLength(text), state: "uploaded", url: assetUrl(500) }] }, /invalid id/],
      ];
      for (const [label, override, pattern] of rereadCases) {
        const api = fakeGitHub({ releases: [managedRelease({ id: 51, version, manifest: priorRelease.manifest })] });
        api.hooks.after = (call, response) => (call.endpoint.endsWith("releases/51") ? { ...response, ...override } : response);
        await rejects(() => findPriorRelease({ api }), pattern).catch((error) => assert.fail(`${label}: ${error.message}`));
        assert.ok(!api.calls.some((c) => c.options.raw === true), `${label}: no asset bytes are downloaded from an unproven release`);
      }
      const intact = fakeGitHub({ releases: [managedRelease({ id: 52, version, manifest: priorRelease.manifest })] });
      assert.equal((await findPriorRelease({ api: intact })).prior.releaseId, 52);
    });
  });

  describe("upstream and repository preflight", () => {
    it("re-reads the official release by id and peels its tag; any drift fails", async () => {
      const record = upstreamRecord();
      const api = upstreamApi(upstreamRoutes());
      await verifyUpstreamRelease({ record, lock: first.lock, manifest: first.manifest, upstreamApi: api });
      assert.deepEqual(api.calls.map((c) => c.endpoint), [`${UPSTREAM_API_PREFIX}releases/${UPSTREAM_RELEASE_ID}`, `${UPSTREAM_API_PREFIX}git/ref/tags/v${UPSTREAM_VERSION}`]);
      await rejects(() => verifyUpstreamRelease({ record, lock: first.lock, upstreamApi: upstreamApi(upstreamRoutes({ commit: OTHER_REVISION })) }), /tag .* resolves to/);
      await rejects(() => verifyUpstreamRelease({ record, lock: first.lock, upstreamApi: upstreamApi(upstreamRoutes({ overrides: { draft: true } })) }), /no longer a published/);
      await rejects(() => verifyUpstreamRelease({ record, lock: first.lock, upstreamApi: upstreamApi(upstreamRoutes({ overrides: { prerelease: false } })) }), /no longer a published/);
      await rejects(() => verifyUpstreamRelease({ record, lock: first.lock, upstreamApi: upstreamApi(upstreamRoutes({ overrides: { published_at: "2026-09-06T00:00:00Z" } })) }), /publishedAt/);
      await rejects(() => verifyUpstreamRelease({ record, lock: first.lock, upstreamApi: upstreamApi(upstreamRoutes({ overrides: { tag_name: "v0.0.39-nightly.20260905.1290" } })) }), /tag/);
      await rejects(() => verifyUpstreamRelease({ record, lock: first.lock, upstreamApi: upstreamApi({}) }), /HTTP 404/);
      await rejects(() => verifyUpstreamRelease({ record: upstreamRecord({ commit: OTHER_REVISION }), lock: first.lock, upstreamApi: api }), /lock pins commit/);
      await rejects(() => verifyUpstreamRelease({ record: upstreamRecord({ version: "0.0.39-nightly.20260905.1290", tag: "v0.0.39-nightly.20260905.1290" }), lock: first.lock, manifest: first.manifest, upstreamApi: api }), /manifest upstreamVersion/);
      await rejects(() => verifyUpstreamRelease({ record: upstreamRecord({ repository: "other/repo" }), lock: first.lock, upstreamApi: api }), /repository must be/);
    });

    it("requires immutable releases to be enabled and the exact tag to be absent from refs and releases of every state", async () => {
      await requireImmutableReleasesEnabled(fakeGitHub({ immutable: true }).readImmutableSetting);
      await rejects(() => requireImmutableReleasesEnabled(fakeGitHub({ immutable: false }).readImmutableSetting), /immutable releases are not enabled/);
      const enabledHook = fakeGitHub();
      enabledHook.hooks.after = () => ({ enabled: "true" });
      await rejects(() => requireImmutableReleasesEnabled(enabledHook.readImmutableSetting), /immutable releases are not enabled/);
      const tag = releaseTag(first.manifest.releaseVersion);
      await requireTagAbsent(fakeGitHub(), tag);
      await requireTagAbsent(fakeGitHub({ refs: { [`${tag}-other`]: BUILDER_REVISION } }), tag);
      await rejects(() => requireTagAbsent(fakeGitHub({ refs: { [tag]: BUILDER_REVISION } }), tag), /ref refs\/tags\/.* already exists/);
      await rejects(() => requireTagAbsent(fakeGitHub({ releases: [managedRelease({ id: 1, version: first.manifest.releaseVersion, draft: true })] }), tag), /draft release 1 already uses tag/);
      await rejects(() => requireTagAbsent(fakeGitHub({ releases: [managedRelease({ id: 2, version: first.manifest.releaseVersion })] }), tag), /published release 2 already uses tag/);
      const malformed = fakeGitHub();
      malformed.hooks.after = (call, response) => (call.endpoint.includes("matching-refs") ? { refs: [] } : response);
      await rejects(() => requireTagAbsent(malformed, tag), /matching-refs/);
    });

    it("treats malformed matching-ref and release rows as invalid absence evidence and never creates a release on them", async () => {
      const tag = releaseTag(first.manifest.releaseVersion);
      const cases = [
        ["null ref", (call, response) => (call.endpoint.includes("matching-refs") ? [null] : response), /matching-refs/],
        ["string ref", (call, response) => (call.endpoint.includes("matching-refs") ? ["refs/tags/x"] : response), /matching-refs/],
        ["ref without a name", (call, response) => (call.endpoint.includes("matching-refs") ? [{ object: { sha: BUILDER_REVISION } }] : response), /matching-refs/],
        ["ref with a non-string name", (call, response) => (call.endpoint.includes("matching-refs") ? [{ ref: 7 }] : response), /matching-refs/],
        ["null release inside a page", (call, response) => (call.endpoint === RELEASES_ENDPOINT ? [[null]] : response), /releases listing/],
        ["string release inside a page", (call, response) => (call.endpoint === RELEASES_ENDPOINT ? [["release"]] : response), /releases listing/],
        ["release without a tag", (call, response) => (call.endpoint === RELEASES_ENDPOINT ? [[{ id: 5, draft: false }]] : response), /releases listing/],
        ["release with a non-string tag", (call, response) => (call.endpoint === RELEASES_ENDPOINT ? [[{ id: 5, tag_name: 5, draft: false }]] : response), /releases listing/],
        ["non-list refs", (call, response) => (call.endpoint.includes("matching-refs") ? { refs: [] } : response), /matching-refs/],
        ["non-list releases", (call, response) => (call.endpoint === RELEASES_ENDPOINT ? { releases: [] } : response), /must be an array/],
      ];
      for (const [label, after, pattern] of cases) {
        const direct = fakeGitHub();
        direct.hooks.after = after;
        await rejects(() => requireTagAbsent(direct, tag), pattern).catch((error) => assert.fail(`${label}: ${error.message}`));
        const api = fakeGitHub();
        api.hooks.after = after;
        await rejects(() => publishManagedRelease(publishOptions({ api })), pattern).catch((error) => assert.fail(`${label} via publish: ${error.message}`));
        const names = summarize(api.calls);
        assert.ok(!names.includes("POST releases"), `${label}: no release is created on invalid absence evidence`);
        assert.ok(api.calls.every((c) => c.method === "GET"), `${label}: nothing is mutated`);
        assert.equal(api.state.releases.size, 0, label);
      }
      // Well-formed rows for other tags and an empty listing remain valid absence evidence.
      const other = fakeGitHub({ refs: { [`${tag}-other`]: BUILDER_REVISION }, releases: [managedRelease({ id: 9, version: `${UPSTREAM_VERSION}.managed.1.p${"c".repeat(12)}` }), { id: 10, tag_name: "v1.0.0", draft: false, prerelease: false, immutable: false, published_at: "2026-01-01T00:00:00Z", assets: [] }] });
      await requireTagAbsent(other, tag);
    });
  });

  describe("local closure", () => {
    it("accepts exactly the six feed files with matching sizes and checksums", async () => {
      const closure = await readReleaseClosure(first.releaseDir);
      assert.equal(closure.tag, releaseTag(first.manifest.releaseVersion));
      assert.deepEqual(closure.files.map((f) => f.name), [MANIFEST_FILE, SUMS_FILE, ...first.manifest.artifacts.map((a) => a.file)]);
      for (const file of closure.files) {
        assert.deepEqual({ bytes: file.bytes, sha256: file.sha256 }, await hashFile(file.path), file.name);
        assert.equal(typeof file.contentType, "string");
      }
      assert.deepEqual(closure.manifest, first.manifest);
      validateManifest(first.manifest);
    });

    it("refuses missing, extra, symlinked, or non-regular files, a malformed manifest, and wrong checksums or sizes before any mutation", async () => {
      const base = first.releaseDir;
      const copyClosure = async (name, mutate) => {
        const dir = path.join(root, "closures", name);
        await mkdir(dir, { recursive: true });
        for (const entry of await readdir(base)) await writeFile(path.join(dir, entry), await readFile(path.join(base, entry)));
        await mutate(dir);
        return dir;
      };
      const artifact = first.manifest.artifacts[0].file;
      const cases = [
        ["missing", (dir) => rm(path.join(dir, artifact)), /missing/],
        ["extra", (dir) => writeFile(path.join(dir, "descriptor.json"), "{}"), /unexpected file/],
        ["extra-inventory", (dir) => writeFile(path.join(dir, "managed-server-linux-x64.inventory.json"), "[]"), /unexpected file/],
        ["symlink", async (dir) => { await rm(path.join(dir, artifact)); await symlink(path.join(base, artifact), path.join(dir, artifact)); }, /symbolic link/],
        ["directory", async (dir) => { await rm(path.join(dir, artifact)); await mkdir(path.join(dir, artifact)); }, /not a regular file/],
        ["manifest-json", (dir) => writeFile(path.join(dir, MANIFEST_FILE), "{not json"), /cannot parse/],
        ["manifest-shape", (dir) => writeFile(path.join(dir, MANIFEST_FILE), canonicalJson({ ...first.manifest, schemaVersion: 2 })), /schemaVersion/],
        ["manifest-digest", (dir) => writeFile(path.join(dir, MANIFEST_FILE), canonicalJson({ ...first.manifest, builderRevision: OTHER_REVISION })), /does not match the digest/],
        ["manifest-artifacts", (dir) => writeFile(path.join(dir, MANIFEST_FILE), canonicalJson({ ...first.manifest, artifacts: first.manifest.artifacts.slice(0, 3) })), /exactly four/],
        ["artifact-bytes", (dir) => writeFile(path.join(dir, artifact), "tampered"), /bytes|sha256/],
        ["artifact-size", (dir) => writeFile(path.join(dir, artifact), `${"fixture bytes for managed-nightly-darwin-arm64 in first\n".repeat(3)}x`), /bytes|sha256/],
        ["sums-tampered", async (dir) => { const sums = await readFile(path.join(dir, SUMS_FILE), "utf8"); await writeFile(path.join(dir, SUMS_FILE), sums.replace(/^[0-9a-f]{64}/m, "0".repeat(64))); }, /SHA256SUMS/],
        ["sums-short", async (dir) => { const sums = await readFile(path.join(dir, SUMS_FILE), "utf8"); await writeFile(path.join(dir, SUMS_FILE), sums.split("\n").slice(1).join("\n")); }, /SHA256SUMS/],
        ["sums-unsorted", async (dir) => { const lines = (await readFile(path.join(dir, SUMS_FILE), "utf8")).split("\n").filter(Boolean); await writeFile(path.join(dir, SUMS_FILE), `${lines.reverse().join("\n")}\n`); }, /SHA256SUMS/],
        ["sums-symlink", async (dir) => { await rm(path.join(dir, SUMS_FILE)); await symlink(path.join(base, SUMS_FILE), path.join(dir, SUMS_FILE)); }, /symbolic link/],
        ["manifest-symlink", async (dir) => { await rm(path.join(dir, MANIFEST_FILE)); await symlink(path.join(base, MANIFEST_FILE), path.join(dir, MANIFEST_FILE)); }, /symbolic link/],
        ["empty", (dir) => writeFile(path.join(dir, artifact), ""), /empty|bytes|sha256/],
      ];
      for (const [name, mutate, pattern] of cases) {
        const dir = await copyClosure(name, mutate);
        await rejects(() => readReleaseClosure(dir), pattern).catch((error) => assert.fail(`${name}: ${error.message}`));
        const api = fakeGitHub();
        await rejects(() => publishManagedRelease(publishOptions({ releaseDir: dir, api })), pattern).catch((error) => assert.fail(`${name} via publish: ${error.message}`));
        assert.deepEqual(api.calls, [], `${name}: a local closure failure reaches no API`);
      }
      await rejects(() => readReleaseClosure(path.join(root, "does-not-exist")), /release directory/);
    });
  });

  describe("publication", () => {
    it("creates a draft, uploads six files without clobber, verifies bytes, publishes, then verifies the immutable exact-tag release", async () => {
      const api = fakeGitHub();
      const upstream = upstreamApi(upstreamRoutes());
      const result = await publishManagedRelease(publishOptions({ api, upstreamApi: upstream }));
      const tag = releaseTag(first.manifest.releaseVersion);
      assert.equal(result.tag, tag);
      assert.equal(result.releaseId, 1001);
      assert.equal(result.immutable, true);
      assert.equal(result.tagCommit, BUILDER_REVISION);
      assert.deepEqual(result.assets.map((a) => a.name), [MANIFEST_FILE, SUMS_FILE, ...first.manifest.artifacts.map((a) => a.file)]);

      const names = summarize(api.calls);
      const uploads = names.filter((n) => n.startsWith("POST https://uploads.github.com/"));
      assert.equal(uploads.length, 6);
      assert.deepEqual(
        names.filter((n) => !n.startsWith("POST https://uploads.github.com/")),
        [
          "GET immutable-releases",
          `GET git/matching-refs/tags/${encodeURIComponent(tag)}`,
          "GET releases?per_page=100",
          "POST releases",
          "GET releases/1001",
          "PATCH releases/1001",
          "GET releases/1001",
          `GET releases/tags/${encodeURIComponent(tag)}`,
          `GET git/ref/tags/${encodeURIComponent(tag)}`,
        ],
      );
      // Ordering: preflight, create, six uploads, verify, publish, verify.
      const createIndex = names.indexOf("POST releases");
      const patchIndex = names.indexOf("PATCH releases/1001");
      assert.ok(api.calls.slice(createIndex + 1, createIndex + 7).every((c) => c.endpoint.startsWith("https://uploads.github.com/")));
      assert.equal(names[createIndex + 7], "GET releases/1001");
      assert.equal(patchIndex, createIndex + 8);
      const create = api.calls[createIndex].options.body;
      assert.deepEqual(create, { tag_name: tag, target_commitish: BUILDER_REVISION, name: tag, body: create.body, draft: true, prerelease: true, make_latest: "false" });
      assert.deepEqual(api.calls[patchIndex].options.body, { draft: false }, "publishing changes only draft");
      assert.deepEqual(
        api.calls.slice(createIndex + 1, createIndex + 7).map((c) => decodeURIComponent(c.endpoint.split("name=")[1])),
        [MANIFEST_FILE, SUMS_FILE, ...first.manifest.artifacts.map((a) => a.file)],
      );
      assert.ok(api.calls.every((c) => ["GET", "POST", "PATCH"].includes(c.method)), "no destructive method");
      assert.ok(api.calls.every((c) => !/clobber|force|delete/i.test(c.endpoint)));
      assert.ok(api.calls.every((c) => !JSON.stringify(c.options).includes("clobber")));
      const release = api.state.releases.get(1001);
      assert.equal(release.draft, false);
      assert.equal(release.immutable, true);
      assert.equal(api.state.refs.get(tag), BUILDER_REVISION);
      assert.equal(upstream.calls.length, 2, "upstream release and tag are re-read");
    });

    it("downloads an asset by numeric id and hashes the bytes when the API omits a digest", async () => {
      const api = fakeGitHub({ omitDigest: true });
      await publishManagedRelease(publishOptions({ api }));
      const downloads = api.calls.filter((c) => /releases\/assets\/\d+$/.test(c.endpoint) && c.options.raw === true);
      assert.equal(downloads.length, 6);
      const tampered = fakeGitHub({ omitDigest: true });
      tampered.hooks.after = (call, response) => (call.options.raw === true && call.endpoint.endsWith("/1004") ? Buffer.alloc(response.length, "x") : response);
      await rejects(() => publishManagedRelease(publishOptions({ api: tampered })), /sha256/);
      assert.ok(!summarize(tampered.calls).some((n) => n.startsWith("PATCH")), "never published");
    });

    it("refuses before creating a release when trust, the immutable setting, upstream identity, or the tag preflight fails", async () => {
      const tag = releaseTag(first.manifest.releaseVersion);
      const cases = [
        ["wrong repository", publishOptions({ repository: "kgarg2468/harbor-fork" }), /repository/],
        ["wrong ref", publishOptions({ ref: "refs/heads/feature" }), /ref/],
        ["wrong builder revision", publishOptions({ builderRevision: OTHER_REVISION }), /builderRevision/],
        ["malformed builder revision", publishOptions({ builderRevision: "abc" }), /builder revision/],
        ["immutable disabled", publishOptions({ api: fakeGitHub({ immutable: false }) }), /immutable releases are not enabled/],
        ["moved upstream tag", publishOptions({ upstreamApi: upstreamApi(upstreamRoutes({ commit: OTHER_REVISION })) }), /resolves to/],
        ["moved upstream release", publishOptions({ upstreamApi: upstreamApi(upstreamRoutes({ overrides: { id: 1 } })) }), /releaseId/],
        ["existing ref", publishOptions({ api: fakeGitHub({ refs: { [tag]: BUILDER_REVISION } }) }), /already exists/],
        ["existing draft", publishOptions({ api: fakeGitHub({ releases: [managedRelease({ id: 3, version: first.manifest.releaseVersion, draft: true })] }) }), /draft release 3 already uses tag/],
        ["existing published", publishOptions({ api: fakeGitHub({ releases: [managedRelease({ id: 4, version: first.manifest.releaseVersion })] }) }), /published release 4 already uses tag/],
        ["lock disagreement", publishOptions({ lock: { ...first.lock, commit: OTHER_REVISION } }), /lock pins commit/],
      ];
      for (const [label, options, pattern] of cases) {
        await rejects(() => publishManagedRelease(options), pattern).catch((error) => assert.fail(`${label}: ${error.message}`));
        const names = summarize(options.api.calls);
        assert.ok(!names.includes("POST releases"), `${label}: no release is created`);
        assert.ok(!names.some((n) => n.startsWith("PATCH") || n.startsWith("POST https://uploads")), `${label}: nothing is mutated`);
        assert.equal(options.api.state.releases.size, options.api.state.releases.size, label);
      }
    });

    it("never publishes and never cleans up when an upload fails or the draft drifts, leaving the draft as it is", async () => {
      const tag = releaseTag(first.manifest.releaseVersion);
      const scenarios = [
        [
          "upload failure",
          (api) => {
            api.hooks.before = (call) => {
              if (call.endpoint.startsWith("https://uploads.github.com/") && call.endpoint.endsWith("name=SHA256SUMS")) throw httpError(502, "Bad Gateway");
            };
          },
          /HTTP 502/,
        ],
        [
          "missing remote asset",
          (api) => {
            api.hooks.after = (call, response) => (call.method === "GET" && call.endpoint.endsWith("releases/1001") ? { ...response, assets: response.assets.slice(1) } : response);
          },
          /asset/,
        ],
        [
          "extra remote asset",
          (api) => {
            api.hooks.after = (call, response) =>
              call.method === "GET" && call.endpoint.endsWith("releases/1001")
                ? { ...response, assets: [...response.assets, { id: 9999, name: "descriptor.json", size: 2, state: "uploaded", digest: `sha256:${sha256("{}")}`, url: assetUrl(9999) }] }
                : response;
          },
          /asset/,
        ],
        [
          "digest mismatch",
          (api) => {
            api.hooks.after = (call, response) =>
              call.method === "GET" && call.endpoint.endsWith("releases/1001")
                ? { ...response, assets: response.assets.map((a) => (a.name === MANIFEST_FILE ? { ...a, digest: `sha256:${"1".repeat(64)}` } : a)) }
                : response;
          },
          /sha256/,
        ],
        [
          "malformed digest",
          (api) => {
            api.hooks.after = (call, response) =>
              call.method === "GET" && call.endpoint.endsWith("releases/1001") ? { ...response, assets: response.assets.map((a) => ({ ...a, digest: "md5:abc" })) } : response;
          },
          /digest/,
        ],
        [
          "size mismatch",
          (api) => {
            api.hooks.after = (call, response) =>
              call.method === "GET" && call.endpoint.endsWith("releases/1001") ? { ...response, assets: response.assets.map((a) => ({ ...a, size: a.size + 1 })) } : response;
          },
          /size/,
        ],
        [
          "asset not uploaded",
          (api) => {
            api.hooks.after = (call, response) =>
              call.method === "GET" && call.endpoint.endsWith("releases/1001") ? { ...response, assets: response.assets.map((a) => ({ ...a, state: "open" })) } : response;
          },
          /state/,
        ],
        [
          "moved draft tag",
          (api) => {
            api.hooks.before = (call, state) => {
              if (call.method === "GET" && call.endpoint.endsWith("releases/1001")) state.releases.get(1001).tag_name = `${tag}-moved`;
            };
          },
          /tag/,
        ],
        [
          "moved draft target",
          (api) => {
            api.hooks.before = (call, state) => {
              if (call.method === "GET" && call.endpoint.endsWith("releases/1001")) state.releases.get(1001).target_commitish = OTHER_REVISION;
            };
          },
          /target/,
        ],
        [
          "draft already published by someone else",
          (api) => {
            api.hooks.before = (call, state) => {
              if (call.method === "GET" && call.endpoint.endsWith("releases/1001")) state.releases.get(1001).draft = false;
            };
          },
          /draft/,
        ],
        [
          "interrupted verification",
          (api) => {
            api.hooks.before = (call) => {
              if (call.method === "GET" && call.endpoint.endsWith("releases/1001")) throw httpError(500, "Server Error");
            };
          },
          /HTTP 500/,
        ],
        [
          "creation returned another tag",
          (api) => {
            api.hooks.after = (call, response) => (call.method === "POST" && call.endpoint.endsWith("/releases") ? { ...response, tag_name: `${tag}x` } : response);
          },
          /tag/,
        ],
      ];
      for (const [label, arm, pattern] of scenarios) {
        const api = fakeGitHub();
        arm(api);
        await rejects(() => publishManagedRelease(publishOptions({ api })), pattern).catch((error) => assert.fail(`${label}: ${error.message}`));
        const names = summarize(api.calls);
        assert.ok(names.includes("POST releases"), `${label}: the draft was created`);
        assert.ok(!names.some((n) => n.startsWith("PATCH")), `${label}: the publish call never happens`);
        assert.ok(api.calls.every((c) => ["GET", "POST"].includes(c.method)), `${label}: no destructive or cleanup call`);
        const draft = api.state.releases.get(1001);
        assert.ok(draft !== undefined, `${label}: the draft is left in place`);
        assert.equal(api.state.refs.has(tag), false, `${label}: no tag was created`);
      }
    });

    it("fails after publishing when the release is not immutable or the tag does not resolve to the builder SHA, without any further mutation", async () => {
      const notImmutable = fakeGitHub();
      notImmutable.hooks.after = (call, response) => (call.method === "GET" && call.endpoint.endsWith("releases/1001") && response.draft === false ? { ...response, immutable: false } : response);
      await rejects(() => publishManagedRelease(publishOptions({ api: notImmutable })), /immutable/);
      const patches = notImmutable.calls.filter((c) => c.method === "PATCH");
      assert.equal(patches.length, 1);
      assert.ok(notImmutable.calls.slice(notImmutable.calls.indexOf(patches[0]) + 1).every((c) => c.method === "GET"), "only reads follow the publish call");

      const movedTag = fakeGitHub();
      movedTag.hooks.before = (call, state) => {
        if (call.method === "GET" && call.endpoint.includes("git/ref/tags/")) state.refs.set(releaseTag(first.manifest.releaseVersion), OTHER_REVISION);
      };
      await rejects(() => publishManagedRelease(publishOptions({ api: movedTag })), /resolves to/);

      const wrongLookup = fakeGitHub();
      wrongLookup.hooks.after = (call, response) => (call.endpoint.includes("releases/tags/") ? { ...response, id: 77 } : response);
      await rejects(() => publishManagedRelease(publishOptions({ api: wrongLookup })), /releases\/tags/);

      const unpublished = fakeGitHub();
      unpublished.hooks.after = (call, response) => (call.method === "GET" && call.endpoint.endsWith("releases/1001") && response.draft === false ? { ...response, published_at: null } : response);
      await rejects(() => publishManagedRelease(publishOptions({ api: unpublished })), /published_at/);

      const changedAssets = fakeGitHub();
      changedAssets.hooks.after = (call, response) =>
        call.method === "GET" && call.endpoint.endsWith("releases/1001") && response.draft === false ? { ...response, assets: response.assets.map((a) => ({ ...a, id: a.id + 1 })) } : response;
      await rejects(() => publishManagedRelease(publishOptions({ api: changedAssets })), /asset/);

      // The publish PATCH takes effect and then its response is lost: the
      // release may already be public. Exactly one publish call, no retry, no
      // cleanup, and a report that says the status is uncertain rather than
      // claiming the release stayed invisible.
      const lostResponse = fakeGitHub();
      lostResponse.hooks.after = (call, response) => {
        if (call.method === "PATCH") throw httpError(502, "Bad Gateway");
        return response;
      };
      await assert.rejects(
        () => publishManagedRelease(publishOptions({ api: lostResponse })),
        (error) => {
          assert.ok(error instanceof PublishError, error.stack);
          assert.match(error.message, /HTTP 502/);
          assert.match(error.message, /uncertain/);
          assert.match(error.message, /release 1001/);
          assert.doesNotMatch(error.message, /invisible|left the draft|still a draft/);
          return true;
        },
      );
      const lostPatches = lostResponse.calls.filter((c) => c.method === "PATCH");
      assert.equal(lostPatches.length, 1, "the publish call is never retried");
      assert.equal(lostResponse.calls.at(-1), lostPatches[0], "nothing follows the failed publish call");
      assert.ok(lostResponse.calls.every((c) => ["GET", "POST", "PATCH"].includes(c.method)), "no destructive or cleanup call");
      const published = lostResponse.state.releases.get(1001);
      assert.equal(published.draft, false, "the mutation did apply: the release is public");
      assert.equal(lostResponse.state.refs.get(releaseTag(first.manifest.releaseVersion)), BUILDER_REVISION, "the tag now exists and is left alone");

      // An annotated tag is peeled to the builder commit.
      const annotated = fakeGitHub();
      annotated.hooks.before = (call, state) => {
        if (call.method === "GET" && call.endpoint.includes("git/ref/tags/")) {
          const tag = releaseTag(first.manifest.releaseVersion);
          state.tagObjects.set("d".repeat(40), { sha: BUILDER_REVISION, type: "commit" });
          state.refs.set(tag, "d".repeat(40));
        }
      };
      const result = await publishManagedRelease(publishOptions({ api: annotated }));
      assert.equal(result.tagCommit, BUILDER_REVISION);
    });

    it("publishes a later release whose version was resolved against the prior manifest", async () => {
      const priorApi = fakeGitHub({ releases: [managedRelease({ id: 60, version: first.manifest.releaseVersion, manifest: first.manifest })] });
      const found = await findPriorRelease({ api: priorApi });
      const second = await writeRelease(root, "second", { releaseCounter: 2, priorRelease: found.manifest });
      assert.equal(second.descriptor.priorRelease.releaseVersion, first.manifest.releaseVersion);
      const result = await publishManagedRelease(publishOptions({ releaseDir: second.releaseDir, lock: second.lock, api: priorApi }));
      assert.equal(result.tag, releaseTag(second.manifest.releaseVersion));
      assert.notEqual(result.tag, releaseTag(first.manifest.releaseVersion));
      assert.equal(priorApi.state.releases.get(60).draft, false, "the prior release is untouched");
    });
  });

  describe("assemble", () => {
    async function writeBuilds(dir, release, mutate = async () => {}) {
      for (const artifact of release.manifest.artifacts) {
        const rowDir = path.join(dir, `${BUILD_ARTIFACT_PREFIX}${artifact.id}`);
        await mkdir(rowDir, { recursive: true });
        await writeFile(path.join(rowDir, artifact.file), await readFile(path.join(release.releaseDir, artifact.file)));
        const record = release.inventory.find((r) => r.id === artifact.id);
        await writeFile(path.join(rowDir, `${artifact.id}-${release.manifest.releaseVersion}.inventory.json`), canonicalJson(record));
      }
      await mutate(dir);
      return dir;
    }

    it("collects exactly one inventory and archive per row into a flat artifact directory and one inventory array", async () => {
      const builds = await writeBuilds(path.join(root, "builds-ok"), first);
      const artifactsDir = path.join(root, "assembled", "artifacts");
      const inventoryOutput = path.join(root, "assembled", "inventory.json");
      const records = await assembleBuilds({ buildsDir: builds, artifactsDir, inventoryOutput });
      assert.deepEqual(records.map((r) => r.id), EXPECTED_ARTIFACTS.map((a) => a.id));
      assert.deepEqual((await readdir(artifactsDir)).sort(), first.manifest.artifacts.map((a) => a.file).sort());
      assert.deepEqual(JSON.parse(await readFile(inventoryOutput, "utf8")), records);
      // The existing manifest writer accepts the assembled inputs and reproduces the same closure.
      const destination = path.join(root, "assembled", "release");
      const manifest = await writeManagedReleaseManifest({ descriptor: first.descriptor, inventory: records, artifactsDir, destination });
      assert.deepEqual(manifest, first.manifest);
      await rejects(() => assembleBuilds({ buildsDir: builds, artifactsDir, inventoryOutput }), /already exists/);
    });

    it("refuses a missing row, an extra file, two inventories, a foreign inventory, and a mismatched archive name", async () => {
      const row = `${BUILD_ARTIFACT_PREFIX}managed-server-linux-x64`;
      const version = first.manifest.releaseVersion;
      const cases = [
        ["missing row", (dir) => rm(path.join(dir, row), { recursive: true }), /missing/],
        ["extra file", (dir) => writeFile(path.join(dir, row, "build.log"), "log"), /exactly one/],
        ["two inventories", (dir) => writeFile(path.join(dir, row, `managed-server-linux-x64-other.inventory.json`), "{}"), /exactly one/],
        ["foreign inventory", async (dir) => {
          const file = path.join(dir, row, `managed-server-linux-x64-${version}.inventory.json`);
          await writeFile(file, canonicalJson({ ...JSON.parse(await readFile(file, "utf8")), id: "managed-server-darwin-arm64" }));
        }, /names artifact/],
        ["mismatched archive", async (dir) => {
          const file = path.join(dir, row, `managed-server-linux-x64-${version}.inventory.json`);
          await writeFile(file, canonicalJson({ ...JSON.parse(await readFile(file, "utf8")), file: "other.tar.gz" }));
        }, /archive/],
        ["symlinked archive", async (dir) => {
          const file = path.join(dir, row, `managed-server-linux-x64-${version}.tar.gz`);
          await rm(file);
          await symlink(path.join(first.releaseDir, `managed-server-linux-x64-${version}.tar.gz`), file);
        }, /symbolic link/],
      ];
      for (const [label, mutate, pattern] of cases) {
        const builds = await writeBuilds(path.join(root, "builds-bad", label.replace(/ /g, "-")), first, mutate);
        const out = path.join(root, "builds-bad", `${label.replace(/ /g, "-")}-out`);
        await rejects(() => assembleBuilds({ buildsDir: builds, artifactsDir: path.join(out, "artifacts"), inventoryOutput: path.join(out, "inventory.json") }), pattern).catch((error) => assert.fail(`${label}: ${error.message}`));
        await assert.rejects(readFile(path.join(out, "inventory.json")), { code: "ENOENT" }, `${label}: no inventory written`);
      }
    });
  });

  describe("CLI", () => {
    it("parses each subcommand and refuses unknown or repeated flags", () => {
      assert.deepEqual(parseArgs(["public-config", "--output", "/tmp/c.json"]).command, "public-config");
      assert.equal(parseArgs(["prior", "--output", "/tmp/p.json", "--github-output", "/tmp/o"]).options.githubOutput, "/tmp/o");
      assert.equal(parseArgs(["preflight", "--release-version", "1.2.3-nightly.20260905.1.managed.1.p000000000000"]).options.releaseVersion, "1.2.3-nightly.20260905.1.managed.1.p000000000000");
      assert.equal(parseArgs(["verify-upstream", "--lock", "l", "--upstream-release", "u"]).options.lock, path.resolve("l"));
      assert.equal(parseArgs(["assemble", "--builds", "b", "--artifacts", "a", "--inventory", "i"]).options.inventory, path.resolve("i"));
      const publish = parseArgs(["publish", "--release-dir", "r", "--lock", "l", "--upstream-release", "u", "--repository", HARBOR_REPOSITORY, "--ref", TRUSTED_REF, "--builder-revision", BUILDER_REVISION]);
      assert.equal(publish.options.builderRevision, BUILDER_REVISION);
      throwsPublish(() => parseArgs([]), /subcommand/);
      throwsPublish(() => parseArgs(["delete"]), /unknown subcommand/);
      throwsPublish(() => parseArgs(["prior"]), /--output is required/);
      throwsPublish(() => parseArgs(["prior", "--output", "a", "--output", "b"]), /more than once/);
      throwsPublish(() => parseArgs(["prior", "--output", "a", "--tag", "x"]), /unknown argument/);
      throwsPublish(() => parseArgs(["publish", "--release-dir", "r"]), /is required/);
      throwsPublish(() => parseArgs(["prior", "--output"]), /requires a value/);
    });

    it("public-config writes the file from the environment and emits only the fingerprint", async () => {
      const output = path.join(root, "cli-public-config.json");
      const ghOutput = path.join(root, "cli-public-config.out");
      const env = { PATH: process.env.PATH, ...PUBLIC_CONFIG };
      const ok = await cli(["public-config", "--output", output, "--github-output", ghOutput], { env });
      assert.equal(ok.code, 0, ok.stderr);
      assert.equal(await readFile(ghOutput, "utf8"), `public_config_sha256=${first.descriptor.publicConfig.sha256}\n`);
      for (const value of Object.values(PUBLIC_CONFIG)) assert.ok(!(ok.stdout + ok.stderr).includes(value));
      const missing = await cli(["public-config", "--output", `${output}.2`], { env: { PATH: process.env.PATH, ...PUBLIC_CONFIG, T3CODE_RELAY_URL: "" } });
      assert.notEqual(missing.code, 0);
      assert.match(missing.stderr, /T3CODE_RELAY_URL/);
      for (const value of Object.values(PUBLIC_CONFIG)) assert.ok(!(missing.stdout + missing.stderr).includes(value));
    });

    it("assemble runs end to end and importing the module does not run main", async () => {
      const builds = path.join(root, "cli-builds");
      for (const artifact of first.manifest.artifacts) {
        const rowDir = path.join(builds, `${BUILD_ARTIFACT_PREFIX}${artifact.id}`);
        await mkdir(rowDir, { recursive: true });
        await writeFile(path.join(rowDir, artifact.file), await readFile(path.join(first.releaseDir, artifact.file)));
        await writeFile(path.join(rowDir, `${artifact.id}-${first.manifest.releaseVersion}.inventory.json`), canonicalJson(first.inventory.find((r) => r.id === artifact.id)));
      }
      const out = path.join(root, "cli-assembled");
      const ok = await cli(["assemble", "--builds", builds, "--artifacts", path.join(out, "artifacts"), "--inventory", path.join(out, "inventory.json")]);
      assert.equal(ok.code, 0, ok.stderr);
      assert.equal(JSON.parse(await readFile(path.join(out, "inventory.json"), "utf8")).length, 4);
      const { stdout, stderr } = await execFileAsync(process.execPath, ["--input-type=module", "-e", `await import(${JSON.stringify(script)});`]);
      assert.equal(stdout + stderr, "");
    });

    it("publish refuses before any gh call when the repository, ref, or admin-read token is missing or untrusted", async () => {
      const upstreamPath = path.join(root, "cli-upstream.json");
      await writeFile(upstreamPath, canonicalJson(upstreamRecord()));
      const binDir = path.join(root, "cli-bin");
      await mkdir(binDir, { recursive: true });
      const log = path.join(root, "cli-gh.log");
      // The stub records the token gh would use and its arguments, then fails.
      await writeFile(path.join(binDir, "gh"), `#!/bin/sh\necho "token=$GH_TOKEN admin=$T3_MANAGED_RELEASE_ADMIN_READ_TOKEN args=$*" >> ${JSON.stringify(log)}\nexit 1\n`, { mode: 0o755 });
      const adminToken = "ghp_CLIADMINREADFIXTURE";
      const env = { PATH: `${binDir}:${process.env.PATH}`, GH_TOKEN: "ordinary", [ADMIN_READ_TOKEN_ENV]: adminToken };
      const args = (repository, ref) => ["publish", "--release-dir", first.releaseDir, "--lock", first.lockPath, "--upstream-release", upstreamPath, "--repository", repository, "--ref", ref, "--builder-revision", BUILDER_REVISION];
      const wrongRepo = await cli(args("kgarg2468/harbor-fork", TRUSTED_REF), { env });
      assert.notEqual(wrongRepo.code, 0);
      assert.match(wrongRepo.stderr, /repository/);
      const wrongRef = await cli(args(HARBOR_REPOSITORY, "refs/heads/feature"), { env });
      assert.notEqual(wrongRef.code, 0);
      assert.match(wrongRef.stderr, /ref/);
      const noToken = await cli(args(HARBOR_REPOSITORY, TRUSTED_REF), { env: { ...env, [ADMIN_READ_TOKEN_ENV]: undefined } });
      assert.notEqual(noToken.code, 0);
      assert.match(noToken.stderr, /T3_MANAGED_RELEASE_ADMIN_READ_TOKEN/);
      const emptyToken = await cli(args(HARBOR_REPOSITORY, TRUSTED_REF), { env: { ...env, [ADMIN_READ_TOKEN_ENV]: "" } });
      assert.notEqual(emptyToken.code, 0);
      assert.match(emptyToken.stderr, /T3_MANAGED_RELEASE_ADMIN_READ_TOKEN/);
      await assert.rejects(readFile(log), { code: "ENOENT" }, "gh is never invoked");
      // With trusted inputs the first gh call is the read-only upstream re-read
      // on the ordinary token, which the stub fails; the admin token is not in
      // that child's environment at all.
      const trusted = await cli(args(HARBOR_REPOSITORY, TRUSTED_REF), { env });
      assert.notEqual(trusted.code, 0);
      assert.ok(!(trusted.stdout + trusted.stderr).includes(adminToken), "the admin token is never printed");
      const logged = (await readFile(log, "utf8")).trim().split("\n");
      assert.equal(logged.length, 1);
      assert.equal(logged[0], "token=ordinary admin= args=api --method GET /repos/pingdotgg/t3code/releases/384223346");
    });

    it("preflight reads the immutable setting with the admin-read token as the child GH_TOKEN only, and fails closed without it", async () => {
      const binDir = path.join(root, "cli-preflight-bin");
      await mkdir(binDir, { recursive: true });
      const log = path.join(root, "cli-preflight-gh.log");
      await writeFile(path.join(binDir, "gh"), `#!/bin/sh\necho "token=$GH_TOKEN admin=$T3_MANAGED_RELEASE_ADMIN_READ_TOKEN args=$*" >> ${JSON.stringify(log)}\necho "gh: HTTP 403: Resource not accessible by integration" >&2\nexit 1\n`, { mode: 0o755 });
      const adminToken = "ghp_PREFLIGHTADMINREADFIXTURE";
      const args = ["preflight", "--release-version", first.manifest.releaseVersion];
      const missing = await cli(args, { env: { PATH: `${binDir}:${process.env.PATH}`, GH_TOKEN: "ordinary" } });
      assert.notEqual(missing.code, 0);
      assert.match(missing.stderr, /T3_MANAGED_RELEASE_ADMIN_READ_TOKEN/);
      await assert.rejects(readFile(log), { code: "ENOENT" }, "gh is never invoked without the admin-read token");
      const forbidden = await cli(args, { env: { PATH: `${binDir}:${process.env.PATH}`, GH_TOKEN: "ordinary", [ADMIN_READ_TOKEN_ENV]: adminToken } });
      assert.notEqual(forbidden.code, 0);
      assert.match(forbidden.stderr, /immutable-releases/);
      assert.match(forbidden.stderr, /HTTP 403/);
      assert.ok(!(forbidden.stdout + forbidden.stderr).includes(adminToken), "the admin token is never printed");
      const logged = (await readFile(log, "utf8")).trim().split("\n");
      assert.deepEqual(logged, [`token=${adminToken} admin= args=api --method GET ${IMMUTABLE_SETTINGS_ENDPOINT}`], "one GET on the fixed endpoint, the token only as GH_TOKEN, and nothing after the refusal");
    });
  });
});

// --- workflow structure --------------------------------------------------------

// The workflow is written in a small YAML subset: two-space indentation,
// `key: value` lines, block lists of `- key: value` mappings for the matrix,
// and literal block scalars for run steps. These helpers extract that
// structure; they are not a YAML parser.
function stripComments(text) {
  return text
    .split("\n")
    .filter((line) => !/^\s*#/.test(line))
    .join("\n");
}

function indentOf(line) {
  return line.length - line.trimStart().length;
}

// Lines of the block introduced by the first line matching `pattern`, i.e.
// every following non-blank line indented deeper than it.
function blockAfter(lines, pattern) {
  const start = lines.findIndex((line) => pattern.test(line));
  assert.notEqual(start, -1, `no line matches ${pattern}`);
  const base = indentOf(lines[start]);
  const block = [];
  for (const line of lines.slice(start + 1)) {
    if (line.trim() === "") continue;
    if (indentOf(line) <= base) break;
    block.push(line);
  }
  return { header: lines[start], block };
}

// A scalar with one layer of matching surrounding quotes removed.
function unquote(value) {
  const match = /^(["'])(.*)\1$/.exec(value);
  return match === null ? value : match[2];
}

function mapping(block, indent) {
  const out = {};
  for (const line of block) {
    if (indentOf(line) !== indent) continue;
    const match = /^\s*([A-Za-z0-9_.-]+):\s*(.*)$/.exec(line);
    if (match !== null) out[match[1]] = unquote(match[2]);
  }
  return out;
}

function listOfMappings(block) {
  const items = [];
  for (const line of block) {
    const item = /^(\s*)- ([A-Za-z0-9_.-]+):\s*(.*)$/.exec(line);
    if (item !== null) {
      items.push({ [item[2]]: unquote(item[3]) });
      continue;
    }
    const field = /^\s*([A-Za-z0-9_.-]+):\s*(.*)$/.exec(line);
    if (field !== null && items.length > 0) items.at(-1)[field[1]] = unquote(field[2]);
  }
  return items;
}

// Every `- uses: <action>` step block in a job, with its `with:` mapping.
function stepsUsing(jobBlock, action) {
  const out = [];
  jobBlock.forEach((line, index) => {
    if (!new RegExp(`uses: actions/${action}@`).test(line)) return;
    const base = indentOf(line);
    const block = [];
    for (const next of jobBlock.slice(index + 1)) {
      if (next.trim() === "") continue;
      if (indentOf(next) <= base) break;
      block.push(next);
    }
    out.push({ with: mapping(block, base + 4), lines: block });
  });
  return out;
}

// The lines of the `- name:` step whose `id:` is exactly `id`.
function stepWithId(jobBlock, id) {
  const idIndex = jobBlock.findIndex((line) => new RegExp(`^\\s+id: ${id}$`).test(line));
  assert.notEqual(idIndex, -1, `no step has id ${id}`);
  const base = indentOf(jobBlock[idIndex]) - 2;
  let start = idIndex;
  while (start > 0 && !(indentOf(jobBlock[start]) === base && /^\s*- /.test(jobBlock[start]))) start -= 1;
  const block = [];
  for (const line of jobBlock.slice(start + 1)) {
    if (line.trim() === "") continue;
    if (indentOf(line) <= base) break;
    block.push(line);
  }
  return block;
}

describe("t3-managed-release workflow", () => {
  let raw;
  let text;
  let lines;
  let jobs;
  before(async () => {
    raw = await readFile(workflowPath, "utf8");
    text = stripComments(raw);
    lines = text.split("\n");
    const jobsBlock = blockAfter(lines, /^jobs:$/).block;
    jobs = {};
    for (const line of jobsBlock) {
      const match = /^  ([a-z][a-z0-9-]*):$/.exec(line);
      if (match !== null) jobs[match[1]] = blockAfter(jobsBlock, new RegExp(`^  ${match[1]}:$`)).block;
    }
  });

  it("triggers only on trusted-main lock/provenance pushes and workflow_dispatch without inputs", () => {
    const on = blockAfter(lines, /^on:$/).block;
    const triggers = Object.keys(mapping(on, 2));
    assert.deepEqual(triggers.sort(), ["push", "workflow_dispatch"]);
    const push = blockAfter(on, /^  push:$/).block;
    assert.match(push.join("\n"), /branches:\s*\[main\]/);
    const paths = push.filter((line) => /^\s+- /.test(line)).map((line) => line.trim().slice(2).replace(/^["']|["']$/g, ""));
    assert.deepEqual(paths.sort(), ["t3-reasoning/source.lock.json", "t3-reasoning/upstream-release.json"]);
    assert.match(on.join("\n"), /^  workflow_dispatch: \{\}$/m, "workflow_dispatch takes no inputs");
    assert.doesNotMatch(text, /pull_request/);
    assert.doesNotMatch(text, /inputs\./);
    assert.doesNotMatch(text, /github\.event\.inputs/);
  });

  it("uses one fixed non-cancelling concurrency group and top-level contents: read", () => {
    const concurrency = mapping(blockAfter(lines, /^concurrency:$/).block, 2);
    assert.deepEqual(concurrency, { group: "t3-managed-release", "cancel-in-progress": "false" });
    const permissions = mapping(blockAfter(lines, /^permissions:$/).block, 2);
    assert.deepEqual(permissions, { contents: "read" });
  });

  it("defines resolve, build, and publish jobs, each gated on the repository and main ref", () => {
    assert.deepEqual(Object.keys(jobs), ["resolve", "build", "publish"]);
    for (const [name, block] of Object.entries(jobs)) {
      const job = mapping(block, 4);
      assert.ok(job.if !== undefined, `${name} has an if gate`);
      assert.match(job.if, /github\.repository == 'kgarg2468\/harbor'/, name);
      assert.match(job.if, /github\.ref == 'refs\/heads\/main'/, name);
      assert.ok(job["timeout-minutes"] !== undefined, `${name} has a timeout`);
    }
    assert.match(mapping(jobs.build, 4).needs, /resolve/);
    assert.match(mapping(jobs.publish, 4).needs, /build/);
    assert.equal(mapping(jobs.resolve, 4)["runs-on"], "ubuntu-24.04");
    assert.equal(mapping(jobs.publish, 4)["runs-on"], "ubuntu-24.04");
  });

  it("grants contents: write only to the publish job", () => {
    for (const [name, block] of Object.entries(jobs)) {
      const permissions = mapping(blockAfter(block, /^    permissions:$/).block, 6);
      assert.deepEqual(permissions, { contents: name === "publish" ? "write" : "read" }, name);
    }
    const writes = text.match(/contents: write/g) ?? [];
    assert.equal(writes.length, 1);
    assert.doesNotMatch(text, /pull-requests: write|actions: write|id-token|statuses: write|administration:/);
  });

  it("supplies the admin-read secret only to the resolve preflight and the final publish step, never as GH_TOKEN", () => {
    const secret = /\$\{\{ secrets\.T3_MANAGED_RELEASE_ADMIN_READ_TOKEN \}\}/g;
    assert.equal((text.match(secret) ?? []).length, 2);
    const uses = [...text.matchAll(/^\s+([A-Z0-9_]+): \$\{\{ secrets\.T3_MANAGED_RELEASE_ADMIN_READ_TOKEN \}\}$/gm)].map((m) => m[1]);
    assert.deepEqual(uses, [ADMIN_READ_TOKEN_ENV, ADMIN_READ_TOKEN_ENV], "the secret is exported only under its own name");
    assert.doesNotMatch(jobs.build.join("\n"), /T3_MANAGED_RELEASE_ADMIN_READ_TOKEN/);
    const preflight = stepWithId(jobs.resolve, "preflight").join("\n");
    assert.match(preflight, /T3_MANAGED_RELEASE_ADMIN_READ_TOKEN: \$\{\{ secrets\.T3_MANAGED_RELEASE_ADMIN_READ_TOKEN \}\}/);
    assert.match(preflight, /GH_TOKEN: \$\{\{ secrets\.GITHUB_TOKEN \}\}/);
    const publish = stepWithId(jobs.publish, "publish").join("\n");
    assert.match(publish, /T3_MANAGED_RELEASE_ADMIN_READ_TOKEN: \$\{\{ secrets\.T3_MANAGED_RELEASE_ADMIN_READ_TOKEN \}\}/);
    assert.match(publish, /GH_TOKEN: \$\{\{ secrets\.GITHUB_TOKEN \}\}/);
    const ghTokens = [...text.matchAll(/GH_TOKEN: (.*)$/gm)].map((m) => m[1]);
    assert.ok(ghTokens.every((value) => value === "${{ secrets.GITHUB_TOKEN }}"), "ordinary release operations stay on the workflow token");
    assert.doesNotMatch(text, /echo .*ADMIN_READ|--token|gh auth/);
  });

  it("pins every action by full commit SHA with persist-credentials: false on checkouts", () => {
    const uses = [...text.matchAll(/^\s+(?:- )?uses:\s*(\S+)/gm)].map((m) => m[1]);
    assert.ok(uses.length >= 8);
    const names = new Set();
    for (const use of uses) {
      const match = /^actions\/(checkout|setup-node|upload-artifact|download-artifact)@([0-9a-f]{40})$/.exec(use);
      assert.ok(match !== null, `${use} must be a full-SHA pin of a first-party action`);
      names.add(match[1]);
    }
    assert.deepEqual([...names].sort(), ["checkout", "download-artifact", "setup-node", "upload-artifact"]);
    const checkouts = text.match(/uses: actions\/checkout@/g).length;
    assert.equal(text.match(/persist-credentials: false/g).length, checkouts);
    assert.doesNotMatch(text, /actions\/cache|cache: |cache-dependency-path|rust-toolchain@|dtolnay/);
    assert.doesNotMatch(text, /macos-latest|ubuntu-latest/);
  });

  it("resolves once, shares one descriptor/config artifact with every row, and preflights the tag", () => {
    const resolve = jobs.resolve.join("\n");
    assert.equal((resolve.match(/resolve-managed-release\.mjs/g) ?? []).length, 1);
    assert.match(resolve, /--release-counter "\$\{GITHUB_RUN_NUMBER\}"/);
    assert.match(resolve, /--builder-revision "\$\{GITHUB_SHA\}"/);
    assert.match(resolve, /--upstream-version "\$\{UPSTREAM_VERSION\}"/);
    assert.match(resolve, /--github-output "\$\{GITHUB_OUTPUT\}"/);
    assert.match(resolve, /publish-managed-release\.mjs verify-upstream/);
    assert.match(resolve, /publish-managed-release\.mjs public-config/);
    assert.match(resolve, /publish-managed-release\.mjs prior/);
    assert.match(resolve, /publish-managed-release\.mjs preflight/);
    assert.match(resolve, /git rev-parse HEAD/);
    assert.match(resolve, /git status --porcelain/);
    for (const key of PUBLIC_CONFIG_KEYS) {
      assert.match(resolve, new RegExp(`${key}: \\$\\{\\{ vars\\.${key} \\}\\}`));
    }
    assert.doesNotMatch(resolve, /echo .*T3CODE_|cat .*public-config/);
    const uploads = blockAfter(jobs.resolve, /uses: actions\/upload-artifact@/).block;
    const upload = mapping(uploads, 10);
    assert.equal(upload.name, "t3-managed-release-inputs");
    const uploadPaths = uploads.filter((line) => indentOf(line) === 12).map((line) => line.trim());
    assert.deepEqual(uploadPaths, ["${{ runner.temp }}/release-inputs/descriptor.json", "${{ runner.temp }}/release-inputs/public-config.json"]);
    assert.equal(upload["retention-days"], "1");
    assert.equal((jobs.resolve.join("\n").match(/upload-artifact@/g) ?? []).length, 1);
    const download = mapping(blockAfter(jobs.build, /uses: actions\/download-artifact@/).block, 10);
    assert.equal(download.name, "t3-managed-release-inputs");
  });

  it("builds exactly the four static native rows with fresh preparation and one builder invocation each", () => {
    const strategy = blockAfter(jobs.build, /^    strategy:$/).block;
    assert.deepEqual(mapping(strategy, 6)["fail-fast"], "false");
    const rows = listOfMappings(blockAfter(strategy, /^        include:$/).block);
    const expected = [
      { id: "managed-server-darwin-arm64", "runs-on": "macos-15", variant: "managed-nightly", builder: "server", platform: "darwin", arch: "arm64", format: "tar.gz", rust_target: "aarch64-apple-darwin" },
      { id: "managed-server-linux-x64", "runs-on": "ubuntu-24.04", variant: "managed-nightly", builder: "server", platform: "linux", arch: "x64", format: "tar.gz", rust_target: "x86_64-unknown-linux-gnu" },
      { id: "managed-nightly-darwin-arm64", "runs-on": "macos-15", variant: "managed-nightly", builder: "desktop", platform: "darwin", arch: "arm64", format: "zip", rust_target: "aarch64-apple-darwin" },
      { id: "reasoning-darwin-arm64", "runs-on": "macos-15", variant: "reasoning", builder: "desktop", platform: "darwin", arch: "arm64", format: "zip", rust_target: "aarch64-apple-darwin" },
    ];
    assert.deepEqual(rows, expected);
    assert.deepEqual(rows.map((r) => r.id).sort(), EXPECTED_ARTIFACTS.map((a) => a.id).sort());
    assert.equal(mapping(jobs.build, 4)["runs-on"], "${{ matrix.runs-on }}");
    const build = jobs.build.join("\n");
    assert.match(build, /node-version: "24\.13\.1"/);
    assert.match(build, /npm install --global pnpm@11\.10\.0/);
    assert.match(build, /rustup toolchain install 1\.95\.0 --profile minimal/);
    assert.match(build, /rustup target add "\$\{RUST_TARGET\}" --toolchain 1\.95\.0/);
    assert.match(build, /RUST_TARGET: \$\{\{ matrix\.rust_target \}\}/);
    assert.match(build, /prepare-source\.mjs \\\n\s+--lock t3-reasoning\/source\.lock\.json \\\n\s+--variant "\$\{PREPARE_VARIANT\}" \\\n\s+--destination "\$\{RUNNER_TEMP\}\/prepared-source"/);
    assert.equal((build.match(/prepare-source\.mjs/g) ?? []).length, 1);
    assert.match(build, /build-managed-server-runtime\.mjs \\\n\s+--source "\$\{RUNNER_TEMP\}\/prepared-source" \\\n\s+--descriptor "\$\{RUNNER_TEMP\}\/release-inputs\/descriptor\.json" \\\n\s+--public-config "\$\{RUNNER_TEMP\}\/release-inputs\/public-config\.json" \\\n\s+--platform "\$\{TARGET_PLATFORM\}" --arch "\$\{TARGET_ARCH\}" \\\n\s+--destination "\$\{RUNNER_TEMP\}\/built"/);
    assert.match(build, /build-managed-desktop-runtime\.mjs \\\n\s+--source "\$\{RUNNER_TEMP\}\/prepared-source" \\\n\s+--descriptor "\$\{RUNNER_TEMP\}\/release-inputs\/descriptor\.json" \\\n\s+--public-config "\$\{RUNNER_TEMP\}\/release-inputs\/public-config\.json" \\\n\s+--variant "\$\{PREPARE_VARIANT\}" \\\n\s+--destination "\$\{RUNNER_TEMP\}\/built"/);
    assert.equal((build.match(/build-managed-server-runtime\.mjs/g) ?? []).length, 1);
    assert.equal((build.match(/build-managed-desktop-runtime\.mjs/g) ?? []).length, 1);
    assert.match(build, /builderRevision/);
    const upload = blockAfter(jobs.build, /uses: actions\/upload-artifact@/).block;
    const fields = mapping(upload, 10);
    assert.equal(fields.name, `${BUILD_ARTIFACT_PREFIX}\${{ matrix.id }}`);
    assert.equal(fields["if-no-files-found"], "error");
    const uploadPaths = upload.filter((line) => indentOf(line) === 12).map((line) => line.trim());
    assert.deepEqual(uploadPaths, ["${{ runner.temp }}/built/*.${{ matrix.format }}", "${{ runner.temp }}/built/*.inventory.json"]);
    assert.doesNotMatch(build, /--signed|codesign|notar|CSC_|APPLE_|keychain|security /);
  });

  it("assembles the six-file closure with the existing manifest writer and publishes once", () => {
    const publish = jobs.publish.join("\n");
    assert.match(publish, /git rev-parse HEAD/);
    assert.match(publish, /publish-managed-release\.mjs verify-upstream/);
    const downloads = stepsUsing(jobs.publish, "download-artifact").map((step) => step.with);
    assert.equal(downloads.length, 2);
    assert.deepEqual(downloads[0], { name: "t3-managed-release-inputs", path: "${{ runner.temp }}/release-inputs" });
    assert.deepEqual(downloads[1], { pattern: `${BUILD_ARTIFACT_PREFIX}*`, path: "${{ runner.temp }}/builds", "merge-multiple": "false" });
    assert.match(publish, /publish-managed-release\.mjs assemble \\\n\s+--builds "\$\{RUNNER_TEMP\}\/builds" \\\n\s+--artifacts "\$\{RUNNER_TEMP\}\/artifacts" \\\n\s+--inventory "\$\{RUNNER_TEMP\}\/inventory\.json"/);
    assert.match(publish, /write-managed-release-manifest\.mjs \\\n\s+--descriptor "\$\{RUNNER_TEMP\}\/release-inputs\/descriptor\.json" \\\n\s+--inventory "\$\{RUNNER_TEMP\}\/inventory\.json" \\\n\s+--artifacts "\$\{RUNNER_TEMP\}\/artifacts" \\\n\s+--destination "\$\{RUNNER_TEMP\}\/release"/);
    assert.match(publish, /publish-managed-release\.mjs publish \\\n\s+--release-dir "\$\{RUNNER_TEMP\}\/release" \\\n\s+--lock t3-reasoning\/source\.lock\.json \\\n\s+--upstream-release t3-reasoning\/upstream-release\.json \\\n\s+--repository "\$\{GITHUB_REPOSITORY\}" \\\n\s+--ref "\$\{GITHUB_REF\}" \\\n\s+--builder-revision "\$\{GITHUB_SHA\}"/);
    assert.equal((publish.match(/publish-managed-release\.mjs publish/g) ?? []).length, 1);
    assert.equal((publish.match(/write-managed-release-manifest\.mjs/g) ?? []).length, 1);
    assert.match(publish, /GH_TOKEN: \$\{\{ secrets\.GITHUB_TOKEN \}\}/);
  });

  it("contains no fork/ref/tag/platform input, force, clobber, delete, upstream binary or npm fallback, or signing step", () => {
    assert.doesNotMatch(text, /--clobber|--force|force-with-lease|\bDELETE\b|gh release delete|gh release create|gh release upload|gh release edit/);
    assert.doesNotMatch(text, /releases\/download|releases\/latest|npm install t3|npm view|npm pack|npx t3|@t3\/|homebrew|brew install/);
    assert.doesNotMatch(text, /codesign|notarytool|xcrun|APPLE_ID|CSC_LINK|keychain|--signed/);
    assert.doesNotMatch(text, /latest\.json|make_latest: "?true/);
    assert.doesNotMatch(text, /\$\{\{ github\.event\.(client_payload|inputs)/);
    assert.doesNotMatch(text, /environment:/);
  });
});
