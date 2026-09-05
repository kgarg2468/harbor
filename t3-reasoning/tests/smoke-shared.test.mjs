// Integration test for scripts/smoke-shared.mjs. The real two-client smoke
// runs only when T3_REASONING_SERVER_BIN points at a built T3 server
// (apps/server/dist/bin.mjs). Without it the integration case is skipped and
// only the argument-handling cases run, so CI without a materialized runtime
// still exercises the entry point.
import assert from "node:assert/strict";
import { execFile, spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { mkdtemp, rm, symlink } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { describe, it } from "node:test";
import { promisify } from "node:util";

const run = promisify(execFile);
const here = path.dirname(fileURLToPath(import.meta.url));
const script = path.join(here, "..", "scripts", "smoke-shared.mjs");
const serverBin = process.env.T3_REASONING_SERVER_BIN;

// Every named check the smoke performs. The integration case asserts the
// exact list so a silently dropped check cannot pass as a green run.
const EXPECTED_CHECKS = [
  "server ready on its own port",
  "runtime state belongs to our server process",
  "two independently paired sessions",
  "both clients synchronized shell subscriptions",
  "project visible and identical on both clients",
  "thread visible and identical on both clients",
  "client 1 shell sees client 2 title change",
  "client 2 thread snapshot reads its own title change",
  "reconnected client 1 shell snapshot reads latest title",
  "reconnected client 1 thread snapshot reads latest title",
];

async function cli(args) {
  try {
    const { stdout, stderr } = await run(process.execPath, [script, ...args]);
    return { code: 0, stdout, stderr };
  } catch (error) {
    return { code: error.code, stdout: error.stdout ?? "", stderr: error.stderr ?? "" };
  }
}

// Signal 0 delivers nothing; it only reports whether the pid exists.
function isAlive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return error.code === "EPERM";
  }
}

async function waitUntil(predicate, ms, label) {
  const deadline = Date.now() + ms;
  while (!predicate()) {
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${label}`);
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
}

// Runs the CLI as a real child with an IPC channel, waits until it reports the
// server it owns, interrupts it with `signal`, and checks that it took its
// server and temp root down with it while exiting with the conventional code.
async function interruptMidRun(signal, expectedCode) {
  const child = spawn(process.execPath, [script, "--server-bin", serverBin], {
    stdio: ["ignore", "pipe", "pipe", "ipc"],
  });
  let stderr = "";
  child.stderr.on("data", (chunk) => (stderr += chunk));
  const exited = new Promise((resolve) => child.once("exit", (code) => resolve(code)));
  const owned = await Promise.race([
    new Promise((resolve) => child.once("message", resolve)),
    exited.then((code) => {
      throw new Error(`smoke exited (${code}) before reporting ownership\n${stderr}`);
    }),
  ]);
  assert.equal(typeof owned.serverPid, "number");
  assert.ok(isAlive(owned.serverPid), "owned server must be running before the signal");
  assert.ok(existsSync(owned.root), "temp root must exist before the signal");

  child.kill(signal);
  assert.equal(await exited, expectedCode, stderr);
  await waitUntil(() => !isAlive(owned.serverPid), 5_000, "owned server to exit");
  assert.equal(existsSync(owned.root), false, "temp root must be removed");
}

describe("smoke-shared", () => {
  it("refuses to run without --server-bin", async () => {
    const result = await cli([]);
    assert.notEqual(result.code, 0);
    assert.match(result.stderr, /--server-bin/);
  });

  // The entry point must run when invoked through any path that resolves to
  // the script, including symlinks and aliased temp directories such as /tmp
  // versus /private/tmp on macOS, where the argv path and the module URL differ.
  it("runs main when invoked through a symlink", async () => {
    const dir = await mkdtemp(path.join(tmpdir(), "t3-smoke-link-"));
    try {
      const link = path.join(dir, "smoke-link.mjs");
      await symlink(script, link);
      const result = await run(process.execPath, [link]).then(
        () => ({ code: 0, stderr: "" }),
        (error) => ({ code: error.code, stderr: error.stderr ?? "" }),
      );
      assert.notEqual(result.code, 0, "the symlinked entry point must execute main");
      assert.match(result.stderr, /--server-bin/);
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  });

  it("importing the module does not run main", async () => {
    const { stdout, stderr } = await run(process.execPath, ["--input-type=module", "-e", `await import(${JSON.stringify(script)});`]);
    assert.equal(stdout + stderr, "");
  });

  it("refuses a relative --server-bin", async () => {
    const result = await cli(["--server-bin", "apps/server/dist/bin.mjs"]);
    assert.notEqual(result.code, 0);
    assert.match(result.stderr, /absolute/);
  });

  it("refuses a --server-bin that does not exist", async () => {
    const result = await cli(["--server-bin", path.join(here, "does-not-exist.mjs")]);
    assert.notEqual(result.code, 0);
    assert.match(result.stderr, /does not exist|not found|ENOENT/);
  });

  it(
    "two paired clients share project, thread, title update, and reconnect state",
    { skip: serverBin ? false : "T3_REASONING_SERVER_BIN is not set", timeout: 180_000 },
    async () => {
      const { runSharedSmoke } = await import(script);
      const result = await runSharedSmoke({ serverBin, nodeBin: process.execPath });
      assert.deepEqual(
        result.checks.map((check) => check.name),
        EXPECTED_CHECKS,
        "the smoke must perform exactly the documented checks",
      );
      const failed = result.checks.filter((check) => !check.ok);
      assert.deepEqual(
        failed.map((check) => `${check.name}: ${check.detail ?? ""}`),
        [],
        "every check must pass",
      );
      assert.equal(result.passed, EXPECTED_CHECKS.length);
      assert.equal(result.failed, 0);
    },
  );

  it(
    "the CLI prints only pass/fail counts and exits zero on a green run",
    { skip: serverBin ? false : "T3_REASONING_SERVER_BIN is not set", timeout: 180_000 },
    async () => {
      const result = await cli(["--server-bin", serverBin]);
      assert.equal(result.code, 0, result.stderr);
      assert.equal(result.stdout.trim(), `shared smoke: ${EXPECTED_CHECKS.length} passed, 0 failed`);
      // No credential material may reach the terminal.
      assert.doesNotMatch(result.stdout + result.stderr, /token=|Token:|access_token|wsTicket=/i);
    },
  );

  it(
    "SIGINT mid-run stops the owned server, removes the temp root, and exits 130",
    { skip: serverBin ? false : "T3_REASONING_SERVER_BIN is not set", timeout: 180_000 },
    () => interruptMidRun("SIGINT", 130),
  );

  it(
    "SIGTERM mid-run stops the owned server, removes the temp root, and exits 143",
    { skip: serverBin ? false : "T3_REASONING_SERVER_BIN is not set", timeout: 180_000 },
    () => interruptMidRun("SIGTERM", 143),
  );
});
