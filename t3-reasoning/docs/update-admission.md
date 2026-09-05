# Update admission primitive

`0003-update-admission.patch` adds a standalone server service and 11 focused
tests. No request handler or updater uses it yet.

`withAdmission` rejects new commands with a retryable error during maintenance.
Otherwise it holds a count until the wrapped effect finishes, fails, or is
interrupted. `withMaintenance` serializes maintenance owners, closes admissions,
drains admitted effects, and runs its callback while admissions remain closed.
Every callback exit reopens admissions.

The primitive is non-reentrant: apply admission once at a mutation boundary.
Maintenance handlers must execute outside admitted commands. Do not nest
maintenance calls. Separate maintenance owners each reopen on exit; continuous
closure between queued owners is not part of the contract, despite the current
serialization test's broader title.

Future integration must track detached provider, reactor, and finalization work
separately. A completed RPC does not establish agent idleness. Keep the
maintenance callback alive through the actual restart handoff; returning after
an acknowledgement would reopen admission too early.

Verification on Node 24.13.1: all 11 focused tests pass. Independent review found
no blocking issue in this standalone contract. The patch also materializes
cleanly on the locked upstream revision after the first two patches.
