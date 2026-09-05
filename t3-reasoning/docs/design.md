# T3 Reasoning: shared conversations, queued updates, and forks

Status: approved by the owner. No live installation or activation has occurred.

## Product contract

Keep managed Nightly and Reasoning apps side by side. The owner approved managed
custom builds of both variants so each can enforce a shared default on every
launch. Reasoning is the same upstream product plus a maintained feature patch
set. Both clients show
the same projects, threads, messages, attachments, approvals, and work status
when connected to the same environment. A message sent in either client becomes
visible in the other through T3's existing event stream.

Each machine updates independently when a new official Nightly is available.
Downloads and builds may run while agents work. Installation waits until the
affected machine has no active agent work, then updates and reconnects/reopens.
There is no timeout that forces an update while an agent is working.

Reasoning adds a Fork action: select a conversation boundary, a new chat in the
current workspace or a new git worktree, and an available harness/model.

## Repository and release ownership

This component lives in `t3-reasoning/` in Harbor. It is separate from `fleet/`;
the existing fleet provisioning work continues on its own branch. The owner's
new component request extends Harbor's repository scope without changing fleet's
existing contract not to patch or manage T3 internals.

Keep an exact upstream source revision and an ordered, reviewable feature patch
set here, with build tooling, focused tests, and durable architecture documents.
Materialize upstream source in an ignored build checkout. Do not publish private
chat data, connections, credentials, machine names, or build output.

Both releases combine the exact official Nightly source with shared-server
support. Reasoning also includes the accepted feature patch set. The managed
Nightly bundle is a custom build, not the official signed artifact.
A plain stock download must never overwrite Reasoning and silently remove its
features. A source conflict or failing compatibility test retains the previous
working Reasoning release and reports the reason; automatic discovery retries.

## Shared conversations

Use one background T3 server as the authority for each machine's environment.
Both desktop apps connect to those same environments. A remote server keeps its
own projects and filesystem; this does not replicate repositories between hosts.
The Mac environment runs independently of either desktop app's window lifecycle.

Do not synchronize two writable SQLite files or run two servers against one home.
For the first migration, preserve consistent snapshots of both existing stores.
Use the current Nightly history as the initial shared environment; expose unique
or divergent Reasoning history to both clients as a clearly labeled legacy
environment. Do not silently drop, deduplicate, or replay divergent event streams.
Make shared environments the normal destination for new work in both apps.

Persist the shared default in both managed variants and restore it on every
launch and reconnect. An unavailable shared environment stays selected with an
offline state; never silently route new work to a separate embedded store.
Verify both managed clients against the reasoning-capable shared server.

## Updates queued per machine

Discover published Nightly releases periodically, including after wake/reconnect;
do not assume a release exists every calendar night. Stage exact, verified
artifacts. Record installed and queued versions durably per target.

Use the vendor server launcher and its activation/recovery facilities where
available. Add a server-owned update gate around activation. The gate and turn
admission must serialize: an idle observation alone is insufficient because a
new turn could start before the restart.

Busy includes starting/running turns, pending tool/approval work belonging to a
turn, automatic follow-up/queued turns, worktree setup, and checkpoint/finalization
work. An open window, unsent draft, or an idle CLI process alone is not busy.
An unreachable target or an unknown activity state cannot authorize installation.

Pending updates allow agents to finish. At the final activation boundary, briefly
hold new turn admissions, drain required work, activate and verify, then reopen
admissions. Requests arriving during that boundary must be retained or rejected
with an explicit retryable response, never dropped or started on a stopping server.

The remote machine owns its queue so closing the Mac client does not lose it.
The Mac app restart waits for all affected Mac environments, including embedded
fallback backends, to be idle. Remote work does not block a Mac-only UI update
when that update does not restart the remote server or lose its pending input.
Save drafts and connection state; reopen apps that were open before the update.

Display Available, Downloading, Queued (agents working), Updating, Current, and
Failed states with versions and a concise reason. Provide queue cancellation and
retry. An offline target remains pending and retries after reconnect.

Give the managed release coordinator exclusive desktop update ownership; the
upstream updater must not race it or replace either variant with stock code.
Verify the final idle guard before unattended activation.
Similarly, verify server code and database rollback together; an old binary is
not a recovery plan for an incompatible migrated database.

## Conversation forks

Capture a fixed message/turn boundary and preserve parent-thread lineage.
Offer a new chat in the current workspace or a new git worktree. Default a new
worktree to the selected completed turn's checkpoint. Preserve tracked and
non-ignored untracked source changes included by that checkpoint; never mutate
the source branch. Show the chosen file state before creating the fork.

If no matching checkpoint exists, make the available branch/commit choice
explicit. A non-git project can fork a chat but cannot offer a git worktree.
Do not copy ignored secrets, dependency directories, or process state; use the
project's existing workspace setup mechanism for dependencies and configuration.

Reuse a native provider fork only when that adapter supports both the selected
history boundary and target working directory. Otherwise start a fresh provider
session with the captured conversation, relevant tool results, and supported
attachments. Cross-harness forks always use this context-transfer path.
Do not copy provider resume tokens across harnesses or represent a summary as an
exact native fork. Disclose any context-limit reduction or unsupported attachment.

Preserve history for display, but seed the destination model as historical
context rather than automatically replaying old user commands. The new chat waits
for its next prompt. A fork never cancels or changes its parent. Forking while a
parent works captures the last selected completed boundary, not an unstable file
copy from the active turn.

Validate harness/model availability on the destination environment. Disable
unavailable choices with a useful reason. A failed operation must be retryable
without duplicate threads or abandoned worktrees; clean up only artifacts created
by that operation.

## Delivery and evidence

1. Shared-environment build/migration and two-client visibility. Reuse only the
   existing implementation pieces that pass focused tests and review.
2. Durable server update queue and atomic idle/admission gate, tested with a turn
   starting concurrently with activation and with a busy remote machine.
3. Nightly discovery/build pipeline and desktop restart integration, including
   patch conflict, failed launch, offline target, and database rollback cases.
4. Fork orchestration/provider context transfer/worktree creation, followed by
   Reasoning UI and an end-to-end Claude-to-Codex example.
5. Staged activation on the real environments after integration verification and
   an idle cutover; confirm both clients see the same newly created conversation.

Keep implementation PRs to one observable concern, generally under 600 changed
lines excluding fixtures. Establish component-specific CI coverage; the existing
fleet workflows do not cover this component's JavaScript or Markdown yet.
Use Fable 5.1 high for code and Astra for planning, integration, and review.
After each PR and later push, use Luna low to watch CI and Greptile, quote results,
and report only. Astra validates findings; Fable fixes confirmed code defects.
Repeat focused checks and the review wave on the changed head until resolved.

Do not treat a green review badge as proof of behavior. Acceptance requires the
named integration cases with isolated test data, then evidence from the installed
setup. Reuse one concise design; revise it for concrete implementation findings
rather than repeatedly expanding speculative review protocols.
