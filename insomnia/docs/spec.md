# Insomnia specification

This describes the source preview’s intended, tested software behavior. Hardware
claims remain subject to the [release checks](release-checks.md). The
[September 5 audit](launch-readiness-audit-2026-09-05.md) describes an older
revision and preserves the evidence that motivated these changes.

## Purpose and platform

Insomnia runs timed awake sessions for work on a ventilated Mac. It can pause
selected non-agent apps while the lid is closed and optionally assist browser,
Docker, audio, hotspot and tmux workflows. Enclosed or in-bag operation is not
supported. No claim is made that every agent or browser keeps making progress.

Source is MIT licensed, built with Swift Package Manager, and locally ad-hoc
signed by the installer. Supported verification uses Apple Silicon, macOS 26.2,
Xcode 26.4.1 and Swift 6.3.1. The package minimum is macOS 26 / Swift 6.2.
Public signed/notarized binaries are a separate delivery track.

## 1. Timed sessions

Use inline Days / Hours / Minutes entry or editable right-click menu presets.
The default presets include 30m, 1h, 2h, 4h, 8h, 12h, 24h and 3d; the maximum is
30 days. Enter with empty fields uses the configured default. During a session,
entry and preset actions extend the current deadline. Hold the end control for
early end; Quit requests cleanup.

Start saves the session and restoration intent, arms independent recovery, and
only then applies sleep prevention when needed. Extend updates the backstop and
accepted journal; a partial failure ends safely and retains unresolved work.
Lifecycle operations are serialized across asynchronous calls. End invalidates
queued work and waits for already-started mutations before restoring them.

The countdown redraw ticks each second while visible and stops with the lid
closed. Pause state is rederived for each session. Deadline handling is separate
from redraw, so a stopped display timer does not disable the session deadline.

## 2. Privilege and ownership

The installer grants one actual login UID exactly four literal pmset commands:
`-a disablesleep 0/1` and `-b lowpowermode 0/1`. These are machine power settings.
No arbitrary root execution is granted to the GUI or recovery helper. Other
processes of the owning account can use the same four commands.

Record original settings before changing them. Already-enabled user settings
are not claimed as Insomnia’s. Restore recorded originals; legacy ownership
flags without originals retain their documented off-restoration meaning.
Missing or ambiguous power readings fail safely instead of assuming off.

## 3. Lid events

IOKit reports clamshell changes with debounce. Active sessions run the close or
open action list. Starting or reconciling while already closed also runs the
initial close path. No active session means no lid side effects. A contended
synchronous journal transaction skips its action instead of blocking the UI.

## 4. Process and audio changes

Before a freeze, identify each process using PID, kernel birth time and boot
identity, and reject an already-stopped process. Recheck identity and expected
parent immediately before SIGSTOP. Recovery verifies identity again before
SIGCONT. Exited/replaced or already-running processes need no resume; failed or
unavailable lookups/signals remain journaled for retry.

Normal freeze planning excludes Apple apps, Insomnia, Docker Desktop and agent
bundle IDs. The separate opt-in Docker rule explicitly permits Docker Desktop
when its own local daemon reports no running containers. It uses the current
user’s actual Desktop socket and clears Docker context/environment overrides.

Optional audio muting records volume, mute state and the device UID together.
Mute and restore target that device. A disconnected original device remains
pending until available. Bare legacy PIDs or incomplete audio identities remain
unresolved; recovery must not guess their targets.

## 5. Agent and browser behavior

The agent list protects ordinary freezing. Insomnia does not automatically
write persistent App Nap defaults into other applications. Preferences written
by older versions are not guessed at or deleted automatically.

Browser checks and relaunch are off by default. When enabled, native process
arguments preserve profile/path boundaries, including spaces. Newest scans win;
superseded scans produce no publishable result. Relaunch requires the selected
process to still exist, confirms quit, passes the preserved profile arguments
and checks the new process’s effective flags. A successful `open` command alone
is not proof of success.

The optional flags are `--disable-backgrounding-occluded-windows` and
`--disable-renderer-backgrounding`. Their benefit for a particular closed-lid
workload remains unmeasured. If the premise fails the acceptance measurement,
remove or narrow the feature and its claims. It remains an explicit experiment.

## 6. Battery and thermal rules

Battery and thermal events drive a pure decision table. On battery, charge below
10% ends by default; charge below 40% requests Low Power Mode. Thermal serious
requests Low Power Mode and critical ends when thermal rules are enabled.
When neither condition requests Low Power Mode, restore only Insomnia’s owned
change. This controls the battery preference; it does not promise AC thermal
throttling or a particular build-performance improvement.

Saved floors must be 1–99%, with end <= low-power. Invalid legacy values use
40/10 with a visible notice. Successful Settings edits reevaluate the current
power sample immediately. Failed persistence does not change live settings.

## 7. Network and tmux

A Wi-Fi path outage starts a delayed, bounded-backoff hotspot attempt only when
an SSID is configured. CoreWLAN scans for that SSID; the login Keychain supplies
the password without command-line exposure. With a password, select supported
WPA3 Personal/transition or WPA2 Personal and reject weaker/open/unknown or
enterprise matches. This does not establish an access point’s physical identity.
Location permission is requested for configured hotspot use, not mere launch.

A satisfied path records the completed outage immediately. Long-gap recovery
may send `continue` and Enter to explicitly configured tmux targets and notify
the user. Cancelling invalidates later panes, retries and publication. A native
association already in progress may complete despite cancellation. tmux input
requires a dedicated, known pane; target names alone do not establish what
program or pending input currently occupies it.

## 8. Journal, backstop and cleanup

Session records have durable UUIDs on new writes; old files remain readable
without inventing new IDs during decode. A stale manager cannot delete or revive
a replacement session. A persistent BSD file lock coordinates the complete
read/validate/side-effect/write transaction between GUI and shell recovery.
An additional process-lifetime instance lock prevents two GUI owners.

The LaunchAgent runs at load and near the accepted deadline, with throttled
retries after failed recovery. Replacement attempts restore the previous job on
failure and report rollback failure explicitly. The shell invalidates the ended
session under the lease, restores owned power values, invokes the headless
process/audio helper on staged state and commits partial progress atomically.
Logging failures do not interrupt restoration.

Unreadable journals and failed restores remain pending. Cleanup attempts rearm
independent recovery and schedule a local retry; a stale retry cannot end a new
session. Quit refuses incomplete cleanup. New sessions cannot overwrite dirty
state. Backup files do not prove the corresponding launchd job is loaded.

The backstop requires the account’s login context, readable compatible files,
available devices and power privileges. It is not an independent continuous
battery/thermal monitor after GUI death and cannot guarantee restoration under
all OS, disk, privilege or hardware failures.

## 9. Notifications and diagnostics

Notify on session end, reminders, floor actions and network recovery. Report
incomplete cleanup distinctly from success. The menu’s sleep-held status is
confirmed state, not the journal’s intended side effect.

App-owned data directories are 0700 and files 0600 before metadata writes.
Persistent diagnostic interpolation is redacted; unified dynamic messages are
private. New diagnostic/handoff files keep a bounded active file and one
archive. Old diagnostic history is migrated into a private legacy directory,
retained outside automatic rotation and excluded from new sanitized output.

## 10. Settings and removal

Settings contain presets/default duration, freeze/agent lists, optional Docker,
audio and browser behavior, battery/thermal thresholds, hotspot credentials,
tmux targets and login registration. Password values use Keychain, not JSON.
Save and permission failures are visible.

Install/uninstall require standard per-user paths and reject root invocation,
foreign grants and `INSOMNIA_HOME`. They hold a machine installer guard and
verify GUI termination before committing under the recovery lease. New GUI
launch/activation refuses an installation in progress.

Removal requires successful recovery and confirmed agent unload. Configuration
and logs remain by default; purge also removes stored hotspot credentials.
Login-registration cleanup must be explicit, with a reported legacy-protocol
boundary. Recovery and instance lock inodes are retained.

## 11. Current menu bar UI

`NSStatusItem` hosts SwiftUI cup, pill fields and countdown. `KeyCatcherPanel`
handles keyboard entry/focus without the deleted popover design. Click for
entry/extension; right-click for preset actions, machine/action status,
experimental browser relaunch, Settings and Quit. A dedicated Settings window
holds configuration. There are no preset or session popovers.

`CupMark`, `PillView`, `HoldToEndButton` and `Motion` provide the existing visual
language. Reduced-motion and accessibility hooks remain part of acceptance.
Watts are read on request, not by the countdown timer. Battery/lid/SSID/browser
status refreshes are asynchronous and reject obsolete results.

## 12. Verification and source layout

The executable and tests live in `Sources/Insomnia` and `Tests/InsomniaTests`.
`Core` contains lifecycle, locking, subprocess and recovery logic; `Model` holds
configuration/session/runtime state; `Store` handles paths and persistence;
`System` contains hardware/integration adapters; `UI` contains the status item,
key panel, menu, Settings and SwiftUI views. `Tests/scripts` exercises the actual
installer/backstop/uninstaller against isolated command shims.

CI builds/tests Swift, assembles and verifies a locally signed bundle, lints
scripts and runs their failure fixtures. Manual acceptance remains tracked in
[release-checks.md](release-checks.md). Test on a ventilated surface; use injected
thermal samples, never intentional overheating as a test strategy.
