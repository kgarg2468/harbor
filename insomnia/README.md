# Insomnia

An open-source macOS menu bar app for timed awake sessions, including work with
the lid closed. Pick a duration, protect your agent apps from the configured
freeze list, and restore recorded changes when the session ends.

**Source preview; hardware acceptance is still in progress.** The code is MIT
licensed. Build it locally on a supported Mac. This is not a signed, notarized
binary release, and the recovery mechanism is not a guarantee against power
loss, denied privileges, unavailable devices, or every macOS failure.

Use a stable, ventilated surface. Closed-lid operation inside a bag or other
enclosure is not a supported use case. See [Apple’s temperature guidance](https://support.apple.com/en-us/102336).

## Build and install

Supported test environment: Apple Silicon, macOS 26.2, Xcode 26.4.1 / Swift
6.3.1. The package requires macOS 26 and Swift 6.2 or newer. Intel Macs and other
OS/toolchain combinations have not been verified. There are no external Swift
package dependencies; Harbor’s other projects are not needed to build Insomnia.

```sh
git clone https://github.com/kgarg2468/harbor.git
cd harbor/insomnia
swift test
swift build -c release
./scripts/install.sh
open ~/Applications/Insomnia.app
```

The installer builds and locally signs the app, stages it before replacement,
installs independent recovery, and asks for administrator authentication to
install a narrowly scoped sudoers rule. Run the script as your login account;
do not run the whole script with sudo. Review `scripts/install.sh` first.

The rule grants that account passwordless access to exactly these commands:

```text
/usr/bin/pmset -a disablesleep 1
/usr/bin/pmset -a disablesleep 0
/usr/bin/pmset -b lowpowermode 1
/usr/bin/pmset -b lowpowermode 0
```

These power settings affect the machine. Any process running as the granted
account can use those four commands. The GUI and recovery helper run as the
user, and receive no general root-command permission. Only one account may own
this installation’s grant; another account cannot replace or remove it.

Keep Insomnia closed until installation finishes. The installer verifies app
termination and serializes recovery and replacement. New GUI instances and
session activation refuse work while installation is in progress. If recovery
or agent loading fails, follow the reported error and retry; do not delete the
recovery files to force installation through.

For a downloadable app, Developer ID signing, Hardened Runtime and
[notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
are a separate release track. The local ad-hoc signature does not provide that
distribution experience. Do not disable Gatekeeper globally.

## Use

- Click the cup to enter Days / Hours / Minutes. Tab changes fields; Enter
  starts; Escape or an outside click dismisses entry.
- Right-click for preset Start actions, status, Settings and Quit. During a
  session, presets extend it. Edit presets and the default in Settings.
- Click the running countdown to enter an extension. Hold the end control to
  end early. Quit ends the session and waits for cleanup; incomplete cleanup
  leaves an error and permits a retry.
- Default battery thresholds are 40% for Low Power Mode and 10% to end the
  session. They apply below the threshold while on battery. Thermal rules
  request Low Power Mode at serious heat and end at critical heat. Valid
  thresholds are 1–99%, with the end threshold no higher than the power threshold.

Settings changes are saved before taking effect. Edited floors reevaluate the
current session immediately. Invalid legacy floor settings use 40/10 and show
an explanation. User power settings already enabled before the session are
preserved; Insomnia restores its own recorded changes.

## Optional integrations

| Feature | Setup and current boundary |
| --- | --- |
| App freezing | Review the configured bundle IDs. Apple apps, Insomnia and listed agent apps are protected from ordinary freezes. Process identity includes its birth time and the current boot, not just a reusable PID. |
| Docker Desktop | Off by default. Explicitly opting in allows idle Desktop freezing even when Docker is in the agent list. The probe uses the current user’s local Desktop socket and ignores remote context/environment overrides. Test idle/busy behavior on your Mac. |
| Audio mute | Off by default. Recovery uses the saved output device identity. Reconnect an unavailable original device and retry cleanup. Real Bluetooth/device-change recovery still needs acceptance testing. |
| Browser flag checks | Off by default. Enable in Settings to offer Chromium relaunch with backgrounding flags. Relaunch closes the selected browser and preserves its profile arguments. Closed-lid occlusion and actual workload benefit have not been measured on the supported hardware. |
| Hotspot failover | Off until an SSID is configured. Enter your own SSID/password in Settings and grant Location permission when prompted. Test an actual outage before relying on it. |
| tmux nudge | Off with an empty target list. A configured target receives `continue` and Enter after a long outage. Use a dedicated pane with known input state; pane names can later refer to another program. |

Hotspot passwords stay in the login Keychain under service `insomnia-hotspot`;
they are passed to CoreWLAN, never placed in command arguments. Location
permission lets macOS reveal SSIDs and discover the hotspot. A configured
password requires a supported personal-security network; an open SSID match is
not accepted as a substitute. An already-running native Wi-Fi association may
finish after cancellation; later retries and status publication are cancelled.

Browser flags are an experimental compatibility aid, not evidence that a
closed lid always makes Chrome occluded. Test headed browser task progress and
profile preservation before enabling it. Insomnia does not automatically write
persistent App Nap preferences into other applications.

## Recovery and troubleshooting

`session.json` records the accepted deadline and session identity. `state.json`
records changes that still need restoration. The GUI and backstop hold the same
persistent file lock while checking validity, applying changes and saving
progress. Failed restoration keeps its journal entries for retry.

The per-user LaunchAgent runs at load and around the scheduled deadline, and
retries failed recovery. It invokes the installed recovery helper for process
and audio restoration. It requires the login session, its installed files and
the power-command grant to remain available. After a GUI crash, battery and
thermal monitoring stop until the GUI restarts; independent recovery is driven
by the deadline, not continuous battery or thermal observation.

If cleanup fails, reconnect missing devices, restore the installation/grant as
reported, and retry. Do not delete `state.json`, the helper or the sudoers rule
while changes remain outstanding. Old records containing only PIDs, or audio
without a device identity, cannot safely identify their targets. They require
manual ownership resolution; do not send signals to an unverified PID copied
from an old log.

A killed installer may leave `/private/tmp/com.kgarg.insomnia-install.lock`.
Confirm no installer is running, inspect the guard’s owner, and have that owner
remove the abandoned empty directory. The scripts never steal an occupied guard.

## Files and diagnostics

```text
~/Applications/Insomnia.app
~/Library/Application Support/Insomnia/   config.json, session.json, state.json,
                                        backstop.sh, InsomniaRecovery,
                                        recovery.lock, instance.lock
~/Library/Logs/Insomnia/                  insomnia.log, handoffs.log
~/Library/LaunchAgents/                  com.insomnia.backstop.plist
/etc/sudoers.d/insomnia
```

App data/log directories are private to the account; metadata files use mode
0600. New diagnostics redact interpolated metadata. Diagnostic and handoff logs
keep a bounded active file and one archive. On migration, old diagnostic logs
are preserved privately in `legacy-diagnostics`; that one-time archive may
contain old personal metadata and is outside automatic retention. Inspect and
remove it yourself when no longer needed. Never attach raw legacy logs,
config/state files, passwords or full tmux output to a public issue.

`INSOMNIA_HOME` relocates application journals/logs and the test LaunchAgent
path. It is useful for isolated development; install/uninstall explicitly
reject this override and operate on standard per-user paths.

## Uninstall

```sh
./scripts/uninstall.sh
./scripts/uninstall.sh --purge
```

Uninstall restores owned changes before removing recovery capability. If
recovery fails or the LaunchAgent cannot be confirmed unloaded, it keeps the
installation and reports failure. Ordinary removal retains configuration and
logs. Purge also removes saved configuration/logs and hotspot credentials.
Persistent recovery and instance lock files remain to keep concurrent waiters
on the same inodes. Login-item cleanup and legacy-install boundaries are
reported by the script; check its result before calling removal complete.

## Contribute and report problems

```sh
swift test
swift build -c release
/usr/bin/python3 -m unittest discover -s Tests/scripts -p 'test_*.py' -v
shellcheck -S warning scripts/*.sh
```

The shell tests use isolated command shims, never real sudo, power changes,
application termination or LaunchAgents. Automated checks cannot certify
hardware behavior. See the [current specification](docs/spec.md),
[release checks](docs/release-checks.md), and
[historical launch audit](docs/launch-readiness-audit-2026-09-05.md).

For vulnerabilities, use [private reporting](https://github.com/kgarg2468/harbor/security/advisories/new).
For ordinary bugs, include the revision, macOS/Xcode versions, steps and a
sanitized result. Root [MIT licensing](../LICENSE) and
[contribution guidance](../CONTRIBUTING.md) apply to Insomnia.
