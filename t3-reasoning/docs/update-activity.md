# Update activity ownership

The activity registry and fanout helpers establish the ownership rule needed
for idle updates: acquire work before enqueueing, publishing, or scheduling it,
and release ownership only after that work actually finishes. Idle claiming
atomically seals an empty registry; new acquisitions then fail until it reopens.

Required consumers have separate tracked delivery queues. Missing, canceled,
or failed consumers block an idle claim, even after their queued bookkeeping
is released. Ordinary UI observers do not count as work. A registered consumer
whose processing loop has not started also blocks a claim, covering startup
activation and interruption before its first instruction.

The helpers have 14 focused tests covering queue ownership, cancellation,
consumer startup/failure, callback construction failures, delivery ordering,
and the acquire-versus-seal race. These tests pass independently on Node 24.

The patch is shared by both managed variants. It is not wired into Engine,
provider adapters, reactors, or the update launcher yet, and does not currently
detect whether real agents are idle. Native turn and background-task lifecycle
integration must preserve this ownership across their asynchronous boundaries
before any live automatic update can use it.
