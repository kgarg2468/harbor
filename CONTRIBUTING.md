# Contributing

## Insomnia contributions

For changes under `insomnia/`, start with [its README](insomnia/README.md) and
[current specification](insomnia/docs/spec.md). Run Swift tests, release build,
ShellCheck and isolated script tests listed there. Use fake power, process, audio
and network adapters; never make routine CI manipulate the runner’s real power
settings or existing applications. Record real-device checks separately.

The fleet section-8 sequencing and Bash rules below apply to Harbor/fleet work,
not Insomnia’s Swift features. Shared secret-scanning and focused PR conventions
still apply. Keep recovery changes reviewable and explain larger migrations.

## Ground rules

- Read `docs/superpowers/specs/2026-09-01-harbor-design.md` first. Pull requests follow the
  order and scope of its section 8 table; behavior outside the current PR's row is deferred,
  not squeezed in.
- `fleet/bin/`, `fleet/lib/`, `fleet/client/`, and `fleet/tests/` are bash 3.2: they must run under macOS's system
  `/bin/bash`. Only `fleet/node/` may use bash 5 features.
- No secrets, live tailnet IPs, private hostnames, or personal emails anywhere in the tree.
  Documentation and tests use only the placeholders from design section 3.8: `harbor-node`,
  `TAILNET.ts.net`, `TAILNET_IP`, `OPERATOR`, `operator@example.com`, `RELAY_HOSTNAME`.
- No work-in-progress markers in tracked files. The placeholder scan rejects them.
- Keep a pull request under about 600 changed lines excluding fixtures and vendored helpers.
  When a PR must exceed that, say why in its description.

## Checkout

The Bats libraries are git submodules:

```sh
git clone --recurse-submodules <repository-url>
# or, in an existing clone:
git submodule update --init --recursive
```

## Lint locally

```sh
shellcheck -s bash -x -a -S warning -P 'SCRIPTDIR/..:SCRIPTDIR/../..' --enable=require-variable-braces \
  fleet/bin/harbor fleet/lib/*.sh fleet/tests/run_unit.sh fleet/tests/shims/bin/harbor-shim \
  fleet/tests/lint/placeholder_scan.sh fleet/tests/unit/test_helper.bash
shfmt -i 2 -ci -bn -d fleet/bin/harbor fleet/lib fleet/tests/run_unit.sh fleet/tests/shims/bin/harbor-shim \
  fleet/tests/lint/placeholder_scan.sh fleet/tests/unit/test_helper.bash
fleet/tests/lint/placeholder_scan.sh
gitleaks detect --source . --config .gitleaks.toml --no-banner --redact
npx --yes markdownlint-cli@0.41.0 --config .markdownlint.yml '**/*.md' --ignore fleet/tests/vendor
```

Install: `shellcheck` from your package manager; `go install mvdan.cc/sh/v3/cmd/shfmt@v3.8.0`;
gitleaks 8.18.4 from its GitHub release; Node.js for `npx`.

## Unit tests locally

```sh
fleet/tests/run_unit.sh                 # everything, as CI runs it
fleet/tests/run_unit.sh fleet/tests/unit/lib/lock.bats
```

On macOS the runner pins `PATH` so Bats executes under `/bin/bash` 3.2, which is what the
`macos-14` job in CI does. Run the suite on both an Ubuntu machine and a Mac before opening a
PR when you touched `fleet/lib/` or `fleet/bin/`.

## Commit and PR conventions

- Conventional prefixes: `feat:`, `fix:`, `test:`, `docs:`, `ci:`, `chore:`.
- One PR per section 8 row. The PR description names the row, lists the section 7 tests it
  adds, and, when it cannot be automated, the runbook checks re-run by hand.
