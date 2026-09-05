// Integration test for scripts/smoke-shared.mjs. The real two-client smoke
// runs only when T3_REASONING_SERVER_BIN points at a built T3 server
// (apps/server/dist/bin.mjs). Without it the integration case is skipped and
// only the argument-handling cases run, so CI without a materialized runtime
// still exercises the entry point.
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
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

describe("smoke-shared", () => {
  it("refuses to run without --server-bin", async () => {
    const result = await cli([]);
    assert.notEqual(result.code, 0);
    assert.match(result.stderr, /--server-bin/);
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
});
