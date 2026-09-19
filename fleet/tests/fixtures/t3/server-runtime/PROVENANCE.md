# Runtime-state fixture provenance

Inspected on 2026-09-18: `/tmp/t3probe/lib/node_modules/t3/package.json`
reports `t3@0.0.38`. Source: the installed package's `dist/bin.mjs`.
No running server was started and none of these files is a live capture.

## Confirmed from the pinned package

Searched for `resolveBaseDir`, `deriveServerPaths`, `serverRuntimeStatePath`,
`PersistedServerRuntimeState`, `runtimeOriginForConfig`, and
`persistServerRuntimeState` with `rg -n`, then read their definitions.

- `resolveBaseDir` defaults to `NodeOS.homedir()` joined with `.t3`.
- `deriveServerPaths` uses `userdata` normally and joins it with
  `server-runtime.json`. Its dev variant depends on `devUrl` and whether the
  base directory was explicit.
- `PersistedServerRuntimeState` contains `version: Literal(1)`, `pid: Int`,
  optional string `host`, `port: Int`, string `origin`, optional string `devUrl`,
  and string `startedAt`.
- `runtimeOriginForConfig` substitutes `127.0.0.1` for an absent or wildcard host;
  otherwise it uses the configured host, formatted for a URL.
- `persistServerRuntimeState` writes `${JSON.stringify(input.state)}\n`:
  compact JSON followed by a newline, with no indentation argument.

## Constructed fixtures

Every fixture is hand-written from the plan. PID 4242, port 3773, timestamp,
and addresses are synthetic; they were not observed in a live runtime file.

| Fixture | Construction |
| --- | --- |
| `healthy` | Schema-conforming compact object and trailing newline |
| `non-loopback-host` | Same shape with an explicit routable host |
| `no-port` | Deliberately omits the required port |
| `wrong-version` | Deliberately changes the schema literal to 2 |
| `pretty-printed` | Same values as healthy, with synthetic indentation |
| `garbage` | Deliberately truncated JSON |

## Nondefault port regression (2026-09-18)

`nondefault` derives from `healthy`, with port and origin changed to 41773, so
the endpoint integration test fails if production hard-codes the usual port.
