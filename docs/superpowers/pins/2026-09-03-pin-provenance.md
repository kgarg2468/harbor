# Pin provenance, 2026-09-03

Where each value in `fleet/versions.lock` came from. PR 3 owns the eight values below;
the other five keys (`claude_code_version`, `claude_code_install`, `codex_version`,
`codex_install`, `t3_install`) stay empty until PR 4. Every command was run on 2026-09-03
against the live network, and the output line quoted is the exact line the value was read
from. A future version-bump PR re-runs the same commands and updates both files together.

## Summary

| Key | Value |
| --- | --- |
| `ubuntu_release` | `24.04` |
| `tailscale_apt_channel` | `stable/ubuntu/noble` |
| `tailscale_version` | `1.102.3` |
| `nodejs_version` | `24.20.0` |
| `nodejs_install` | `https://nodejs.org/dist/v24.20.0/node-v24.20.0-linux-x64.tar.xz` |
| `nodejs_sha256` | `2f2c0da162318f0de47665410c7c8c2ed3d36c8f3105de4bbc61176c70a7cbf2` |
| `t3_version` | `0.0.38` |
| `t3_engines_node` | `^22.16\|\|^23.11\|\|>=24.10` |

## `ubuntu_release`

Value: `24.04`, the compatibility floor of design section 2, stated as `/etc/os-release`
reports it in `VERSION_ID` (`VERSION_ID="24.04"`), without the point-release suffix, so the
bootstrap preflight compares a stable string across 24.04.x point releases.

Command (2026-09-03):

```sh
curl -sS https://changelogs.ubuntu.com/meta-release-lts | awk '/^Dist: noble$/{p=1} p&&/^Version:/{print; exit}'
```

Output line:

```text
Version: 24.04.4 LTS
```

## `tailscale_apt_channel`

Value: `stable/ubuntu/noble`. This is the path component under `https://pkgs.tailscale.com/`
that names the stable channel for Ubuntu noble (24.04). The install step derives its two
files from it: the source list at `<channel>.list` and the keyring at `<channel>.gpg`
(also served as `<channel>.asc` and, with the `signed-by` form, `<channel>.tailscale-keyring.list`).

Commands (2026-09-03):

```sh
curl -sS -o /dev/null -w '%{http_code}\n' https://pkgs.tailscale.com/stable/ubuntu/noble.list
curl -sS https://pkgs.tailscale.com/stable/ubuntu/noble.list
```

Output lines:

```text
200
# Tailscale packages for ubuntu noble
deb https://pkgs.tailscale.com/stable/ubuntu noble main
```

Keyring URL check (2026-09-03), one status per URL:

```sh
for u in stable/ubuntu/noble.noarch.gpg stable/ubuntu/noble.gpg stable/ubuntu/noble.tailscale-keyring.list stable/ubuntu/noble.asc; do printf '%s ' "$u"; curl -sS -o /dev/null -w '%{http_code}\n' "https://pkgs.tailscale.com/$u"; done
```

```text
stable/ubuntu/noble.noarch.gpg 404
stable/ubuntu/noble.gpg 200
stable/ubuntu/noble.tailscale-keyring.list 200
stable/ubuntu/noble.asc 200
```

## `tailscale_version`

Value: `1.102.3`, the newest `tailscale` package version in the stable channel's noble
amd64 Packages index. The index is not sorted, so the versions are passed through
`sort -V` and the last line is taken.

Command (2026-09-03):

```sh
curl -sS https://pkgs.tailscale.com/stable/ubuntu/dists/noble/main/binary-amd64/Packages | awk '/^Package: tailscale$/{p=1} p&&/^Version:/{print; p=0}' | sort -V | tail -3
```

Output lines (the last is the value):

```text
Version: 1.102.1
Version: 1.102.2
Version: 1.102.3
```

## `nodejs_version`

Value: `24.20.0`, the newest release on the 24.x line, which is the current Active LTS line
(codename Krypton; LTS since 2025-10-28, maintenance from 2026-10-20 per the Node.js release
schedule). Stored bare, without the `v` prefix, so it compares directly against the output of
`node --version` with the prefix stripped.

Command (2026-09-03):

```sh
curl -sS https://nodejs.org/dist/index.json | python3 -c 'import json,sys; rels=json.load(sys.stdin); v24=[r for r in rels if r["version"].startswith("v24.")]; print(json.dumps({k: v24[0][k] for k in ("version","date","lts")}))'
```

Output line:

```text
{"version": "v24.20.0", "date": "2026-08-26", "lts": "Krypton"}
```

LTS schedule check (2026-09-03):

```sh
curl -sS https://raw.githubusercontent.com/nodejs/Release/main/schedule.json | python3 -c 'import json,sys; d=json.load(sys.stdin)["v24"]; print(json.dumps(d))'
```

```text
{"start": "2025-05-06", "lts": "2025-10-28", "maintenance": "2026-10-20", "end": "2028-04-30", "codename": "Krypton"}
```

The `latest-v24.x` alias resolves to the same tarball:

```sh
curl -sS https://nodejs.org/dist/latest-v24.x/ | grep -o 'node-v24\.[0-9.]*-linux-x64\.tar\.xz' | sort -u
```

```text
node-v24.20.0-linux-x64.tar.xz
```

## `nodejs_install`

Value: `https://nodejs.org/dist/v24.20.0/node-v24.20.0-linux-x64.tar.xz`, the linux-x64
tarball of the exact release above under the versioned directory, never the `latest` alias.

Command (2026-09-03):

```sh
curl -sSI https://nodejs.org/dist/v24.20.0/node-v24.20.0-linux-x64.tar.xz | head -1
```

Output line:

```text
HTTP/2 200
```

## `nodejs_sha256`

Value: `2f2c0da162318f0de47665410c7c8c2ed3d36c8f3105de4bbc61176c70a7cbf2`, read from the
release's `SHASUMS256.txt` for the exact file name `nodejs_install` ends with.

Command (2026-09-03):

```sh
curl -sS https://nodejs.org/dist/v24.20.0/SHASUMS256.txt | grep ' node-v24.20.0-linux-x64.tar.xz$'
```

Output line:

```text
2f2c0da162318f0de47665410c7c8c2ed3d36c8f3105de4bbc61176c70a7cbf2  node-v24.20.0-linux-x64.tar.xz
```

## `t3_version`

Value: `0.0.38`, the current published version of the `t3` npm package (repository
`pingdotgg/t3code`).

Commands (2026-09-03):

```sh
npm view t3 version
npm view t3 repository.url
```

Output lines:

```text
0.0.38
https://github.com/pingdotgg/t3code
```

## `t3_engines_node`

Value: `^22.16||^23.11||>=24.10`. The `engines.node` range of `t3@0.0.38` as npm reports it
is `^22.16 || ^23.11 || >=24.10`; the lock stores it with the spaces around each `||` removed,
because `harbor_versions_load` rejects any value containing whitespace. Semver treats the two
spellings identically: `||` alternation is split on the separator and each side is trimmed.
`nodejs_version` `24.20.0` satisfies the `>=24.10` alternative; the plan's Task 2 and Task 5
prove that with code.

Command (2026-09-03):

```sh
npm view t3 engines
```

Output line:

```text
{ node: '^22.16 || ^23.11 || >=24.10' }
```
