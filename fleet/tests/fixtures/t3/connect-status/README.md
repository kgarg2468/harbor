# `t3 connect status --json` fixtures

Recorded against the pinned `t3_version` (0.0.38). The emitter is
`JSON.stringify(status, null, 2)`, so the top level is two-space indented and
`relayClient`'s own keys sit at four spaces. `harbor_t3_connect_status` reads
exactly four values out of these — `desired`, `authenticated`, `linked`, and
`relayClient.status` — and ignores every other key on purpose, so that a vendor
adding fields cannot change Harbor's classification.

## Provenance

Not every state can be captured. Producing an authenticated one would mean
authorizing a real account, and Harbor never reads, copies, prints, or inspects
a vendor credential store. The split is recorded here so a later reader does not
mistake a constructed fixture for a measured one.

| Fixture | Provenance |
| --- | --- |
| `needs-login` | **Measured.** `t3 connect status --json` against an isolated `--base-dir`, byte for byte, with only the machine-specific `executablePath` neutralised. |
| `needs-link` | Constructed: authorized, but the environment link is not provisioned yet. |
| `healthy` | Constructed: every flag true. |
| `relay-missing` | Constructed from `RelayClientStatusSchema`: the `missing` variant carries `version` only. |
| `relay-unsupported` | Constructed from `RelayClientStatusSchema`: the `unsupported` variant carries `platform` and `arch`. |
| `unparseable` | Not JSON, standing in for a CLI that printed something else. |

Every constructed fixture was emitted through the same `JSON.stringify(x, null, 2)`
the vendor uses, so none of them can drift from the real formatting by hand.

## What the constructed values are not

No fixture carries a real `cloudUserId` or `relayUrl`. `healthy` uses
`fixture-cloud-user` and a `.invalid` host, which is the reserved TLD for names
guaranteed never to resolve.

## The three relay words

`RelayClientStatusSchema` at the pin is a union of exactly `available`,
`missing`, and `unsupported`. The three variants carry **different** sibling
keys, so no reader may assume a fixed field order after `status`. Anything
outside those three words is `unknown`.
