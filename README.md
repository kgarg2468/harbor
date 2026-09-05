# Harbor

This repository also contains [Insomnia](insomnia/README.md), a Swift macOS menu
bar app for timed awake sessions. Its source-build setup and release status are
documented separately.

Harbor provisions a single Ubuntu 24.04 node as a T3 Code agent host and pairs a macOS
controller with it, using only the vendors' own tools (Tailscale, Node.js, Claude Code, Codex,
`t3`), with every mutation journaled so it can be inspected and undone exactly.

## Status

Design complete, implementation in progress. This repository currently contains:

- the approved design specification, `docs/superpowers/specs/2026-09-01-harbor-design.md`;
- the foundation from PR 2 under `fleet/`: the `fleet/bin/harbor` dispatcher, the `fleet/lib/`
  libraries for logging, checks, version pinning, the command lock, and the ownership journal,
  the `harbor journal resolve` command, the Bats test harness, the vendor shim skeleton, the
  placeholder scan, and CI.

Nothing here installs, configures, or removes anything on a node yet. `harbor bootstrap`,
`harbor provision`, `harbor status`, `harbor upgrade`, `harbor teardown`, and the macOS client
arrive in later pull requests in the order given by section 8 of the design.

## Layout

- `fleet/`: all of Harbor's code. Everything below is relative to it.
- `fleet/bin/harbor`: the single entry point. It dispatches subcommands and contains no logic.
- `fleet/lib/`: `log.sh`, `checks.sh`, `versions.sh`, `lock.sh`, `journal.sh`.
- `fleet/versions.lock`: exact third-party versions, one per key. Empty until each component's PR.
- `fleet/tests/`: Bats unit tests, vendor shims, fixtures, and the placeholder scan.
- `docs/superpowers/specs/`: the design. `docs/superpowers/plans/`: per-PR implementation plans.

## Running the checks

See `CONTRIBUTING.md` for the exact lint and unit-test commands. They are the same commands
CI runs.

## Documents

- Design: `docs/superpowers/specs/2026-09-01-harbor-design.md`
- Security policy: `SECURITY.md`
- Contributing: `CONTRIBUTING.md`
- License: `LICENSE`
