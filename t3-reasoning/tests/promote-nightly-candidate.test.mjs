import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import {
  reconcile,
  readPages,
  cleanGreptile,
  expectedMain,
} from "../scripts/promote-nightly-candidate.mjs";

test("pagination consumes all pages and rejects incomplete totals", async () => {
  assert.deepEqual(await readPages(async () => [[1], [2]], "/x"), [1, 2]);
  await assert.rejects(
    readPages(async () => [{ total_count: 2, jobs: [{}] }], "/x", "jobs"),
  );
  await assert.rejects(readPages(async () => ({ jobs: [] }), "/x", "jobs"));
});
test("Greptile requires authenticated exact clean grammar", () => {
  const check = {
    app: { id: 867647 },
    name: "Greptile Review",
    head_sha: "a".repeat(40),
    status: "completed",
    conclusion: "success",
    output: {
      annotations_count: 0,
      summary: "2 files reviewed, 0 comments added.",
    },
  };
  assert.equal(cleanGreptile(check, check.head_sha), true);
  for (const patch of [
    { app: { id: 1 } },
    { status: "queued" },
    { conclusion: "neutral" },
    { head_sha: "b".repeat(40) },
    { output: { annotations_count: 1, summary: check.output.summary } },
    {
      output: {
        annotations_count: 0,
        summary: `${check.output.summary}\nIssues found`,
      },
    },
  ])
    assert.equal(cleanGreptile({ ...check, ...patch }, check.head_sha), false);
});
test("release expected SHA rejects malformed and moved main", () => {
  const sha = "a".repeat(40);
  assert.equal(expectedMain(sha, sha), sha);
  assert.throws(() => expectedMain("", sha));
  assert.throws(() => expectedMain("b".repeat(40), sha));
});
test("wrong trusted main and malformed listing cannot mutate", async () => {
  const writes = [];
  const sha = "a".repeat(40);
  const api = async (endpoint, options = {}) => {
    if (options.method) writes.push(endpoint);
    return { object: { sha: "b".repeat(40) } };
  };
  await assert.rejects(reconcile({ api, trustedSha: sha }));
  assert.deepEqual(writes, []);
});
test("trusted workflows constrain dispatch and release SHA before checkout", async () => {
  const promote = await readFile(
    new URL(
      "../../.github/workflows/t3-managed-nightly-promote.yml",
      import.meta.url,
    ),
    "utf8",
  );
  const release = await readFile(
    new URL("../../.github/workflows/t3-managed-release.yml", import.meta.url),
    "utf8",
  );
  assert.match(promote, /8,23,38,53 \* \* \* \*/);
  assert.doesNotMatch(
    promote,
    /check_run:|pull_request_target:|ref:.*head_sha/,
  );
  assert.match(release, /run-name:.*expected_main_sha/);
  assert.ok(
    release.indexOf("Require expected main SHA") <
      release.indexOf("Check out trusted"),
  );
});

import { createHash } from "node:crypto";
const ROOT = "/repos/kgarg2468/harbor";
const MAIN = "a".repeat(40);
const HEAD = "b".repeat(40);
const MERGE = HEAD;
const UPSTREAM = "d".repeat(40);
const BOT = { id: 41898282, login: "github-actions[bot]", type: "Bot" };
const LOCK = "t3-reasoning/source.lock.json";
const PROV = "t3-reasoning/upstream-release.json";
const CHECKER = "t3-managed-nightly-candidate.yml";
const RELEASE = "t3-managed-release.yml";

async function fixture() {
  const lockText = await readFile(
    new URL("../source.lock.json", import.meta.url),
    "utf8",
  );
  const lock = JSON.parse(lockText);
  const candidateLock = lockText.replace(
    `"commit": "${lock.commit}"`,
    `"commit": "${UPSTREAM}"`,
  );
  const provenance = {
    schemaVersion: 1,
    repository: "pingdotgg/t3code",
    releaseId: 12,
    tag: "v0.0.0-nightly.20991231.1",
    version: "0.0.0-nightly.20991231.1",
    commit: UPSTREAM,
    publishedAt: "2026-09-01T00:00:00Z",
  };
  const data = new Map();
  const addBlob = (path, text) => {
    const bytes = Buffer.from(text);
    const id = createHash("sha1")
      .update(`blob ${bytes.length}\0`)
      .update(bytes)
      .digest("hex");
    data.set(`${ROOT}/git/blobs/${id}`, {
      sha: id,
      size: bytes.length,
      encoding: "base64",
      content: bytes.toString("base64"),
    });
    return { path, sha: id, mode: "100644", type: "blob" };
  };
  const oldTree = [addBlob(LOCK, lockText), addBlob("safe.txt", "safe")];
  const newTree = [
    addBlob(LOCK, candidateLock),
    addBlob(PROV, `${JSON.stringify(provenance, null, 2)}\n`),
    oldTree[1],
  ];
  const addCommit = (id, tree, parents) => {
    const treeId = createHash("sha1")
      .update(JSON.stringify(tree))
      .digest("hex");
    data.set(`${ROOT}/git/commits/${id}`, {
      sha: id,
      tree: { sha: treeId },
      parents: parents.map((sha) => ({ sha })),
    });
    data.set(`${ROOT}/git/trees/${treeId}?recursive=1`, {
      sha: treeId,
      tree,
      truncated: false,
    });
  };
  addCommit(MAIN, oldTree, []);
  addCommit(HEAD, newTree, [MAIN]);

  let current = MAIN;
  let merged = false;
  const pr = {
    number: 1,
    id: 1,
    user: BOT,
    draft: false,
    state: "open",
    merged: false,
    base: { ref: "main", sha: MAIN, repo: { full_name: "kgarg2468/harbor" } },
    head: {
      sha: HEAD,
      ref: `t3/nightly-candidate/${provenance.version}--${MAIN}`,
      repo: { full_name: "kgarg2468/harbor" },
    },
  };
  data.set(`${ROOT}/pulls/1`, pr);
  data.set(`${ROOT}/git/ref/heads/${pr.head.ref}`, {
    ref: `refs/heads/${pr.head.ref}`,
    object: { type: "commit", sha: HEAD },
  });
  data.set(`${ROOT}/compare/${MAIN}...${MAIN}`, {
    status: "identical",
    base_commit: { sha: MAIN },
    merge_base_commit: { sha: MAIN },
  });
  const published = {
    id: 12,
    tag_name: provenance.tag,
    published_at: provenance.publishedAt,
    draft: false,
    prerelease: true,
  };
  data.set("/repos/pingdotgg/t3code/releases/12", published);
  data.set("/repos/pingdotgg/t3code/releases?per_page=100", [[published]]);
  data.set(`/repos/pingdotgg/t3code/git/ref/tags/${provenance.tag}`, {
    ref: `refs/tags/${provenance.tag}`,
    object: { sha: UPSTREAM, type: "commit" },
  });
  data.set(`${ROOT}/commits/${HEAD}/statuses?per_page=100`, [
    [
      {
        id: 1,
        context: "t3-managed-nightly-candidate",
        creator: BOT,
        state: "success",
        target_url: "https://github.com/kgarg2468/harbor/actions/runs/10",
      },
    ],
  ]);
  const workflow = {
    id: 20,
    path: `.github/workflows/${CHECKER}`,
    state: "active",
  };
  data.set(`${ROOT}/actions/workflows/${CHECKER}`, workflow);
  const run = {
    id: 10,
    workflow_id: 20,
    path: workflow.path,
    event: "workflow_dispatch",
    head_branch: "main",
    head_sha: MAIN,
    repository: { full_name: "kgarg2468/harbor" },
    head_repository: { full_name: "kgarg2468/harbor" },
    status: "completed",
    conclusion: "success",
    run_attempt: 1,
  };
  data.set(`${ROOT}/actions/runs/10`, run);
  data.set(`${ROOT}/actions/runs/10/attempts/1/jobs?per_page=100`, [
    {
      total_count: 2,
      jobs: ["validate", "status"].map((name, id) => ({
        id,
        name,
        run_id: 10,
        head_sha: MAIN,
        status: "completed",
        conclusion: "success",
      })),
    },
  ]);
  const check = {
    id: 30,
    app: { id: 867647 },
    name: "Greptile Review",
    head_sha: HEAD,
    status: "completed",
    conclusion: "success",
    output: {
      annotations_count: 0,
      summary: "2 files reviewed, 0 comments added.",
    },
  };
  data.set(`${ROOT}/commits/${HEAD}/check-runs?filter=all&per_page=100`, [
    { total_count: 1, check_runs: [check] },
  ]);
  data.set(`${ROOT}/check-runs/30/annotations?per_page=100`, [[]]);
  data.set(`${ROOT}/pulls/1/comments?per_page=100`, [[]]);
  data.set(`${ROOT}/pulls/1/reviews?per_page=100`, [[]]);
  data.set(
    `${ROOT}/actions/workflows/${CHECKER}/runs?branch=main&event=workflow_dispatch&head_sha=${MAIN}&per_page=100`,
    [{ total_count: 0, workflow_runs: [] }],
  );
  data.set(
    `${ROOT}/actions/workflows/${RELEASE}/runs?branch=main&head_sha=${MERGE}&per_page=100`,
    [{ total_count: 0, workflow_runs: [] }],
  );
  const writes = [];
  const reads = new Map();
  let intercept = () => undefined;
  const api = async (endpoint, options = {}) => {
    reads.set(endpoint, (reads.get(endpoint) ?? 0) + 1);
    const override = intercept(endpoint, options, reads.get(endpoint));
    if (override !== undefined) return override;
    if (options.method) {
      writes.push({ endpoint, ...options });
      if (endpoint.endsWith("/git/refs/heads/main")) {
        current = MERGE;
        merged = true;
        Object.assign(pr, {
          state: "closed",
          merged: true,
          merged_by: BOT,
          merge_commit_sha: MERGE,
        });
        return {
          ref: "refs/heads/main",
          object: { type: "commit", sha: MERGE },
        };
      }
      return null;
    }
    if (endpoint === `${ROOT}/git/ref/heads/main`)
      return {
        ref: "refs/heads/main",
        object: { type: "commit", sha: current },
      };
    if (endpoint.startsWith(`${ROOT}/pulls?state=open`))
      return [merged ? [] : [pr]];
    if (endpoint.startsWith(`${ROOT}/pulls?state=closed`))
      return [merged ? [pr] : []];
    if (!data.has(endpoint)) throw new Error(`unexpected API ${endpoint}`);
    return structuredClone(data.get(endpoint));
  };
  return {
    api,
    data,
    pr,
    check,
    run,
    writes,
    addCommit,
    newTree,
    oldTree,
    addBlob,
    reads,
    set intercept(value) {
      intercept = value;
    },
    recover() {
      current = MERGE;
      merged = true;
      Object.assign(pr, {
        state: "closed",
        merged: true,
        merged_by: BOT,
        merge_commit_sha: MERGE,
      });
    },
    options: {
      api,
      trustedSha: MAIN,
      verifyLocal: async () => {},
      now: () => new Date("2026-09-10T00:00:00Z"),
    },
  };
}

test("safe candidate merges exact head then explicitly dispatches guarded release", async () => {
  const f = await fixture();
  const result = await reconcile(f.options);
  assert.equal(result.status, "release-dispatched", JSON.stringify(result));
  assert.deepEqual(
    f.writes.map((x) => x.body),
    [
      { sha: HEAD, force: false },
      { ref: "main", inputs: { expected_main_sha: MERGE } },
    ],
  );
});

test("unsafe candidates never merge or release", async (t) => {
  const mutations = {
    "wrong bot": (f) => {
      f.pr.user = { ...BOT, id: 2 };
    },
    draft: (f) => {
      f.pr.draft = true;
    },
    fork: (f) => {
      f.pr.head.repo.full_name = "attacker/harbor";
    },
    "base moved": (f) => {
      f.pr.base.sha = UPSTREAM;
    },
    "extra parent": (f) => f.addCommit(HEAD, f.newTree, [MAIN, UPSTREAM]),
    "off main ancestry": (f) =>
      f.data.set(`${ROOT}/compare/${MAIN}...${MAIN}`, { status: "diverged" }),
    "empty tree": (f) =>
      f.addCommit(
        HEAD,
        [
          ...f.newTree,
          { path: "hidden", sha: UPSTREAM, mode: "040000", type: "tree" },
        ],
        [MAIN],
      ),
    "extra file": (f) =>
      f.addCommit(
        HEAD,
        [...f.newTree, f.addBlob(".github/workflows/evil.yml", "run: evil")],
        [MAIN],
      ),
    symlink: (f) =>
      f.addCommit(
        HEAD,
        f.newTree.map((x) => (x.path === LOCK ? { ...x, mode: "120000" } : x)),
        [MAIN],
      ),
    "truncated tree": (f) => {
      const id = f.data.get(`${ROOT}/git/commits/${HEAD}`).tree.sha;
      f.data.get(`${ROOT}/git/trees/${id}?recursive=1`).truncated = true;
    },
    "blob corrupt": (f) => {
      const id = f.newTree[0].sha;
      f.data.get(`${ROOT}/git/blobs/${id}`).content = "ZXZpbA==";
    },
    "upstream changed": (f) => {
      f.data.get("/repos/pingdotgg/t3code/releases/12").draft = true;
    },
    "wrong app": (f) => {
      f.check.app.id = 1;
    },
    "ambiguous summary": (f) => {
      f.check.output.summary += "\nEverything looks good";
    },
    annotation: (f) => {
      f.check.output.annotations_count = 1;
    },
    "inline finding later page": (f) =>
      f.data.set(`${ROOT}/pulls/1/comments?per_page=100`, [
        [],
        [{ id: 1, body: "bug" }],
      ]),
    "changes requested": (f) =>
      f.data.set(`${ROOT}/pulls/1/reviews?per_page=100`, [
        [{ id: 1, state: "CHANGES_REQUESTED" }],
      ]),
    "latest check pending": (f) => {
      const list = f.data.get(
        `${ROOT}/commits/${HEAD}/check-runs?filter=all&per_page=100`,
      )[0];
      list.total_count++;
      list.check_runs.push({ ...f.check, id: 31, status: "in_progress" });
    },
    "truncated checks": (f) => {
      f.data.get(
        `${ROOT}/commits/${HEAD}/check-runs?filter=all&per_page=100`,
      )[0].total_count = 2;
    },
    "head moved on reread": (f) => {
      f.intercept = (endpoint, _, count) =>
        endpoint === `${ROOT}/pulls/1` && count > 1
          ? { ...f.pr, head: { ...f.pr.head, sha: UPSTREAM } }
          : undefined;
    },
    "base moved at merge": (f) => {
      f.intercept = (endpoint, _, count) =>
        endpoint === `${ROOT}/git/ref/heads/main` && count > 1
          ? {
              ref: "refs/heads/main",
              object: { type: "commit", sha: UPSTREAM },
            }
          : undefined;
    },
  };
  for (const [name, mutate] of Object.entries(mutations))
    await t.test(name, async () => {
      const f = await fixture();
      mutate(f);
      await reconcile(f.options);
      assert.deepEqual(f.writes, []);
    });
});

test("untrusted or stale checker refreshes only checker, never merges", async (t) => {
  for (const [name, mutate] of Object.entries({
    "wrong workflow": (f) => {
      f.run.workflow_id = 9;
    },
    "wrong event": (f) => {
      f.run.event = "pull_request";
    },
    "wrong revision": (f) => {
      f.run.head_sha = UPSTREAM;
    },
    "wrong job": (f) => {
      f.data.get(
        `${ROOT}/actions/runs/10/attempts/1/jobs?per_page=100`,
      )[0].jobs[0].name = "attacker";
    },
    "spoof status": (f) => {
      f.data.get(
        `${ROOT}/commits/${HEAD}/statuses?per_page=100`,
      )[0][0].creator = { ...BOT, id: 1 };
    },
  }))
    await t.test(name, async () => {
      const f = await fixture();
      mutate(f);
      await reconcile(f.options);
      assert.equal(f.writes.length, 1);
      assert.equal(
        f.writes[0].endpoint,
        `${ROOT}/actions/workflows/${CHECKER}/dispatches`,
      );
    });
});

test("merge conflicts and rejected SHA never dispatch release", async (t) => {
  for (const response of [
    { merged: false },
    { merged: true },
    new Error("409 SHA mismatch"),
  ])
    await t.test(String(response), async () => {
      const f = await fixture();
      f.intercept = (endpoint) => {
        if (endpoint.endsWith("/git/refs/heads/main")) {
          if (response instanceof Error) throw response;
          return response;
        }
      };
      await assert.rejects(reconcile(f.options));
      assert.equal(f.writes.length, 0);
    });
});

test("lost dispatch recovers current bot merge and dedupes active or successful runs", async (t) => {
  const f = await fixture();
  f.intercept = (endpoint) => {
    if (endpoint.endsWith(`${RELEASE}/dispatches`))
      throw new Error("lost dispatch");
  };
  await assert.rejects(reconcile(f.options), /lost dispatch/);
  f.intercept = () => undefined;
  const recovered = await reconcile({ ...f.options, trustedSha: MERGE });
  assert.equal(recovered.status, "release-dispatched");
  assert.equal(
    f.writes.filter((x) => x.endpoint.endsWith("/git/refs/heads/main")).length,
    1,
  );
  for (const [status, conclusion] of [
    ["queued", null],
    ["in_progress", null],
    ["completed", "success"],
  ])
    await t.test(status, async () => {
      const g = await fixture();
      g.recover();
      g.data.set(
        `${ROOT}/actions/workflows/${RELEASE}/runs?branch=main&head_sha=${MERGE}&per_page=100`,
        [
          {
            total_count: 1,
            workflow_runs: [
              {
                id: 40,
                head_sha: MERGE,
                head_branch: "main",
                repository: { full_name: "kgarg2468/harbor" },
                path: `.github/workflows/${RELEASE}`,
                event: "workflow_dispatch",
                status,
                conclusion,
              },
            ],
          },
        ],
      );
      assert.equal(
        (await reconcile({ ...g.options, trustedSha: MERGE })).status,
        "release-present",
      );
      assert.deepEqual(g.writes, []);
    });
});

test("API runner uses only gh argv and never executes candidate content", async () => {
  const { createApi } = await import(
    "../scripts/promote-nightly-candidate.mjs"
  );
  const calls = [];
  const api = createApi(async (command, args) => {
    calls.push({ command, args });
    return { stdout: "{}" };
  });
  await api(`${ROOT}/git/blobs/${HEAD}`);
  await api(`${ROOT}/actions/workflows/${RELEASE}/dispatches`, {
    method: "POST",
    body: { ref: "main", inputs: { expected_main_sha: MAIN } },
  });
  assert.ok(calls.every((call) => call.command === "gh"));
  assert.ok(calls[1].args.includes(`inputs[expected_main_sha]=${MAIN}`));
  await assert.rejects(api("/repos/attacker/repo/git/commits/main"));
});

test("candidate on later open-PR page is reconciled", async () => {
  const f = await fixture();
  f.intercept = (endpoint) =>
    endpoint.startsWith(`${ROOT}/pulls?state=open`) ? [[], [f.pr]] : undefined;
  assert.equal((await reconcile(f.options)).status, "release-dispatched");
});

test("recovery refuses a human merge, extra merged file, and superseded upstream", async (t) => {
  for (const [name, mutate] of Object.entries({
    "human merge": (f) => {
      f.pr.merged_by = { id: 1, login: "human", type: "User" };
    },
    "extra merged file": (f) =>
      f.addCommit(
        MERGE,
        [...f.newTree, f.addBlob("evil.sh", "echo evil")],
        [MAIN, HEAD],
      ),
    "superseded upstream": (f) => {
      const prior = f.data.get("/repos/pingdotgg/t3code/releases/12");
      f.data.set("/repos/pingdotgg/t3code/releases?per_page=100", [
        [prior],
        [{ ...prior, id: 13, tag_name: "v0.0.0-nightly.20991231.2" }],
      ]);
    },
  }))
    await t.test(name, async () => {
      const f = await fixture();
      f.recover();
      mutate(f);
      await assert.rejects(reconcile({ ...f.options, trustedSha: MERGE }));
      assert.deepEqual(f.writes, []);
    });
});

test("release shell guard accepts exact/manual SHA and rejects wrong SHA before checkout", async () => {
  const { execFile } = await import("node:child_process");
  const { promisify } = await import("node:util");
  const run = promisify(execFile);
  const workflow = await readFile(
    new URL("../../.github/workflows/t3-managed-release.yml", import.meta.url),
    "utf8",
  );
  const block =
    /name: Require expected main SHA before checkout[\s\S]*?        run: \|\n([\s\S]*?)\n      - name: Check out/.exec(
      workflow,
    )[1];
  const script = block
    .split("\n")
    .map((line) => line.slice(10))
    .join("\n");
  for (const expected of [MAIN, ""])
    await run("bash", ["-c", script], {
      env: { GITHUB_SHA: MAIN, EXPECTED_MAIN_SHA: expected },
    });
  for (const expected of [HEAD, "invalid", "$(false)"])
    await assert.rejects(
      run("bash", ["-c", script], {
        env: { GITHUB_SHA: MAIN, EXPECTED_MAIN_SHA: expected },
      }),
    );
});

test("concurrent divergent main advance is rejected atomically at ref write", async () => {
  const f = await fixture();
  let landed = false;
  f.intercept = (endpoint, options) => {
    if (endpoint.endsWith("/git/refs/heads/main")) {
      assert.equal(options.method, "PATCH");
      assert.equal(options.body.force, false);
      assert.equal(options.body.sha, HEAD);
      // Simulated GitHub ref CAS: current main diverged after last GET.
      throw new Error("422 Update is not a fast forward");
    }
    if (options.method) landed = true;
  };
  await assert.rejects(reconcile(f.options), /not a fast forward/);
  assert.equal(landed, false);
  assert.deepEqual(f.writes, []);
});

test("run queries exclude more than 1000 unrelated historical runs", async () => {
  const f = await fixture();
  f.recover();
  f.intercept = (endpoint) => {
    if (endpoint.includes("/runs?")) {
      if (!endpoint.includes("head_sha="))
        return [
          {
            total_count: 1001,
            workflow_runs: Array.from({ length: 1000 }, (_, id) => ({
              id,
              head_sha: UPSTREAM,
            })),
          },
        ];
      assert.match(endpoint, /head_sha=[a-f0-9]{40}/);
    }
  };
  assert.equal(
    (await reconcile({ ...f.options, trustedSha: HEAD })).status,
    "release-dispatched",
  );
});

test("lost fast-forward response recovers without another ref write", async () => {
  const f = await fixture();
  const api = async (endpoint, options) => {
    const result = await f.api(endpoint, options);
    if (endpoint.endsWith("/git/refs/heads/main"))
      throw new Error("lost ref response");
    return result;
  };
  await assert.rejects(reconcile({ ...f.options, api }), /lost ref response/);
  assert.equal(
    (await reconcile({ ...f.options, trustedSha: HEAD })).status,
    "release-dispatched",
  );
  assert.equal(
    f.writes.filter((w) => w.endpoint.endsWith("/git/refs/heads/main")).length,
    1,
  );
});

test("already-at-head reconciles delayed PR closure without another ref update", async () => {
  const f = await fixture();
  f.recover();
  Object.assign(f.pr, { state: "open", merged: false, merge_commit_sha: null });
  f.intercept = (endpoint, options) => {
    if (endpoint.startsWith(`${ROOT}/pulls?state=open`)) return [[f.pr]];
    if (endpoint === `${ROOT}/pulls/1` && options.method === "PATCH") {
      assert.deepEqual(options.body, { state: "closed" });
      f.pr.state = "closed";
      return structuredClone(f.pr);
    }
  };
  assert.equal(
    (await reconcile({ ...f.options, trustedSha: HEAD })).status,
    "release-dispatched",
  );
  assert.equal(f.pr.state, "closed");
  assert.equal(
    f.writes.filter((w) => w.endpoint.endsWith("/git/refs/heads/main")).length,
    0,
  );
});

test("run cap ambiguity on the exact SHA fails closed", async () => {
  const f = await fixture();
  f.recover();
  f.intercept = (endpoint) =>
    endpoint.includes(`${RELEASE}/runs?`)
      ? [
          {
            total_count: 1001,
            workflow_runs: Array.from({ length: 1000 }, (_, id) => ({
              id,
              head_sha: HEAD,
              status: "completed",
              conclusion: "failure",
            })),
          },
        ]
      : undefined;
  await assert.rejects(
    reconcile({ ...f.options, trustedSha: HEAD }),
    /truncated listing/,
  );
  assert.deepEqual(f.writes, []);
});

test("guarded duplicate dispatches have one counter and cannot publish twice", async () => {
  const { execFile } = await import("node:child_process");
  const { promisify } = await import("node:util");
  const { mkdtemp, rm, writeFile } = await import("node:fs/promises");
  const { tmpdir } = await import("node:os");
  const { formatManagedReleaseVersion, checkAgainstPriorRelease } =
    await import("../scripts/resolve-managed-release.mjs");
  const run = promisify(execFile);
  const workflow = await readFile(
    new URL("../../.github/workflows/t3-managed-release.yml", import.meta.url),
    "utf8",
  );
  const script =
    "set -euo pipefail\n" +
    /          # Counter blocks[\s\S]*?(?=          UPSTREAM_VERSION=)/
      .exec(workflow)[0]
      .split("\n")
      .map((line) => line.slice(10))
      .join("\n");
  const dir = await mkdtemp(`${tmpdir()}/t3-counter-`);
  try {
    await run("git", ["init", "--quiet", dir]);
    await run(
      "git",
      [
        "-c",
        "user.name=Counter Test",
        "-c",
        "user.email=counter-test@example.com",
        "-c",
        "commit.gpgsign=false",
        "commit",
        "--allow-empty",
        "--quiet",
        "-m",
        "Counter fixture",
      ],
      { cwd: dir },
    );
    const actual = (
      await run("git", ["rev-parse", "HEAD"], { cwd: dir })
    ).stdout.trim();
    const counters = [];
    for (const runNumber of ["100", "101"]) {
      await run("bash", ["-c", script], {
        cwd: dir,
        env: {
          ...process.env,
          EXPECTED_MAIN_SHA: actual,
          GITHUB_SHA: actual,
          GITHUB_RUN_NUMBER: runNumber,
          GITHUB_ENV: `${dir}/${runNumber}`,
        },
      });
      counters.push(
        Number(
          (await readFile(`${dir}/${runNumber}`, "utf8")).trim().split("=")[1],
        ),
      );
    }
    assert.equal(counters[0], counters[1]);
    assert.ok(counters[0] > 0);
    const version = "0.0.0-nightly.20991231.1";
    const releaseVersion = formatManagedReleaseVersion(
      version,
      counters[0],
      "a".repeat(64),
    );
    assert.equal(
      formatManagedReleaseVersion(version, counters[1], "a".repeat(64)),
      releaseVersion,
    );
    const first = {
      releaseVersion,
      upstreamVersion: version,
      upstreamCommit: UPSTREAM,
      releaseCounter: counters[0],
    };
    let publications = 0;
    checkAgainstPriorRelease(first, null);
    publications++;
    // Even changed config/digest cannot escape the same guarded counter.
    assert.throws(() => {
      checkAgainstPriorRelease(
        {
          ...first,
          releaseVersion: formatManagedReleaseVersion(
            version,
            counters[1],
            "b".repeat(64),
          ),
        },
        first,
      );
      publications++;
    }, /does not increase/);
    assert.equal(publications, 1);
    let previous = first;
    for (const runNumber of ["102", "103"]) {
      await run("bash", ["-c", script], {
        cwd: dir,
        env: {
          ...process.env,
          EXPECTED_MAIN_SHA: "",
          GITHUB_SHA: actual,
          GITHUB_RUN_NUMBER: runNumber,
          GITHUB_ENV: `${dir}/${runNumber}`,
        },
      });
      const counter = Number(
        (await readFile(`${dir}/${runNumber}`, "utf8")).trim().split("=")[1],
      );
      assert.equal(counter, counters[0] + Number(runNumber));
      const next = {
        ...first,
        releaseCounter: counter,
        releaseVersion: formatManagedReleaseVersion(
          version,
          counter,
          "a".repeat(64),
        ),
      };
      checkAgainstPriorRelease(next, previous);
      previous = next;
    }
    for (const runNumber of ["0", "1000000000", "-1", "01", "9e2"]) {
      await assert.rejects(
        run("bash", ["-c", script], {
          cwd: dir,
          env: {
            ...process.env,
            EXPECTED_MAIN_SHA: "",
            GITHUB_SHA: actual,
            GITHUB_RUN_NUMBER: runNumber,
            GITHUB_ENV: `${dir}/invalid`,
          },
        }),
      );
    }
    await writeFile(
      `${dir}/git`,
      '#!/bin/sh\ncase "$*" in\n"rev-parse --is-shallow-repository") echo false ;;\n"rev-parse HEAD") echo "$GITHUB_SHA" ;;\n*) echo "$FAKE_COUNT" ;;\nesac\n',
      { mode: 0o700 },
    );
    const boundedEnv = {
      ...process.env,
      PATH: `${dir}:${process.env.PATH}`,
      EXPECTED_MAIN_SHA: "",
      GITHUB_SHA: actual,
      GITHUB_RUN_NUMBER: "999999999",
      GITHUB_ENV: `${dir}/bound`,
    };
    await run("bash", ["-c", script], {
      cwd: dir,
      env: { ...boundedEnv, FAKE_COUNT: "9000000" },
    });
    const maximum = Number(
      (await readFile(`${dir}/bound`, "utf8")).trim().split("=")[1],
    );
    assert.equal(maximum, 9000000999999999);
    assert.ok(Number.isSafeInteger(maximum));
    for (const count of ["0", "9000001", "10000000", "99999999999999999999"]) {
      await assert.rejects(
        run("bash", ["-c", script], {
          cwd: dir,
          env: { ...boundedEnv, FAKE_COUNT: count },
        }),
      );
    }
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("stale and fresh candidates coexist but only fresh can write", async () => {
  const f = await fixture();
  const stale = structuredClone(f.pr);
  stale.number = 2;
  stale.id = 2;
  stale.head = {
    ...stale.head,
    sha: UPSTREAM,
    ref: `t3/nightly-candidate/0.0.0-nightly.20991231.1--${"e".repeat(40)}`,
  };
  f.data.set(`${ROOT}/pulls/2`, stale);
  f.addCommit(UPSTREAM, f.newTree, ["e".repeat(40)]);
  f.data.set(`${ROOT}/git/ref/heads/${stale.head.ref}`, {
    ref: `refs/heads/${stale.head.ref}`,
    object: { type: "commit", sha: UPSTREAM },
  });
  f.intercept = (endpoint) =>
    endpoint.startsWith(`${ROOT}/pulls?state=open`)
      ? [[stale], [f.pr]]
      : undefined;
  const result = await reconcile(f.options);
  assert.equal(result.status, "release-dispatched");
  assert.equal(result.results[0].number, 2);
  assert.equal(result.results[0].status, "pending");
  assert.match(result.results[0].reason, /directly descend/);
  assert.deepEqual(
    f.writes
      .filter((w) => w.endpoint.endsWith("/git/refs/heads/main"))
      .map((w) => w.body),
    [{ sha: HEAD, force: false }],
  );
});

test("discovery and checker bind branch version to full base SHA", async () => {
  const discovery = await readFile(
    new URL(
      "../../.github/workflows/t3-managed-nightly-discovery.yml",
      import.meta.url,
    ),
    "utf8",
  );
  const checker = await readFile(
    new URL(
      "../../.github/workflows/t3-managed-nightly-candidate.yml",
      import.meta.url,
    ),
    "utf8",
  );
  assert.match(
    discovery,
    /const branch = `\$\{branchPrefix\}\$\{provenance.version\}--\$\{baseSha\}`/,
  );
  assert.match(checker, /const branchBaseSha = branchMatch\[2\]/);
  assert.match(checker, /mergeBase !== branchBaseSha/);
});
