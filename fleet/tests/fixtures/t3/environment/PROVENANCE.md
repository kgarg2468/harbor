# Environment-descriptor fixture provenance

Inspected on 2026-09-18: `/tmp/t3probe/lib/node_modules/t3/package.json`
reports `t3@0.0.38`. Source: the installed package's `dist/bin.mjs`.
No HTTP endpoint was queried and none of these files is a live capture.

## Confirmed from the pinned package

Searched for `ExecutionEnvironmentDescriptor`, `ExecutionEnvironmentPlatform`,
and `WELL_KNOWN_ENVIRONMENT_PATH` with `rg -n`, then read their definitions.

- The path is `/.well-known/t3/environment`.
- The descriptor has `environmentId: EnvironmentId`, nonempty trimmed `label`
  and `serverVersion`, `platform: ExecutionEnvironmentPlatform`, and a
  `capabilities` object.
- Platform is an object with `os` and `arch`, not the string `linux` supplied
  in the plan. Linux and x64 are accepted literals; these fixtures correct that
  plan defect.
- `capabilities.repositoryIdentity` is boolean with a decoding default of false.
  Other capabilities are optional; these fixtures omit them.

## Constructed fixtures

All IDs, labels, and version/platform choices below are synthetic. The source
inspection confirms their shape, not that any real server emitted these bytes.

| Fixture | Construction |
| --- | --- |
| `valid` | Compact descriptor with synthetic ID `env_2f7a91c4` |
| `valid-other-id` | Same schema with synthetic ID `env_9b3e04d1` and another label |
| `not-t3` | Hand-written HTML, not a vendor response |
| `empty` | Zero bytes, representing an endpoint that answered with no body |

The following fixtures are CONSTRUCTED from the inspected `t3@0.0.38`
schema recorded above and the review’s required-field inventory; no new package
measurement or HTTP capture was performed for this revision. Each retains the
synthetic ID from `valid`.

| Fixture | Construction |
| --- | --- |
| `missing-label` | CONSTRUCTED: omit required `label` from the descriptor |
| `missing-platform` | CONSTRUCTED: omit required `platform` from the descriptor |
| `missing-serverVersion` | CONSTRUCTED: omit required `serverVersion` from the descriptor |
| `missing-capabilities` | CONSTRUCTED: omit required `capabilities` from the descriptor |
| `missing-os` | CONSTRUCTED: omit required `os` from platform |
| `missing-arch` | CONSTRUCTED: omit required `arch` from platform |
| `non-object` | CONSTRUCTED: wrap the complete descriptor in HTML |

## Adversarial JSON reader fixtures (2026-09-18)

`escaped-local` and `escaped-remote` reproduce the escaped-quote collision from
the review using synthetic IDs. `nested-wrapper`, `tabs`, `duplicate-id`,
`nested-platform`, and `sentinel-body` derive from `valid` by changing only the
structure or spelling named by the file. No live environment was queried.
