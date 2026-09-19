# Provenance of the `tailscale serve status` fixtures

Design section 7 requires every vendor adapter to be backed by fixtures captured
from the pinned release. These are not all captured, and this file records which
are which, because a fixture whose origin is unrecorded gets treated as evidence
by the next person to read it. Plan correction 33 is the reason: a fixture written
from Harbor's own code agrees with Harbor by construction and with the vendor only
by luck, and the whole value of a fixture is the part that is not luck.

## Measured

| File | Measured against | What was confirmed |
| --- | --- | --- |
| `absent` | a real `tailscale` CLI 1.96.4 against a tailscaled 1.98.2, 2026-09-16 | byte-exact, including the trailing newline: `No serve config\n` on **stdout**. The version-skew warning that client emits goes to **stderr** and is not part of this body — see plan correction 35, which is the bug that measurement found. |

## Constructed, not measured

Every other file here is hand-written. They are the shapes the adapter must
classify, not transcripts of a vendor run.

| File | Represents | Why it was not measured |
| --- | --- | --- |
| `vendor-443` | the mapping `t3 pair --tailscale` leaves behind | creating one requires applying a Serve config |
| `foreign-443` | a 443 listener proxying something other than this node's T3 server | same |
| `non-443` | a listener on a port this adapter does not report on | same |
| `mixed-listeners` | a non-443 listener **above** the 443 one | same |
| `ambiguous-443` | two root handlers inside one 443 listener | same |
| `no-root-443` | a 443 listener with handlers but no root handler | same |
| `foreign-443-funnel` | a 443 listener Harbor did not predict, publicly exposed | `foreign-443`'s handler under `funnel`'s header; both halves are already in this table and neither can be captured by running Harbor |
| `funnel` | a public Funnel exposure | Harbor never creates a Funnel, so this can never be captured by running Harbor, and creating one by hand publishes a host on the public internet |
| `garbage` | output from a version or state this adapter does not recognize | it is by definition not a shape any pinned version prints |
| `empty` | the command answering nothing at all | same |

`tailscale serve --bg --https=443 http://127.0.0.1:3773` was attempted against the
real client above in order to capture the populated shapes. It hung indefinitely
across three attempts, never applied anything, and left the Serve config at `{}`
every time. Plan correction 36 records that, and the finding it produced about the
unbounded vendor call in `harbor pair` turned out to matter more than the fixture
would have.

## What this means for a reader

The populated-listener **layout** — one header per listener, handlers indented
beneath it as `|-- <path> proxy <target>` — is the adapter's assumption and is
**not** vendor-confirmed. If `harbor_serve_mapping` ever misreads a real node,
this layout is the first thing to doubt, and the fix is to capture a real body and
move the relevant row from the second table to the first rather than to adjust the
parser until the existing fixtures pass.

`tailscale serve status --json` exists and would sidestep the layout question
entirely. It is deliberately not used yet: `{}` for the empty config was confirmed
on the client above, but no populated JSON body was ever captured, and trading a
measured text format for an unmeasured JSON schema is the same mistake in the
other direction.
