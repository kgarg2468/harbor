# Security policy

## Reporting a vulnerability

Report vulnerabilities through GitHub's private vulnerability reporting on this repository
("Security" tab, "Report a vulnerability"). Do not open a public issue for a security problem.
There is no reporting email address.

Expect an acknowledgement within seven days. Fixes ship as ordinary pull requests once a
mitigation exists; the advisory is published when the fix is merged.

## Scope

In scope: anything Harbor itself does on the node or the Mac, including the command lock, the
ownership journal, file modes, firewall and SSH changes, and how Harbor invokes vendor tools.

Out of scope: vulnerabilities in Tailscale, Node.js, Claude Code, Codex, or T3 Code themselves.
Report those to their vendors.

## What not to include in a report

Harbor's design (section 3.8) keeps secrets, tailnet IPs, private hostnames, personal emails,
pairing URLs, and tokens out of this repository. The same applies to reports: describe the
problem with the placeholders the design uses (`harbor-node`, `TAILNET.ts.net`, `TAILNET_IP`,
`OPERATOR`, `operator@example.com`, `RELAY_HOSTNAME`) and never paste a token, key, auth URL, or
log file that might contain one.
