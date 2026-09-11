#!/usr/bin/env node
// Trusted main code only. Candidate trees/blobs are API data, never checked out
// or executed. All writes have fixed endpoints and explicit immutable identity.
import { createHash } from "node:crypto";
import {
  defaultRun,
  candidateLockText,
  validateProvenance,
  normalizeRelease,
  resolvePublishedCommit,
  selectPublishedNightly,
  UPSTREAM_REPOSITORY,
} from "./discover-upstream-nightly.mjs";
import {
  COMMIT_RE,
  compareExactVersions,
  readVerifiedLock,
  validateLock,
  isEntryPoint,
} from "./resolve-managed-release.mjs";

const REPO = "kgarg2468/harbor";
const ROOT = `/repos/${REPO}`;
const CHECKER = "t3-managed-nightly-candidate.yml";
const RELEASE = "t3-managed-release.yml";
const CONTEXT = "t3-managed-nightly-candidate";
const PREFIX = "t3/nightly-candidate/";
const LOCK = "t3-reasoning/source.lock.json";
const PROVENANCE = "t3-reasoning/upstream-release.json";
const bot = (user) =>
  user?.id === 41898282 &&
  user?.login === "github-actions[bot]" &&
  user?.type === "Bot";
const fail = (message) => {
  throw new Error(message);
};
const requireGate = (ok, message) => {
  if (!ok) fail(message);
};
const sha = (value) => typeof value === "string" && COMMIT_RE.test(value);

export function expectedMain(expected, actual) {
  requireGate(
    sha(expected) && expected === actual,
    "expected main SHA differs from workflow SHA",
  );
  return actual;
}

export function createApi(run = defaultRun) {
  return async (endpoint, { method = "GET", body, paginate = false } = {}) => {
    requireGate(
      endpoint.startsWith(`${ROOT}/`) ||
        (method === "GET" && endpoint.startsWith("/repos/pingdotgg/t3code/")),
      "unexpected API endpoint",
    );
    const args = [
      "api",
      "--method",
      method,
      ...(paginate ? ["--paginate", "--slurp"] : []),
      endpoint,
    ];
    // JSON passed as an argv field; never interpolated into a command or shell.
    if (body)
      for (const [key, value] of Object.entries(body)) {
        if (typeof value === "object")
          for (const [name, entry] of Object.entries(value))
            args.push("-f", `${key}[${name}]=${entry}`);
        else
          args.push(
            typeof value === "boolean" ? "-F" : "-f",
            `${key}=${value}`,
          );
      }
    const { stdout } = await run("gh", args, {
      env: { GH_PROMPT_DISABLED: "1", GH_NO_UPDATE_NOTIFIER: "1" },
    });
    return stdout.trim() === "" ? null : JSON.parse(stdout);
  };
}

// gh follows every Link header. Envelope totals are additionally reconciled;
// a missing page, duplicate id, API cap or malformed envelope is never absence.
export async function readPages(api, endpoint, key = null) {
  const pages = await api(endpoint, { paginate: true });
  requireGate(
    Array.isArray(pages) && pages.length > 0,
    "missing paginated response",
  );
  const rows = [];
  let total;
  for (const page of pages) {
    const list = key === null ? page : page?.[key];
    requireGate(Array.isArray(list), "malformed pagination");
    if (key !== null) {
      requireGate(
        Number.isSafeInteger(page.total_count) && page.total_count >= 0,
        "missing listing total",
      );
      total ??= page.total_count;
      requireGate(
        total === page.total_count,
        "listing moved during pagination",
      );
    }
    rows.push(...list);
  }
  if (key !== null) requireGate(rows.length === total, "truncated listing");
  const ids = rows.filter((row) => row?.id !== undefined).map((row) => row.id);
  requireGate(new Set(ids).size === ids.length, "duplicate paginated entry");
  return rows;
}

export function cleanGreptile(check, head) {
  return (
    check?.app?.id === 867647 &&
    check.name === "Greptile Review" &&
    check.head_sha === head &&
    check.status === "completed" &&
    check.conclusion === "success" &&
    check.output?.annotations_count === 0 &&
    check.output.summary === "2 files reviewed, 0 comments added."
  );
}

async function tree(api, commitSha) {
  const commit = await api(`${ROOT}/git/commits/${commitSha}`);
  requireGate(
    commit?.sha === commitSha &&
      sha(commit.tree?.sha) &&
      Array.isArray(commit.parents),
    "invalid commit",
  );
  const listing = await api(`${ROOT}/git/trees/${commit.tree.sha}?recursive=1`);
  requireGate(
    listing?.sha === commit.tree.sha &&
      listing.truncated === false &&
      Array.isArray(listing.tree),
    "truncated or invalid tree",
  );
  const map = new Map();
  const paths = new Set();
  for (const item of listing.tree) {
    requireGate(
      typeof item.path === "string" && sha(item.sha) && !paths.has(item.path),
      "invalid tree entry",
    );
    paths.add(item.path);
    if (item.type === "tree")
      requireGate(item.mode === "040000", "invalid directory mode");
    // Directory ids naturally change when their children do. Leaf objects,
    // including symlinks and submodules, remain part of the exact comparison.
    if (item.type !== "tree") map.set(item.path, item);
  }
  for (const item of listing.tree.filter((entry) => entry.type === "tree")) {
    requireGate(
      [...map.keys()].some((leaf) => leaf.startsWith(`${item.path}/`)),
      "empty or omitted directory tree",
    );
  }
  return { commit, map };
}

async function blob(api, item) {
  requireGate(
    item?.type === "blob" && item.mode === "100644",
    "candidate data is not a plain 100644 blob",
  );
  const value = await api(`${ROOT}/git/blobs/${item.sha}`);
  requireGate(
    value?.sha === item.sha &&
      value.encoding === "base64" &&
      typeof value.content === "string",
    "invalid blob",
  );
  const bytes = Buffer.from(value.content, "base64");
  requireGate(
    bytes.length === value.size && bytes.length <= 1024 * 1024,
    "invalid blob size",
  );
  const hash = createHash("sha1")
    .update(`blob ${bytes.length}\0`)
    .update(bytes)
    .digest("hex");
  requireGate(hash === item.sha, "blob digest mismatch");
  return bytes.toString("utf8");
}

async function currentMain(api) {
  const ref = await api(`${ROOT}/git/ref/heads/main`);
  requireGate(
    ref?.ref === "refs/heads/main" &&
      ref.object?.type === "commit" &&
      sha(ref.object.sha),
    "invalid main ref",
  );
  return ref.object.sha;
}

async function inspect(api, number, main, { recovery = false } = {}) {
  const pr = await api(`${ROOT}/pulls/${number}`);
  requireGate(
    pr?.number === number && bot(pr.user) && pr.draft === false,
    "not a bot-created nondraft candidate",
  );
  requireGate(
    pr.base?.repo?.full_name === REPO &&
      pr.head?.repo?.full_name === REPO &&
      pr.base.ref === "main",
    "wrong candidate repository or base",
  );
  requireGate(
    sha(pr.head.sha) &&
      typeof pr.head.ref === "string" &&
      pr.head.ref.startsWith(PREFIX),
    "invalid candidate head",
  );
  if (recovery)
    requireGate(
      pr.head.sha === main &&
        ["open", "closed"].includes(pr.state) &&
        (pr.merged !== true ||
          (bot(pr.merged_by) && pr.merge_commit_sha === main)),
      "not the current candidate fast-forward",
    );
  else {
    requireGate(
      pr.state === "open" && pr.merged === false && pr.base.sha === main,
      "candidate head/base moved or closed",
    );
    const ref = await api(`${ROOT}/git/ref/heads/${pr.head.ref}`);
    requireGate(
      ref?.ref === `refs/heads/${pr.head.ref}` &&
        ref.object?.type === "commit" &&
        ref.object.sha === pr.head.sha,
      "candidate branch moved",
    );
  }
  const head = await tree(api, pr.head.sha);
  requireGate(
    head.commit.parents.length === 1 && sha(head.commit.parents[0].sha),
    "candidate must have exactly one parent",
  );
  const parentSha = head.commit.parents[0].sha;
  let base = main;
  let mainTree;
  if (recovery) {
    mainTree = await tree(api, main);
    requireGate(
      main === pr.head.sha && mainTree.commit.parents.length === 1,
      "fast-forward ancestry does not identify candidate",
    );
    base = parentSha;
  }
  requireGate(
    parentSha === base,
    "candidate must directly descend from current main",
  );
  const ancestry = await api(`${ROOT}/compare/${parentSha}...${base}`);
  requireGate(
    ancestry?.merge_base_commit?.sha === parentSha &&
      ancestry.base_commit?.sha === parentSha &&
      ["ahead", "identical"].includes(ancestry.status),
    "candidate parent is not on main ancestry",
  );
  const parent = await tree(api, parentSha);
  const trusted = await tree(api, base);
  const paths = new Set([...parent.map.keys(), ...head.map.keys()]);
  const changed = [...paths]
    .filter(
      (p) =>
        JSON.stringify(parent.map.get(p)) !== JSON.stringify(head.map.get(p)),
    )
    .sort();
  requireGate(
    JSON.stringify(changed) === JSON.stringify([LOCK, PROVENANCE]),
    "candidate is not exact two-file change",
  );
  const lockText = await blob(api, head.map.get(LOCK));
  const lock = validateLock(JSON.parse(lockText), "candidate lock");
  requireGate(
    lock.repository === UPSTREAM_REPOSITORY,
    "wrong upstream repository",
  );
  const trustedText = await blob(api, trusted.map.get(LOCK));
  const trustedLock = validateLock(JSON.parse(trustedText), "main lock");
  requireGate(lock.commit !== trustedLock.commit, "candidate already pinned");
  for (const text of [trustedText, await blob(api, parent.map.get(LOCK))]) {
    requireGate(
      lockText === candidateLockText(text, JSON.parse(text), lock.commit),
      "lock differs beyond commit line or stale catalog",
    );
  }
  if (parent.map.has(PROVENANCE)) await blob(api, parent.map.get(PROVENANCE));
  const provenanceText = await blob(api, head.map.get(PROVENANCE));
  const provenance = validateProvenance(JSON.parse(provenanceText));
  requireGate(
    provenanceText === `${JSON.stringify(provenance, null, 2)}\n`,
    "noncanonical provenance",
  );
  requireGate(
    provenance.commit === lock.commit &&
      pr.head.ref === `${PREFIX}${provenance.version}--${parentSha}`,
    "provenance/head mismatch",
  );
  if (trusted.map.has(PROVENANCE)) {
    const previous = validateProvenance(
      JSON.parse(await blob(api, trusted.map.get(PROVENANCE))),
    );
    requireGate(
      previous.commit === trustedLock.commit &&
        compareExactVersions(provenance.version, previous.version) > 0,
      "candidate does not advance main",
    );
  }
  const published = normalizeRelease(
    await api(`/repos/pingdotgg/t3code/releases/${provenance.releaseId}`),
  );
  requireGate(
    published !== null &&
      ["releaseId", "tag", "version", "publishedAt"].every(
        (key) => published[key] === provenance[key],
      ),
    "official release differs",
  );
  requireGate(
    (await resolvePublishedCommit(provenance, api)) === provenance.commit,
    "official tag differs",
  );
  const latest = selectPublishedNightly(
    await readPages(api, "/repos/pingdotgg/t3code/releases?per_page=100"),
  );
  requireGate(
    latest.candidate.version === provenance.version &&
      latest.candidate.releaseId === provenance.releaseId,
    "candidate superseded upstream",
  );
  if (recovery) {
    // Merge must contain precisely base plus the two reviewed blobs.
    const expected = new Map(trusted.map);
    for (const p of [LOCK, PROVENANCE]) expected.set(p, head.map.get(p));
    requireGate(
      expected.size === mainTree.map.size &&
        [...expected].every(
          ([p, item]) =>
            JSON.stringify(item) === JSON.stringify(mainTree.map.get(p)),
        ),
      "merged tree differs from reviewed candidate",
    );
  }
  return { pr, base, head: pr.head.sha, provenance };
}

async function checker(api, candidate) {
  const statuses = await readPages(
    api,
    `${ROOT}/commits/${candidate.head}/statuses?per_page=100`,
  );
  const relevant = statuses
    .filter((s) => s.context === CONTEXT)
    .sort((a, b) => b.id - a.id);
  const status = relevant[0];
  if (!status || !bot(status.creator) || status.state !== "success")
    return false;
  const match = new RegExp(
    `^https://github\\.com/${REPO}/actions/runs/([1-9][0-9]*)$`,
  ).exec(status.target_url);
  if (!match) return false;
  const workflow = await api(`${ROOT}/actions/workflows/${CHECKER}`);
  const run = await api(`${ROOT}/actions/runs/${match[1]}`);
  if (
    workflow.path !== `.github/workflows/${CHECKER}` ||
    workflow.state !== "active" ||
    run.id !== Number(match[1]) ||
    run.workflow_id !== workflow.id ||
    run.path !== workflow.path ||
    run.event !== "workflow_dispatch" ||
    run.head_branch !== "main" ||
    run.head_sha !== candidate.base ||
    run.repository?.full_name !== REPO ||
    run.head_repository?.full_name !== REPO ||
    run.status !== "completed" ||
    run.conclusion !== "success"
  )
    return false;
  const jobs = await readPages(
    api,
    `${ROOT}/actions/runs/${run.id}/attempts/${run.run_attempt}/jobs?per_page=100`,
    "jobs",
  );
  return (
    jobs.length === 2 &&
    ["validate", "status"].every((name) =>
      jobs.some(
        (job) =>
          job.name === name &&
          job.run_id === run.id &&
          job.head_sha === candidate.base &&
          job.status === "completed" &&
          job.conclusion === "success",
      ),
    )
  );
}

async function review(api, candidate) {
  const checks = await readPages(
    api,
    `${ROOT}/commits/${candidate.head}/check-runs?filter=all&per_page=100`,
    "check_runs",
  );
  const latest = checks
    .filter(
      (c) =>
        c.app?.id === 867647 &&
        c.name === "Greptile Review" &&
        c.head_sha === candidate.head,
    )
    .sort((a, b) => b.id - a.id)[0];
  if (!cleanGreptile(latest, candidate.head)) return false;
  const annotations = await readPages(
    api,
    `${ROOT}/check-runs/${latest.id}/annotations?per_page=100`,
  );
  if (annotations.length !== 0) return false;
  const comments = await readPages(
    api,
    `${ROOT}/pulls/${candidate.pr.number}/comments?per_page=100`,
  );
  const reviews = await readPages(
    api,
    `${ROOT}/pulls/${candidate.pr.number}/reviews?per_page=100`,
  );
  // REST inline reviews do not expose app ids. Any inline finding or requested
  // change therefore blocks conservatively, including outdated/resolved rows.
  return (
    comments.length === 0 &&
    !reviews.some((r) => r.state === "CHANGES_REQUESTED")
  );
}

async function refreshChecker(api, candidate) {
  const runs = await readPages(
    api,
    `${ROOT}/actions/workflows/${CHECKER}/runs?branch=main&event=workflow_dispatch&head_sha=${candidate.base}&per_page=100`,
    "workflow_runs",
  );
  // Existing checker runs do not expose dispatch inputs. Any active main run
  // suppresses refresh; its linked status will authenticate the head later.
  if (
    runs.some((r) => r.head_sha === candidate.base && r.status !== "completed")
  )
    return;
  await api(`${ROOT}/actions/workflows/${CHECKER}/dispatches`, {
    method: "POST",
    body: {
      ref: "main",
      inputs: {
        pull_request_number: String(candidate.pr.number),
        head_sha: candidate.head,
      },
    },
  });
}

async function dispatchRelease(api, main) {
  const runs = await readPages(
    api,
    `${ROOT}/actions/workflows/${RELEASE}/runs?branch=main&head_sha=${main}&per_page=100`,
    "workflow_runs",
  );
  if (
    runs.some(
      (r) =>
        r.head_sha === main &&
        r.path === `.github/workflows/${RELEASE}` &&
        r.repository?.full_name === REPO &&
        r.head_branch === "main" &&
        ["push", "workflow_dispatch"].includes(r.event) &&
        (r.status !== "completed" || r.conclusion === "success"),
    )
  )
    return "release-present";
  requireGate(
    (await currentMain(api)) === main,
    "main moved before release dispatch",
  );
  await api(`${ROOT}/actions/workflows/${RELEASE}/dispatches`, {
    method: "POST",
    body: { ref: "main", inputs: { expected_main_sha: main } },
  });
  return "release-dispatched";
}

async function finishPromotion(api, number, main, results, now) {
  const candidate = await inspect(api, number, main, { recovery: true });
  requireGate(
    (await checker(api, candidate)) && (await review(api, candidate)),
    "recovery gates pending",
  );
  requireGate((await currentMain(api)) === main, "main moved during recovery");
  const fresh = await inspect(api, number, main, { recovery: true });
  requireGate(
    fresh.head === candidate.head &&
      (await checker(api, fresh)) &&
      (await review(api, fresh)),
    "recovery gates moved",
  );
  if (fresh.pr.state === "open") {
    // GitHub usually closes a PR when its commits reach the base. Reconcile
    // delayed PR bookkeeping explicitly, only after proving exact main/head.
    requireGate(
      (await currentMain(api)) === main,
      "main moved before PR close",
    );
    await api(`${ROOT}/pulls/${number}`, {
      method: "PATCH",
      body: { state: "closed" },
    });
    const closed = await api(`${ROOT}/pulls/${number}`);
    requireGate(
      closed.state === "closed" && closed.head?.sha === main,
      "PR closure pending",
    );
  }
  return {
    checkedAt: now().toISOString(),
    results,
    status: await dispatchRelease(api, main),
  };
}

export async function reconcile({
  api = createApi(),
  trustedSha = process.env.GITHUB_SHA,
  verifyLocal = async () => {
    await readVerifiedLock(LOCK);
  },
  now = () => new Date(),
} = {}) {
  const main = await currentMain(api);
  expectedMain(trustedSha, main);
  await verifyLocal();
  const results = [];
  const open = await readPages(
    api,
    `${ROOT}/pulls?state=open&base=main&per_page=100`,
  );
  for (const row of open.filter((p) => p.head?.ref?.startsWith(PREFIX))) {
    if (row.head.sha === main)
      return finishPromotion(api, row.number, main, results, now);
    let candidate;
    try {
      candidate = await inspect(api, row.number, main);
      if (!(await checker(api, candidate))) {
        requireGate(
          (await currentMain(api)) === main,
          "main moved before checker refresh",
        );
        const fresh = await inspect(api, row.number, main);
        requireGate(
          fresh.head === candidate.head,
          "head moved before checker refresh",
        );
        await refreshChecker(api, fresh);
        results.push({ number: row.number, status: "checker-pending" });
        continue;
      }
      if (!(await review(api, candidate))) {
        results.push({ number: row.number, status: "review-pending" });
        continue;
      }
      // Re-read every gate, including release/tag and both verdicts, immediately
      // before the fast-forward. GitHub rejects a divergent main atomically.
      requireGate((await currentMain(api)) === main, "main moved before merge");
      const fresh = await inspect(api, row.number, main);
      requireGate(
        fresh.head === candidate.head &&
          (await checker(api, fresh)) &&
          (await review(api, fresh)),
        "gates moved before merge",
      );
      requireGate((await currentMain(api)) === main, "main moved before merge");
    } catch (error) {
      results.push({
        number: row.number,
        status: "pending",
        reason: error.message,
      });
      continue;
    }
    // A non-force ref update is atomic: head has precisely one parent, the
    // expected main, so a concurrent divergent advance is not a fast-forward.
    // Lost responses recover from main === head, without repeating the write.
    const updated = await api(`${ROOT}/git/refs/heads/main`, {
      method: "PATCH",
      body: { sha: candidate.head, force: false },
    });
    requireGate(
      updated?.ref === "refs/heads/main" &&
        updated.object?.type === "commit" &&
        updated.object.sha === candidate.head,
      "fast-forward failed or returned a different SHA",
    );
    requireGate(
      (await currentMain(api)) === candidate.head,
      "main advanced after fast-forward",
    );
    return finishPromotion(api, row.number, candidate.head, results, now);
  }
  // A successful fast-forward followed by a lost dispatch usually has a
  // closed PR. Only the candidate at CURRENT main may recover; never older work.
  const closed = await readPages(
    api,
    `${ROOT}/pulls?state=closed&base=main&sort=updated&direction=desc&per_page=100`,
  );
  for (const row of closed.filter(
    (p) => p.head?.sha === main && p.head?.ref?.startsWith(PREFIX),
  )) {
    return finishPromotion(api, row.number, main, results, now);
  }
  return { checkedAt: now().toISOString(), results, status: "pending" };
}

if (isEntryPoint(import.meta)) {
  reconcile()
    .then((result) => console.log(JSON.stringify(result, null, 2)))
    .catch((error) => {
      console.error(`promote-nightly-candidate: ${error.message}`);
      process.exitCode = 1;
    });
}
