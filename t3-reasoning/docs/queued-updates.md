# Durable update queue

`0004-queued-update.patch` adds the queue controller and 37 focused tests. It is
not installed or connected to RPC handlers, nightly discovery, or the launcher.

The controller records an exact target version before starting background
staging. Its states are downloading, queued, updating, current, and failed.
The process's installed version is authoritative after restart. A saved pending
target resumes; an interrupted activation is reconciled against the running
version. Invalid saved state fails startup without silently erasing intent.

Queueing the same target is idempotent. A queued or downloading update can be
canceled or replaced. Activation reserves the updating state under the same
mutex as commands: cancellation, replacement, and retry are rejected until the
attempt declines or the process restarts. This prevents a superseded artifact
from activating after the UI has acknowledged cancellation or replacement.

Staging and activation are injected dependencies. Staging must verify the exact
artifact; the activation callback must check the real activity barrier and
respond promptly when busy or uncertain. After accepting a restart handoff it
must keep the gates held and never return. This controller supplies neither the
activity detector nor permission to interrupt running agents.

A busy or uncertain answer returns the target to queued for another attempt.
If saving that answer fails, the controller retains its activation reservation
and retries only the state write. It does not repeat activation while the
previous result is waiting to become durable. Accepted handoffs remain updating.

Before its first state replacement, each controller creates any missing state
directories and syncs their full ancestor chain. It repeats that proof after
a failed barrier, including after a process restart with partially created
directories still visible. Subsequent writes reuse the proof while the directory
exists.

State writes sync the temporary file before replacement and sync its parent
directory afterward. Commands acknowledge only after both barriers succeed.
If the directory sync fails after replacement, memory follows the new pathname
with `durable: false`; waiters and activation remain blocked until the barrier
succeeds. This implementation targets macOS and Linux filesystems that support
directory sync.

The injected installed version must be an exact version. The controller
validates queued targets and staged identities; release integration owns the
running binary's version stamp and artifact verification.

## Verification

On Node 24.13.1, `pnpm --filter t3 test src/cloud/queuedUpdate.test.ts` passes all
37 tests. Coverage includes busy and unknown activity, restart recovery, staged
failures, cancellation and replacement races, interrupted commands, exact-version
validation, and failed state writes after both busy and failed activation.

Independent review found four activation races, then a persistence recovery
gap. Regression tests reproduce the failures and pass with the corrections.
Greptile identified the missing durability barriers; eight additional tests cover
file sync, directory sync, canceled intent across recovery, and observers waiting
for durable state, nested directory creation, and restarting after a failed
creation barrier.
Live activation still requires the separate activity tracker, admission wiring,
verified artifact staging, and launcher integration.
