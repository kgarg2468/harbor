# Shared-environment smoke

`scripts/smoke-shared.mjs` proves, against a real built T3 server, that two
independently paired clients see the same project and thread metadata and that
a metadata change made by one client reaches the other, including across a
disconnect and reconnect. It is the first integration gate for the
shared-conversations part of `design.md`.

## What it covers

The smoke starts one headless `t3 serve` on a private temporary home and a
random loopback port, pairs two clients through the real `t3 pair` CLI and the
OAuth token exchange, and speaks the WebSocket RPC protocol directly. It never
opens a browser, never starts a provider turn, and never touches `~/.t3` or
`~/.t3-reasoning`.

It performs exactly these checks, in order:

1. The server reports ready on the chosen port and answers the environment
   descriptor.
2. The server's runtime state file names our child process id and our port, so
   the run is talking to its own server and not to another instance.
3. Two pairing tokens minted separately exchange for two distinct bearer
   tokens, and a consumed pairing token is refused a second time.
4. Both clients open authenticated WebSockets, read server config, subscribe to
   the orchestration shell, and reach the synchronized marker.
5. Client 1 creates a project. Both clients receive it through their
   subscriptions and their copies are identical.
6. Client 1 creates a thread with `runtimeMode: approval-required`,
   `interactionMode: default`, no branch, and no worktree, using a model from
   the server's own provider list. Both clients receive it, their copies are
   identical, and no provider session exists.
7. Client 2 renames the thread. Client 1's shell subscription delivers the new
   title.
8. Client 2's fresh thread-detail snapshot carries the new title without a
   reconnect.
9. Client 1 closes its socket, reconnects with its existing bearer token, and
   the fresh shell snapshot carries the new title and matches client 2's live
   view.
10. Reconnected client 1's fresh thread-detail snapshot carries the new title
    and no messages.

Only pass and fail counts are printed. Tokens, tickets, and server responses
are never written to the terminal; error details are redacted before output.

## What it does not cover

These are future acceptance gates, not claims this smoke makes:

- Message generation. No turn is started, so nothing about provider output,
  streaming text, approvals, or checkpoints is tested.
- Graphical stock-client compatibility. The clients here are protocol clients
  written for the test, not the Nightly desktop or web app.
- Thread-detail live events for metadata. Upstream's thread-detail stream
  forwards message, plan, activity, diff, revert, and session events only.
  Title changes reach clients through the shell stream, which is what checks
  7, 9, and 10 rely on.

## Running it

Requires Node.js 24, `git`, and a built T3 server. Pass the server entry point
as an absolute path:

```sh
node t3-reasoning/scripts/smoke-shared.mjs \
  --server-bin /absolute/path/to/apps/server/dist/bin.mjs
```

Exit code 0 means every check passed, 1 means at least one check failed, and 2
means the run could not start.

The integration test wraps the same run:

```sh
T3_REASONING_SERVER_BIN=/absolute/path/to/apps/server/dist/bin.mjs \
  node --test t3-reasoning/tests/smoke-shared.test.mjs
```

Without `T3_REASONING_SERVER_BIN` the four integration cases are skipped and
only the argument-handling cases run, which is what the component workflow does
today. Once the workflow materializes and builds the pinned source, it can set
the variable to that build's `apps/server/dist/bin.mjs` and the same test
becomes a CI gate.

Besides the green run, the integration cases cover interruption: the test
spawns the CLI as a real child process with an IPC channel, waits until the
child reports the server pid and temporary root it owns, then sends `SIGINT`
or `SIGTERM` and asserts that the owned server exits, the root is removed, and
the CLI exits with 130 or 143 respectively.

## Cleanup guarantees

The run owns exactly one server process and one temporary root. It captures
the server child at spawn, before waiting for readiness, so cleanup can reach
it even if the ready wait is cut short. On the normal path it stops the server
by that captured pid and removes the temporary root in a `finally` block.

If the process is interrupted first, a synchronous and idempotent guard runs
instead: on `exit`, `SIGINT`, and `SIGTERM` it kills the captured server and
removes the root, and for a signal it then exits with the conventional
128 + signal number (130 for `SIGINT`, 143 for `SIGTERM`). The guard only ever
signals the pid it spawned; it never matches processes by name or pattern.
Nothing else on the machine is signalled or deleted.

A WebSocket that fails to open, whether by error or by timeout, is closed
before the failure propagates, and each client close is bounded so a peer that
never completes the close handshake cannot stall teardown before the server is
stopped. `SIGKILL` cannot be handled by any process, so a killed run leaves
its server and root behind; that is the only uncovered case.
