# Insomnia launch-readiness audit — 2026-09-05

**Verdict: the source is already public and MIT-licensed, but this revision is not ready for a stable public release.** Buildability is in good shape. Recovery correctness, installation failure handling, feature verification, and release documentation need work before recommending it to other users.

Scope: public **download-source, build, and use** distribution. A signed binary release is a separate, optional delivery target. This audit is led and independently reviewed by GPT-6 Astra in the Codex harness. It continues the original “Lid-Closed Agent Runtime” thread in the platform-created worktree on `t3code/open-source-launch-readiness`. Audited repository revision: `561e41dad3a44385835c4c3d3a086d1163891a5e`; latest Insomnia source commit: `205a4c1`. Insomnia source matches the local main checkout.

No production code, live configuration, power settings, credentials, network connections, installed app, or GitHub settings were changed. The existing unit tests were run; some append routine diagnostics to the local app log. This work adds an audit and isolated regression-probe source only. Nothing has been pushed or published.

## What was checked

| Check | Result and boundary |
| --- | --- |
| `swift test` | **178 existing tests pass**, zero failures. These include fake integrations; they do not certify hardware behavior. |
| `swift build -c release` | Pass on Apple Silicon, macOS 26.2, Xcode 26.4.1, Swift 6.3.1. No warning/error diagnostics in the captured build. |
| Bundle assembly | Built a separate temporary `.app` using the installer’s copy/sign steps. Ad-hoc signing and `codesign --verify --deep --strict` pass. No installation or launch. |
| Binary dependencies | arm64 executable; `otool -L` lists system frameworks/runtime libraries, with no developer-machine library paths. No external Swift package dependencies. Other architectures/minimum toolchains remain untested. |
| Installed bundle | Contains `KeyCatcherPanel`; no `PresetPopoverView`/`SessionPopoverView` symbols. Signature is ad-hoc, no Team ID. Confirms the focus fix is installed, not that every binary byte matches this checkout. |
| Scripts and plist | Insomnia script ShellCheck at warning level passes; shell syntax and Info.plist lint pass. Install/uninstall were reviewed, not executed. |
| Secret scan | Gitleaks with the repository configuration reports **no leaks across 152 local commits** (~17.90 MB). This is a scanner result within its rules, not proof of absence of every secret. |
| Repository hosting | GitHub reports PUBLIC, MIT, not archived. No releases returned. Root CI exists, but has no Insomnia Swift build/test or script-test lane. |
| Security reporting | GitHub API reports private vulnerability reporting **disabled**, although root SECURITY.md directs users there and offers no email alternative. |
| Targeted regression probes | **Six new tests fail with nine failed assertions** in a temporary package copy. They use fake power/process/backstop services; product source is unchanged. Details below. |
| Standalone backstop probe | Real script with a fixture log path that is a directory exits 1 at line 40 before recovery. Dirty journal remains unchanged. No real pmset or process signals are reached. |

The original session log does show a long successful session, lid-close freezing, seven PID resumes, session end, and sleep restoration. That is useful evidence for one normal path. It does not prove every app continued doing useful work, or the failure paths tested below.

## Release-blocking recovery findings

Priorities here describe impact on this product’s reliability promise, not CVSS scores or claims of remote compromise. **P1 means fix before a stable public release.**

### R1 — P1: asynchronous lifecycle operations can outlive session end

Evidence: `Sources/Insomnia/Core/SessionManager.swift:114–160,164–210,228–250`; `Sources/Insomnia/InsomniaApp.swift:63,68–75`.

MainActor does not serialize an entire operation across its `await` points. Start and extension resume without checking whether end/quit invalidated them. The UI’s pending-start guard does not cover app termination or the deadline racing an extension.

Three deterministic probes reproduce consequences:

- Pause start while scheduling its backstop, run end, then release start: sleep becomes disabled **after** cleanup, while session.json is absent and the ownership flag is false.
- Pause extension, end the session, release extension: an ended session reappears in memory and on disk, despite sleep already being restored.
- Pause the actual Low Power Mode enable side effect, end, release it: Low Power Mode becomes enabled after end while the journal says it is clean.

**Acceptance:** serialize lifecycle transitions or use explicit operation generations plus compensation for already-started side effects. Gate every await in start/extend/reconcile/power changes; let end or quit intervene. Once cleanup finishes and stale operations complete, no session, observer, timer, or unowned power change may reappear. Merely checking cancellation after pmset returns is insufficient to undo a late mutation.

### R2 — P1: recovery setup is not transactional and reconcile does not fail closed

Evidence: `Core/LaunchdBackstop.swift:32–39,66–89`; `Core/SessionManager.swift:164–183,358–389` (under `Sources/Insomnia/`).

Backstop replacement overwrites the plist, boots out the existing job, then attempts bootstrap. Bootstrap failure can leave **no loaded backstop**, contrary to extend’s comment that the old deadline remains. Conversely, a successful reschedule followed by failed session persistence leaves the backup at the proposed later deadline while the accepted session retains its old deadline. These partial failures are confirmed by control flow; real launchd failure injection was not performed.

Reconcile is worse than ordinary start: it reapplies sleep prevention **before** successfully rearming the backstop, ignores a journal-write failure with `try?`, and continues after pmset or scheduling failure. A deterministic fake-backstop probe confirms that failed scheduling still leaves sleep disabled and the session active. A pmset failure also leaves the journal intent flag true; `UI/StatusItemController.swift:432` passes that flag into the “Sleep held” status instead of independently verified state.

**Acceptance:** prove recovery is armed before applying sleep prevention, including reconcile. Restore the previous schedule on partial replacement/persistence failure, or end and restore safely. Never apply a side effect after failed journaling. Separate recovery intent from confirmed live status. Tests must model successful bootout followed by failed bootstrap; a fake that throws before doing anything cannot establish rollback.

### R3 — P1: logging and unsynchronized journals can defeat independent recovery

Evidence: `scripts/backstop.sh:19,38–40,49–125`; `Sources/Insomnia/Store/Store.swift:39–49`; `Core/SessionManager.swift:281–326`; `Core/LidActions.swift:76–89`.

The first backstop log call is mandatory under `set -e`. An unusable log path aborts before pmset or SIGCONT; this is reproduced with the real script and a safe fixture. Later logging failures can interrupt a partial restore. Logging must be best effort throughout recovery.

Separately, the app and backstop read/write the same session/state files without a shared lock or session-generation check. Whole-file atomic rename protects one write from truncation; it does not serialize validity checks, side effects, deletes, and several `plutil` updates across processes. Old recovery can clear newer state, or an app write can overwrite recovery progress. This overlap is a source-confirmed missing coordination mechanism; no live concurrent power/process experiment was run.

**Acceptance:** broken/unwritable logs must not prevent independent restore attempts. Use barriers around backstop validity checks and PID snapshots to interleave a new session/app journal update. Old recovery must never delete newer session state or forget processes it did not resume. Define a common lock/identity protocol for both writers.

### R4 — P1: uninstall removes the recovery mechanism even after restoration fails

Evidence: `scripts/uninstall.sh:26–56`; `scripts/backstop.sh:79–94,127–132`.

Uninstall deletes the session, ignores backstop failure, removes the LaunchAgent and sudoers grant, then deletes state.json. The backstop itself returns success even when pmset failed and it intentionally kept a dirty journal. Therefore uninstall can print Done while leaving sleep disabled or other recorded changes unrecovered, with the retry machinery removed. Its fixed two-second wait also does not prove the app’s asynchronous cleanup has finished.

**Acceptance:** make restore outcome machine-readable and verify app termination. Inject pmset and logging failures into an isolated installer harness. Failed restore must stop teardown, preserve the journal and recovery capability, and return actionable failure. Only successful recovery may permit removal. An authenticated fallback restore can precede teardown when the original grant is broken.

## Other confirmed behavior and security issues

These are **P2 unless noted**. Address them before stable release, or deliberately disable/limit the affected feature and document the boundary.

| Finding | Evidence | Required behavior / acceptance |
| --- | --- | --- |
| Original power preferences are not preserved | `Core/SessionManager.swift:228–250,302–306`; `Core/SleepGuard.swift`; `Model/RuntimeState.swift` | An already-enabled user Low Power Mode setting is claimed as Insomnia’s and later cleared. Snapshot original settings and restore only owned changes. Global sleep clearing also needs an explicit ownership policy. |
| Countdown pause survives into the next session | `Core/SessionManager.swift:419–427,475,498–503` | Reproduced: pause, end, start again leaves countdown timer unarmed. Reset/rederive pause from current lid state. Start/reconcile while already closed also needs initial lid actions, not just future change callbacks. |
| Browser profile arguments lose spaces | `System/BrowserThrottle.swift:29–79,190–216` | Reproduced: `--profile-directory=Profile 1` becomes `--profile-directory=Profile`; spaced user-data paths truncate. A harmless real process confirmed macOS `ps` flattens argv without protective quoting. Use a lossless argv source and preserve the actual profile. |
| Stale browser scans and misleading relaunch success | `System/BrowserThrottle.swift:167–205`; `Core/AppServices.swift:35–38,249–255` | Older asynchronous scans can overwrite newer results. A refused browser quit still proceeds to `open` and can log success without changing running flags. Keep newest-request results; fail relaunch accurately and verify effective flags. |
| Network recovery work survives stop | `System/NetworkFailover.swift:239–243,276–309,365–382`; `System/TmuxNudge.swift:22–35` | Untracked recovery tasks can continue typing into subsequent tmux panes or posting status after session end. Gate first of two fake target calls, stop, release: there must be no second call or stale publication. Cancel/generation-check async completion as well as timers. |
| PID journals do not establish process ownership | `Core/ProcessControl.swift:45–69`; `Core/LidActions.swift:76–89`; `scripts/backstop.sh:77,97–125` | Numeric PID/PPID/stopped checks cannot distinguish reused PIDs across exits/reboots. Previously stopped processes are not excluded. Signal failures are forgotten when all entries clear. Record stable identity and original stopped state, preserve retryable failures, reject invalid/nonpositive IDs. A malformed PID 0 in shell recovery can address the process group; normal discovery does not generate it. No foreign-user signal permission bypass was found. |
| Docker can query the wrong daemon | `System/DockerRule.swift:31–58` | Bare `docker ps -q` follows the current context/environment, while freeze always targets local Desktop. An empty remote/alternate daemon can cause local busy Desktop to be frozen. Bind the probe to the actual Desktop instance; test context and environment overrides. |
| Floor changes wait for another power event | `UI/SettingsView.swift:40–65`; `Core/AppServices.swift:102–106,222–234` | Changing a floor while battery/thermal readings stay constant does not immediately reevaluate it. Test an active session at 50%, then set endFloor=60 without another hardware event. |
| Settings can silently disable protections | `UI/SettingsView.swift:167–174`; `Model/Config.swift`; `Core/FloorRules.swift:27–37` | 0 is accepted as an end floor without explaining that the battery cutoff becomes impossible. Validate ranges/relationships on load and save, or make disabling an explicit, clearly labeled choice. Surface persistence failures instead of logging them only. |
| Multi-user install/restore collisions | `scripts/install.sh:15,52–65`; `scripts/uninstall.sh:21,44–46` | Every account overwrites/removes the same sudoers file, while pmset is global and journals are per-user. Choose one owning account and enforce it, or design coordinated multi-user ownership. Test A/B install/uninstall with shims. |
| Restore-everything and purge boundaries are inaccurate/incomplete | `System/AppNap.swift`; `scripts/backstop.sh:117–125`; `scripts/uninstall.sh` | App Nap preferences persist after end/uninstall by design. Standalone backstop retains saved audio fields but does not restore audio. Purge does not remove hotspot Keychain items, and uninstall does not explicitly unregister SMAppService login launch. Restore owned changes or accurately disclose retention and provide cleanup. Audio also lacks original output-device identity. |

Paths in the table are relative to `Sources/Insomnia/` unless they begin with `scripts/`.

Security boundaries that are already sensible: Swift subprocesses use argument arrays and absolute executables; hotspot passwords use Keychain and CoreWLAN instead of command arguments; the app and recovery script run as the user; sudoers grants four literal pmset commands. I found **no established generic root execution, remote code execution, or password disclosure path**. A user-writable LaunchAgent script is not itself root escalation under these exact grants. Any process running as that user can use the four grants, so installation documentation must describe the actual privilege scope.

Additional hardening and privacy work:

- Derive the sudoers identity from the actual UID rather than trusting `$USER`; reject an entire root-run install and validate the account. Untrusted installer environment is not a standalone root exploit, but stale/crafted values can grant the wrong identity after the user authorizes sudo.
- Escape home paths in installer-generated XML. Swift’s serializer does this; the shell heredoc does not. A path containing `&` can fail after the old agent has been removed.
- `INSOMNIA_HOME` is not propagated into the generated LaunchAgent environment. Either limit the override to tests or ensure scheduled recovery reads the same relocated journal. Install/uninstall currently use standard HOME paths.
- SSIDs and tmux target names are logged; all Swift log interpolation is marked public. Files use default modes; live config/state were 0644. Actual cross-user accessibility depends on ancestor permissions. Add private modes, metadata redaction, log retention limits, and a safe diagnostics-sharing procedure. No hotspot password was read during this audit.
- CoreWLAN chooses the first SSID match. Security-mode/downgrade handling and Keychain access after an ad-hoc rebuild need explicit tests; an evil-twin credential disclosure was **not established**.
- Tmux sends `continue` plus Enter to configured panes. Keep it explicit opt-in and document/verify target identity and pending input; pane names can later refer to another program.
- The timeout subprocess wrapper kills only its immediate child; inherited output pipes held by descendants can defeat its wall-clock bound. pmset/launchctl use the wrapper without a timeout. Test cancellation/hung-child behavior before promising bounded recovery latency.

## Adjudication of the pasted audit

| Pasted claim | Current assessment |
| --- | --- |
| Merged focus fix is installed; build and 178 tests pass | **Confirmed anew**, within the verification boundaries above. |
| Hotspot failover has never worked | **Too absolute.** Live SSID remains empty; 16 outage records and 294 missing-SSID skip messages show no successful join in the available logs. This proves the configured feature was not exercised successfully, not that CoreWLAN implementation cannot work. A user must configure their own hotspot; defaults should not contain yours. |
| Live floors are 100/0 | **Confirmed.** Shipped defaults are correctly 40/10. At 100, battery-triggered LPM applies below 100% while on battery, not literally always/on AC. At 0, the battery-end rule cannot fire. Actual build slowdown was not measured. Recommend restoring your live 40/10 values separately; audit did not change them. |
| Preset chips have no consumer | **Substantially correct.** No one-click preset chooser remains. The preset list still supplies the default-preset picker, and defaultPreset itself is used by empty Enter. Restore a menu chooser or intentionally revise Settings/spec; do not describe all default-preset behavior as dead. |
| README/spec describe deleted popovers/files | **Confirmed.** README:59; spec sections 1/11 and file layout. Replace with the actual pills, right-click menu, Settings window, and current source layout. |
| Chrome/tmux/thermal/mute tests never ran | **Hardware acceptance remains unproven.** Unit coverage exists, but cannot establish these real integrations. Live tmux targets remain empty and mute remains false; absence of configuration/log evidence cannot prove every historical test was never attempted. |
| Docker cannot fire because agentList denies it | **Incorrect.** `DockerRule.swift:34` explicitly passes `applyDenylist:false`. It is reachable and covered by idle/busy/error unit scenarios. The real defects are the contradictory “Agents are never frozen” copy and the daemon-context mismatch. |
| logFrames on launch; deprecated activation; stale refreshes | **Confirmed.** Two unconditional startup layout logs are P3 cleanup, not continuous polling. Old activation calls remain at SettingsWindow:26 and StatusItemController:497; no warning appeared in this build. Stale refresh handling is a correctness issue described above. |
| Reconcile journals true before pmset, so “sleep held” lies | **Confirmed with an important distinction:** journal-before-side-effect is intentional recovery design. Reporting that intent as verified state, ignoring journal failure, and continuing without a backstop are the defects. |
| Untracked mockup and no .github | **Mixed.** The mockup remains untracked in the original main checkout and is absent from this clean worktree. Root `.github` exists; Insomnia-specific CI does not. Choosing whether to publish a design mockup is not a release safety blocker. |
| No icon, ad-hoc only, version 0.1.0 / personal wording | **Confirmed.** Icon and product metadata need polish; signing/notarization apply to the intended binary-delivery experience, not publishing source for local builds. |
| Interactive sudo makes public use unacceptable | **A product choice, not an established fact.** These narrow, reviewable grants can be supported for technical source builders if clearly documented and safely installed/removed. A signed privileged helper is an architectural option, not a prerequisite for open source. |

## Public source-build release requirements

1. Fix R1–R4 and adopt the regression probes as passing permanent tests with meaningful failure injection. Do not preserve the unconditional “always restores” promise until its actual boundary is proven.
2. Add an Insomnia CI lane with a macOS/Xcode combination meeting the package’s Swift 6.2 and macOS 26 requirements: build, Swift tests, script lint, and isolated install/backstop/uninstall failure tests. Current CI builds fleet/T3 only. Pin and state the toolchain actually tested; the README’s “Xcode 26 (Swift 6.3)” is less precise than the observed environment.
3. Update Insomnia README/spec for source-build distribution, current UI, privileged actions, supported hardware/OS, optional feature setup, troubleshooting, recovery, and uninstall/retention. Link Insomnia from the root repo entry point or document its place in the monorepo. Root MIT applies now; preserve its notice if extracting a standalone repository.
4. Make security reporting usable: enable the promised private reporting route or provide another private channel, and explicitly include Insomnia in the scope. Root CONTRIBUTING currently assumes Harbor/fleet rules and tests; add an Insomnia contribution path. No GitHub setting was changed by this audit.
5. Resolve the preset chooser, truthful Docker exception, dangerous floor semantics, persistence errors, browser relaunch correctness, original-state ownership, and privacy/retention findings. Features with unresolved hazards should be disabled by default or withheld with explicit limitations.
6. Record the hardware acceptance matrix below, with macOS build, Mac model, app revision, outcome, and sanitized evidence. A second clean account/Mac matters because this machine already has grants and permissions.
7. Choose a source release version/tag and write release notes and known limitations. An app icon is useful polish; it does not outrank recovery correctness. Publishing a stable tag/release was not part of this audit.

**Optional downloadable binary track:** separately add Developer ID signing, Hardened Runtime, secure timestamp, notarization/stapling, packaging, and tests of the exact quarantined artifact on a clean Mac. This checkout’s ad-hoc build is not that artifact. Apple documents these requirements for [notarized direct distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution). They should not be misreported as a blocker to offering source that a user builds locally.

The product currently promotes doing work while the laptop is **in a bag**. Remove that supported-use claim. Apple recommends a stable surface with good ventilation in its [Mac laptop temperature guidance](https://support.apple.com/en-us/102336). App thermal callbacks and a deadline-only LaunchAgent do not establish safe enclosed operation. After an app crash, battery/thermal observers are gone until restart; the backstop only restores at its scheduled deadline. Test on a ventilated surface; do not deliberately overheat a laptop to validate a thermal rule.

## Hardware acceptance still required

| Scenario | Evidence needed |
| --- | --- |
| Clean install/build/uninstall | New account or disposable test Mac; correct grants/paths; cancellation and denied-sudo outcomes; clean removal and owned-state restoration. |
| Timed closed-lid session | Battery and AC, actual agent progress during close, open/end/quit restore, deadline recovery after controlled app termination. Inspect loaded launchd deadline and actual pmset state, not logs alone. |
| Sleep/recovery edge cases | Reboot/login/logout, clock/time-zone changes, app restart with valid/expired/corrupt journal, missing grant/script, failed reload. Start with fake/isolated tests for destructive failure paths. |
| Hotspot | Grant/deny/restricted Location states, correct/incorrect password, absent hotspot, actual SSID association and resumed network requests, disconnect/recovery timing, cancellation at end. Do not collect credentials in logs. |
| Chrome/Chromium/Arc | Measure actual occlusion/background task progress with lid closed and no external display, compare flags, verify profiles/tabs preserved, and handle refused quit. Remove or narrow the feature if the spec’s claimed occlusion premise is false. |
| Docker Desktop | Idle/busy/error paths on the real Desktop daemon, alternative context and env overrides, relevant VM/helper coverage, resumed containers. |
| Audio | Mute/unmute and original volume, app death and restart, Bluetooth/default-output change, restore failure retention. |
| tmux | Disposable named panes and known programs; verify opt-in input/recovery timing and no input after session end. |
| Battery/thermal | Inject all floor decisions/failures first; safe observation of actual callbacks and power state, AC-vs-battery LPM semantics, edited-floor immediacy. No critical-heat stress test. |
| UI/accessibility/login | Keyboard focus, Escape/outside click, VoiceOver actions, reduced motion, menu on multiple displays/Spaces, login registration and revocation, fresh countdown after a closed-lid end. Source hooks exist; a complete interactive pass was not run. |

These are outstanding checks, not claims that they passed. Hotspot credentials, physical lid manipulation, extra hardware, and fresh-account permissions were not supplied or changed during this audit.

## Reproduce the six deterministic failures

Probe source: [`audit-probes/AuditRegressionTests.swift`](audit-probes/AuditRegressionTests.swift). It deliberately asserts the desired safe behavior and currently fails; it lives outside the normal test target. It uses the existing Harness/fakes plus gated backstop/power fakes. It does not operate real pmset, launchd, networking, or other apps.

From `insomnia/`, copy source and tests into a temporary package:

```sh
probe_dir="$(mktemp -d /tmp/insomnia-audit-probes.XXXXXX)"
cp Package.swift "$probe_dir/"
cp -R Sources Tests scripts "$probe_dir/"
cp docs/audit-probes/AuditRegressionTests.swift "$probe_dir/Tests/InsomniaTests/"
cd "$probe_dir"
swift test --filter AuditRegressionTests
```

Observed: six tests failed, nine assertions. Test names identify end-during-start, end-during-extension, pending-LPM-after-end, reconcile-without-backstop, paused-next-countdown, and spaced-browser-profile cases. Existing suite and release-build success are separate facts; these failures are product defects, not an inability to build the probe.

Local raw logs from this audit are `/tmp/insomnia-audit-swift-test.log`, `/tmp/insomnia-audit-release.log`, `/tmp/insomnia-audit-regression.log`, and `/tmp/insomnia-audit-gitleaks.log`. Independent Astra review notes remain at `/tmp/insomnia-astra-security.md` and `/tmp/insomnia-astra-behavior.md`; this report reconciles their findings with the executed probes. None of these logs or private review notes were uploaded.
