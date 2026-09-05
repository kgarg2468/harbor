#!/usr/bin/env node
// Two-client shared-environment smoke against a real built T3 server.
//
// Starts one headless `t3 serve` on a private temp home and a random loopback
// port, pairs two independent clients through the real CLI pairing flow and
// OAuth token exchange, and drives the WebSocket RPC protocol directly: both
// clients subscribe to the orchestration shell, client 1 creates a project
// and thread, client 2 renames the thread, client 1 observes the rename, then
// client 1 disconnects and reconnects and reads the latest title from fresh
// snapshots. No provider turn is ever started.
//
// Usage: node smoke-shared.mjs --server-bin /abs/path/to/apps/server/dist/bin.mjs
// Prints only "shared smoke: N passed, M failed". Never prints credentials.
import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { existsSync, rmSync } from "node:fs";
import { mkdir, mkdtemp, readFile, rm } from "node:fs/promises";
import net from "node:net";
import { constants as osConstants, tmpdir } from "node:os";
import path from "node:path";

const READY_TIMEOUT_MS = 90_000;
const STEP_TIMEOUT_MS = 30_000;
const SHUTDOWN_TIMEOUT_MS = 10_000;
const CLIENT_CLOSE_TIMEOUT_MS = 5_000;
const TOKEN_SCOPE =
  "orchestration:read orchestration:operate terminal:operate review:write relay:read";

const gitEnv = {
  GIT_AUTHOR_NAME: "OPERATOR",
  GIT_AUTHOR_EMAIL: "operator@example.com",
  GIT_COMMITTER_NAME: "OPERATOR",
  GIT_COMMITTER_EMAIL: "operator@example.com",
  GIT_CONFIG_GLOBAL: "/dev/null",
  GIT_CONFIG_SYSTEM: "/dev/null",
};

/** Strips anything that looks like a credential before it can reach an error message. */
export function redact(text) {
  return String(text)
    .replace(/(token=)[^&\s"']+/gi, "$1<redacted>")
    .replace(/(Token:\s*)\S+/g, "$1<redacted>")
    .replace(/(access_token"?\s*[:=]\s*"?)[^",\s]+/gi, "$1<redacted>")
    .replace(/(wsTicket=)[^&\s"']+/gi, "$1<redacted>")
    .replace(/(Bearer\s+)\S+/g, "$1<redacted>");
}

function withTimeout(promise, ms, label) {
  let timer;
  const timeout = new Promise((_, reject) => {
    timer = setTimeout(() => reject(new Error(`timed out after ${ms}ms: ${label}`)), ms);
  });
  return Promise.race([promise, timeout]).finally(() => clearTimeout(timer));
}

function runProcess(command, args, options = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { ...options, stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => (stdout += chunk));
    child.stderr.on("data", (chunk) => (stderr += chunk));
    child.on("error", reject);
    child.on("exit", (code) => resolve({ code, stdout, stderr }));
  });
}

/** Picks a free loopback port by binding port 0 and releasing it. */
export function pickFreePort() {
  return new Promise((resolve, reject) => {
    const probe = net.createServer();
    probe.once("error", reject);
    probe.listen(0, "127.0.0.1", () => {
      const { port } = probe.address();
      probe.close((error) => (error ? reject(error) : resolve(port)));
    });
  });
}

/**
 * Starts `t3 serve` on the given port and resolves once it prints its headless
 * ready line. Resolves with the child so the caller can stop it by pid;
 * `onSpawn` hands the child over as soon as it exists so a caller's cleanup
 * can reach it even if the ready wait is cut short.
 */
export async function startServer({ nodeBin, serverBin, baseDir, workspace, port, onSpawn }) {
  const child = spawn(
    nodeBin,
    [
      serverBin,
      "serve",
      "--base-dir",
      baseDir,
      "--host",
      "127.0.0.1",
      "--port",
      String(port),
      "--no-browser",
      workspace,
    ],
    {
      cwd: workspace,
      env: { ...process.env, T3CODE_HOME: baseDir, NO_COLOR: "1" },
      stdio: ["ignore", "pipe", "pipe"],
    },
  );
  onSpawn?.(child);
  let output = "";
  const ready = new Promise((resolve, reject) => {
    const onData = (chunk) => {
      output += chunk;
      if (output.includes("T3 Code server is ready.")) {
        resolve();
      }
    };
    child.stdout.on("data", onData);
    child.stderr.on("data", onData);
    child.once("error", reject);
    child.once("exit", (code, signal) => {
      reject(
        new Error(
          `server exited before ready (code ${code}, signal ${signal}); port ${port} may be in use\n${redact(output).slice(-2000)}`,
        ),
      );
    });
  });
  try {
    await withTimeout(ready, READY_TIMEOUT_MS, "server ready line");
  } catch (error) {
    await stopServer(child);
    throw error;
  }
  return child;
}

export async function stopServer(child) {
  if (!child || child.exitCode !== null || child.signalCode !== null) {
    return;
  }
  const exited = new Promise((resolve) => child.once("exit", resolve));
  child.kill("SIGTERM");
  try {
    await withTimeout(exited, SHUTDOWN_TIMEOUT_MS, "server shutdown");
  } catch {
    child.kill("SIGKILL");
    await exited;
  }
}

/** Mints a one-time pairing token through the real `t3 pair` CLI. */
export async function mintPairingToken({ nodeBin, serverBin, baseDir, label }) {
  const result = await runProcess(
    nodeBin,
    [serverBin, "pair", "--base-dir", baseDir, "--label", label, "--ttl", "15m"],
    { env: { ...process.env, T3CODE_HOME: baseDir, NO_COLOR: "1" } },
  );
  if (result.code !== 0) {
    throw new Error(`t3 pair failed (code ${result.code})\n${redact(result.stderr).slice(-2000)}`);
  }
  const line = result.stdout.split("\n").find((entry) => entry.startsWith("Token: "));
  if (!line) {
    throw new Error("t3 pair printed no token line");
  }
  return line.slice("Token: ".length).trim();
}

async function readJson(response, label) {
  const text = await response.text();
  if (!response.ok) {
    throw new Error(`${label} failed with HTTP ${response.status}: ${redact(text).slice(0, 500)}`);
  }
  return JSON.parse(text);
}

/** Exchanges a one-time pairing token for a bearer access token. */
export async function exchangeToken({ origin, pairingToken, label }) {
  const body = new URLSearchParams({
    grant_type: "urn:ietf:params:oauth:grant-type:token-exchange",
    subject_token: pairingToken,
    subject_token_type: "urn:t3:params:oauth:token-type:environment-bootstrap",
    requested_token_type: "urn:ietf:params:oauth:token-type:access_token",
    scope: TOKEN_SCOPE,
    client_label: label,
  });
  const response = await fetch(`${origin}/oauth/token`, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body,
  });
  const result = await readJson(response, "token exchange");
  if (typeof result.access_token !== "string" || result.token_type !== "Bearer") {
    throw new Error("token exchange returned no bearer access token");
  }
  return result.access_token;
}

async function issueWebSocketTicket({ origin, accessToken }) {
  const response = await fetch(`${origin}/api/auth/websocket-ticket`, {
    method: "POST",
    headers: { authorization: `Bearer ${accessToken}` },
  });
  const result = await readJson(response, "websocket ticket");
  if (typeof result.ticket !== "string") {
    throw new Error("websocket ticket response had no ticket");
  }
  return result.ticket;
}

/**
 * Minimal Effect RPC client over one WebSocket: unary requests resolve on
 * Exit, streams deliver Chunk values to a callback and are acknowledged so the
 * server keeps sending. Keeps enough shell state to answer "what does this
 * client currently see".
 */
export async function connectClient({ origin, accessToken, label }) {
  const ticket = await issueWebSocketTicket({ origin, accessToken });
  const wsUrl = new URL("/ws", origin.replace(/^http/, "ws"));
  wsUrl.searchParams.set("wsTicket", ticket);
  wsUrl.searchParams.set("clientSurface", "web");
  wsUrl.searchParams.set("clientDeviceType", "desktop");
  wsUrl.searchParams.set("connectionMethod", "direct");
  const socket = new WebSocket(wsUrl);
  socket.binaryType = "arraybuffer";

  let nextId = 1;
  const pending = new Map();
  const streams = new Map();
  const closed = new Promise((resolve) => socket.addEventListener("close", resolve));
  const shell = { projects: new Map(), threads: new Map(), watchers: new Set() };

  const notifyShell = () => {
    for (const watcher of [...shell.watchers]) {
      if (watcher.predicate(shell)) {
        shell.watchers.delete(watcher);
        watcher.resolve();
      }
    }
  };
  const applyShellItem = (item) => {
    switch (item.kind) {
      case "snapshot":
        shell.projects.clear();
        shell.threads.clear();
        for (const project of item.snapshot.projects) shell.projects.set(project.id, project);
        for (const thread of item.snapshot.threads) shell.threads.set(thread.id, thread);
        break;
      case "project-upserted":
        shell.projects.set(item.project.id, item.project);
        break;
      case "project-removed":
        shell.projects.delete(item.projectId);
        break;
      case "thread-upserted":
        shell.threads.set(item.thread.id, item.thread);
        break;
      case "thread-removed":
        shell.threads.delete(item.threadId);
        break;
      default:
        break;
    }
    notifyShell();
  };

  let closingIntentionally = false;
  const send = (message) => socket.send(JSON.stringify(message));
  const failAll = (error) => {
    for (const entry of pending.values()) entry.reject(error);
    pending.clear();
    for (const entry of streams.values()) {
      if (closingIntentionally) entry.end();
      else entry.fail(error);
    }
    streams.clear();
  };

  socket.addEventListener("message", (event) => {
    const raw = typeof event.data === "string" ? event.data : new TextDecoder().decode(event.data);
    const message = JSON.parse(raw);
    switch (message._tag) {
      case "Exit": {
        const request = pending.get(message.requestId);
        pending.delete(message.requestId);
        const stream = streams.get(message.requestId);
        streams.delete(message.requestId);
        if (message.exit._tag === "Success") {
          request?.resolve(message.exit.value);
          stream?.end();
        } else {
          const error = new Error(
            `${request?.tag ?? stream?.tag ?? "rpc"} failed: ${redact(JSON.stringify(message.exit.cause)).slice(0, 800)}`,
          );
          request?.reject(error);
          stream?.fail(error);
        }
        break;
      }
      case "Chunk": {
        const stream = streams.get(message.requestId);
        if (stream) {
          for (const value of message.values) stream.onValue(value);
        }
        send({ _tag: "Ack", requestId: message.requestId });
        break;
      }
      case "Defect":
      case "ClientProtocolError":
        failAll(new Error(`${label}: protocol failure: ${redact(raw).slice(0, 500)}`));
        break;
      default:
        break;
    }
  });
  socket.addEventListener("error", () => failAll(new Error(`${label}: websocket error`)));
  socket.addEventListener("close", (event) =>
    failAll(new Error(`${label}: websocket closed (${event.code})`)),
  );

  try {
    await withTimeout(
      new Promise((resolve, reject) => {
        socket.addEventListener("open", resolve, { once: true });
        socket.addEventListener("error", () => reject(new Error("websocket upgrade failed")), {
          once: true,
        });
        socket.addEventListener("close", (event) => reject(new Error(`websocket closed (${event.code}) before open`)), {
          once: true,
        });
      }),
      STEP_TIMEOUT_MS,
      `${label} websocket open`,
    );
  } catch (error) {
    // A socket that never opened is not returned to anyone, so close it here
    // rather than leave a connecting handle behind.
    closingIntentionally = true;
    socket.close();
    throw error;
  }

  const request = (tag, payload) =>
    withTimeout(
      new Promise((resolve, reject) => {
        const id = String(nextId++);
        pending.set(id, { tag, resolve, reject });
        send({ _tag: "Request", id, tag, payload, headers: [] });
      }),
      STEP_TIMEOUT_MS,
      `${label} ${tag}`,
    );

  const subscribe = (tag, payload, onValue) => {
    const id = String(nextId++);
    let settle;
    const done = new Promise((resolve, reject) => {
      settle = { resolve, reject };
    });
    const synchronized = new Promise((resolve, reject) => {
      streams.set(id, {
        tag,
        onValue: (value) => {
          if (value.kind === "synchronized") resolve();
          onValue(value);
        },
        end: () => settle.resolve(),
        fail: (error) => {
          reject(error);
          settle.reject(error);
        },
      });
    });
    // Nobody is required to await `done`; a late failure must not surface as
    // an unhandled rejection that kills the run.
    done.catch(() => {});
    send({ _tag: "Request", id, tag, payload, headers: [] });
    return {
      synchronized: withTimeout(synchronized, STEP_TIMEOUT_MS, `${label} ${tag} synchronized`),
      done,
      interrupt: () => {
        if (socket.readyState === WebSocket.OPEN) send({ _tag: "Interrupt", requestId: id });
      },
    };
  };

  const waitForShell = (predicate, description) =>
    withTimeout(
      new Promise((resolve) => {
        if (predicate(shell)) {
          resolve();
          return;
        }
        shell.watchers.add({ predicate, resolve });
      }),
      STEP_TIMEOUT_MS,
      `${label} waiting for ${description}`,
    );

  return {
    label,
    request,
    subscribe,
    applyShellItem,
    waitForShell,
    shell,
    // Bounded so a peer that never completes the close handshake cannot stall
    // teardown before the server is stopped.
    close: () => {
      closingIntentionally = true;
      if (socket.readyState === WebSocket.OPEN || socket.readyState === WebSocket.CONNECTING) {
        socket.close(1000, "smoke done");
      } else if (socket.readyState === WebSocket.CLOSED) {
        return Promise.resolve();
      }
      return withTimeout(closed, CLIENT_CLOSE_TIMEOUT_MS, `${label} close`).catch(() => {});
    },
  };
}

/** Picks the first configured provider model from the server's own config. */
export function pickModelSelection(config) {
  const providers = Array.isArray(config?.providers) ? config.providers : [];
  const withModels = providers.find((provider) => provider.models?.length > 0);
  if (withModels) {
    return { instanceId: withModels.instanceId, model: withModels.models[0].slug };
  }
  const first = providers[0];
  if (first) {
    return { instanceId: first.instanceId, model: "smoke-model" };
  }
  throw new Error("server config lists no providers to build a model selection from");
}

const identityFields = (thread) => ({
  id: thread.id,
  projectId: thread.projectId,
  title: thread.title,
  modelSelection: thread.modelSelection,
  runtimeMode: thread.runtimeMode,
  interactionMode: thread.interactionMode,
  branch: thread.branch,
  worktreePath: thread.worktreePath,
  createdAt: thread.createdAt,
  updatedAt: thread.updatedAt,
});

const sameJson = (left, right) => JSON.stringify(left) === JSON.stringify(right);

/**
 * Runs the whole scenario. Returns { passed, failed, checks } where each check
 * is { name, ok, detail? }. Throws only for setup failures that prevent any
 * check from running.
 */
export async function runSharedSmoke({ serverBin, nodeBin = process.execPath }) {
  if (typeof serverBin !== "string" || !path.isAbsolute(serverBin)) {
    throw new Error("--server-bin must be an absolute path");
  }
  if (!existsSync(serverBin)) {
    throw new Error(`--server-bin does not exist: ${serverBin}`);
  }

  const checks = [];
  const check = (name, ok, detail) => {
    checks.push(detail === undefined ? { name, ok } : { name, ok, detail });
  };
  const attempt = async (name, body) => {
    try {
      const detail = await body();
      check(name, true, detail);
      return true;
    } catch (error) {
      check(name, false, redact(error instanceof Error ? error.message : String(error)));
      return false;
    }
  };

  const root = await mkdtemp(path.join(tmpdir(), "t3-shared-smoke-"));
  const baseDir = path.join(root, "home");
  const workspace = path.join(root, "workspace");
  let server;
  let client1;
  let client2;
  let client1Again;
  // If the process dies mid-run (uncaught error, SIGINT, SIGTERM), the async
  // finally below never runs. This synchronous, idempotent guard stops only
  // the server we spawned, by the pid we captured, and removes only our temp
  // root. A signal then exits with the conventional 128 + signal number.
  let cleanedUp = false;
  const cleanupSync = () => {
    if (cleanedUp) return;
    cleanedUp = true;
    try {
      server?.kill("SIGKILL");
    } catch {
      // Already gone.
    }
    rmSync(root, { recursive: true, force: true });
  };
  const onSignal = (signal) => {
    cleanupSync();
    process.exit(128 + osConstants.signals[signal]);
  };
  process.once("exit", cleanupSync);
  process.on("SIGINT", onSignal);
  process.on("SIGTERM", onSignal);
  try {
    await mkdir(baseDir, { recursive: true });
    await mkdir(workspace, { recursive: true });
    const init = await runProcess("git", ["-c", "init.defaultBranch=main", "init", "-q"], {
      cwd: workspace,
      env: { ...process.env, ...gitEnv },
    });
    if (init.code !== 0) {
      throw new Error(`git init failed: ${init.stderr}`);
    }

    const port = await pickFreePort();
    const origin = `http://127.0.0.1:${port}`;

    const serverOk = await attempt("server ready on its own port", async () => {
      await startServer({
        nodeBin,
        serverBin,
        baseDir,
        workspace,
        port,
        onSpawn: (child) => {
          server = child;
        },
      });
      const descriptor = await fetch(`${origin}/.well-known/t3/environment`);
      if (!descriptor.ok) {
        throw new Error(`descriptor probe returned HTTP ${descriptor.status}`);
      }
    });
    if (!serverOk) {
      return summarize(checks);
    }
    // When a parent spawned us with an IPC channel (the regression tests do),
    // tell it which server and temp root we own, then release the channel so
    // it cannot keep this process alive.
    if (typeof process.send === "function") {
      process.send({ type: "owned", serverPid: server.pid, root }, () => process.disconnect());
    }

    await attempt("runtime state belongs to our server process", async () => {
      const statePath = path.join(baseDir, "userdata", "server-runtime.json");
      const state = JSON.parse(await readFile(statePath, "utf8"));
      if (state.pid !== server.pid) {
        throw new Error(`runtime state pid ${state.pid} is not our child pid ${server.pid}`);
      }
      if (state.port !== port) {
        throw new Error(`runtime state port ${state.port} is not our port ${port}`);
      }
    });

    let token1;
    let token2;
    const pairedOk = await attempt("two independently paired sessions", async () => {
      const pairing1 = await mintPairingToken({ nodeBin, serverBin, baseDir, label: "smoke-client-1" });
      const pairing2 = await mintPairingToken({ nodeBin, serverBin, baseDir, label: "smoke-client-2" });
      if (pairing1 === pairing2) {
        throw new Error("pairing tokens were not distinct");
      }
      token1 = await exchangeToken({ origin, pairingToken: pairing1, label: "smoke-client-1" });
      token2 = await exchangeToken({ origin, pairingToken: pairing2, label: "smoke-client-2" });
      if (token1 === token2) {
        throw new Error("access tokens were not distinct");
      }
      // A consumed one-time token must not pair a third session.
      const replay = await fetch(`${origin}/oauth/token`, {
        method: "POST",
        headers: { "content-type": "application/x-www-form-urlencoded" },
        body: new URLSearchParams({
          grant_type: "urn:ietf:params:oauth:grant-type:token-exchange",
          subject_token: pairing1,
          subject_token_type: "urn:t3:params:oauth:token-type:environment-bootstrap",
          requested_token_type: "urn:ietf:params:oauth:token-type:access_token",
        }),
      });
      if (replay.ok) {
        throw new Error("a consumed pairing token was accepted a second time");
      }
    });
    if (!pairedOk) {
      return summarize(checks);
    }

    let config;
    const subscribedOk = await attempt("both clients synchronized shell subscriptions", async () => {
      client1 = await connectClient({ origin, accessToken: token1, label: "client-1" });
      client2 = await connectClient({ origin, accessToken: token2, label: "client-2" });
      config = await client1.request("server.getConfig", {});
      await client2.request("server.getConfig", {});
      const shell1 = client1.subscribe(
        "orchestration.subscribeShell",
        { requestCompletionMarker: true },
        client1.applyShellItem,
      );
      const shell2 = client2.subscribe(
        "orchestration.subscribeShell",
        { requestCompletionMarker: true },
        client2.applyShellItem,
      );
      await Promise.all([shell1.synchronized, shell2.synchronized]);
    });
    if (!subscribedOk) {
      return summarize(checks);
    }

    const projectId = `project-${randomUUID()}`;
    const threadId = `thread-${randomUUID()}`;
    const originalTitle = "Shared smoke thread";
    const renamedTitle = `Renamed by client 2 ${randomUUID().slice(0, 8)}`;

    await attempt("project visible and identical on both clients", async () => {
      await client1.request("orchestration.dispatchCommand", {
        type: "project.create",
        commandId: `command-${randomUUID()}`,
        projectId,
        title: "Shared smoke project",
        workspaceRoot: workspace,
        createdAt: new Date().toISOString(),
      });
      await Promise.all([
        client1.waitForShell((shell) => shell.projects.has(projectId), "project on client 1"),
        client2.waitForShell((shell) => shell.projects.has(projectId), "project on client 2"),
      ]);
      const seen1 = client1.shell.projects.get(projectId);
      const seen2 = client2.shell.projects.get(projectId);
      if (!sameJson(seen1, seen2)) {
        throw new Error("project shells differ between clients");
      }
      if (seen1.workspaceRoot !== workspace) {
        throw new Error("project workspace root does not match the created workspace");
      }
    });

    const modelSelection = pickModelSelection(config);
    await attempt("thread visible and identical on both clients", async () => {
      await client1.request("orchestration.dispatchCommand", {
        type: "thread.create",
        commandId: `command-${randomUUID()}`,
        threadId,
        projectId,
        title: originalTitle,
        modelSelection,
        runtimeMode: "approval-required",
        interactionMode: "default",
        branch: null,
        worktreePath: null,
        createdAt: new Date().toISOString(),
      });
      const hasThread = (shell) => shell.threads.get(threadId)?.title === originalTitle;
      await Promise.all([
        client1.waitForShell(hasThread, "thread on client 1"),
        client2.waitForShell(hasThread, "thread on client 2"),
      ]);
      const seen1 = client1.shell.threads.get(threadId);
      const seen2 = client2.shell.threads.get(threadId);
      if (!sameJson(identityFields(seen1), identityFields(seen2))) {
        throw new Error("thread shells differ between clients");
      }
      if (seen1.runtimeMode !== "approval-required" || seen1.session !== null) {
        throw new Error("thread was created with an unexpected runtime mode or a live session");
      }
    });

    // Reads the thread detail snapshot through a fresh subscription and
    // interrupts it once the initial frame has landed.
    const readThreadSnapshot = async (client) => {
      let snapshot;
      const stream = client.subscribe(
        "orchestration.subscribeThread",
        { threadId, requestCompletionMarker: true },
        (item) => {
          if (item.kind === "snapshot") snapshot = item.snapshot;
        },
      );
      await stream.synchronized;
      stream.interrupt();
      if (!snapshot) {
        throw new Error("thread subscription produced no snapshot frame");
      }
      return snapshot;
    };

    await attempt("client 1 shell sees client 2 title change", async () => {
      await client2.request("orchestration.dispatchCommand", {
        type: "thread.meta.update",
        commandId: `command-${randomUUID()}`,
        threadId,
        title: renamedTitle,
      });
      await client1.waitForShell(
        (shell) => shell.threads.get(threadId)?.title === renamedTitle,
        "renamed thread on client 1",
      );
      await client2.waitForShell(
        (shell) => shell.threads.get(threadId)?.title === renamedTitle,
        "renamed thread on client 2",
      );
    });

    // Upstream's thread detail stream forwards only message, plan, activity,
    // diff, revert, and session events; metadata changes reach clients through
    // the shell stream. The detail read model must still carry the new title.
    await attempt("client 2 thread snapshot reads its own title change", async () => {
      const snapshot = await readThreadSnapshot(client2);
      if (snapshot.thread.id !== threadId || snapshot.thread.title !== renamedTitle) {
        throw new Error("live thread detail snapshot does not carry the renamed title");
      }
    });

    await client1.close();

    await attempt("reconnected client 1 shell snapshot reads latest title", async () => {
      client1Again = await connectClient({ origin, accessToken: token1, label: "client-1-again" });
      await client1Again.request("server.getConfig", {});
      const shell = client1Again.subscribe(
        "orchestration.subscribeShell",
        { requestCompletionMarker: true },
        client1Again.applyShellItem,
      );
      await shell.synchronized;
      const thread = client1Again.shell.threads.get(threadId);
      if (!thread) {
        throw new Error("thread missing from the fresh shell snapshot");
      }
      if (thread.title !== renamedTitle) {
        throw new Error("fresh shell snapshot does not carry the renamed title");
      }
      if (!sameJson(identityFields(thread), identityFields(client2.shell.threads.get(threadId)))) {
        throw new Error("fresh shell snapshot differs from client 2's live view");
      }
    });

    await attempt("reconnected client 1 thread snapshot reads latest title", async () => {
      const snapshot = await readThreadSnapshot(client1Again);
      if (snapshot.thread.id !== threadId || snapshot.thread.title !== renamedTitle) {
        throw new Error("thread detail snapshot does not carry the renamed title");
      }
      if (snapshot.thread.messages.length !== 0) {
        throw new Error("thread detail snapshot unexpectedly contains messages");
      }
    });

    return summarize(checks);
  } finally {
    for (const client of [client1, client2, client1Again]) {
      try {
        await client?.close();
      } catch {
        // Closing during teardown is best effort.
      }
    }
    await stopServer(server);
    await rm(root, { recursive: true, force: true });
    cleanedUp = true;
    process.off("exit", cleanupSync);
    process.off("SIGINT", onSignal);
    process.off("SIGTERM", onSignal);
  }
}

function summarize(checks) {
  const passed = checks.filter((entry) => entry.ok).length;
  return { passed, failed: checks.length - passed, checks };
}

function parseArgs(argv) {
  const args = { serverBin: undefined };
  for (let index = 0; index < argv.length; index += 1) {
    const value = argv[index];
    if (value === "--server-bin") {
      args.serverBin = argv[index + 1];
      index += 1;
    } else if (value.startsWith("--server-bin=")) {
      args.serverBin = value.slice("--server-bin=".length);
    } else {
      throw new Error(`unknown argument: ${value}`);
    }
  }
  return args;
}

async function main() {
  let args;
  try {
    args = parseArgs(process.argv.slice(2));
  } catch (error) {
    console.error(error.message);
    console.error("usage: smoke-shared.mjs --server-bin /absolute/path/to/apps/server/dist/bin.mjs");
    return 2;
  }
  if (!args.serverBin) {
    console.error("--server-bin is required");
    console.error("usage: smoke-shared.mjs --server-bin /absolute/path/to/apps/server/dist/bin.mjs");
    return 2;
  }
  let result;
  try {
    result = await runSharedSmoke({ serverBin: args.serverBin, nodeBin: process.execPath });
  } catch (error) {
    console.error(redact(error instanceof Error ? error.message : String(error)));
    return 2;
  }
  console.log(`shared smoke: ${result.passed} passed, ${result.failed} failed`);
  for (const entry of result.checks) {
    if (!entry.ok) {
      console.error(`FAIL ${entry.name}: ${entry.detail ?? ""}`);
    }
  }
  return result.failed === 0 ? 0 : 1;
}

// import.meta.main (Node 24) is true only for the process entry module, however
// it was reached: a symlink, an aliased directory such as /tmp on macOS, or the
// canonical path. Comparing argv against the module URL missed the first two.
if (import.meta.main) {
  main().then(
    (code) => {
      process.exitCode = code;
    },
    (error) => {
      console.error(redact(error instanceof Error ? error.stack ?? error.message : String(error)));
      process.exitCode = 2;
    },
  );
}
