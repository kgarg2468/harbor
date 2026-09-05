# Conversation fork backend

A fork creates a new durable thread from a completed source turn. It copies
history and attachments through that boundary, records its lineage, and can
restore the selected checkpoint into a new worktree. The source thread and its
workspace remain unchanged. Sharing the existing workspace is also supported;
that choice means both threads edit the same files.

The destination selects its provider and model independently. The fork itself
does not start an agent. Its first real message supplies bounded copied context
to a fresh provider conversation; subsequent messages use that conversation.
Displayed history stays intact even when the provider context is shortened.
Reasoning messages are retained for display and excluded from the handoff text.
Only bounded completed-tool summaries are included, never raw provider payloads.

Retries with the same command and intent reuse the created fork. Changing intent
under that command is rejected, and retrying after deletion reports that the
fork was deleted. Copied history preserves source order across equal timestamps,
reload, pagination, and another fork. Owned pre-commit resources are cleaned up
on failure; an uncertain committed result never authorizes deleting them.
A configured project setup script runs after the worktree fork is committed;
its failure leaves the fork intact and returns a warning.

The handoff is consumed after adapter acceptance, with durable recording retried
without sending the payload again. Per-thread ownership prevents competing
first messages from repeating copied context, including stale snapshot and
preparation-failure races. A lost native acknowledgement, or process restart
between acceptance and durable recording, can still repeat copied context on a
later explicit send. This is a fresh context handoff, not a native session clone.

## Verification and deployment boundary

The focused backend suite passes 54 tests using real SQLite and temporary git
repositories; three fork RPC tests and ten handoff tests pass independently.
Server and web package typechecks pass in a fresh checkout containing only
the published patch stack and this backend patch.
The source patch is shared by both managed variants and adds no new wire-event
types. The desktop fork dialog is a separate patch, and no live app or data has
been updated by this change.
